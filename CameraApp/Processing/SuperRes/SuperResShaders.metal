#include <metal_stdlib>
using namespace metal;

// MARK: - sr_unsharp

/// v1 super-res sharpen pass: single 3x3 unsharp mask on the Lanczos output.
/// amount = 0.15, threshold = 0.02 (luma detail magnitude). Metal function name
/// carries the unique `sr_` prefix to avoid collisions with other kernels.
constant float3 sr_kLumaWeights = float3(0.2126f, 0.7152f, 0.0722f);

kernel void sr_unsharp(texture2d<float, access::read> inputTexture [[texture(0)]],
                       texture2d<float, access::write> outputTexture [[texture(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    uint2 size = uint2(inputTexture.get_width(), inputTexture.get_height());
    int2 pos = int2(gid);

    float3 sum = float3(0.0f);
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int2 coord = int2(clamp(pos.x + dx, 0, int(size.x) - 1),
                              clamp(pos.y + dy, 0, int(size.y) - 1));
            sum += inputTexture.read(uint2(coord)).rgb;
        }
    }
    float3 blur = sum / 9.0f;
    float4 centerSample = inputTexture.read(gid);
    float3 center = centerSample.rgb;
    float3 detail = center - blur;
    float detailLuma = fabs(dot(detail, sr_kLumaWeights));

    float3 outRGB = center;
    if (detailLuma > 0.02f) {
        outRGB = center + 0.15f * detail;
    }
    outRGB = clamp(outRGB, 0.0f, 1.0f);

    outputTexture.write(float4(outRGB, centerSample.a), gid);
}