//
//  Stabilize.metal
//  깊이 안정화 — 품질의 8할이 여기 있다. (docs/01-architecture.md §5)
//
//  프레임 독립 추론이라 픽셀 단위로 떨린다. Video Depth Anything(CVPR'25)이
//  학습으로 푸는 문제지만 실시간엔 무겁다. 대신 edge-stopping 시간필터를 쓴다.
//
//  ⚠️ 색 가중치를 빼면 안 된다. 깊이 차이만으로 히스토리를 섞으면
//  사람이 움직일 때 이전 프레임의 깊이가 끌려와 고스팅이 생긴다.
//

#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

kernel void stabilize_depth(device const float   *current      [[buffer(0)]],
                            device const float   *history      [[buffer(1)]],
                            device float         *output       [[buffer(2)]],
                            constant SunUniforms &u            [[buffer(3)]],
                            texture2d<float, access::sample> color        [[texture(0)]],
                            texture2d<float, access::sample> colorHistory [[texture(1)]],
                            texture2d<float, access::write>  colorOut     [[texture(2)]],
                            uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.depthWidth || gid.y >= u.depthHeight) { return; }

    const uint index = gid.y * u.depthRowStride + gid.x;
    float raw = current[index];

    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(u.depthWidth, u.depthHeight);
    float3 nowColor = color.sample(linearSampler, uv).rgb;

    // 첫 프레임(히스토리 없음)이면 그대로 통과시킨다.
    float previous = history[index];
    if (u.historyValid == 0) {
        output[index] = raw;
        colorOut.write(float4(nowColor, 1.0), gid);
        return;
    }

    float3 wasColor = colorHistory.sample(linearSampler, uv).rgb;

    // 색이 크게 변한 픽셀 = 다른 물체가 들어왔다 → 히스토리를 버린다.
    float3 colorDelta = nowColor - wasColor;
    float colorWeight = exp(-dot(colorDelta, colorDelta) / max(u.colorSigma, 1e-4));

    // 깊이가 크게 변한 픽셀도 마찬가지. 진짜 움직임을 뭉개지 않는다.
    float depthDelta = abs(raw - previous);
    float depthWeight = exp(-depthDelta / max(u.depthSigma, 1e-4));

    float blend = u.temporalBlend * colorWeight * depthWeight;
    output[index] = mix(raw, previous, blend);

    colorOut.write(float4(nowColor, 1.0), gid);
}
