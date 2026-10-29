// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// The sky-view LUT pass (mcshade.m, mc_shade_lut_render): once per frame, before the sky draws, the atmosphere's radiance for
// every texel's direction (shade_common.metal: shadeLutDirection, shadeSkyRadiance) into a SHADE_LUT_W x SHADE_LUT_H
// RGBA16Float target (with the art layer's golden-hour gain, ShadeLook at buffer(17)). 10k pixels of the 8-sample scattering integral instead of 6 million: ~0.01 ms instead of ~3 ms at
// 3024x1964. Loaded after shade_common.metal.

struct ShadeLutOut { float4 position [[position]]; };

vertex ShadeLutOut shade_lut_vs(uint vid [[vertex_id]]) {
	ShadeLutOut out;
	out.position = float4(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0, 0.0, 1.0);
	return out;
}

fragment half4 shade_lut_fs(ShadeLutOut in [[stage_in]], constant ShadeFrame &f [[buffer(16)]], constant ShadeLook &L [[buffer(17)]]) {
	float2 uv = (in.position.xy - 0.5) / float2(SHADE_LUT_W - 1, SHADE_LUT_H - 1);
	float3 transmittance;
	float3 dir = shadeLutDirection(uv, f);
	bool art = L.skyGoldH.w > 0.5; // M3 sunset art (mcopt.shade.sunsetArt)
	float3 sky = shadeSkyRadiance(art ? shadeSunsetStretch(dir, f.sunDirWorld.xyz, f.sunDirWorld.w, f.weather.x) : dir, f, transmittance, art, false);
	// M2 art layer: the golden hour's warm horizon and rose upper sky (ShadeLook.skyGold*), strongest toward the sun; baked
	// into the LUT so the sky, its reflections and the fog into the sky behind terrain all agree
	float2 hz = dir.xz, sz = f.sunDirWorld.xz;
	float toward = dot(hz, hz) > 1e-8 && dot(sz, sz) > 1e-8 ? dot(normalize(hz), normalize(sz)) * 0.5 + 0.5 : 0.5;
	float3 gain = mix(L.skyGoldH.rgb, L.skyGoldZ.rgb, smoothstep(0.02, 0.55, abs(dir.y)));
	gain = mix(float3(1.0), max(gain, 0.0), art ? 0.15 + 0.85 * toward * toward : 0.55 + 0.45 * toward); // art: little gold away from the sun
	sky *= gain;
	// M3: the evening sky's hue toward rose (upper sky, a little mauve) and peach (lower), at the same luminance: the warm
	// pink-gold evening of the studied packs, our sun, rays and blue top kept (ShadeLook.skyGoldZ.w, 0 by day)
	float rose = L.skyGoldZ.w;
	if (rose > 0.0 && dir.y > 0.0) {
		float up = smoothstep(0.08, 0.6, dir.y);
		float3 tint = mix(float3(1.6, 1.0, 0.6), float3(1.6, 0.88, 0.86), up); // gold-peach low, warm rose high (was mauve: read lilac-grey)
		tint /= dot(tint, float3(0.2126, 0.7152, 0.0722));
		float l = dot(sky, float3(0.2126, 0.7152, 0.0722));
		// Ease from the gold horizon across a broad band instead of a narrow pink stripe.
		float w = rose * (0.55 + 0.45 * toward) * (1.0 - 0.3 * smoothstep(0.55, 1.0, dir.y)) * smoothstep(0.0, 0.35, dir.y);
		sky = mix(sky, l * tint, w);
	}
	// Apply also to the art tint added above, so reducing the atmospheric chroma can't be undone by the rose overlay.
	return half4(half3(min(shadeAwaySunset(sky, dir, f), 60000.0)), 1.0h);
}
