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

@Observable
final class HandTracker {

    private(set) var pinch = PinchState()
    private(set) var isHandVisible = false
    private var detector = PinchDetector()

    /// maximumHandCount는 지연에 직접 영향을 준다. 필요한 최솟값으로 둔다.
    private var request: DetectHumanHandPoseRequest = {
        var r = DetectHumanHandPoseRequest()
        r.maximumHandCount = 1
        return r
    }()

    /// 한 프레임 처리.
    /// - Parameter depthSampler: 정규화 좌표(좌상단 원점)를 받아 역깊이를 돌려준다.
    ///   손끝은 얇아서 깊이가 배경으로 새므로, 구현은 이웃의 "가장 가까운 쪽" 분위수를 써야 한다.
    func process(pixelBuffer: CVPixelBuffer,
                 depthSampler: ((CGPoint) -> Float)? = nil) async {

        guard let observations = try? await request.perform(on: pixelBuffer),
              let hand = observations.first else {
            // 손을 놓쳤을 때 마지막 위치를 유지한다. 조명이 튀지 않게.
            isHandVisible = false
            return
        }
        isHandVisible = true

        let thumbJoints = hand.allJoints(in: .thumb)
        let indexJoints = hand.allJoints(in: .indexFinger)

        guard let thumbTip = thumbJoints[.thumbTip],
              let indexTip = indexJoints[.indexTip] else { return }

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

        var next = detector.update(separation: separation,
                                   confidence: confidence,
                                   position: midpoint)

        if let depthSampler {
            next.normalizedDepth = depthSampler(midpoint)
        }

        pinch = next
    }

    /// 손 크기는 1/Z에 비례한다. 깊이 샘플이 튈 때 버텨주는 보조 신호.
    /// (docs/01-architecture.md §8)
    static func apparentHandSize(_ hand: HumanHandPoseObservation) -> Float? {
        let all = hand.allJoints()
        guard let wrist = all[.wrist], let middleMCP = all[.middleMCP] else { return nil }
        return Float(wrist.distance(to: middleMCP))
    }
}
