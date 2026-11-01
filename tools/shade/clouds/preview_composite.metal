// Copyright 2026 mcopt-shade contributors. Licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0). Dev tool for mcopt native shading's clouds, not part of the mod.
// The offline preview's composite: sky (LUT + sun disc) + the cloud history (or the dome), a flat ground 16 blocks down
// with the cloud shadows, exposure + Shade Filmic, sRGB. Output rows top-down (PNG).
struct PVOut { float4 pos [[position]]; };
vertex PVOut cloudpreview_vs(uint vid [[vertex_id]]) {
	PVOut o; o.pos = float4(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0, 0.0, 1.0); return o;
}
fragment float4 cloudpreview_fs(PVOut in [[stage_in]], constant ShadeFrame &f [[buffer(16)]], constant ShadeLook &L [[buffer(17)]],
                                texture2d<half> lut [[texture(17)]], sampler ls [[sampler(13)]], texture2d<half> hist [[texture(0)]],
                                texture2d<half> dome [[texture(1)]], texture2d<half> shadow [[texture(2)]], constant int4 &mode [[buffer(0)]]) {
	float2 ndc = float2(in.pos.x * f.screen.z * 2.0 - 1.0, 1.0 - in.pos.y * f.screen.w * 2.0);
	float4 w = f.invViewProj * float4(ndc, 0.5, 1.0);
	float3 dir = normalize(w.xyz / w.w);
	float ex = f.time.z;
	float3 c;
	if (dir.y < -0.01) {
		// ground plane 16 blocks below the camera, lit by the sun through the cloud shadows, fogged into the sky
		float t = 16.0 / -dir.y;
		float3 p = dir * t;
		float cs = shadeCloudShadow(p, L, shadow);
		float3 albedo = float3(0.16, 0.30, 0.09);
		float nl = saturate(f.lightDirWorld.y);
		c = albedo * (f.sunColor.rgb * nl * cs + f.ambientSky.rgb);
		float fog = 1.0 - exp(-t / 1800.0);
		c = mix(c, shadeSkyLookup(float3(dir.x, 0.0, dir.z), lut, ls, f), fog);
		if (mode.x == 2) c = float3(cs);
	} else {
		// Daytime only: this preview has no Milky Way texture bound.
		c = f.lightDirWorld.w > 0.5
		    ? shadeSkyRadiance2(dir, lut, ls, f, L, lut, 1.4 * f.screen.w)
		    : shadeSkyLookup(dir, lut, ls, f);
		float4 cl = mode.x == 1 ? shadeCloudsDome(dir, L, dome) : shadeCloudsScreen(dir, L, hist);
		c = c * cl.a + cl.rgb;
		if (mode.x == 3) c = float3(1.0 - cl.a) / ex;
	}
	float3 y = shadeDisplay(c * ex, L);
	return float4(shadeLinearToSrgbExact(saturate(y)), 1.0);
}
