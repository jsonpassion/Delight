//
//  LightRig.swift
//  광원은 처음부터 배열이다. 키 + 필 2개만 되어도 품질이 확 오른다.
//
//  ★ 광원 z는 **피사체 깊이를 기준으로** 정한다.
//    피사체보다 앞이면 정면광, 뒤면 역광이다.
//    절대 좌표로 두면 사람이 조금만 움직여도 조명이 얼굴 속으로 들어간다.
//

import Foundation
import simd
import Observation

struct PointLight: Identifiable, Equatable {
    let id = UUID()
    /// 뷰공간 위치(미터). z가 클수록 카메라에서 멀다.
    var position: SIMD3<Float> = .init(0.18, -0.12, 0.45)
    var color: SIMD3<Float> = .init(1.0, 0.82, 0.62)   // 텅스텐 3200K
    var intensity: Float = 1.6
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

    /// 깊이맵에서 읽은 피사체(얼굴) 기준 깊이. 광원 z의 원점이다.
    var subjectDepth: Float = 0.6

    /// 광원이 피사체 기준으로 얼마나 앞/뒤에 있는가. 음수 = 카메라 쪽(정면광).
    /// 이 범위가 "얼굴 앞에도, 뒤로도" 를 성립시킨다.
    var depthOffset: Float = -0.15 {
        didSet { depthOffset = min(max(depthOffset, Self.nearestOffset), Self.farthestOffset) }
    }
    static let nearestOffset: Float = -0.35   // 카메라 바로 앞
    static let farthestOffset: Float =  0.90  // 피사체 한참 뒤 → 완전한 역광

    /// 광원이 피사체 뒤에 있는가. UI 표시와 그림자 강도 힌트에 쓴다.
    var isBehindSubject: Bool { depthOffset > 0.02 }

    /// 역광 정도 0…1. 0 = 정면광, 1 = 완전한 역광.
    var backlightAmount: Float {
        guard depthOffset > 0 else { return 0 }
        return min(depthOffset / Self.farthestOffset, 1)
    }

    // MARK: 레이마칭

    /// **가장 위험한 파라미터.** 크면 화면이 검게 죽고, 작으면 그림자가 안 생긴다.
    var personThickness: Float = 0.12     // 몸통 ≈ 얼굴폭 × 0.25
    var backgroundThickness: Float = 0.05
    var raymarchSteps: Int = 24

    // MARK: 셰이딩

    var ambientOcclusionEnabled = true
    var specularEnabled = true
    var skinRoughness: Float = 0.5
    /// 피부는 표면 아래 산란 때문에 명암 경계가 부드럽다.
    var wrapDiffuse: Float = 0.35
    /// 실루엣 림라이트 날카로움. 낮을수록 넓게 번진다.
    var rimPower: Float = 3.0
    /// 귀·머리카락 같은 얇은 부위의 투과 산란.
    var translucency: Float = 0.6
    var detailStrength: Float = 0.4

    /// 활성 광원. 핀치가 잡고 있는 대상.
    var activeIndex: Int = 0
    var active: PointLight? {
        get { lights.indices.contains(activeIndex) ? lights[activeIndex] : nil }
        set { if let newValue, lights.indices.contains(activeIndex) { lights[activeIndex] = newValue } }
    }

    /// 핀치(또는 마우스)의 화면 위치와 깊이를 광원의 뷰공간 좌표로 옮긴다.
    ///
    /// - Parameters:
    ///   - normalized: 화면 정규화 좌표(좌상단 원점)
    ///   - handDepth: 손에서 읽은 정규화 역깊이(1에 가까울수록 카메라에 가까움). nil이면 z 유지.
    ///   - calibration: 초점거리 추정치
    ///   - pixelSize: 출력 해상도
    func place(normalized: SIMD2<Float>,
               handDepth: Float?,
               calibration: CameraCalibration,
               pixelSize: SIMD2<Float>) {
        guard lights.indices.contains(activeIndex) else { return }

        if let handDepth {
            // 손이 카메라에 가까울수록(역깊이 큼) 광원을 앞으로 당긴다.
            // 손을 멀리 뻗으면 광원이 얼굴 뒤로 넘어가 역광이 된다.
            let t = 1 - min(max(handDepth, 0), 1)             // 0 = 가까움, 1 = 멂
            depthOffset = Self.nearestOffset
                        + t * (Self.farthestOffset - Self.nearestOffset)
        }

        let z = max(subjectDepth + depthOffset, 0.05)
        let px = normalized.x * pixelSize.x
        let py = normalized.y * pixelSize.y
        lights[activeIndex].position = SIMD3<Float>(
            (px - calibration.cx) / calibration.fx * z,
            (py - calibration.cy) / calibration.fy * z,
            z)
    }

    /// 셰이더 유니폼에 현재 상태를 싣는다.
    func fill(_ uniforms: inout SunUniforms) {
        uniforms.personThickness = personThickness
        uniforms.backgroundThickness = backgroundThickness
        uniforms.raymarchSteps = UInt32(raymarchSteps)
        uniforms.skinRoughness = skinRoughness
        uniforms.detailStrength = detailStrength
        uniforms.wrapDiffuse = wrapDiffuse
        uniforms.rimPower = rimPower
        uniforms.translucency = translucency
        uniforms.subjectDepth = subjectDepth
        uniforms.enableAO = ambientOcclusionEnabled ? 1 : 0
        uniforms.enableSpecular = specularEnabled ? 1 : 0

        let enabled = lights.filter(\.isEnabled).prefix(4)
        uniforms.lightCount = UInt32(enabled.count)
        var packed = [SunLight](repeating: SunLight(), count: 4)
        for (index, light) in enabled.enumerated() {
            packed[index] = SunLight(position: light.position,
                                     color: light.color,
                                     intensity: light.intensity,
                                     radius: light.radius)
        }
        uniforms.lights = (packed[0], packed[1], packed[2], packed[3])
    }
}
