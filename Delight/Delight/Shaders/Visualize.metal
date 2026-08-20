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

/// 재조명 결과를 창에 그린다. 거울상으로 뒤집고 aspect-fill로 채운다.
///
/// 거울은 **프리뷰 전용**이다. 사용자는 거울에 익숙하지만
/// 상대가 보는 영상은 비반전이 정석이라 SyphonSink는 원본을 그대로 내보낸다.
kernel void present_mirrored(texture2d<float, access::sample> source [[texture(0)]],
                             texture2d<float, access::write>  output [[texture(1)]],
                             uint2 gid [[thread_position_in_grid]])
{
    const uint W = output.get_width(), H = output.get_height();
    if (gid.x >= W || gid.y >= H) { return; }

    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);

    float paneAspect = float(W) / float(H);
    float texAspect = float(source.get_width()) / float(source.get_height());
    float2 uv = (float2(gid) + 0.5) / float2(W, H);

    // 레터박스 없이 꽉 채운다 — 검은 띠는 데모에서 손해다.
    if (texAspect > paneAspect) {
        uv.x = (uv.x - 0.5) * (paneAspect / texAspect) + 0.5;
    } else {
        uv.y = (uv.y - 0.5) * (texAspect / paneAspect) + 0.5;
    }

    uv.x = 1.0 - uv.x;
    output.write(float4(source.sample(linearSampler, uv).rgb, 1.0), gid);
}
