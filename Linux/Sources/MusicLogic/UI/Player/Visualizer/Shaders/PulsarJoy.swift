extension VisualizerShaders {
    /// `viz_pulsar_joy`: App/Features/Player/Visualizer/PulsarJoy.metal in GLSL.
    static let pulsarJoy = #"""
    // Pulsar Joy: the last second of spectrum as stacked white lines, nearest at the
    // bottom, each humped in the middle like the pulsar plot on Unknown Pleasures. A
    // nearer line hides the ones behind it.

    #define BOOST 3.
    #define STEPS 32.
    #define THICKNESS .005

    vec4 vizMain() {
        vec2 fragCoord = gl_FragCoord.xy;
        vec2 uv = fragCoord / u.resolution;
        uv.y /= u.resolution.x / u.resolution.y;

        vec4 color = vec4(0.);
        bool drawn = false;

        for (float i = 0.; i < STEPS - 1.; i += 1.) {
            float dim = 1.0 - (i / STEPS / 1.2);
            float offset = i / STEPS * 0.7 + 0.01 - 0.003 * i;

            if (!drawn) {
                float row = mod(u.frequencyHistoryIndex - i, STEPS) / STEPS;
                float level = texture(history, vec2(uv.x, row)).r;
                float vol = level * pow(0.5 - abs(uv.x - 0.5), 1.7) * BOOST;
                float line = offset + vol;
                float linePct = smoothstep(line - THICKNESS, line, uv.y) - smoothstep(line, line + THICKNESS, uv.y);

                color = vec4(linePct);
                color.a = color.a * dim;
                drawn = uv.y < (offset + vol + THICKNESS);
            }
        }

        return vizOutput(color);
    }
    """#
}
