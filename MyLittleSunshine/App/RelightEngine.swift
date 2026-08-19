//
//  RelightEngine.swift
//  파이프라인 오케스트레이터. 각 스테이지는 프로토콜 뒤에 있으므로
//  하나가 실패해도 나머지가 산다. (docs/01-architecture.md §10)
//

import Foundation
import Metal
import CoreMedia
import Observation

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

    /// 손 인식이 실패해도 데모가 죽지 않도록 하는 폴백. P2에서 반드시 살려둔다.
    var inputMode: InputMode = .hand

    enum InputMode: String, CaseIterable, Identifiable {
        case hand = "손"
        case mouse = "마우스"
        var id: String { rawValue }
    }

    // MARK: 구성 요소

    let device: MTLDevice
    private(set) var capture: CameraCapture?
    private(set) var depthProvider: (any DepthProvider)?
    private(set) var handTracker: HandTracker?
    private(set) var sinks: [any FrameSink] = []

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal 지원 GPU를 찾을 수 없습니다.")
        }
        self.device = device
    }

    // MARK: 수명주기

    func start() {
        guard status != .running else { return }
        do {
            let capture = try CameraCapture(device: device)
            capture.onFrame = { [weak self] frame in
                Task { @MainActor in self?.process(frame) }
            }
            try capture.start()
            self.capture = capture

            self.handTracker = HandTracker()
            self.status = .running
        } catch {
            self.status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        capture?.stop()
        capture = nil
        status = .idle
    }

    // MARK: 프레임 처리

    private func process(_ frame: CameraFrame) {
        stats.record(captureAt: frame.presentationTime)

        // P1: 프리뷰까지. P2 이후 깊이 → 지오메트리 → 리라이팅이 여기에 붙는다.
        // 전체 흐름은 docs/01-architecture.md §1 참조.
        for sink in sinks {
            sink.submit(frame.texture, pts: frame.presentationTime)
        }
    }

    func attach(sink: any FrameSink) {
        sinks.append(sink)
    }
}

/// 프레임 타이밍 통계. HUD에 그대로 표시한다.
struct FrameStats {
    private(set) var fps: Double = 0
    private(set) var frameCount: Int = 0
    private var lastTime: CMTime = .zero
    private var accumulated: Double = 0

    mutating func record(captureAt time: CMTime) {
        frameCount += 1
        if lastTime != .zero {
            let dt = (time - lastTime).seconds
            if dt > 0 { accumulated = accumulated * 0.9 + dt * 0.1 }
            if accumulated > 0 { fps = 1.0 / accumulated }
        }
        lastTime = time
    }
}
