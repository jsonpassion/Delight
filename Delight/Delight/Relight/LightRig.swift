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
    ///
    /// ⚠️ didSet 안에서 자기 자신을 클램프하면 안 된다 — @Observable 매크로가
    /// 프로퍼티를 computed로 바꾸므로 재대입이 didSet을 무한 재귀시켜
    /// 스택 오버플로로 크래시한다(실제 크래시 리포트로 확인). 클램프는 쓰는 쪽에서.
    var depthOffset: Float = -0.15
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

    // MARK: 깊이 안정화
    /// 히스토리 비중. 0이면 안정화 off — A/B 비교에 그대로 쓴다.
    var temporalBlend: Float = 0.85
    /// 색 변화 허용폭. 크면 고스팅, 작으면 떨림이 남는다.
    var colorSigma: Float = 0.012
    var depthSigma: Float = 0.05

    /// 광원이 손끝보다 얼마나 카메라 쪽에 놓이는가(미터).
    /// 0이면 손 안에 파묻혀 보이지 않는다. 항상 손 앞에 떠 있어야 "잡았다"가 성립한다.
    static let handLeadDistance: Float = 0.07

    /// 핀치를 막 시작했을 때 광원이 손끝으로 날아가는 속도(프레임당 보간율).
    /// 낮을수록 부드럽지만 굼뜨다. 0.28이면 30fps에서 약 0.2초에 붙는다.
    private static let snapRate: Float = 0.28
    /// 핀치 유지 중 추종 속도. 손을 즉각 따라가야 "잡고 있다"는 감각이 산다.
    private static let followRate: Float = 0.65

    /// 직전 프레임에 핀치 중이었는가. 잡는 순간을 감지해 애니메이션을 시작한다.
    private var wasPinching = false

    /// 핀치 시작 시점의 손 크기와 그때 깊이맵이 말한 거리.
    /// 이후에는 이 기준으로 손 크기 변화만 보고 거리를 추적한다.
    private var referenceHandScale: Float = 0
    private var referenceHandZ: Float = 0

    /// 마지막으로 확정한 손 거리(미터). 손을 놓쳐도 이 값을 유지해 조명이 튀지 않는다.
    private(set) var trackedHandZ: Float = 0.5

    /// 광원이 켜져 있는가.
    ///
    /// 핀치를 놓으면 즉시 끈다. 손을 놓았는데 광원이 마지막 자리에 남아 있으면,
    /// 그 자리가 손등 뒤나 얼굴 속일 때 "왜 저기 박혀 있지"가 된다.
    /// 잡고 있을 때만 존재하게 하면 그 상태 자체가 사라진다.
    var isLit = true

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
    ///   - affine: 역깊이를 미터로 되돌리는 계수. 손 깊이를 실제 거리로 환산할 때 쓴다.
    ///   - isGrabbing: 핀치로 잡고 있는가. 잡는 순간이면 손끝으로 날아가는 애니메이션이 걸린다.
    func place(normalized: SIMD2<Float>,
               handDepth: Float?,
               calibration: CameraCalibration,
               pixelSize: SIMD2<Float>,
               affine: SIMD2<Float> = SIMD2<Float>(2.524, 0.333),
               isGrabbing: Bool = false,
               handScale: Float = 0) {
        guard lights.indices.contains(activeIndex) else { return }

        if let handDepth {
            let handZ = resolveHandDistance(inverseDepth: handDepth,
                                            handScale: handScale,
                                            isGrabbing: isGrabbing,
                                            affine: affine)
            trackedHandZ = handZ
            // 광원은 손보다 **카메라 쪽**에 놓는다.
            // 손 뒤에 두면 손에 가려 보이지 않는다 — 잡고 있다는 감각이 사라진다.
            let lightZ = max(handZ - Self.handLeadDistance, 0.08)
            depthOffset = min(max(lightZ - subjectDepth, Self.nearestOffset), Self.farthestOffset)
        }

        let z = max(subjectDepth + depthOffset, 0.05)
        let px = normalized.x * pixelSize.x
        let py = normalized.y * pixelSize.y
        let target = SIMD3<Float>(
            (px - calibration.cx) / calibration.fx * z,
            (py - calibration.cy) / calibration.fy * z,
            z)

        // 잡는 순간에는 천천히 날아가고, 잡고 있는 동안에는 즉각 따라간다.
        // 마우스(isGrabbing = false)는 보간 없이 바로 놓는다 — 커서가 곧 광원이다.
        if isGrabbing {
            let rate = wasPinching ? Self.followRate : Self.snapRate
            lights[activeIndex].position = mix(lights[activeIndex].position, target, t: rate)
        } else {
            lights[activeIndex].position = target
        }
        wasPinching = isGrabbing
    }

    /// 핀치를 놓았을 때 호출한다. 다음 핀치가 다시 "날아오는" 애니메이션으로 시작한다.
    func releaseGrab() {
        wasPinching = false
        referenceHandScale = 0      // 다음 핀치에서 다시 캘리브레이션한다
    }

    /// 손까지의 거리를 미터로 정한다.
    ///
    /// **왜 깊이맵만 쓰면 안 되는가.**
    /// 손을 머리 뒤로 가져가면 깊이맵의 그 픽셀은 손이 아니라 **머리**를 가리킨다.
    /// 그대로 쓰면 광원이 머리 앞에 붙어 고정된다 — 뒤로 보내려는 의도와 정반대다.
    /// 2.5D 깊이맵의 근본 한계이지 튜닝으로 풀 수 있는 문제가 아니다.
    ///
    /// 그래서 **가림에 영향받지 않는 손 크기**를 주 신호로 쓴다.
    /// 손 크기는 1/Z에 비례하므로, 핀치 시작 시 깊이맵으로 스케일을 한 번 맞춰 두면
    /// 이후에는 크기 변화만으로 거리를 추적할 수 있다.
    private func resolveHandDistance(inverseDepth: Float,
                                     handScale: Float,
                                     isGrabbing: Bool,
                                     affine: SIMD2<Float>) -> Float {
        let depthZ = 1 / max(affine.x * min(max(inverseDepth, 0), 1) + affine.y, 1e-3)

        // 손 크기를 못 읽으면 깊이맵으로 폴백한다(손이 프레임 경계에 걸린 경우 등).
        guard handScale > 0.01 else { return depthZ }

        // 핀치 시작 순간에만 깊이맵을 믿는다. 이때는 손이 앞에 나와 있어 가려질 일이 없다.
        if !isGrabbing || referenceHandScale <= 0 {
            referenceHandScale = handScale
            referenceHandZ = depthZ
            return depthZ
        }

        // 이후에는 크기 변화만 본다. 손이 작아 보이면 멀어진 것이다 — 가려져 있어도 성립한다.
        let scaleRatio = referenceHandScale / max(handScale, 1e-4)
        let estimated = referenceHandZ * scaleRatio
        return min(max(estimated, 0.15), 3.0)
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
        uniforms.temporalBlend = temporalBlend
        uniforms.colorSigma = colorSigma
        uniforms.depthSigma = depthSigma
        uniforms.enableAO = ambientOcclusionEnabled ? 1 : 0
        uniforms.enableSpecular = specularEnabled ? 1 : 0

        let enabled = isLit ? Array(lights.filter(\.isEnabled).prefix(4)) : []
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
