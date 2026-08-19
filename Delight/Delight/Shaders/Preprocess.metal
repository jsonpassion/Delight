//
//  Preprocess.metal
//  캡처 텍스처 → 모델 입력 텐서(f32, NCHW, 행 패딩 포함).
//
//  ⚠️ 정규화를 여기서 하면 안 된다.
//  변환된 그래프가 ImageNet 정규화를 이미 갖고 있다(model.mil 첫 두 연산):
//      sub(mean = 123.675, 116.28, 103.53)      ← 0-255 스케일의 ImageNet 평균
//      mul(1/58.395, 1/57.12, 1/57.375)         ← 1/(std × 255)
//  따라서 이 커널은 **0-255 원본 RGB를 그대로** 써야 한다.
//  0-1로 넘기거나 여기서 정규화하면 이중 정규화가 되어 깊이가 뒤집힌다.
//  (Tools/probe_p1.swift 의 Core ML 교차검증이 이 버그를 잡는다)
//
//  Depth Anything V2는 stretch(비율 무시 리사이즈)로 학습되었으므로
//  letterbox가 아니라 stretch가 맞다.
//

#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

kernel void preprocess_to_tensor(texture2d<float, access::sample> source [[texture(0)]],
                                 device float                    *tensor [[buffer(0)]],
                                 constant SunUniforms            &u      [[buffer(1)]],
                                 uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.depthWidth || gid.y >= u.depthHeight) { return; }

    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(u.depthWidth, u.depthHeight);
    float3 rgb = source.sample(linearSampler, uv).rgb * 255.0;   // 그래프가 0-255를 기대한다

    // NCHW. 채널 평면 간격은 rowStride * height 이다 —
    // width가 아니라 rowStride를 써야 한다. (64바이트 정렬 패딩)
    uint planeStride = u.depthRowStride * u.depthHeight;
    uint offset = gid.y * u.depthRowStride + gid.x;

    tensor[0 * planeStride + offset] = rgb.r;
    tensor[1 * planeStride + offset] = rgb.g;
    tensor[2 * planeStride + offset] = rgb.b;
}
