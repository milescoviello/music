#include "VisualizerShaders.h"

// Amoeba: fourteen soft blobs circling the centre, each pushed out by its band, melting
// into one another; where they pile up the palette shows through by distance. After
// Inigo Quilez's metaballs, as Plexamp has it:

// The MIT License
// Copyright © 2014 Inigo Quilez
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

#define BALLS 14

VIZ_FRAGMENT(viz_amoeba) {
    float2 fragCoord = vizFragCoord(in, u);
    float2 uv = (-u.resolution + 2.0 * fragCoord) / u.resolution.y;
    float3 v = float3(0);
    float delta = 3.141592653589793 * 2. / float(BALLS);

    // Plexamp fills two arrays and then sums them; one pass sums the same terms in the
    // same order.
    for (int i = 0; i < BALLS; i++) {
        // Anim.
        float angle = delta * float(i) + (u.time * 0.5 + getFrequencyValue(frequencies, 0.7, FREQ_AMPLITUDE));
        float vol = getFrequencyValue(frequencies, float(i) / float(BALLS), FREQ_AMPLITUDE) * 4.0 + sin(u.time / 3.0) / 3.0;
        float2 ball = float2(sin(angle) * 0.5, cos(angle) * 0.5) * vol;
        float3 colour = getTweenedTexture(palette, vol / 2.5, u.crossfade).rgb;

        // Potential.
        v += (1.0 - smoothstep(0.2, 0.4, length(uv - ball))) * colour;
    }

    float3 col = mix(v, getTweenedTexture(palette, length(uv), u.crossfade).rgb, smoothstep(0.6, 0.91, v));
    return vizOutput(float4(col, sqrt(length(col))));
}
