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

    // MARK: 구성 요소

    let device: MTLDevice
    private(set) var capture: CameraCapture?
    private(set) var depthPipeline: DepthPipeline?
    private(set) var handTracker: HandTracker?

    /// 렌더러가 읽어 가는 최신 결과.
    let frameStore = FrameStore()

    private let processingQueue = DispatchQueue(label: "delight.depth", qos: .userInitiated)
    private let inFlight = InFlightGate()

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
                self.start()
                // 슬라이더 조작과 같은 경로로 depthOffset을 대입해 회귀를 잡는다.
                // (@Observable + didSet 자기대입이 무한재귀로 크래시한 전례가 있다)
                let offsets: [Float] = [-0.3, 0.0, 0.4, 0.9, -0.15]
                for i in 0..<10 {
                    try? await Task.sleep(for: .seconds(3))
                    self.lightRig.depthOffset = offsets[i % offsets.count]
                    let (camera, depth) = self.frameStore.latest()
                    let line = String(
                        format: "status=%@ 캡처 %.1ffps 깊이 %.2fms(%.1ffps) 프레임 %d cam=%@ depth=%@",
                        String(describing: self.status), self.stats.captureFPS,
                        self.stats.depthMilliseconds, self.stats.depthFPS, self.stats.frameCount,
                        camera == nil ? "nil" : "OK", depth == nil ? "nil" : "OK")
                    NSLog("[Delight] %@", line)
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
                outputWidth: DepthPipeline.modelWidth,
                outputHeight: DepthPipeline.modelHeight)
            self.depthPipeline = pipeline

            let capture = try CameraCapture(device: device)
            let store = frameStore
            let gate = inFlight
            let queue = processingQueue

            capture.onFrame = { [weak self] frame in
                store.publishCamera(frame)
                Task { @MainActor in self?.stats.recordCapture(at: frame.presentationTime) }

                // 추론이 아직 돌고 있으면 이 프레임은 버린다.
                guard gate.tryEnter() else { return }
                queue.async {
                    let start = CACurrentMediaTime()
                    let result = pipeline.process(source: frame.texture)
                    let elapsed = (CACurrentMediaTime() - start) * 1000
                    if let result { store.publishDepth(result) }
                    gate.leave()
                    Task { @MainActor in self?.stats.recordDepth(milliseconds: elapsed) }
                }
            }
            self.capture = capture
            self.handTracker = HandTracker()
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
}

/// 캡처 스레드가 쓰고 렌더 스레드가 읽는 최신 프레임 보관소.
/// CameraFrame 전체를 보관해야 한다 — MTLTexture만 저장하면 CVMetalTexture가
/// 해제되면서 캐시가 IOSurface를 재활용해 화면이 검거나 찢어진다.
nonisolated final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var camera: CameraFrame?
    private var depth: MTLTexture?

    func publishCamera(_ frame: CameraFrame) {
        lock.lock(); camera = frame; lock.unlock()
    }
    func publishDepth(_ texture: MTLTexture) {
        lock.lock(); depth = texture; lock.unlock()
    }
    func latest() -> (camera: MTLTexture?, depth: MTLTexture?) {
        lock.lock(); defer { lock.unlock() }
        return (camera?.texture, depth)
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
