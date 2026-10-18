#include "VisualizerShaders.h"

// Scratch: eleven concentric grooves, like a record, each with a short arc that runs
// round it as far as its band is loud, rounded at both ends.

#define NUM_RINGS 10.
#define ANGULAR_WIDTH 0.15
#define ANGLE_OFFSET 0.25

static float scratchCircle(float2 uv, float radius, float angle, float volAngle) {
    float2 center = radius * float2(cos(volAngle * 2. * PI), sin(volAngle * 2. * PI));
    float circleRadius = 0.011;
    return smoothstep(circleRadius + 0.005, circleRadius - 0.005, length(center - uv));
}

static float scratchRing(float2 uv, float index, float angle, texture2d<float> frequencies) {
    float radius = 1.0 / NUM_RINGS / 2.7 * index + 0.1;
    float sampleRadius = 1.0 / (NUM_RINGS - 1.) * index;
    float dist = length(uv);

    float vol = getFrequencyValue(frequencies, sampleRadius, FREQ_AMPLITUDE) * 4. / (sampleRadius / 1.3 + 1.);
    float timeOffset = 0.;
    float startAngle = max(0., vol + timeOffset - ANGULAR_WIDTH);
    float endAngle = vol + timeOffset;

    // Draw the groove foreground.
    float val = 0.;

    if ((angle > startAngle && angle < endAngle) || (angle + 1. > startAngle && angle + 1. < endAngle)) {
        val = smoothstep(radius - 0.015, radius - 0.007, dist) -
              smoothstep(radius + 0.007, radius + 0.015, dist);
    }

    // Add the rounded end-caps.
    if (vol > 0.) {
        val = max(val, scratchCircle(uv, radius, angle, startAngle + ANGLE_OFFSET));
        val = max(val, scratchCircle(uv, radius, angle, endAngle + ANGLE_OFFSET));
    }

    return val;
}

VIZ_FRAGMENT(viz_scratch) {
    float2 fragCoord = vizFragCoord(in, u);
    float2 uv = fragCoord / u.resolution;
    uv.x *= u.resolution.x / u.resolution.y;
    uv.y -= 0.5;
    uv.x -= 0.5 * (u.resolution.x / u.resolution.y);

    // Mirror in the X plane.
    uv.x *= -1.;

    float3 color = float3(0);
    float angle = mod(atan2(uv.y, uv.x) / (2. * PI) - ANGLE_OFFSET, 1.);
    for (float i = 0.; i <= NUM_RINGS; i += 1.) {
        color += scratchRing(uv, i, angle, frequencies) * getTweenedTexture(palette, i / (NUM_RINGS - 1.), u.crossfade).rgb;
    }

    return vizOutput(float4(color, sqrt(length(color))));
}
