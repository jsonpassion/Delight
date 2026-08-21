//
//  HeightField.metal
//  깊이맵 → 높이장(height map) 재투영.
//
//  아키텍처의 핵심 결정: 씬을 **3D 점구름이 아니라 2D 높이장**으로 다룬다.
//
//  점구름으로 다루면 광선을 뷰공간에서 진행시키고 매 스텝 화면에 재투영해야 한다
//  (스텝당 나눗셈 2회). 높이장으로 다루면 광선이 텍스처 공간에서 직선으로 가므로
//  투영이 사라진다 — 시차 폐색 매핑(POM)이 쓰는 바로 그 성질이다.
//
//  재투영이 하는 일은 스케일을 맞추는 것이다.
//  화면 uv 1단위가 실제 몇 미터인지, 높이 1단위가 몇 미터인지를 일치시켜야
//  광선의 기울기가 물리적으로 옳아진다.
//

#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

constant float kPI = 3.14159265359;

/// 밴딩을 깨는 지터.
inline float dither(uint2 gid)
{
    return fract(52.9829189 * fract(dot(float2(gid), float2(0.06711056, 0.00583715))));
}

inline float sampleInverse(device const float *depth, constant SunUniforms &u, int2 p)
{
    p = clamp(p, int2(0), int2(u.depthWidth - 1, u.depthHeight - 1));
    return depth[p.y * u.depthRowStride + p.x];
}

/// 역깊이 → 높이. **[0,1]로 정규화한다.**
///
/// 미터를 그대로 쓰면 깊이 범위(수 미터)가 화면 폭(수십 cm)보다 훨씬 커서
/// 작은 노이즈도 거대한 기울기가 된다. 실제로 그 상태에서 AO가 전부 포화되어
/// 화면이 검게 죽었다. 높이는 uv와 같은 [0,1]로 두고,
/// 광선 기울기 보정은 heightToUV 비율이 따로 맡는다.
inline float toHeight(float inverseDepth, constant SunUniforms &u)
{
    float z = 1.0 / max(u.affineA * inverseDepth + u.affineB, 1e-4);
    return saturate((u.farDistance - z) * u.heightScale);
}

/// 높이장 위 앰비언트 오클루전. 여러 방향으로 짧게 마칭해 하늘이 얼마나 열렸는지 센다.
/// 턱밑·목·코 옆의 접촉 그늘을 만든다 — 광원과 무관하게 항상 입체감을 올린다.
kernel void compute_ao_field(texture2d<float, access::sample> heightField [[texture(0)]],
                             texture2d<float, access::write>  aoOut       [[texture(1)]],
                             constant SunUniforms            &u           [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.depthWidth || gid.y >= u.depthHeight) { return; }
    if (u.enableAO == 0) { aoOut.write(float4(1.0), gid); return; }

    float2 uv = (float2(gid) + 0.5) / float2(u.depthWidth, u.depthHeight);
    float height = heightField.sample(sampler(filter::linear, address::clamp_to_edge), uv).r;

    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    // 해상도를 낮춘 이득을 샘플 수로 도로 까먹지 않게 한다.
    // 8×5(40샘플)로 늘렸더니 이동 이득이 그대로 사라졌다 — 측정으로 확인했다.
    // AO는 저주파 신호라 4×4에 지터를 섞는 편이 비용 대비 낫다.
    const uint directions = 4;
    const uint stepsPerDirection = 4;
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
    aoOut.write(float4(saturate(1.0 - occlusion / float(directions) * u.aoStrength)), gid);
}


/// 깊이 텐서 → 높이장 + 노멀 + 피사체 마스크.
///
/// 노멀을 높이장에서 직접 구한다. 이웃 높이차만 있으면 되므로
/// 뷰공간 위치를 복원할 필요가 없다 — 5-tap 언프로젝션이 통째로 사라진다.
kernel void build_height_field(device const float   *depth        [[buffer(0)]],
                               constant SunUniforms &u            [[buffer(1)]],
                               texture2d<float, access::sample> source       [[texture(0)]],
                               texture2d<float, access::sample> segmentation [[texture(1)]],
                               texture2d<float, access::write>  heightOut    [[texture(2)]],
                               texture2d<float, access::write>  normalOut    [[texture(3)]],
                               uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.depthWidth || gid.y >= u.depthHeight) { return; }

    int2 p = int2(gid);
    float height = toHeight(sampleInverse(depth, u, p), u);

    // 이웃 높이차로 기울기를 구한다. 텍셀 간 실제 거리(metersPerTexel)로 나눠야
    // 노멀이 물리적으로 옳다 — 안 나누면 해상도가 바뀔 때 음영이 달라진다.
    float hL = toHeight(sampleInverse(depth, u, p + int2(-1, 0)), u);
    float hR = toHeight(sampleInverse(depth, u, p + int2( 1, 0)), u);
    float hD = toHeight(sampleInverse(depth, u, p + int2(0, -1)), u);
    float hU = toHeight(sampleInverse(depth, u, p + int2(0,  1)), u);

    // 실루엣 절벽에서는 중앙차분이 깨진다. 변화가 작은 쪽을 쓴다.
    float dx = (abs(hR - height) < abs(height - hL)) ? (hR - height) : (height - hL);
    float dy = (abs(hU - height) < abs(height - hD)) ? (hU - height) : (height - hD);

    // 기울기를 uv 단위로 환산한다. 높이는 [0,1]이고 텍셀 간격도 [0,1] 기준이므로
    // heightToUV로 실제 종횡비를 되돌려야 음영이 물리적으로 맞다.
    float texelUV = 1.0 / float(u.depthWidth);
    float3 normal = normalize(float3(-dx * u.heightToUV / texelUV,
                                     -dy * u.heightToUV / texelUV,
                                     1.0));

    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(u.depthWidth, u.depthHeight);

    // 피부 미세 요철. 저해상도 높이장은 얼굴을 매끄러운 타원으로 만들고
    // 그 위 하이라이트는 완벽한 원이 된다. 루마 기울기로 요철을 되살린다.
    if (u.detailStrength > 0.0) {
        float2 texel = 1.0 / float2(source.get_width(), source.get_height());
        const float3 luma = float3(0.2126, 0.7152, 0.0722);
        float c = dot(source.sample(linearSampler, uv).rgb, luma);
        float r = dot(source.sample(linearSampler, uv + float2(texel.x, 0)).rgb, luma);
        float t = dot(source.sample(linearSampler, uv + float2(0, texel.y)).rgb, luma);
        normal.xy += float2(c - r, c - t) * u.detailStrength * 12.0;
        normal = normalize(normal);
    }

    float coverage = (u.hasSegmentation != 0)
        ? segmentation.sample(linearSampler, uv).r
        : smoothstep(0.35, 0.60, sampleInverse(depth, u, p));

    heightOut.write(float4(height, coverage, 0, 1), gid);
    normalOut.write(float4(normal * 0.5 + 0.5, 1), gid);
}
