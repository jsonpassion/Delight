//
//  Visualize.metal
//  역깊이 버퍼 → 화면에 보이는 색.
//
//  깊이 텐서는 행 패딩이 있다(64바이트 정렬). depthWidth가 아니라 depthRowStride로
//  인덱싱해야 한다 — 틀리면 행마다 조금씩 밀려 비스듬히 찢어진 그림이 나온다.
//

#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

/// Turbo 컬러맵 근사. 회색조보다 깊이 층이 훨씬 잘 읽힌다.
inline float3 turbo(float t)
{
    t = saturate(t);
    const float3 c0 = float3( 0.1140, 0.0628, 0.2248);
    const float3 c1 = float3( 6.7164,  3.1822, 7.5715);
    const float3 c2 = float3(-66.094, -4.9279, -10.094);
    const float3 c3 = float3( 228.77,  25.045, -91.541);
    const float3 c4 = float3(-334.83, -69.319,  288.58);
    const float3 c5 = float3( 218.76,  67.522, -305.20);
    const float3 c6 = float3(-52.889, -21.545,  110.51);
    return saturate(c0 + t * (c1 + t * (c2 + t * (c3 + t * (c4 + t * (c5 + t * c6))))));
}

/// 역깊이 버퍼를 컬러맵으로 칠해 텍스처에 쓴다.
kernel void visualize_depth(device const float   *depth  [[buffer(0)]],
                            constant SunUniforms &u      [[buffer(1)]],
                            texture2d<float, access::write> output [[texture(0)]],
                            uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }

    // 출력 해상도 → 깊이 해상도 매핑 (최근접). P6에서 joint bilateral로 교체한다.
    uint2 d = uint2(float2(gid) * float2(u.depthWidth, u.depthHeight)
                                / float2(output.get_width(), output.get_height()));
    d = min(d, uint2(u.depthWidth - 1, u.depthHeight - 1));

    float inv = depth[d.y * u.depthRowStride + d.x];   // ← rowStride, width 아님
    output.write(float4(turbo(inv), 1.0), gid);
}

/// 카메라 텍스처를 그대로 옮긴다. Metal 4 경로에서 드로어블에 합성할 때 쓴다.
kernel void blit_source(texture2d<float, access::sample> source [[texture(0)]],
                        texture2d<float, access::write>  output [[texture(1)]],
                        uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());
    output.write(float4(source.sample(linearSampler, uv).rgb, 1.0), gid);
}

/// 카메라와 깊이맵을 좌우로 나눠 드로어블에 합성한다. P1의 눈에 보이는 성과.
/// splitFraction 0 → 카메라만, 1 → 깊이만.
kernel void composite_split(texture2d<float, access::sample> camera [[texture(0)]],
                            texture2d<float, access::sample> depth  [[texture(1)]],
                            texture2d<float, access::write>  output [[texture(2)]],
                            constant float                  &splitFraction [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]])
{
    const uint W = output.get_width(), H = output.get_height();
    if (gid.x >= W || gid.y >= H) { return; }

    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    const float split = float(W) * splitFraction;

    // 2px 구분선
    if (splitFraction > 0.001 && splitFraction < 0.999 &&
        abs(float(gid.x) - split) < 1.0) {
        output.write(float4(0.08, 0.09, 0.11, 1.0), gid);
        return;
    }

    const bool isDepthSide = float(gid.x) > split;
    texture2d<float, access::sample> chosen = isDepthSide ? depth : camera;

    // 각 반쪽 안에서 aspect-fill 로 채운다 — 레터박스 없이 꽉 찬 화면이 데모에 낫다.
    const float halfWidth = isDepthSide ? (float(W) - split) : split;
    const float localX = isDepthSide ? (float(gid.x) - split) : float(gid.x);

    const float paneAspect = halfWidth / float(H);
    const float texAspect = float(chosen.get_width()) / float(chosen.get_height());

    float2 uv = float2((localX + 0.5) / halfWidth, (float(gid.y) + 0.5) / float(H));
    if (texAspect > paneAspect) {
        const float scale = paneAspect / texAspect;
        uv.x = (uv.x - 0.5) * scale + 0.5;
    } else {
        const float scale = texAspect / paneAspect;
        uv.y = (uv.y - 0.5) * scale + 0.5;
    }

    output.write(float4(chosen.sample(linearSampler, uv).rgb, 1.0), gid);
}
