#include <metal_stdlib>
using namespace metal;

// CameraApp processing shaders — Task 13: lens correction.
//
// ONE fused kernel (`lc_fused_correct`) performs radial distortion remap +
// lateral chromatic aberration + vignette gain in a single compute pass.
// Kernel names carry the `lc_` prefix (Task 13); T6's Shaders.metal owns the
// `peakingKernel`/`zebraKernel` assist kernels.

// MARK: - Lens-correction fused warp params

struct LCFusedWarpParams {
    float k1;              // Brown-Conrady radial k1 (× strength from profile)
    float k2;              // Brown-Conrady radial k2
    float k3;              // Brown-Conrady radial k3
    float ca;               // lateral CA strength (× strength from profile)
    float vignetteGain;   // vignette max gain (× strength from profile)
    float strength;        // 0...1 blend / correction scale (0 → identity)
    float centerX;         // principal-point center (normalized UV)
    float centerY;         // principal-point center (normalized UV)
    uint hasChroma;        // 1 → biplanar 420 (chroma in texture(1), subsampled); 0 → single-plane BGRA
};

static inline uint2 lcClampedCoord(uint2 coord, texture2d<float, access::read> tex) {
    return uint2(min(coord.x, tex.get_width() - 1u), min(coord.y, tex.get_height() - 1u));
}

/// Reads one source color (RGBA float4) at a normalized-UV position, handling
/// both single-plane BGRA sources and biplanar 420 YCbCr sources (chroma
/// subsampled by /2, BT.709 / video range — mirrors the T6 assist kernels).
static inline float4 lcReadSource(texture2d<float, access::read> sourceTexture,
                                 texture2d<float, access::read> chromaTexture,
                                 uint2 size,
                                 float2 sourceUV,
                                 uint hasChroma) {
    uint2 pixel = lcClampedCoord(uint2(sourceUV.x * float(size.x), sourceUV.y * float(size.y)), sourceTexture);
    if (hasChroma == 0u) {
        float4 c = sourceTexture.read(pixel);
        return float4(c.r, c.g, c.b, c.a);
    }
    uint2 chromaCoord = uint2(pixel.x / 2u, pixel.y / 2u);
    float4 yTexel = sourceTexture.read(lcClampedCoord(chromaCoord, sourceTexture));
    float2 cbcr = chromaTexture.read(lcClampedCoord(chromaCoord, chromaTexture)).rg;
    float cb = cbcr.x - 0.5f;
    float cr = cbcr.y - 0.5f;
    float yl = (yTexel.r - 0.0625f) * 1.164383f;
    float3 rgb = float3(yl + 1.792741f * cr, yl - 0.213249f * cb - 0.532909f * cr, yl + 2.112402f * cb);
    return float4(rgb, 1.0f);
}

// MARK: - Fused lens-correction warp

/// ONE fused pass per texel: radial distortion remap (Brown-Conrady k1/k2/k3 on
/// the corrected→source direction), lateral CA (red samples at r·(1+ca), blue at
/// r·(1−ca), green at r) and vignette gain (g = 1 + vignetteGain·r²), all in one
/// kernel. Strength 0 → identity sample passthrough.
kernel void lc_fused_correct(texture2d<float, access::read> sourceTexture [[texture(0)]],
                             texture2d<float, access::read> chromaTexture [[texture(1)]],
                             texture2d<float, access::write> outputTexture [[texture(2)]],
                             constant LCFusedWarpParams &params [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;   // partial edge threadgroup
    }

    uint2 size = uint2(sourceTexture.get_width(), sourceTexture.get_height());
    float2 center = float2(params.centerX, params.centerY);
    float2 uv = float2(float(gid.x) + 0.5f, float(gid.y) + 0.5f) / float2(float(size.x), float(size.y));
    float2 dir = uv - center;
    float r = length(dir);
    float r2 = r * r;

    // Brown-Conrady radial remap, corrected → source direction:
    // sourceRadius = correctedRadius * (1 + k1*r^2 + k2*r^4 + k3*r^6).
    float sourceR = r * (1.0f + params.k1 * r2 + params.k2 * (r2 * r2) + params.k3 * (r2 * r2 * r2));
    float sourceScale = (r > 0.0000001f) ? (sourceR / r) : 1.0f;
    float2 sourceUV = center + dir * sourceScale;

    uint hasChroma = params.hasChroma;
    float4 srcGreen = lcReadSource(sourceTexture, chromaTexture, size, sourceUV, hasChroma);
    float4 srcRed = (params.ca == 0.0f)
        ? srcGreen
        : lcReadSource(sourceTexture, chromaTexture, size, center + dir * (sourceScale * (1.0f + params.ca)), hasChroma);
    float4 srcBlue = (params.ca == 0.0f)
        ? srcGreen
        : lcReadSource(sourceTexture, chromaTexture, size, center + dir * (sourceScale * (1.0f - params.ca)), hasChroma);

    // Lateral CA: red channel from the red-shifted sample, green from the
    // centered sample, blue from the blue-shifted sample.
    float3 corrected = float3(srcRed.r, srcGreen.g, srcBlue.b);

    // Vignette gain: g = 1 + vignetteGain * r^2, scaled by the profile×strength
    // blend factor (strength 0 → identity passthrough).
    float gain = 1.0f + params.vignetteGain * r2;
    float3 color = corrected * gain * params.strength;
    color = float3(
        min(max(color.r, 0.0f), 1.0f),
        min(max(color.g, 0.0f), 1.0f),
        min(max(color.b, 0.0f), 1.0f)
    );
    outputTexture.write(float4(color, 1.0f), gid);
}
