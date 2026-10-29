// Copyright 2026 mcopt-shade contributors. Apache-2.0.
#ifndef MCOPT_SHADE_LAVA
#define MCOPT_SHADE_LAVA
static inline bool shadeLavaRect(float2 uv, float4 r) {
	return all(r.zw > r.xy) && all(uv >= r.xy) && all(uv < r.zw);
}
static inline bool shadeLavaSprite(float2 uv, constant ShadeLook &l) {
	return shadeLavaRect(uv, l.lavaStill) || shadeLavaRect(uv, l.lavaFlow);
}
// The animated resource-pack texture supplies the moving molten/crust pattern on tops and falls.
// Self-emission is independent of sunlight, biome tint and face shading; the normal post pass adds bloom/halation.
static inline float3 shadeLavaSurface(float3 texel, float3 world, float time, float strength) {
	float3 base = float3(shadeToLinear(half3(saturate(texel))));
	float heat = smoothstep(0.08, 0.60, shadeLuma(base));
	float pulse = 1.0 + 0.04 * sin(world.x * 0.7 + world.z * 0.53 + world.y * 0.31 + time * 0.55);
	return base * (1.4 + 3.6 * heat) * pulse * strength;
}
#endif
