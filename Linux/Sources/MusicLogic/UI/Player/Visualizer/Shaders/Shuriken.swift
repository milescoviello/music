extension VisualizerShaders {
    /// `viz_shuriken`: App/Features/Player/Visualizer/Shuriken.metal in GLSL.
    static let shuriken = #"""
    // Shuriken: glowing rings rippling out from the centre, bent into six blades by the
    // spectrum read along the radius, so the loud bands warp them into a throwing star.

    vec4 vizMain() {
        vec2 fragCoord = gl_FragCoord.xy;

        // Build a line from the center to the point we're rendering.
        vec2 uv = fragCoord / u.resolution;
        uv.x *= u.resolution.x / u.resolution.y;
        vec2 line = vec2(0.5 * u.resolution.x / u.resolution.y, 0.5) - uv;

        // Get angle from 0 to 1 and read the amplitude.
        float angle = atan(line.y, line.x) / TWO_PI + 0.5;

        // Compute the radius of the line.
        float r = length(line);
        r -= sin(15.0 * (0.5 - getFrequencyValueBilinear(frequencies, r, FREQ_AMPLITUDE)) + angle * TWO_PI * 6.0) / 30.0;

        // Build concentric glowing rings with the radius, which grow over time.
        float z = 1.5 / sqrt(abs(sin(r * 25.0 - u.time)));

        // Color based on distance from origin.
        vec3 col = getTweenedTexture(palette, length(line) * 1.5, u.crossfade).rgb * 0.2;

        return vizOutput(vec4(col * vec3(z), sqrt(length(col * vec3(z)))));
    }
    """#
}
