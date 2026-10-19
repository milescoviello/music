extension VisualizerShaders {
    /// `viz_disco_ball`: App/Features/Player/Visualizer/DiscoBall.metal in GLSL.
    static let discoBall = #"""
    // Disco Ball: a raymarched sphere that throws out spikes — round its equator from the
    // spectrum by angle, up and down from the spectrum by height — breathing with the bass,
    // lit from above with a rim of a second palette colour, as the camera orbits it.

    #define MAX_STEPS 100
    #define MAX_DIST 50.0
    #define SURF_DIST 0.001

    // `bass` and `mid` are the same for every point of the frame, so they are read once
    // and passed in; the distances come out exactly as if read at every step.
    float discoSpikes(vec3 p, float time, float bass, float mid, sampler2D frequencies) {
        // Normalize direction.
        vec3 dir = normalize(p);
        float ang = atan(dir.z, dir.x) / (2.0 * PI) + 0.5;
        float vert = dir.y * 0.5 + 0.5;

        // Sample bands.
        float eqAmp = getFrequencyValue(frequencies, ang, FREQ_AMPLITUDE);
        float vertAmp = getFrequencyValue(frequencies, vert, FREQ_AMPLITUDE);

        // Base radius pulsing with bass.
        float baseR = 1.0 + bass * 0.1 + sin(time * 0.3) * 0.05;

        // Directional spike pattern around the equator.
        float pattern = sin(ang * PI * 32.0);

        // Spike lengths: equatorial spikes scaled by eqAmp and mid, vertical by vertAmp.
        float spikeE = eqAmp * 2.0 + abs(pattern * mid * 0.5);
        float spikeV = vertAmp * 1.0;

        // Combined radius.
        float r = baseR + spikeE + spikeV;
        return length(p) - r;
    }

    // Approximate normal by central differences.
    vec3 discoNormal(vec3 p, float time, float bass, float mid, sampler2D frequencies) {
        vec2 e = vec2(0.001, 0.0);
        return normalize(vec3(
            discoSpikes(p + e.xyy, time, bass, mid, frequencies) - discoSpikes(p - e.xyy, time, bass, mid, frequencies),
            discoSpikes(p + e.yxy, time, bass, mid, frequencies) - discoSpikes(p - e.yxy, time, bass, mid, frequencies),
            discoSpikes(p + e.yyx, time, bass, mid, frequencies) - discoSpikes(p - e.yyx, time, bass, mid, frequencies)
        ));
    }

    // Raymarch the scene.
    vec3 discoRaymarch(vec3 ro, vec3 rd, float time, sampler2D palette,
                       sampler2D frequencies, float crossfade) {
        float bass = getFrequencyValue(frequencies, 0.1, FREQ_AMPLITUDE);
        float mid = getFrequencyValue(frequencies, 0.5, FREQ_AMPLITUDE);

        float dist = 0.0;
        for (int i = 0; i < MAX_STEPS; i++) {
            vec3 pos = ro + rd * dist;
            float d = discoSpikes(pos, time, bass, mid, frequencies);
            dist += d;
            if (dist > MAX_DIST || abs(d) < SURF_DIST) break;
        }
        if (dist > MAX_DIST) return vec3(0.0);

        vec3 hit = ro + rd * dist;
        vec3 n = discoNormal(hit, time, bass, mid, frequencies);

        // Simple lighting.
        float diff = max(dot(n, vec3(0, 1, 0)), 0.0);
        float fres = pow(1.0 - dot(n, -rd), 3.0);

        // Color by overall loudness.
        float loud = (bass + mid + getFrequencyValue(frequencies, 0.9, FREQ_AMPLITUDE)) / 3.0;
        float hue = fract(time * 0.1 + loud * 0.4);

        vec3 c1 = getTweenedTexture(palette, hue, crossfade).rgb * diff;
        vec3 c2 = getTweenedTexture(palette, fract(hue + 0.5), crossfade).rgb * fres;
        return mix(c1, c2, 0.5);
    }

    vec4 vizMain() {
        vec2 fragCoord = gl_FragCoord.xy;

        // Normalize UV.
        vec2 uv = (fragCoord / u.resolution) * 2.0 - 1.0;
        uv.x *= u.resolution.x / u.resolution.y;

        // Camera setup: orbit around y-axis.
        float ca = cos(u.time * 0.2), sa = sin(u.time * 0.2);
        vec3 ro = vec3(5.0 * sa, 1.5, 5.0 * ca);
        vec3 look = vec3(0.0, 0.0, 0.0);
        vec3 fwd = normalize(look - ro);
        vec3 right = normalize(cross(vec3(0, 1, 0), fwd));
        vec3 up = cross(fwd, right);
        vec3 rd = normalize(uv.x * right + uv.y * up + 1.5 * fwd);

        // Raymarch and color. Plexamp also bends `uv` by the bass afterwards and never uses
        // it, so that is left out; the alpha is a flat half.
        vec3 col = discoRaymarch(ro, rd, u.time, palette, frequencies, u.crossfade);
        return vizOutput(vec4(col, 0.5));
    }
    """#
}
