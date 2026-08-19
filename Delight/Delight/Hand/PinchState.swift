//
//  PinchState.swift
//  핀치 검출은 임계값 하나로 하면 경계에서 채터링이 난다.
//  반드시 닫힘/열림 두 개로 분리한다. (docs/01-architecture.md §8)
//

import CoreGraphics

struct PinchState: Equatable {
    var isPinching = false
    /// 정규화 화면좌표 (0…1, 좌상단 원점 — Metal 규약에 맞춰 이미 y가 뒤집힌 값)
    var position: CGPoint = .init(x: 0.5, y: 0.5)
    /// 깊이맵에서 샘플한 정규화 역깊이. 클수록 카메라에 가깝다.
    ///
    /// ⚠️ 손이 다른 물체에 가려지면 이 값은 **손이 아니라 가린 물체**를 가리킨다.
    /// 손을 머리 뒤로 가져가면 머리 깊이를 읽는다. 단독으로 신뢰하면 안 된다.
    var normalizedDepth: Float = 0.5

    /// 손의 겉보기 크기(정규화 화면 단위). 1/Z에 비례한다.
    /// 가림에 영향받지 않으므로 손이 머리 뒤로 가도 거리를 알 수 있다.
    var handScale: Float = 0
    /// 엄지–검지 정규화 거리. UI 피드백용.
    var separation: Float = 1.0
    var confidence: Float = 0

    static let closeThreshold: Float = 0.045
    static let openThreshold:  Float = 0.070
    static let minConfidence:  Float = 0.6
    static let debounceFrames: Int = 3
}

/// 히스테리시스 + 디바운스를 적용하는 작은 상태기계.
struct PinchDetector {
    private var consecutiveClosed = 0
    private(set) var state = PinchState()

    mutating func update(separation: Float, confidence: Float, position: CGPoint) -> PinchState {
        state.separation = separation
        state.confidence = confidence
        state.position = position

        guard confidence >= PinchState.minConfidence else {
            consecutiveClosed = 0
            return state
        }

        if state.isPinching {
            // 열림 판정은 즉시 — 놓는 동작은 반응이 빨라야 자연스럽다.
            if separation > PinchState.openThreshold {
                state.isPinching = false
                consecutiveClosed = 0
            }
        } else {
            if separation < PinchState.closeThreshold {
                consecutiveClosed += 1
                if consecutiveClosed >= PinchState.debounceFrames {
                    state.isPinching = true
                }
            } else {
                consecutiveClosed = 0
            }
        }
        return state
    }
}
