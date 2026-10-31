#include <metal_stdlib>
using namespace metal;

// CameraApp processing shaders (Task 6).
//
// Layout parity with Swift (verified):
//   TexturedQuadVertexIn  { float2; float2 }   ⇄ MetalRenderer.TexturedQuadVertex  (stride 16)
//   OverlayVertexIn       { float2; float4 }   ⇄ MetalRenderer.OverlayVertex       (stride 32, float4 @ 16)
//   PeakingParams         { uint; float; float; float; float4 } ⇄ Stubs.PeakingParams (stride 32, float4 @ 16)
//   ZebraParams           { uint; float; float; float; float4 } ⇄ Stubs.ZebraParams   (stride 32, float4 @ 16)
//
// Peaking/zebra kernels are functional stubs — Task 20 owns tuning; all magic
// numbers live in the Swift Peaking/Zebra constants and arrive as params.

// MARK: - Textured quad (video frame)

struct TexturedQuadVertexIn {
    float2 position;
    float2 texCoord;
};

struct TexturedQuadVaryings {
    float4 position [[position]];
    float2 texCoord;
};

vertex TexturedQuadVaryings texturedQuadVertex(uint vid [[vertex_id]],
                                               device const TexturedQuadVertexIn *vertices [[buffer(0)]]) {
    TexturedQuadVertexIn v = vertices[vid];
    TexturedQuadVaryings out;
    out.position = float4(v.position, 0.0f, 1.0f);
    out.texCoord = v.texCoord;
    return out;
}

/// Single-plane sources (BGRA pixel buffers).
fragment float4 texturedQuadFragment(TexturedQuadVaryings in [[stage_in]],
                                     texture2d<float> sourceTexture [[texture(0)]],
                                     sampler texSampler [[sampler(0)]]) {
    return sourceTexture.sample(texSampler, in.texCoord);
}

/// Biplanar 420 YCbCr sources (camera output): BT.709, video range.
fragment float4 texturedQuadYUVFragment(TexturedQuadVaryings in [[stage_in]],
                                        texture2d<float> yTexture [[texture(0)]],
                                        texture2d<float> cbcrTexture [[texture(1)]],
                                        sampler texSampler [[sampler(0)]]) {
    float y = yTexture.sample(texSampler, in.texCoord).r;
    float2 cbcr = cbcrTexture.sample(texSampler, in.texCoord).rg;
    float cb = cbcr.x - 0.5f;
    float cr = cbcr.y - 0.5f;
    float yl = (y - 0.0625f) * 1.164383f;
    float3 rgb = float3(yl + 1.792741f * cr,
                        yl - 0.213249f * cb - 0.532909f * cr,
                        yl + 2.112402f * cb);
    return float4(clamp(rgb, 0.0f, 1.0f), 1.0f);
}

// MARK: - Overlay pass (grid / HUD lines)

struct OverlayVertexIn {
    float2 position;   // unit space 0...1, origin top-left
    float4 color;
};

struct OverlayVaryings {
    float4 position [[position]];
    float4 color;
};

vertex OverlayVaryings overlayVertex(uint vid [[vertex_id]],
                                     device const OverlayVertexIn *vertices [[buffer(0)]],
                                     constant float2 &viewportSize [[buffer(1)]]) {
    OverlayVertexIn v = vertices[vid];
    float2 ndc = v.position * 2.0f - 1.0f;
    OverlayVaryings out;
    out.position = float4(ndc.x, -ndc.y, 0.0f, 1.0f);   // flip Y: unit origin = top-left
    out.color = v.color;
    return out;
}

fragment float4 overlayFragment(OverlayVaryings in [[stage_in]]) {
    return in.color;
}

// MARK: - Assist kernels (peaking / zebras, functional stubs)

struct PeakingParams {
    uint inputIsSinglePlane;  // 1 → texture(0) is a luma-only plane (420 YCbCr); 0 → BGRA
    float threshold;          // sobel magnitude (normalized 0...1) that triggers an edge
    float softness;           // transition band above the threshold
    float strength;           // final overlay blend factor
    float4 edgeColor;         // overlay color (green)
};

struct ZebraParams {
    uint inputIsSinglePlane;
    float lumaThreshold;      // overexposure trigger (normalized luma 0...1)
    float stripePeriod;       // diagonal stripe period in pixels
    float stripeOpacity;      // stripe blend factor
    float4 stripeColor;       // stripe color (black)
};

// BT.709 luma weights.
constant float3 kLumaWeights = float3(0.2126f, 0.7152f, 0.0722f);

static inline uint2 clampedCoord(uint2 coord, texture2d<float, access::read> tex) {
    return uint2(min(coord.x, tex.get_width() - 1u), min(coord.y, tex.get_height() - 1u));
}

/// Reconstructs the base RGB color of a texel from the input planes.
/// For biplanar 420 input the chroma plane is half resolution, so the chroma
/// coordinate is subsampled (gid / 2) and clamped.
static inline float3 baseColor(texture2d<float, access::read> yTexture,
                               texture2d<float, access::read> cbcrTexture,
                               uint2 gid,
                               uint inputIsSinglePlane) {
    float4 yTexel = yTexture.read(clampedCoord(gid, yTexture));
    if (inputIsSinglePlane != 0u) {
        uint2 chromaCoord = uint2(gid.x / 2u, gid.y / 2u);
        float2 cbcr = cbcrTexture.read(clampedCoord(chromaCoord, cbcrTexture)).rg;
        float cb = cbcr.x - 0.5f;
        float cr = cbcr.y - 0.5f;
        float yl = (yTexel.r - 0.0625f) * 1.164383f;
        return float3(yl + 1.792741f * cr,
                      yl - 0.213249f * cb - 0.532909f * cr,
                      yl + 2.112402f * cb);
    }
    return yTexel.rgb;
}

/// Luma of a sobel-neighborhood position, clamped to the texture bounds so
/// partial edge threadgroups (ceil-div dispatch) never read out of range.
static inline float readLumaClamped(texture2d<float, access::read> yTexture,
                                    int2 position,
                                    uint inputIsSinglePlane,
                                    uint2 textureSize) {
    int2 clamped = int2(clamp(position, int2(0), int2(textureSize) - int2(1)));
    float4 texel = yTexture.read(uint2(clamped));
    if (inputIsSinglePlane != 0u) {
        return texel.r;   // luma plane: .r is the luma sample
    }
    return dot(texel.rgb, kLumaWeights);
}

/// Peaking (focus assist): sobel edge magnitude above `threshold` blends
/// `edgeColor` over the base image. Functional stub — Task 20 tunes.
kernel void peakingKernel(texture2d<float, access::read> yTexture [[texture(0)]],
                          texture2d<float, access::read> cbcrTexture [[texture(1)]],
                          texture2d<float, access::write> outputTexture [[texture(2)]],
                          constant PeakingParams &params [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;   // partial edge threadgroup
    }

    uint2 size = uint2(yTexture.get_width(), yTexture.get_height());
    uint singlePlane = params.inputIsSinglePlane;

    float tl = readLumaClamped(yTexture, int2(gid) + int2(-1, -1), singlePlane, size);
    float tc = readLumaClamped(yTexture, int2(gid) + int2(0, -1), singlePlane, size);
    float tr = readLumaClamped(yTexture, int2(gid) + int2(1, -1), singlePlane, size);
    float ml = readLumaClamped(yTexture, int2(gid) + int2(-1, 0), singlePlane, size);
    float mr = readLumaClamped(yTexture, int2(gid) + int2(1, 0), singlePlane, size);
    float bl = readLumaClamped(yTexture, int2(gid) + int2(-1, 1), singlePlane, size);
    float bc = readLumaClamped(yTexture, int2(gid) + int2(0, 1), singlePlane, size);
    float br = readLumaClamped(yTexture, int2(gid) + int2(1, 1), singlePlane, size);

    float gx = (tr + 2.0f * mr + br) - (tl + 2.0f * ml + bl);
    float gy = (bl + 2.0f * bc + br) - (tl + 2.0f * tc + tr);
    // Normalized edge magnitude: sqrt(gx² + gy²) * 0.25 peaks at ≈1.41 for pure
    // diagonal extremes (≈1.0 for axis-aligned edges); 0.15 is the tuning constant.
    float magnitude = sqrt(gx * gx + gy * gy) * 0.25f;

    float mask = clamp((magnitude - params.threshold) / max(params.softness, 0.0001f), 0.0f, 1.0f);
    float3 base = baseColor(yTexture, cbcrTexture, gid, singlePlane);
    float3 rgb = mix(base, params.edgeColor.rgb, mask * params.strength);
    outputTexture.write(float4(clamp(rgb, 0.0f, 1.0f), 1.0f), gid);
}

/// Zebras (exposure assist): luma above `lumaThreshold` gets a fixed
/// diagonal-stripe overlay (45°, constant pattern — no configuration).
kernel void zebraKernel(texture2d<float, access::read> yTexture [[texture(0)]],
                        texture2d<float, access::read> cbcrTexture [[texture(1)]],
                        texture2d<float, access::write> outputTexture [[texture(2)]],
                        constant ZebraParams &params [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;   // partial edge threadgroup
    }

    float3 base = baseColor(yTexture, cbcrTexture, gid, params.inputIsSinglePlane);
    float luma = dot(base, kLumaWeights);

    float stripe = 0.0f;
    if (luma > params.lumaThreshold) {
        float phase = fmod(float(gid.x + gid.y), params.stripePeriod);
        stripe = phase < (params.stripePeriod * 0.5f) ? 1.0f : 0.0f;
    }

    float3 rgb = mix(base, params.stripeColor.rgb, stripe * params.stripeOpacity);
    outputTexture.write(float4(clamp(rgb, 0.0f, 1.0f), 1.0f), gid);
}
