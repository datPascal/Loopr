#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// The tab colour field: three soft blobs that drift, and a faint grain so the
// gradients do not band. One pass over the page colour, no offscreen blur.
// The geometry follows `.aura i` and `.grain` in design/longevity-vision/index.html.

// Six floats per blob: centre x, centre y, radius x, radius y (fractions of the
// view), opacity, and the seconds the blob is ahead in its drift.
constant int kBlobStride = 6;
constant int kMaxBlobs = 3;
// `drift 22s ease-in-out infinite alternate`.
constant float kDriftSeconds = 22.0;

static float easeInOut(float x) {
    return x * x * (3.0 - 2.0 * x);
}

// The drift keyframes: 0% at rest, 50% moved by (8%, 6%) of the blob's box and
// scaled 1.12, 100% moved by (-6%, 10%) and scaled 0.95. Each segment eases in
// and out, and `alternate` plays it back the other way.
static float3 drift(float seconds) {
    float cycle = fmod(seconds, 2.0 * kDriftSeconds) / kDriftSeconds;
    float progress = cycle <= 1.0 ? cycle : 2.0 - cycle;
    if (progress < 0.5) {
        float s = easeInOut(progress * 2.0);
        return float3(mix(float2(0.0), float2(0.08, 0.06), s), mix(1.0, 1.12, s));
    }
    float s = easeInOut((progress - 0.5) * 2.0);
    return float3(mix(float2(0.08, 0.06), float2(-0.06, 0.10), s), mix(1.12, 0.95, s));
}

static float hash(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

[[ stitchable ]] half4 looprColorField(
    float2 position,
    half4 color,
    float2 size,
    float time,
    float motion,
    half4 first,
    half4 second,
    half4 third,
    device const float *blobs,
    int count,
    float auraOpacity,
    float grainOpacity,
    float grainMultiply
) {
    float2 uv = position / max(size, float2(1.0));
    half4 tints[kMaxBlobs] = { first, second, third };
    float3 result = float3(color.rgb);
    int blobCount = min(count / kBlobStride, kMaxBlobs);

    for (int i = 0; i < blobCount; i++) {
        device const float *blob = blobs + i * kBlobStride;
        float2 radius = float2(blob[2], blob[3]);
        // `motion` is 0 for the still frame, which puts every blob at rest as in `#still`.
        float3 moved = drift(motion * (time + blob[5]));
        // A CSS translate is a fraction of the blob's own box, which is twice its radius.
        float2 centre = float2(blob[0], blob[1]) + moved.xy * radius * 2.0;
        float distanceFromCentre = length((uv - centre) / (radius * moved.z));
        // A closest-side radial gradient to transparent, softened past its edge like the 30 px blur.
        float alpha = (1.0 - smoothstep(0.0, 1.15, distanceFromCentre)) * blob[4] * auraOpacity;
        result = mix(result, float3(tints[i].rgb), alpha);
    }

    float noise = hash(floor(position));
    // Dark mode dithers around the colour; light mode multiplies a mid grey in, as on paper.
    float3 dithered = result + (noise - 0.5) * grainOpacity * 0.25;
    float3 multiplied = result * (1.0 - grainOpacity * noise * 0.5);
    result = mix(dithered, multiplied, grainMultiply);

    return half4(half3(clamp(result, 0.0, 1.0)) * color.a, color.a);
}
