// What every visualiser shader shares: Plexamp's GLSL preamble, in Metal.
//
// Plexamp's programs are WebGL fragment shaders drawn over one full-screen quad, all
// reading the same uniforms and four small textures. The helpers here are those
// shaders' own helpers, kept to the same names and maths so each program reads as a
// line-for-line port. Two things differ by necessity, and both are handled here rather
// than in every program:
//
// - GL's `gl_FragCoord` has its origin at the bottom left, Metal's at the top left.
//   `vizFragCoord` gives programs the GL one.
// - Plexamp packs each float into the four bytes of an RGBA8 texel and decodes it with
//   a dot product. The textures here are half floats, so a plain `.r` read is that
//   decode. Linear filtering gives the same answer either way: decoding is linear, so
//   interpolating the bytes and then decoding is interpolating the values.

#ifndef VisualizerShaders_h
#define VisualizerShaders_h

#include <metal_stdlib>
using namespace metal;

// Field for field with `VisualizerUniforms` in VisualizerRenderer.swift.
struct VisualizerUniforms {
    float2 resolution;
    float time;
    float progress;
    float crossfade;
    float pixelRatio;
    float frequencyHistoryIndex;
    float unused;
};

struct VisualizerVertexOut {
    float4 position [[position]];
};

#define HALF_PI 1.5707963267948966
#define PI 3.14159265358
#define TWO_PI (2. * 3.141592653589793)

#define FREQ_AMPLITUDE 0
#define FREQ_PEAKS 1

// Every program's entry point has this signature; the renderer binds to these slots.
#define VIZ_FRAGMENT(name) \
    fragment float4 name(VisualizerVertexOut in [[stage_in]], \
                         constant VisualizerUniforms &u [[buffer(0)]], \
                         texture2d<float> palette [[texture(0)]], \
                         texture2d<float> frequencies [[texture(1)]], \
                         texture2d<float> loudness [[texture(2)]], \
                         texture2d<float> history [[texture(3)]])

// The samplers Plexamp's DataTextures were made with: clamped, linear for all but the
// loudness, which is nearest.
constexpr sampler vizLinear(coord::normalized, address::clamp_to_edge, filter::linear);
constexpr sampler vizNearest(coord::normalized, address::clamp_to_edge, filter::nearest);

inline float2 vizFragCoord(VisualizerVertexOut in, constant VisualizerUniforms &u) {
    return float2(in.position.x, u.resolution.y - in.position.y);
}

// What reaches the screen in Plexamp, and it is not plain "over". The canvas is cleared
// to transparent and the quad drawn with blending left on at SRC_ALPHA,
// ONE_MINUS_SRC_ALPHA for colour and alpha alike, so the buffer ends up holding
// (rgb·a, a·a). The page then composites that as premultiplied: rgb·a + behind·(1 − a²).
// Returned here as that premultiplied pair, for a non-opaque layer to composite the
// same way.
inline float4 vizOutput(float4 colour) {
    float4 c = saturate(colour);
    return float4(c.rgb * c.a, c.a * c.a);
}

// GLSL's mod: floored, where Metal's fmod truncates. They differ for negatives, which
// the angle maths in several programs produces. Metal has no `mod` of its own, so the
// programs can keep the GLSL name.
inline float mod(float x, float y) {
    return x - y * floor(x / y);
}

inline float3 mod(float3 x, float3 y) {
    return x - y * floor(x / y);
}

// GLSL's smoothstep, written out. The programs often pass the edges reversed —
// `smoothstep(w + aa, w - aa, d)` for "1 inside, 0 outside" — which every GL driver
// answers by the formula and Metal's documentation leaves undefined. The formula is the
// same whichever way round the edges are, so this is the GL behaviour by construction.
inline float glslSmoothstep(float edge0, float edge1, float x) {
    float t = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

inline float3 glslSmoothstep(float edge0, float edge1, float3 x) {
    float3 t = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

#define smoothstep glslSmoothstep

inline float cubicOut(float t) {
    float f = t - 1.0;
    return f * f * f + 1.0;
}

inline float getFrequencyValue(texture2d<float> frequencies, float val, int index) {
    return frequencies.sample(vizLinear, float2(val, float(index))).r;
}

// Rows 0 and 1 are this track and the last; `crossfade` runs 0 to 1 over a second
// after a track change and sits at 1 otherwise.
inline float getTweenedLoudness(texture2d<float> loudness, float value, float crossfade) {
    float current = loudness.sample(vizNearest, float2(value, 0)).r;
    if (crossfade == 1.0) {
        return current;
    }
    float previous = loudness.sample(vizNearest, float2(value, 1)).r;
    return mix(previous, current, cubicOut(crossfade));
}

inline float4 getTweenedTexture(texture2d<float> palette, float value, float crossfade) {
    float4 current = palette.sample(vizLinear, float2(value, 0));
    if (crossfade == 1.0) {
        return current;
    }
    float4 previous = palette.sample(vizLinear, float2(value, 1));
    return mix(previous, current, float4(cubicOut(crossfade)));
}

// What a GLSL `texture2D(...).x` of a spectrum texture sees, for the two programs that
// read it that way (Paint Mixer, Trails) instead of decoding all four bytes: the packed
// float's first byte, floor(v × 255) / 255, linearly filtered. Done by hand — four
// texels, each quantised, then mixed — because filtering first and quantising after is
// not the same number.
inline float vizHighByte(texture2d<float> texture, float2 uv) {
    float2 size = float2(texture.get_width(), texture.get_height());
    float2 st = uv * size - 0.5;
    float2 base = floor(st);
    float2 f = st - base;
    int2 last = int2(size) - 1;
    int2 i0 = clamp(int2(base), int2(0), last);
    int2 i1 = clamp(int2(base) + 1, int2(0), last);
    float q00 = floor(texture.read(uint2(i0.x, i0.y)).r * 255.) / 255.;
    float q10 = floor(texture.read(uint2(i1.x, i0.y)).r * 255.) / 255.;
    float q01 = floor(texture.read(uint2(i0.x, i1.y)).r * 255.) / 255.;
    float q11 = floor(texture.read(uint2(i1.x, i1.y)).r * 255.) / 255.;
    return mix(mix(q00, q10, f.x), mix(q01, q11, f.x), f.y);
}

// Plexamp's "improved bilinear" fetch: two explicit taps either side, mixed.
inline float getFrequencyValueBilinear(texture2d<float> frequencies, float val, int index) {
    float2 res = float2(64., 2.);
    float2 st = float2(val, float(index)) * res - 0.5;

    float2 iuv = floor(st);
    float2 fuv = fract(st);

    float a = getFrequencyValue(frequencies, ((iuv + float2(0.5, 0.5)) / res).x, index);
    float b = getFrequencyValue(frequencies, ((iuv + float2(1.5, 0.5)) / res).x, index);

    return mix(a, b, fuv.x);
}

#endif
