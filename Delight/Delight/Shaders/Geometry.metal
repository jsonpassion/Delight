//
//  Geometry.metal
//  역깊이 텐서 → 뷰공간 위치 + 노멀.
//
//  단순 ddx/ddy 외적은 실루엣 경계에서 깨진다(얼굴 윤곽 전체에 거짓 하이라이트).
//  5-tap accurate reconstruction으로 깊이 불연속이 없는 쪽 이웃을 고른다.
//

#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

inline float sampleInverseDepth(device const float *depth, constant SunUniforms &u, int2 p)
{
    p = clamp(p, int2(0), int2(u.depthWidth - 1, u.depthHeight - 1));
    return depth[p.y * u.depthRowStride + p.x];
}

inline float3 viewPosition(device const float *depth, constant SunUniforms &u, int2 p)
{
    float inv = sampleInverseDepth(depth, u, p);
    float z = 1.0 / max(u.affineA * inv + u.affineB, 1e-4);

    // 깊이 해상도 좌표를 출력 픽셀 좌표로 환산해 내부파라미터를 적용한다.
    float sx = float(u.outputWidth)  / float(u.depthWidth);
    float sy = float(u.outputHeight) / float(u.depthHeight);
    float px = float(p.x) * sx;
    float py = float(p.y) * sy;

    return float3((px - u.cx) / u.fx * z, (py - u.cy) / u.fy * z, z);
}

kernel void build_gbuffer(device const float   *depth    [[buffer(0)]],
                          constant SunUniforms &u        [[buffer(1)]],
                          texture2d<float, access::sample> source   [[texture(0)]],
                          texture2d<float, access::write>  position [[texture(1)]],
                          texture2d<float, access::write>  normal   [[texture(2)]],
                          texture2d<float, access::write>  matte    [[texture(3)]],
                          uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.depthWidth || gid.y >= u.depthHeight) { return; }

    int2 p = int2(gid);
    float3 c  = viewPosition(depth, u, p);

    float3 l1 = viewPosition(depth, u, p + int2(-1, 0));
    float3 l2 = viewPosition(depth, u, p + int2(-2, 0));
    float3 r1 = viewPosition(depth, u, p + int2( 1, 0));
    float3 r2 = viewPosition(depth, u, p + int2( 2, 0));
    float3 d1 = viewPosition(depth, u, p + int2(0, -1));
    float3 d2 = viewPosition(depth, u, p + int2(0, -2));
    float3 t1 = viewPosition(depth, u, p + int2(0,  1));
    float3 t2 = viewPosition(depth, u, p + int2(0,  2));

    // 2차 미분이 작은 쪽 = 불연속이 없는 쪽을 채택한다.
    float leftError  = abs(l1.z * 2.0 - l2.z - c.z);
    float rightError = abs(r1.z * 2.0 - r2.z - c.z);
    float downError  = abs(d1.z * 2.0 - d2.z - c.z);
    float upError    = abs(t1.z * 2.0 - t2.z - c.z);

    float3 horizontal = (leftError < rightError) ? (c - l1) : (r1 - c);
    float3 vertical   = (downError < upError)    ? (c - d1) : (t1 - c);

    float3 n = normalize(cross(vertical, horizontal));

    // 디테일 주입: 피부는 대체로 램버시안이므로 루마 고주파 ≈ 지오메트리 고주파.
    // 파인튜닝보다 먼저 해야 할 일. (docs/01-architecture.md §4)
    if (u.detailStrength > 0.0) {
        constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
        float2 uv = (float2(gid) + 0.5) / float2(u.depthWidth, u.depthHeight);
        float2 texel = 1.0 / float2(source.get_width(), source.get_height());

        float3 center = source.sample(linearSampler, uv).rgb;
        float3 blur = float3(0.0);
        for (int dy = -2; dy <= 2; ++dy) {
            for (int dx = -2; dx <= 2; ++dx) {
                blur += source.sample(linearSampler, uv + float2(dx, dy) * texel).rgb;
            }
        }
        blur /= 25.0;

        float lumaCenter = dot(center, float3(0.2126, 0.7152, 0.0722));
        float lumaBlur   = dot(blur,   float3(0.2126, 0.7152, 0.0722));
        float highPass   = lumaCenter - lumaBlur;

        n.xy += highPass * u.detailStrength;
        n = normalize(n);
    }

    position.write(float4(c, 1.0), gid);
    normal.write(float4(n * 0.5 + 0.5, 1.0), gid);

    // 피사체 마스크를 깊이에서 근사한다. 상대 역깊이라 가까운 픽셀이 곧 사람이다.
    // 레이마칭 두께 프라이어와 스펙큘러 마스크에 쓰인다.
    // TODO(P4): Vision GeneratePersonSegmentationRequest로 교체하면 실루엣이 정확해진다.
    float inv = sampleInverseDepth(depth, u, p);
    matte.write(float4(smoothstep(0.35, 0.60, inv), 0, 0, 1), gid);
}
