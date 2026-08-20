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

    /// 캡처가 스스로 멈췄을 때(장치 분리, 런타임 에러) 불린다. 캡처 큐에서 호출된다.
    ///
    /// 왜 필요한가: 캡처 중 카메라가 사라지면(iPhone Continuity 분리 등)
    /// CoreMediaIO의 확장 무효화 콜백이 죽은 장치를 계속 두드리다 프레임워크 내부에서
    /// 세그폴트를 낸다(크래시 리포트: CMIODALExtensionDevice deviceHasBeenInvalidated).
    /// 우리 코드 프레임이 아니라 100% 막을 수는 없지만, 분리를 감지하는 즉시
    /// 세션을 내려 죽은 장치를 참조하는 시간을 최소화한다.
    var onInterruption: (@Sendable (String) -> Void)?

    private var observers: [NSObjectProtocol] = []
    private let activeDevice: AVCaptureDevice

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "sunshine.capture", qos: .userInteractive)
    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache?

    init(device: MTLDevice, preferred: AVCaptureDevice? = nil) throws {
        self.device = device
        guard let camera = preferred ?? Self.defaultCamera() else { throw CaptureError.noDevice }
        self.activeDevice = camera
        super.init()

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw CaptureError.textureCacheFailed }
        self.textureCache = cache

        session.beginConfiguration()
        session.sessionPreset = .high

        // 포맷을 명시적으로 고른다. preset에 맡기면 시스템이 30fps 저해상도를 줄 수 있다.
        // 우선순위: 높은 프레임레이트 → 큰 해상도.
        // 60fps 소스는 손 인터랙션 체감에 직결된다(iPhone Continuity는 1920×1440@60을 준다).
        if let best = Self.preferredFormat(for: camera),
           (try? camera.lockForConfiguration()) != nil {
            camera.activeFormat = best.format
            let duration = CMTime(value: 1, timescale: CMTimeScale(best.frameRate))
            camera.activeVideoMinFrameDuration = duration
            camera.activeVideoMaxFrameDuration = duration
            camera.unlockForConfiguration()
        }

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

        // 장치 분리·런타임 에러 감시. 알림은 임의 스레드로 오므로 캡처 큐로 넘긴다.
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let self,
                  let device = notification.object as? AVCaptureDevice,
                  device.uniqueID == self.activeDevice.uniqueID else { return }
            self.queue.async {
                if self.session.isRunning { self.session.stopRunning() }
                self.onInterruption?("카메라가 분리되었습니다: \(device.localizedName)")
            }
        })
        observers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self.queue.async {
                if self.session.isRunning { self.session.stopRunning() }
                self.onInterruption?("캡처 런타임 에러: \(error?.localizedDescription ?? "알 수 없음")")
            }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
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

    /// 프레임레이트를 해상도보다 우선한다. 조명이 손을 늦게 따라오는 것이
    /// 화소가 조금 부족한 것보다 훨씬 크게 느껴진다.
    static func preferredFormat(for device: AVCaptureDevice)
        -> (format: AVCaptureDevice.Format, frameRate: Double)? {
        var best: (AVCaptureDevice.Format, Double, Int)?
        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let pixels = Int(dimensions.width) * Int(dimensions.height)
            guard let maxRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max()
            else { continue }
            // 240fps 같은 극단 포맷은 해상도가 너무 낮다. 60까지만 본다.
            let rate = min(maxRate, 60)
            guard pixels >= 640 * 480 else { continue }
            if let current = best {
                if rate > current.1 || (rate == current.1 && pixels > current.2) {
                    best = (format, rate, pixels)
                }
            } else {
                best = (format, rate, pixels)
            }
        }
        guard let best else { return nil }
        return (best.0, best.1)
    }

    /// 현재 활성 포맷의 해상도. 파이프라인 출력 해상도를 여기 맞춘다.
    var activeDimensions: CMVideoDimensions {
        CMVideoFormatDescriptionGetDimensions(activeDevice.activeFormat.formatDescription)
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
