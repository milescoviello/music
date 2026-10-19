extension VisualizerShaders {
    /// `viz_amnesiac`: App/Features/Player/Visualizer/Amnesiac.metal in GLSL.
    static let amnesiac = #"""
    // Amnesiac: thirty-two rings of light hanging in space, each lifted by its band, as a
    // camera circles them. After Inigo Quilez's disc-intersection shader, as Plexamp has it:

    // The MIT License
    // Copyright © 2013 Inigo Quilez
    // Permission is hereby granted, free of charge, to any person obtaining a copy of this
    // software and associated documentation files (the "Software"), to deal in the Software
    // without restriction, including without limitation the rights to use, copy, modify,
    // merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
    // permit persons to whom the Software is furnished to do so, subject to the following
    // conditions: The above copyright notice and this permission notice shall be included in
    // all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS",
    // WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
    // WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
    // NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
    // OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT
    // OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

    #define SC 3.0
    #define NUM_DISCS 32

    // Ugly (but faster) way to intersect a planar coordinate system: plane + projection.
    vec3 amnesiacIntersectCoordSys(vec3 o, vec3 d, vec3 c, vec3 u, vec3 v) {
        vec3 q = o - c;
        vec3 n = cross(u, v);
        float t = -dot(n, q) / dot(d, n);
        float r = dot(u, q + d * t);
        float s = dot(v, q + d * t);
        return vec3(t, s, r);
    }

    // Precise sine: the hash multiplies it by 43758, so a fast sine's error would move
    // every disc away from where Plexamp puts it.
    vec3 amnesiacHash3(float n) {
        return fract(sin(vec3(n, n + 1.0, n + 2.0)) * vec3(43758.5453123, 12578.1459123, 19642.3490423));
    }

    vec3 amnesiacShade(vec4 res, float time, sampler2D palette,
                       sampler2D frequencies, float crossfade) {
        float ra = length(res.yz);
        float an = atan(res.y, res.z) + 10.0 * (time / 5.0 + 1.5 + getFrequencyValue(frequencies, res.a / float(NUM_DISCS), FREQ_AMPLITUDE));
        float pa = sin(3.0 * an);

        // Color.
        vec3 cola = getTweenedTexture(palette, res.a / float(NUM_DISCS), crossfade).rgb;

        vec3 col = vec3(0.0);
        col += cola * 0.4 * (1.0 - smoothstep(0.90, 1.00, ra));
        col += cola * 1.0 * (1.0 - smoothstep(0.00, 0.03, abs(ra - 0.8))) * (0.5 + 0.5 * pa);
        col += cola * 1.0 * (1.0 - smoothstep(0.00, 0.20, abs(ra - 0.8))) * (0.5 + 0.5 * pa);
        col += cola * 0.5 * (1.0 - smoothstep(0.05, 0.10, abs(ra - 0.5))) * (0.5 + 0.5 * pa);
        col += cola * 0.7 * (1.0 - smoothstep(0.00, 0.30, abs(ra - 0.5))) * (0.5 + 0.5 * pa);

        return col * 0.3;
    }

    vec3 amnesiacRender(vec3 ro, vec3 rd, float time, sampler2D palette,
                        sampler2D frequencies, float crossfade) {
        // Raytrace.
        vec3 col = vec3(0.0);
        for (int i = 0; i < NUM_DISCS; i++) {
            // Position disk.
            vec3 r = 2.5 * (-1.0 + 2.0 * amnesiacHash3(float(i)))
                + vec3(0, getFrequencyValue(frequencies, float(i) / float(NUM_DISCS), FREQ_AMPLITUDE) * 3.0, 0);
            r *= SC;

            // Orientate disk.
            vec3 u = normalize(r.zxy);
            vec3 v = normalize(cross(u, vec3(0.0, 1.0, 0.0)));

            // Intersect coord sys.
            vec3 tmp = amnesiacIntersectCoordSys(ro, rd, r, u, v);
            tmp /= SC;
            if (dot(tmp.yz, tmp.yz) < 1.0 && tmp.x > 0.0) {
                // Shade.
                col += amnesiacShade(vec4(tmp, float(i)), time, palette, frequencies, crossfade);
            }
        }

        return col;
    }

    vec4 vizMain() {
        vec2 fragCoord = gl_FragCoord.xy;
        vec2 q = fragCoord / u.resolution;
        vec2 p = -1.0 + 2.0 * q;
        p.x *= u.resolution.x / u.resolution.y;

        // Camera.
        vec3 ro = 2.0 * vec3(cos(0.5 * u.time * 1.1), 0.0, sin(0.5 * u.time * 1.1));
        vec3 ta = vec3(0.0, 0.0, 0.0);

        // Camera matrix.
        vec3 ww = normalize(ta - ro);
        vec3 uu = normalize(cross(ww, vec3(0.0, 1.0, 0.0)));
        vec3 vv = normalize(cross(uu, ww));

        // Create view ray.
        vec3 rd = normalize(p.x * uu + p.y * vv + 1.0 * ww);

        vec3 col = amnesiacRender(ro * SC, rd, u.time, palette, frequencies, u.crossfade);
        return vizOutput(vec4(col, length(col)));
    }
    """#
}
