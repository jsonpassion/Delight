//
//  ShaderTypes.h
//  Metal 셰이더가 공유하는 구조체.
//  Swift 미러는 Depth/ShaderUniforms.swift 에 있다 — **레이아웃이 반드시 일치해야 한다.**
//  한쪽만 고치면 런타임에 조용히 쓰레기 값이 들어간다. 컴파일러가 잡아주지 않는다.
//

#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

typedef struct {
    simd_float3 position;    // 뷰공간(미터). z가 클수록 카메라에서 멀다.
    simd_float3 color;
    float       intensity;
    float       radius;      // 광원 반경(미터). 페넘브라 폭을 결정한다.
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

    // 역광·산란 — 광원이 피사체 뒤로 갔을 때의 사실감을 만든다.
    float wrapDiffuse;         // 램버시안 감쌈 정도(피부는 0.3~0.5)
    float rimPower;            // 실루엣 림라이트 날카로움
    float translucency;        // 얇은 부위(귀·머리카락) 투과 산란 세기
    float subjectDepth;        // 피사체 기준 깊이(미터). 광원 z의 기준점.

    uint  enableAO;
    uint  enableSpecular;
    uint  hasSegmentation;   // 0이면 깊이 기반 근사 매트로 폴백

    // 깊이 안정화.
    uint  historyValid;      // 첫 프레임에는 히스토리가 없다
    float temporalBlend;     // 히스토리 비중
    float colorSigma;        // 색 변화 허용폭. 크면 고스팅, 작으면 떨림
    float depthSigma;        // 깊이 변화 허용폭

    uint  lightCount;
    SunLight lights[4];
} SunUniforms;


// Swift 미러(Depth/ShaderUniforms.swift)와 레이아웃이 어긋나면 **여기서 빌드가 깨진다.**
// 런타임에 조용히 쓰레기 값이 들어가는 것보다 낫다.
// 값을 바꿔야 한다면 Swift 쪽 MemoryLayout<...>.stride 를 찍어 확인할 것.
#ifdef __METAL_VERSION__
static_assert(sizeof(SunLight)    == 48,  "SunLight 레이아웃이 Swift 미러와 다르다");
static_assert(sizeof(SunUniforms) == 320, "SunUniforms 레이아웃이 Swift 미러와 다르다");
#endif

#endif /* ShaderTypes_h */
