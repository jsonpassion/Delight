//
//  Relight.metal
//  높이장을 재조명한다. 그림자는 POM 방식 레이마칭으로 얻는다.
//
//  ── 아키텍처 ──
//  깊이 → 높이장 재투영 → 높이장 조명 → 재구성된 씬 위 레이마칭(POM 유사)
//
//  광선을 뷰공간에서 진행시키고 매 스텝 화면에 재투영하는 대신,
//  **텍스처 공간에서 직선으로** 진행한다. 스텝당 나눗셈 두 번과
//  좌표 변환이 통째로 사라지고, 남는 것은 텍스처 페치 한 번뿐이다.
//  이것이 시차 폐색 매핑이 오랫동안 써온 성질이고, 속도가 여기서 나온다.
//
//  가산 조명(delta lighting)인 이유:
//  원본 프레임에는 이미 조명이 구워져 있다. 완전 재조명은 intrinsic 분해가 필요하고
//  그건 실시간이 아니다. 원본을 환경광으로 두고 가상 광원의 기여만 더한다 —
//  방에 스탠드 하나를 켜는 것과 같은 연산이다.
//

#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

constant float kPI = 3.14159265359;
/// 피부의 수직 입사 반사율.
constant float kSkinF0 = 0.028;

inline float luminance(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

/// 카메라 텍스처는 sRGB로 인코딩되어 있다. 조명은 선형 공간에서 더해야 한다.
inline float3 srgbToLinear(float3 c)
{
    return select(c / 12.92, pow((c + 0.055) / 1.055, 2.4), c > 0.04045);
}
inline float3 linearToSrgb(float3 c)
{
    c = max(c, 0.0);
    return select(c * 12.92, 1.055 * pow(c, 1.0 / 2.4) - 0.055, c > 0.0031308);
}

/// GGX 정규분포. 이중 로브를 만들려고 따로 뺐다.
inline float ggx(float NdotH, float roughness)
{
    float a = max(roughness * roughness, 1e-3);
    float a2 = a * a;
    float d = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / max(kPI * d * d, 1e-6);
}

/// 밴딩을 깨는 지터. 통계적 품질보다 값이 싼 것이 중요하다.
inline float dither(uint2 gid)
{
    return fract(52.9829189 * fract(dot(float2(gid), float2(0.06711056, 0.00583715))));
}

/// 높이장 위 레이마칭 그림자 — POM 셀프섀도잉과 같은 알고리즘.
///
/// 광원 방향을 텍스처 공간 이동량(uvStep)과 높이 변화량(heightStep)으로 분해하고
/// 직선으로 진행한다. **투영이 없다.**
///
/// thickness가 이 파이프라인에서 가장 위험한 파라미터다.
/// 높이장은 2.5D라 물체의 뒤쪽을 모른다. 창이 너무 크면 배경 전체가
/// 피사체 뒤로 판정되어 화면이 검게 죽고, 작으면 그림자가 아예 안 생긴다.
inline float traceShadow(float2 startUV,
                         float startHeight,
                         float3 lightDirection,   // 텍스처 공간 (xy = uv, z = 높이)
                         float coverage,
                         texture2d<float, access::sample> heightField,
                         constant SunUniforms &u,
                         uint2 gid)
{
    // 광원이 표면 아래를 향하면 애초에 빛이 닿지 않는다.
    if (lightDirection.z <= 0.0) { return 1.0; }

    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);

    uint steps = max(u.raymarchSteps, 4u);
    float travel = u.shadowReach / float(steps);
    float2 uvStep = lightDirection.xy * travel;
    // 높이는 [0,1]로 정규화되어 있으므로 uv와 같은 비율로 되돌려 기울기를 맞춘다.
    float heightStep = lightDirection.z * travel / max(u.heightToUV, 1e-4);

    float jitter = dither(gid);
    float2 uv = startUV + uvStep * jitter;
    float rayHeight = startHeight + heightStep * jitter;

    float thickness = mix(u.backgroundThickness, u.personThickness, coverage);

    for (uint i = 0; i < steps; ++i) {
        uv += uvStep;
        rayHeight += heightStep;

        if (any(uv < 0.0) || any(uv > 1.0)) { break; }   // 높이장 밖 → 조기 종료

        float sceneHeight = heightField.sample(linearSampler, uv).r;
        float delta = sceneHeight - rayHeight;   // 씬이 광선보다 위로 솟아 있으면 양수

        // bias 없이 delta > 0만 보면 평평한 면에서도 수치 오차로 자기그림자가 생긴다.
        // 먼 배경(높이가 거의 0인 평면)에서 블록 단위로 검게 죽는 원인이었다.
        if (delta > u.shadowBias && delta < thickness) {
            // 끝에서 딱 자르면 경계선이 보인다. 진행도에 따라 풀어준다.
            return smoothstep(0.85, 1.0, float(i) / float(steps));
        }
    }
    return 1.0;
}

/// 높이장 위 앰비언트 오클루전. 여러 방향으로 짧게 마칭해 하늘이 얼마나 열렸는지 센다.
/// 턱밑·목·코 옆의 접촉 그늘을 만든다 — 광원과 무관하게 항상 입체감을 올린다.
inline float ambientOcclusion(float2 uv, float height,
                              texture2d<float, access::sample> heightField,
                              constant SunUniforms &u, uint2 gid)
{
    if (u.enableAO == 0) { return 1.0; }

    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    // 출력 해상도가 2.4M 픽셀이다. 방향×스텝을 늘리면 그대로 곱해져 비용이 커진다.
    // AO는 저주파 신호라 적은 샘플에 지터를 섞는 편이 낫다.
    const uint directions = 4;
    const uint stepsPerDirection = 3;
    float reach = u.shadowReach * 0.25;
    float jitter = dither(gid);

    float occlusion = 0.0;
    for (uint d = 0; d < directions; ++d) {
        float angle = (float(d) + jitter) / float(directions) * 2.0 * kPI;
        float2 direction = float2(cos(angle), sin(angle)) * (reach / float(stepsPerDirection));

        float horizon = 0.0;
        float2 p = uv;
        for (uint s = 1; s <= stepsPerDirection; ++s) {
            p += direction;
            if (any(p < 0.0) || any(p > 1.0)) { break; }
            float rise = (heightField.sample(linearSampler, p).r - height) / max(u.heightToUV, 1e-4);
            // 거리로 나눈 기울기가 곧 지평선 각도다. 가장 높이 솟은 것이 가린다.
            horizon = max(horizon, rise / (float(s) * reach / float(stepsPerDirection)));
        }
        occlusion += saturate(horizon);
    }
    return saturate(1.0 - occlusion / float(directions) * u.aoStrength);
}

kernel void relight(texture2d<float, access::sample> sourceTex   [[texture(0)]],
                    texture2d<float, access::sample> heightField [[texture(1)]],
                    texture2d<float, access::sample> normalTex   [[texture(2)]],
                    texture2d<float, access::write>  outputTex   [[texture(3)]],
                    constant SunUniforms            &u           [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.outputWidth || gid.y >= u.outputHeight) { return; }

    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(u.outputWidth, u.outputHeight);

    float3 source = sourceTex.sample(linearSampler, uv).rgb;
    float3 linearSource = srgbToLinear(source);

    float2 field = heightField.sample(linearSampler, uv).rg;
    float height = field.r;
    float coverage = field.g;
    float3 normal = normalize(normalTex.sample(linearSampler, uv).xyz * 2.0 - 1.0);

    // albedo 프록시는 원본 그대로다. 가산 조명에서는 밝은 표면이 더 반사하는 게 옳다.
    float3 albedo = linearSource;
    // 높이장 공간의 시선은 화면을 정면으로 본다.
    const float3 viewDirection = float3(0, 0, 1);

    float ao = ambientOcclusion(uv, height, heightField, u, gid);
    float3 accumulated = float3(0.0);
    float3 glow = float3(0.0);

    for (uint i = 0; i < min(u.lightCount, 4u); ++i) {
        SunLight light = u.lights[i];

        // 광원도 높이장 공간에 있다. xy는 화면 위치, z는 높이.
        // 높이 성분을 uv와 같은 비율로 되돌려야 방향과 거리가 물리적으로 맞다.
        float3 toLight = float3(light.position.xy - uv,
                                (light.position.z - height) / max(u.heightToUV, 1e-4));
        float distance = length(toLight);
        float3 L = toLight / max(distance, 1e-4);

        // 거리는 uv 단위(화면 폭 = 1)다. 미터 기준 계수를 쓰면 기여가 0에 수렴해
        // 화면이 통째로 검게 죽는다 — 실제로 그렇게 만들었다.
        float attenuation = 1.0 / (1.0 + 1.5 * distance + 2.5 * distance * distance);
        float shadow = traceShadow(uv, height, L, coverage, heightField, u, gid);

        // ── 확산: 감쌈 램버시안. 피부는 표면 아래 산란 때문에 경계가 부드럽다.
        float raw = dot(normal, L);
        float wrapped = saturate((raw + u.wrapDiffuse) / (1.0 + u.wrapDiffuse));
        float3 diffuse = albedo * wrapped * attenuation;

        // ── 스펙큘러: 구 면광원 + 이중 로브.
        // 점광원으로 계산하면 하이라이트가 흰 dot이 된다. 실제 조명은 면적을 가진다.
        float3 specular = float3(0.0);
        if (u.enableSpecular && raw > 0.0) {
            float3 reflectDir = reflect(-viewDirection, normal);
            float3 centerToRay = dot(toLight, reflectDir) * reflectDir - toLight;
            float3 closest = toLight
                + centerToRay * saturate(light.radius / max(length(centerToRay), 1e-4));
            float3 specL = normalize(closest);

            float3 H = normalize(specL + viewDirection);
            float NdotH = saturate(dot(normal, H));
            float VdotH = saturate(dot(viewDirection, H));
            float NdotV = saturate(dot(normal, viewDirection));
            float NdotL = saturate(dot(normal, specL));

            float widen = saturate(light.radius / (2.0 * max(distance, 1e-3)));
            float roughness = saturate(max(u.skinRoughness, 0.08) + widen);
            float energy = 1.0 / (1.0 + widen * 4.0);   // 넓어진 만큼 어두워져야 한다

            // 피부는 얇은 기름막(좁고 밝음)과 그 아래 층(넓고 흐림)이 겹쳐 반사한다.
            float D = mix(ggx(NdotH, roughness * 1.6), ggx(NdotH, roughness * 0.7), 0.35);
            float F = kSkinF0 + (1.0 - kSkinF0) * pow(1.0 - VdotH, 5.0);
            float a = roughness * roughness, k = a / 2.0;
            float G = (NdotL / max(NdotL * (1.0 - k) + k, 1e-4))
                    * (NdotV / max(NdotV * (1.0 - k) + k, 1e-4));

            specular = float3(D * F * G) * energy * coverage * attenuation;
        }

        accumulated += (diffuse + specular) * light.color * light.intensity * shadow;

        // ── 역광: 광원이 피사체 뒤(높이가 낮은 쪽)로 갔을 때만 켜진다.
        float backness = saturate(-L.z);
        if (backness > 0.0) {
            float rim = pow(1.0 - saturate(normal.z), u.rimPower);
            accumulated += rim * backness * coverage
                         * light.color * light.intensity * attenuation;
        }

        // ── 광원 글로우: 높이로 가려지면 사라진다.
        // "뒤로 넘겼다"를 눈으로 확인시켜 주는 장치다.
        if (light.position.z > height) {
            float2 delta = (uv - light.position.xy)
                         * float2(float(u.outputWidth) / float(u.outputHeight), 1.0);
            glow += exp(-dot(delta, delta) * 900.0) * light.color * light.intensity * 0.9;
        }
    }

    // 진단 스위치 — 어느 항이 화면을 죽이는지 격리한다.
    if (u.debugMode == 1) { outputTex.write(float4(source, 1), gid); return; }
    if (u.debugMode == 2) { outputTex.write(float4(ao, ao, ao, 1), gid); return; }
    if (u.debugMode == 3) { outputTex.write(float4(height, height, height, 1), gid); return; }
    if (u.debugMode == 4) { outputTex.write(float4(normal * 0.5 + 0.5, 1), gid); return; }

    float3 result = linearSource * mix(1.0, ao, 0.6) + accumulated + glow;

    // 소프트 클립 — 1 이하는 원본 그대로 통과시키고 넘치는 부분만 눌러 담는다.
    float peak = luminance(result);
    if (peak > 1.0) { result /= (1.0 + (peak - 1.0)); }

    outputTex.write(float4(linearToSrgb(result), 1.0), gid);
}
