#include "VisualizerShaders.h"

// Neutrona: twelve glowing lines stacked and rippling, each one riding on the one below
// it, wobbling faster the louder its pair of bands.

#define LINE_COUNT 12

static float neutronaWeight(texture2d<float> frequencies, int i) {
    float ret = 0.0;
    float delta = 1.0 / (float(LINE_COUNT) * 2.);
    float index = float(i + 1) / float(LINE_COUNT + 1);
    ret += getFrequencyValue(frequencies, index, FREQ_AMPLITUDE);
    ret += getFrequencyValue(frequencies, index + delta, FREQ_AMPLITUDE);
    return ret;
}

static float neutronaGlow(float x) {
    return clamp(0.15 / pow(x, 0.5), 0., 1.);
}

VIZ_FRAGMENT(viz_neutrona) {
    float2 fragCoord = vizFragCoord(in, u);
    float2 uvTrue = fragCoord / u.resolution * 2.0;
    float2 uv = -3.0 + 3.0 * uvTrue;
    float3 color = float3(0.0);

    for (int index = 0; index < LINE_COUNT; index++) {
        float i = float(index);

        // Figure out amplitude of segment.
        float amplitude = neutronaWeight(frequencies, index);

        // Offset each wave from each other, and add in a harmonic component based on frequency.
        uv.y += (0.15 * sin(uv.x + i / float(LINE_COUNT - 1) - u.time * 0.8)) + 0.1 * sin(uv.x * 7.0 * amplitude);

        // Move the wave up based on amplitude.
        float glow = neutronaGlow(abs(uv.y));
        color = max(color, glow * getTweenedTexture(palette, float(i) / float(LINE_COUNT), u.crossfade).rgb);
    }

    return vizOutput(float4(color, length(color)));
}
