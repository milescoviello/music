#include "VisualizerShaders.h"

// Galaxy: seventy-two out-of-focus discs flung outward from the centre by their bands,
// and twelve beams of light from the middle, seen by a camera circling the whole.

// Precise sine, as in Plexamp's `highp` hash: a fast sine's error times 43758 would
// scatter the discs somewhere else.
static float galaxyHash(float n) {
    float a = 12.9898;
    float b = 78.233;
    float c = 43758.5453;
    float dt = dot(float2(n, n), float2(a, b));
    float sn = mod(dt, 3.14);
    return fract(precise::sin(sn) * c);
}

static float3 galaxyClosestPointFromLineToLine(float3 l1Start, float3 l1End, float3 l2Start, float3 l2End,
                                               thread float &dist) {
    float3 u = l1End - l1Start;
    float3 v = l2End - l1Start;
    float3 w = l1Start - l2Start;
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

    float3 closestPoint = (tc * v);
    float3 dP = w + (sc * u) - closestPoint;
    dist = length(dP);

    // Make sure we're not following the line the wrong direction.
    if (dot(closestPoint - l2Start, l2End - l2Start) < 0.) {
        dist = 1000.;
    }

    return closestPoint;
}

static float galaxyBokehRing(float3 ro, float3 rd, float3 p, float size, float blur) {
    float dist = length(cross(p - ro, rd));
    float m = smoothstep(size, size * (1. - blur), dist);
    m *= mix(.25, 1., smoothstep(.95 * size, size, dist));
    return m;
}

static float3 galaxyDisc(float3 cameraPos, float3 rd, float3 p, texture2d<float> palette, float crossfade) {
    float distanceFromOrigin = length(p);

    // Focus is on a plane from origin.
    float distanceFromFocalPlane = abs(15. - length(p - cameraPos));
    float blur = (distanceFromFocalPlane < 4.) ? 0.05 : min(distanceFromFocalPlane / 2., .5);
    float m = galaxyBokehRing(cameraPos, rd, p, .55, blur);

    // Fade out as we get closer to origin.
    float brightness = min(distanceFromOrigin / 1.7, 3.);

    return m * brightness * getTweenedTexture(palette, length(p - float3(0, 0, 0)) / 7.0, crossfade).rgb;
}

static float3 galaxyLine(float3 cameraPos, float3 rayDirection, float3 lineOrigin, float3 lineDirection, float3 color) {
    float dist;
    float3 closestPoint = galaxyClosestPointFromLineToLine(cameraPos, cameraPos + rayDirection * 100.,
                                                           lineOrigin, lineOrigin + lineDirection * 100., dist);
    float distFromOrigin = length(closestPoint - float3(0));
    float distFromCamera = length(cameraPos - closestPoint);

    return color * (1. - smoothstep(0., 0.03 + distFromOrigin / 7., dist)) / (1.5 * distFromCamera / 2.0);
}

static float3 galaxyCreateRay(float2 uvOrig, float3 cameraPos, float3 lookAt, float2 resolution) {
    float2 uv = uvOrig;
    uv -= .5;
    uv.x *= resolution.x / resolution.y;

    float3 rayOrigin = cameraPos;
    float3 forward = normalize(lookAt - rayOrigin);
    float3 right = cross(float3(0, 1, 0), forward);
    float3 up = cross(forward, right);
    float3 center = rayOrigin + forward;
    float3 intersect = center + (uv.x * right) + (uv.y * up);

    return normalize(intersect - rayOrigin);
}

#define BALL_SETS 3.
#define NUM_RAYS 12.

VIZ_FRAGMENT(viz_galaxy) {
    float2 fragCoord = vizFragCoord(in, u);

    // Create normalized coord system centered on 0,0.
    float2 uv = fragCoord / u.resolution;

    float3 cameraPos = float3(sin(u.time) * 10., 0., -10. * cos(u.time));
    float3 lookAt = float3(0, 0, 0);
    float3 ray = galaxyCreateRay(uv, cameraPos, lookAt, u.resolution);
    float3 col = float3(0.);

    // Render the discs.
    for (float j = 0.; j < 24. * BALL_SETS; j += 1.) {
        float i = mod(j, 24.);
        float zeroToOne = i / 23.;
        float vol = getFrequencyValue(frequencies, zeroToOne, FREQ_AMPLITUDE);
        float3 ballRay = normalize(float3(galaxyHash(j) - 0.5, galaxyHash(j * 3.) - 0.5, galaxyHash(j * 5.) - 0.5));

        col += galaxyDisc(cameraPos, ray, ballRay * vol * 15., palette, u.crossfade);
    }

    // Render the rays.
    for (float j = 0.; j < NUM_RAYS; j += 1.) {
        float vol = getFrequencyValue(frequencies, j / (NUM_RAYS - 1.), FREQ_AMPLITUDE);
        float3 color = getTweenedTexture(palette, vol + 0.1, u.crossfade).rgb;
        vol /= 4.;

        // Pick a semi-random direction.
        float random = galaxyHash(j);
        float3 lightDir = normalize(float3(sin(j + random + vol) + .1, cos(j + vol) + cos(u.time / 100.) / 3. - .1, random));

        // Turn down brightness if it's pointing towards us, avoids flashes.
        float dotRay = dot(lightDir, ray);
        float brightness = 1. - smoothstep(-0.1, -0.9, dotRay);

        // Offset the origin just a tiny bit in the right direction so they don't overlap on origin.
        float3 lightOrigin = float3(0.) + 0.01 * lightDir;
        col += brightness * galaxyLine(cameraPos, ray, lightOrigin, lightDir, color) * 1.5;
    }

    return vizOutput(float4(col, length(col)));
}
