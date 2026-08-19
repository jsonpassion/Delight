//
//  HandTracker.swift
//  Vision 핸드포즈 → 핀치. z는 별도 센서 없이 깊이맵에서 얻는다.
//
//  핵심: 손이 프레임 안에 있으므로 깊이맵이 이미 손의 깊이를 갖고 있다.
//  (docs/01-architecture.md §8)
//

import Vision
import CoreVideo
import CoreGraphics
import Foundation

/// ⚠️ @Observable로 두고 백그라운드에서 갱신하면 SwiftUI 레이아웃과 참조카운트가 경쟁해
/// EXC_BAD_ACCESS로 죽는다(실제 크래시 리포트로 확인).
/// 그래서 관찰 대상이 아니라 **결과를 반환하는 순수 계산기**로 만들고,
/// 관찰 가능한 상태는 메인 액터의 RelightEngine이 소유한다. PersonMatte와 같은 패턴이다.
nonisolated final class HandTracker: @unchecked Sendable {

    private let lock = NSLock()
    private var detector = PinchDetector()
    private var _isHandVisible = false

    var isHandVisible: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isHandVisible
    }

    /// maximumHandCount는 지연에 직접 영향을 준다. 필요한 최솟값으로 둔다.
    private var request: DetectHumanHandPoseRequest = {
        var r = DetectHumanHandPoseRequest()
        r.maximumHandCount = 1
        return r
    }()

    /// 한 프레임 처리. 결과를 반환한다 — 내부 상태를 관찰하게 하지 않는다.
    /// - Parameter depthSampler: 정규화 좌표(좌상단 원점)를 받아 역깊이를 돌려준다.
    ///   손끝은 얇아서 깊이가 배경으로 새므로, 구현은 이웃의 "가장 가까운 쪽" 분위수를 써야 한다.
    /// - Returns: 갱신된 핀치 상태. 손을 놓쳤으면 nil(호출부는 마지막 상태를 유지한다).
    func process(pixelBuffer: CVPixelBuffer,
                 depthSampler: ((CGPoint) -> Float)? = nil) async -> PinchState? {

        guard let observations = try? await request.perform(on: pixelBuffer),
              let hand = observations.first else {
            // 손을 놓쳤을 때 마지막 위치를 유지한다. 조명이 튀지 않게.
            lock.lock(); _isHandVisible = false; lock.unlock()
            return nil
        }
        lock.lock(); _isHandVisible = true; lock.unlock()

        let thumbJoints = hand.allJoints(in: .thumb)
        let indexJoints = hand.allJoints(in: .indexFinger)

        guard let thumbTip = thumbJoints[.thumbTip],
              let indexTip = indexJoints[.indexTip] else { return nil }

        // Vision은 좌하단 원점, Metal은 좌상단 원점.
        // 뒤집기는 **여기 한 곳에서만** 한다. 두 곳에서 하면 반드시 버그가 난다.
        let thumbPoint = thumbTip.location.verticallyFlipped().cgPoint
        let indexPoint = indexTip.location.verticallyFlipped().cgPoint

        let dx = Float(thumbPoint.x - indexPoint.x)
        let dy = Float(thumbPoint.y - indexPoint.y)
        let separation = (dx * dx + dy * dy).squareRoot()
        let confidence = min(thumbTip.confidence, indexTip.confidence)
        let midpoint = CGPoint(x: (thumbPoint.x + indexPoint.x) / 2,
                               y: (thumbPoint.y + indexPoint.y) / 2)

        lock.lock()
        var next = detector.update(separation: separation,
                                   confidence: confidence,
                                   position: midpoint)
        lock.unlock()

        if let depthSampler {
            next.normalizedDepth = depthSampler(midpoint)
        }
        next.handScale = Self.apparentHandSize(hand) ?? 0
        return next
    }

    /// 손의 겉보기 크기. 1/Z에 비례한다.
    ///
    /// 이 신호가 깊이맵보다 나은 지점이 하나 있다: **가림에 영향받지 않는다.**
    /// 손을 머리 뒤로 가져가면 깊이맵은 머리를 읽지만, 손목–중지MCP 거리는
    /// 손이 보이는 한 계속 손의 거리를 말해준다.
    static func apparentHandSize(_ hand: HumanHandPoseObservation) -> Float? {
        let all = hand.allJoints()
        guard let wrist = all[.wrist], let middleMCP = all[.middleMCP],
              wrist.confidence > 0.3, middleMCP.confidence > 0.3 else { return nil }
        let size = Float(wrist.distance(to: middleMCP))
        return size > 0.01 ? size : nil
    }
}
