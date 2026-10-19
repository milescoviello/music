extension VisualizerShaders {
    /// `viz_snowflake`: App/Features/Player/Visualizer/Snowflake.metal in GLSL.
    static let snowflake = #"""
    // Snowflake: an eight-petalled flower of palette colour, turning and breathing with
    // time, its petals deepened from the centre outward by the spectrum read along the
    // radius.

    #define ANGLE_OFFSET 0.25

    vec4 vizMain() {
        vec2 fragCoord = gl_FragCoord.xy;
        vec2 uv = fragCoord / u.resolution;
        uv.x *= u.resolution.x / u.resolution.y;
        uv.y -= 0.5;
        uv.x -= 0.5 * (u.resolution.x / u.resolution.y);
        float vol = getFrequencyValueBilinear(frequencies, length(uv - vec2(0., 0.)), 0);
        float vol2 = getFrequencyValueBilinear(frequencies, uv.x + 0.5, 0);

        vec2 p = uv * 3.000;
        // x before y, as Plexamp has it: the angle is measured from the vertical.
        float a = atan(p.x, p.y);
        float r = length(p);
        r = (sin(abs(2. * sin(r + vol2 - u.time / 3.) - (sin(u.time))))) - (-vol * 1.2 + 0.8) * abs(sin(a * 4. - u.time) * sin(r));
        vec3 color = getTweenedTexture(palette, r, u.crossfade).rgb;
        return vizOutput(length(vec4(r, r * r, .6, 0.)) * vec4(color, sqrt(length(color))));
    }
    """#
}
