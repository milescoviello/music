extension VisualizerShaders {
    /// `viz_strings`: App/Features/Player/Visualizer/Strings.metal in GLSL.
    static let strings = #"""
    // Strings: twenty sine waves across the screen, one per slice of the spectrum, each
    // as tall as its band is loud, the higher ones faster and thinner. Where they cross,
    // the brightest wins.

    #define LINE_COUNT 20
    #define THICKNESS 0.03

    vec4 vizMain() {
        vec2 fragCoord = gl_FragCoord.xy;
        vec2 uv = fragCoord / u.resolution;
        vec3 color = vec3(0.0);

        // Make sure treble gets the brighter colors.
        float colorMultiplier = 1.0;
        float colorOffset = 0.0;
        vec3 minColor = getTweenedTexture(palette, 0.0, u.crossfade).rgb;
        vec3 maxColor = getTweenedTexture(palette, 1.0, u.crossfade).rgb;

        if (length(minColor) > length(maxColor)) {
            colorMultiplier = -1.0;
            colorOffset = 1.0;
        }

        for (int index = 0; index < LINE_COUNT; index++) {
            float i = float(index);

            // Figure out amplitude of segment.
            float amplitude = getFrequencyValue(frequencies, i / float(LINE_COUNT), FREQ_AMPLITUDE);
            float thickness = clamp(float(THICKNESS) - i / float(LINE_COUNT) / 30.0, 0.025, 1.0);

            // Move the wave up based on amplitude.
            float waveSpeedMultiplier;
            if (index < 5) {
                waveSpeedMultiplier = 2.0;
            } else if (index >= 5 && index < 15) {
                waveSpeedMultiplier = 1.5;
            } else {
                waveSpeedMultiplier = 1.1;
            }

            float value = sin(
                uv.x * 2.1 * (i + 1.) / 1.1 +   // Frequency of sine wave increases for each line.
                u.time * waveSpeedMultiplier    // Move waves.
            ) * pow(amplitude, 0.9) +           // Scale amplitude of wave by frequency band.
                0.5;                            // Move up to be centered.

            float glow = smoothstep(value - thickness, value, uv.y) - smoothstep(value, value + thickness, uv.y);
            vec3 tint = getTweenedTexture(palette, colorOffset + colorMultiplier * float(i) / float(LINE_COUNT), u.crossfade).rgb;
            color = max(color, glow * tint * (amplitude / 10.0 + 0.98));
        }

        return vizOutput(vec4(color, length(color)));
    }
    """#
}
