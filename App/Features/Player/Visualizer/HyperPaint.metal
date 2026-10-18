#include "VisualizerShaders.h"

// Hyper Paint: the palette swirled round the centre like paint on a spinning wheel —
// bass swells the swirl, mids twist and jitter it, treble tightens the ripples and
// brightens everything — fading out under a round vignette.

VIZ_FRAGMENT(viz_hyper_paint) {
    float2 fragCoord = vizFragCoord(in, u);
    // Normalize to centered square [-0.5,0.5].
    float2 uv = fragCoord / u.resolution - 0.5;
    uv.x *= u.resolution.x / u.resolution.y;

    // Sample frequency bands.
    float low = getFrequencyValue(frequencies, 0.2, FREQ_AMPLITUDE);
    float mid = getFrequencyValue(frequencies, 0.5, FREQ_AMPLITUDE);
    float high = getFrequencyValue(frequencies, 0.8, FREQ_AMPLITUDE);

    // Convert to polar coordinates.
    float r = length(uv);
    float a = atan2(uv.y, uv.x);

    // Amplify radial pulsation.
    float pulsedR = r * (1.0 + low * 0.5);

    // Swirl the angle based on radius, time, and mid/high frequencies.
    a += sin(pulsedR * (6.0 + high * 20.0) - u.time * 2.0 + mid * 5.0) * (0.5 + high * 2.0);

    // Reconstruct UV after swirl.
    float2 swirlUV = float2(cos(a), sin(a)) * pulsedR;

    // Mid-band jitter for extra motion.
    swirlUV += float2(sin(a * 5.0 + u.time * 4.0), cos(a * 5.0 - u.time * 4.0)) * mid * 0.1;

    // Dynamic color index from angle, time, and low frequency.
    float colorIdx = fract(a / (2.0 * PI) + u.time * 0.1 + low * 0.2 + mid * 0.2);
    float3 baseColor = getTweenedTexture(palette, colorIdx, u.crossfade).rgb;

    // Add dancing ribbons via a sine-wave distortion, driven by mid frequency.
    float wave = sin((swirlUV.x + swirlUV.y) * (10.0 + high * 40.0) + u.time * (3.0 + high * 10.0)) * 0.5 + 0.5;
    baseColor *= mix(0.8, 1.2, wave * mid);

    // Boost peak brightness.
    baseColor *= 1.0 + high * 1.0;

    // Vignette to fade edges.
    float vignette = smoothstep(0.8, 0.4, r);
    baseColor *= vignette;

    return vizOutput(float4(baseColor, 1.0));
}
