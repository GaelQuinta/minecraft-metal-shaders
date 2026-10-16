// Copyright 2026 mcopt-shade contributors. Apache-2.0.
// The extra light is added in scene-linear space, before bloom and the display transform.
// Reproduce vanilla's linear fog (including its hard boundary for equal start/end),
// attenuating only emission: multiplying the already fogged colour would brighten the fog too.
static inline float shadeBeaconFog(float distance, float start, float end) {
	if (distance <= start) return 0.0;
	if (distance >= end) return 1.0;
	return (distance - start) / (end - start);
}
static inline float3 shadeBeaconEmission(float3 srgb, float distance, float4 ranges, float fogAlpha, constant ShadeLook &L) {
	float extra = max(L.user2.y - 1.0, 0.0);
	if (extra == 0.0) return float3(0.0); // 1x exactly restores the approved HDR look
	float fog = max(shadeBeaconFog(distance, ranges.x, ranges.y), shadeBeaconFog(distance, ranges.z, ranges.w));
	float visibility = 1.0 - saturate(fog * fogAlpha);
	return shadeLdrToHdr(srgb, L) * (extra * visibility);
}
