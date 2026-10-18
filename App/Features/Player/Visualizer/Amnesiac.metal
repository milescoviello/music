#include "VisualizerShaders.h"

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
static float3 amnesiacIntersectCoordSys(float3 o, float3 d, float3 c, float3 u, float3 v) {
    float3 q = o - c;
    float3 n = cross(u, v);
    float t = -dot(n, q) / dot(d, n);
    float r = dot(u, q + d * t);
    float s = dot(v, q + d * t);
    return float3(t, s, r);
}

// Precise sine: the hash multiplies it by 43758, so a fast sine's error would move
// every disc away from where Plexamp puts it.
static float3 amnesiacHash3(float n) {
    return fract(precise::sin(float3(n, n + 1.0, n + 2.0)) * float3(43758.5453123, 12578.1459123, 19642.3490423));
}

static float3 amnesiacShade(float4 res, float time, texture2d<float> palette,
                            texture2d<float> frequencies, float crossfade) {
    float ra = length(res.yz);
    float an = atan2(res.y, res.z) + 10.0 * (time / 5.0 + 1.5 + getFrequencyValue(frequencies, res.a / float(NUM_DISCS), FREQ_AMPLITUDE));
    float pa = sin(3.0 * an);

    // Color.
    float3 cola = getTweenedTexture(palette, res.a / float(NUM_DISCS), crossfade).rgb;

    float3 col = float3(0.0);
    col += cola * 0.4 * (1.0 - smoothstep(0.90, 1.00, ra));
    col += cola * 1.0 * (1.0 - smoothstep(0.00, 0.03, abs(ra - 0.8))) * (0.5 + 0.5 * pa);
    col += cola * 1.0 * (1.0 - smoothstep(0.00, 0.20, abs(ra - 0.8))) * (0.5 + 0.5 * pa);
    col += cola * 0.5 * (1.0 - smoothstep(0.05, 0.10, abs(ra - 0.5))) * (0.5 + 0.5 * pa);
    col += cola * 0.7 * (1.0 - smoothstep(0.00, 0.30, abs(ra - 0.5))) * (0.5 + 0.5 * pa);

    return col * 0.3;
}

static float3 amnesiacRender(float3 ro, float3 rd, float time, texture2d<float> palette,
                             texture2d<float> frequencies, float crossfade) {
    // Raytrace.
    float3 col = float3(0.0);
    for (int i = 0; i < NUM_DISCS; i++) {
        // Position disk.
        float3 r = 2.5 * (-1.0 + 2.0 * amnesiacHash3(float(i)))
            + float3(0, getFrequencyValue(frequencies, float(i) / float(NUM_DISCS), FREQ_AMPLITUDE) * 3.0, 0);
        r *= SC;

        // Orientate disk.
        float3 u = normalize(r.zxy);
        float3 v = normalize(cross(u, float3(0.0, 1.0, 0.0)));

        // Intersect coord sys.
        float3 tmp = amnesiacIntersectCoordSys(ro, rd, r, u, v);
        tmp /= SC;
        if (dot(tmp.yz, tmp.yz) < 1.0 && tmp.x > 0.0) {
            // Shade.
            col += amnesiacShade(float4(tmp, float(i)), time, palette, frequencies, crossfade);
        }
    }

    return col;
}

VIZ_FRAGMENT(viz_amnesiac) {
    float2 fragCoord = vizFragCoord(in, u);
    float2 q = fragCoord / u.resolution;
    float2 p = -1.0 + 2.0 * q;
    p.x *= u.resolution.x / u.resolution.y;

    // Camera.
    float3 ro = 2.0 * float3(cos(0.5 * u.time * 1.1), 0.0, sin(0.5 * u.time * 1.1));
    float3 ta = float3(0.0, 0.0, 0.0);

    // Camera matrix.
    float3 ww = normalize(ta - ro);
    float3 uu = normalize(cross(ww, float3(0.0, 1.0, 0.0)));
    float3 vv = normalize(cross(uu, ww));

    // Create view ray.
    float3 rd = normalize(p.x * uu + p.y * vv + 1.0 * ww);

    float3 col = amnesiacRender(ro * SC, rd, u.time, palette, frequencies, u.crossfade);
    return vizOutput(float4(col, length(col)));
}
