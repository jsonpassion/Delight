//
//  LightRig.swift
//  광원은 처음부터 배열이다. 키 + 필 2개만 되어도 품질이 확 오른다.
//

import Foundation
import simd
import SwiftUI

struct PointLight: Identifiable, Equatable {
    let id = UUID()
    /// 뷰공간 위치(미터). z가 클수록 카메라에서 멀다.
    var position: SIMD3<Float> = .init(0.25, -0.15, 0.45)
    var color: SIMD3<Float> = .init(1.0, 0.82, 0.62)   // 텅스텐 3200K
    var intensity: Float = 1.4
    /// 소프트섀도우 반경(미터). 두 손 핀치 간격에 매핑된다.
    var radius: Float = 0.06
    var isEnabled = true

    /// 색온도(K) → 선형 RGB 근사. 슬라이더용.
    static func color(temperature kelvin: Float) -> SIMD3<Float> {
        let t = max(1500, min(10000, kelvin)) / 100
        let r = t <= 66 ? 1.0 : min(1.0, 1.292936 * pow(t - 60, -0.1332047))
        let g = t <= 66 ? min(1.0, 0.3900816 * log(t) - 0.6318414)
                        : min(1.0, 1.129891 * pow(t - 60, -0.0755148))
        let b = t >= 66 ? 1.0 : (t <= 19 ? 0 : min(1.0, 0.5432068 * log(t - 10) - 1.19625))
        return SIMD3<Float>(Float(r), Float(g), Float(b))
    }
}

@Observable
final class LightRig {
    var lights: [PointLight] = [PointLight()]

    /// 레이마칭 두께 — 이 파이프라인에서 가장 위험한 파라미터.
    /// 너무 크면 배경 전체가 그림자로 죽고, 너무 작으면 그림자가 안 생긴다.
    /// (docs/01-architecture.md §7)
    var personThickness: Float = 0.12     // 몸통 ≈ 얼굴폭 × 0.25
    var backgroundThickness: Float = 0.05

    var raymarchSteps: Int = 24
    var ambientOcclusionEnabled = true
    var specularEnabled = true
    var skinRoughness: Float = 0.5

    /// 활성 광원. 핀치가 잡고 있는 대상.
    var activeIndex: Int = 0
    var active: PointLight? {
        get { lights.indices.contains(activeIndex) ? lights[activeIndex] : nil }
        set { if let newValue, lights.indices.contains(activeIndex) { lights[activeIndex] = newValue } }
    }
}
