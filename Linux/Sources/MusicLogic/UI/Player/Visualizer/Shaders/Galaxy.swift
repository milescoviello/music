extension VisualizerShaders {
    /// `viz_galaxy`: App/Features/Player/Visualizer/Galaxy.metal in GLSL.
    static let galaxy = #"""
    // Galaxy: seventy-two out-of-focus discs flung outward from the centre by their bands,
    // and twelve beams of light from the middle, seen by a camera circling the whole.

    // Precise sine, as in Plexamp's `highp` hash: a fast sine's error times 43758 would
    // scatter the discs somewhere else.
    float galaxyHash(float n) {
        float a = 12.9898;
        float b = 78.233;
        float c = 43758.5453;
        float dt = dot(vec2(n, n), vec2(a, b));
        float sn = mod(dt, 3.14);
        return fract(sin(sn) * c);
    }

    vec3 galaxyClosestPointFromLineToLine(vec3 l1Start, vec3 l1End, vec3 l2Start, vec3 l2End,
                                          out float dist) {
        vec3 u = l1End - l1Start;
        vec3 v = l2End - l1Start;
        vec3 w = l1Start - l2Start;
        float a = dot(u, u);
        float b = dot(u, v);
        float c = dot(v, v);
        float d = dot(u, w);
        float e = dot(v, w);
        float D = a * c - b * b;
        float sc, tc;

        if (D < 0.001) {
            sc = 0.0;
            tc = (b > c ? d / b : e / c);
        } else {
            sc = (b * e - c * d) / D;
            tc = (a * e - b * d) / D;
        }

        vec3 closestPoint = (tc * v);
        vec3 dP = w + (sc * u) - closestPoint;
        dist = length(dP);

        // Make sure we're not following the line the wrong direction.
        if (dot(closestPoint - l2Start, l2End - l2Start) < 0.) {
            dist = 1000.;
        }

        return closestPoint;
    }

    float galaxyBokehRing(vec3 ro, vec3 rd, vec3 p, float size, float blur) {
        float dist = length(cross(p - ro, rd));
        float m = smoothstep(size, size * (1. - blur), dist);
        m *= mix(.25, 1., smoothstep(.95 * size, size, dist));
        return m;
    }

    vec3 galaxyDisc(vec3 cameraPos, vec3 rd, vec3 p, sampler2D palette, float crossfade) {
        float distanceFromOrigin = length(p);

        // Focus is on a plane from origin.
        float distanceFromFocalPlane = abs(15. - length(p - cameraPos));
        float blur = (distanceFromFocalPlane < 4.) ? 0.05 : min(distanceFromFocalPlane / 2., .5);
        float m = galaxyBokehRing(cameraPos, rd, p, .55, blur);

        // Fade out as we get closer to origin.
        float brightness = min(distanceFromOrigin / 1.7, 3.);

        return m * brightness * getTweenedTexture(palette, length(p - vec3(0, 0, 0)) / 7.0, crossfade).rgb;
    }

    vec3 galaxyLine(vec3 cameraPos, vec3 rayDirection, vec3 lineOrigin, vec3 lineDirection, vec3 color) {
        float dist;
        vec3 closestPoint = galaxyClosestPointFromLineToLine(cameraPos, cameraPos + rayDirection * 100.,
                                                             lineOrigin, lineOrigin + lineDirection * 100., dist);
        float distFromOrigin = length(closestPoint - vec3(0));
        float distFromCamera = length(cameraPos - closestPoint);

        return color * (1. - smoothstep(0., 0.03 + distFromOrigin / 7., dist)) / (1.5 * distFromCamera / 2.0);
    }

    vec3 galaxyCreateRay(vec2 uvOrig, vec3 cameraPos, vec3 lookAt, vec2 resolution) {
        vec2 uv = uvOrig;
        uv -= .5;
        uv.x *= resolution.x / resolution.y;

        vec3 rayOrigin = cameraPos;
        vec3 forward = normalize(lookAt - rayOrigin);
        vec3 right = cross(vec3(0, 1, 0), forward);
        vec3 up = cross(forward, right);
        vec3 center = rayOrigin + forward;
        vec3 intersect = center + (uv.x * right) + (uv.y * up);

        return normalize(intersect - rayOrigin);
    }

    #define BALL_SETS 3.
    #define NUM_RAYS 12.

    vec4 vizMain() {
        vec2 fragCoord = gl_FragCoord.xy;

        // Create normalized coord system centered on 0,0.
        vec2 uv = fragCoord / u.resolution;

        vec3 cameraPos = vec3(sin(u.time) * 10., 0., -10. * cos(u.time));
        vec3 lookAt = vec3(0, 0, 0);
        vec3 ray = galaxyCreateRay(uv, cameraPos, lookAt, u.resolution);
        vec3 col = vec3(0.);

        // Render the discs.
        for (float j = 0.; j < 24. * BALL_SETS; j += 1.) {
            float i = mod(j, 24.);
            float zeroToOne = i / 23.;
            float vol = getFrequencyValue(frequencies, zeroToOne, FREQ_AMPLITUDE);
            vec3 ballRay = normalize(vec3(galaxyHash(j) - 0.5, galaxyHash(j * 3.) - 0.5, galaxyHash(j * 5.) - 0.5));

            col += galaxyDisc(cameraPos, ray, ballRay * vol * 15., palette, u.crossfade);
        }

        // Render the rays.
        for (float j = 0.; j < NUM_RAYS; j += 1.) {
            float vol = getFrequencyValue(frequencies, j / (NUM_RAYS - 1.), FREQ_AMPLITUDE);
            vec3 color = getTweenedTexture(palette, vol + 0.1, u.crossfade).rgb;
            vol /= 4.;

            // Pick a semi-random direction.
            float random = galaxyHash(j);
            vec3 lightDir = normalize(vec3(sin(j + random + vol) + .1, cos(j + vol) + cos(u.time / 100.) / 3. - .1, random));

            // Turn down brightness if it's pointing towards us, avoids flashes.
            float dotRay = dot(lightDir, ray);
            float brightness = 1. - smoothstep(-0.1, -0.9, dotRay);

            // Offset the origin just a tiny bit in the right direction so they don't overlap on origin.
            vec3 lightOrigin = vec3(0.) + 0.01 * lightDir;
            col += brightness * galaxyLine(cameraPos, ray, lightOrigin, lightDir, color) * 1.5;
        }

        return vizOutput(vec4(col, length(col)));
    }
    """#
}
