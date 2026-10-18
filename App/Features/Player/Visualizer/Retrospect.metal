#include "VisualizerShaders.h"

// Retrospect: a grid of round dots, lit from the bottom up to each column's level, like
// an LED meter. Columns run along the spectrum; the colour comes from height, so the
// top of a tall column reaches further along the palette.

#define BASE_BARS 24.0
#define SCALE 2.0
#define COLOR_SCALE 1.7
#define ALPHA 0.5

static float retrospectCircle(float2 center, float2 point, float radius) {
    float2 dist = point - center;
    return 1. - smoothstep(radius - 0.05, radius + 0.05, dot(dist, dist) * 3.);
}

static float4 retrospectColor(float NUM_BARS, float2 uv, float scale, float2 resolution,
                              texture2d<float> palette, texture2d<float> frequencies,
                              float crossfade) {
    float2 intUV = floor(uv * NUM_BARS) / NUM_BARS;
    float height = getFrequencyValue(frequencies, intUV.x * (resolution.y / resolution.x), FREQ_AMPLITUDE) * scale;

    if (height > max(intUV.y, 0.05)) {
        return float4(getTweenedTexture(palette, intUV.y * COLOR_SCALE, crossfade).rgb, 1.0);
    }

    // Unlit dots: a dim grey, which is what makes the grid visible in silence.
    return float4(float3(.1), 0.0);
}

VIZ_FRAGMENT(viz_retrospect) {
    float2 fragCoord = vizFragCoord(in, u);

    // Adjust for landscape.
    float NUM_BARS = floor(BASE_BARS * u.resolution.x / u.resolution.y);

    // Adjust scaling.
    float scale = SCALE * u.resolution.y / u.resolution.x;

    float2 uv = fragCoord / u.resolution;
    uv.y *= u.resolution.y / u.resolution.x;
    float2 tiledUV = float2(fract(uv.x * NUM_BARS), fract(uv.y * NUM_BARS));
    float4 colour = float4(float3(retrospectCircle(float2(.5), tiledUV, .5)), ALPHA);
    colour *= float4(retrospectColor(NUM_BARS, uv, scale, u.resolution, palette, frequencies, u.crossfade).rgb, 1.0);
    return vizOutput(colour);
}
