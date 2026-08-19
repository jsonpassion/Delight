//
//  ShaderTypes.h
//  Metal 셰이더가 공유하는 구조체.
//  Swift 쪽 미러는 Relight/ShaderUniforms.swift 에 있다 — **레이아웃이 반드시 일치해야 한다.**
//

#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

typedef struct {
    simd_float3 position;    // 뷰공간(미터)
    simd_float3 color;
    float       intensity;
    float       radius;
} SunLight;

typedef struct {
    // 카메라 내부파라미터 — macOS는 시스템이 주지 않아 추정한 값이다.
    float fx, fy, cx, cy;

    // 상대 역깊이 → 미터로 되돌리는 affine 계수.
    float affineA, affineB;

    // 깊이 텐서 레이아웃. rowStride는 64바이트 정렬 때문에 width보다 크다.
    uint  depthWidth, depthHeight, depthRowStride;

    // 출력 해상도.
    uint  outputWidth, outputHeight;

    // 레이마칭.
    uint  raymarchSteps;
    float personThickness;
    float backgroundThickness;
    float shadowBias;

    // 셰이딩.
    float skinRoughness;
    float detailStrength;      // 루마 고주파 → 노멀 주입량
    uint  enableAO;
    uint  enableSpecular;

    uint  lightCount;
    SunLight lights[4];
} SunUniforms;

#endif /* ShaderTypes_h */
