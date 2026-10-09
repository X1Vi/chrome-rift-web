//! Lightweight retro grade.
//!
//! Samples the frame at native resolution and ordered-dithers and quantizes it
//! in perceptual space. The virtual grid only lays out the dither cells; it
//! never resamples the image, because the fullscreen sampler is nearest and
//! point-sampling a moving frame aliases into a shimmer. One texture fetch and
//! a handful of ALU ops; no extra render targets, no per-frame allocations.

#import bevy_core_pipeline::fullscreen_vertex_shader::FullscreenVertexOutput

@group(0) @binding(0) var screen_texture: texture_2d<f32>;
@group(0) @binding(1) var texture_sampler: sampler;
@group(0) @binding(2) var<uniform> settings: RetroSettings;

struct RetroSettings {
    levels: f32,
    amount: f32,
    virtual_size: vec2<f32>,
    speed: f32,
    padding: vec3<f32>,
};

// 4x4 ordered (Bayer) threshold matrix, normalised to 0..1.
fn bayer4(position: vec2<i32>) -> f32 {
    var matrix = array<f32, 16>(
        0.0, 8.0, 2.0, 10.0,
        12.0, 4.0, 14.0, 6.0,
        3.0, 11.0, 1.0, 9.0,
        15.0, 7.0, 13.0, 5.0,
    );
    return matrix[(position.y & 3) * 4 + (position.x & 3)] / 16.0;
}

// How much of the Bayer threshold is applied. 1.0 is a full dither; below
// that the steps keep a little banding instead of a fabric-like weave.
const DITHER_STRENGTH: f32 = 0.6;

@fragment
fn fragment(in: FullscreenVertexOutput) -> @location(0) vec4<f32> {
    // The virtual grid only sizes the dither cells (2x2 at 720p, 3x3 at
    // 1080p); the image itself is sampled at native resolution.
    let dims = vec2<f32>(textureDimensions(screen_texture));
    let target_size = max(settings.virtual_size, vec2<f32>(2.0, 2.0));
    let scale = max(1.0, floor(dims.y / target_size.y));
    let virtual_size = floor(dims / scale);
    let pixel = floor(in.uv * virtual_size);

    let color = textureSample(screen_texture, texture_sampler, in.uv).rgb;

    // Quantize in a perceptual (gamma-ish) space so the bands are even to the
    // eye, and offset each step by the Bayer threshold to dither the edges.
    let levels = max(settings.levels, 2.0);
    let perceptual = pow(max(color, vec3<f32>(0.0)), vec3<f32>(1.0 / 2.2));
    let threshold = bayer4(vec2<i32>(pixel)) * DITHER_STRENGTH;
    let quantized = clamp(
        floor(perceptual * (levels - 1.0) + threshold) / (levels - 1.0),
        vec3<f32>(0.0),
        vec3<f32>(1.0),
    );

    // Vignette every frame, then pull radial speed lines in at pace. The
    // lines live in the same pass so the effect costs a few ALU ops.
    let centered = in.uv - vec2<f32>(0.5);
    let radius = length(centered) * 1.41421356;
    let angle = atan2(centered.y, centered.x);
    let vignette = 1.0 - smoothstep(0.45, 1.1, radius) * 0.22;
    let speed = clamp(settings.speed, 0.0, 1.5);
    let streaks = smoothstep(0.5, 0.95, radius);
    let line = pow(abs(sin(angle * 48.0)), 24.0);
    let graded = mix(perceptual, quantized, clamp(settings.amount, 0.0, 1.0)) * vignette
        + vec3<f32>(speed * streaks * line * 0.16);

    return vec4<f32>(pow(max(graded, vec3<f32>(0.0)), vec3<f32>(2.2)), 1.0);
}
