// probe_p1.swift — P1 GPU 체인 검증: 전처리 → ML 추론 → 컬러맵, 전부 하나의 커맨드 버퍼.
// 합성 입력을 넣고 PNG로 떨어뜨려 눈으로 확인한다.
//
// 빌드:
//   xcrun -sdk macosx metal -c Delight/Delight/Shaders/{Preprocess,Visualize}.metal -o ...
//   xcrun -sdk macosx metallib ... -o /tmp/delight.metallib
//   xcrun swiftc -O -o /tmp/probe_p1 Tools/probe_p1.swift
// 실행:
//   /tmp/probe_p1 /tmp/delight.metallib Models/DepthAnythingV2Small.mtlpackage /tmp/p1.png [입력.png]

import Foundation
import QuartzCore
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreML
import CoreVideo

setvbuf(stdout, nil, _IONBF, 0)

let args = CommandLine.arguments
guard args.count >= 4 else { fatalError("usage: probe_p1 <metallib> <mtlpackage> <out.png> [in.png]") }
let metallibPath = args[1], packagePath = args[2], outPath = args[3]
let inputPath: String? = args.count > 4 ? args[4] : nil

let DW = 518, DH = 392                      // 모델 고정 입력
let OW = 518, OH = 392                      // 시각화 출력

let device = MTLCreateSystemDefaultDevice()!
print("device:", device.name)

func extents(_ v: [Int]) -> MTLTensorExtents {
    v.withUnsafeBufferPointer { MTLTensorExtents(__rank: v.count, values: $0.baseAddress)! }
}

// 검증된 제약: machineLearning usage면 strides[1]이 64바이트 정렬이어야 한다.
let elementBytes = 4
let rowStride = ((DW * elementBytes + 63) / 64) * 64 / elementBytes
print("rowStride: \(rowStride) elem (width \(DW) → \(rowStride - DW) elem 패딩)")

// ---------- 셰이더 유니폼 (ShaderTypes.h와 레이아웃이 일치해야 한다) ----------
struct SunLight { var position = SIMD3<Float>(); var color = SIMD3<Float>(); var intensity: Float = 0; var radius: Float = 0 }
struct SunUniforms {
    var fx: Float = 0, fy: Float = 0, cx: Float = 0, cy: Float = 0
    var affineA: Float = 1, affineB: Float = 0
    var depthWidth: UInt32 = 0, depthHeight: UInt32 = 0, depthRowStride: UInt32 = 0
    var outputWidth: UInt32 = 0, outputHeight: UInt32 = 0
    var raymarchSteps: UInt32 = 24
    var personThickness: Float = 0.12, backgroundThickness: Float = 0.05, shadowBias: Float = 0.002
    var skinRoughness: Float = 0.5, detailStrength: Float = 0.4
    var wrapDiffuse: Float = 0.35, rimPower: Float = 3.0
    var translucency: Float = 0.6, subjectDepth: Float = 0.6
    var enableAO: UInt32 = 1, enableSpecular: UInt32 = 1
    var lightCount: UInt32 = 0
    var lights: (SunLight, SunLight, SunLight, SunLight) = (SunLight(), SunLight(), SunLight(), SunLight())
}

var uniforms = SunUniforms()
uniforms.depthWidth = UInt32(DW); uniforms.depthHeight = UInt32(DH)
uniforms.depthRowStride = UInt32(rowStride)
uniforms.outputWidth = UInt32(OW); uniforms.outputHeight = UInt32(OH)
uniforms.fx = 500; uniforms.fy = 500; uniforms.cx = Float(OW)/2; uniforms.cy = Float(OH)/2

// ---------- 입력 텍스처 ----------
let srcDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: DW, height: DH, mipmapped: false)
srcDesc.usage = [.shaderRead, .shaderWrite]
srcDesc.storageMode = .shared
let sourceTexture = device.makeTexture(descriptor: srcDesc)!

var pixels = [UInt8](repeating: 0, count: DW * DH * 4)
if let inputPath, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: inputPath) as CFURL, nil),
   let image = CGImageSourceCreateImageAtIndex(src, 0, nil) {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: &pixels, width: DW, height: DH, bitsPerComponent: 8, bytesPerRow: DW * 4,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: DW, height: DH))
    print("입력: \(inputPath)")
} else {
    // 합성 장면: 배경 그라디언트 + 가운데 밝은 타원(머리 대용) + 코 융기
    for y in 0..<DH {
        for x in 0..<DW {
            let i = (y * DW + x) * 4
            let nx = (Float(x) - Float(DW) * 0.5) / (Float(DW) * 0.22)
            let ny = (Float(y) - Float(DH) * 0.55) / (Float(DH) * 0.40)
            let r2 = nx * nx + ny * ny
            var v: Float = 0.25 + 0.35 * Float(y) / Float(DH)
            if r2 < 1 { v = 0.78 - 0.18 * r2 }
            let c = UInt8(max(0, min(255, v * 255)))
            pixels[i] = c; pixels[i+1] = UInt8(Float(c) * 0.92); pixels[i+2] = UInt8(Float(c) * 0.85); pixels[i+3] = 255
        }
    }
    print("입력: 합성 장면")
}
sourceTexture.replace(region: MTLRegionMake2D(0, 0, DW, DH), mipmapLevel: 0, withBytes: pixels, bytesPerRow: DW * 4)

// ---------- 출력 텍스처 ----------
let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: OW, height: OH, mipmapped: false)
outDesc.usage = [.shaderRead, .shaderWrite]
outDesc.storageMode = .shared
let outputTexture = device.makeTexture(descriptor: outDesc)!

// ---------- 텐서 ----------
func makeTensor(_ dims: [Int]) throws -> (MTLBuffer, MTLTensor) {
    let d = MTLTensorDescriptor()
    d.dataType = .float32
    d.usage = [.machineLearning, .compute]
    d.storageMode = .shared          // 검증용으로 CPU 읽기 허용 (앱에서는 .private)
    d.dimensions = extents(dims)
    var strides = [1, rowStride]
    for i in 2..<dims.count { strides.append(strides[i-1] * dims[i-1]) }
    d.strides = extents(strides)
    let sa = device.tensorSizeAndAlign(descriptor: d)
    let buf = device.makeBuffer(length: sa.size, options: .storageModeShared)!
    return (buf, try buf.makeTensor(descriptor: d, offset: 0))
}
let (inputBuffer, inputTensor)   = try makeTensor([DW, DH, 3, 1])
let (depthBuffer, outputTensor)  = try makeTensor([DW, DH, 1, 1])
let uniformBuffer = device.makeBuffer(bytes: &uniforms, length: MemoryLayout<SunUniforms>.stride, options: .storageModeShared)!

// ---------- 파이프라인 ----------
let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
let shaderLib = try device.makeLibrary(URL: URL(fileURLWithPath: metallibPath))

func computePipeline(_ name: String) throws -> any MTLComputePipelineState {
    let fn = MTL4LibraryFunctionDescriptor(); fn.name = name; fn.library = shaderLib
    let d = MTL4ComputePipelineDescriptor(); d.computeFunctionDescriptor = fn
    return try compiler.makeComputePipelineState(descriptor: d)
}
let preprocessPSO = try computePipeline("preprocess_to_tensor")
let visualizePSO  = try computePipeline("visualize_depth")

let mlLib = try device.makeLibrary(URL: URL(fileURLWithPath: packagePath))
let mlFn = MTL4LibraryFunctionDescriptor(); mlFn.name = mlLib.functionNames.first ?? "main"; mlFn.library = mlLib
let mlDesc = MTL4MachineLearningPipelineDescriptor()
mlDesc.machineLearningFunctionDescriptor = mlFn
mlDesc.setInputDimensions(extents([DW, DH, 3, 1]), bufferIndex: 0)
let mlPSO = try compiler.makeMachineLearningPipelineState(descriptor: mlDesc)

let heapDesc = MTLHeapDescriptor()
heapDesc.size = max(mlPSO.intermediatesHeapSize, 4096)
heapDesc.storageMode = .private
heapDesc.type = .placement
let heap = device.makeHeap(descriptor: heapDesc)!

// ---------- 인자 테이블 ----------
let atDesc = MTL4ArgumentTableDescriptor()
atDesc.maxBufferBindCount = 8
atDesc.maxTextureBindCount = 4
let argTable = try device.makeArgumentTable(descriptor: atDesc)

// ---------- 레지던시 (Metal 4는 자동 레지던시가 없다) ----------
let residency = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
for r in [inputBuffer, depthBuffer, uniformBuffer] { residency.addAllocation(r) }
residency.addAllocation(heap)
residency.addAllocation(sourceTexture)
residency.addAllocation(outputTexture)
residency.commit(); residency.requestResidency()

let qDesc = MTL4CommandQueueDescriptor()
qDesc.feedbackQueue = DispatchQueue(label: "probe.feedback")
let queue = try device.makeMTL4CommandQueue(descriptor: qDesc)
queue.addResidencySet(residency)
let allocator = device.makeCommandAllocator()!
let commandBuffer = device.makeCommandBuffer()!
let event = device.makeSharedEvent()!
var signalValue: UInt64 = 0

func runFrame() {
    allocator.reset()
    commandBuffer.beginCommandBuffer(allocator: allocator)

    // [C0] 전처리 — 카메라 텍스처 → 모델 입력 텐서
    if let enc = commandBuffer.makeComputeCommandEncoder() {
        argTable.setTexture(sourceTexture.gpuResourceID, index: 0)
        argTable.setAddress(inputBuffer.gpuAddress, index: 0)
        argTable.setAddress(uniformBuffer.gpuAddress, index: 1)
        enc.setArgumentTable(argTable)
        enc.setComputePipelineState(preprocessPSO)
        enc.dispatchThreads(threadsPerGrid: MTLSize(width: DW, height: DH, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.barrier(afterStages: .dispatch, beforeQueueStages: .machineLearning, visibilityOptions: .device)
        enc.endEncoding()
    }

    // [ML] 추론 — 같은 커맨드 버퍼, CPU 왕복 없음
    if let enc = commandBuffer.makeMachineLearningCommandEncoder() {
        argTable.setResource(inputTensor.gpuResourceID, bufferIndex: 0)
        argTable.setResource(outputTensor.gpuResourceID, bufferIndex: 1)
        enc.setArgumentTable(argTable)
        enc.setPipelineState(mlPSO)
        enc.dispatchNetwork(intermediatesHeap: heap)
        enc.barrier(afterStages: .machineLearning, beforeQueueStages: .dispatch, visibilityOptions: .device)
        enc.endEncoding()
    }

    // [C1] 시각화 — 추론 결과 버퍼를 그대로 읽는다
    if let enc = commandBuffer.makeComputeCommandEncoder() {
        argTable.setAddress(depthBuffer.gpuAddress, index: 0)
        argTable.setAddress(uniformBuffer.gpuAddress, index: 1)
        argTable.setTexture(outputTexture.gpuResourceID, index: 0)
        enc.setArgumentTable(argTable)
        enc.setComputePipelineState(visualizePSO)
        enc.dispatchThreads(threadsPerGrid: MTLSize(width: OW, height: OH, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
    }

    commandBuffer.endCommandBuffer()
    queue.commit([commandBuffer])
    signalValue += 1
    queue.signalEvent(event, value: signalValue)
    _ = event.wait(untilSignaledValue: signalValue, timeoutMS: 5000)
}

// 워밍업 + 계측
for _ in 0..<3 { runFrame() }
var times: [Double] = []
for _ in 0..<20 {
    let t0 = CACurrentMediaTime(); runFrame(); times.append((CACurrentMediaTime() - t0) * 1000)
}
times.sort()
print(String(format: "전체 체인(전처리+추론+시각화): median %.2f ms  = %.1f fps", times[10], 1000/times[10]))

// ---------- 검증: 깊이 출력 통계 ----------
let count = DW * DH
let ptr = depthBuffer.contents().bindMemory(to: Float.self, capacity: depthBuffer.length / 4)
var mn = Float.infinity, mx = -Float.infinity, sum = 0.0, nan = 0
for y in 0..<DH { for x in 0..<DW {
    let v = ptr[y * rowStride + x]
    if v.isNaN { nan += 1; continue }
    mn = min(mn, v); mx = max(mx, v); sum += Double(v)
}}
print(String(format: "깊이 출력: min %.4f  max %.4f  mean %.4f  NaN %d/%d", mn, mx, sum/Double(count), nan, count))
print(mx > mn ? "→ 네트워크 실행 확인 (출력에 변화 있음)" : "→ 의심: 출력이 상수")

// ---------- PNG 저장 ----------
var out = [UInt8](repeating: 0, count: OW * OH * 4)
outputTexture.getBytes(&out, bytesPerRow: OW * 4, from: MTLRegionMake2D(0, 0, OW, OH), mipmapLevel: 0)
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: &out, width: OW, height: OH, bitsPerComponent: 8, bytesPerRow: OW * 4,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("저장:", outPath)


// ---------- 교차검증: 같은 입력을 Core ML에 넣어 상관계수를 본다 ----------
// 전처리(ImageNet 정규화·행 패딩)가 틀렸다면 여기서 상관이 무너진다.
// Core ML은 정규화를 모델 안에 갖고 있으므로 서로 독립적인 경로다.
let mlmodelc = URL(fileURLWithPath: packagePath)
    .deletingLastPathComponent()
    .appendingPathComponent("DepthAnythingV2SmallF16.mlmodelc")

if FileManager.default.fileExists(atPath: mlmodelc.path) {
    let config = MLModelConfiguration()
    config.computeUnits = .all
    let model = try MLModel(contentsOf: mlmodelc, configuration: config)

    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, DW, DH, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
    let buffer = pb!
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.bindMemory(to: UInt8.self, capacity: DW * DH * 4)
    let bpr = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<DH { for x in 0..<DW {
        let s = (y * DW + x) * 4                    // 텍스처는 RGBA
        let d = y * bpr + x * 4                     // 픽셀버퍼는 BGRA
        base[d]   = pixels[s + 2]
        base[d+1] = pixels[s + 1]
        base[d+2] = pixels[s]
        base[d+3] = 255
    }}
    CVPixelBufferUnlockBaseAddress(buffer, [])

    let name = model.modelDescription.inputDescriptionsByName.keys.first!
    let input = try MLDictionaryFeatureProvider(dictionary: [name: buffer])
    let result = try model.prediction(from: input)
    let outName = model.modelDescription.outputDescriptionsByName.keys.first!

    guard let refBuffer = result.featureValue(for: outName)?.imageBufferValue else {
        print("Core ML 출력이 이미지 타입이 아님 — 교차검증 생략"); exit(0)
    }
    // 출력은 Grayscale16Half — fp32로 읽으면 쓰레기가 나온다.
    let refFormat = CVPixelBufferGetPixelFormatType(refBuffer)
    precondition(refFormat == kCVPixelFormatType_OneComponent16Half,
                 "예상과 다른 출력 포맷: \(refFormat)")
    CVPixelBufferLockBaseAddress(refBuffer, .readOnly)
    let refBase = CVPixelBufferGetBaseAddress(refBuffer)!.bindMemory(to: Float16.self, capacity: DW * DH)
    let refBPR = CVPixelBufferGetBytesPerRow(refBuffer) / 2

    // 피어슨 상관계수. 두 경로가 같은 것을 계산한다면 1에 가까워야 한다.
    var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
    let n = Double(DW * DH)
    for y in 0..<DH { for x in 0..<DW {
        let a = Double(ptr[y * rowStride + x])
        let b = Double(refBase[y * refBPR + x])
        sa += a; sb += b; saa += a*a; sbb += b*b; sab += a*b
    }}
    let cov = sab/n - (sa/n)*(sb/n)
    let sda = (saa/n - (sa/n)*(sa/n)).squareRoot()
    let sdb = (sbb/n - (sb/n)*(sb/n)).squareRoot()
    let r = cov / max(sda * sdb, 1e-12)
    CVPixelBufferUnlockBaseAddress(refBuffer, .readOnly)

    print(String(format: "교차검증 (Metal 4 ML vs Core ML): r = %.5f", r))
    print(r > 0.99 ? "→ 전처리·인덱싱 정확 (두 경로가 같은 깊이를 낸다)"
                   : "→ 불일치. 전처리 정규화 또는 행 패딩 인덱싱을 의심할 것")
} else {
    print("교차검증 생략: \(mlmodelc.lastPathComponent) 없음")
}
