// Copyright 2026 mcopt-shade contributors. Apache-2.0.
// Shared by visible terrain, mesh shading and sun-shadow casters. Vertex/mesh buffer 30, outside own's 16..29 slots.
struct ShadeLeaves {
	float4 motion; // strength, periodic time (hour fraction), valid sprite count, reserved
	float4 sprites[16];
};

static bool shadeLeafSprite(float2 uv, constant ShadeLeaves &l) {
	for (uint i = 0; i < min(uint(l.motion.z), 16u); i++) {
		float4 r = l.sprites[i];
		if (r.z > r.x && r.w > r.y && all(uv > r.xy) && all(uv < r.zw)) return true;
	}
	return false;
}

// Continuous across adjacent leaf blocks and section boundaries. Periodic coordinates preserve precision far from spawn.
// Integer harmonics also meet at the hourly game-clock wrap. Maximum displacement on any axis is 0.08 blocks.
static float3 shadeLeafOffset(float3 local, int3 origin, constant ShadeLeaves &l) {
	if (l.motion.x <= 0.0) return float3(0.0);
	float3 p = local + float3(origin & 511);
	float s = 2.0 / 512.0;
	float slow = sinpi(dot(p, float3(11, 5, 7)) * s + l.motion.y * 720.0);
	float flutter = sinpi(dot(p, float3(37, 17, 29)) * s + l.motion.y * 1440.0);
	float crosswind = sinpi(dot(p, float3(7, 13, 19)) * s + l.motion.y * 960.0);
	float a = 0.04 * clamp(l.motion.x, 0.0, 2.0);
	return a * float3(0.75 * slow + 0.25 * flutter, 0.12 * flutter, 0.55 * slow + 0.25 * crosswind);
}
