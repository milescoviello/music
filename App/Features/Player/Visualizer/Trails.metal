#include "VisualizerShaders.h"

// Trails: the last second of spectrum as rows of square blocks, sixteen to a row,
// each row older, smaller and dimmer than the one below it, receding up the screen.

#define BOOST 1.5
#define BUCKETS 16.
#define ANTIALIAS 0.005
#define STEPS 32.
#define RESOLUTION 32.

VIZ_FRAGMENT(viz_trails) {
    float2 fragCoord = vizFragCoord(in, u);
    float2 uv = fragCoord / u.resolution;
    uv.y /= u.resolution.x / u.resolution.y;

    // The background.
    float4 colour = float4(0., 0., 0., 0.1);

    for (float i = 0.; i < STEPS; i += 1.) {
        float dim = 1.0 - (i / STEPS);
        float offset = i / STEPS * 0.7;
        float scale = 1. - (i / STEPS);

        float minX = (1. - scale) / 2.;
        float maxX = 1. - (1. - scale) / 2.;

        if (uv.x >= minX && uv.x <= maxX) {
            // Texture offset.
            float textureOffset = floor(clamp((uv.x - minX) / scale, 0., 1.) * BUCKETS) / BUCKETS;
            float startX = minX + floor(textureOffset * BUCKETS) / BUCKETS * scale;
            float bucketSize = scale / BUCKETS;

            // Read textures.
            float historyOffset = mod(u.frequencyHistoryIndex - i, STEPS) / STEPS;
            float vol = vizHighByte(history, float2(textureOffset, historyOffset));

            // Adjust.
            vol = (vol * BOOST * scale) / (u.resolution.x / u.resolution.y) + bucketSize;

            // Read color.
            float4 hue = float4(getTweenedTexture(palette, vol * 1.8, u.crossfade).rgb, 0.9);

            // Draw the square.
            float4 block = hue * (smoothstep(uv.y, uv.y + ANTIALIAS, vol + offset) -
                                  smoothstep(uv.y + bucketSize, uv.y + bucketSize + ANTIALIAS, vol + offset)) *
                                 (smoothstep(startX, startX + ANTIALIAS, uv.x) -
                                  smoothstep(startX + bucketSize, startX + bucketSize + ANTIALIAS, uv.x));

            // Make more transparent.
            block.a *= pow(dim, 2.);
            block.rgb *= pow(dim, 2.);

            colour = max(colour, block);
        }
    }

    return vizOutput(colour);
}
