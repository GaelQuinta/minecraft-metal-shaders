// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// Portions adapted from Photon Shaders by Benjamin Stott ("sixthsurge"), MIT License, commit 26c2906e
// (include/sky/clouds/common.glsl, cumulus.glsl, cirrus.glsl; program/d2_clouds_upscaling.fsh): the cumulus altitude
// shaping (flat bases, egg-shaped tops), the "powder" brightening of dense cores, the cloud phase function as a mix of a
// strong forward lobe and a backward one, the octave loop of the multiple-scattering approximation, the aerial perspective
// blend toward the clear sky by the clouds' apparent distance, and the checkerboard + reprojected-history upscaling.
// History reprojection with Catmull-Rom sampling after Matt Pettineo (MJP), "Bicubic texture filtering with the Catmull-Rom
// spline in 9 / 5 taps" (gist TheRealMJP/c83b8c0f46b63f3a88a5986f4fa982b1), MIT License (5-tap variant, as taa.metal).
// Everything else (units in blocks, the density model, the slab on a curved world, the weather map, the cirrus layer, the
// cloud shadow map, the reflection dome, the bakes) is original; techniques after Schneider & Vos (Horizon Zero Dawn
// volumetric cloudscapes, SIGGRAPH 2015; Nubis 2017/2022) and Wrenninge et al. (multiple-scattering octaves).
//
// E05 volumetric clouds (mcopt.metal.shade.clouds.ShadeClouds, native/mcclouds.m). Loaded after ShadeMsl.prelude().
// Passes (all fragment passes into private textures; the bakes are compute, once):
//   cloud_bake_noise   (compute, once)  64^3 RGBA8 tileable 3D noise: r Perlin-Worley (billows), g/b/a Worley fBm at 3 scales
//   cloud_bake_weather (compute, once)  512^2 RGBA8 tileable 2D noise: r regional coverage, g cumulus cells, b cirrus, a detail
//   cloud_shadow       (256^2 R16F, every 4th frame) transmittance of the cumulus layer toward the light, on the layer's plane (consumers:
//                                       terrain, water, volumetric light: shadeCloudShadow)
//   cloud_march        (1/N x 1/N of the history: this frame's slot of the N x N checkerboard; N = 3 at potato/balanced,
//                                       2 above) cumulus + cirrus: scattered
//                                       light (rgb, before exposure, after aerial perspective) + transmittance, and the
//                                       clouds' apparent distance (MRT)
//   cloud_resolve      (history size)   reprojection (camera motion + wind) of last frame's history, this frame's slot blended
//                                       in, the other slots from the history (or the march upsampled where it is invalid)
//   cloud_dome         (upper hemisphere, 128x64; every 4th frame) a cheap march by direction, temporally blended: the clouds for
//                                       reflections of directions off screen (water) and future environment lighting
// The sky pass (sky.fs.metal) composites the history behind everything: sky * T + S (shade_clouds.metal).

#ifndef MCOPT_SHADE_CLOUDS_PASSES
#define MCOPT_SHADE_CLOUDS_PASSES

// Per-frame parameters (mcopt.metal.shade.clouds.CloudParams packs exactly this layout: 2 matrices + 20 float4 = 448 bytes).
struct CloudParams {
	float4x4 invViewProj;  //   0 this frame's clip -> camera-relative world, without the TAA jitter
	float4x4 prevViewProj; //  64 last frame's camera-relative world (re-based on this camera) -> clip, without jitter
	float4 size;           // 128 xy history size (px), zw march size (px)
	float4 frame;          // 144 xy this frame's checkerboard slot (0..N-1 each), z 1 = drop the history, w most frames blended (age cap)
	float4 layer;          // 160 x cumulus base y, y cumulus top y (absolute), z camera y (absolute), w curvature 1/(2 R) (1/blocks)
	float4 shape;          // 176 x coverage 0..1, y type (0 flat .. 1 towering), z extinction per block at density 1, w erosion
	float4 origin;         // 192 xy the camera's xz in the weather map's space (blocks, wrapped, wind included), zw the same for
	                       //     the 3D noise (mcopt.shade.clouds.noiseDrift 0.82 x the wind: the clouds boil a little as they drift)
	float4 wind;           // 208 xy how far the clouds moved since last frame (blocks), z cirrus coverage, w rain/storm 0..1
	float4 light;          // 224 rgb irradiance from the light reaching the cloud layer (sun or moon; before exposure), w 1 sun
	float4 lightDir;       // 240 xyz toward the light (unit), w M3.1 dev bits (mcopt.shade.clouds.dev; CLOUD_DEV_*)
	float4 ambTop;         // 256 rgb mean sky radiance above the layer (before exposure), w albedo
	float4 ambBottom;      // 272 rgb mean radiance from below (ground and haze), w multiple-scattering boost of the ambient
	float4 march;          // 288 x primary steps, y light steps, z max distance (blocks), w aerial perspective distance (blocks)
	float4 cirrus;         // 304 x altitude (absolute y), y extinction, zw the camera's xz in the cirrus map's space (wrapped)
	float4 shadow;         // 320 x extent (blocks), y reference height (absolute y), zw the map's centre relative to the camera (xz)
	float4 look;           // 336 x powder, y silver lining, z forward g, w overall opacity (fades the clouds in/out)
	float4 dome;           // 352 x dome updates so far (wrapped; FT2.8 audit idx 28, was the width: the size is the history's), y (FT2.10)
	                       //     the bases' spread (share of the thickness a base rises by with the weather map's fine fBm, cloudBaseH),
	                       //     z blend of the new march, w primary steps of the dome march
	float4 misc;           // 368 x frame counter, y first light step (blocks; 0 = 4), z ground height (absolute y: rays stop there), w detail strength
	float4 windDir;        // 384 xy unit axis of the cirrus streaks (fixed in the world; cirrus.zw is in its frame), z checkerboard N (1-4),
	                       //     w radians a march sample covers (history pixel angle x N; the noise mip by distance)
	float4 shadowDir;      // 400 xyz the light the cloud shadow map is cast by (ShadeFrame's: sun, then moon), y >= 0.05, w M3.3 mode bits
	                       //     (CLOUD_MODE_*; CloudConfig.modeBits, read every frame; 0 = M3.2)
	float4 art;            // 416 x multiple-scattering octave weight (each octave x this), y octave extinction factor, z sky-light
	                       //     extinction factor, w style (0 volumetric, 1 blocky: vanilla-style 12-block cells, ray-traced)
	float4 shear;          // 432 xy horizontal offset of the 2D shape over the layer's height (blocks; wind shear: tops lean
	                       //     downwind, and columns stop lining up into streaks toward the zenith), z optical depth per step
	                       //     in cloud (smaller = more samples in dense cloud), w the shortest step (fraction of the base step)
};
static_assert(sizeof(CloudParams) == 448, "CloudParams layout (CloudParams.java)");

// M3.1 dev bits (CloudParams.lightDir.w; CloudConfig.DEV_*): an M3.1 saving switched back to M3's way, for pricing in game
#define CLOUD_DEV_OLD_RESOLVE 1024 // the resolve reads its five march distances one by one (M3)
#define CLOUD_DEV_OLD_MARCH 2048   // the march looks the sky up for every ray, cloud or not (M3)
#define CLOUD_DEV_OLD_MIP 8192     // the billow noise from its full-size level at any distance (M3)
#define CLOUD_DEV_OLD_SHADOW 1048576 // (FT2.7) the shadow map's 6 fixed slices through the slab at any sun height (FT2.6)
// (v12-opt) function constants 0-2: the dev bits, mode bits and style (art.w) compiled in. mcclouds.m's lean march and resolves
// (mc_clouds_lean) are specialized for the values the settings had at startup and bound on the frames whose CloudParams carry
// exactly those values; unset (every other pipeline), the passes read them from CloudParams as before. The same arithmetic
// without the code of the modes that are off (fewer live registers in the latency-bound march).
constant int CLOUD_FC_DEV [[function_constant(0)]];
constant int CLOUD_FC_MODE [[function_constant(1)]];
constant float CLOUD_FC_STYLE [[function_constant(2)]];
constant bool cloudFc = is_function_constant_defined(CLOUD_FC_DEV) && is_function_constant_defined(CLOUD_FC_MODE) && is_function_constant_defined(CLOUD_FC_STYLE);
constant int cloudFcDev = cloudFc ? CLOUD_FC_DEV : 0;
constant int cloudFcMode = cloudFc ? CLOUD_FC_MODE : 0;
constant float cloudFcStyle = cloudFc ? CLOUD_FC_STYLE : 0.0;
static inline bool cloudDev(constant CloudParams &c, int bit) { return ((cloudFc ? cloudFcDev : int(c.lightDir.w)) & bit) != 0; }
// the style (art.w: 0 volumetric, 1 blocky, 2 blocky from the game's cloud texture)
static inline float cloudStyle(constant CloudParams &c) { return cloudFc ? cloudFcStyle : c.art.w; }

// M3.3 mode bits (CloudParams.shadowDir.w; CloudConfig.MODE_*): new behaviour, each bit off = M3.2's way
#define CLOUD_MODE_STABLE 1 // the march's start offsets from a per-pixel hash (not interleaved gradient noise) and the resolve that
                            // carries the clouds' distance in the history (cloud_resolve_st): no comb on soft edges in the wind
#define CLOUD_MODE_LIGHT2 2 // the light march (and the sky-light sample above) on every other in-cloud sample, the ones between
                            // lit by the mean of their neighbours' (cloudMarch)
#define CLOUD_MODE_BATCH 4  // a march sample's texture fetches issued together (cloudDensityB, cloudLightDepthB): same values
                            // (tried on the shadow map's six samples too: twice as slow there, run m33c-2's timer: removed)
#define CLOUD_MODE_PAIR 8   // the march's empty-air tests two at a time (both fetches issued together): same tests, same values
#define CLOUD_MODE_EDGE 16  // the stable resolve's history clamp only where the reprojection depends on the distance (FT1.2)
#define CLOUD_MODE_ZOOM 64  // (FT2.8, audit idx 12) a zoom in (spyglass, FOV) lowers the history's age by how magnified it is
#define CLOUD_MODE_DRIFT 32 // the stable resolve trusts less a history that drifts against a pure turn (near clouds: FT2.6)
static inline bool cloudMode(constant CloudParams &c, int bit) { return ((cloudFc ? cloudFcMode : int(c.shadowDir.w)) & bit) != 0; }

constexpr sampler cloudRep(filter::linear, address::repeat);
// M3.1: the billow noise from the mip level of the sample's footprint, as cloudDensity's lod always meant (M3's cloudRep has
// no mip filter, so its level(lod) read the full-size level at any distance: rays 3 history pixels apart fetched scattered
// texels, slow on the cache; the far billows aliased into grain). Nearest level with the lod dithered per sample (the
// history averages neighbouring levels: no contour where the level changes): march ~ -12 %, same look (CLOUDS.md M3.1).
constexpr sampler cloudRepMip(filter::linear, mip_filter::nearest, address::repeat);
constexpr sampler cloudClamp(filter::linear, address::clamp_to_edge);

// ---- bakes ---------------------------------------------------------------------------------------------------------------
// Periodic gradient noise and Worley noise on integer lattices that wrap (the textures tile), hashed with shadeHash3.
static inline float3 cloudGrad3(int3 c, int period, uint salt) {
	c = ((c % period) + period) % period;
	uint h = shadeHash3(c, salt);
	float3 g = float3(shadeHash01(h), shadeHash01(h ^ 0x68e31da4u), shadeHash01(h ^ 0xb5297a4du)) * 2.0 - 1.0;
	return g * rsqrt(max(dot(g, g), 1e-6));
}

static float cloudPerlin3(float3 p, int period, uint salt) {
	int3 i = int3(floor(p));
	float3 f = p - floor(p);
	float3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float n000 = dot(cloudGrad3(i + int3(0, 0, 0), period, salt), f - float3(0, 0, 0));
	float n100 = dot(cloudGrad3(i + int3(1, 0, 0), period, salt), f - float3(1, 0, 0));
	float n010 = dot(cloudGrad3(i + int3(0, 1, 0), period, salt), f - float3(0, 1, 0));
	float n110 = dot(cloudGrad3(i + int3(1, 1, 0), period, salt), f - float3(1, 1, 0));
	float n001 = dot(cloudGrad3(i + int3(0, 0, 1), period, salt), f - float3(0, 0, 1));
	float n101 = dot(cloudGrad3(i + int3(1, 0, 1), period, salt), f - float3(1, 0, 1));
	float n011 = dot(cloudGrad3(i + int3(0, 1, 1), period, salt), f - float3(0, 1, 1));
	float n111 = dot(cloudGrad3(i + int3(1, 1, 1), period, salt), f - float3(1, 1, 1));
	float x0 = mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y);
	float x1 = mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y);
	return mix(x0, x1, u.z) * 1.15; // ~[-1, 1]
}

// Distance to the nearest of one jittered point per cell (cells per tile = period), 0 .. ~1 (in cells).
static float cloudWorley3(float3 p, int period, uint salt) {
	int3 i = int3(floor(p));
	float3 f = p - floor(p);
	float md = 9.0;
	for (int z = -1; z <= 1; z++)
		for (int y = -1; y <= 1; y++)
			for (int x = -1; x <= 1; x++) {
				int3 c = i + int3(x, y, z);
				int3 w = ((c % period) + period) % period;
				uint h = shadeHash3(w, salt);
				float3 o = float3(shadeHash01(h), shadeHash01(h ^ 0x1b56c4e9u), shadeHash01(h ^ 0x7f4a7c15u));
				float3 r = float3(x, y, z) + o - f;
				md = min(md, dot(r, r));
			}
	return sqrt(md);
}

static inline float cloudRemap(float v, float lo, float hi, float a, float b) {
	return a + (b - a) * saturate((v - lo) / max(hi - lo, 1e-5));
}

// Spreads a roughly normal value (mean mu, deviation sigma, measured on the baked texture: tools/shade/clouds run.sh stats)
// to a roughly uniform 0..1 (logistic approximation of the normal CDF): coverage c then covers about c of the area.
static inline float cloudUniform(float v, float mu, float sigma) {
	return 1.0 / (1.0 + exp(-1.702 * (v - mu) / sigma));
}

// 64^3: one tile spans 1 in each axis of the sampling coordinate.
kernel void cloud_bake_noise(texture3d<half, access::write> out [[texture(0)]], uint3 id [[thread_position_in_grid]]) {
	const float N = 64.0;
	if (any(float3(id) >= N)) return;
	float3 p = (float3(id) + 0.5) / N;
	// Perlin fBm (4, 8, 16 cells), remapped by an inverted Worley fBm: round billows with soft gaps (Perlin-Worley)
	float pf = cloudPerlin3(p * 4.0, 4, 11u) * 0.5 + cloudPerlin3(p * 8.0, 8, 12u) * 0.3 + cloudPerlin3(p * 16.0, 16, 13u) * 0.2;
	pf = saturate(pf * 0.6 + 0.5);
	float w4 = 1.0 - saturate(cloudWorley3(p * 4.0, 4, 21u));
	float w8 = 1.0 - saturate(cloudWorley3(p * 8.0, 8, 22u));
	float w16 = 1.0 - saturate(cloudWorley3(p * 16.0, 16, 23u));
	float w32 = 1.0 - saturate(cloudWorley3(p * 32.0, 32, 24u));
	float wf0 = w4 * 0.625 + w8 * 0.25 + w16 * 0.125;
	float pw = cloudRemap(pf, wf0 - 1.0, 1.0, 0.0, 1.0);
	float g = w4 * 0.625 + w8 * 0.25 + w16 * 0.125;
	float b = w8 * 0.625 + w16 * 0.25 + w32 * 0.125;
	float a = w16 * 0.75 + w32 * 0.25;
	out.write(half4(half(cloudUniform(pw, 0.67, 0.059)), half(cloudUniform(g, 0.48, 0.118)), half(cloudUniform(b, 0.48, 0.118)),
		half(cloudUniform(a, 0.48, 0.14))), id);
}

static inline float2 cloudGrad2(int2 c, int period, uint salt) {
	c = ((c % period) + period) % period;
	uint h = shadeHash3(int3(c, 0), salt);
	float a = shadeHash01(h) * 6.2831853;
	return float2(cos(a), sin(a));
}

static float cloudPerlin2(float2 p, int period, uint salt) {
	int2 i = int2(floor(p));
	float2 f = p - floor(p);
	float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float n00 = dot(cloudGrad2(i, period, salt), f);
	float n10 = dot(cloudGrad2(i + int2(1, 0), period, salt), f - float2(1, 0));
	float n01 = dot(cloudGrad2(i + int2(0, 1), period, salt), f - float2(0, 1));
	float n11 = dot(cloudGrad2(i + int2(1, 1), period, salt), f - float2(1, 1));
	return mix(mix(n00, n10, u.x), mix(n01, n11, u.x), u.y) * 1.4;
}

static float cloudFbm2(float2 p, int period, int octaves, uint salt) {
	float s = 0.0, a = 0.5, n = 0.0;
	for (int i = 0; i < octaves; i++) {
		s += cloudPerlin2(p, period, salt + uint(i)) * a;
		n += a;
		p *= 2.0;
		period *= 2;
		a *= 0.5;
	}
	return s / n;
}

static float cloudWorley2(float2 p, int period, uint salt) {
	int2 i = int2(floor(p));
	float2 f = p - floor(p);
	float md = 9.0;
	for (int y = -1; y <= 1; y++)
		for (int x = -1; x <= 1; x++) {
			int2 c = i + int2(x, y);
			int2 w = ((c % period) + period) % period;
			uint h = shadeHash3(int3(w, 1), salt);
			float2 o = float2(shadeHash01(h), shadeHash01(h ^ 0x1b56c4e9u));
			float2 r = float2(x, y) + o - f;
			md = min(md, dot(r, r));
		}
	return sqrt(md);
}

// 512^2, one tile = CLOUD_WEATHER_TILE blocks (4096): r regional coverage (features ~1500 blocks), g cumulus cells
// (~200-300 blocks: Perlin fBm shaped by an inverted Worley, clustered), b cirrus fBm, a fine detail fBm.
kernel void cloud_bake_weather(texture2d<half, access::write> out [[texture(0)]], uint2 id [[thread_position_in_grid]]) {
	const float N = 512.0;
	if (any(float2(id) >= N)) return;
	float2 p = (float2(id) + 0.5) / N;
	float r = cloudFbm2(p * 3.0, 3, 4, 101u);
	float pf = cloudFbm2(p * 12.0, 12, 4, 201u);
	float w = 1.0 - saturate(cloudWorley2(p * 16.0, 16, 301u));
	float w2 = 1.0 - saturate(cloudWorley2(p * 32.0, 32, 302u));
	float cells = pf + (w * 0.75 + w2 * 0.25) * 0.45;
	float b = cloudFbm2(p * 6.0, 6, 5, 401u);
	float a = cloudFbm2(p * 24.0, 24, 3, 501u);
	out.write(half4(half(cloudUniform(r * 0.5 + 0.5, 0.49, 0.104)), half(cloudUniform(cells * 0.5 + 0.25, 0.38, 0.1035)),
		half(cloudUniform(b * 0.5 + 0.5, 0.50, 0.089)), half(cloudUniform(a * 0.5 + 0.5, 0.50, 0.104))), id);
}

// ---- the layer -----------------------------------------------------------------------------------------------------------
#define CLOUD_WEATHER_TILE 4096.0
#define CLOUD_NOISE_SCALE (1.0 / 120.0)
#define CLOUD_DETAIL_SCALE (1.0 / 60.0)
#define CLOUD_NOISE_TEXEL (120.0 / 64.0) // blocks per texel of the billow noise

struct CloudRay {
	float a, b, y0; // altitude above the curved ground along the ray: y0 + b t + a t^2
};

static inline CloudRay cloudRay(float3 dir, constant CloudParams &c) {
	CloudRay r;
	r.a = max(c.layer.w * (1.0 - dir.y * dir.y), 1e-9);
	r.b = dir.y;
	r.y0 = c.layer.z;
	return r;
}

static inline float cloudAltitude(CloudRay r, float t) { return r.y0 + t * (r.b + t * r.a); }

// Real roots of a t^2 + b t + cc = 0 (a > 0), r1 <= r2; false when none. Stable form (no cancellation for tiny a).
static inline bool cloudRoots(float a, float b, float cc, thread float &r1, thread float &r2) {
	float disc = b * b - 4.0 * a * cc;
	if (disc < 0.0) return false;
	float q = -0.5 * (b + (b >= 0.0 ? 1.0 : -1.0) * sqrt(disc));
	float x1 = q / a, x2 = abs(q) > 1e-20 ? cc / q : x1;
	r1 = min(x1, x2);
	r2 = max(x1, x2);
	return true;
}

// The first stretch [t0, t1] of the ray inside the slab yb..yt (curved with the world), clipped at maxT and at the ground;
// false when there is none.
static bool cloudSegment(CloudRay r, float yb, float yt, float ground, float maxT, thread float &t0, thread float &t1) {
	float t1a, t2a;
	if (!cloudRoots(r.a, r.b, r.y0 - yt, t1a, t2a)) return false; // always above the top
	float lo = max(t1a, 0.0), hi = t2a;
	float r1, r2;
	if (cloudRoots(r.a, r.b, r.y0 - yb, r1, r2)) {
		// below the base between r1 and r2
		float s0 = lo, s1 = min(hi, r1);
		if (s1 <= s0) {
			s0 = max(lo, r2);
			s1 = hi;
		}
		lo = s0;
		hi = s1;
	}
	float g1, g2;
	if (r.y0 > ground && cloudRoots(r.a, r.b, r.y0 - ground, g1, g2) && g1 > 0.0) hi = min(hi, g1); // the planet in the way
	hi = min(hi, maxT);
	t0 = lo;
	t1 = hi;
	return hi > lo;
}

// Cumulus density (0..1) at camera-relative p with absolute altitude y. q: 0 = 2D shape only (far light samples, shadow
// map), 1 = + billows (3D), 2 = + fine detail.
#define CLOUD_BLOCK 12.0

// Blocky style: whether the 12-block cell at wrapped world xz holds a cloud (the weather map's cells at the cell's centre,
// with the day's coverage), like vanilla's cloud texture but following our weather.
// (1.1) art.w 2: the game's own cloud texture (ShadeClouds: textures/environment/clouds.png as a 0/1 mask, bound in place of the
// weather map; one texel per 12-block cell, origin.xy in its space as vanilla's CloudRenderer places it).
static inline bool cloudBlockFilled(float2 cell, constant CloudParams &c, texture2d<half> weather) {
	if (cloudStyle(c) > 1.5) {
		float2 size = float2(weather.get_width(), weather.get_height());
		return weather.sample(cloudRep, (cell + 0.5) / size, level(0.0)).r > 0.5h;
	}
	half4 w = weather.sample(cloudRep, (cell + 0.5) * (CLOUD_BLOCK / CLOUD_WEATHER_TILE), level(0.0));
	float cov = saturate(c.shape.x + (float(w.r) - 0.5) * 0.55);
	return float(w.g) > 1.0 - cov;
}
static inline bool cloudBlockCell(float2 xz, constant CloudParams &c, texture2d<half> weather) {
	return cloudBlockFilled(floor(xz / CLOUD_BLOCK), c, weather);
}

// (FT2.10, CloudParams.dome.y) far clouds' bases spread: with every base on the layer's floor, the clouds beyond ~1000 blocks lined up
// toward the horizon into thin flat-bottomed slivers stacked like plates, dark straight lines across the sunset sky (Gael
// 2026-10-10). Out there the bases rise by up to dome.y of the thickness with the weather map's fine fBm (features ~170 blocks),
// so they stand at different heights and ragged, and fade in softer; within ~400 blocks (the clouds overhead) they stay flat as
// before (spread 0: the same shapes). rel: the point's camera-relative xz.
static inline float cloudSpread(float2 rel, constant CloudParams &c) {
	return c.dome.y > 0.0 ? c.dome.y * smoothstep(400.0, 1500.0, length(rel)) : 0.0;
}
// The height in the layer measured from this point's own cloud base (spread: cloudSpread).
static inline float cloudBaseH(float h, half4 w, float spread) {
	float off = spread * float(w.a);
	return off > 0.0 ? (h - off) / (1.0 - off) : h;
}

// lod: mip level of the 3D noise (log2 of the sample's footprint in billow texels): far samples read blurred noise
// instead of aliasing it into grain.
static float cloudDensity(float3 p, float y, int q, constant CloudParams &c, texture2d<half> weather, texture3d<half> noise,
                          float detail = 1.0, float lod = 0.0) {
	if (cloudStyle(c) > 0.5) return y >= c.layer.x && y <= c.layer.y && cloudBlockCell(c.origin.xy + p.xz, c, weather) ? 1.0 : 0.0;
	float h = (y - c.layer.x) / (c.layer.y - c.layer.x);
	if (h <= 0.0 || h >= 1.0) return 0.0;
	float2 xz = c.origin.xy + p.xz;
	half4 w = weather.sample(cloudRep, (xz - c.shear.xy * h) * (1.0 / CLOUD_WEATHER_TILE), level(0.0));
	float spread = cloudSpread(p.xz, c);
	h = cloudBaseH(h, w, spread);
	if (h <= 0.0) return 0.0;
	// coverage varies by region (the weather map's r), the cells (g) say where the cumulus stand
	float cov = saturate(c.shape.x + (float(w.r) - 0.5) * 0.55);
	float cell = float(w.g);
	float core = saturate((cell - (1.0 - cov)) / max(cov, 0.08)); // 0 at a cloud's footprint edge, 1 in its core
	// vertical profile (after Photon's cumulus shaping): a flat base, the footprint shrinking toward an egg-shaped top; the
	// column's height grows with its core and the day's cloud type (flat fair-weather cumulus .. towering)
	float topH = mix(0.38, 1.0, c.shape.y) * (0.45 + 0.55 * core);
	float x = h / max(topH, 0.05);
	float d = core - x * x * mix(0.9, 0.6, c.shape.y);
	d *= smoothstep(0.0, 0.04 + 0.3 * spread, h); // (FT2.10: softer where the bases spread, cloudSpread)
	if (d <= 0.0) return 0.0;
	if (q == 0) return saturate(d * 0.85);
	float3 n3 = float3(xz.x + c.origin.z - c.origin.x, y, xz.y + c.origin.w - c.origin.y);
	half4 n = cloudDev(c, CLOUD_DEV_OLD_MIP) ? noise.sample(cloudRep, n3 * CLOUD_NOISE_SCALE, level(lod))
		: noise.sample(cloudRepMip, n3 * CLOUD_NOISE_SCALE, level(lod));
	// billows (after Photon's detail erosion): Worley distance squared eats into the shape between the cells, more where
	// the cloud is thin (dampen(1 - d)), so the edges and the tops break into round lobes; the Perlin-Worley adds variety
	float wd = 1.0 - (float(n.g) * 0.75 + float(n.r) * 0.25);
	float thin = saturate(1.0 - d);
	thin = thin * (2.0 - thin);
	d -= c.shape.w * 0.55 * wd * wd * thin;
	if (q >= 2 && d > 0.0) {
		half4 m = cloudDev(c, CLOUD_DEV_OLD_MIP) ? noise.sample(cloudRep, n3 * CLOUD_DETAIL_SCALE, level(lod + 1.0))
			: noise.sample(cloudRepMip, n3 * CLOUD_DETAIL_SCALE, level(lod + 1.0));
		float wd2 = 1.0 - (float(m.g) * 0.6 + float(m.b) * 0.4);
		// fine detail: strongest on the sides and lower half, little on the domes' crowns
		float fade = 0.6 + 0.2 * smoothstep(0.85, 1.0, 1.0 - h) - 0.35 * smoothstep(0.05, 0.5, h);
		d -= 0.55 * c.misc.w * detail * wd2 * wd2 * thin * fade;
	}
	// inner texture: the billow noise varies the density inside the cloud too (mottled bases and bellies seen from below,
	// uneven light through the body), not only its edges
	d *= mix(0.85 + 0.3 * float(n.r), 0.6 + 0.8 * float(n.r), c.wind.w);
	d = saturate(d);
	// A broad low-density fringe lets the sky remain visible through the cloud boundary.
	float feather = smoothstep(0.0, 0.5, d);
	return feather * d * (0.5 + 0.5 * smoothstep(0.0, 0.2, h));
}

// ---- M3.3 (CLOUD_MODE_BATCH): the same densities with every texture fetch of a sample issued before any of them is used ----
// cloudDensity returns early between its fetches (no cloud in the weather map: no noise fetch), so a march sample was a chain
// of dependent fetches (weather, then billows, then detail; the light march three of those in a row, then the sky-light
// sample above): the march is latency-bound (a few samples per ray, most of its time waiting). Here the positions are worked
// out first, all fetches are issued together (some unused), then cloudDensityMath (cloudDensity's arithmetic, unchanged:
// keep the two in step) evaluates them.
static inline float cloudDensityMath(half4 w, half4 n, half4 m, float h, int q, constant CloudParams &c, float detail, float2 rel) {
	if (h <= 0.0 || h >= 1.0) return 0.0;
	float spread = cloudSpread(rel, c);
	h = cloudBaseH(h, w, spread);
	if (h <= 0.0) return 0.0;
	float cov = saturate(c.shape.x + (float(w.r) - 0.5) * 0.55);
	float cell = float(w.g);
	float core = saturate((cell - (1.0 - cov)) / max(cov, 0.08));
	float topH = mix(0.38, 1.0, c.shape.y) * (0.45 + 0.55 * core);
	float x = h / max(topH, 0.05);
	float d = core - x * x * mix(0.9, 0.6, c.shape.y);
	d *= smoothstep(0.0, 0.04 + 0.3 * spread, h); // (FT2.10: softer where the bases spread, cloudSpread)
	if (d <= 0.0) return 0.0;
	if (q == 0) return saturate(d * 0.85);
	float wd = 1.0 - (float(n.g) * 0.75 + float(n.r) * 0.25);
	float thin = saturate(1.0 - d);
	thin = thin * (2.0 - thin);
	d -= c.shape.w * 0.55 * wd * wd * thin;
	if (q >= 2 && d > 0.0) {
		float wd2 = 1.0 - (float(m.g) * 0.6 + float(m.b) * 0.4);
		float fade = 0.6 + 0.2 * smoothstep(0.85, 1.0, 1.0 - h) - 0.35 * smoothstep(0.05, 0.5, h);
		d -= 0.55 * c.misc.w * detail * wd2 * wd2 * thin * fade;
	}
	d *= mix(0.85 + 0.3 * float(n.r), 0.6 + 0.8 * float(n.r), c.wind.w);
	d = saturate(d);
	float feather = smoothstep(0.0, 0.5, d);
	return feather * d * (0.5 + 0.5 * smoothstep(0.0, 0.2, h));
}

static inline half4 cloudWeatherAt(float2 xz, float h, constant CloudParams &c, texture2d<half> weather) {
	return weather.sample(cloudRep, (xz - c.shear.xy * h) * (1.0 / CLOUD_WEATHER_TILE), level(0.0));
}

static inline float3 cloudNoisePos(float2 xz, float y, constant CloudParams &c) {
	return float3(xz.x + c.origin.z - c.origin.x, y, xz.y + c.origin.w - c.origin.y);
}

// cloudDensity (volumetric, M3.1 noise mips) with its fetches issued together.
static inline float cloudDensityB(float3 p, float y, int q, constant CloudParams &c, texture2d<half> weather, texture3d<half> noise,
                                  float detail, float lod) {
	float h = (y - c.layer.x) / (c.layer.y - c.layer.x);
	float2 xz = c.origin.xy + p.xz;
	float3 n3 = cloudNoisePos(xz, y, c);
	half4 w = cloudWeatherAt(xz, h, c, weather);
	half4 n = noise.sample(cloudRepMip, n3 * CLOUD_NOISE_SCALE, level(lod));
	half4 m = q >= 2 ? noise.sample(cloudRepMip, n3 * CLOUD_DETAIL_SCALE, level(lod + 1.0)) : half4(0.0h);
	return cloudDensityMath(w, n, m, h, q, c, detail, p.xz);
}

// cloudLightDepth (up to 4 light steps; the first two with billows) and the sky-light sample above (pUp, yUp: its 2D density in
// dUp) with all their fetches issued together.
static float cloudLightDepthB(float3 p, float y, float jitter, int steps, constant CloudParams &c, texture2d<half> weather,
                              texture3d<half> noise, float lod, float3 pUp, float yUp, thread float &dUp) {
	float3 L = c.lightDir.xyz;
	float inv = 1.0 / (c.layer.y - c.layer.x);
	float s = 0.0, stp = c.misc.y > 0.0 ? c.misc.y : 4.0;
	float grow = steps <= 3 ? 3.5 : steps == 4 ? 2.6 : 2.0;
	float hs[4], len[4];
	float2 xz[4], rl[4];
	float yq[4];
	for (int i = 0; i < 4; i++) {
		float m = s + stp * (0.5 + 0.5 * (jitter - 0.5));
		float3 q = p + L * m;
		yq[i] = y + L.y * m;
		hs[i] = (yq[i] - c.layer.x) * inv;
		rl[i] = q.xz;
		xz[i] = c.origin.xy + q.xz;
		len[i] = stp;
		s += stp;
		stp *= grow;
	}
	float hUp = (yUp - c.layer.x) * inv;
	float2 xzUp = c.origin.xy + pUp.xz;
	half4 w0 = cloudWeatherAt(xz[0], hs[0], c, weather), w1 = cloudWeatherAt(xz[1], hs[1], c, weather);
	half4 w2 = steps > 2 ? cloudWeatherAt(xz[2], hs[2], c, weather) : half4(0.0h);
	half4 w3 = steps > 3 ? cloudWeatherAt(xz[3], hs[3], c, weather) : half4(0.0h);
	half4 wUp = cloudWeatherAt(xzUp, hUp, c, weather);
	half4 n0 = noise.sample(cloudRepMip, cloudNoisePos(xz[0], yq[0], c) * CLOUD_NOISE_SCALE, level(lod));
	half4 n1 = noise.sample(cloudRepMip, cloudNoisePos(xz[1], yq[1], c) * CLOUD_NOISE_SCALE, level(lod + 1.0));
	float tau = cloudDensityMath(w0, n0, n0, hs[0], 1, c, 1.0, rl[0]) * len[0];
	if (steps > 1) tau += cloudDensityMath(w1, n1, n1, hs[1], 1, c, 1.0, rl[1]) * len[1];
	if (steps > 2) tau += cloudDensityMath(w2, w2, w2, hs[2], 0, c, 1.0, rl[2]) * len[2];
	if (steps > 3) tau += cloudDensityMath(w3, w3, w3, hs[3], 0, c, 1.0, rl[3]) * len[3];
	dUp = cloudDensityMath(wUp, wUp, wUp, hUp, 0, c, 1.0, pUp.xz);
	return tau * c.shape.z;
}

// Optical depth toward the light from p (blocks x density x extinction): steps double from 6 blocks, jittered.
static float cloudLightDepth(float3 p, float y, float jitter, int steps, constant CloudParams &c, texture2d<half> weather, texture3d<half> noise,
                             float lod) {
	float3 L = c.lightDir.xyz;
	// steps of 4, 8, 16, 32... blocks (faster growth with fewer steps): the first two see the billows (3D noise: shadowed creases between the lobes), the
	// rest only the cloud's large shape
	float tau = 0.0, s = 0.0, step = c.misc.y > 0.0 ? c.misc.y : 4.0;
	// fewer steps grow faster, so the march still reaches ~90-110 blocks (deep shadow inside big clouds)
	float grow = steps <= 3 ? 3.5 : steps == 4 ? 2.6 : 2.0;
	for (int i = 0; i < steps; i++) {
		float m = s + step * (0.5 + 0.5 * (jitter - 0.5));
		float3 q = p + L * m;
		tau += cloudDensity(q, y + L.y * m, i < 2 ? 1 : 0, c, weather, noise, 1.0, lod + float(i)) * step;
		s += step;
		step *= grow;
	}
	return tau * c.shape.z;
}

static inline float cloudHG(float mu, float g) {
	float g2 = g * g;
	float x = max(1.0 + g2 - 2.0 * g * mu, 1e-4);
	return 0.0795775 * (1.0 - g2) / (x * sqrt(x)); // x^1.5 without pow's log and exp (12 per marched ray)
}

// Phase: a strong forward lobe, a narrow silver-lining peak and a backward lobe (Photon's mix, our weights); k narrows
// the lobes for the multiple-scattering octaves.
static inline float cloudPhase(float mu, float k, constant CloudParams &c) {
	float g = c.look.z * k;
	return 0.7 * cloudHG(mu, g) + c.look.y * k * cloudHG(mu, 0.97) + 0.3 * cloudHG(mu, -0.25 * k);
}

struct CloudResult {
	float3 S;    // scattered light toward the camera (before exposure)
	float T;     // transmittance
	float dist;  // apparent distance (blocks): transmittance-weighted mean depth of what scattered
};

// One in-cloud sample's light (direct + ambient; x albedo x its segment weight T (1 - stepT): the light it scatters to the camera):
// tauL the optical depth toward the light, dUp the 2D density above it (sky light), d its density, st = d x extinction.
static inline float3 cloudSampleLight(float tauL, float dUp, float d, float st, float h, float y, float mu, float pw, float ph0, float ph1,
                                      float ph2, float ph3, constant CloudParams &c) {
	float sigma = c.shape.z;
	float above = c.layer.y - y;
	// (diffuse light: much less extinct than the direct beam)
	float tauUp = (dUp * 0.7 + d * 0.3) * sigma * above * c.art.z;
	float tauDown = d * sigma * (y - c.layer.x) * c.art.z * 0.75;
	// multiple scattering: 4 octaves (Wrenninge): each dimmer, far less extinct and more isotropic (the light that
	// diffuses through a thick cloud: lit sides near white, bases grey, not black)
	float a1 = c.art.x, b1 = c.art.y;
	float ms = exp(-tauL) * ph0 + a1 * exp(-b1 * tauL) * ph1 + a1 * a1 * exp(-b1 * b1 * tauL) * ph2
		+ a1 * a1 * a1 * exp(-b1 * b1 * b1 * tauL) * ph3;
	// powder: the thin skin of a cloud scatters less light toward the eye than its depths (dark creases on the sunlit
	// side), gone when looking toward the light (Schneider's "beer-powder", shaped after Photon's)
	float powder = 1.0 - pw * exp(-st * 28.0);
	ms *= mix(powder, 1.0, saturate(mu * 1.5));
	float3 direct = c.light.rgb * ms;
	// Diffuse multiple scattering keeps the interior lit even when the direct sun is occluded.
	float skyFill = 0.5 + 0.5 * exp(-tauUp);
	float groundFill = 0.35 + 0.65 * exp(-tauDown);
	float3 amb = (c.ambTop.rgb * skyFill * (0.55 + 0.45 * h) + c.ambBottom.rgb * groundFill) * c.ambBottom.w;
	return direct + amb;
}

// The cumulus layer along dir (camera-relative world, unit). steps/lsteps: primary and light samples; q: best density
// quality; jitter in [0, 1).
// foot: the radians one march sample covers (the noise mip by distance): the screen march's windDir.w, the dome's own texel
// (FT2.8, audit idx 15: the dome took the screen's, 2-3.5 mips too sharp for its 128 x 64 texels: reflected clouds sparkled)
static CloudResult cloudMarch(float3 dir, int steps, int lsteps, int q, float jitter, constant CloudParams &c, texture2d<half> weather,
                              texture3d<half> noise, float foot) {
	CloudResult o;
	o.S = 0.0;
	o.T = 1.0;
	o.dist = -1.0;
	CloudRay r = cloudRay(dir, c);
	float t0, t1;
	if (!cloudSegment(r, c.layer.x, c.layer.y, c.misc.z, c.march.z, t0, t1)) return o;
	// inside the layer: the fog around the camera matters, the far stretch is hidden by it (and by aerial perspective)
	bool inside = t0 < 1.0;
	if (inside) t1 = min(t1, 1500.0);
	float len = t1 - t0;
	// fewer, longer steps where the stretch is short (straight up); along the long grazing stretches toward the horizon the
	// steps stay at most ~48 blocks (up to 3x the steps): 100-200-block steps there sliced the far clouds into horizontal
	// stripes of see-through sky at sunset (Gael's report 2026-10-07; steps=60 removed them, a bigger loop budget did not)
	int n = clamp(int(max(float(steps) * saturate(len / 600.0), len / 48.0) + 0.999), max(steps / 2, 4), 3 * steps);
	float dt = len / float(n);
	// the fine detail (a ~30-block tile) fades out where the steps get too coarse to resolve it (it aliases into grain)
	float detail = saturate((26.0 - dt) / 14.0);
	if (detail <= 0.0) q = min(q, 1);
	float sigma = c.shape.z;
	float albedo = c.ambTop.w;
	float3 L = c.lightDir.xyz;
	float mu = dot(dir, L);
	float pw = c.look.x;
	// the phase depends on the ray only (mu): the octaves' lobes once per ray, not per sample (12 pow per sample before)
	float ph0 = cloudPhase(mu, 1.0, c), ph1 = cloudPhase(mu, 0.5, c), ph2 = cloudPhase(mu, 0.25, c), ph3 = cloudPhase(mu, 0.125, c);
	float3 Sacc = 0.0;
	float T = 1.0, dsum = 0.0, wsum = 0.0;
	float thick = c.layer.y - c.layer.x;
	// empty air is crossed with double steps on the 2D footprint alone (a superset of the cloud: erosion only removes);
	// a hit steps back and walks on with single full-quality steps until 4 misses in a row
	bool fine = false;
	int miss = 0;
	// M3.3 (CLOUD_MODE_LIGHT2): the pending sample between two light marches (its weight, density, extinction, height, y)
	bool light2 = cloudMode(c, CLOUD_MODE_LIGHT2), haveL = false, odd = false;
	// M3.3 (CLOUD_MODE_BATCH): fetches issued together (the M3 noise sampler, dev bit OLD_MIP, and > 4 light steps keep the chain)
	bool batch = cloudMode(c, CLOUD_MODE_BATCH) && !cloudDev(c, CLOUD_DEV_OLD_MIP) && lsteps <= 4;
	float lastTauL = 0.0, lastUp = 0.0, pw0 = 0.0, pd = 0.0, pst = 0.0, ph = 0.0, py = 0.0;
	// inside the layer the steps start short and grow with distance (the cloud around the camera is close: uniform 60-block
	// steps made it a noisy guess that showed the checkerboard)
	float dtl = inside ? dt * 0.08 : dt;
	float t = t0 + jitter * dtl;
	int budget = 3 * n + 4 + (inside ? 24 : 0);
	// M3.3 (CLOUD_MODE_PAIR): outside the layer, the empty-air test also looks one double step ahead, both fetches issued
	// together (the tests and their order are the serial loop's: a pair counts as two iterations)
	bool pair = cloudMode(c, CLOUD_MODE_PAIR) && !inside;
	for (int i = 0; i < budget && t < t1; i++) {
		if (inside) dtl = dt * clamp((t + 24.0) / 400.0, 0.08, 1.0);
		float3 p = dir * t;
		float y = cloudAltitude(r, t);
		if (!fine && pair) {
			float tB = t + 2.0 * dtl;
			float3 pB = dir * tB;
			float yB = cloudAltitude(r, tB);
			float inv = 1.0 / (c.layer.y - c.layer.x);
			float hA = (y - c.layer.x) * inv, hB = (yB - c.layer.x) * inv;
			half4 wA = cloudWeatherAt(c.origin.xy + p.xz, hA, c, weather), wB = cloudWeatherAt(c.origin.xy + pB.xz, hB, c, weather);
			bool useB = i + 1 < budget && tB < t1;
			if (cloudDensityMath(wA, wA, wA, hA, 0, c, 1.0, p.xz) > 0.0) {
				fine = true;
				miss = 0;
				t = max(t - dtl, t0 + jitter * dtl);
				continue;
			}
			t = tB;
			if (!useB) continue;
			i++;
			if (cloudDensityMath(wB, wB, wB, hB, 0, c, 1.0, pB.xz) > 0.0) {
				fine = true;
				miss = 0;
				t = max(tB - dtl, t0 + jitter * dtl);
				continue;
			}
			t = tB + 2.0 * dtl;
			continue;
		}
		if (!fine) {
			if (cloudDensity(p, y, 0, c, weather, noise) <= 0.0) {
				t += 2.0 * dtl;
				continue;
			}
			fine = true;
			miss = 0;
			t = max(t - dtl, t0 + jitter * dtl);
			continue;
		}
		// mip of the noise for this sample's footprint (pixel angle x distance)
		// (M3.1: dithered per sample for the nearest-level sampler; CLOUD_DEV_OLD_MIP: M3's, whose level was ignored)
		float lod = cloudDev(c, CLOUD_DEV_OLD_MIP) ? max(log2(max(t * foot, 1e-3) / CLOUD_NOISE_TEXEL), 0.0)
			: max(log2(max(t * foot, 1e-3) / CLOUD_NOISE_TEXEL), 0.0) + fract(jitter * 3.17 + float(i) * 0.7548777) - 0.5;
		// skylight from above through what is left above this point (one cheap sample), bounce from below
		float above = c.layer.y - y;
		// (CLOUD_MODE_BATCH) a sample that will need a light march fetches for it together with its own density (wasted
		// when the sample misses: few do)
		bool needL = !(light2 && haveL && !odd);
		float d, tauL = 0.0, dUp = 0.0;
		if (batch && needL) {
			d = cloudDensityB(p, y, T > 0.25 ? q : 1, c, weather, noise, detail, lod);
			tauL = cloudLightDepthB(p, y, fract(jitter + float(i) * 0.618034), lsteps, c, weather, noise, lod, p + float3(0.0, above * 0.4, 0.0),
				y + above * 0.4, dUp);
		} else if (batch) {
			d = cloudDensityB(p, y, T > 0.25 ? q : 1, c, weather, noise, detail, lod);
		} else {
			d = cloudDensity(p, y, T > 0.25 ? q : 1, c, weather, noise, detail, lod);
		}
		if (d <= 0.002) {
			if (++miss >= 4) fine = false;
			t += dtl;
			continue;
		}
		miss = 0;
		float st = d * sigma;
		// in dense cloud a whole step would jump from lit to opaque: at most shear.z optical depths per sample (down to
		// shear.w of a step), so where the ray starts in the cloud (the jitter) matters less
		float ds = clamp(c.shear.z / max(st, 1e-4), dtl * c.shear.w, dtl);
		float stepT = exp(-st * ds);
		float h = saturate((y - c.layer.x) / thick);
		float wseg = T * (1.0 - stepT);
		dsum += t * wseg;
		wsum += wseg;
		T *= stepT;
		// M3.3 (CLOUD_MODE_LIGHT2): every other sample waits for the next one's light march and takes the mean of its
		// neighbours' (the light depth and the sky-light sample above vary smoothly along the ray)
		if (!needL) {
			odd = true;
			pw0 = wseg;
			pd = d;
			pst = st;
			ph = h;
			py = y;
			if (T < 0.02) break;
			t += ds;
			continue;
		}
		if (!batch) {
			tauL = cloudLightDepth(p, y, fract(jitter + float(i) * 0.618034), lsteps, c, weather, noise, lod);
			dUp = cloudDensity(p + float3(0.0, above * 0.4, 0.0), y + above * 0.4, 0, c, weather, noise);
		}
		if (odd) {
			Sacc += (albedo * pst * cloudSampleLight(0.5 * (lastTauL + tauL), 0.5 * (lastUp + dUp), pd, pst, ph, py, mu, pw, ph0, ph1, ph2, ph3, c))
				* (pw0 / max(pst, 1e-6));
			odd = false;
		}
		lastTauL = tauL;
		lastUp = dUp;
		haveL = true;
		float3 Sstep = albedo * st * cloudSampleLight(tauL, dUp, d, st, h, y, mu, pw, ph0, ph1, ph2, ph3, c);
		Sacc += Sstep * (wseg / max(st, 1e-6));
		if (T < 0.02) break;
		t += ds;
	}
	// a sample still waiting for its neighbour's light: the last one's
	if (odd) Sacc += (albedo * pst * cloudSampleLight(lastTauL, lastUp, pd, pst, ph, py, mu, pw, ph0, ph1, ph2, ph3, c)) * (pw0 / max(pst, 1e-6));
	o.S = Sacc;
	o.T = T; // Preserve the remaining sky transmission instead of remapping it toward opaque.
	o.dist = wsum > 1e-5 ? dsum / wsum : t0;
	return o;
}

// Thin cirrus on a curved plane high above the cumulus: streaks along the wind, lit with a broad forward lobe.
static CloudResult cloudCirrus(float3 dir, constant CloudParams &c, texture2d<half> weather) {
	CloudResult o;
	o.S = 0.0;
	o.T = 1.0;
	o.dist = -1.0;
	if (c.wind.z <= 0.001) return o;
	CloudRay r = cloudRay(dir, c);
	float r1, r2;
	if (!cloudRoots(r.a, r.b, r.y0 - c.cirrus.x, r1, r2)) return o;
	float t = r1 > 0.0 ? r1 : r2;
	if (t <= 0.0 || t > c.march.z * 1.6) return o;
	// in the streaks' frame (axis fixed in the world; cirrus.zw: the camera there, wrapped), stretched 4:1 along the axis
	float2 rel = dir.xz * t;
	float2 wd = c.windDir.xy, wn = float2(-wd.y, wd.x);
	float2 s = c.cirrus.zw + float2(dot(rel, wd), dot(rel, wn));
	half4 w0 = weather.sample(cloudRep, s * float2(1.0 / 16384.0, 1.0 / 4096.0), level(0.0));
	float2 warp = (float2(w0.a, w0.r) - 0.5) * 0.06;
	half4 w1 = weather.sample(cloudRep, s * float2(1.0 / 8192.0, 1.0 / 2048.0) + warp, level(0.0));
	half4 w2 = weather.sample(cloudRep, s * float2(1.0 / 4096.0, 1.0 / 1024.0) + warp * 1.5, level(0.0));
	// broad sheets (w0, w1) combed into soft streaks (w2)
	float n = float(w0.b) * 0.45 + float(w1.b) * 0.4 + float(w2.a) * 0.15;
	float d = cloudRemap(n, 1.0 - c.wind.z * 0.6, 1.0, 0.0, 1.0);
	d *= 0.55 + 0.45 * float(w2.b);
	d = d * d * (3.0 - 2.0 * d);
	if (d <= 0.0) return o;
	float tau = d * c.cirrus.y;
	float T = exp(-tau);
	float mu = dot(dir, c.lightDir.xyz);
	float phase = 0.6 * cloudHG(mu, 0.75) + 0.4 * cloudHG(mu, 0.2);
	float3 S = (c.light.rgb * phase * 3.0 + c.ambTop.rgb * 0.9) * (1.0 - T) * 0.9;
	o.S = S;
	o.T = T;
	o.dist = t;
	return o;
}

// M3.3 (CLOUD_MODE_BATCH): cloudCirrus in two halves, the first one's fetch issued before the cumulus march and used after
// it (the same values as cloudCirrus).
struct CloudCirrusPre {
	float t;     // distance to the cirrus plane (<= 0: none)
	float2 s;    // the streaks' frame position
	half4 w0;    // the broad sheets' fetch
};

static inline CloudCirrusPre cloudCirrusBegin(float3 dir, constant CloudParams &c, texture2d<half> weather) {
	CloudCirrusPre o;
	o.t = 0.0;
	o.s = 0.0;
	o.w0 = half4(0.0h);
	if (c.wind.z <= 0.001) return o;
	CloudRay r = cloudRay(dir, c);
	float r1, r2;
	if (!cloudRoots(r.a, r.b, r.y0 - c.cirrus.x, r1, r2)) return o;
	float t = r1 > 0.0 ? r1 : r2;
	if (t <= 0.0 || t > c.march.z * 1.6) return o;
	float2 rel = dir.xz * t;
	float2 wd = c.windDir.xy, wn = float2(-wd.y, wd.x);
	o.s = c.cirrus.zw + float2(dot(rel, wd), dot(rel, wn));
	o.w0 = weather.sample(cloudRep, o.s * float2(1.0 / 16384.0, 1.0 / 4096.0), level(0.0));
	o.t = t;
	return o;
}

static inline CloudResult cloudCirrusEnd(CloudCirrusPre pre, float3 dir, constant CloudParams &c, texture2d<half> weather) {
	CloudResult o;
	o.S = 0.0;
	o.T = 1.0;
	o.dist = -1.0;
	if (pre.t <= 0.0) return o;
	float2 s = pre.s;
	half4 w0 = pre.w0;
	float2 warp = (float2(w0.a, w0.r) - 0.5) * 0.06;
	half4 w1 = weather.sample(cloudRep, s * float2(1.0 / 8192.0, 1.0 / 2048.0) + warp, level(0.0));
	half4 w2 = weather.sample(cloudRep, s * float2(1.0 / 4096.0, 1.0 / 1024.0) + warp * 1.5, level(0.0));
	float n = float(w0.b) * 0.45 + float(w1.b) * 0.4 + float(w2.a) * 0.15;
	float d = cloudRemap(n, 1.0 - c.wind.z * 0.6, 1.0, 0.0, 1.0);
	d *= 0.55 + 0.45 * float(w2.b);
	d = d * d * (3.0 - 2.0 * d);
	if (d <= 0.0) return o;
	float tau = d * c.cirrus.y;
	float T = exp(-tau);
	float mu = dot(dir, c.lightDir.xyz);
	float phase = 0.6 * cloudHG(mu, 0.75) + 0.4 * cloudHG(mu, 0.2);
	float3 S = (c.light.rgb * phase * 3.0 + c.ambTop.rgb * 0.9) * (1.0 - T) * 0.9;
	o.S = S;
	o.T = T;
	o.dist = pre.t;
	return o;
}

// Blocky style (Storybook): the slab of 12-block cells ray-traced exactly (a 2D DDA through the cells between the slab's
// planes, flat like vanilla's), the first filled cell's face lit: wrapped sun with a self-shadow from the cells toward the
// light, sky light from above and the ground's from below, a forward rim toward the sun. Nearly opaque, crisp edges.
static CloudResult cloudBlocky(float3 dir, constant CloudParams &c, texture2d<half> weather) {
	CloudResult o;
	o.S = 0.0;
	o.T = 1.0;
	o.dist = -1.0;
	float y0 = c.layer.z, yb = c.layer.x, yt = c.layer.y;
	float maxT = min(c.march.z, 4000.0);
	float t0, t1;
	if (abs(dir.y) < 1e-5) {
		if (y0 < yb || y0 > yt) return o;
		t0 = 0.0;
		t1 = maxT;
	} else {
		float ta = (yb - y0) / dir.y, tb = (yt - y0) / dir.y;
		t0 = max(min(ta, tb), 0.0);
		t1 = min(max(ta, tb), maxT);
	}
	if (t1 <= t0) return o;
	float2 q0 = c.origin.xy + dir.xz * t0;
	float2 d = dir.xz;
	float2 cell = floor(q0 / CLOUD_BLOCK);
	float2 st = float2(d.x >= 0.0 ? 1.0 : -1.0, d.y >= 0.0 ? 1.0 : -1.0);
	float2 ad = max(abs(d), float2(1e-6));
	float2 tDelta = CLOUD_BLOCK / ad;
	float2 next = ((cell + max(st, 0.0)) * CLOUD_BLOCK - q0) / (st * ad);
	float t = t0;
	int axis = -1;
	bool hit = false;
	for (int i = 0; i < 160; i++) {
		if (cloudBlockFilled(cell, c, weather)) {
			hit = true;
			break;
		}
		if (next.x < next.y) {
			t = t0 + next.x;
			next.x += tDelta.x;
			cell.x += st.x;
			axis = 0;
		} else {
			t = t0 + next.y;
			next.y += tDelta.y;
			cell.y += st.y;
			axis = 1;
		}
		if (t >= t1) break;
	}
	if (!hit) return o;
	float3 n = axis == 0 ? float3(-st.x, 0.0, 0.0) : axis == 1 ? float3(0.0, 0.0, -st.y)
		: (t0 > 0.0 ? float3(0.0, dir.y > 0.0 ? -1.0 : 1.0, 0.0) : -dir);
	float3 L = c.lightDir.xyz;
	float3 ph = dir * t;
	float yh = y0 + dir.y * t;
	float vis = 1.0;
	for (int k = 1; k <= 3; k++) {
		float3 pk = ph + n * 0.5 + L * (float(k) * 7.0);
		float yk = yh + n.y * 0.5 + L.y * float(k) * 7.0;
		if (yk >= yb && yk <= yt && cloudBlockCell(c.origin.xy + pk.xz, c, weather)) vis *= 0.45;
	}
	float ndl = dot(n, L);
	float wrap = saturate((ndl + 0.35) / 1.35);
	float mu = dot(dir, L);
	float rim = (1.0 - abs(dot(n, dir))) * cloudHG(mu, 0.75) * 0.9;
	// sky light by the face's direction, plus light diffused through the thin slab (keeps undersides from going flat grey)
	float3 amb = mix(c.ambBottom.rgb * 1.4 + c.ambTop.rgb * 0.5, c.ambTop.rgb * 1.25, n.y * 0.5 + 0.5) + c.light.rgb * 0.035;
	float albedo = c.ambTop.w;
	o.S = albedo * (c.light.rgb * (wrap * vis * 0.3183 + rim * vis) + amb) * 0.92;
	o.T = 0.08;
	o.dist = t;
	return o;
}

// Aerial perspective (Photon's blend): the clouds' light fades toward the clear sky behind by the air between. fade (0..1)
// multiplies the air's transmittance: the clouds melt into the horizon's haze instead of ending on a line.
static inline CloudResult cloudAerial(CloudResult r, float3 sky, float fade, constant CloudParams &c) {
	if (r.dist < 0.0) return r;
	float Tair = exp(-r.dist / c.march.w) * fade * (1.0 - smoothstep(0.55 * c.march.z, c.march.z, r.dist));
	r.S = mix((1.0 - r.T) * sky, r.S, Tair);
	return r;
}

// Rays below the horizontal skim the curved world before they rise into the layer (the clouds seen there are the farthest,
// squeezed into the horizon): 1 for rays level or up, falling to 0 toward the ray that grazes the ground (misc.z), so the
// cloud deck fades into the horizon haze below it instead of stopping on a hard edge over the haze.
static inline float cloudHorizonFade(float3 dir, constant CloudParams &c) {
	float clear = c.layer.z - c.misc.z;
	if (dir.y >= 0.0 || clear <= 1.0) return 1.0;
	CloudRay r = cloudRay(dir, c);
	float k = saturate(1.0 - r.b * r.b / (4.0 * r.a * clear)); // the ray's closest approach to the ground / the camera's height
	// only for a camera below the layer: from inside or above it, rays looking down meet the clouds before the ground (the
	// fade turned the whole deck seen from above into flat sky-coloured haze)
	return mix(smoothstep(0.0, 0.9, k), 1.0, smoothstep(c.layer.x - 24.0, c.layer.x, c.layer.z));
}

// Cumulus + cirrus toward dir with aerial perspective: (S, T) and the apparent distance (-1: no cloud).
static CloudResult cloudSky(float3 dir, int steps, int lsteps, int q, float jitter, constant ShadeFrame &f, constant CloudParams &c,
                            texture2d<half> weather, texture3d<half> noise, texture2d<half> lut, sampler lutS, float foot) {
	// (M3.3 CLOUD_MODE_BATCH: the cirrus' first fetch and the sky LUT are fetched before the cumulus march and wait alongside
	// it; the march is latency-bound, a fetch more costs less than one more wait after it)
	CloudResult ci, cu;
	bool batch = cloudMode(c, CLOUD_MODE_BATCH);
	float3 skyPre = 0.0;
	if (batch) {
		CloudCirrusPre pre = cloudCirrusBegin(dir, c, weather);
		// (FT2.8, audit idx 30) the sky only for a ray that can meet a cloud (M3.1's "no lookup for the empty rays", kept in the
		// batch): a cumulus stretch (cloudSegment, ALU only), the cirrus plane, or the dev path that always takes it
		CloudRay rs = cloudRay(dir, c);
		float s0, s1;
		if (cloudStyle(c) > 0.5 || pre.t > 0.0 || cloudDev(c, CLOUD_DEV_OLD_MARCH) || cloudSegment(rs, c.layer.x, c.layer.y, c.misc.z, c.march.z, s0, s1))
			skyPre = shadeSkyLookup(dir, lut, lutS, f);
		cu = cloudStyle(c) > 0.5 ? cloudBlocky(dir, c, weather) : cloudMarch(dir, steps, lsteps, q, jitter, c, weather, noise, foot);
		ci = cloudCirrusEnd(pre, dir, c, weather);
	} else {
		cu = cloudStyle(c) > 0.5 ? cloudBlocky(dir, c, weather) : cloudMarch(dir, steps, lsteps, q, jitter, c, weather, noise, foot);
		ci = cloudCirrus(dir, c, weather);
	}
	// the clear sky behind only matters where a cloud is (aerial perspective; M3.1: no lookup for the empty rays)
	if (cu.dist >= 0.0 || ci.dist >= 0.0 || cloudDev(c, CLOUD_DEV_OLD_MARCH)) {
		float3 sky = batch ? skyPre : shadeSkyLookup(dir, lut, lutS, f);
		float hf = cloudHorizonFade(dir, c);
		cu = cloudAerial(cu, sky, hf, c);
		ci = cloudAerial(ci, sky, hf, c);
	}
	CloudResult o;
	o.S = cu.S + cu.T * ci.S; // the cirrus is always behind (far above) the cumulus
	o.T = cu.T * ci.T;
	o.dist = cu.dist >= 0.0 ? cu.dist : ci.dist;
	float fade = c.look.w;
	o.S *= fade;
	o.T = mix(1.0, o.T, fade);
	return o;
}

static inline float3 cloudDirection(float2 uv, constant CloudParams &c) {
	return normalize(shadeViewRay(uv * 2.0 - 1.0, c.invViewProj)); // from the eye: view bobbing moves it (shade_common.metal)
}

// ---- passes --------------------------------------------------------------------------------------------------------------
struct CloudVsOut { float4 position [[position]]; };

vertex CloudVsOut cloud_vs(uint vid [[vertex_id]]) {
	CloudVsOut o;
	o.position = float4(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0, 0.0, 1.0);
	return o;
}

struct CloudMarchOut {
	half4 color [[color(0)]]; // rgb scattered light (before exposure), a transmittance
	float dist [[color(1)]];  // apparent distance (blocks; the slab's mid distance where the ray holds no cloud)
};

fragment CloudMarchOut cloud_march(CloudVsOut in [[stage_in]], constant ShadeFrame &f [[buffer(16)]], constant CloudParams &c [[buffer(0)]],
                                   texture2d<half> weather [[texture(0)]], texture3d<half> noise [[texture(1)]],
                                   texture2d<half> lut [[texture(17)]], sampler lutS [[sampler(13)]]) {
	// the history pixel this march pixel stands for this frame (N x N checkerboard, N = windDir.z)
	float n = c.windDir.z;
	float2 hp = min(floor(in.position.xy) * n + c.frame.xy, c.size.xy - 1.0);
	float2 uv = (hp + 0.5) / c.size.xy;
	float3 dir = cloudDirection(uv, c);
	// a history pixel is marched every N^2 frames: its start offsets step by the golden ratio per visit (stepping per frame
	// made N^2 x 0.618 = 0.56 per visit with N = 3, nearly periodic: a biased mean that showed the checkerboard as a grid)
	float visit = floor(c.misc.x / (n * n));
	// M3.3 (CLOUD_MODE_STABLE): the per-pixel offset from a hash instead of interleaved gradient noise. IGN is linear in the
	// pixel (mod 1): a cloud the wind carries across the pixels met offsets that stepped by a near-constant amount per visit,
	// which could cancel the golden-ratio step (e.g. one 3-pixel block in -x per 9 frames: -0.665 + 0.618 = -0.047), so it was
	// marched at almost the same depth phase visit after visit and its step aliasing never averaged out: the comb / hatching
	// on soft edges in the wind and while turning (CLOUDS.md M3.3). A hash has no such structure; still pixels keep their
	// golden-ratio sequence
	float seed = cloudMode(c, CLOUD_MODE_STABLE) ? shadeHash01(shadeHash3(int3(int2(hp), 0), 0x2c1b3c6du)) : shadeNoise(hp, 0);
	float jitter = fract(seed + visit * 0.6180339887);
	CloudResult r = cloudSky(dir, int(c.march.x), int(c.march.y), 2, jitter, f, c, weather, noise, lut, lutS, c.windDir.w);
	CloudMarchOut o;
	o.color = half4(half3(min(r.S, 60000.0)), half(r.T));
	float dist = r.dist;
	if (dist < 0.0) {
		// no cloud: reproject by the slab's distance in that direction (clouds that appear there move like that)
		CloudRay ray = cloudRay(dir, c);
		float t0, t1;
		dist = cloudSegment(ray, c.layer.x, c.layer.y, c.misc.z, c.march.z, t0, t1) ? 0.5 * (t0 + t1) : c.march.z;
	}
	o.dist = dist;
	return o;
}

// 5-tap Catmull-Rom of the history (rgb and transmittance): the wind moves the clouds a fraction of a pixel every frame, and
// bilinear reprojection would blur the history a little more each frame.
static inline half4 cloudCatmullRom(texture2d<half> tex, float2 uv, float2 size) {
	float2 pos = uv * size;
	float2 t1 = floor(pos - 0.5) + 0.5;
	float2 f = pos - t1;
	float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
	float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
	float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
	float2 w3 = f * f * (-0.5 + 0.5 * f);
	float2 w12 = w1 + w2;
	float2 inv = 1.0 / size;
	float2 t0 = (t1 - 1.0) * inv, t3 = (t1 + 2.0) * inv, t12 = (t1 + w2 / w12) * inv;
	float4 c = float4(tex.sample(cloudClamp, float2(t12.x, t0.y))) * (w12.x * w0.y)
		+ float4(tex.sample(cloudClamp, float2(t0.x, t12.y))) * (w0.x * w12.y)
		+ float4(tex.sample(cloudClamp, t12)) * (w12.x * w12.y)
		+ float4(tex.sample(cloudClamp, float2(t3.x, t12.y))) * (w3.x * w12.y)
		+ float4(tex.sample(cloudClamp, float2(t12.x, t3.y))) * (w12.x * w3.y);
	float wsum = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
	c /= wsum;
	return half4(half3(max(c.rgb, 0.0)), half(saturate(c.a)));
}

struct CloudResolveOut {
	half4 color [[color(0)]]; // rgb scattered light (before exposure), a transmittance
	half age [[color(1)]];    // R8Unorm: frames this pixel was marched and blended / 64
};

// The history pixel's new value: this frame's march where it is this frame's checkerboard slot (blended into the
// reprojected history: 1 / age, capped), else the reprojected history (Photon's checkerboard upscaling, our weights), or the
// march upsampled where nothing reprojects (a turn uncovering the screen edge, first frames).
fragment CloudResolveOut cloud_resolve(CloudVsOut in [[stage_in]], constant CloudParams &c [[buffer(0)]],
                                       texture2d<half> cur [[texture(0)]], texture2d<float> curDist [[texture(1)]],
                                       texture2d<half> hist [[texture(2)]], texture2d<half> histAge [[texture(3)]]) {
	uint n = uint(c.windDir.z);
	uint2 px = uint2(in.position.xy);
	uint2 slot = uint2(c.frame.xy);
	uint2 mp = min(px / n, uint2(c.size.zw) - 1u);
	bool mine = all(px % n == slot);
	float2 uv = (float2(px) + 0.5) / c.size.xy;
	float3 dir = cloudDirection(uv, c);
	half4 now = cur.read(mp);
	// M3.1: the march distances around mp by two gathers (texel corners: (x-1..x, y-1..y) and (x..x+1, y..y+1); each returns
	// (x0,y1) (x1,y1) (x1,y0) (x0,y0)) instead of five reads; clamp_to_edge = M3's clamped neighbours
	bool oldTaps = cloudDev(c, CLOUD_DEV_OLD_RESOLVE);
	constexpr sampler gatherS(filter::nearest, address::clamp_to_edge);
	float2 msz = c.size.zw;
	float4 g0 = oldTaps ? float4(0.0) : curDist.gather(gatherS, float2(mp) / msz);
	float dNow = oldTaps ? curDist.read(mp).r : g0.y;
	// reproject: where this direction's cloud (at the current march's distance) was last frame. The density is read at
	// origin + p with origin = camera + the accumulated wind, so a cloud drifts by -wind each frame: last frame it was at
	// p + wind (the sign matters: the other way round the history smeared 2 x wind per frame, blurring and patterning the
	// clouds)
	// (from the eye, where the march's rays start: view bobbing moves it up to 0.1 block, a pixel or two at the clouds' distance,
	// and taken from the camera's origin the history trailed the bob: the clouds swam with the camera while walking, Gael
	// 2026-10-09)
	float3 wp = shadeEye(c.invViewProj) + dir * dNow + float3(c.wind.x, 0.0, c.wind.y);
	float4 pc = c.prevViewProj * float4(wp, 1.0);
	float2 puv = pc.xy / max(pc.w, 1e-6) * 0.5 + 0.5;
	bool valid = c.frame.z < 0.5 && pc.w > 1e-4 && all(puv >= 0.0) && all(puv <= 1.0);
	half4 h = half4(0.0h, 0.0h, 0.0h, 1.0h);
	float age = 0.0;
	if (valid) {
		h = cloudCatmullRom(hist, puv, c.size.xy);
		age = float(histAge.sample(cloudClamp, puv).r) * 64.0;
		// the block's one march distance reprojects all N x N of its pixels: where the distances jump (a near cloud's edge
		// against far sky or cloud: wind and camera parallax differ there) the history can come from the wrong surface, so
		// keep it inside the range of this frame's march around it (fringes of stray pixels on near clouds otherwise)
		int2 mi = int2(mp), ms = int2(c.size.zw) - 1;
		int2 ax = int2(min(mi.x + 1, ms.x), mi.y), bx = int2(max(mi.x - 1, 0), mi.y);
		int2 ay = int2(mi.x, min(mi.y + 1, ms.y)), by = int2(mi.x, max(mi.y - 1, 0));
		float d1, d2, d3, d4;
		if (oldTaps) {
			d1 = curDist.read(uint2(ax)).r, d2 = curDist.read(uint2(bx)).r, d3 = curDist.read(uint2(ay)).r, d4 = curDist.read(uint2(by)).r;
		} else {
			float4 g1 = curDist.gather(gatherS, (float2(mp) + 1.0) / msz);
			d1 = g1.z; // (x+1, y)
			d2 = g0.x; // (x-1, y)
			d3 = g1.x; // (x, y+1)
			d4 = g0.z; // (x, y-1)
		}
		float dMin = min(min(min(d1, d2), min(d3, d4)), dNow), dMax = max(max(max(d1, d2), max(d3, d4)), dNow);
		if (dMax > dMin * 1.3 + 4.0) {
			half4 c1 = cur.read(uint2(ax)), c2 = cur.read(uint2(bx)), c3 = cur.read(uint2(ay)), c4 = cur.read(uint2(by));
			half4 lo = min(min(min(c1, c2), min(c3, c4)), now), hi = max(max(max(c1, c2), max(c3, c4)), now);
			half4 pad = (hi - lo) * 0.15h;
			h = clamp(h, lo - pad, hi + pad);
		}
	}
	CloudResolveOut o;
	if (mine) {
		float w = valid ? 1.0 / min(age + 1.0, c.frame.w) : 1.0;
		o.color = valid ? mix(h, now, half(w)) : now;
		o.age = half(min(age + 1.0, c.frame.w) / 64.0);
	} else if (valid && age > 0.5) {
		o.color = h;
		o.age = half(age / 64.0);
	} else {
		float2 mpos = (float2(px) + 0.5 - float2(slot) - 0.5) / float(n) + 0.5;
		o.color = cur.sample(cloudClamp, mpos / c.size.zw);
		o.age = 0.0h;
	}
	// (1.1.1) never keep Inf or NaN in the history (shadeBad: fast math may drop isfinite): clear sky instead
	if (shadeBad(o.color)) o.color = half4(0.0h, 0.0h, 0.0h, 1.0h);
	return o;
}

// ---- M3.3: the resolve that carries the clouds' distance (CLOUD_MODE_STABLE) ----------------------------------------------
// Data target R16Uint per history pixel: bits 12-15 age (frames blended, 0..15), bits 0-11 the distance of the clouds the
// pixel holds as log2(blocks) x 256 (0.27 % steps up to 65536 blocks; 4095 = holds no cloud).
#define CLOUD_DIST_NONE 4095u
static inline uint cloudDistCode(float d) { return uint(clamp(log2(max(d, 1.0)) * 256.0 + 0.5, 0.0, 4094.0)); }
static inline float cloudDistDecode(uint q) { return exp2(float(q) * (1.0 / 256.0)); }

struct CloudResolveStOut {
	half4 color [[color(0)]]; // rgb scattered light (before exposure), a transmittance
	ushort data [[color(1)]]; // R16Uint: age << 12 | distance code
};

// cloud_resolve with the history's own distance (CLOUD_MODE_STABLE, M3.3). M3.2 reprojected every pixel of a march block by
// that block's one march distance, which jumps between visits wherever a soft cloud lets some rays through (the slab's entry
// for a clear ray, the cloud's depth for a hit): in the wind the history slid at a different speed each frame, block by block
// (combs along soft edges, a band where the jumps were large). Here each pixel carries the distance of what it shows,
// averaged over its visits (1/distance, the parallax, blended like the colour), reprojects with the nearest cloud distance of
// its 2x2 neighbourhood (the edge of a cloud moves with that cloud; as Photon's closest-distance reprojection), and a clear
// sample does not move the distance of a pixel that still holds cloud.
fragment CloudResolveStOut cloud_resolve_st(CloudVsOut in [[stage_in]], constant CloudParams &c [[buffer(0)]],
                                            texture2d<half> cur [[texture(0)]], texture2d<float> curDist [[texture(1)]],
                                            texture2d<half> hist [[texture(2)]], texture2d<ushort> histData [[texture(3)]]) {
	uint n = uint(c.windDir.z);
	uint2 px = uint2(in.position.xy);
	uint2 slot = uint2(c.frame.xy);
	uint2 mp = min(px / n, uint2(c.size.zw) - 1u);
	bool mine = all(px % n == slot);
	float2 uv = (float2(px) + 0.5) / c.size.xy;
	float3 dir = cloudDirection(uv, c);
	half4 now = cur.read(mp);
	constexpr sampler gatherS(filter::nearest, address::clamp_to_edge);
	float2 msz = c.size.zw;
	float4 g0 = curDist.gather(gatherS, float2(mp) / msz);
	// the nearest cloud distance the history holds in this pixel's 2x2 neighbourhood, read where the pixel is (not where it
	// came from, so this fetch waits alongside the march's: a turn does not depend on the distance, and the wind moves the
	// clouds less than a pixel per frame)
	uint4 qu = uint4(histData.gather(gatherS, uv)) & 0xfffu;
	uint qMin = min(min(qu.x, qu.y), min(qu.z, qu.w));
	float dNow = max(g0.y, 1.0);
	float3 wnd = float3(c.wind.x, 0.0, c.wind.y);
	float dRep = qMin != CLOUD_DIST_NONE ? cloudDistDecode(qMin) : dNow;
	// (the point from the eye, where the march's rays start: see cloud_resolve)
	float4 pc = c.prevViewProj * float4(shadeEye(c.invViewProj) + dir * dRep + wnd, 1.0);
	float2 puv = pc.xy / max(pc.w, 1e-6) * 0.5 + 0.5;
	bool valid = c.frame.z < 0.5 && pc.w > 1e-4 && all(puv >= 0.0) && all(puv <= 1.0);
	half4 h = half4(0.0h, 0.0h, 0.0h, 1.0h);
	float age = 0.0, dOwn = dNow;
	uint qOwn = CLOUD_DIST_NONE;
	bool ownCloud = false;
	// FT2.6 (CLOUD_MODE_DRIFT): how far the reprojection moves this pixel's history against a pure turn of the camera (history
	// pixels): the camera's travel and the wind, seen at the clouds' distance. Inside a cloud or next to one that distance is a
	// few blocks and the history slides by pixels every frame, while the fog's glow toward the sun hangs on the direction
	// alone: the reprojected glow slid away with every step and gust, and the 1/age blend (one visit per N^2 frames, age up to
	// 10) kept it for about a second: a comet tail from the sun (Gael's FT2.5 screenshots 8 and 9, flying in a cloud). Where
	// it drifts the history is kept inside this frame's march colours around and its age capped low (far clouds: no drift)
	float drift = 0.0;
	if (valid && cloudMode(c, CLOUD_MODE_DRIFT)) {
		float4 pd = c.prevViewProj * float4(dir, 0.0);
		float2 sep = (puv - (pd.xy / max(pd.w, 1e-6) * 0.5 + 0.5)) * c.size.xy;
		// (FT2.6.1, audit idx 7: only where the distance reprojection cannot follow the light: content near the camera, inside or next
		// to a cloud, or in the sun's glow cone. Far and overhead clouds move with the wind and the camera exactly as it models them; on
		// them the clamp to the 1/3-resolution march brought back grainy 3x3-block edges on windy days)
		float nearW = 1.0 - smoothstep(32.0, 128.0, dRep);
		float glowW = smoothstep(0.85, 0.97, dot(dir, c.lightDir.xyz));
		drift = smoothstep(0.5, 1.5, length(sep)) * max(nearW, glowW);
	}
	if (valid) {
		// age and own distance where the pixel came from: (x0,y1) (x1,y1) (x1,y0) (x0,y0)
		uint4 q = uint4(histData.gather(gatherS, puv));
		float2 f = fract(puv * c.size.xy - 0.5);
		float4 ages = float4(q >> 12u);
		age = mix(mix(ages.w, ages.z, f.x), mix(ages.x, ages.y, f.x), f.y);
		if (cloudMode(c, CLOUD_MODE_ZOOM)) {
			// zoom (spyglass x0.1, FOV effects): how many old history pixels one new pixel spans. Below 1 the history is a
			// magnified copy of coarser content and counts as fewer visits (the factor multiplies frame after frame: the drop
			// follows the total zoom, not the frame rate). Zooming out and plain turns (s ~ 1) change nothing
			float3 dirR = cloudDirection(uv + float2(1.0 / c.size.x, 0.0), c);
			float4 a0 = c.prevViewProj * float4(dir, 0.0), a1 = c.prevViewProj * float4(dirR, 0.0);
			float sz = a0.w > 1e-4 && a1.w > 1e-4 ? length((a1.xy / a1.w - a0.xy / a0.w) * 0.5 * c.size.xy) : 1.0;
			age *= min(1.0, sz * sz);
		}
		uint4 qd = q & 0xfffu;
		qOwn = f.y < 0.5 ? (f.x < 0.5 ? qd.w : qd.z) : (f.x < 0.5 ? qd.x : qd.y);
		ownCloud = qOwn != CLOUD_DIST_NONE;
		if (ownCloud) dOwn = cloudDistDecode(qOwn);
		h = cloudCatmullRom(hist, puv, c.size.xy);
		// (as cloud_resolve) where this frame's march distances jump, keep the history inside their colour range
		int2 mi = int2(mp), ms = int2(c.size.zw) - 1;
		int2 ax = int2(min(mi.x + 1, ms.x), mi.y), bx = int2(max(mi.x - 1, 0), mi.y);
		int2 ay = int2(mi.x, min(mi.y + 1, ms.y)), by = int2(mi.x, max(mi.y - 1, 0));
		float4 g1 = curDist.gather(gatherS, (float2(mp) + 1.0) / msz);
		float d1 = g1.z, d2 = g0.x, d3 = g1.x, d4 = g0.z;
		float dMin = min(min(min(d1, d2), min(d3, d4)), g0.y), dMax = max(max(max(d1, d2), max(d3, d4)), g0.y);
		bool jump = dMax > dMin * 1.3 + 4.0;
		if (jump && cloudMode(c, CLOUD_MODE_EDGE)) {
			// FT1.2: only where it matters, i.e. where the history would come from apart with the nearest vs the farthest
			// distance around (camera motion, wind parallax: a near cloud over a far one). The box below is one per 3x3 block of
			// the 1/3-resolution march: on every soft edge against the sky it cut the edge into block steps and specks. pc =
			// dRep A + B with A = prevViewProj (dir, 0), so the reprojection with distance d is d A + B
			float4 A = c.prevViewProj * float4(dir, 0.0), B = pc - dRep * A;
			float4 pa = dMin * A + B, pb = dMax * A + B;
			float2 sep = (pa.xy / max(pa.w, 1e-6) - pb.xy / max(pb.w, 1e-6)) * 0.5 * c.size.xy;
			jump = dot(sep, sep) > 0.25; // half a history pixel
		}
		if (jump || drift > 0.0) {
			half4 c1 = cur.read(uint2(ax)), c2 = cur.read(uint2(bx)), c3 = cur.read(uint2(ay)), c4 = cur.read(uint2(by));
			half4 lo = min(min(min(c1, c2), min(c3, c4)), now), hi = max(max(max(c1, c2), max(c3, c4)), now);
			half4 pad = (hi - lo) * 0.15h;
			h = jump ? clamp(h, lo - pad, hi + pad) : mix(h, clamp(h, lo - pad, hi + pad), half(drift));
		}
		// (a cap on the age, not a cut that compounds every frame)
		age = min(age, mix(min(c.frame.w, 15.0), 1.0, drift));
	}
	const half clear = 0.995h; // transmittance above this: no cloud
	bool histCloud = valid && age > 0.5 && ownCloud && h.a < clear;
	CloudResolveStOut o;
	uint ageOut, qOut;
	float cap = mix(min(c.frame.w, 15.0), 2.0, drift);
	if (mine) {
		float w = valid ? 1.0 / min(age + 1.0, cap) : 1.0;
		o.color = valid ? mix(h, now, half(w)) : now;
		ageOut = uint(min(age + 1.0, cap) + 0.5);
		bool nowCloud = now.a < clear;
		qOut = nowCloud ? cloudDistCode(histCloud ? 1.0 / mix(1.0 / dOwn, 1.0 / dNow, w) : dNow) : histCloud ? qOwn : CLOUD_DIST_NONE;
	} else if (valid && age > 0.5) {
		o.color = h;
		// a pixel the camera uncovered lately holds the mean of few of its own samples (noisy, at 1/9 rate): until its third
		// visit it also leans toward this frame's march around it (spatially averaged), so a turn's new sky settles faster
		if (age < 2.5) {
			float2 mpos = (float2(px) + 0.5 - float2(slot) - 0.5) / float(n) + 0.5;
			o.color = mix(h, cur.sample(cloudClamp, mpos / c.size.zw), half(0.5 / (age + 1.0)));
		}
		ageOut = uint(age + 0.5);
		qOut = histCloud ? qOwn : CLOUD_DIST_NONE;
	} else {
		float2 mpos = (float2(px) + 0.5 - float2(slot) - 0.5) / float(n) + 0.5;
		o.color = cur.sample(cloudClamp, mpos / c.size.zw);
		ageOut = 0u;
		qOut = o.color.a < clear ? cloudDistCode(dNow) : CLOUD_DIST_NONE;
	}
	// (1.1.1) never keep Inf or NaN in the history (shadeBad: fast math may drop isfinite): clear sky instead
	if (shadeBad(o.color)) {
		o.color = half4(0.0h, 0.0h, 0.0h, 1.0h);
		qOut = CLOUD_DIST_NONE;
	}
	o.data = ushort(min(ageOut, 15u) << 12u | qOut);
	return o;
}

// Clouds in front of the world (the camera up at or above the cloud layer: flying, mountain tops): composited over the
// HDR scene before the tone map where the terrain lies behind the clouds' apparent distance (the sky pass already put
// them behind everything else). Blend: One, OneMinusSourceAlpha (scene x T + light x exposure).
fragment half4 cloud_over(CloudVsOut in [[stage_in]], constant ShadeFrame &f [[buffer(16)]], constant ShadeLook &L [[buffer(17)]],
                          constant ShadeGpu &g [[buffer(18)]], depth2d<float> depth [[texture(0)]], texture2d<float> cdist [[texture(1)]],
                          texture2d<half> hist [[texture(2)]], texture2d<ushort> hdata [[texture(3)]], constant uint &mode [[buffer(0)]]) {
	float d = depth.read(uint2(in.position.xy));
	// mode bit 1 (Distant Horizons drew this frame): its LODs are not in the world depth, so an empty pixel below the horizon is
	// taken as far terrain behind the clouds (true sky there gets the clouds a second time: rare with the LODs to the horizon)
	if (d <= 0.0 && (mode & 1u) == 0u) discard_fragment();
	// (FT2.7, audit idx 9) ...but only from inside or above the layer: from under its base the clouds below the horizon are the
	// curved world's far deck, which shadeFogAir2 already puts BEHIND the LODs (wc = smoothstep(0, 24, base - camY)); here its
	// complement, so they are never drawn twice (a hazy band of far clouds over the LOD mountains under the horizon, popping in
	// at camY = base - 48)
	float kEmpty = d > 0.0 ? 1.0 : 1.0 - smoothstep(0.0, 24.0, L.clouds0.x);
	if (kEmpty <= 0.001) discard_fragment();
	float2 ndc = in.position.xy * f.screen.zw * 2.0 - 1.0;
	float4 w = f.invViewProj * float4(ndc, d > 0.0 ? d : 0.5, 1.0);
	float3 p = w.xyz / w.w - shadeEye(f.invViewProj); // from the eye (view bobbing moves it): the ray cloudDirection holds
	float dist = length(p);
	float3 dir = p / max(dist, 1e-4);
	if (d <= 0.0) {
		if (dir.y >= 0.0) discard_fragment();
		dist = 1e9;
	}
	float4 cp = L.viewProjNoJitter * float4(dir, 0.0);
	if (cp.w <= 1e-6) discard_fragment();
	float2 uv = cp.xy / cp.w * 0.5 + 0.5;
	float cd;
	if ((mode & 2u) != 0u) {
		// (1.2.3, issue #4) mode bit 2 (the history came from cloud_resolve_st): the distance the history carries with its colour,
		// over the 2x2 texels the colour below is filtered from, the clear ones (CLOUD_DIST_NONE) left out. The march's distances
		// are this frame's 1/N-resolution slots, and a clear ray's is the slab's middle (from inside the layer looking down: a few
		// dozen blocks): along a cloud's soft edge their mix came out in front of the nearer terrain, so from high up the edges
		// of the clouds far behind a ridge were drawn over it
		constexpr sampler gatherS(filter::nearest, address::clamp_to_edge);
		uint4 q = uint4(hdata.gather(gatherS, uv)) & 0xfffu;
		float2 fh = fract(uv * float2(hdata.get_width(), hdata.get_height()) - 0.5);
		// (x0,y1) (x1,y1) (x1,y0) (x0,y0), the bilinear weights
		float4 wq = float4((1.0 - fh.x) * fh.y, fh.x * fh.y, fh.x * (1.0 - fh.y), (1.0 - fh.x) * (1.0 - fh.y));
		wq = select(float4(0.0), wq, q != CLOUD_DIST_NONE);
		float wsum = wq.x + wq.y + wq.z + wq.w;
		if (wsum <= 1e-4) discard_fragment(); // no cloud the history knows of here
		cd = dot(wq, exp2(float4(q) * (1.0 / 256.0))) / wsum; // (cloudDistDecode)
	} else {
		// the march's distances (1/N of the history): bilinear by hand (R32F), the nearest texel drew stair steps along the
		// clouds' edges in front of the world
		float2 dsz = float2(cdist.get_width(), cdist.get_height());
		float2 dp = clamp(uv * dsz - 0.5, float2(0.0), dsz - 1.0);
		uint2 d0 = uint2(dp), d1 = min(d0 + 1u, uint2(dsz) - 1u);
		float2 fw = dp - float2(d0);
		cd = mix(mix(cdist.read(d0).r, cdist.read(uint2(d1.x, d0.y)).r, fw.x), mix(cdist.read(uint2(d0.x, d1.y)).r, cdist.read(d1).r, fw.x), fw.y);
	}
	float k = smoothstep(cd * 0.8, cd * 1.05, dist) * kEmpty;
	if (k <= 0.001) discard_fragment();
	half4 cl = hist.sample(cloudClamp, uv);
	float T = mix(1.0, float(cl.a), k);
	return half4(half3(min(float3(cl.rgb) * k * g.exposure.x, 60000.0)), half(1.0 - T));
}

// The reflection dome: texel (u, v) <-> azimuth u * 2 pi (atan2(z, x)), height dir.y = v^2 (dense near the horizon).
static inline float3 cloudDomeDirection(float2 uv) {
	float az = uv.x * 6.2831853, y = uv.y * uv.y, c = sqrt(max(1.0 - y * y, 0.0));
	return float3(cos(az) * c, y, sin(az) * c);
}

fragment half4 cloud_dome(CloudVsOut in [[stage_in]], constant ShadeFrame &f [[buffer(16)]], constant CloudParams &c [[buffer(0)]],
                          texture2d<half> weather [[texture(0)]], texture3d<half> noise [[texture(1)]], texture2d<half> prev [[texture(2)]],
                          texture2d<half> lut [[texture(17)]], sampler lutS [[sampler(13)]]) {
	float2 uv = in.position.xy / float2(prev.get_width(), prev.get_height());
	float3 dir = cloudDomeDirection(uv);
	// a golden-ratio step per update (FT2.8, audit idx 28: by the dome's own update count; floor(frame / 4) assumed an update
	// every 4th frame, and at performance/balanced it runs every 8th: steps of 0.236, a slow ramp over ~4 updates that the
	// 0.4 blend averaged into a sweeping bias, slowly crawling bands on reflected clouds)
	float jitter = fract(shadeNoise(in.position.xy, 0) + c.dome.x * 0.6180339887);
	// one texel's angle: the geometric mean of its azimuth (2 pi / width) and elevation (pi/2 / height) spans
	float2 dsz = float2(prev.get_width(), prev.get_height());
	float foot = sqrt((6.2831853 / dsz.x) * (1.5707963 / dsz.y));
	CloudResult r = cloudSky(dir, int(c.dome.w), 2, 1, jitter, f, c, weather, noise, lut, lutS, foot);
	half4 now = half4(half3(min(r.S, 60000.0)), half(r.T));
	if (c.frame.z > 0.5) return now;
	return mix(prev.read(uint2(in.position.xy)), now, half(c.dome.z));
}

// Transmittance of the cumulus toward the light, on the plane y = shadow.y: texel -> the plane point, then a few samples
// along the light direction through the slab (2D shape + billows).
fragment half cloud_shadow(CloudVsOut in [[stage_in]], constant CloudParams &c [[buffer(0)]], texture2d<half> weather [[texture(0)]],
                           texture3d<half> noise [[texture(1)]]) {
	float2 uv = in.position.xy / 256.0;
	float2 rel = c.shadow.zw + (uv - 0.5) * c.shadow.x;
	float3 L = c.shadowDir.xyz;
	float ly = L.y;
	float yRef = c.shadow.y;
	float sa = (c.layer.x - yRef) / ly, sb = (c.layer.y - yRef) / ly;
	// (FT2.7, audit idx 13) the slices sized from the light's path through the slab (150 / ly blocks: 214 at 44 degrees, 833 at 10):
	// 6 fixed ones sat ~140 blocks apart at a low sun, half a cumulus cell, and each one's optical depth is near binary, so the
	// shadows on the land (and the VL's shafts through cloud gaps) were stacks of offset copies in steps along the sun's azimuth.
	// ~36-block steps, 6 from ~45 degrees up (midday as before), at most 24; on 1 frame in 4 (~+0.03 ms per frame at sunset)
	int N = cloudDev(c, CLOUD_DEV_OLD_SHADOW) ? 6 : clamp(int(ceil((sb - sa) / 36.0)), 6, 24);
	float ds = (sb - sa) / float(N);
	float tau = 0.0;
	float3 base = float3(rel.x, yRef - c.layer.z, rel.y);
	for (int i = 0; i < N; i++) {
		float s = sa + (float(i) + 0.5) * ds;
		float3 p = base + float3(L.x, ly, L.z) * s;
		tau += cloudDensity(p, yRef + ly * s, 1, c, weather, noise, 1.0, cloudDev(c, CLOUD_DEV_OLD_MIP) ? 1.1 : 0.0) * ds; // (level 0 both ways)
	}
	return half(exp(-tau * c.shape.z * 0.8));
}

#endif
