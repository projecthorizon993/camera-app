#include <metal_stdlib>
using namespace metal;

// CameraApp bracketing shaders (Task 12).
// Unique kernel names use the `bracket_` prefix to avoid collisions with
// CameraApp/Processing/Shaders.metal (Task 6).

// MARK: - bracket_warp_sample

kernel void bracket_warp_sample(
    texture2d<float, access::read>  sourceTexture [[texture(0)]],
    texture2d<float, access::read>  flowTexture   [[texture(1)]],
    texture2d<float, access::write> outputTexture [[texture(2)]],
    constant float                 &strength      [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) return;

    uint outW = outputTexture.get_width();
    uint outH = outputTexture.get_height();

    // Half-res flow lookup (nearest).
    uint fw = max(flowTexture.get_width(), 1u);
    uint fh = max(flowTexture.get_height(), 1u);
    uint fx = min(gid.x / 2u, fw - 1u);
    uint fy = min(gid.y / 2u, fh - 1u);
    float2 flow = flowTexture.read(uint2(fx, fy)).rg;

    float2 uv = (float2(gid) + 0.5f) / float2(outW, outH);
    float2 srcUV = uv - flow * strength;

    // Clamp to source bounds.
    srcUV = clamp(srcUV, float2(0.0f), float2(1.0f));

    // Bilinear sample source.
    float2 sp = srcUV * float2(sourceTexture.get_width(), sourceTexture.get_height()) - 0.5f;
    int2 i0 = int2(floor(sp));
    float2 f = sp - float2(i0);
    int2 i1 = i0 + int2(1, 0);
    int2 i2 = i0 + int2(0, 1);
    int2 i3 = i0 + int2(1, 1);

    uint2 coord00 = uint2(
        clamp(i0.x, 0, (int)sourceTexture.get_width()  - 1),
        clamp(i0.y, 0, (int)sourceTexture.get_height() - 1));
    uint2 coord10 = uint2(
        clamp(i1.x, 0, (int)sourceTexture.get_width()  - 1),
        clamp(i1.y, 0, (int)sourceTexture.get_height() - 1));
    uint2 coord01 = uint2(
        clamp(i2.x, 0, (int)sourceTexture.get_width()  - 1),
        clamp(i2.y, 0, (int)sourceTexture.get_height() - 1));
    uint2 coord11 = uint2(
        clamp(i3.x, 0, (int)sourceTexture.get_width()  - 1),
        clamp(i3.y, 0, (int)sourceTexture.get_height() - 1));

    float4 c00 = sourceTexture.read(coord00);
    float4 c10 = sourceTexture.read(coord10);
    float4 c01 = sourceTexture.read(coord01);
    float4 c11 = sourceTexture.read(coord11);

    float4 top    = mix(c00, c10, f.x);
    float4 bottom = mix(c01, c11, f.x);
    float4 out    = mix(top, bottom, f.y);

    outputTexture.write(out, gid);
}

// MARK: - bracket_fuse_weights

kernel void bracket_fuse_weights(
    texture2d<float, access::read>  sourceTexture [[texture(0)]],
    texture2d<float, access::write> weightTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= weightTexture.get_width() || gid.y >= weightTexture.get_height()) return;
    if (gid.x >= sourceTexture.get_width() || gid.y >= sourceTexture.get_height()) return;

    float4 c = sourceTexture.read(gid);
    float3 rgb = c.rgb;
    float luma = dot(rgb, float3(0.2126f, 0.7152f, 0.0722f));
    // Cheap per-texel contrast estimate: |I - mean(I)| with mean ~ 0.5.
    float contrast = fabs(luma - 0.5f);
    float sat = max(max(rgb.r, rgb.g), rgb.b) - min(min(rgb.r, rgb.g), rgb.b);
    const float sigma = 0.2f;
    float exposure = exp(-((luma - 0.5f) * (luma - 0.5f)) / (2.0f * sigma * sigma));
    float w = contrast * sat * exposure;

    weightTexture.write(float4(w, 0.0f, 0.0f, 0.0f), gid);
}

// MARK: - bracket_exposure_fuse

kernel void bracket_exposure_fuse(
    texture2d<float, access::read>        sourceTexture   [[texture(0)]],
    texture2d<float, access::read>        weightTexture   [[texture(1)]],
    texture2d<float, access::read_write>  accumTexture    [[texture(2)]],
    texture2d<float, access::read_write>  weightSumTexture[[texture(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= accumTexture.get_width() || gid.y >= accumTexture.get_height()) return;

    float w = weightTexture.read(gid).r;
    float4 color = sourceTexture.read(gid);
    float4 acc = accumTexture.read(gid);
    float  ws  = weightSumTexture.read(gid).r;

    accumTexture.write(acc + color * w, gid);
    weightSumTexture.write(float4(ws + w, 0.0f, 0.0f, 0.0f), gid);
}

// MARK: - bracket_fuse_normalize

kernel void bracket_fuse_normalize(
    texture2d<float, access::read>  accumTexture     [[texture(0)]],
    texture2d<float, access::read>  weightSumTexture  [[texture(1)]],
    texture2d<float, access::write> outputTexture     [[texture(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) return;

    float4 acc = accumTexture.read(gid);
    float  ws  = weightSumTexture.read(gid).r;
    float inv = 1.0f / max(ws, 1e-6f);
    outputTexture.write(acc * inv, gid);
}

// MARK: - bracket_median_sort

kernel void bracket_median_sort(
    texture2d<float, access::read> t0 [[texture(0)]],
    texture2d<float, access::read> t1 [[texture(1)]],
    texture2d<float, access::read> t2 [[texture(2)]],
    texture2d<float, access::read> t3 [[texture(3)]],
    texture2d<float, access::read> t4 [[texture(4)]],
    texture2d<float, access::read> t5 [[texture(5)]],
    texture2d<float, access::read> t6 [[texture(6)]],
    texture2d<float, access::read> t7 [[texture(7)]],
    texture2d<float, access::read> t8 [[texture(8)]],
    texture2d<float, access::write> outputTexture [[texture(9)]],
    constant uint &count [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) return;

    float r[9], g[9], b[9];
    int n = 0;

    if (count > 0 && gid.x < t0.get_width() && gid.y < t0.get_height()) {
        float4 c = t0.read(gid); r[n]=c.r; g[n]=c.g; b[n]=c.b; n++;
    }
    if (count > 1 && gid.x < t1.get_width() && gid.y < t1.get_height()) {
        float4 c = t1.read(gid); r[n]=c.r; g[n]=c.g; b[n]=c.b; n++;
    }
    if (count > 2 && gid.x < t2.get_width() && gid.y < t2.get_height()) {
        float4 c = t2.read(gid); r[n]=c.r; g[n]=c.g; b[n]=c.b; n++;
    }
    if (count > 3 && gid.x < t3.get_width() && gid.y < t3.get_height()) {
        float4 c = t3.read(gid); r[n]=c.r; g[n]=c.g; b[n]=c.b; n++;
    }
    if (count > 4 && gid.x < t4.get_width() && gid.y < t4.get_height()) {
        float4 c = t4.read(gid); r[n]=c.r; g[n]=c.g; b[n]=c.b; n++;
    }
    if (count > 5 && gid.x < t5.get_width() && gid.y < t5.get_height()) {
        float4 c = t5.read(gid); r[n]=c.r; g[n]=c.g; b[n]=c.b; n++;
    }
    if (count > 6 && gid.x < t6.get_width() && gid.y < t6.get_height()) {
        float4 c = t6.read(gid); r[n]=c.r; g[n]=c.g; b[n]=c.b; n++;
    }
    if (count > 7 && gid.x < t7.get_width() && gid.y < t7.get_height()) {
        float4 c = t7.read(gid); r[n]=c.r; g[n]=c.g; b[n]=c.b; n++;
    }
    if (count > 8 && gid.x < t8.get_width() && gid.y < t8.get_height()) {
        float4 c = t8.read(gid); r[n]=c.r; g[n]=c.g; b[n]=c.b; n++;
    }

    if (n == 0) { outputTexture.write(float4(0,0,0,1), gid); return; }

    // Insertion sort per channel.
    for (int i = 1; i < n; i++) {
        float kr = r[i], kg = g[i], kb = b[i];
        int j = i - 1;
        while (j >= 0 && r[j] > kr) { r[j+1] = r[j]; j--; }
        r[j+1] = kr;
        j = i - 1;
        while (j >= 0 && g[j] > kg) { g[j+1] = g[j]; j--; }
        g[j+1] = kg;
        j = i - 1;
        while (j >= 0 && b[j] > kb) { b[j+1] = b[j]; j--; }
        b[j+1] = kb;
    }

    int mid = n / 2;
    outputTexture.write(float4(r[mid], g[mid], b[mid], 1.0f), gid);
}
