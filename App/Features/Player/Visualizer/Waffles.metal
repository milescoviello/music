#include "VisualizerShaders.h"

// Waffles: a raymarched ball whose skin is a grid of moving bumps, waffle-like, raised
// round its circumference by the spectrum, lit by a point light with a sharp specular
// and coloured by how high each bump stands.

constant float eps = 0.005;
constant int maxIterations = 128;
constant float stepScale = 0.5;
constant float stopThreshold = 0.005;

static float wafflesSphere(float3 p, float3 centerPos, float radius) {
    return length(p - centerPos) - radius;
}

static float wafflesBumps(float3 p, float time, texture2d<float> frequencies) {
    float samplePoint = mod((atan2(p.x + 0.5, p.z) + PI) / PI / 2., 1.0);
    float vol = getFrequencyValueBilinear(frequencies, samplePoint, FREQ_AMPLITUDE) + 0.03;
    return -(vol * 8. * (0.5 + sin(p.x * 16. + time * 0.57) * cos(p.y * 16. + time * 2.17) * sin(p.z * 16. - time * 1.31)
                         + 0.5 * sin(p.x * 32. + time * 0.07) * cos(p.y * 32. + time * 2.11) * sin(p.z * 32. - time * 1.23)));
}

static float wafflesScene(float3 p, float time, texture2d<float> frequencies) {
    return wafflesSphere(p, float3(0., 0., 3.), 2.4) + 0.04 * wafflesBumps(p, time, frequencies);
}

static float3 wafflesNormal(float3 p, float time, texture2d<float> frequencies) {
    // 6-tap normalization. Probably the most accurate, but a bit of a cycle waster.
    return normalize(float3(
        wafflesScene(float3(p.x + eps, p.y, p.z), time, frequencies) - wafflesScene(float3(p.x - eps, p.y, p.z), time, frequencies),
        wafflesScene(float3(p.x, p.y + eps, p.z), time, frequencies) - wafflesScene(float3(p.x, p.y - eps, p.z), time, frequencies),
        wafflesScene(float3(p.x, p.y, p.z + eps), time, frequencies) - wafflesScene(float3(p.x, p.y, p.z - eps), time, frequencies)
    ));
}

static float wafflesMarch(float3 origin, float3 dir, float start, float end, float time, texture2d<float> frequencies) {
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

VIZ_FRAGMENT(viz_waffles) {
    float2 fragCoord = vizFragCoord(in, u);
    float2 aspect = float2(u.resolution.x / u.resolution.y, 1.0);
    float2 screenCoords = (2.0 * fragCoord / u.resolution - 1.0) * aspect;

    float3 lookAt = float3(0., 0., 0.);
    float3 camPos = float3(0., 0., -0.8);

    // Camera setup.
    float3 forward = normalize(lookAt - camPos);
    float3 right = normalize(float3(forward.z, 0., -forward.x));
    float3 up = normalize(cross(forward, right));
    float FOV = 0.5;

    float3 ro = camPos;
    float3 rd = normalize(forward + FOV * screenCoords.x * right + FOV * screenCoords.y * up);

    // Ray marching.
    const float clipNear = 0.0;
    const float clipFar = 10.0;
    float dist = wafflesMarch(ro, rd, clipNear, clipFar, u.time, frequencies);
    if (dist >= clipFar) {
        return vizOutput(float4(0.));
    }

    // Surface position, and its normal.
    float3 sp = ro + rd * dist;
    float3 surfNormal = wafflesNormal(sp, u.time, frequencies);

    // Light position and direction.
    float3 lp = float3(0.5, 0.5, -1.);
    float3 ld = lp - sp;
    float3 lightColor = float3(1., 0.97, 0.92);

    float len = length(ld);
    ld /= len;
    float lightAtten = min(1.0 / (0.25 * len * len), 1.0);
    float3 ref = reflect(-ld, surfNormal);

    float3 sceneColor = float3(1) * surfNormal.y * 0.1;

    float bumps = wafflesBumps(sp, u.time, frequencies);
    float3 objColor = getTweenedTexture(palette, clamp(abs(bumps / 4.0), 0., 1.), u.crossfade).rgb;

    float ambient = .5;
    float specularPower = 75.0;
    float diffuse = max(0.0, dot(surfNormal, ld));
    float specular = max(0.0, dot(ref, normalize(camPos - sp)));
    specular = pow(specular, specularPower);

    // Bringing all the lighting components together to color the screen pixel.
    sceneColor += (objColor * (diffuse * 0.8 + ambient) + specular * 0.4) * lightColor * lightAtten;
    sceneColor = clamp(sceneColor, 0.0, 1.0);

    return vizOutput(float4(sceneColor, sqrt(length(sceneColor))));
}
