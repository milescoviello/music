extension VisualizerShaders {
    /// `viz_waffles`: App/Features/Player/Visualizer/Waffles.metal in GLSL.
    static let waffles = #"""
    // Waffles: a raymarched ball whose skin is a grid of moving bumps, waffle-like, raised
    // round its circumference by the spectrum, lit by a point light with a sharp specular
    // and coloured by how high each bump stands.

    const float eps = 0.005;
    const int maxIterations = 128;
    const float stepScale = 0.5;
    const float stopThreshold = 0.005;

    float wafflesSphere(vec3 p, vec3 centerPos, float radius) {
        return length(p - centerPos) - radius;
    }

    float wafflesBumps(vec3 p, float time, sampler2D frequencies) {
        float samplePoint = mod((atan(p.x + 0.5, p.z) + PI) / PI / 2., 1.0);
        float vol = getFrequencyValueBilinear(frequencies, samplePoint, FREQ_AMPLITUDE) + 0.03;
        return -(vol * 8. * (0.5 + sin(p.x * 16. + time * 0.57) * cos(p.y * 16. + time * 2.17) * sin(p.z * 16. - time * 1.31)
                             + 0.5 * sin(p.x * 32. + time * 0.07) * cos(p.y * 32. + time * 2.11) * sin(p.z * 32. - time * 1.23)));
    }

    float wafflesScene(vec3 p, float time, sampler2D frequencies) {
        return wafflesSphere(p, vec3(0., 0., 3.), 2.4) + 0.04 * wafflesBumps(p, time, frequencies);
    }

    vec3 wafflesNormal(vec3 p, float time, sampler2D frequencies) {
        // 6-tap normalization. Probably the most accurate, but a bit of a cycle waster.
        return normalize(vec3(
            wafflesScene(vec3(p.x + eps, p.y, p.z), time, frequencies) - wafflesScene(vec3(p.x - eps, p.y, p.z), time, frequencies),
            wafflesScene(vec3(p.x, p.y + eps, p.z), time, frequencies) - wafflesScene(vec3(p.x, p.y - eps, p.z), time, frequencies),
            wafflesScene(vec3(p.x, p.y, p.z + eps), time, frequencies) - wafflesScene(vec3(p.x, p.y, p.z - eps), time, frequencies)
        ));
    }

    float wafflesMarch(vec3 origin, vec3 dir, float start, float end, float time, sampler2D frequencies) {
        float sceneDist = 1e4;
        float rayDepth = start;
        for (int i = 0; i < maxIterations; i++) {
            sceneDist = wafflesScene(origin + dir * rayDepth, time, frequencies);
            if ((sceneDist < stopThreshold) || (rayDepth >= end)) {
                break;
            }
            rayDepth += sceneDist * stepScale;
        }

        if (sceneDist >= stopThreshold) {
            rayDepth = end;
        } else {
            rayDepth += sceneDist;
        }

        return rayDepth;
    }

    vec4 vizMain() {
        vec2 fragCoord = gl_FragCoord.xy;
        vec2 aspect = vec2(u.resolution.x / u.resolution.y, 1.0);
        vec2 screenCoords = (2.0 * fragCoord / u.resolution - 1.0) * aspect;

        vec3 lookAt = vec3(0., 0., 0.);
        vec3 camPos = vec3(0., 0., -0.8);

        // Camera setup.
        vec3 forward = normalize(lookAt - camPos);
        vec3 right = normalize(vec3(forward.z, 0., -forward.x));
        vec3 up = normalize(cross(forward, right));
        float FOV = 0.5;

        vec3 ro = camPos;
        vec3 rd = normalize(forward + FOV * screenCoords.x * right + FOV * screenCoords.y * up);

        // Ray marching.
        const float clipNear = 0.0;
        const float clipFar = 10.0;
        float dist = wafflesMarch(ro, rd, clipNear, clipFar, u.time, frequencies);
        if (dist >= clipFar) {
            return vizOutput(vec4(0.));
        }

        // Surface position, and its normal.
        vec3 sp = ro + rd * dist;
        vec3 surfNormal = wafflesNormal(sp, u.time, frequencies);

        // Light position and direction.
        vec3 lp = vec3(0.5, 0.5, -1.);
        vec3 ld = lp - sp;
        vec3 lightColor = vec3(1., 0.97, 0.92);

        float len = length(ld);
        ld /= len;
        float lightAtten = min(1.0 / (0.25 * len * len), 1.0);
        vec3 ref = reflect(-ld, surfNormal);

        vec3 sceneColor = vec3(1) * surfNormal.y * 0.1;

        float bumps = wafflesBumps(sp, u.time, frequencies);
        vec3 objColor = getTweenedTexture(palette, clamp(abs(bumps / 4.0), 0., 1.), u.crossfade).rgb;

        float ambient = .5;
        float specularPower = 75.0;
        float diffuse = max(0.0, dot(surfNormal, ld));
        float specular = max(0.0, dot(ref, normalize(camPos - sp)));
        specular = pow(specular, specularPower);

        // Bringing all the lighting components together to color the screen pixel.
        sceneColor += (objColor * (diffuse * 0.8 + ambient) + specular * 0.4) * lightColor * lightAtten;
        sceneColor = clamp(sceneColor, 0.0, 1.0);

        return vizOutput(vec4(sceneColor, sqrt(length(sceneColor))));
    }
    """#
}
