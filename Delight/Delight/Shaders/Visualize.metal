//
//  Visualize.metal
//  프리뷰 출력. 창에 보이는 것을 만드는 유일한 커널이다.
//
//  깊이 시각화(visualize_depth)와 좌우 분할(composite_split)은
//  개발 중 눈으로 확인하려고 두었던 것이고 지금은 없다.
//  UI에서 그 기능이 사라지면서 함께 지웠다 — 쓰이지 않는 커널은
//  metallib을 키우고, 무엇이 살아 있는지 헷갈리게 만든다.
//

#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

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
