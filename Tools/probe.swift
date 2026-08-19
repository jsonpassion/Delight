// probe.swift — 파이프라인 전제조건 실측 프로브
// 실행: xcrun swift relight/tools/probe.swift
import Foundation
import Metal
import AVFoundation
import Vision

func line(_ s: String) { print(s) }
func head(_ s: String) { print("\n=== \(s) ===") }

// ---------- 1. Metal / Metal 4 ----------
head("Metal")
guard let dev = MTLCreateSystemDefaultDevice() else { fatalError("no Metal device") }
line("device            : \(dev.name)")
line("unified memory    : \(dev.hasUnifiedMemory)")
line("recommended max WS: \(dev.recommendedMaxWorkingSetSize / 1024 / 1024) MB")
let families: [(String, MTLGPUFamily)] = [
    ("Apple7", .apple7), ("Apple8", .apple8), ("Apple9", .apple9),
    ("Metal3", .metal3),
]
var famStr = families.filter { dev.supportsFamily($0.1) }.map(\.0)
if let apple10 = MTLGPUFamily(rawValue: 1010), dev.supportsFamily(apple10) { famStr.append("Apple10") }
if let metal4 = MTLGPUFamily(rawValue: 5002), dev.supportsFamily(metal4) { famStr.append("Metal4") }
line("GPU families      : \(famStr.joined(separator: ", "))")

// ---------- 2. MTLTensor / ML pipeline 가용성 ----------
head("Metal 4 ML path")
if #available(macOS 26.0, *) {
    // 검증된 사실: device-alloc 텐서는 strides가 nil이어야 하고, 셰이더가 직접 읽으려면
    // MTLBuffer 기반 텐서로 만들어야 한다(.machineLearning + .compute 동시 지정 가능).
    func extents(_ v: [Int]) -> MTLTensorExtents {
        v.withUnsafeBufferPointer { MTLTensorExtents(__rank: v.count, values: $0.baseAddress)! }
    }
    let d = MTLTensorDescriptor()
    d.dataType = .float16
    d.usage = [.machineLearning, .compute]
    d.storageMode = .private
    d.dimensions = extents([448, 448, 1, 1])      // 첫 원소가 innermost(W)
    d.strides = extents([1, 448, 448 * 448, 448 * 448])
    let sa = dev.tensorSizeAndAlign(descriptor: d)
    line("tensor 448x448 f16 [ML|compute] : \(sa.size) B, align \(sa.align)")
    if let buf = dev.makeBuffer(length: sa.size, options: .storageModePrivate),
       let t = try? buf.makeTensor(descriptor: d, offset: 0) {
        line("buffer-backed tensor            : OK (셰이더가 같은 버퍼를 직접 읽음)")
        _ = t
    } else {
        line("buffer-backed tensor            : FAILED")
    }
    let q4 = dev.makeMTL4CommandQueue()
    line("MTL4CommandQueue          : \(q4 != nil ? "OK" : "nil")")
    let compiler = try? dev.makeCompiler(descriptor: MTL4CompilerDescriptor())
    line("MTL4Compiler              : \(compiler != nil ? "OK" : "nil")")
} else {
    line("macOS < 26 — Metal 4 불가")
}

// ---------- 3. 카메라 (내장 + 외부) ----------
head("Cameras")
let disc = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
    mediaType: .video, position: .unspecified)
for d in disc.devices {
    line("• \(d.localizedName)  [\(d.deviceType.rawValue)]  uniqueID=\(d.uniqueID)")
    // 30fps 이상 나오는 포맷 중 가장 큰 것 3개
    let fmts = d.formats.filter { f in
        f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 29.9 }
    }
    let ranked = fmts.sorted { a, b in
        let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
        let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
        return Int(da.width) * Int(da.height) > Int(db.width) * Int(db.height)
    }.prefix(3)
    for f in ranked {
        let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
        let subStr = String(bytes: [UInt8((sub >> 24) & 0xff), UInt8((sub >> 16) & 0xff),
                                    UInt8((sub >> 8) & 0xff), UInt8(sub & 0xff)], encoding: .ascii) ?? "?"
        let fps = f.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
        line("    \(dim.width)x\(dim.height) @\(Int(fps))  subtype=\(subStr)")
    }
}
if disc.devices.isEmpty { line("(장치 없음 — 권한 미승인 상태에서도 열거는 되어야 함)") }

// intrinsics: macOS에서는 videoFieldOfView / cameraIntrinsicMatrixDelivery 모두 API_UNAVAILABLE(macos).
// → focal length는 추정해야 함(얼굴 기반 캘리브레이션 or 사용자 슬라이더). 아래 Vision 섹션 참조.
// ---------- 4. Vision 요청 가용성 ----------
head("Vision")
if #available(macOS 15.0, *) {
    var r = DetectHumanHandPoseRequest()
    r.maximumHandCount = 2
    line("DetectHumanHandPoseRequest : OK (maxHands=\(r.maximumHandCount))")
    line("revisions                  : \(DetectHumanHandPoseRequest.supportedRevisions.map { String(describing: $0) })")
    line("GeneratePersonSegmentation : \(GeneratePersonSegmentationRequest.supportedRevisions.map { String(describing: $0) })")
    line("DetectFaceLandmarksRequest : \(DetectFaceLandmarksRequest.supportedRevisions.map { String(describing: $0) })")
} else {
    line("legacy VN API only")
}
