//! Volumetric dusk cloud band. The cylinder mesh is just a backstop: every
//! fragment rays into a world-space cloud slab, marches a wind-drifted FBM
//! density field, and scatters the scene's directional sun through it with a
//! few self-shadow steps. A minimal pixel layer on top quantises the result
//! (and its alpha) to hard levels with a 4x4 Bayer dither, so the volume reads
//! as pixel art while the lighting stays volumetric.

#import bevy_pbr::{
    forward_io::{Vertex, VertexOutput},
    mesh_functions::{get_world_from_local, mesh_position_local_to_world},
    mesh_view_bindings::{lights, view},
}

// Cloud slab in world metres. The band mesh only spans y 84..234, so the
// vertex stage stretches it upward to cover the top of the frame; the density
// fades to zero before the stretched top edge, so no cloud is ever clipped.
const MESH_BOTTOM: f32 = 84.0;
const MESH_STRETCH: f32 = 3.2;
const SLAB_BOTTOM: f32 = 70.0;
const SLAB_TOP: f32 = 560.0;
// Slow vertical layering: the density rises and falls a couple of times with
// altitude, so the band reads as stacked sheets instead of one solid mass.
const STRATA: f32 = 2.1;
// Base noise frequency: ~55 m billows, three octaves down to ~14 m.
const NOISE_FREQ: f32 = 0.018;
// Wind in metres per second.
const WIND: vec2<f32> = vec2<f32>(3.0, 1.1);
// Primary march: 16 jittered steps, early-out when opaque.
const MARCH_STEPS: i32 = 16;
// Self-shadow march: two widening steps toward the sun.
const LIGHT_STEPS: i32 = 2;
const LIGHT_STEP_GROWTH: f32 = 2.1;
const LIGHT_START: f32 = 12.0;
// Extinction per metre at full density; larger reads heavier and darker.
const EXTINCTION: f32 = 0.085;
// Wind time is derived from the scroll uniform the CPU advances each frame,
// keeping the asset interface unchanged.
const SCROLL_MPS: f32 = 0.012;

// Pixel layer: levels per channel and for alpha, plus the dither cell size in
// screen pixels (1.0 matches the sprite texel scale the rest of the art uses).
const COLOR_LEVELS: f32 = 6.0;
const ALPHA_LEVELS: f32 = 6.0;
const DITHER_CELL: f32 = 1.0;

// xy = UV scroll in texture units (x drives wind time), z = alpha cutoff below
// which a fragment is dropped, w = unused. Texture bindings are part of the
// material contract but the volume does not need them.
@group(3) @binding(0) var<uniform> scroll: vec4<f32>;
@group(3) @binding(1) var _cloud_texture: texture_2d<f32>;
@group(3) @binding(2) var _cloud_sampler: sampler;

// 4x4 Bayer matrix, values 0..15. A private array can be indexed at runtime.
var<private> BAYER: array<f32, 16> = array<f32, 16>(
    0.0, 8.0, 2.0, 10.0,
    12.0, 4.0, 14.0, 6.0,
    3.0, 11.0, 1.0, 9.0,
    15.0, 7.0, 13.0, 5.0,
);

@vertex
fn vertex(vertex: Vertex) -> VertexOutput {
    var out: VertexOutput;
    // Stretch the 150 m backstop to reach the top of the frame. Geometry and
    // material constants on the CPU side stay untouched.
    let stretched = vec3<f32>(
        vertex.position.x,
        MESH_BOTTOM + (vertex.position.y - MESH_BOTTOM) * MESH_STRETCH,
        vertex.position.z,
    );
    let world = mesh_position_local_to_world(
        get_world_from_local(vertex.instance_index),
        vec4<f32>(stretched, 1.0),
    );
    out.world_position = world;
    out.position = view.clip_from_world * world;
    out.uv = vertex.uv;
    return out;
}

// --- Noise -------------------------------------------------------------

fn hash13(p: vec3<f32>) -> f32 {
    var q = fract(p * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

fn value_noise(p: vec3<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = mix(
        mix(hash13(i + vec3(0.0, 0.0, 0.0)), hash13(i + vec3(1.0, 0.0, 0.0)), u.x),
        mix(hash13(i + vec3(0.0, 1.0, 0.0)), hash13(i + vec3(1.0, 1.0, 0.0)), u.x),
        u.y,
    );
    let b = mix(
        mix(hash13(i + vec3(0.0, 0.0, 1.0)), hash13(i + vec3(1.0, 0.0, 1.0)), u.x),
        mix(hash13(i + vec3(0.0, 1.0, 1.0)), hash13(i + vec3(1.0, 1.0, 1.0)), u.x),
        u.y,
    );
    return mix(a, b, u.z);
}

fn fbm(p: vec3<f32>, octaves: i32) -> f32 {
    var value = 0.0;
    var amplitude = 0.5;
    var q = p;
    for (var i = 0; i < octaves; i++) {
        value += amplitude * value_noise(q);
        q = q * 2.07 + vec3<f32>(13.7, 7.3, 17.1);
        amplitude *= 0.5;
    }
    return value;
}

// --- Cloud density -----------------------------------------------------

fn density(p: vec3<f32>, wind: vec2<f32>) -> f32 {
    let h = (p.y - SLAB_BOTTOM) / (SLAB_TOP - SLAB_BOTTOM);
    if h < 0.0 || h > 1.0 {
        return 0.0;
    }
    // Flat base, feathering to nothing at both slab edges.
    let profile = smoothstep(0.0, 0.06, h) * (1.0 - smoothstep(0.80, 1.0, h));
    // Density waxes and wanes slowly with altitude: thin sheets, not a wall.
    let strata = 0.35 + 0.65 * (0.5 + 0.5 * sin(h * 6.2832 * STRATA - 1.1));
    // Slow large-scale coverage so the band opens into wide clear-blue patches.
    // A higher floor than the dusk version keeps a sunny day mostly open sky.
    let q = (p.xz + WIND * wind) * NOISE_FREQ;
    let cover = 0.56 + 0.20 * value_noise(vec3<f32>(q * 0.22, wind.x * 0.02));
    let n = fbm(vec3<f32>(q, p.y * NOISE_FREQ), 3) / 0.875;
    let raw = max(n - cover, 0.0) / (1.0 - cover);
    return min(raw * 1.6, 1.0) * profile * strata;
}

// --- Lighting ----------------------------------------------------------

fn henyey_greenstein(cos_theta: f32, g: f32) -> f32 {
    let g2 = g * g;
    let denom = 1.0 + g2 - 2.0 * g * cos_theta;
    return (1.0 - g2) / (4.0 * 3.14159265 * pow(max(denom, 1e-3), 1.5));
}

fn transmittance_to_sun(p: vec3<f32>, sun: vec3<f32>, wind: vec2<f32>) -> f32 {
    var trans = 1.0;
    var t = LIGHT_START;
    for (var i = 0; i < LIGHT_STEPS; i++) {
        let d = density(p + sun * t, wind);
        trans *= exp(-d * EXTINCTION * t * (LIGHT_STEP_GROWTH - 1.0));
        if trans < 0.03 {
            break;
        }
        t *= LIGHT_STEP_GROWTH;
    }
    return trans;
}

// --- Pixel layer -------------------------------------------------------

fn bayer_at(px: vec2<f32>) -> f32 {
    let cell = vec2<u32>(u32(px.x / DITHER_CELL) % 4u, u32(px.y / DITHER_CELL) % 4u);
    return (BAYER[cell.y * 4u + cell.x] + 0.5) / 16.0;
}

// Quantise in sqrt space: an inexpensive stand-in for perceptual (sRGB)
// quantisation, which keeps the dither pattern even in the dark tones.
fn pixelize(color: vec3<f32>, dither: f32) -> vec3<f32> {
    let s = sqrt(max(color, vec3<f32>(0.0)));
    let q = floor(s * COLOR_LEVELS + dither) / COLOR_LEVELS;
    return q * q;
}

// --- Fragment ----------------------------------------------------------

@fragment
fn fragment(in: VertexOutput) -> @location(0) vec4<f32> {
    let camera = view.world_position;
    let to_fragment = in.world_position.xyz - camera;
    let surface_distance = length(to_fragment);
    let ray = to_fragment / surface_distance;

    // Clip the ray to the cloud slab in front of the backstop.
    var t_start = 0.0;
    var t_end = surface_distance;
    if abs(ray.y) > 1e-4 {
        let ta = (SLAB_BOTTOM - camera.y) / ray.y;
        let tb = (SLAB_TOP - camera.y) / ray.y;
        t_start = max(t_start, min(ta, tb));
        t_end = min(t_end, max(ta, tb));
    }
    if t_end <= t_start {
        discard;
    }

    // Scene sun: the directional light drives both direction and tint.
    var sun = vec3<f32>(0.0, 1.0, 0.0);
    var sun_color = vec3<f32>(1.0, 0.72, 0.48);
    if lights.n_directional_lights > 0u {
        let light = lights.directional_lights[0];
        sun = normalize(light.direction_to_light);
        let lum = max(dot(light.color.rgb, vec3<f32>(0.2126, 0.7152, 0.0722)), 1e-4);
        sun_color = light.color.rgb / lum;
    }
    let ambient = lights.ambient_color.rgb
        / max(dot(lights.ambient_color.rgb, vec3<f32>(0.2126, 0.7152, 0.0722)), 1e-4);

    let time = scroll.x / SCROLL_MPS;
    let wind = vec2<f32>(time % 4096.0);
    let dither = bayer_at(in.position.xy);
    let phase = 0.18 + 0.82 * henyey_greenstein(dot(ray, sun), 0.55);

    // Jittered march: the dither offset doubles as the step jitter, so the
    // quantisation pattern and the sampling pattern agree.
    let step_size = (t_end - t_start) / f32(MARCH_STEPS);
    var t = t_start + step_size * dither;
    var scattered = vec3<f32>(0.0);
    var trans = 1.0;
    for (var i = 0; i < MARCH_STEPS; i++) {
        let p = camera + ray * t;
        let d = density(p, wind);
        if d > 0.002 {
            // A floor on the sun transmittance fakes the multiple scattering
            // that keeps thick dusk clouds from crushing to black.
            let shadow = max(transmittance_to_sun(p, sun, wind), 0.14);
            let h = clamp((p.y - SLAB_BOTTOM) / (SLAB_TOP - SLAB_BOTTOM), 0.0, 1.0);
            // Dusky sky fill: warm near the horizon, violet overhead.
            let sky_fill = ambient * mix(0.15, 0.04, h) + sun_color * 0.05 * (1.0 - h);
            let lit = sun_color * (2.0 * shadow * phase) + sky_fill;
            let absorbed = 1.0 - exp(-d * EXTINCTION * step_size);
            scattered += trans * absorbed * lit;
            trans *= 1.0 - absorbed;
            if trans < 0.02 {
                break;
            }
        }
        t += step_size;
    }

    let opacity = floor((1.0 - trans) * ALPHA_LEVELS + dither) / ALPHA_LEVELS;
    if opacity <= 0.0 {
        discard;
    }
    return vec4<f32>(pixelize(scattered, dither), opacity);
}
