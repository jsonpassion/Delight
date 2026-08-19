//
//  CameraCapture.swift
//  AVFoundation → CVPixelBuffer → MTLTexture (zero-copy, CVMetalTextureCache)
//

import AVFoundation
import CoreVideo
import Metal
import CoreMedia

struct CameraFrame {
    let texture: MTLTexture
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime

    /// CVMetalTexture를 잡고 있어야 texture가 유효하다.
    /// 놓치면 캐시가 텍스처를 재활용해 화면이 찢어진다.
    let retainedTexture: CVMetalTexture
}

enum CaptureError: LocalizedError {
    case noDevice
    case cannotAddInput
    case cannotAddOutput
    case textureCacheFailed
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .noDevice:            return "사용 가능한 카메라를 찾지 못했습니다."
        case .cannotAddInput:      return "카메라 입력을 세션에 추가하지 못했습니다."
        case .cannotAddOutput:     return "비디오 출력을 세션에 추가하지 못했습니다."
        case .textureCacheFailed:  return "Metal 텍스처 캐시를 만들지 못했습니다."
        case .permissionDenied:
            return "카메라 접근이 거부되었습니다. 시스템 설정 → 개인정보 보호 및 보안 → 카메라에서 Delight를 허용한 뒤 다시 시도하세요."
        }
    }
}

final class CameraCapture: NSObject {

    /// 프레임 콜백. 캡처 큐에서 호출된다 — 메인 액터가 아니다.
    var onFrame: (@Sendable (CameraFrame) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "sunshine.capture", qos: .userInteractive)
    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache?

    init(device: MTLDevice, preferred: AVCaptureDevice? = nil) throws {
        self.device = device
        super.init()

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw CaptureError.textureCacheFailed }
        self.textureCache = cache

        guard let camera = preferred ?? Self.defaultCamera() else { throw CaptureError.noDevice }

        session.beginConfiguration()
        session.sessionPreset = .high

        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw CaptureError.cannotAddInput }
        session.addInput(input)

        // BGRA로 받는다. 420v가 대역폭은 절반이지만 P1에서는 단순함이 우선.
        // 최적화 시 kCVPixelFormatType_420YpCbCr8BiPlanarFullRange + 셰이더 변환으로 바꾼다.
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CaptureError.cannotAddOutput }
        session.addOutput(output)

        session.commitConfiguration()
    }

    /// 내장 → 외부 → Continuity 순으로 고른다.
    /// Continuity(iPhone)는 1920×1440@60을 주므로 인터랙션 체감에 유리하다.
    static func availableCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    static func defaultCamera() -> AVCaptureDevice? {
        availableCameras().first
    }

    /// 권한을 먼저 확보한 뒤 세션을 시작한다.
    /// .notDetermined 상태에서 startRunning을 하면 프롬프트가 떠도
    /// 이미 시작된 세션에는 프레임이 오지 않는다 — 순서가 중요하다.
    func start() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                throw CaptureError.permissionDenied
            }
        default:
            throw CaptureError.permissionDenied
        }
        queue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }
}

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let cache = textureCache else { return }

        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
        guard result == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        onFrame?(CameraFrame(texture: texture,
                             pixelBuffer: pixelBuffer,
                             presentationTime: pts,
                             retainedTexture: cvTexture))
    }
}
