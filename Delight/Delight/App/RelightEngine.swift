//
//  RelightEngine.swift
//  파이프라인 오케스트레이터. 각 스테이지는 프로토콜/클래스 뒤에 있으므로
//  하나가 실패해도 나머지가 산다. (docs/01-architecture.md §10)
//
//  레이트 분리: 캡처 30/60Hz, 깊이 추론 ~30Hz(15.4ms), 렌더 60Hz.
//  추론이 밀리면 프레임을 버린다 — 조명이 손을 늦게 따라오는 것보다 낫다.
//

import Foundation
import Metal
import CoreMedia
import AVFoundation
import Observation
import QuartzCore

@Observable
@MainActor
final class RelightEngine {

    // MARK: 상태

    enum Status: Equatable {
        case idle
        case running
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var stats = FrameStats()

    /// 씬에 놓인 광원들. 다중 광원 확장을 위해 처음부터 배열이다.
    var lightRig = LightRig()

    /// 손 인식이 실패해도 데모가 죽지 않도록 하는 폴백. 항상 살려둔다.
    var inputMode: InputMode = .mouse

    enum InputMode: String, CaseIterable, Identifiable {
        case hand = "손"
        case mouse = "마우스"
        var id: String { rawValue }
    }

    /// 깊이맵을 화면에 보여줄지. P1의 눈에 보이는 성과다.
    var showDepth = true

    /// 거울상 프리뷰. 손 인터랙션은 거울이 자연스럽다. 송출에는 적용하지 않는다.
    var isMirrored = true

    /// 재조명 결과를 보여줄지. 끄면 원본 카메라가 나와 전후 비교가 된다.
    var showRelit = true

    /// 최신 핀치 상태. HUD 피드백용. **관찰 가능한 상태는 메인 액터가 소유한다.**
    private(set) var pinch = PinchState()
    private(set) var isHandVisible = false

    // MARK: 구성 요소

    let device: MTLDevice
    private(set) var capture: CameraCapture?
    private(set) var depthPipeline: DepthPipeline?
    private(set) var handTracker: HandTracker?
    private(set) var personMatte: PersonMatte?

    /// 렌더러가 읽어 가는 최신 결과.
    let frameStore = FrameStore()

    private let processingQueue = DispatchQueue(label: "delight.depth", qos: .userInitiated)
    private let inFlight = InFlightGate()
    /// 손 추적은 깊이 추론과 독립적으로 흐른다. 서로 기다리게 하면 둘 다 느려진다.
    private let handInFlight = InFlightGate()
    /// 세그멘테이션도 마찬가지. 실루엣은 천천히 변하므로 15Hz로 충분하다.
    private let matteInFlight = InFlightGate()
    /// Vision 모델 첫 로드가 끝날 때까지 스트림 투입을 막는다.
    ///
    /// 세그멘테이션과 핸드포즈가 **동시에** 첫 로드를 하면 Espresso(ANE 런타임)의
    /// 커널 등록이 레이스해 힙 손상으로 죽는 일이 간헐적으로 있었다
    /// (크래시 리포트: Espresso::ANERuntimeEngine::register_kernels → malloc EXC_BREAKPOINT).
    /// 시작 시 더미 입력으로 하나씩 순서대로 초기화한 뒤에 게이트를 연다.
    private let visionWarmedUp = InFlightGate()   // tryEnter 성공 = 아직 워밍업 안 끝남
    private let matteQueue = DispatchQueue(label: "delight.matte", qos: .userInitiated)

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal 지원 GPU를 찾을 수 없습니다.")
        }
        self.device = device

        // 앱 시작 시 자가진단 — 모델 로딩은 카메라 권한과 무관하므로 미리 검증한다.
        // 과거 사례: 템플릿 기본값 ENABLE_APP_SANDBOX=YES 가 컨테이너 밖 Models/ 읽기를 막아
        // "Invalid metal package"로 나타났다. 이 로그가 그런 실패를 시작 전에 잡는다.
        if let url = ModelLocator.mtlpackageURL() {
            do {
                _ = try device.makeLibrary(URL: url)
                NSLog("[Delight] 모델 자가진단 OK: %@", url.lastPathComponent)
            } catch {
                NSLog("[Delight] 모델 자가진단 실패: %@ — %@", url.path, String(describing: error))
            }
        } else {
            NSLog("[Delight] 모델을 찾지 못함 — Tools/fetch_models.sh 를 실행하세요")
        }
        NSLog("[Delight] 카메라 권한: %d (0=미결정 1=제한 2=거부 3=허용)",
              AVCaptureDevice.authorizationStatus(for: .video).rawValue)

        // 테스트 자동화: --autostart 로 실행하면 UI 클릭 없이 엔진을 돌리고
        // 3초마다 상태를 로그로 남긴다. CLI에서 파이프라인 전체를 검증할 때 쓴다.
        if ProcessInfo.processInfo.arguments.contains("--autostart") {
            Task { @MainActor in
                // 손 경로까지 검증한다. 마우스만으로는 Vision·깊이샘플링이 안 돌아본다.
                self.inputMode = .hand
                self.start()
                // 슬라이더 조작과 같은 경로로 depthOffset을 대입해 회귀를 잡는다.
                // (@Observable + didSet 자기대입이 무한재귀로 크래시한 전례가 있다)
                // 진단 루프는 **관측만 한다.**
                // 이전에는 여기서 3초마다 lightRig를 흔들어 A/B를 쟀는데,
                // 그 쓰기가 SwiftUI 레이아웃과 경쟁해 진단 도구 자체가 크래시를 만들었다.
                // A/B가 필요하면 --stabilize-off 로 고정해 두 번 돌린다.
                self.lightRig.temporalBlend =
                    ProcessInfo.processInfo.arguments.contains("--stabilize-off") ? 0.0 : 0.85
                for tick in 0..<10 {
                    try? await Task.sleep(for: .seconds(3))
                    let (camera, depth, relit) = self.frameStore.latest()
                    let line = String(
                        format: "안정화=%@ status=%@ 캡처 %.1ffps 깊이 %.2fms(%.1ffps) 프레임 %d cam=%@ depth=%@ relit=%@ 매트=%@ 플리커=%.5f 손=%@ 핀치=%@ d=%.2f z=%.2f",
                        self.lightRig.temporalBlend > 0 ? "ON " : "OFF",
                        String(describing: self.status), self.stats.captureFPS,
                        self.stats.depthMilliseconds, self.stats.depthFPS, self.stats.frameCount,
                        camera == nil ? "nil" : "OK",
                        depth == nil ? "nil" : "OK",
                        relit == nil ? "nil" : "OK",
                        self.personMatte?.latestTexture() == nil ? "nil" : "OK",
                        self.depthPipeline?.flickerMetric ?? 0,
                        self.isHandVisible ? "보임" : "없음",
                        self.pinch.isPinching ? "잡음" : "놓음",
                        self.pinch.normalizedDepth,
                        self.lightRig.active?.position.z ?? 0)
                    NSLog("[Delight] %@", line)
                    if tick == 4, let pipeline = self.depthPipeline {
                        let ok = pipeline.dumpRelit(to: "/tmp/delight_relit.png")
                        NSLog("[Delight] 재조명 결과 덤프: %@", ok ? "OK" : "실패")
                    }
                    // open(1)으로 실행되면 stderr를 받을 수 없으므로 파일에도 남긴다.
                    if let data = (line + "\n").data(using: .utf8),
                       let handle = FileHandle(forWritingAtPath: "/tmp/delight_status.log") {
                        handle.seekToEndOfFile(); handle.write(data); try? handle.close()
                    } else {
                        try? (line + "\n").write(toFile: "/tmp/delight_status.log",
                                                  atomically: false, encoding: .utf8)
                    }
                }
            }
        }
    }

    // MARK: 수명주기

    func start() {
        guard status != .running else { return }
        do {
            let pipeline = try DepthPipeline(
                device: device,
                outputWidth: Self.outputWidth,
                outputHeight: Self.outputHeight)
            self.depthPipeline = pipeline

            let capture = try CameraCapture(device: device)
            capture.onInterruption = { [weak self] reason in
                Task { @MainActor in
                    guard let self else { return }
                    self.status = .failed(reason + " — 다시 시작하면 사용 가능한 카메라로 연결합니다.")
                    NSLog("[Delight] 캡처 중단: %@", reason)
                    self.capture = nil      // 다음 start()가 장치를 새로 고른다
                }
            }
            let store = frameStore
            let gate = inFlight
            let handGate = handInFlight
            let matteGate = matteInFlight
            let queue = processingQueue
            let matteWork = matteQueue
            // 콜백이 값을 캡처하므로 **여기서 먼저** 만들어야 한다.
            // 나중에 만들면 콜백은 nil을 붙잡은 채로 남는다.
            let visionReady = OpenFlag()
            // --no-matte: 세그멘테이션 격리 실험용. 크래시 이등분에 쓴다.
            let matteProvider = ProcessInfo.processInfo.arguments.contains("--no-matte")
                ? nil : PersonMatte(device: device)
            self.personMatte = matteProvider
            if matteProvider == nil {
                NSLog("[Delight] 인물 세그멘테이션 초기화 실패 — 깊이 기반 근사 매트로 폴백")
            }

            capture.onFrame = { [weak self] frame in
                store.publishCamera(frame)
                Task { @MainActor in self?.stats.recordCapture(at: frame.presentationTime) }

                // 추론이 아직 돌고 있으면 이 프레임은 버린다.
                guard gate.tryEnter() else { return }

                // 인물 세그멘테이션 — 15Hz(PersonMatte가 스스로 제한한다).
                // 메인 액터를 거치지 않는다. 프레임마다 Task를 만들면 UI 트랜잭션과 경쟁한다.
                if visionReady.isOpen, let matte = matteProvider, matteGate.tryEnter() {
                    matteWork.async {
                        matte.process(pixelBuffer: frame.pixelBuffer)
                        matteGate.leave()
                    }
                }

                // 손 추적 — 깊이 추론과 병렬로 돈다.
                if visionReady.isOpen, handGate.tryEnter() {
                    Task { @MainActor [weak self] in
                        guard let self, self.inputMode == .hand,
                              let tracker = self.handTracker else {
                            handGate.leave(); return
                        }
                        let result = await tracker.process(pixelBuffer: frame.pixelBuffer) { point in
                            // 핀치 지점의 깊이. 손도 프레임 안에 있으므로 별도 센서가 필요 없다.
                            pipeline.sampleInverseDepth(
                                atNormalized: SIMD2<Float>(Float(point.x), Float(point.y))) ?? 0.5
                        }
                        self.isHandVisible = tracker.isHandVisible
                        if let result { self.applyPinch(result) }
                        handGate.leave()
                    }
                }

                // 광원 상태는 메인 액터가 소유하므로 값 타입 스냅샷으로 건넨다.
                Task { @MainActor in
                    let lighting = self?.currentLighting()
                    let matteTexture = self?.personMatte?.latestTexture()
                    queue.async {
                        let start = CACurrentMediaTime()
                        let result = pipeline.process(source: frame.texture,
                                                      lighting: lighting,
                                                      segmentation: matteTexture)
                        let elapsed = (CACurrentMediaTime() - start) * 1000
                        if let result {
                            store.publishResult(depth: result.depth, relit: result.relit)
                        }
                        gate.leave()
                        Task { @MainActor in self?.stats.recordDepth(milliseconds: elapsed) }
                    }
                }
            }
            self.capture = capture
            let tracker = HandTracker()
            self.handTracker = tracker

            // Vision 워밍업 — 더미 프레임으로 하나씩, 순서대로. (visionWarmedUp 주석 참조)
            // 캡처 시작 전에 끝내야 Metal 4 ML 초기화와 겹치지 않는다.
            matteQueue.async {
                if let dummy = Self.makeDummyPixelBuffer() {
                    matteProvider?.warmUp(with: dummy)
                    let semaphore = DispatchSemaphore(value: 0)
                    Task.detached {
                        _ = await tracker.process(pixelBuffer: dummy)
                        semaphore.signal()
                    }
                    _ = semaphore.wait(timeout: .now() + 5)
                }
                visionReady.open()
                NSLog("[Delight] Vision 워밍업 완료")
            }
            Task { @MainActor in
                do {
                    try await capture.start()
                    self.status = .running
                    NSLog("[Delight] 캡처 시작됨")
                } catch {
                    self.status = .failed(error.localizedDescription)
                    NSLog("[Delight] 캡처 시작 실패: %@", String(describing: error))
                }
            }
        } catch {
            self.status = .failed(error.localizedDescription)
            NSLog("[Delight] 엔진 시작 실패: %@", String(describing: error))
        }
    }

    func stop() {
        capture?.stop()
        capture = nil
        status = .idle
    }

    /// 현재 조명 상태를 셰이더 유니폼 스냅샷으로 만든다.
    func currentLighting() -> SunUniforms {
        var uniforms = SunUniforms()
        lightRig.fill(&uniforms)
        // 초점거리는 출력 해상도와 짝이어야 한다. 빠뜨리면 기본값이 들어가 원근이 틀어진다.
        uniforms.fx = calibration.fx
        uniforms.fy = calibration.fy
        return uniforms
    }

    /// 핀치 상태를 광원에 반영한다.
    ///
    /// 거울상 보정은 하지 않는다 — 핀치 좌표와 렌더링이 **둘 다 원본 카메라 좌표계**이고,
    /// 프리뷰에서 함께 뒤집히므로 사용자 눈에는 손과 조명이 같은 자리에 보인다.
    /// (마우스는 사용자가 이미 뒤집힌 화면을 보고 찍으므로 보정이 필요하다 — ContentView 참조)
    func applyPinch(_ pinch: PinchState) {
        self.pinch = pinch
        guard pinch.isPinching else {
            lightRig.releaseGrab()
            return
        }
        moveLight(toNormalized: SIMD2<Float>(Float(pinch.position.x), Float(pinch.position.y)),
                  handDepth: pinch.normalizedDepth,
                  isGrabbing: true,
                  handScale: pinch.handScale)
    }

    /// 프리뷰 위 정규화 좌표로 광원을 옮긴다. 마우스와 핀치가 같은 경로를 쓴다.
    /// - Parameter normalized: 좌상단 원점 0…1. 거울상 보정은 호출부에서 끝낸 값이어야 한다.
    func moveLight(toNormalized normalized: SIMD2<Float>,
                   handDepth: Float? = nil,
                   isGrabbing: Bool = false,
                   handScale: Float = 0) {
        lightRig.place(normalized: normalized,
                       handDepth: handDepth,
                       calibration: calibration,
                       pixelSize: SIMD2<Float>(Float(Self.outputWidth),
                                               Float(Self.outputHeight)),
                       affine: SIMD2<Float>(SunUniforms().affineA, SunUniforms().affineB),
                       isGrabbing: isGrabbing,
                       handScale: handScale)
    }

    /// 리라이팅 출력 해상도. 깊이 해상도(518×392)의 3배다.
    /// 깊이맵은 저해상도로 두고 조명만 고해상도로 계산한다 —
    /// 깊이는 저주파라 확대해도 티가 안 나지만, 최종 화면은 카메라 해상도여야 한다.
    static let outputWidth = DepthPipeline.modelWidth * 3      // 1554
    static let outputHeight = DepthPipeline.modelHeight * 3    // 1176

    /// 초점거리 추정치. macOS는 내부파라미터를 주지 않아 추정값을 쓴다.
    private(set) var calibration = CameraCalibration(width: outputWidth, height: outputHeight)
}

/// 캡처 스레드가 쓰고 렌더 스레드가 읽는 최신 프레임 보관소.
/// CameraFrame 전체를 보관해야 한다 — MTLTexture만 저장하면 CVMetalTexture가
/// 해제되면서 캐시가 IOSurface를 재활용해 화면이 검거나 찢어진다.
nonisolated final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var camera: CameraFrame?
    private var depth: MTLTexture?
    private var relit: MTLTexture?

    func publishCamera(_ frame: CameraFrame) {
        lock.lock(); camera = frame; lock.unlock()
    }
    func publishResult(depth: MTLTexture, relit: MTLTexture) {
        lock.lock(); self.depth = depth; self.relit = relit; lock.unlock()
    }
    func latest() -> (camera: MTLTexture?, depth: MTLTexture?, relit: MTLTexture?) {
        lock.lock(); defer { lock.unlock() }
        return (camera?.texture, depth, relit)
    }
}

/// 한 번 열리면 계속 열려 있는 플래그.
nonisolated final class OpenFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return opened }
    func open() { lock.lock(); opened = true; lock.unlock() }
}

/// 더미 프레임 생성 — Vision 워밍업용.
extension RelightEngine {
    nonisolated static func makeDummyPixelBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                            &buffer)
        return buffer
    }
}

/// 추론이 진행 중이면 새 프레임을 버리기 위한 게이트.
nonisolated final class InFlightGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false

    func tryEnter() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if busy { return false }
        busy = true
        return true
    }
    func leave() {
        lock.lock(); busy = false; lock.unlock()
    }
}

/// 프레임 타이밍 통계. HUD에 그대로 표시한다.
struct FrameStats {
    private(set) var captureFPS: Double = 0
    private(set) var depthMilliseconds: Double = 0
    private(set) var depthFPS: Double = 0
    private(set) var frameCount: Int = 0

    private var lastCapture: CMTime = .zero
    private var smoothedInterval: Double = 0

    mutating func recordCapture(at time: CMTime) {
        frameCount += 1
        if lastCapture != .zero {
            let dt = (time - lastCapture).seconds
            if dt > 0 {
                smoothedInterval = smoothedInterval == 0 ? dt : smoothedInterval * 0.9 + dt * 0.1
                captureFPS = 1.0 / smoothedInterval
            }
        }
        lastCapture = time
    }

    mutating func recordDepth(milliseconds: Double) {
        depthMilliseconds = depthMilliseconds == 0
            ? milliseconds
            : depthMilliseconds * 0.85 + milliseconds * 0.15
        depthFPS = 1000.0 / max(depthMilliseconds, 0.001)
    }
}
