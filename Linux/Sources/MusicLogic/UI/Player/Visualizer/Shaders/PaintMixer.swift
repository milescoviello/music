extension VisualizerShaders {
    /// `viz_paint_mixer`: App/Features/Player/Visualizer/PaintMixer.metal in GLSL.
    static let paintMixer = #"""
    // Paint Mixer: a field of swirling, folded colour, like paint being stirred, flowing
    // toward the viewer; the spectrum pushes every step of the march, so the music bends
    // the folds. Its colours are the palette looked up by the field's brightness.

    #define ITERATIONS 32

    float paintField(vec3 p, float time) {
        p.y += 1.5 * sin(p.x + time * 2.);
        p.z += 2. * time;
        return length(.1 * sin(p.x / 1.5 + p.y) + cos(p.zzx / 4.)) - .9;
    }

    vec3 paintRgb2hsv(vec3 c) {
        vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
        vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
        vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));

        float d = q.x - min(q.w, q.y);
        float e = 1.0e-10;
        return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
    }

    vec4 vizMain() {
        vec2 fragCoord = gl_FragCoord.xy;
        vec3 d = .9 - vec3(fragCoord / .65, 0) / u.resolution.x;
        vec3 o = d;

        for (int i = 0; i < ITERATIONS; i++) {
            // Plexamp reads `.x` here, the first byte of its packed float, not the value.
            o += paintField(o, u.time) * d + vizHighByte(frequencies, vec2(float(i) / float(ITERATIONS), 0)) / 1.2;
        }

        vec3 rgb = abs(paintField(o * 1.8, u.time) * vec3(.3 + sin(o.x) / 3., .1, .1)
                       + paintField(o * .5, u.time) * vec3(.1, .05, 0)) * (9. - o.y / 3.);
        vec3 hsv = paintRgb2hsv(rgb);
        vec3 colour = getTweenedTexture(palette, hsv.z, u.crossfade).rgb;
        colour = colour * 0.7 + rgb * 0.3;
        return vizOutput(vec4(colour, 1.));
    }
    """#
}
