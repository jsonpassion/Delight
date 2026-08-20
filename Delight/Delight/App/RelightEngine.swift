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
    @ObservationIgnored let frameStats = FrameStats()
    @ObservationIgnored let lightingStore = LightingStore()

    /// 씬에 놓인 광원들. 다중 광원 확장을 위해 처음부터 배열이다.
    var lightRig = LightRig()

    /// Syphon 송출. 켜면 OBS의 Syphon Client 소스에 "Delight"가 나타난다.
    var isBroadcasting = false {
        didSet {
            guard isBroadcasting != oldValue else { return }
            isBroadcasting ? syphonSink.start() : syphonSink.stop()
        }
    }
    /// @ObservationIgnored — 싱크 자체는 관찰 대상이 아니다(상태는 isBroadcasting이 들고 있다).
    /// @Observable 매크로가 프로퍼티를 computed로 바꾸므로 lazy를 쓸 수 없다.
    @ObservationIgnored private(set) var syphonSink: SyphonSink!

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
    /// 메모리 감시 — 누수가 시스템을 죽이기 전에 스스로 멈춘다.
    ///
    /// 텍스처 캐시 flush를 빠뜨려 IOSurface가 쌓였고, WindowServer가 굶어
    /// 커널 watchdog이 맥을 재부팅시킨 적이 있다. 그때 앱은 아무 신호도 주지 않았다.
    /// 원인을 고쳤지만, 같은 부류의 누수가 다시 생겨도 시스템까지 끌고 가지는 않게 한다.
    @ObservationIgnored private var memoryWatchdog: Timer?
    private static let memoryLimitMB = 4_096.0

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
        self.syphonSink = SyphonSink(device: device)

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
                self.start()
                // 슬라이더 조작과 같은 경로로 depthOffset을 대입해 회귀를 잡는다.
                // (@Observable + didSet 자기대입이 무한재귀로 크래시한 전례가 있다)
                // --broadcast: Syphon 송출까지 검증한다.
                if ProcessInfo.processInfo.arguments.contains("--broadcast") {
                    self.isBroadcasting = true
                }

                // 진단 루프는 **관측만 한다.**
                // 이전에는 여기서 3초마다 lightRig를 흔들어 A/B를 쟀는데,
                // 그 쓰기가 SwiftUI 레이아웃과 경쟁해 진단 도구 자체가 크래시를 만들었다.
                // A/B가 필요하면 --stabilize-off 로 고정해 두 번 돌린다.
                self.lightRig.temporalBlend =
                    ProcessInfo.processInfo.arguments.contains("--stabilize-off") ? 0.0 : 0.85
                for tick in 0..<10 {
                    try? await Task.sleep(for: .seconds(3))
                    let (camera, relit) = self.frameStore.latest()
                    let line = String(
                        format: "안정화=%@ status=%@ 캡처 %.1ffps 깊이 %.2fms(%.1ffps) 프레임 %d cam=%@ relit=%@ mem=%.0fMB 매트=%@ 송출=%@ 플리커=%.5f [enc %.1f gpu %.1f aff %.1f flk %.1f] 손=%@ 핀치=%@ d=%.2f z=%.2f",
                        self.lightRig.temporalBlend > 0 ? "ON " : "OFF",
                        String(describing: self.status), self.frameStats.captureFPS,
                        self.frameStats.depthMilliseconds, self.frameStats.depthFPS, self.frameStats.frameCount,
                        camera == nil ? "nil" : "OK",
                        relit == nil ? "nil" : "OK",
                        Self.residentMemoryMB(),
                        self.personMatte?.latestTexture() == nil ? "nil" : "OK",
                        self.syphonSink.isActive ? "ON" : "off",
                        self.depthPipeline?.flickerMetric ?? 0,
                        self.depthPipeline?.timing.encode ?? 0,
                        self.depthPipeline?.timing.gpuWait ?? 0,
                        self.depthPipeline?.timing.affine ?? 0,
                        self.depthPipeline?.timing.flicker ?? 0,
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
            // 캡처를 먼저 만들어 실제 해상도를 알아낸다.
            // 출력이 카메라보다 작으면 다운샘플로 디테일이 날아가 "카메라 질감"을 잃는다.
            let capture = try CameraCapture(device: device)
            let dimensions = capture.activeDimensions
            let (outWidth, outHeight) = Self.outputSize(for: dimensions)
            NSLog("[Delight] 카메라 %dx%d → 출력 %dx%d",
                  dimensions.width, dimensions.height, outWidth, outHeight)

            let pipeline = try DepthPipeline(
                device: device,
                outputWidth: outWidth,
                outputHeight: outHeight)
            self.depthPipeline = pipeline
            self.calibration = CameraCalibration(width: outWidth, height: outHeight)
            self.outputSize = SIMD2<Float>(Float(outWidth), Float(outHeight))

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
            let sink = self.syphonSink!
            let lightingStore = self.lightingStore
            let stats = self.frameStats
            let matteProvider = ProcessInfo.processInfo.arguments.contains("--no-matte")
                ? nil : PersonMatte(device: device)
            self.personMatte = matteProvider
            if matteProvider == nil {
                NSLog("[Delight] 인물 세그멘테이션 초기화 실패 — 깊이 기반 근사 매트로 폴백")
            }

            capture.onFrame = { [weak self] frame in
                store.publishCamera(frame)
                stats.recordCapture(at: frame.presentationTime)

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
                        guard let self, let tracker = self.handTracker else {
                            handGate.leave(); return
                        }
                        let result = await tracker.process(pixelBuffer: frame.pixelBuffer) { point in
                            // 핀치 지점의 깊이. 손도 프레임 안에 있으므로 별도 센서가 필요 없다.
                            pipeline.sampleInverseDepth(
                                atNormalized: SIMD2<Float>(Float(point.x), Float(point.y)))
                                ?? (depth: 0.5, reliable: false)
                        }
                        // @Observable 프로퍼티는 **값이 바뀔 때만** 쓴다.
                        // 같은 값을 초당 30번 대입하면 SwiftUI가 그만큼 레이아웃을 다시 하고,
                        // 그 부하가 AttributeGraph에서 참조카운트 경쟁으로 터진다.
                        if self.isHandVisible != tracker.isHandVisible {
                            self.isHandVisible = tracker.isHandVisible
                        }
                        if let result {
                            self.applyPinch(result)
                        } else {
                            // 손이 안 보이면 **위치를 예측하지 않는다.**
                            // 마지막 자리에 광원을 남기면 그 자리가 오브젝트 앞일 때
                            // "뒤로 보냈는데 앞에 붙는" 버그가 된다. 그냥 놓는다.
                            var released = self.pinch
                            released.isPinching = false
                            self.applyPinch(released)
                        }
                        handGate.leave()
                    }
                }

                // 조명·매트는 모두 락으로 보호된 저장소에서 읽는다.
                // 메인 액터를 거치지 않으므로 SwiftUI와 경쟁하지 않는다.
                let lighting = lightingStore.load()
                let matteTexture = matteProvider?.latestTexture()
                queue.async {
                    let start = CACurrentMediaTime()
                    let relit = pipeline.process(source: frame.texture,
                                                 lighting: lighting,
                                                 segmentation: matteTexture)
                    stats.recordDepth(milliseconds: (CACurrentMediaTime() - start) * 1000)
                    if let relit {
                        store.publishResult(relit: relit)
                        // 송출은 거울상을 적용하지 않는다 — 프리뷰 전용이다.
                        sink.submit(relit, pts: frame.presentationTime)
                    }
                    gate.leave()
                }
            }
            self.capture = capture
            publishLighting()
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
                    self.startMemoryWatchdog()
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

    /// 상주 메모리(MB). 누수 감시용.
    private static func residentMemoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }

    private func startMemoryWatchdog() {
        memoryWatchdog?.invalidate()
        memoryWatchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let used = Self.residentMemoryMB()
                guard used > Self.memoryLimitMB else { return }
                NSLog("[Delight] 메모리 %.0fMB — 한계 초과로 캡처를 멈춥니다", used)
                self.stop()
                self.status = .failed(String(format:
                    "메모리 사용량이 %.0fMB에 도달해 안전을 위해 멈췄습니다. 다시 시작할 수 있습니다.", used))
            }
        }
    }

    func stop() {
        memoryWatchdog?.invalidate()
        memoryWatchdog = nil
        capture?.stop()
        capture = nil
        isBroadcasting = false
        status = .idle
    }

    /// 현재 조명 상태를 셰이더 유니폼 스냅샷으로 만든다.
    /// 조명이 바뀌면 캡처 스레드가 읽을 스냅샷을 갱신한다.
    func publishLighting() {
        var uniforms = SunUniforms()
        lightRig.fill(&uniforms)
        // 초점거리는 출력 해상도와 짝이어야 한다. 빠뜨리면 기본값이 들어가 원근이 틀어진다.
        uniforms.fx = calibration.fx
        uniforms.fy = calibration.fy
        lightingStore.store(uniforms)
    }

    /// 핀치 상태를 광원에 반영한다.
    ///
    /// 거울상 보정은 하지 않는다 — 핀치 좌표와 렌더링이 **둘 다 원본 카메라 좌표계**이고,
    /// 프리뷰에서 함께 뒤집히므로 사용자 눈에는 손과 조명이 같은 자리에 보인다.
    /// (마우스는 사용자가 이미 뒤집힌 화면을 보고 찍으므로 보정이 필요하다 — ContentView 참조)
    func applyPinch(_ pinch: PinchState) {
        // 잡음/놓음이 바뀔 때만 관찰 프로퍼티를 건드린다. 위치는 매 프레임 바뀌지만
        // 화면에 쓰이지 않으므로 SwiftUI를 깨울 이유가 없다.
        if self.pinch.isPinching != pinch.isPinching {
            self.pinch = pinch
        }
        let pinch = pinch
        guard pinch.isPinching else {
            // 핀치를 놓으면 광원도 즉시 사라진다.
            // 손을 놓은 뒤 광원이 손등 뒤나 얼굴 속에 남아 있는 상태 자체를 없앤다.
            lightRig.releaseGrab()
            lightRig.isLit = false
            publishLighting()
            return
        }
        lightRig.isLit = true
        // 깊이가 신뢰할 수 없으면(가림 경계) 이번 프레임은 움직이지 않는다.
        guard pinch.depthIsReliable else { return }
        moveLight(toNormalized: SIMD2<Float>(Float(pinch.position.x), Float(pinch.position.y)),
                  handDepth: pinch.normalizedDepth,
                  isGrabbing: true)
    }

    /// 프리뷰 위 정규화 좌표로 광원을 옮긴다. 마우스와 핀치가 같은 경로를 쓴다.
    /// - Parameter normalized: 좌상단 원점 0…1. 거울상 보정은 호출부에서 끝낸 값이어야 한다.
    func moveLight(toNormalized normalized: SIMD2<Float>,
                   handDepth: Float? = nil,
                   isGrabbing: Bool = false) {
        // 마우스로 끌면 항상 켠다. 손 모드에서만 핀치 여부가 광원의 존재를 정한다.
        if !isGrabbing { lightRig.isLit = true }
        lightRig.place(normalized: normalized,
                       handDepth: handDepth,
                       calibration: calibration,
                       pixelSize: outputSize,
                       affine: SIMD2<Float>(SunUniforms().affineA, SunUniforms().affineB),
                       isGrabbing: isGrabbing)
        publishLighting()
    }

    /// 리라이팅 출력 해상도를 카메라 해상도에 맞춘다.
    /// 깊이맵은 518×392 저해상도로 두고 **조명만** 고해상도로 계산한다 —
    /// 깊이는 저주파라 확대해도 티가 안 나지만, 최종 화면은 카메라 그대로여야 한다.
    /// 상한은 GPU 예산 때문이다(레이마칭이 픽셀 수에 선형).
    static func outputSize(for dimensions: CMVideoDimensions) -> (Int, Int) {
        let width = Int(dimensions.width), height = Int(dimensions.height)
        guard width > 0, height > 0 else { return (1554, 1176) }
        let maxPixels = 1920 * 1440
        let pixels = width * height
        guard pixels > maxPixels else { return (width, height) }
        let scale = (Double(maxPixels) / Double(pixels)).squareRoot()
        // 컴퓨트 디스패치 정렬을 위해 짝수로 맞춘다.
        return ((Int(Double(width) * scale) / 2) * 2, (Int(Double(height) * scale) / 2) * 2)
    }

    /// 실제 출력 해상도. 좌표 변환에 쓰인다.
    private(set) var outputSize = SIMD2<Float>(1554, 1176)

    /// 초점거리 추정치. macOS는 내부파라미터를 주지 않아 추정값을 쓴다.
    private(set) var calibration = CameraCalibration(width: 1554, height: 1176)
}

/// 캡처 스레드가 쓰고 렌더 스레드가 읽는 최신 프레임 보관소.
/// CameraFrame 전체를 보관해야 한다 — MTLTexture만 저장하면 CVMetalTexture가
/// 해제되면서 캐시가 IOSurface를 재활용해 화면이 검거나 찢어진다.
nonisolated final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var camera: CameraFrame?
    private var relit: MTLTexture?

    func publishCamera(_ frame: CameraFrame) {
        lock.lock(); camera = frame; lock.unlock()
    }
    func publishResult(relit: MTLTexture) {
        lock.lock(); self.relit = relit; lock.unlock()
    }
    func latest() -> (camera: MTLTexture?, relit: MTLTexture?) {
        lock.lock(); defer { lock.unlock() }
        return (camera?.texture, relit)
    }
}

/// 메인 액터가 쓰고 캡처 스레드가 읽는 조명 스냅샷.
///
/// 매 프레임 `Task { @MainActor }`로 조명을 가져오면 초당 수십 개의 태스크가
/// SwiftUI 트랜잭션과 경쟁해 참조카운트가 깨진다(크래시: RefCounts::incrementSlow).
/// 조명은 사용자가 움직일 때만 바뀌므로, 바뀔 때 밀어넣고 캡처 쪽은 락으로 읽는다.
nonisolated final class LightingStore: @unchecked Sendable {
    private let lock = NSLock()
    private var uniforms = SunUniforms()

    func store(_ value: SunUniforms) { lock.lock(); uniforms = value; lock.unlock() }
    func load() -> SunUniforms { lock.lock(); defer { lock.unlock() }; return uniforms }
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

/// 프레임 타이밍 통계. 진단 전용이므로 관찰 대상이 아니다 —
/// 초당 30번 바뀌는 값을 @Observable로 두면 SwiftUI가 그만큼 레이아웃을 다시 한다.
nonisolated final class FrameStats: @unchecked Sendable {
    private let lock = NSLock()

    private var _captureFPS: Double = 0
    private var _depthMilliseconds: Double = 0
    private var _depthFPS: Double = 0
    private var _frameCount: Int = 0
    private var lastCapture: CMTime = .zero
    private var smoothedInterval: Double = 0

    var captureFPS: Double { lock.lock(); defer { lock.unlock() }; return _captureFPS }
    var depthMilliseconds: Double { lock.lock(); defer { lock.unlock() }; return _depthMilliseconds }
    var depthFPS: Double { lock.lock(); defer { lock.unlock() }; return _depthFPS }
    var frameCount: Int { lock.lock(); defer { lock.unlock() }; return _frameCount }

    func recordCapture(at time: CMTime) {
        lock.lock(); defer { lock.unlock() }
        _frameCount += 1
        if lastCapture != .zero {
            let dt = (time - lastCapture).seconds
            if dt > 0 {
                smoothedInterval = smoothedInterval == 0 ? dt : smoothedInterval * 0.9 + dt * 0.1
                _captureFPS = 1.0 / smoothedInterval
            }
        }
        lastCapture = time
    }

    func recordDepth(milliseconds: Double) {
        lock.lock(); defer { lock.unlock() }
        _depthMilliseconds = _depthMilliseconds == 0
            ? milliseconds
            : _depthMilliseconds * 0.85 + milliseconds * 0.15
        _depthFPS = 1000.0 / max(_depthMilliseconds, 0.001)
    }
}
