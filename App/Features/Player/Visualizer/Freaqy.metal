#include "VisualizerShaders.h"

// Freaqy: the spectrum wrapped into a circle, a solid rosette whose radius at each
// angle is that band's level, with a faint halo at the rim. The ends of the spectrum
// are blended where they meet at the top so the seam does not jump.

static float freaqyWrapped(texture2d<float> frequencies, float val) {
    if (val > 0.9) {
        return mix(getFrequencyValue(frequencies, val, FREQ_AMPLITUDE),
                   getFrequencyValue(frequencies, 1. - val, FREQ_AMPLITUDE), (val - 0.9) * 5.);
    } else if (val < 0.1) {
        return mix(getFrequencyValue(frequencies, val, FREQ_AMPLITUDE),
                   getFrequencyValue(frequencies, 1. - val, FREQ_AMPLITUDE), (0.1 - val) * 5.);
    }

    return getFrequencyValue(frequencies, val, FREQ_AMPLITUDE);
}

static float4 freaqySpoke(float2 line, float angle, texture2d<float> palette,
                          texture2d<float> frequencies, float crossfade) {
    float len = 0.01 + freaqyWrapped(frequencies, 1. - angle) * 1.4;
    float lineLength = length(line);

    float4 color = float4(0);
    color += smoothstep(len + 0.005, len - 0.005, lineLength);
    color *= getTweenedTexture(palette, len * 2.7, crossfade);

    float spread = 0.03;
    color += (smoothstep(len - spread, len, lineLength - 0.01) - smoothstep(len, len + spread, lineLength - 0.01))
        * getTweenedTexture(palette, .2, crossfade) * 0.1;

    // Clamp alpha.
    if (color.a < 0.1) {
        color.a = 0.0;
    }

    return color;
}

VIZ_FRAGMENT(viz_freaqy) {
    float2 fragCoord = vizFragCoord(in, u);
    float2 uv = fragCoord / u.resolution;
    uv.x *= u.resolution.x / u.resolution.y;
    float2 line = float2(0.5 * u.resolution.x / u.resolution.y, 0.5) - uv;
    float angle = mod(atan2(line.y, line.x) / TWO_PI + 0.25, 1.);

    // Mix two spokes slightly offset for antialiasing (at a weight of 0, as Plexamp has it).
    float4 colour = mix(freaqySpoke(line, angle, palette, frequencies, u.crossfade),
                        freaqySpoke(line, angle + 0.0005, palette, frequencies, u.crossfade), 0.);
    colour.a = sqrt(length(colour.rgb));
    return vizOutput(colour);
}
