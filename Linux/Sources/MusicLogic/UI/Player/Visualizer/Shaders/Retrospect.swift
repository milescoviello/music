extension VisualizerShaders {
    /// `viz_retrospect`: App/Features/Player/Visualizer/Retrospect.metal in GLSL.
    static let retrospect = #"""
    // Retrospect: a grid of round dots, lit from the bottom up to each column's level, like
    // an LED meter. Columns run along the spectrum; the colour comes from height, so the
    // top of a tall column reaches further along the palette.

    #define BASE_BARS 24.0
    #define SCALE 2.0
    #define COLOR_SCALE 1.7
    #define ALPHA 0.5

    float retrospectCircle(vec2 center, vec2 point, float radius) {
        vec2 dist = point - center;
        return 1. - smoothstep(radius - 0.05, radius + 0.05, dot(dist, dist) * 3.);
    }

    vec4 retrospectColor(float NUM_BARS, vec2 uv, float scale, vec2 resolution,
                         sampler2D palette, sampler2D frequencies,
                         float crossfade) {
        vec2 intUV = floor(uv * NUM_BARS) / NUM_BARS;
        float height = getFrequencyValue(frequencies, intUV.x * (resolution.y / resolution.x), FREQ_AMPLITUDE) * scale;

        if (height > max(intUV.y, 0.05)) {
            return vec4(getTweenedTexture(palette, intUV.y * COLOR_SCALE, crossfade).rgb, 1.0);
        }

        // Unlit dots: a dim grey, which is what makes the grid visible in silence.
        return vec4(vec3(.1), 0.0);
    }

    vec4 vizMain() {
        vec2 fragCoord = gl_FragCoord.xy;

        // Adjust for landscape.
        float NUM_BARS = floor(BASE_BARS * u.resolution.x / u.resolution.y);

        // Adjust scaling.
        float scale = SCALE * u.resolution.y / u.resolution.x;

        vec2 uv = fragCoord / u.resolution;
        uv.y *= u.resolution.y / u.resolution.x;
        vec2 tiledUV = vec2(fract(uv.x * NUM_BARS), fract(uv.y * NUM_BARS));
        vec4 colour = vec4(vec3(retrospectCircle(vec2(.5), tiledUV, .5)), ALPHA);
        colour *= vec4(retrospectColor(NUM_BARS, uv, scale, u.resolution, palette, frequencies, u.crossfade).rgb, 1.0);
        return vizOutput(colour);
    }
    """#
}
