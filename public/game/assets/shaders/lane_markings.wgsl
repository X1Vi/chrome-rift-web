//! Animated lane paint. A single ribbon mesh carries `uv = (progress_m,
//! lateral_m)`; this shader cuts dashed dividers from the progress with
//! `fract`, keeps the edge lines solid, and scrolls the dash phase from a
//! uniform so the lanes stream with the bike. Distance is faded toward the
//! scene's exponential fog so the paint never outshines the road under it.

#import bevy_pbr::{
    forward_io::{Vertex, VertexOutput},
    mesh_functions::{get_world_from_local, mesh_position_local_to_world},
    mesh_view_bindings::view,
}

// Anything further from the centreline than this is an edge line, not a
// divider, in metres.
const EDGE_SPLIT_M: f32 = 5.0;
// Screen-space width of the dash fade, in dash-cycle units.
const DASH_AA: f32 = 1.5;

// x = scroll phase (m), y = dash period (m), z = dash duty, w = unused.
@group(3) @binding(0) var<uniform> params: vec4<f32>;
// rgb = paint colour, a = opacity.
@group(3) @binding(1) var<uniform> paint: vec4<f32>;
// rgb = fog colour, w = exponential fog density.
@group(3) @binding(2) var<uniform> haze: vec4<f32>;

@vertex
fn vertex(vertex: Vertex) -> VertexOutput {
    var out: VertexOutput;
    let world = mesh_position_local_to_world(
        get_world_from_local(vertex.instance_index),
        vec4<f32>(vertex.position, 1.0),
    );
    out.world_position = world;
    out.position = view.clip_from_world * world;
    out.uv = vertex.uv;
    return out;
}

@fragment
fn fragment(in: VertexOutput) -> @location(0) vec4<f32> {
    let progress = in.uv.x;
    let lateral = abs(in.uv.y);
    let is_edge = select(0.0, 1.0, lateral > EDGE_SPLIT_M);

    // Dash cycle coordinate, scrolled by the CPU phase. `fract` wraps the
    // cycle, and the derivative gives the dash ends a clean anti-aliased edge.
    let cycle = (progress + params.x) / params.y;
    let dash = fract(cycle);
    let aa = max(fwidth(cycle) * DASH_AA, 1e-4);
    let on = smoothstep(0.0, aa, dash) - smoothstep(params.z - aa, params.z, dash);
    let coverage = mix(on, 1.0, is_edge);

    // Match the camera's exponential distance fog: the paint dissolves into
    // the same haze the asphalt does.
    let distance = length(view.world_position - in.world_position.xyz);
    let fog = 1.0 - exp(-distance * haze.w);
    let color = mix(paint.rgb, haze.rgb, fog);
    let alpha = paint.a * coverage;
    if alpha < 0.01 {
        discard;
    }
    return vec4<f32>(color, alpha);
}
