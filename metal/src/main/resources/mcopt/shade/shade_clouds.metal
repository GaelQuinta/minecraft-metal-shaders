// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// M3 volumetric clouds (E05): what the rest of shading reads of them, part of ShadeMsl.prelude() (after shade_common.metal,
// before shade_m2.metal: its air fog blends distant terrain into the sky with the clouds).
// The clouds module (clouds.metal, native/mcclouds.m, mcopt.metal.shade.clouds) renders, before the sky pass each frame:
//   ShadeResources.cloudShadow (12)  R16F transmittance of the cumulus toward the light, ShadeLook.cloudShadowVP maps a
//                                    camera-relative point onto it (an oblique projection along the light onto the layer)
//   ShadeResources.cloudDome (13)    RGBA16F scattered light (before exposure) + transmittance by direction (upper hemisphere)
//   ShadeResources.cloudScreen (14)  the same for this frame's view (by direction through ShadeLook.viewProjNoJitter)
// Everything is gated on ShadeLook.clouds0.w (clouds drawn this frame) / clouds0.z (shadow strength): with the module off
// or in the Nether/End these return "no cloud" without touching the textures.
#ifndef MCOPT_SHADE_CLOUDS
#define MCOPT_SHADE_CLOUDS

constexpr sampler shadeCloudSampler(filter::linear, address::clamp_to_edge);

// M3.1 dev bits (ShadeLook.clouds1.z = mcopt.shade.clouds.dev, read every frame; 0 normally, CloudConfig.DEV_*): the bench's
// price phases switch a consumer off, or an M3.1 saving back to M3's way, inside one session.
#define SHADE_CLOUD_DEV_NO_SKY 4      // the sky pass skips the composite
#define SHADE_CLOUD_DEV_NO_FOG 8      // shadeFogAir2 skips the clouds behind distant terrain
#define SHADE_CLOUD_DEV_NO_VL 32      // VL ignores the clouds (shadow per step, sky mask)
#define SHADE_CLOUD_DEV_OLD_FOG 256   // M3: the fog looks the clouds up for every terrain pixel
#define SHADE_CLOUD_DEV_OLD_VL 512    // M3: VL fetches the cloud shadow on every lit step
#define SHADE_CLOUD_DEV_EARLY_FOG 2097152 // FT2.9: the clouds behind distant terrain from the border fog's start (mcopt.shade.clouds.lateFog=false)
#define SHADE_CLOUD_DEV_NO_AP 4194304       // (FT2.12, diagnosis) shadeFogAir2 without the aerial blend toward the sky behind
#define SHADE_CLOUD_DEV_AP_SUN 8388608      // FT2.11: shadeFogAir2's aerial blend toward the sky behind with its glow around the sun (mcopt.shade.aerialSun=true)
static inline bool shadeCloudDev(constant ShadeLook &L, int bit) { return (int(L.clouds1.z) & bit) != 0; }

// Light reaching camera-relative p through the cumulus (1 = open sky .. ~0.1 under a thick cloud), for the sun/moon term.
static inline float shadeCloudShadow(float3 p, constant ShadeLook &L, texture2d<half> map) {
	if (L.clouds0.z <= 0.0) return 1.0;
	float2 uv = (L.cloudShadowVP * float4(p, 1.0)).xy;
	float2 e = abs(uv - 0.5);
	float edge = saturate((0.5 - max(e.x, e.y)) * 12.0);
	// fades out for receivers up in (or above) the cloud layer
	float above = 1.0 - smoothstep(L.clouds0.x - 16.0, L.clouds0.x + 40.0, p.y);
	float w = L.clouds0.z * edge * above;
	if (w <= 0.0) return 1.0; // (FT2.8, audit idx 31: past the map, e.g. DH's LODs, no fetch for a weight of 0)
	float t = float(map.sample(shadeCloudSampler, uv, level(0.0)).r);
	return mix(1.0, t, w);
}

// The same for points dir * t along a ray from the camera (a march): the map coordinate is affine in t (cloudShadowVP has
// w = 1), so the march sets the ray up once and pays one fetch per step, without the matrix.
struct ShadeCloudRay {
	float2 uv0, duv;
	float dy;
};

static inline ShadeCloudRay shadeCloudRay(float3 dir, constant ShadeLook &L) {
	ShadeCloudRay r;
	r.uv0 = (L.cloudShadowVP * float4(0.0, 0.0, 0.0, 1.0)).xy;
	r.duv = (L.cloudShadowVP * float4(dir, 0.0)).xy;
	r.dy = dir.y;
	return r;
}

static inline float shadeCloudShadowRay(ShadeCloudRay r, float t, constant ShadeLook &L, texture2d<half> map) {
	if (L.clouds0.z <= 0.0) return 1.0;
	float2 uv = r.uv0 + r.duv * t;
	float2 e = abs(uv - 0.5);
	float edge = saturate((0.5 - max(e.x, e.y)) * 12.0);
	float above = 1.0 - smoothstep(L.clouds0.x - 16.0, L.clouds0.x + 40.0, r.dy * t);
	float s = float(map.sample(shadeCloudSampler, uv, level(0.0)).r);
	return mix(1.0, s, L.clouds0.z * edge * above);
}

// The clouds toward unit dir in this frame's view: rgb scattered light (before exposure), a transmittance; (0, 1) when off
// or off screen. Composite: c = c * a + rgb (before exposure).
static inline float4 shadeCloudsScreen(float3 dir, constant ShadeLook &L, texture2d<half> tex) {
	if (L.clouds0.w < 0.5) return float4(0.0, 0.0, 0.0, 1.0);
	float4 c = L.viewProjNoJitter * float4(dir, 0.0);
	if (c.w <= 1e-6) return float4(0.0, 0.0, 0.0, 1.0);
	float2 uv = c.xy / c.w * 0.5 + 0.5;
	if (L.clouds1.w < 0.5) return float4(tex.sample(shadeCloudSampler, uv, level(0.0)));
	// M3.4 (mcopt.shade.clouds.smooth): a cubic B-spline from 4 bilinear taps (Sigg & Hadwiger's weights): the magnified history
	// shows no texel blocks on soft edges, and its per-pixel noise is smoothed
	float2 sz = float2(tex.get_width(), tex.get_height());
	float2 t = uv * sz - 0.5, i = floor(t), f = t - i, f2 = f * f, f3 = f2 * f;
	float2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0, w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0, w2 = (1.0 + 3.0 * f + 3.0 * f2 - 3.0 * f3) / 6.0, w3 = f3 / 6.0;
	float2 g0 = w0 + w1, g1 = w2 + w3;
	float2 h0 = (i - 0.5 + w1 / g0) / sz, h1 = (i + 1.5 + w3 / g1) / sz;
	float4 a = float4(tex.sample(shadeCloudSampler, float2(h0.x, h0.y), level(0.0))), b = float4(tex.sample(shadeCloudSampler, float2(h1.x, h0.y), level(0.0)));
	float4 cc = float4(tex.sample(shadeCloudSampler, float2(h0.x, h1.y), level(0.0))), d = float4(tex.sample(shadeCloudSampler, float2(h1.x, h1.y), level(0.0)));
	return g0.y * (g0.x * a + g1.x * b) + g1.y * (g0.x * cc + g1.x * d);
}

// The clouds toward unit dir from the reflection dome (any direction; nothing below the horizon).
static inline float4 shadeCloudsDome(float3 dir, constant ShadeLook &L, texture2d<half> dome) {
	if (L.clouds0.w < 0.5 || L.clouds1.x < 0.5 || dir.y <= 0.0) return float4(0.0, 0.0, 0.0, 1.0);
	float az = atan2(dir.z, dir.x) * 0.15915494;
	float2 uv = float2(az < 0.0 ? az + 1.0 : az, sqrt(saturate(dir.y)));
	constexpr sampler wrapU(filter::linear, s_address::repeat, t_address::clamp_to_edge);
	float4 c = float4(dome.sample(wrapU, uv, level(0.0)));
	// toward the horizon the dome's texels stretch: fade to "no cloud" over the last degree
	float k = smoothstep(0.0, 0.02, dir.y);
	return float4(c.rgb * k, mix(1.0, c.a, k));
}


// Foreground clouds on DH surfaces: compare distances from any camera height.
// A high peak may be behind a cloud even when the viewer is below the cloud base.
// Near terrain is handled by cloud_over; empty sky already contains its cloud composite.
static inline float4 shadeCloudsForeground(float3 p, constant ShadeLook &L, constant ShadeResources &R) {
	float k = 1.0;
	if (L.clouds0.w < 0.5) return float4(0.0, 0.0, 0.0, 1.0);
	float4 cp = L.viewProjNoJitter * float4(p, 0.0);
	if (cp.w <= 1e-6) return float4(0.0, 0.0, 0.0, 1.0);
	float2 uv = cp.xy / cp.w * 0.5 + 0.5;
	if (any(uv < 0.0) || any(uv > 1.0)) return float4(0.0, 0.0, 0.0, 1.0);
	float cd;
	if (L.clouds0.w > 1.5) {
		constexpr sampler point(filter::nearest, address::clamp_to_edge);
		uint4 q = uint4(R.cloudHistoryData.gather(point, uv)) & 0xfffu;
		float2 t = fract(uv * float2(R.cloudHistoryData.get_width(), R.cloudHistoryData.get_height()) - 0.5);
		float4 w = float4((1.0-t.x)*t.y, t.x*t.y, t.x*(1.0-t.y), (1.0-t.x)*(1.0-t.y));
		w = select(float4(0.0), w, q != 4095u);
		float sum = dot(w, float4(1.0));
		if (sum <= 1e-4) return float4(0.0, 0.0, 0.0, 1.0);
		cd = dot(w, exp2(float4(q) * (1.0/256.0))) / sum;
	} else {
		float2 size = float2(R.cloudDistance.get_width(), R.cloudDistance.get_height());
		float2 pos = clamp(uv * size - 0.5, float2(0.0), size - 1.0);
		uint2 a = uint2(pos), b = min(a + 1u, uint2(size) - 1u);
		float2 t = fract(pos);
		cd = mix(mix(R.cloudDistance.read(a).r, R.cloudDistance.read(uint2(b.x,a.y)).r, t.x),
			mix(R.cloudDistance.read(uint2(a.x,b.y)).r, R.cloudDistance.read(b).r, t.x), t.y);
	}
	k *= smoothstep(cd * 0.8, cd * 1.05, length(p));
	float4 cloud = shadeCloudsScreen(normalize(p), L, R.cloudScreen);
	return float4(cloud.rgb * k, mix(1.0, cloud.a, k));
}

#endif
