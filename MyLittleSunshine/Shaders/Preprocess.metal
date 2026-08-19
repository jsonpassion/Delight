//
//  Preprocess.metal
//  캡처 텍스처 → 모델 입력 텐서(f32, NCHW, 행 패딩 포함).
//
//  Depth Anything V2는 stretch(비율 무시 리사이즈)로 학습되었으므로
//  letterbox가 아니라 stretch가 맞다.
//

#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

constant float3 kImageNetMean = float3(0.485, 0.456, 0.406);
constant float3 kImageNetStd  = float3(0.229, 0.224, 0.225);

kernel void preprocess_to_tensor(texture2d<float, access::sample> source [[texture(0)]],
                                 device float                    *tensor [[buffer(0)]],
                                 constant SunUniforms            &u      [[buffer(1)]],
                                 uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.depthWidth || gid.y >= u.depthHeight) { return; }

    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(u.depthWidth, u.depthHeight);
    float3 rgb = source.sample(linearSampler, uv).rgb;

    float3 normalized = (rgb - kImageNetMean) / kImageNetStd;

    // NCHW. 채널 평면 사이 간격은 rowStride * height 이다 —
    // width가 아니라 rowStride를 써야 한다. (64바이트 정렬 패딩)
    uint planeStride = u.depthRowStride * u.depthHeight;
    uint offset = gid.y * u.depthRowStride + gid.x;

    tensor[0 * planeStride + offset] = normalized.r;
    tensor[1 * planeStride + offset] = normalized.g;
    tensor[2 * planeStride + offset] = normalized.b;
}
