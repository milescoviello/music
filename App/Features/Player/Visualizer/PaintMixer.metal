#include "VisualizerShaders.h"

// Paint Mixer: a field of swirling, folded colour, like paint being stirred, flowing
// toward the viewer; the spectrum pushes every step of the march, so the music bends
// the folds. Its colours are the palette looked up by the field's brightness.

#define ITERATIONS 32

static float paintField(float3 p, float time) {
    p.y += 1.5 * sin(p.x + time * 2.);
    p.z += 2. * time;
    return length(.1 * sin(p.x / 1.5 + p.y) + cos(p.zzx / 4.)) - .9;
}

static float3 paintRgb2hsv(float3 c) {
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));

    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

VIZ_FRAGMENT(viz_paint_mixer) {
    float2 fragCoord = vizFragCoord(in, u);
    float3 d = .9 - float3(fragCoord / .65, 0) / u.resolution.x;
    float3 o = d;

    for (int i = 0; i < ITERATIONS; i++) {
        // Plexamp reads `.x` here, the first byte of its packed float, not the value.
        o += paintField(o, u.time) * d + vizHighByte(frequencies, float2(float(i) / float(ITERATIONS), 0)) / 1.2;
    }

    float3 rgb = abs(paintField(o * 1.8, u.time) * float3(.3 + sin(o.x) / 3., .1, .1)
                     + paintField(o * .5, u.time) * float3(.1, .05, 0)) * (9. - o.y / 3.);
    float3 hsv = paintRgb2hsv(rgb);
    float3 colour = getTweenedTexture(palette, hsv.z, u.crossfade).rgb;
    colour = colour * 0.7 + rgb * 0.3;
    return vizOutput(float4(colour, 1.));
}
