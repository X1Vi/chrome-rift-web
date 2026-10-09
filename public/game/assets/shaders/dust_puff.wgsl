//! Dust and exhaust puffs: one dynamic mesh of camera-facing quads.
//!
//! Particle centres live in the vertex positions and each quad is expanded in
//! view space here, so every puff faces the camera without per-particle
//! entities or transforms. The per-particle tint and fade ride in the color
//! attribute and the current puff size in `uv_b.x`, both rewritten by the CPU
//! pool each frame. One draw call covers the whole pool.

#import bevy_pbr::{
    forward_io::{Vertex, VertexOutput},
    mesh_view_bindings::view,
}

@group(3) @binding(0) var puff_texture: texture_2d<f32>;
@group(3) @binding(1) var puff_sampler: sampler;

@vertex
fn vertex(vertex: Vertex) -> VertexOutput {
    var out: VertexOutput;
    let view_centre = view.view_from_world * vec4<f32>(vertex.position, 1.0);
    let corner = vertex.uv - vec2<f32>(0.5);
    let size = vertex.uv_b.x;
    out.position = view.clip_from_view * (view_centre + vec4<f32>(corner * size, 0.0, 0.0));
    out.world_position = vec4<f32>(vertex.position, 1.0);
    out.world_normal = vec3<f32>(0.0, 1.0, 0.0);
    out.uv = vertex.uv;
    out.uv_b = vertex.uv_b;
    out.color = vertex.color;
    return out;
}

@fragment
fn fragment(in: VertexOutput) -> @location(0) vec4<f32> {
    let texel = textureSample(puff_texture, puff_sampler, in.uv);
    let alpha = texel.a * in.color.a;
    if alpha < 0.01 {
        discard;
    }
    return vec4<f32>(texel.rgb * in.color.rgb, alpha);
}
