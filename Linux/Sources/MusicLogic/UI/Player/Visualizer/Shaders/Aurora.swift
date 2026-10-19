extension VisualizerShaders {
    /// `viz_aurora`: App/Features/Player/Visualizer/Aurora.metal in GLSL.
    static let aurora = #"""
    // Aurora: 64 radial bars round a circle, each a ring segment pushed out by its band,
    // with a thinner peak ring beyond it, the colours turning slowly round the palette.

    float auroraEase(float x) {
        return x * x * (3.0 - 2.0 * x);
    }

    // Draw a single smooth bar.
    float auroraBar(float x, float t, float w, vec2 resolution) {
        float d = abs(x - t);
        // Approximate anti-aliasing without fwidth.
        float aa = 1.0 / resolution.x;
        return smoothstep(w + aa, w - aa, d);
    }

    vec4 vizMain() {
        vec2 fragCoord = gl_FragCoord.xy;
        vec2 uv = fragCoord / u.resolution;
        vec2 cent = uv - 0.5;
        cent.x *= u.resolution.x / u.resolution.y;

        // Number of bars around a circle.
        float BARS = 64.0;
        float angle = atan(cent.y, cent.x);
        float radius = length(cent);
        float barIdx = floor((angle + PI) / (2.0 * PI) * BARS);
        float t = (barIdx + 0.5) / BARS;

        // Sample amplitude and peak.
        float amp = getFrequencyValue(frequencies, t, FREQ_AMPLITUDE);
        float peak = getFrequencyValue(frequencies, t, FREQ_PEAKS);

        // Radial bar height mapped to radius; peaks extend slightly beyond the main maximum.
        float minR = 0.10;
        float maxR = 0.85;
        float maxPeakR = 0.95;
        float r0 = mix(minR, maxR, auroraEase(amp));
        float r1 = mix(minR, maxPeakR, auroraEase(peak));

        // Vary bar thickness between half and full base width; the peak ring is thinner.
        float baseWidth = 3.0 / BARS * 0.8;
        float barWidth = baseWidth * (0.5 + amp * 0.5);
        float peakWidth = baseWidth * (0.3 + peak * 0.2);

        float mask = auroraBar(radius, r0, barWidth, u.resolution);
        float peakMask = auroraBar(radius, r1, peakWidth, u.resolution) * step(r0 + 0.02, r1);

        // Color for this bar from palette.
        float hue = fract(t + u.time * 0.05);
        vec3 colMain = getTweenedTexture(palette, hue, u.crossfade).rgb;
        vec3 colPeak = getTweenedTexture(palette, fract(hue + 0.3), u.crossfade).rgb;

        vec3 col = vec3(0, 0, 0);
        col = mix(col, colMain, mask);
        col = mix(col, colPeak, peakMask);

        return vizOutput(vec4(col, sqrt(length(col))));
    }
    """#
}
