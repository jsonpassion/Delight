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
import CoreGraphics
import ImageIO
import QuartzCore

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
    private let heightFieldPSO: any MTLComputePipelineState
    private let ambientOcclusionPSO: any MTLComputePipelineState
    private let relightPSO: any MTLComputePipelineState
    private let stabilizePSO: any MTLComputePipelineState
    private let mlPSO: any MTL4MachineLearningPipelineState
    private let intermediatesHeap: MTLHeap

    private let inputBuffer: MTLBuffer
    private let inputTensor: MTLTensor
    private let depthBuffer: MTLBuffer
    /// 안정화 결과 핑퐁. 이번 프레임 출력이 다음 프레임의 히스토리가 된다.
    private var stabilizedBuffers: [MTLBuffer] = []
    private var colorHistoryTextures: [MTLTexture] = []
    private var historyIndex = 0
    private var hasHistory = false
    private let outputTensor: MTLTensor
    private let uniformBuffer: MTLBuffer

    /// 결과 텍스처 링. 렌더러가 읽는 동안 GPU가 다른 것에 쓴다.
    private var relitTextures: [MTLTexture] = []
    private var writeIndex = 0

    /// 높이장(R = 높이, G = 피사체 마스크)과 노멀.
    /// 뷰공간 위치 텍스처가 사라졌다 — 높이장은 이 둘만 있으면 조명이 성립한다.
    private let heightTexture: MTLTexture
    private let normalTexture: MTLTexture
    /// 세그멘테이션이 없을 때 바인딩할 더미.
    /// ⚠️ 예전에는 heightTexture를 폴백으로 썼는데, 그러면 같은 커널이 그 텍스처를
    /// 읽으면서 동시에 쓰게 되어 정의되지 않은 동작이 된다(화면에 타일 크기 블록이 나타났다).
    private let dummyTexture: MTLTexture
    /// AO는 높이장 해상도에서 미리 계산한다. 저주파 신호라 올려도 티가 안 난다.
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
        self.heightFieldPSO = try computePipeline("build_height_field")
        self.ambientOcclusionPSO = try computePipeline("compute_ao_field")
        self.relightPSO     = try computePipeline("relight")
        self.stabilizePSO = try computePipeline("stabilize_depth")

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
        // .shared — 진단용 PNG 덤프에 CPU 읽기가 필요하다.
        // 통합 메모리라 비용이 거의 없다(깊이 텐서에서 이미 검증).
        textureDescriptor.storageMode = .shared
        for _ in 0..<3 {
            guard let relitTexture = device.makeTexture(descriptor: textureDescriptor) else {
                throw DepthPipelineError.resourceAllocationFailed
            }
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
        // 안정화 핑퐁 — 깊이 버퍼와 같은 레이아웃(행 패딩 포함)이어야 한다.
        let stabilizedLength = outBuffer.length
        for _ in 0..<2 {
            guard let buffer = device.makeBuffer(length: stabilizedLength, options: .storageModeShared) else {
                throw DepthPipelineError.resourceAllocationFailed
            }
            stabilizedBuffers.append(buffer)
        }
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: Self.modelWidth, height: Self.modelHeight, mipmapped: false)
        colorDescriptor.usage = [.shaderRead, .shaderWrite]
        colorDescriptor.storageMode = .private
        for _ in 0..<2 {
            guard let texture = device.makeTexture(descriptor: colorDescriptor) else {
                throw DepthPipelineError.resourceAllocationFailed
            }
            colorHistoryTextures.append(texture)
        }

        self.heightTexture = try makeGBuffer(.rg16Float)
        self.normalTexture = try makeGBuffer(.rgba16Float)
        self.dummyTexture  = try makeGBuffer(.r8Unorm)
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
        for texture in relitTextures { staticResidency.addAllocation(texture) }
        staticResidency.addAllocation(heightTexture)
        staticResidency.addAllocation(normalTexture)
        staticResidency.addAllocation(dummyTexture)
        staticResidency.addAllocation(ambientOcclusionTexture)
        for buffer in stabilizedBuffers { staticResidency.addAllocation(buffer) }
        for texture in colorHistoryTextures { staticResidency.addAllocation(texture) }
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
    /// - Returns: 재조명 결과 텍스처.
    func process(source: MTLTexture,
                 lighting: SunUniforms? = nil,
                 segmentation: MTLTexture? = nil) -> MTLTexture? {
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

            // ── 높이장 재투영 스케일 ──
            // 화면 uv 1단위와 높이 1단위가 실제로 몇 미터인지를 맞춘다.
            // 이게 틀리면 광선 기울기가 물리적으로 어긋나 그림자가 엉뚱하게 길거나 짧아진다.
            let nearZ = 1 / max(merged.affineA + merged.affineB, 1e-3)   // 역깊이 1 → 가장 가까움
            let farZ  = 1 / max(merged.affineB, 1e-3)                     // 역깊이 0 → 가장 멂
            let depthSpan = max(farZ - nearZ, 1e-3)

            // 피사체 거리에서 화면 전체 폭이 덮는 실제 거리.
            let sceneWidth = merged.subjectDepth * Float(uniforms.outputWidth) / max(merged.fx, 1e-3)

            // 높이는 [0,1]로 정규화하고, 실제 종횡비는 heightToUV가 들고 있는다.
            merged.heightScale = 1 / depthSpan
            merged.farDistance = farZ
            merged.heightToUV = depthSpan / max(sceneWidth, 1e-3)
            merged.shadowReach = 0.35
            // --debug N 으로 중간 결과를 확인한다 (1=원본 2=AO 3=높이 4=노멀).
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "--debug"), i + 1 < args.count,
               let v = UInt32(args[i + 1]) {
                merged.debugMode = v
            }

            uniforms = merged
        }
        uniforms.hasSegmentation = segmentation != nil ? 1 : 0
        uniforms.historyValid = hasHistory ? 1 : 0

        // 배경 기준 affine 정합. 사람이 움직여도 스케일이 고정된다.
        // 배경 통계는 천천히 변한다. 매 프레임 800샘플을 정렬할 이유가 없다.
        // 5프레임마다 갱신해 프레임당 CPU를 1.3ms → 0.3ms로 줄인다.
        let affineStart = CACurrentMediaTime()
        frameCounter &+= 1
        if frameCounter % 5 == 0, let fitted = fitAffineFromBackground() {
            cachedAffine = fitted
        }
        if let cached = cachedAffine {
            uniforms.affineA = cached.a
            uniforms.affineB = cached.b
        }
        timing.affine = (CACurrentMediaTime() - affineStart) * 1000

        let encodeStart = CACurrentMediaTime()
        uniformBuffer.contents().copyMemory(
            from: &uniforms, byteCount: MemoryLayout<SunUniforms>.stride)

        let relitTarget = relitTextures[writeIndex]
        writeIndex = (writeIndex + 1) % relitTextures.count

        // 카메라 텍스처는 CVMetalTextureCache가 돌려쓰므로 매 프레임 레지던시를 갱신한다.
        frameResidency.removeAllAllocations()
        frameResidency.addAllocation(source)
        if let segmentation { frameResidency.addAllocation(segmentation) }
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

        // [C1] 안정화 — edge-stopping 시간필터로 플리커를 죽인다.
        let writeBuffer = stabilizedBuffers[historyIndex]
        let readBuffer = stabilizedBuffers[1 - historyIndex]
        let colorWrite = colorHistoryTextures[historyIndex]
        let colorRead = colorHistoryTextures[1 - historyIndex]
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            argumentTable.setAddress(depthBuffer.gpuAddress, index: 0)
            argumentTable.setAddress(readBuffer.gpuAddress, index: 1)
            argumentTable.setAddress(writeBuffer.gpuAddress, index: 2)
            argumentTable.setAddress(uniformBuffer.gpuAddress, index: 3)
            argumentTable.setTexture(source.gpuResourceID, index: 0)
            argumentTable.setTexture(colorRead.gpuResourceID, index: 1)
            argumentTable.setTexture(colorWrite.gpuResourceID, index: 2)
            encoder.setArgumentTable(argumentTable)
            encoder.setComputePipelineState(stabilizePSO)
            encoder.dispatchThreads(
                threadsPerGrid: MTLSize(width: Self.modelWidth, height: Self.modelHeight, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.barrier(afterStages: .dispatch, beforeQueueStages: .dispatch,
                            visibilityOptions: .device)
            encoder.endEncoding()
        }

        // [C3] 높이장 재투영 — 깊이 → 높이 + 노멀 + 마스크
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            argumentTable.setAddress(stabilizedBuffers[historyIndex].gpuAddress, index: 0)
            argumentTable.setAddress(uniformBuffer.gpuAddress, index: 1)
            argumentTable.setTexture(source.gpuResourceID, index: 0)
            argumentTable.setTexture((segmentation ?? dummyTexture).gpuResourceID, index: 1)
            argumentTable.setTexture(heightTexture.gpuResourceID, index: 2)
            argumentTable.setTexture(normalTexture.gpuResourceID, index: 3)
            encoder.setArgumentTable(argumentTable)
            encoder.setComputePipelineState(heightFieldPSO)
            encoder.dispatchThreads(
                threadsPerGrid: MTLSize(width: Self.modelWidth, height: Self.modelHeight, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.barrier(afterStages: .dispatch, beforeQueueStages: .dispatch,
                            visibilityOptions: .device)
            encoder.endEncoding()
        }

        // [C4] 앰비언트 오클루전 — 높이장 해상도(518×392)에서 계산한다.
        // 출력 해상도로 올리면 픽셀 수가 6배가 되어 방향×스텝이 그대로 곱해진다.
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            argumentTable.setAddress(uniformBuffer.gpuAddress, index: 0)
            argumentTable.setTexture(heightTexture.gpuResourceID, index: 0)
            argumentTable.setTexture(ambientOcclusionTexture.gpuResourceID, index: 1)
            encoder.setArgumentTable(argumentTable)
            encoder.setComputePipelineState(ambientOcclusionPSO)
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
            argumentTable.setTexture(heightTexture.gpuResourceID, index: 1)
            argumentTable.setTexture(normalTexture.gpuResourceID, index: 2)
            argumentTable.setTexture(ambientOcclusionTexture.gpuResourceID, index: 3)
            argumentTable.setTexture(relitTarget.gpuResourceID, index: 4)
            encoder.setArgumentTable(argumentTable)
            encoder.setComputePipelineState(relightPSO)
            encoder.dispatchThreads(
                threadsPerGrid: MTLSize(width: relitTarget.width, height: relitTarget.height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
        }

        commandBuffer.endCommandBuffer()
        timing.encode = (CACurrentMediaTime() - encodeStart) * 1000

        let gpuStart = CACurrentMediaTime()
        queue.commit([commandBuffer])
        signalValue += 1
        queue.signalEvent(event, value: signalValue)
        guard event.wait(untilSignaledValue: signalValue, timeoutMS: 2000) else { return nil }
        timing.gpuWait = (CACurrentMediaTime() - gpuStart) * 1000

        // 플리커 측정은 순수 진단이다. 평상시에는 돌리지 않는다.
        let flickerStart = CACurrentMediaTime()
        if Self.measuresFlicker {
            measureFlicker(buffer: stabilizedBuffers[historyIndex])
        }
        timing.flicker = (CACurrentMediaTime() - flickerStart) * 1000

        // 이번 프레임 출력이 다음 프레임의 히스토리가 된다.
        historyIndex = 1 - historyIndex
        hasHistory = true

        return relitTarget
    }

    /// 최신 재조명 결과를 PNG로 저장한다. 화질 확인용 진단 경로.
    func dumpRelit(to path: String) -> Bool {
        let index = (writeIndex + relitTextures.count - 1) % relitTextures.count
        let texture = relitTextures[index]
        guard texture.storageMode == .shared else { return false }

        let width = texture.width, height = texture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
        else { return false }

        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    // MARK: 안정성 측정

    /// 직전 프레임의 안정화 깊이 스냅샷(서브샘플). 플리커 측정용.
    private var flickerProbe: [Float] = []
    /// 연속 프레임 간 깊이 변화의 중앙값. 낮을수록 안정적이다.
    private(set) var flickerMetric: Float = 0

    /// 구간별 소요 시간(ms). 전체 시간만 재면 어디가 변동하는지 알 수 없다.
    struct StageTiming {
        var encode = 0.0      // 커맨드 인코딩 (CPU)
        var gpuWait = 0.0     // GPU 완료 대기
        var affine = 0.0      // 배경 앵커 정합 (CPU, .shared 버퍼 읽기)
        var flicker = 0.0     // 플리커 측정 (CPU, .shared 버퍼 읽기)
    }
    private(set) var timing = StageTiming()

    /// 플리커 측정은 --autostart 진단 모드에서만. 프레임당 1.2ms를 쓴다.
    static let measuresFlicker = ProcessInfo.processInfo.arguments.contains("--autostart")

    private var frameCounter: UInt64 = 0
    private var cachedAffine: (a: Float, b: Float)?

    /// 안정화가 실제로 효과가 있는지 수치로 본다.
    /// 눈으로는 "덜 떨리는 것 같다"밖에 말할 수 없다.
    private func measureFlicker(buffer: MTLBuffer) {
        guard buffer.storageMode == .shared else { return }
        let pointer = buffer.contents().bindMemory(
            to: Float.self, capacity: buffer.length / MemoryLayout<Float>.size)

        var current: [Float] = []
        current.reserveCapacity(900)
        var y = 0
        while y < Self.modelHeight {
            var x = 0
            while x < Self.modelWidth {
                current.append(pointer[y * rowStride + x])
                x += 16
            }
            y += 16
        }

        if flickerProbe.count == current.count {
            var deltas = zip(current, flickerProbe).map { abs($0 - $1) }
            deltas.sort()
            let median = deltas[deltas.count / 2]
            // EMA로 부드럽게 — 단일 프레임 값은 노이즈가 크다.
            flickerMetric = flickerMetric == 0 ? median : flickerMetric * 0.9 + median * 0.1
        }
        flickerProbe = current
    }

    // MARK: affine 정합

    /// 기준 프레임의 배경 통계. 아주 느리게 갱신해 앵커 역할을 한다.
    private var referenceMedian: Float = 0
    private var referenceScale: Float = 0

    /// 배경만으로 robust affine fit.
    ///
    /// 상대 역깊이라 프레임마다 스케일과 오프셋이 흔들린다.
    /// 3D에 고정한 광원 기준으로 보면 씬 전체가 앞뒤로 펌핑한다.
    /// **사람은 움직여도 배경은 안 움직이므로**, 배경 픽셀만으로 기준에 맞추면
    /// 스케일이 고정된다. 중앙값·MAD 기반이라 RANSAC이 필요 없다.
    ///
    /// 배경 판정은 깊이 자체로 한다 — 상대 역깊이에서 작은 값이 먼 것이다.
    /// (세그멘테이션 매트는 GPU 텍스처라 여기서 읽을 수 없다)
    private func fitAffineFromBackground() -> (a: Float, b: Float)? {
        guard depthBuffer.storageMode == .shared else { return nil }
        let pointer = depthBuffer.contents().bindMemory(
            to: Float.self, capacity: depthBuffer.length / MemoryLayout<Float>.size)

        // 16픽셀 간격 서브샘플이면 약 800개 — 통계에 충분하고 비용은 무시할 만하다.
        var samples: [Float] = []
        samples.reserveCapacity(900)
        var y = 0
        while y < Self.modelHeight {
            var x = 0
            while x < Self.modelWidth {
                samples.append(pointer[y * rowStride + x])
                x += 16
            }
            y += 16
        }
        guard samples.count > 64 else { return nil }

        samples.sort()
        // 하위 45%를 배경으로 본다. 웹캠 상반신이면 사람이 화면의 절반을 넘지 않는다.
        let backgroundCount = max(samples.count * 45 / 100, 16)
        let background = Array(samples[0..<backgroundCount])

        let median = background[background.count / 2]
        var deviations = background.map { abs($0 - median) }
        deviations.sort()
        let scale = max(deviations[deviations.count / 2], 1e-4)

        if referenceScale <= 0 {
            referenceMedian = median
            referenceScale = scale
            return nil            // 첫 프레임은 기준만 세우고 보정하지 않는다
        }

        // current → reference 로 맞추는 선형 변환.
        let a = referenceScale / scale
        let b = referenceMedian - a * median

        // 기준은 아주 느리게 따라간다. 빠르면 앵커 역할을 못 하고 같이 흘러간다.
        let rate: Float = 0.02
        referenceMedian += (median - referenceMedian) * rate
        referenceScale += (scale - referenceScale) * rate

        // 정합 계수를 미터 변환 계수와 합성한다.
        //   d' = a·d + b  를 거친 뒤  z = 1/(A·d' + B)  이므로
        //   z = 1/(A·a·d + A·b + B)
        let baseA = SunUniforms().affineA
        let baseB = SunUniforms().affineB
        let combinedA = baseA * a
        let combinedB = baseA * b + baseB

        // 폭주 방지 — 정합이 튀면 조명이 순간이동한다.
        guard combinedA.isFinite, combinedB.isFinite,
              combinedA > baseA * 0.5, combinedA < baseA * 2.0 else { return nil }
        return (combinedA, combinedB)
    }

    // MARK: 깊이 샘플링

    /// 정규화 좌표(좌상단 원점)에서 역깊이를 읽는다. 클수록 카메라에 가깝다.
    ///
    /// 손끝은 얇아서 최근접 한 점을 그냥 읽으면 깊이가 배경으로 샌다.
    /// 그래서 이웃에서 **가장 가까운 쪽 분위수**를 쓴다 — 평균이나 중앙값이면
    /// 배경 픽셀이 섞여 광원이 뒤로 밀린다. (docs/01-architecture.md §8)
    func sampleInverseDepth(atNormalized point: SIMD2<Float>, radius: Int = 2)
        -> (depth: Float, reliable: Bool)? {
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
        let depth = neighborhood[index]

        // 이웃 깊이의 퍼짐이 크면 여기는 **가림 경계**다.
        // 손과 그 뒤 물체가 한 창에 같이 잡혀 있다는 뜻이라, 어느 쪽을 골라도 틀릴 수 있다.
        // 이럴 때는 추측하지 않고 신뢰 없음으로 표시한다.
        let spread = neighborhood[neighborhood.count - 1] - neighborhood[0]
        return (depth, spread < 0.12)
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
