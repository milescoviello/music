#include "VisualizerShaders.h"

// Shuriken: glowing rings rippling out from the centre, bent into six blades by the
// spectrum read along the radius, so the loud bands warp them into a throwing star.

VIZ_FRAGMENT(viz_shuriken) {
    float2 fragCoord = vizFragCoord(in, u);

    // Build a line from the center to the point we're rendering.
    float2 uv = fragCoord / u.resolution;
    uv.x *= u.resolution.x / u.resolution.y;
    float2 line = float2(0.5 * u.resolution.x / u.resolution.y, 0.5) - uv;

    // Get angle from 0 to 1 and read the amplitude.
    float angle = atan2(line.y, line.x) / TWO_PI + 0.5;

    // Compute the radius of the line.
    float r = length(line);
    r -= sin(15.0 * (0.5 - getFrequencyValueBilinear(frequencies, r, FREQ_AMPLITUDE)) + angle * TWO_PI * 6.0) / 30.0;

    // Build concentric glowing rings with the radius, which grow over time.
    float z = 1.5 / sqrt(abs(sin(r * 25.0 - u.time)));

    // Color based on distance from origin.
    float3 col = getTweenedTexture(palette, length(line) * 1.5, u.crossfade).rgb * 0.2;

    return vizOutput(float4(col * float3(z), sqrt(length(col * float3(z)))));
}
