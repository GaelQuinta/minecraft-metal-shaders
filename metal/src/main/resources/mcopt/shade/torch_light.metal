// Copyright 2026 mcopt-shade contributors. Apache-2.0.
#ifndef MCOPT_SHADE_TORCH_LIGHT
#define MCOPT_SHADE_TORCH_LIGHT
#include <metal_stdlib>
using namespace metal;

// Warm direct light close to a flame; weaker surrounding fill becomes neutral without gaining energy.
// The block-light level also supplies a distance estimate for placed torches (whose position is not in the lightmap).
static inline float shadeTorchWarmth(float level) { return smoothstep(0.45, 0.9, level); }
static inline float shadeTorchLuma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
static inline float3 shadeTorchSpectrum(float3 c, float level) {
	return mix(float3(shadeTorchLuma(c)), c, shadeTorchWarmth(level));
}
// Only ordinary flame-coloured lights use the neutral outer fill. Soul fire and other coloured lights retain their hue.
static inline bool shadeTorchTint(float3 tint) {
	float hi = max(max(tint.r, tint.g), tint.b), lo = min(min(tint.r, tint.g), tint.b);
	return hi - lo <= max(hi, 1e-5) * 0.01;
}
#endif
