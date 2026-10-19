extension VisualizerShaders {
    /// `viz_rothko`: App/Features/Player/Visualizer/Rothko.metal in GLSL.
    static let rothko = #"""
    // Rothko: the palette as soft horizontal bands, like the paintings, brightened in
    // vertical stripes where the spectrum is loud and nudged upward by it, under a heavy
    // vignette and a ghostly alpha that thins where the music is loudest.

    vec4 vizMain() {
        vec2 fragCoord = gl_FragCoord.xy;
        vec2 uv = fragCoord / u.resolution;
        float color = 0.;

        // Use the volume to make some vertical lines on the background.
        float vol = getFrequencyValue(frequencies, uv.x, FREQ_AMPLITUDE);
        float bgMultiplier = (.8 - color + 1.5 * vol);

        // Distort the background a little with the volume, just to make it more interesting.
        vec4 colour = bgMultiplier * vec4(getTweenedTexture(palette, uv.y - vol / 4.0, u.crossfade).rgb, 1.0);

        // Now give everything a really vignetted overlay.
        colour *= 5.0 * sqrt(uv.x * uv.y * (1. - uv.x) * (1. - uv.y));

        // And use some alpha to make it more ghostly and enhance the vertical patterns a bit.
        colour.a = 0.65 - vol / 2.;
        return vizOutput(colour);
    }
    """#
}
