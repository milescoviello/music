extension VisualizerShaders {
    /// `viz_soundprint`: App/Features/Player/Visualizer/Soundprint.metal in GLSL.
    static let soundprint = #"""
    // Soundprint: the whole track's loudness as a ring of a hundred spokes, start at the
    // top and clockwise to the end, with a pale spoke past the rim marking how far through
    // it is. It reads no spectrum at all, which is why it carries on while paused.

    #define INNER_RADIUS 0.05
    #define NUM_SPOKES 100.
    #define ANGLE_OFFSET (1. / NUM_SPOKES)
    #define ANTIALIAS 0.0025
    #define STROKE_WIDTH 0.0025

    float soundprintArc(vec2 uv, float innerRadius, float outerRadius, float angle, float startAngle) {
        // Limit the arc from inside to outside.
        float dist = length(uv);
        float val = smoothstep(innerRadius - ANTIALIAS * 2., innerRadius, dist) -
                    smoothstep(outerRadius - ANTIALIAS * 2., outerRadius, dist);

        // Limit the arc from edge to edge.
        float endAngle = startAngle + ANGLE_OFFSET + STROKE_WIDTH;
        val *= smoothstep(startAngle, startAngle + ANTIALIAS, angle) -
               smoothstep(endAngle - ANTIALIAS, endAngle, angle);

        return val;
    }

    vec4 vizMain() {
        vec2 fragCoord = gl_FragCoord.xy;

        // Center on 0, 0.
        vec2 uv = fragCoord / u.resolution;
        uv.x *= u.resolution.x / u.resolution.y;
        uv.y -= 0.5;
        uv.x -= 0.5 * (u.resolution.x / u.resolution.y);
        uv.x *= -1.;

        // Convert angle to number between [0, 1], with 0 being at "noon".
        float angle = mod(atan(uv.y, uv.x) / (2. * PI) - 0.25, 1.);

        // GLSL leaves this unset unless a spoke below matches; drivers start it at zero.
        float progressRadius = 0.;
        float progressAngle = ceil(u.progress * NUM_SPOKES / 100.);

        vec4 color = vec4(0.);
        for (float i = -0.2; i < NUM_SPOKES; i += 1.) {
            float segmentedAngle = 1. / NUM_SPOKES * i;
            // Only process the segment if we're in the area.
            if (angle > segmentedAngle - 2. / NUM_SPOKES && angle < segmentedAngle + 2. / NUM_SPOKES) {
                float level = max(0.01, getTweenedLoudness(loudness, segmentedAngle, u.crossfade));
                vec4 tint = vec4(getTweenedTexture(palette, level * 1.2, u.crossfade).rgb, 0.8);
                float radius = INNER_RADIUS + level / 1.9;
                color += soundprintArc(uv, INNER_RADIUS, radius, angle, ANGLE_OFFSET * i) * tint;

                if (i + 0.2 == progressAngle) {
                    progressRadius = radius;
                }
            }
        }

        // Progress bar.
        color = color + soundprintArc(uv, progressRadius, 2., angle + 0.2 / NUM_SPOKES, ANGLE_OFFSET * progressAngle) * vec4(0.5);

        return vizOutput(color);
    }
    """#
}
