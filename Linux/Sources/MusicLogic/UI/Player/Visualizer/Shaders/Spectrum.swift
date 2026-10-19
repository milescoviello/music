extension VisualizerShaders {
    /// `viz_spectrum`: App/Features/Player/Visualizer/Spectrum.metal in GLSL.
    static let spectrum = #"""
    // Spectrum: classic bars along the spectrum, each with a thin falling peak line above.
    // The bar's colour runs up the palette with height, offset so even short bars have one.

    #define BASE_BARS 25.0
    #define SCALE 1.7
    #define COLOR_SCALE (1.8/3.0)
    #define COLOR_OFFSET 0.3
    #define PEAK_HEIGHT 0.005

    float spectrumBar(float center, float point, float width, float delta) {
        float dist = abs(point - center);
        return 1. - smoothstep(width - delta, width + delta, dist);
    }

    vec4 vizMain() {
        vec2 fragCoord = gl_FragCoord.xy;
        // The gap between bars is a fixed fraction of a 250-pixel width, so it depends on
        // the resolution drawn at — one reason each program has its own `pixels`.
        float delta = 0.003 * 250.0 / u.resolution.x;

        // Adjust for landscape.
        float NUM_BARS = floor(BASE_BARS * u.resolution.x / u.resolution.y);

        vec2 uv = fragCoord / u.resolution;
        float bar = floor(uv.x * NUM_BARS);
        float offset = bar / NUM_BARS;
        float height = getFrequencyValue(frequencies, offset, FREQ_AMPLITUDE) * SCALE;
        float peak = max(getFrequencyValue(frequencies, offset, FREQ_PEAKS) * SCALE, height);

        // The background.
        vec4 colour = vec4(0.);

        // Shade the peaks.
        if (peak > 0.01) {
            colour = 0.5 * vec4(smoothstep(peak - PEAK_HEIGHT, peak, uv.y) - smoothstep(peak, peak + PEAK_HEIGHT, uv.y));
        }

        // The bar.
        if (uv.y < height) {
            float mask = spectrumBar(offset, uv.x, 1.0 / NUM_BARS - delta, delta);
            colour = vec4(getTweenedTexture(palette, uv.y * COLOR_SCALE + COLOR_OFFSET, u.crossfade).rgb, 1) * mask;
        }

        return vizOutput(colour);
    }
    """#
}
