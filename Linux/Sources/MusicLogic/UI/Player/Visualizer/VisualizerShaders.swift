/// The visualisers' GLSL: Plexamp's WebGL programs as the phone ported them to Metal,
/// brought back. One file per program under `Shaders/`, as the phone has one `.metal`
/// file each; this one holds what they share and the table the renderer looks them up in.
enum VisualizerShaders {
    /// The program for a `VisualizerProgram.function`, with the prelude in front and no
    /// version line: the renderer adds the one its context speaks.
    static func fragment(_ function: String) -> String? {
        programs[function].map { prelude + "\n" + $0 }
    }

    /// One triangle that covers the whole target, which is all a fragment-shader
    /// visualiser needs, made from the vertex index alone.
    static let vertex = #"""
    void main() {
        vec2 position = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2)) * 2.0 - 1.0;
        gl_Position = vec4(position, 0.0, 1.0);
    }
    """#

    private static let programs: [String: String] = [
        "viz_amnesiac": amnesiac,
        "viz_amoeba": amoeba,
        "viz_aurora": aurora,
        "viz_disco_ball": discoBall,
        "viz_freaqy": freaqy,
        "viz_galaxy": galaxy,
        "viz_hyper_paint": hyperPaint,
        "viz_neutrona": neutrona,
        "viz_paint_mixer": paintMixer,
        "viz_pulsar_joy": pulsarJoy,
        "viz_retrospect": retrospect,
        "viz_rothko": rothko,
        "viz_scratch": scratch,
        "viz_shuriken": shuriken,
        "viz_snowflake": snowflake,
        "viz_soundprint": soundprint,
        "viz_spectrum": spectrum,
        "viz_strings": strings,
        "viz_trails": trails,
        "viz_vertigo": vertigo,
        "viz_waffles": waffles,
    ]

    static let prelude = #"""
    // What every visualiser shares: Plexamp's GLSL preamble, as the phone's Metal port has it.
    //
    // Plexamp's programs are WebGL fragment shaders drawn over one full-screen quad, all
    // reading the same uniforms and four small textures. The phone ported them to Metal;
    // these are those ports brought back to GLSL, so each program still reads line for line
    // against the phone's .metal file. The renderer puts the version line in front: GLSL
    // 1.50 on desktop GL, ES 3.00 on GLES.
    //
    // - Plexamp packs each float into the four bytes of an RGBA8 texel and decodes it with a
    //   dot product. The textures here are half floats, so a plain `.r` read is that decode.
    // - The phone's VisualizerUniforms, as a uniform struct, so the programs keep `u.time`.

    precision highp float;
    precision highp int;
    precision highp sampler2D;

    struct VisualizerUniforms {
        vec2 resolution;
        float time;
        float progress;
        float crossfade;
        float pixelRatio;
        float frequencyHistoryIndex;
    };

    uniform VisualizerUniforms u;
    uniform sampler2D palette;
    uniform sampler2D frequencies;
    uniform sampler2D loudness;
    uniform sampler2D history;

    out vec4 vizFragColour;

    #define HALF_PI 1.5707963267948966
    #define PI 3.14159265358
    #define TWO_PI (2. * 3.141592653589793)

    #define FREQ_AMPLITUDE 0
    #define FREQ_PEAKS 1

    // What reaches the screen in Plexamp: the canvas cleared to transparent and the quad
    // blended at SRC_ALPHA, ONE_MINUS_SRC_ALPHA for colour and alpha alike, so the buffer
    // holds (rgb·a, a·a), which the page composites as premultiplied. GTK composites a GL
    // area as premultiplied too, so this is returned as that pair.
    vec4 vizOutput(vec4 colour) {
        vec4 c = clamp(colour, 0.0, 1.0);
        return vec4(c.rgb * c.a, c.a * c.a);
    }

    // GLSL's smoothstep by its formula. The programs often pass the edges reversed — "1
    // inside, 0 outside" — which the specification leaves undefined and every driver answers
    // by the formula; written out, it is that answer everywhere.
    float vizSmoothstep(float edge0, float edge1, float x) {
        float t = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
        return t * t * (3.0 - 2.0 * t);
    }

    vec3 vizSmoothstep(float edge0, float edge1, vec3 x) {
        vec3 t = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
        return t * t * (3.0 - 2.0 * t);
    }

    #define smoothstep vizSmoothstep

    float cubicOut(float t) {
        float f = t - 1.0;
        return f * f * f + 1.0;
    }

    float getFrequencyValue(sampler2D frequencies, float val, int index) {
        return texture(frequencies, vec2(val, float(index))).r;
    }

    // Rows 0 and 1 are this track and the last; `crossfade` runs 0 to 1 over a second after
    // a track change and sits at 1 otherwise.
    float getTweenedLoudness(sampler2D loudness, float value, float crossfade) {
        float current = texture(loudness, vec2(value, 0.)).r;
        if (crossfade == 1.0) {
            return current;
        }
        float previous = texture(loudness, vec2(value, 1.)).r;
        return mix(previous, current, cubicOut(crossfade));
    }

    vec4 getTweenedTexture(sampler2D palette, float value, float crossfade) {
        vec4 current = texture(palette, vec2(value, 0.));
        if (crossfade == 1.0) {
            return current;
        }
        vec4 previous = texture(palette, vec2(value, 1.));
        return mix(previous, current, vec4(cubicOut(crossfade)));
    }

    // What a GLSL `texture2D(...).x` of a spectrum texture sees in Plexamp, for the two
    // programs that read it that way (Paint Mixer, Trails): the packed float's first byte,
    // floor(v × 255) / 255, linearly filtered. Four texels quantised, then mixed, because
    // filtering first and quantising after is not the same number.
    float vizHighByte(sampler2D source, vec2 uv) {
        vec2 size = vec2(textureSize(source, 0));
        vec2 st = uv * size - 0.5;
        vec2 base = floor(st);
        vec2 f = st - base;
        ivec2 last = ivec2(size) - 1;
        ivec2 i0 = clamp(ivec2(base), ivec2(0), last);
        ivec2 i1 = clamp(ivec2(base) + 1, ivec2(0), last);
        float q00 = floor(texelFetch(source, ivec2(i0.x, i0.y), 0).r * 255.) / 255.;
        float q10 = floor(texelFetch(source, ivec2(i1.x, i0.y), 0).r * 255.) / 255.;
        float q01 = floor(texelFetch(source, ivec2(i0.x, i1.y), 0).r * 255.) / 255.;
        float q11 = floor(texelFetch(source, ivec2(i1.x, i1.y), 0).r * 255.) / 255.;
        return mix(mix(q00, q10, f.x), mix(q01, q11, f.x), f.y);
    }

    // Plexamp's "improved bilinear" fetch: two explicit taps either side, mixed.
    float getFrequencyValueBilinear(sampler2D frequencies, float val, int index) {
        vec2 res = vec2(64., 2.);
        vec2 st = vec2(val, float(index)) * res - 0.5;

        vec2 iuv = floor(st);
        vec2 fuv = fract(st);

        float a = getFrequencyValue(frequencies, ((iuv + vec2(0.5, 0.5)) / res).x, index);
        float b = getFrequencyValue(frequencies, ((iuv + vec2(1.5, 0.5)) / res).x, index);

        return mix(a, b, fuv.x);
    }

    // Each program is written as the phone's are, returning its colour.
    vec4 vizMain();

    void main() {
        vizFragColour = vizMain();
    }
    """#
}
