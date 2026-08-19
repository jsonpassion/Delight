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
    private let gbufferPSO: any MTLComputePipelineState
    private let relightPSO: any MTLComputePipelineState
    private let mlPSO: any MTL4MachineLearningPipelineState
    private let intermediatesHeap: MTLHeap

    private let inputBuffer: MTLBuffer
    private let inputTensor: MTLTensor
    private let depthBuffer: MTLBuffer
    private let outputTensor: MTLTensor
    private let uniformBuffer: MTLBuffer

    /// 결과 텍스처 링. 렌더러가 읽는 동안 GPU가 다른 것에 쓴다.
    private var depthTextures: [MTLTexture] = []
    private var relitTextures: [MTLTexture] = []
    private var writeIndex = 0

    /// G버퍼 — 뷰공간 위치, 노멀, 피사체 마스크. 프레임 안에서만 쓰이므로 링이 필요 없다.
    private let positionTexture: MTLTexture
    private let normalTexture: MTLTexture
    private let matteTexture: MTLTexture
    /// AO는 P3에서 채운다. 그때까지 흰색(차폐 없음)으로 바인딩만 유지한다.
    private let ambientOcclusionTexture: MTLTexture

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
        self.gbufferPSO    = try computePipeline("build_gbuffer")
        self.relightPSO    = try computePipeline("relight")

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
        // 출력만 .shared — 핀치 z를 CPU에서 읽어야 한다.
        // 통합 메모리라 비용이 거의 없다(프로브 실측 15.1~15.6ms로 .private과 동일).
        let (outBuffer, outTensor) = try Self.makeTensor(
            device: device, dims: [Self.modelWidth, Self.modelHeight, 1, 1],
            rowStride: rowStride, storageMode: .shared)
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
            guard let depthTexture = device.makeTexture(descriptor: textureDescriptor),
                  let relitTexture = device.makeTexture(descriptor: textureDescriptor) else {
                throw DepthPipelineError.resourceAllocationFailed
            }
            depthTextures.append(depthTexture)
            relitTextures.append(relitTexture)
        }

        // G버퍼. 위치는 미터 단위라 정밀도가 필요하다 — 16비트 부동소수점.
        func makeGBuffer(_ format: MTLPixelFormat) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: Self.modelWidth, height: Self.modelHeight, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw DepthPipelineError.resourceAllocationFailed
            }
            return texture
        }
        self.positionTexture = try makeGBuffer(.rgba16Float)
        self.normalTexture   = try makeGBuffer(.rgba16Float)
        self.matteTexture    = try makeGBuffer(.r8Unorm)
        self.ambientOcclusionTexture = try makeGBuffer(.r8Unorm)

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
        for texture in relitTextures { staticResidency.addAllocation(texture) }
        staticResidency.addAllocation(positionTexture)
        staticResidency.addAllocation(normalTexture)
        staticResidency.addAllocation(matteTexture)
        staticResidency.addAllocation(ambientOcclusionTexture)
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

    /// 한 프레임을 처리한다. GPU 완료까지 기다리므로 **전용 스레드에서 호출할 것**.
    /// - Parameter lighting: 메인 액터의 LightRig가 채운 스냅샷. 값 타입이라 그대로 건너온다.
    /// - Returns: 깊이 시각화와 재조명 결과.
    func process(source: MTLTexture,
                 lighting: SunUniforms? = nil) -> (depth: MTLTexture, relit: MTLTexture)? {
        if let lighting {
            // 해상도·텐서 레이아웃은 파이프라인이 소유한다. 조명 쪽 값만 받아들인다.
            var merged = lighting
            merged.depthWidth = uniforms.depthWidth
            merged.depthHeight = uniforms.depthHeight
            merged.depthRowStride = uniforms.depthRowStride
            merged.outputWidth = uniforms.outputWidth
            merged.outputHeight = uniforms.outputHeight
            merged.cx = uniforms.cx
            merged.cy = uniforms.cy
            uniforms = merged
        }
        uniformBuffer.contents().copyMemory(
            from: &uniforms, byteCount: MemoryLayout<SunUniforms>.stride)

        let target = depthTextures[writeIndex]
        let relitTarget = relitTextures[writeIndex]
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

        // [C3] 지오메트리 — 역깊이 → 뷰공간 위치·5-tap 노멀·피사체 마스크
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            argumentTable.setAddress(depthBuffer.gpuAddress, index: 0)
            argumentTable.setAddress(uniformBuffer.gpuAddress, index: 1)
            argumentTable.setTexture(source.gpuResourceID, index: 0)
            argumentTable.setTexture(positionTexture.gpuResourceID, index: 1)
            argumentTable.setTexture(normalTexture.gpuResourceID, index: 2)
            argumentTable.setTexture(matteTexture.gpuResourceID, index: 3)
            encoder.setArgumentTable(argumentTable)
            encoder.setComputePipelineState(gbufferPSO)
            encoder.dispatchThreads(
                threadsPerGrid: MTLSize(width: Self.modelWidth, height: Self.modelHeight, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.barrier(afterStages: .dispatch, beforeQueueStages: .dispatch,
                            visibilityOptions: .device)
            encoder.endEncoding()
        }

        // [C5] 리라이팅 — 레이마칭 그림자 + 확산 + 스펙큘러 + 역광
        // relight 커널은 유니폼을 buffer(0)에서 읽는다(다른 커널과 인덱스가 다르다).
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            argumentTable.setAddress(uniformBuffer.gpuAddress, index: 0)
            argumentTable.setTexture(source.gpuResourceID, index: 0)
            argumentTable.setTexture(positionTexture.gpuResourceID, index: 1)
            argumentTable.setTexture(normalTexture.gpuResourceID, index: 2)
            argumentTable.setTexture(matteTexture.gpuResourceID, index: 3)
            argumentTable.setTexture(ambientOcclusionTexture.gpuResourceID, index: 4)
            argumentTable.setTexture(relitTarget.gpuResourceID, index: 5)
            encoder.setArgumentTable(argumentTable)
            encoder.setComputePipelineState(relightPSO)
            encoder.dispatchThreads(
                threadsPerGrid: MTLSize(width: relitTarget.width, height: relitTarget.height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
        }

        commandBuffer.endCommandBuffer()
        queue.commit([commandBuffer])

        signalValue += 1
        queue.signalEvent(event, value: signalValue)
        guard event.wait(untilSignaledValue: signalValue, timeoutMS: 2000) else { return nil }

        return (depth: target, relit: relitTarget)
    }

    // MARK: 깊이 샘플링

    /// 정규화 좌표(좌상단 원점)에서 역깊이를 읽는다. 클수록 카메라에 가깝다.
    ///
    /// 손끝은 얇아서 최근접 한 점을 그냥 읽으면 깊이가 배경으로 샌다.
    /// 그래서 이웃에서 **가장 가까운 쪽 분위수**를 쓴다 — 평균이나 중앙값이면
    /// 배경 픽셀이 섞여 광원이 뒤로 밀린다. (docs/01-architecture.md §8)
    func sampleInverseDepth(atNormalized point: SIMD2<Float>, radius: Int = 2) -> Float? {
        guard depthBuffer.storageMode == .shared else { return nil }

        let cx = Int((point.x * Float(Self.modelWidth)).rounded())
        let cy = Int((point.y * Float(Self.modelHeight)).rounded())
        guard cx >= 0, cy >= 0, cx < Self.modelWidth, cy < Self.modelHeight else { return nil }

        let pointer = depthBuffer.contents().bindMemory(
            to: Float.self, capacity: depthBuffer.length / MemoryLayout<Float>.size)

        var neighborhood: [Float] = []
        neighborhood.reserveCapacity((radius * 2 + 1) * (radius * 2 + 1))
        for dy in -radius...radius {
            let y = cy + dy
            guard y >= 0, y < Self.modelHeight else { continue }
            for dx in -radius...radius {
                let x = cx + dx
                guard x >= 0, x < Self.modelWidth else { continue }
                neighborhood.append(pointer[y * rowStride + x])
            }
        }
        guard !neighborhood.isEmpty else { return nil }

        neighborhood.sort()
        let index = min(Int(Float(neighborhood.count) * 0.8), neighborhood.count - 1)
        return neighborhood[index]
    }

    // MARK: 텐서

    /// device-alloc 텐서는 strides가 반드시 nil이어야 한다.
    /// 셰이더가 읽어야 하므로 MTLBuffer 기반으로 만든다.
    private static func makeTensor(device: MTLDevice, dims: [Int], rowStride: Int,
                                   storageMode: MTLStorageMode = .private)
        throws -> (MTLBuffer, MTLTensor) {
        let descriptor = MTLTensorDescriptor()
        descriptor.dataType = .float32
        descriptor.usage = [.machineLearning, .compute]
        descriptor.storageMode = storageMode
        descriptor.dimensions = extents(dims)

        // machineLearning usage면 strides[1]이 64바이트 정렬이어야 한다.
        var strides = [1, rowStride]
        for i in 2..<dims.count { strides.append(strides[i - 1] * dims[i - 1]) }
        descriptor.strides = extents(strides)

        let sizeAndAlign = device.tensorSizeAndAlign(descriptor: descriptor)
        let options: MTLResourceOptions = storageMode == .shared ? .storageModeShared : .storageModePrivate
        guard let buffer = device.makeBuffer(length: sizeAndAlign.size, options: options),
              let tensor = try? buffer.makeTensor(descriptor: descriptor, offset: 0) else {
            throw DepthPipelineError.resourceAllocationFailed
        }
        return (buffer, tensor)
    }

    private static func extents(_ values: [Int]) -> MTLTensorExtents {
        values.withUnsafeBufferPointer { MTLTensorExtents(__rank: values.count, values: $0.baseAddress)! }
    }
}
