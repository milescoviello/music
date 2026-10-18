#include "VisualizerShaders.h"

// One triangle that covers the whole target, which is all a fragment-shader visualiser
// needs. Plexamp draws a two-triangle quad; the pixels are the same and this has no
// seam down the diagonal.
vertex VisualizerVertexOut viz_vertex(uint vid [[vertex_id]]) {
    float2 position = float2(float((vid << 1) & 2), float(vid & 2)) * 2.0 - 1.0;
    VisualizerVertexOut out;
    out.position = float4(position, 0.0, 1.0);
    return out;
}
