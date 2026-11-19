// Adapted from img-fx's pixels-organic preset and Chromium Flow shader
// (https://github.com/Jakubantalik/Libraries.dev, MIT, © 2026 Jakub Antalik)
// at 14ae9d2. See ThirdPartyNotices.txt.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// A small value-noise lattice replaces the web effect's multi-octave simplex
// and blur taps. The two warped ridges are still evaluated at cell centres.
static float paintingHash(float2 p) {
    float3 q = fract(float3(p.xyx) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

static float paintingNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(paintingHash(i), paintingHash(i + float2(1, 0)), f.x),
        mix(paintingHash(i + float2(0, 1)), paintingHash(i + 1), f.x),
        f.y
    ) * 2.0 - 1.0;
}

struct PaintingMosaic {
    half3 color;
    float flow;
    float2 centre;
};

static PaintingMosaic paintingMosaic(
    float2 position, float4 bounds, float time, half4 canvas, half4 raisedSurface, half4 ink
) {
    float2 size = max(bounds.zw, float2(1));
    float2 p = position - bounds.xy;
    // The web preset uses about 22 square cells across the shorter edge.
    float cellSize = clamp(min(size.x, size.y) / 22.0, 2.0, 16.0);
    float2 tile = p / cellSize;
    float2 centre = (floor(tile) + 0.5) * cellSize;
    float2 uv = (centre - size * 0.5) / min(size.x, size.y);
    float t = time * 0.3;

    float2 warped = uv + sin(uv.yx * float2(5.0, 4.0) + float2(t, -t) * 0.64) * 0.24;
    float n1 = paintingNoise(warped * 3.1 + t * 0.62);
    float n2 = paintingNoise(warped * 4.6 + float2(3.0, 7.0) - t * 0.46);
    float ridge1 = 1.0 - abs(n1);
    float ridge2 = 1.0 - abs(n2);
    ridge1 = ridge1 * ridge1 * ridge1 * ridge1;
    ridge2 = ridge2 * ridge2 * ridge2 * ridge2;
    float flow = saturate(ridge1 * 0.69 + ridge2 * 0.44);

    float2 local = abs(fract(tile) - 0.5);
    float mask = 1.0 - smoothstep(0.45, 0.5, max(local.x, local.y));
    float2 edge = min(p, size - p);
    float edgeFade = smoothstep(0.0, 24.0, min(edge.x, edge.y));
    half3 field = mix(raisedSurface.rgb, ink.rgb, half(flow * flow * 0.49));
    half3 color = mix(canvas.rgb, field, half(mix(0.44, 0.68, mask * edgeFade)));
    return { color, flow, centre };
}

[[ stitchable ]] half4 lorePixelsOrganicLoading(
    float2 position, half4 sourceColor, float4 bounds, float time,
    half4 canvas, half4 raisedSurface, half4 ink
) {
    return half4(paintingMosaic(position, bounds, time, canvas, raisedSurface, ink).color, 1.0h);
}

[[ stitchable ]] half4 lorePixelsOrganicReveal(
    float2 position, SwiftUI::Layer layer, float4 bounds, float time, float progress,
    half4 canvas, half4 raisedSurface, half4 ink
) {
    PaintingMosaic mosaic = paintingMosaic(position, bounds, time, canvas, raisedSurface, ink);
    if (progress <= 0.0) return half4(mosaic.color, 1.0h);

    // The moving ridge field drives the placement of the reveal, while time
    // controls its overall advance. Each cell then resolves from its centre.
    float reveal = smoothstep(0.0, 1.0, progress * 1.65 - (1.0 - mosaic.flow) * 0.65);
    float2 samplePoint = clamp(
        mix(mosaic.centre, position - bounds.xy, reveal), float2(0.5), max(bounds.zw - 0.5, float2(0.5))
    );
    half3 painting = layer.sample(bounds.xy + samplePoint).rgb;
    return half4(mix(mosaic.color, painting, half(reveal)), 1.0h);
}
