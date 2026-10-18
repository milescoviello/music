#include "VisualizerShaders.h"

// Vertigo: thirty nested triangles, each a palette step, rotating against each other
// on sine-driven angles, their outlines kinked by the spectrum read across the screen.

static float3 vertigoTriangle(float2 uv, float ang, float zoom, float time, texture2d<float> frequencies) {
    float l = length(uv);
    float a = ang - atan2(uv.x, uv.y);
    float m = (TWO_PI / 3.);
    a = mod(a + m / 2., m) - m / 2.;
    a = a + getFrequencyValueBilinear(frequencies, uv.x / 2. + 0.5, FREQ_AMPLITUDE) * 1.8;
    float d = min(1.10 + sin(time) / 3., 1.45) * 8. * abs(l * cos(a) - zoom);
    return float3(smoothstep(0.09, 0.015, d));
}

VIZ_FRAGMENT(viz_vertigo) {
    float2 fragCoord = vizFragCoord(in, u);
    float2 uv = (2. * fragCoord - u.resolution) / u.resolution.y;
    float t = u.time;
    float3 col = float3(0.0);

    for (float i = 0.0; i < 30.0; i++) {
        float3 color = getTweenedTexture(palette, i / 29., u.crossfade).rgb;
        col += vertigoTriangle(uv, 1.05 + sin(t + i * 0.15), i / 50., t, frequencies) * color;
    }

    return vizOutput(float4(col, sqrt(length(col))));
}
