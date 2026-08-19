//
//  Relight.metal
//  레이마칭 그림자 + delta lighting + GGX 스펙큘러.
//
//  왜 "완전 재조명"이 아니라 가산 조명인가:
//  원본 프레임에는 이미 조명이 구워져 있다. 진짜 재조명은 intrinsic 분해가 필요한데
//  그건 실시간이 아니다. 원본을 환경광으로 보존하고 가상 광원의 기여만 더한다 —
//  물리적으로도 실제 스탠드 조명을 켜는 것과 같은 연산이다.
//  (docs/01-architecture.md §6)
//

#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

constant float kPI = 3.14159265359;
/// 피부의 수직 입사 반사율.
constant float kSkinF0 = 0.028;

inline float luminance(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

/// 뷰공간 점을 정규화 화면좌표로 투영한다.
inline float2 projectToScreen(float3 p, constant SunUniforms &u)
{
    float2 pixel = float2(p.x * u.fx / max(p.z, 1e-4) + u.cx,
                          p.y * u.fy / max(p.z, 1e-4) + u.cy);
    return pixel / float2(u.outputWidth, u.outputHeight);
}

/// 블루노이즈 대용. 밴딩을 깨는 게 목적이라 통계적 품질은 덜 중요하다.
inline float interleavedGradientNoise(uint2 gid)
{
    return fract(52.9829189 * fract(dot(float2(gid), float2(0.06711056, 0.00583715))));
}

/// 화면공간 높이장 레이마칭.
/// **thickness가 전부다.** 무한대로 두면 배경 전체가 사람 뒤로 판정되어 화면이 검게 죽는다.
inline float traceShadow(float3 origin,
                         float3 lightPosition,
                         texture2d<float, access::sample> positionTex,
                         texture2d<float, access::sample> matteTex,
                         constant SunUniforms &u,
                         uint2 gid)
{
    constexpr sampler pointSampler(filter::nearest, address::clamp_to_edge);

    float3 toLight = lightPosition - origin;
    float distance = length(toLight);
    if (distance < 1e-4) { return 1.0; }
    float3 direction = toLight / distance;

    // 광원이 카메라보다 뒤에 있으면 광선이 시작부터 화면 뒤로 간다 → 마칭이 무의미.
    // 이 경우 그림자를 포기하고 N·L만으로 림라이트를 만든다.
    if (lightPosition.z <= 0.0) { return 1.0; }

    uint steps = max(u.raymarchSteps, 4u);
    float stepLength = distance / float(steps);
    float jitter = interleavedGradientNoise(gid);
    float3 p = origin + direction * stepLength * (0.5 + jitter * 0.5);

    for (uint i = 0; i < steps; ++i) {
        float2 uv = projectToScreen(p, u);
        if (any(uv < 0.0) || any(uv > 1.0)) { break; }   // 화면 밖 → 조기 종료

        float sceneZ = positionTex.sample(pointSampler, uv).z;
        if (sceneZ <= 1e-4) { p += direction * stepLength; continue; }

        float matte = matteTex.sample(pointSampler, uv).r;
        float thickness = mix(u.backgroundThickness, u.personThickness, matte);

        float delta = p.z - sceneZ;   // 광선이 씬 표면보다 뒤에 있으면 양수
        if (delta > u.shadowBias && delta < thickness) {
            // 광선 진행도에 따라 페이드 — 딱 자르면 경계선이 보인다.
            float progress = float(i) / float(steps);
            return smoothstep(0.8, 1.0, progress);
        }
        p += direction * stepLength;
    }
    return 1.0;
}

kernel void relight(texture2d<float, access::sample> sourceTex   [[texture(0)]],
                    texture2d<float, access::sample> positionTex [[texture(1)]],
                    texture2d<float, access::sample> normalTex   [[texture(2)]],
                    texture2d<float, access::sample> matteTex    [[texture(3)]],
                    texture2d<float, access::sample> aoTex       [[texture(4)]],
                    texture2d<float, access::write>  outputTex   [[texture(5)]],
                    constant SunUniforms            &u           [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.outputWidth || gid.y >= u.outputHeight) { return; }

    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(u.outputWidth, u.outputHeight);

    float3 source = sourceTex.sample(linearSampler, uv).rgb;
    float3 position = positionTex.sample(linearSampler, uv).xyz;
    float3 normal = normalize(normalTex.sample(linearSampler, uv).xyz * 2.0 - 1.0);
    float  matte = matteTex.sample(linearSampler, uv).r;
    float  ao = u.enableAO ? aoTex.sample(linearSampler, uv).r : 1.0;

    // pseudo-albedo: 저주파 밝기를 나눠서 텍스처만 남긴다(Retinex 근사).
    // 완전한 intrinsic 분해가 아니라 가산 조명을 얹기 위한 근사다.
    float sourceLuma = max(luminance(source), 1e-3);
    float3 albedo = source / pow(sourceLuma, 0.7);

    float3 viewDirection = normalize(-position);
    float3 accumulated = float3(0.0);

    for (uint i = 0; i < min(u.lightCount, 4u); ++i) {
        SunLight light = u.lights[i];

        float3 toLight = light.position - position;
        float distance = length(toLight);
        float3 L = toLight / max(distance, 1e-4);

        float NdotL = saturate(dot(normal, L));
        if (NdotL <= 0.0) { continue; }

        float attenuation = 1.0 / (1.0 + 2.0 * distance + 4.0 * distance * distance);
        float shadow = traceShadow(position, light.position, positionTex, matteTex, u, gid);

        float3 diffuse = albedo * NdotL * attenuation;

        float3 specular = float3(0.0);
        if (u.enableSpecular) {
            float3 H = normalize(L + viewDirection);
            float NdotH = saturate(dot(normal, H));
            float VdotH = saturate(dot(viewDirection, H));
            float NdotV = saturate(dot(normal, viewDirection));

            float a = max(u.skinRoughness * u.skinRoughness, 1e-3);
            float a2 = a * a;

            float denominator = NdotH * NdotH * (a2 - 1.0) + 1.0;
            float D = a2 / max(kPI * denominator * denominator, 1e-6);
            float F = kSkinF0 + (1.0 - kSkinF0) * pow(1.0 - VdotH, 5.0);

            float k = a / 2.0;
            float G = (NdotL / (NdotL * (1.0 - k) + k)) * (NdotV / (NdotV * (1.0 - k) + k));

            // 피부에만 스펙큘러를 얹는다. 옷이나 배경에 뜨면 즉시 가짜티가 난다.
            specular = float3(D * F * G) * matte * attenuation;
        }

        accumulated += (diffuse + specular) * light.color * light.intensity * shadow;
    }

    float3 result = source * mix(1.0, ao, 0.6) + accumulated;

    // ACES 근사 톤매핑 — 클리핑 방지는 선택이 아니라 필수다.
    const float A = 2.51, B = 0.03, C = 2.43, D = 0.59, E = 0.14;
    result = saturate((result * (A * result + B)) / (result * (C * result + D) + E));

    outputTex.write(float4(result, 1.0), gid);
}
