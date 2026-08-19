//
//  DepthPipeline.swift
//  전처리 → ML 추론 → 시각화. 전부 하나의 MTL4CommandBuffer 안에서 GPU 타임라인으로 이어진다.
//  추론 출력이 GPU 메모리를 떠나지 않는다 — CPU 왕복도, 포맷 변환도 없다.
//
//  M5 실측: 체인 전체 15.2ms (추론 단독 15.4ms) — 전처리·시각화는 사실상 공짜다.
//  정확성은 Tools/probe_p1.swift 가 Core ML과 대조해 검증한다 (r = 1.00000).
//

import Metal
import Foundation
import os

enum DepthPipelineError: LocalizedError {
    case modelNotFound
    case libraryMissing
    case pipelineFailed(String)
    case resourceAllocationFailed

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "모델을 찾지 못했습니다. 터미널에서 ./Tools/fetch_models.sh 를 실행하세요."
        case .libraryMissing:
            return "Metal 셰이더 라이브러리를 찾지 못했습니다."
        case .pipelineFailed(let stage):
            return "파이프라인 생성 실패: \(stage)"
        case .resourceAllocationFailed:
            return "GPU 리소스 할당에 실패했습니다."
        }
    }
}

/// 스레드 안전하지 않다. 전용 직렬 큐에서만 호출할 것.
nonisolated final class DepthPipeline {

    /// 모델 고정 입력 크기.
    static let modelWidth = 518
    static let modelHeight = 392

    /// 변환된 그래프는 f32 입출력을 기대한다. f16을 물리면 MPSGraph가 assert한다.
    private static let elementBytes = 4

    let device: MTLDevice
    let rowStride: Int

    private let queue: any MTL4CommandQueue
    private let allocator: any MTL4CommandAllocator
    private let commandBuffer: any MTL4CommandBuffer
    private let argumentTable: any MTL4ArgumentTable
    private let event: any MTLSharedEvent
    private var signalValue: UInt64 = 0

    private let preprocessPSO: any MTLComputePipelineState
    private let visualizePSO: any MTLComputePipelineState
    private let mlPSO: any MTL4MachineLearningPipelineState
    private let intermediatesHeap: MTLHeap

    private let inputBuffer: MTLBuffer
    private let inputTensor: MTLTensor
    private let depthBuffer: MTLBuffer
    private let outputTensor: MTLTensor
    private let uniformBuffer: MTLBuffer

    /// 결과 텍스처 링. 렌더러가 읽는 동안 GPU가 다른 것에 쓴다.
    private var depthTextures: [MTLTexture] = []
    private var writeIndex = 0

    private let staticResidency: any MTLResidencySet
    /// 카메라 텍스처는 매 프레임 바뀐다 — 커맨드 버퍼 단위 레지던시로 처리한다.
    private let frameResidency: any MTLResidencySet

    private var uniforms = SunUniforms()

    init(device: MTLDevice, outputWidth: Int, outputHeight: Int) throws {
        self.device = device
        self.rowStride = ((Self.modelWidth * Self.elementBytes + 63) / 64) * 64 / Self.elementBytes

        guard let packageURL = ModelLocator.mtlpackageURL() else { throw DepthPipelineError.modelNotFound }
        guard let shaderLibrary = device.makeDefaultLibrary() else { throw DepthPipelineError.libraryMissing }

        let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())

        func computePipeline(_ name: String) throws -> any MTLComputePipelineState {
            let function = MTL4LibraryFunctionDescriptor()
            function.name = name
            function.library = shaderLibrary
            let descriptor = MTL4ComputePipelineDescriptor()
            descriptor.computeFunctionDescriptor = function
            guard let pso = try? compiler.makeComputePipelineState(descriptor: descriptor) else {
                throw DepthPipelineError.pipelineFailed(name)
            }
            return pso
        }
        self.preprocessPSO = try computePipeline("preprocess_to_tensor")
        self.visualizePSO  = try computePipeline("visualize_depth")

        // ML 파이프라인
        let mlLibrary = try device.makeLibrary(URL: packageURL)
        let mlFunction = MTL4LibraryFunctionDescriptor()
        mlFunction.name = mlLibrary.functionNames.first ?? "main"   // 변환 결과는 "main"
        mlFunction.library = mlLibrary
        let mlDescriptor = MTL4MachineLearningPipelineDescriptor()
        mlDescriptor.label = "depth"
        mlDescriptor.machineLearningFunctionDescriptor = mlFunction
        mlDescriptor.setInputDimensions(
            Self.extents([Self.modelWidth, Self.modelHeight, 3, 1]), bufferIndex: 0)
        guard let mlPSO = try? compiler.makeMachineLearningPipelineState(descriptor: mlDescriptor) else {
            throw DepthPipelineError.pipelineFailed("machine learning")
        }
        self.mlPSO = mlPSO

        let heapDescriptor = MTLHeapDescriptor()
        heapDescriptor.size = max(mlPSO.intermediatesHeapSize, 4096)
        heapDescriptor.storageMode = .private
        heapDescriptor.type = .placement
        guard let heap = device.makeHeap(descriptor: heapDescriptor) else {
            throw DepthPipelineError.resourceAllocationFailed
        }
        self.intermediatesHeap = heap

        // 텐서 — 셰이더가 직접 읽으려면 buffer-backed 여야 한다.
        let (inBuffer, inTensor) = try Self.makeTensor(
            device: device, dims: [Self.modelWidth, Self.modelHeight, 3, 1], rowStride: rowStride)
        let (outBuffer, outTensor) = try Self.makeTensor(
            device: device, dims: [Self.modelWidth, Self.modelHeight, 1, 1], rowStride: rowStride)
        self.inputBuffer = inBuffer
        self.inputTensor = inTensor
        self.depthBuffer = outBuffer
        self.outputTensor = outTensor

        guard let uniformBuffer = device.makeBuffer(
            length: MemoryLayout<SunUniforms>.stride, options: .storageModeShared) else {
            throw DepthPipelineError.resourceAllocationFailed
        }
        self.uniformBuffer = uniformBuffer

        // 결과 텍스처 링
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: outputWidth, height: outputHeight, mipmapped: false)
        textureDescriptor.usage = [.shaderRead, .shaderWrite]
        textureDescriptor.storageMode = .private
        for _ in 0..<3 {
            guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
                throw DepthPipelineError.resourceAllocationFailed
            }
            depthTextures.append(texture)
        }

        let argumentDescriptor = MTL4ArgumentTableDescriptor()
        argumentDescriptor.maxBufferBindCount = 8
        argumentDescriptor.maxTextureBindCount = 4
        self.argumentTable = try device.makeArgumentTable(descriptor: argumentDescriptor)

        // Metal 4는 자동 레지던시가 없다.
        self.staticResidency = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
        staticResidency.addAllocation(inBuffer)
        staticResidency.addAllocation(outBuffer)
        staticResidency.addAllocation(uniformBuffer)
        staticResidency.addAllocation(heap)
        for texture in depthTextures { staticResidency.addAllocation(texture) }
        staticResidency.commit()
        staticResidency.requestResidency()

        self.frameResidency = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())

        let queueDescriptor = MTL4CommandQueueDescriptor()
        queueDescriptor.feedbackQueue = DispatchQueue(label: "delight.depth.feedback")
        self.queue = try device.makeMTL4CommandQueue(descriptor: queueDescriptor)
        queue.addResidencySet(staticResidency)

        guard let allocator = device.makeCommandAllocator(),
              let commandBuffer = device.makeCommandBuffer(),
              let event = device.makeSharedEvent() else {
            throw DepthPipelineError.resourceAllocationFailed
        }
        self.allocator = allocator
        self.commandBuffer = commandBuffer
        self.event = event

        uniforms.depthWidth = UInt32(Self.modelWidth)
        uniforms.depthHeight = UInt32(Self.modelHeight)
        uniforms.depthRowStride = UInt32(rowStride)
        uniforms.outputWidth = UInt32(outputWidth)
        uniforms.outputHeight = UInt32(outputHeight)
        uniforms.cx = Float(outputWidth) / 2
        uniforms.cy = Float(outputHeight) / 2
    }

    /// 한 프레임을 처리하고 깊이 시각화 텍스처를 돌려준다.
    /// GPU 완료까지 기다리므로 **전용 스레드에서 호출할 것**.
    func process(source: MTLTexture) -> MTLTexture? {
        uniformBuffer.contents().copyMemory(
            from: &uniforms, byteCount: MemoryLayout<SunUniforms>.stride)

        let target = depthTextures[writeIndex]
        writeIndex = (writeIndex + 1) % depthTextures.count

        // 카메라 텍스처는 CVMetalTextureCache가 돌려쓰므로 매 프레임 레지던시를 갱신한다.
        frameResidency.removeAllAllocations()
        frameResidency.addAllocation(source)
        frameResidency.commit()

        allocator.reset()
        commandBuffer.beginCommandBuffer(allocator: allocator)
        commandBuffer.useResidencySet(frameResidency)

        // [C0] 전처리 — 카메라 텍스처 → 모델 입력 텐서 (0-255 원본 RGB, NCHW)
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            argumentTable.setTexture(source.gpuResourceID, index: 0)
            argumentTable.setAddress(inputBuffer.gpuAddress, index: 0)
            argumentTable.setAddress(uniformBuffer.gpuAddress, index: 1)
            encoder.setArgumentTable(argumentTable)
            encoder.setComputePipelineState(preprocessPSO)
            encoder.dispatchThreads(
                threadsPerGrid: MTLSize(width: Self.modelWidth, height: Self.modelHeight, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.barrier(afterStages: .dispatch, beforeQueueStages: .machineLearning,
                            visibilityOptions: .device)
            encoder.endEncoding()
        }

        // [ML] 추론 — 같은 커맨드 버퍼
        if let encoder = commandBuffer.makeMachineLearningCommandEncoder() {
            argumentTable.setResource(inputTensor.gpuResourceID, bufferIndex: 0)
            argumentTable.setResource(outputTensor.gpuResourceID, bufferIndex: 1)
            encoder.setArgumentTable(argumentTable)
            encoder.setPipelineState(mlPSO)
            encoder.dispatchNetwork(intermediatesHeap: intermediatesHeap)
            encoder.barrier(afterStages: .machineLearning, beforeQueueStages: .dispatch,
                            visibilityOptions: .device)
            encoder.endEncoding()
        }

        // [C1] 시각화 — 추론 결과 버퍼를 그대로 읽는다
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            argumentTable.setAddress(depthBuffer.gpuAddress, index: 0)
            argumentTable.setAddress(uniformBuffer.gpuAddress, index: 1)
            argumentTable.setTexture(target.gpuResourceID, index: 0)
            encoder.setArgumentTable(argumentTable)
            encoder.setComputePipelineState(visualizePSO)
            encoder.dispatchThreads(
                threadsPerGrid: MTLSize(width: target.width, height: target.height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
        }

        commandBuffer.endCommandBuffer()
        queue.commit([commandBuffer])

        signalValue += 1
        queue.signalEvent(event, value: signalValue)
        guard event.wait(untilSignaledValue: signalValue, timeoutMS: 2000) else { return nil }

        return target
    }

    // MARK: 텐서

    /// device-alloc 텐서는 strides가 반드시 nil이어야 한다.
    /// 셰이더가 읽어야 하므로 MTLBuffer 기반으로 만든다.
    private static func makeTensor(device: MTLDevice, dims: [Int], rowStride: Int)
        throws -> (MTLBuffer, MTLTensor) {
        let descriptor = MTLTensorDescriptor()
        descriptor.dataType = .float32
        descriptor.usage = [.machineLearning, .compute]
        descriptor.storageMode = .private
        descriptor.dimensions = extents(dims)

        // machineLearning usage면 strides[1]이 64바이트 정렬이어야 한다.
        var strides = [1, rowStride]
        for i in 2..<dims.count { strides.append(strides[i - 1] * dims[i - 1]) }
        descriptor.strides = extents(strides)

        let sizeAndAlign = device.tensorSizeAndAlign(descriptor: descriptor)
        guard let buffer = device.makeBuffer(length: sizeAndAlign.size, options: .storageModePrivate),
              let tensor = try? buffer.makeTensor(descriptor: descriptor, offset: 0) else {
            throw DepthPipelineError.resourceAllocationFailed
        }
        return (buffer, tensor)
    }

    private static func extents(_ values: [Int]) -> MTLTensorExtents {
        values.withUnsafeBufferPointer { MTLTensorExtents(__rank: values.count, values: $0.baseAddress)! }
    }
}
