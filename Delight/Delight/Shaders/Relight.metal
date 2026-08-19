//
//  Relight.metal
//  레이마칭 그림자 + delta lighting + GGX 스펙큘러 + 역광(림·투과).
//
//  왜 "완전 재조명"이 아니라 가산 조명인가:
//  원본 프레임에는 이미 조명이 구워져 있다. 진짜 재조명은 intrinsic 분해가 필요한데
//  그건 실시간이 아니다. 원본을 환경광으로 보존하고 가상 광원의 기여만 더한다 —
//  물리적으로도 실제 스탠드 조명을 켜는 것과 같은 연산이다.
//
//  광원이 피사체 **뒤로** 갈 수 있어야 한다. 그때 일어나야 하는 일:
//    1) 앞면은 어두워진다        → 레이마칭이 자연히 처리한다(광선이 머리 안을 통과)
//    2) 실루엣이 빛난다          → 림라이트
//    3) 귀·머리카락이 비쳐 보인다 → 투과 산란
//    4) 광원 자체가 머리에 가려진다 → 글로우를 씬 깊이로 테스트
//  (docs/01-architecture.md §6, §7)
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
///
/// **thickness가 전부다.** 무한대로 두면 배경 전체가 피사체 뒤로 판정되어 화면이 검게 죽는다.
/// 광원이 피사체 뒤에 있을 때는 광선이 머리 내부를 통과하며 delta가 두께 창 안에 들어와
/// 앞면이 그림자가 된다 — 이게 역광이 성립하는 원리다.
///
/// 광원 반경만큼 광선 방향을 원뿔 지터링해 페넘브라를 만든다.
/// 한 샘플이지만 시간 누적(P6)과 합쳐지면 부드러워진다.
inline float traceShadow(float3 origin,
                         float3 normal,
                         float3 lightPosition,
                         float  lightRadius,
                         texture2d<float, access::sample> positionTex,
                         texture2d<float, access::sample> matteTex,
                         constant SunUniforms &u,
                         uint2 gid)
{
    constexpr sampler pointSampler(filter::nearest, address::clamp_to_edge);

    float jitter = interleavedGradientNoise(gid);

    // 광원 반경만큼 목표점을 흔든다 → 페넘브라. 거리가 멀수록 그림자가 부드러워진다.
    float angle = jitter * 2.0 * kPI;
    float3 tangent = normalize(abs(normal.x) < 0.9 ? cross(normal, float3(1, 0, 0))
                                                   : cross(normal, float3(0, 1, 0)));
    float3 bitangent = cross(normal, tangent);
    float3 target = lightPosition
                  + (tangent * cos(angle) + bitangent * sin(angle)) * lightRadius * jitter;

    // 자기그림자 여드름을 피하려고 노멀 방향으로 살짝 띄운다.
    float3 start = origin + normal * u.shadowBias * 4.0;

    float3 toLight = target - start;
    float distance = length(toLight);
    if (distance < 1e-4) { return 1.0; }
    float3 direction = toLight / distance;

    // 광원이 카메라보다 앞(z <= 0)이면 광선이 화면 밖 공간으로 나간다 — 마칭이 무의미하다.
    if (target.z <= 0.0) { return 1.0; }

    uint steps = max(u.raymarchSteps, 4u);
    float stepLength = distance / float(steps);
    float3 p = start + direction * stepLength * (0.5 + jitter * 0.5);

    for (uint i = 0; i < steps; ++i) {
        float2 uv = projectToScreen(p, u);
        if (any(uv < 0.0) || any(uv > 1.0)) { break; }   // 화면 밖 → 조기 종료

        float sceneZ = positionTex.sample(pointSampler, uv).z;
        if (sceneZ <= 1e-4) { p += direction * stepLength; continue; }

        float matte = matteTex.sample(pointSampler, uv).r;
        float thickness = mix(u.backgroundThickness, u.personThickness, matte);

        float delta = p.z - sceneZ;   // 광선이 씬 표면보다 뒤(멀리)에 있으면 양수
        if (delta > u.shadowBias && delta < thickness) {
            // 광선 진행도에 따라 페이드 — 딱 자르면 경계선이 보인다.
            float progress = float(i) / float(steps);
            return smoothstep(0.85, 1.0, progress);
        }
        p += direction * stepLength;
    }
    return 1.0;
}

/// 실루엣 근접도. 깊이 기울기가 큰 곳 = 얇은 곳(귀·머리카락·어깨선).
inline float estimateThinness(texture2d<float, access::sample> positionTex,
                              float2 uv, constant SunUniforms &u)
{
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float2 texel = 1.0 / float2(u.outputWidth, u.outputHeight);
    float zc = positionTex.sample(linearSampler, uv).z;
    float zx = positionTex.sample(linearSampler, uv + float2(texel.x, 0)).z;
    float zy = positionTex.sample(linearSampler, uv + float2(0, texel.y)).z;
    float gradient = length(float2(zx - zc, zy - zc));
    return saturate(gradient * 40.0);
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

    float3 source   = sourceTex.sample(linearSampler, uv).rgb;
    float3 position = positionTex.sample(linearSampler, uv).xyz;
    float3 normal   = normalize(normalTex.sample(linearSampler, uv).xyz * 2.0 - 1.0);
    float  matte    = matteTex.sample(linearSampler, uv).r;
    float  ao       = u.enableAO ? aoTex.sample(linearSampler, uv).r : 1.0;
    float  thinness = estimateThinness(positionTex, uv, u);

    // pseudo-albedo: 저주파 밝기를 나눠 텍스처만 남긴다(Retinex 근사).
    float sourceLuma = max(luminance(source), 1e-3);
    float3 albedo = source / pow(sourceLuma, 0.7);

    float3 viewDirection = normalize(-position);
    float3 accumulated = float3(0.0);
    float3 glow = float3(0.0);

    for (uint i = 0; i < min(u.lightCount, 4u); ++i) {
        SunLight light = u.lights[i];

        float3 toLight = light.position - position;
        float distance = length(toLight);
        float3 L = toLight / max(distance, 1e-4);

        float attenuation = 1.0 / (1.0 + 2.0 * distance + 4.0 * distance * distance);
        float shadow = traceShadow(position, normal, light.position, light.radius,
                                   positionTex, matteTex, u, gid);

        // --- 확산: 감쌈(wrap) 램버시안. 피부는 표면 아래 산란 때문에 경계가 부드럽다.
        float raw = dot(normal, L);
        float wrapped = saturate((raw + u.wrapDiffuse) / (1.0 + u.wrapDiffuse));
        float3 diffuse = albedo * wrapped * attenuation;

        // --- 스펙큘러: 정면광일 때만 의미가 있다.
        float3 specular = float3(0.0);
        if (u.enableSpecular && raw > 0.0) {
            float3 H = normalize(L + viewDirection);
            float NdotH = saturate(dot(normal, H));
            float VdotH = saturate(dot(viewDirection, H));
            float NdotV = saturate(dot(normal, viewDirection));
            float NdotL = saturate(raw);

            float a = max(u.skinRoughness * u.skinRoughness, 1e-3);
            float a2 = a * a;
            float denominator = NdotH * NdotH * (a2 - 1.0) + 1.0;
            float D = a2 / max(kPI * denominator * denominator, 1e-6);
            float F = kSkinF0 + (1.0 - kSkinF0) * pow(1.0 - VdotH, 5.0);
            float k = a / 2.0;
            float G = (NdotL / (NdotL * (1.0 - k) + k)) * (NdotV / (NdotV * (1.0 - k) + k));

            // 피부에만 얹는다. 옷이나 배경에 뜨면 즉시 가짜티가 난다.
            specular = float3(D * F * G) * matte * attenuation;
        }

        accumulated += (diffuse + specular) * light.color * light.intensity * shadow;

        // --- 역광: 광원이 피사체 뒤로 갔을 때만 켜지는 두 항 ---
        // backness = 1이면 광원이 카메라 반대편, 즉 완전한 역광이다.
        float backness = saturate(-dot(L, viewDirection));

        if (backness > 0.0) {
            // 림라이트: 실루엣에서 빛이 테두리를 훑는다. 그림자에 가려지지 않는다 —
            // 실루엣 픽셀은 정의상 광선이 곧바로 화면을 벗어나기 때문이다.
            float rim = pow(1.0 - saturate(dot(normal, viewDirection)), u.rimPower);
            float3 rimLight = rim * backness * matte * light.color * light.intensity * attenuation;

            // 투과 산란: 얇은 부위(귀·머리카락)로 빛이 새어 나온다.
            // Frostbite 계열의 값싼 근사 — 빛 방향을 노멀로 살짝 왜곡해 뒤에서 본다.
            float3 scatterDirection = normalize(-L + normal * 0.25);
            float scatter = pow(saturate(dot(viewDirection, scatterDirection)), 4.0);
            float3 transmission = scatter * thinness * matte * u.translucency
                                * light.color * light.intensity * attenuation;

            accumulated += rimLight + transmission;
        }

        // --- 광원 글로우: 씬 깊이로 테스트해 머리 뒤로 가면 사라진다.
        // "뒤로 넘겼다"를 눈으로 확인시켜 주는 장치다.
        if (light.position.z > 0.0) {
            float2 lightUV = projectToScreen(light.position, u);
            float2 delta = (uv - lightUV) * float2(float(u.outputWidth) / float(u.outputHeight), 1.0);
            float d = length(delta);
            float sceneZ = position.z;
            bool visible = (light.position.z < sceneZ + u.shadowBias) || sceneZ <= 1e-4;
            if (visible) {
                glow += exp(-d * d * 900.0) * light.color * light.intensity * 0.9;
            }
        }
    }

    float3 result = source * mix(1.0, ao, 0.6) + accumulated + glow;

    // ACES 근사 톤매핑 — 가산 조명이라 클리핑 방지는 선택이 아니다.
    const float A = 2.51, B = 0.03, C = 2.43, D = 0.59, E = 0.14;
    result = saturate((result * (A * result + B)) / (result * (C * result + D) + E));

    outputTex.write(float4(result, 1.0), gid);
}
