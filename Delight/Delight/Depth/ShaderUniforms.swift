//
//  ShaderUniforms.swift
//  Shaders/ShaderTypes.h 의 Swift 미러.
//
//  ⚠️ 레이아웃이 어긋나면 런타임에 조용히 쓰레기 값이 들어간다. 컴파일러가 잡아주지 않는다.
//  한쪽을 고치면 반드시 다른 쪽도 고칠 것. 필드 순서까지 같아야 한다.
//

import simd

struct SunLight {
    var position = SIMD3<Float>(0.18, -0.12, 0.45)   // 뷰공간(미터)
    var color    = SIMD3<Float>(1.0, 0.82, 0.62)     // 텅스텐 3200K
    var intensity: Float = 1.6
    var radius: Float = 0.06                          // 페넘브라 폭
}

struct SunUniforms {
    // 카메라 내부파라미터 — macOS는 시스템이 주지 않아 추정한 값이다.
    var fx: Float = 500, fy: Float = 500, cx: Float = 0, cy: Float = 0

    // 상대 역깊이 → 미터로 되돌리는 affine 계수.  z = 1 / (a·d + b)
    // 기본값은 웹캠 사전지식으로 잡았다: d=1(가장 가까움) → 0.35 m, d=0(가장 멂) → 3.0 m.
    // P6에서 배경 앵커 기반 robust fit이 이 값을 매 프레임 갱신한다.
    var affineA: Float = 2.524, affineB: Float = 0.333

    // 깊이 텐서 레이아웃. rowStride는 64바이트 정렬 때문에 width보다 크다.
    var depthWidth: UInt32 = 0, depthHeight: UInt32 = 0, depthRowStride: UInt32 = 0

    var outputWidth: UInt32 = 0, outputHeight: UInt32 = 0

    // 레이마칭.
    var raymarchSteps: UInt32 = 24
    var personThickness: Float = 0.12
    var backgroundThickness: Float = 0.05
    var shadowBias: Float = 0.002

    // 셰이딩.
    var skinRoughness: Float = 0.5
    var detailStrength: Float = 0.4

    // 역광·산란.
    var wrapDiffuse: Float = 0.35
    var rimPower: Float = 3.0
    var translucency: Float = 0.6
    var subjectDepth: Float = 0.6

    var enableAO: UInt32 = 1
    var enableSpecular: UInt32 = 1

    var lightCount: UInt32 = 1
    var lights: (SunLight, SunLight, SunLight, SunLight) = (SunLight(), SunLight(), SunLight(), SunLight())
}
