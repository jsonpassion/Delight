//
//  Metal4MLDepthProvider.swift
//  Metal 4 ML 인코더 경로 — 추론·라이팅·드로우가 같은 커맨드 버퍼에서 돈다.
//  추론 출력이 GPU 메모리를 떠나지 않는다.
//
//  준비: xcrun metal-package-builder -ml Model.mlpackage -o Model.mtlpackage
//  (Tools/fetch_models.sh 가 대신 해준다)
//

import Metal
import Foundation

enum DepthProviderError: LocalizedError {
    case packageNotFound(String)
    case pipelineCompileFailed
    case tensorCreationFailed

    var errorDescription: String? {
        switch self {
        case .packageNotFound(let n): return "모델 패키지를 찾지 못했습니다: \(n). Tools/fetch_models.sh 를 먼저 실행하세요."
        case .pipelineCompileFailed:  return "ML 파이프라인 컴파일에 실패했습니다."
        case .tensorCreationFailed:   return "텐서 생성에 실패했습니다."
        }
    }
}

@available(macOS 26.0, *)
final class Metal4MLDepthProvider: DepthProvider {

    let name = "Metal 4 ML"
    private(set) var depthBuffer: MTLBuffer?
    let rowStride: Int

    private let device: MTLDevice
    private let pipeline: any MTL4MachineLearningPipelineState
    private let heap: MTLHeap
    private let inputBuffer: MTLBuffer
    private let inputTensor: MTLTensor
    private let outputTensor: MTLTensor

    /// 변환된 그래프는 f32 입출력을 기대한다. f16 텐서를 물리면 MPSGraph가 assert한다.
    private static let elementBytes = 4

    init(device: MTLDevice, packageURL: URL, compiler: any MTL4Compiler) throws {
        self.device = device
        self.rowStride = DepthModelSpec.rowStride(elementBytes: Self.elementBytes)

        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw DepthProviderError.packageNotFound(packageURL.lastPathComponent)
        }

        let library = try device.makeLibrary(URL: packageURL)
        let function = MTL4LibraryFunctionDescriptor()
        function.name = library.functionNames.first ?? "main"   // 변환 결과는 "main"
        function.library = library

        let descriptor = MTL4MachineLearningPipelineDescriptor()
        descriptor.label = "depth"
        descriptor.machineLearningFunctionDescriptor = function
        descriptor.setInputDimensions(
            Self.extents([DepthModelSpec.width, DepthModelSpec.height, 3, 1]),
            bufferIndex: 0)

        guard let pso = try? compiler.makeMachineLearningPipelineState(descriptor: descriptor) else {
            throw DepthProviderError.pipelineCompileFailed
        }
        self.pipeline = pso

        let heapDescriptor = MTLHeapDescriptor()
        heapDescriptor.size = max(pso.intermediatesHeapSize, 4096)
        heapDescriptor.storageMode = .private
        heapDescriptor.type = .placement
        guard let heap = device.makeHeap(descriptor: heapDescriptor) else {
            throw DepthProviderError.tensorCreationFailed
        }
        self.heap = heap

        let (inBuf, inTensor) = try Self.makeTensor(
            device: device, dims: [DepthModelSpec.width, DepthModelSpec.height, 3, 1])
        let (outBuf, outTensor) = try Self.makeTensor(
            device: device, dims: [DepthModelSpec.width, DepthModelSpec.height, 1, 1])

        self.inputBuffer  = inBuf
        self.inputTensor  = inTensor
        self.outputTensor = outTensor
        self.depthBuffer  = outBuf
    }

    func encode(into commandBuffer: MTL4CommandBuffer, argumentTable: MTL4ArgumentTable) throws {
        argumentTable.setResource(inputTensor.gpuResourceID, bufferIndex: 0)
        argumentTable.setResource(outputTensor.gpuResourceID, bufferIndex: 1)

        guard let encoder = commandBuffer.makeMachineLearningCommandEncoder() else { return }
        encoder.setPipelineState(pipeline)
        encoder.setArgumentTable(argumentTable)
        encoder.dispatchNetwork(intermediatesHeap: heap)
        encoder.endEncoding()
    }

    /// 셰이더가 직접 읽으려면 device-alloc이 아니라 **buffer-backed** 텐서여야 한다.
    /// device-alloc 텐서는 strides가 반드시 nil이어서 패딩 제어가 불가능하다.
    private static func makeTensor(device: MTLDevice, dims: [Int]) throws -> (MTLBuffer, MTLTensor) {
        let descriptor = MTLTensorDescriptor()
        descriptor.dataType = .float32
        descriptor.usage = [.machineLearning, .compute]
        descriptor.storageMode = .private
        descriptor.dimensions = extents(dims)

        let row = DepthModelSpec.rowStride(elementBytes: elementBytes)
        var strides = [1, row]
        for i in 2..<dims.count { strides.append(strides[i - 1] * dims[i - 1]) }
        descriptor.strides = extents(strides)

        let sizeAndAlign = device.tensorSizeAndAlign(descriptor: descriptor)
        guard let buffer = device.makeBuffer(length: sizeAndAlign.size, options: .storageModePrivate),
              let tensor = try? buffer.makeTensor(descriptor: descriptor, offset: 0) else {
            throw DepthProviderError.tensorCreationFailed
        }
        return (buffer, tensor)
    }

    private static func extents(_ values: [Int]) -> MTLTensorExtents {
        values.withUnsafeBufferPointer { MTLTensorExtents(__rank: values.count, values: $0.baseAddress)! }
    }
}
