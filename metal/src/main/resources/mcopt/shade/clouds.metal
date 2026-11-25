// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// Portions adapted from Photon Shaders by Benjamin Stott ("sixthsurge"), MIT License, commit 26c2906e
// (include/sky/clouds/common.glsl, cumulus.glsl, cirrus.glsl, altocumulus.glsl; program/d2_clouds_upscaling.fsh): the cumulus altitude
// shaping (flat bases, egg-shaped tops), the "powder" brightening of dense cores, the cloud phase function as a mix of a
// strong forward lobe and a backward one, the octave loop of the multiple-scattering approximation, the aerial perspective
// blend toward the clear sky by the clouds' apparent distance, the checkerboard + reprojected-history upscaling, and (2026-11)
// the altocumulus layer's density and short march (cloudAlto*, see there).
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

// Per-frame parameters (mcopt.metal.shade.clouds.CloudParams packs exactly this layout: 2 matrices + 25 float4 = 528 bytes).
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
	float4 art2;           // 448 (2026-11, toward Photon's look) x the cumulus cells' scale (the weather map's frequency: 1 = M3's ~250-block
	                       //     cells, more = smaller, more numerous clouds with sky between; origin.xy wraps to match), y the billows'
	                       //     scale (the 3D noise's frequency, 1 = its 120-block tile; origin.zw wraps to match), z the edges'
	                       //     sharpening (x the exponent that hardens the density toward the tops; 1 = M3), w Photon's octaves (the
	                       //     multiple scattering's octaves grown by the density's powder term: bright dense cores, darker thin
	                       //     skins between the lobes; 0 = M3's, 1 = Photon's, blended)
	float4 alto;           // 464 (2026-11) the altocumulus layer (after Photon's, MIT snapshot 26c2906e): x amount (0 = none), y its base
	                       //     (absolute y), z thickness (blocks), w extinction per block at density 1
	float4 art3;           // 480 (2026-11) x, y the distance (blocks) over which the far cumulus go back to M3's edges and extinction
	                       //     (art2.z, sigmaScale: crisp, dense small cells sliced into stripes along the long grazing steps toward
	                       //     the horizon), z 1 / sigmaScale (the extinction there), w (round 2) the longest primary step (blocks;
	                       //     0 = 48, M3): the crisp small cells' mid-distance stripes come from coarser steps than they are
	float4 alto2;          // 496 (2026-11 round 2) the altocumulus' look: x the puffs' frequency (x 1/4096 of the weather map, a whole
	                       //     number of quarters: 4 = ~64-block cells), y softness (x the edges' exponent and the erosion; 1 = Photon's
	                       //     hard edges), z rows (0 = evenly sprinkled, 1 = the puffs gathered in bands across the wind, a mackerel
	                       //     sky), w the coverage at a field's heart
	float4 hz;             // 512 (round 2) the cloud deck at the horizon: x how much of the aerial perspective toward the sky behind grows
	                       //     over the last degrees above the horizon (0 = M3: the lit deck ends on a hard line over the bare horizon
	                       //     sky at dusk), y the ray height (dir.y) where that ramp starts, z (round 4) the far light samples' weather
	                       //     mip (cloudLightDepthB: the light march's third and fourth samples and the sky-light sample above read the
	                       //     cloud's shape blurred over 2^z texels; 0 = the sharp map, M3), w their density's factor with z > 0
	float4 look2;          // 528 (1.2.9 look pass, Look2 clouds; (1, 0, 0, 1) = 1.2.8) the fine detail: x its frequency (x 1/60 blocks), y the
	                       //     curl-like warp of its sample position (blocks; 0 = none), z that warp's frequency (radians per block), w the
	                       //     detail's mip offset over the billows' (1 = M3: one mip blurrier)
};
static_assert(sizeof(CloudParams) == 544, "CloudParams layout (CloudParams.java)");

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
// (round 4) the weather map's mips (mcclouds.m bakes them): the far light samples' blurred shape (cloudLightDepthB)
constexpr sampler cloudRepMipL(filter::linear, mip_filter::linear, address::repeat);

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
static inline float cloudSpreadDist(float distXZ, constant CloudParams &c) {
	return c.dome.y > 0.0 ? c.dome.y * smoothstep(400.0, 1500.0, distXZ) : 0.0;
}
static inline float cloudSpread(float2 rel, constant CloudParams &c) {
	return cloudSpreadDist(length(rel), c);
}
// The height in the layer measured from this point's own cloud base (spread: cloudSpread).
static inline float cloudBaseH(float h, half4 w, float spread) {
	float off = spread * float(w.a);
	return off > 0.0 ? (h - off) / (1.0 - off) : h;
}

// (2026-11, art3) 0 near .. 1 far: the far cumulus' share of M3's edges and extinction. dist: the point's distance (blocks).
static inline float cloudFarK(float dist, constant CloudParams &c) {
	return smoothstep(c.art3.x, c.art3.y, dist);
}

// (1.2.9 look pass, Look2 clouds) The fine detail's sample position in the 3D noise (n3: noise space, blocks), at look2.x times its
// frequency and swirled by a smooth curl-like warp (three crossed sines of ~look2.z radians per block, look2.y blocks: no texture
// fetch, so no latency in the batched march): the edges erode into wisps and curls instead of the same round pits everywhere (the
// look of Photon's curl-warped Worley erosion, our own field). (1, 0, -, 1) = M3's position.
static inline float3 cloudDetailPos(float3 n3, constant CloudParams &c) {
	float3 p = n3;
	if (c.look2.y > 0.0) {
		float3 q = n3 * c.look2.z;
		p += c.look2.y * sin(float3(q.y * 1.31 + q.z * 0.73, q.z * 1.17 - q.x * 0.81, q.x * 1.23 + q.y * 0.67) + float3(0.0, 2.1, 4.2));
	}
	return p * (CLOUD_DETAIL_SCALE * c.art2.y * c.look2.x);
}

// lod: mip level of the 3D noise (log2 of the sample's footprint in billow texels): far samples read blurred noise
// instead of aliasing it into grain.
static float cloudDensity(float3 p, float y, int q, constant CloudParams &c, texture2d<half> weather, texture3d<half> noise,
                          float detail = 1.0, float lod = 0.0) {
	if (cloudStyle(c) > 0.5) return y >= c.layer.x && y <= c.layer.y && cloudBlockCell(c.origin.xy + p.xz, c, weather) ? 1.0 : 0.0;
	float h = (y - c.layer.x) / (c.layer.y - c.layer.x);
	if (h <= 0.0 || h >= 1.0) return 0.0;
	float2 xz = c.origin.xy + p.xz;
	half4 w = weather.sample(cloudRep, (xz - c.shear.xy * h) * (c.art2.x / CLOUD_WEATHER_TILE), level(0.0));
	float distXZ = length(p.xz);
	float spread = cloudSpreadDist(distXZ, c);
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
	half4 n = cloudDev(c, CLOUD_DEV_OLD_MIP) ? noise.sample(cloudRep, n3 * (CLOUD_NOISE_SCALE * c.art2.y), level(lod))
		: noise.sample(cloudRepMip, n3 * (CLOUD_NOISE_SCALE * c.art2.y), level(lod));
	// billows (after Photon's detail erosion): Worley distance squared eats into the shape between the cells, more where
	// the cloud is thin (dampen(1 - d)), so the edges and the tops break into round lobes; the Perlin-Worley adds variety
	float wd = 1.0 - (float(n.g) * 0.75 + float(n.r) * 0.25);
	float thin = saturate(1.0 - d);
	thin = thin * (2.0 - thin);
	d -= c.shape.w * 0.55 * wd * wd * thin;
	if (q >= 2 && d > 0.0) {
		half4 m = cloudDev(c, CLOUD_DEV_OLD_MIP) ? noise.sample(cloudRep, cloudDetailPos(n3, c), level(lod + c.look2.w))
			: noise.sample(cloudRepMip, cloudDetailPos(n3, c), level(lod + c.look2.w));
		float wd2 = 1.0 - (float(m.g) * 0.6 + float(m.b) * 0.4);
		// fine detail: strongest on the sides and lower half, little on the domes' crowns
		float fade = 0.6 + 0.2 * smoothstep(0.85, 1.0, 1.0 - h) - 0.35 * smoothstep(0.05, 0.5, h);
		d -= 0.55 * c.misc.w * detail * wd2 * wd2 * thin * fade;
	}
	// inner texture: the billow noise varies the density inside the cloud too (mottled bases and bellies seen from below,
	// uneven light through the body), not only its edges
	d *= 0.6 + 0.8 * float(n.r);
	d = saturate(d);
	// edges sharpen with height: crisp cauliflower tops, softer ragged bases (2026-11: x art2.z)
	d = 1.0 - pow(1.0 - d, mix(3.0, 7.0, h) * mix(c.art2.z, 1.0, cloudFarK(distXZ, c)));
	return d * (0.5 + 0.5 * smoothstep(0.0, 0.2, h));
}

// ---- M3.3 (CLOUD_MODE_BATCH): the same densities with every texture fetch of a sample issued before any of them is used ----
// (2.0.1 opt) distXZ hoisted out of per-sample length(rel); FP16 density math for faster Apple9 ALU
static inline float cloudDensityMath(half4 w, half4 n, half4 m, float h, int q, constant CloudParams &c, float detail, float distXZ) {
	if (h <= 0.0 || h >= 1.0) return 0.0;
	float spread = cloudSpreadDist(distXZ, c);
	h = cloudBaseH(h, w, spread);
	if (h <= 0.0) return 0.0;
	half hh = half(h);
	half cov = saturate(half(c.shape.x) + (w.r - 0.5h) * 0.55h);
	half core = saturate((w.g - (1.0h - cov)) / max(cov, 0.08h));
	half sy = half(c.shape.y);
	half topH = mix(0.38h, 1.0h, sy) * (0.45h + 0.55h * core);
	half x = hh / max(topH, 0.05h);
	half d = core - x * x * mix(0.9h, 0.6h, sy);
	d *= smoothstep(0.0h, 0.04h + 0.3h * half(spread), hh); // (FT2.10: softer where the bases spread, cloudSpread)
	if (d <= 0.0h) return 0.0;
	if (q == 0) return float(saturate(d * 0.85h));
	half wd = 1.0h - (n.g * 0.75h + n.r * 0.25h);
	half thin = saturate(1.0h - d);
	thin = thin * (2.0h - thin);
	d -= half(c.shape.w * 0.55) * wd * wd * thin;
	if (q >= 2 && d > 0.0h) {
		half wd2 = 1.0h - (m.g * 0.6h + m.b * 0.4h);
		half fade = 0.6h + 0.2h * smoothstep(0.85h, 1.0h, 1.0h - hh) - 0.35h * smoothstep(0.05h, 0.5h, hh);
		d -= half(0.55 * c.misc.w * detail) * wd2 * wd2 * thin * fade;
	}
	d *= 0.6h + 0.8h * n.r;
	d = saturate(d);
	half edgeExp = mix(3.0h, 7.0h, hh) * half(mix(c.art2.z, 1.0, cloudFarK(distXZ, c)));
	d = 1.0h - pow(max(1.0h - d, 1e-4h), edgeExp);
	return float(d * (0.5h + 0.5h * smoothstep(0.0h, 0.2h, hh)));
}

static inline half4 cloudWeatherAt(float2 xz, float h, constant CloudParams &c, texture2d<half> weather) {
	return weather.sample(cloudRep, (xz - c.shear.xy * h) * (c.art2.x / CLOUD_WEATHER_TILE), level(0.0));
}

static inline float3 cloudNoisePos(float2 xz, float y, constant CloudParams &c) {
	return float3(xz.x + c.origin.z - c.origin.x, y, xz.y + c.origin.w - c.origin.y);
}

// cloudDensity (volumetric, M3.1 noise mips) with its fetches issued together.
static inline float cloudDensityB(float3 p, float y, int q, constant CloudParams &c, texture2d<half> weather, texture3d<half> noise,
                                  float detail, float lod, float distXZ) {
	float h = (y - c.layer.x) / (c.layer.y - c.layer.x);
	// (2.0.1 opt) guard before issuing 2D/3D texture fetches when outside slab
	if (h <= 0.0 || h >= 1.0) return 0.0;
	float2 xz = c.origin.xy + p.xz;
	float3 n3 = cloudNoisePos(xz, y, c);
	half4 w = cloudWeatherAt(xz, h, c, weather);
	half4 n = noise.sample(cloudRepMip, n3 * (CLOUD_NOISE_SCALE * c.art2.y), level(lod));
	half4 m = q >= 2 ? noise.sample(cloudRepMip, cloudDetailPos(n3, c), level(lod + c.look2.w)) : half4(0.0h);
	return cloudDensityMath(w, n, m, h, q, c, detail, distXZ);
}

// cloudLightDepth (up to 4 light steps; the first two with billows) and the sky-light sample above (pUp, yUp: its 2D density in
// dUp) with all their fetches issued together.
static float cloudLightDepthB(float3 p, float y, float jitter, int steps, constant CloudParams &c, texture2d<half> weather,
                              texture3d<half> noise, float lod, float3 pUp, float yUp, bool hasLight, thread float &dUp) {
	float inv = 1.0 / (c.layer.y - c.layer.x);
	float hUp = (yUp - c.layer.x) * inv;
	bool inUp = hUp > 0.0 && hUp < 1.0;
	float2 xzUp = c.origin.xy + pUp.xz;
	float wk = c.art2.x / CLOUD_WEATHER_TILE;
	// (2.0.1 opt) moonless night: skip all 4 direct-light steps and fetch only sky-light sample above
	if (!hasLight) {
		if (!inUp) { dUp = 0.0; return 0.0; }
		half4 wUp = c.hz.z > 0.0 ? weather.sample(cloudRepMipL, (xzUp - c.shear.xy * hUp) * wk, level(c.hz.z)) : cloudWeatherAt(xzUp, hUp, c, weather);
		dUp = cloudDensityMath(wUp, wUp, wUp, hUp, 0, c, 1.0, length(pUp.xz));
		return 0.0;
	}
	float3 L = c.lightDir.xyz;
	float s = 0.0, stp = c.misc.y > 0.0 ? c.misc.y : 4.0;
	float grow = steps <= 3 ? 3.5 : steps == 4 ? 2.6 : 2.0;
	float hs[4], len[4];
	float2 xz[4], rl[4];
	float yq[4];
	bool inL[4];
	for (int i = 0; i < 4; i++) {
		float m = s + stp * (0.5 + 0.5 * (jitter - 0.5));
		float3 q = p + L * m;
		yq[i] = y + L.y * m;
		hs[i] = (yq[i] - c.layer.x) * inv;
		inL[i] = (i < steps) && (hs[i] > 0.0 && hs[i] < 1.0);
		rl[i] = q.xz;
		xz[i] = c.origin.xy + q.xz;
		len[i] = stp;
		s += stp;
		stp *= grow;
	}
	// (2.0.1 opt) gate every fetch on hs[i] in (0, 1) and hUp in (0, 1) while keeping live fetches batched together
	half4 w0 = inL[0] ? cloudWeatherAt(xz[0], hs[0], c, weather) : half4(0.0h);
	half4 w1 = inL[1] ? cloudWeatherAt(xz[1], hs[1], c, weather) : half4(0.0h);
	half4 w2, w3, wUp;
	if (c.hz.z > 0.0) {
		w2 = inL[2] ? weather.sample(cloudRepMipL, (xz[2] - c.shear.xy * hs[2]) * wk, level(c.hz.z)) : half4(0.0h);
		w3 = inL[3] ? weather.sample(cloudRepMipL, (xz[3] - c.shear.xy * hs[3]) * wk, level(c.hz.z + 1.0)) : half4(0.0h);
		wUp = inUp ? weather.sample(cloudRepMipL, (xzUp - c.shear.xy * hUp) * wk, level(c.hz.z)) : half4(0.0h);
	} else {
		w2 = inL[2] ? cloudWeatherAt(xz[2], hs[2], c, weather) : half4(0.0h);
		w3 = inL[3] ? cloudWeatherAt(xz[3], hs[3], c, weather) : half4(0.0h);
		wUp = inUp ? cloudWeatherAt(xzUp, hUp, c, weather) : half4(0.0h);
	}
	half4 n0 = inL[0] ? noise.sample(cloudRepMip, cloudNoisePos(xz[0], yq[0], c) * (CLOUD_NOISE_SCALE * c.art2.y), level(lod)) : half4(0.0h);
	half4 n1 = inL[1] ? noise.sample(cloudRepMip, cloudNoisePos(xz[1], yq[1], c) * (CLOUD_NOISE_SCALE * c.art2.y), level(lod + 1.0)) : half4(0.0h);
	float tau = inL[0] ? cloudDensityMath(w0, n0, n0, hs[0], 1, c, 1.0, length(rl[0])) * len[0] : 0.0;
	if (inL[1]) tau += cloudDensityMath(w1, n1, n1, hs[1], 1, c, 1.0, length(rl[1])) * len[1];
	float farK = c.hz.z > 0.0 ? c.hz.w : 1.0;
	if (inL[2]) tau += cloudDensityMath(w2, w2, w2, hs[2], 0, c, 1.0, length(rl[2])) * (len[2] * farK);
	if (inL[3]) tau += cloudDensityMath(w3, w3, w3, hs[3], 0, c, 1.0, length(rl[3])) * (len[3] * farK);
	dUp = inUp ? cloudDensityMath(wUp, wUp, wUp, hUp, 0, c, 1.0, length(pUp.xz)) : 0.0;
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
// (2.0.1 opt) FP16 octave exponentials, reused eL0/eU0 across Wrenninge & Photon, unrolled k=0..3, moonless direct-light skip
static inline float3 cloudSampleLight(float tauL, float dUp, float d, float st, float h, float y, float mu, float pw, float ph0, float ph1,
                                      float ph2, float ph3, bool hasLight, constant CloudParams &c) {
	float sigma = c.shape.z;
	float above = c.layer.y - y;
	// (diffuse light: much less extinct than the direct beam)
	half tauUp = half((dUp * 0.7 + d * 0.3) * sigma * above * c.art.z);
	half tauDown = half(d * sigma * (y - c.layer.x) * c.art.z * 0.75);
	half eDown = exp(-tauDown);
	half eU0 = exp(-tauUp);
	half tauLh = half(tauL);
	half eL0 = hasLight ? exp(-tauLh) : 0.0h;
	float3 direct = float3(0.0), amb = float3(0.0);
	// skip Wrenninge octaves when Photon octaves have full weight (art2.w >= 0.999)
	if (c.art2.w < 0.999) {
		if (hasLight) {
			half a1 = half(c.art.x), b1 = half(c.art.y);
			half a2 = a1 * a1, b2 = b1 * b1;
			half ms = eL0 * half(ph0) + a1 * exp(-b1 * tauLh) * half(ph1) + a2 * exp(-b2 * tauLh) * half(ph2)
				+ (a2 * a1) * exp(-(b2 * b1) * tauLh) * half(ph3);
			half powder = 1.0h - half(pw) * exp(-half(st) * 28.0h);
			ms *= mix(powder, 1.0h, half(saturate(mu * 1.5)));
			direct = c.light.rgb * float(ms);
		}
		amb = (c.ambTop.rgb * float(eU0) * (0.55 + 0.45 * h) + c.ambBottom.rgb * float(eDown)) * c.ambBottom.w;
	}
	if (c.art2.w > 0.0) {
		// (2026-11, art2.w) Photon's octaves (unrolled k=0..3, reusing eL0 and eU0 for k=0)
		half m01 = half(mu * 0.5 + 0.5);
		half P = 3.14159265h * half(d) / (half(d) + 0.15h);
		P = mix(P, 1.0h, 0.8h * m01 * m01);
		half grow = 0.55h * mix(0.75h, 1.0h, m01);
		half dP = hasLight ? eL0 * half(ph0) : 0.0h;
		half aP = eU0;
		half sc = grow * P;
		P = mix(P, sqrt(P), 0.5h);
		if (hasLight) dP += sc * exp(-0.4h * tauLh) * half(ph1);
		aP += sc * exp(-0.4h * tauUp);
		sc *= grow * P;
		P = mix(P, sqrt(P), 0.5h);
		if (hasLight) dP += sc * exp(-0.16h * tauLh) * half(ph2);
		aP += sc * exp(-0.16h * tauUp);
		sc *= grow * P;
		if (hasLight) dP += sc * exp(-0.064h * tauLh) * half(ph3);
		aP += sc * exp(-0.064h * tauUp);
		float3 dPh = hasLight ? c.light.rgb * (float(dP) * 0.5) : float3(0.0);
		float3 aPh = (c.ambTop.rgb * float(aP) * (0.55 + 0.45 * h) * 0.5 + c.ambBottom.rgb * float(eDown)) * c.ambBottom.w;
		direct = c.art2.w >= 0.999 ? dPh : mix(direct, dPh, c.art2.w);
		amb = c.art2.w >= 0.999 ? aPh : mix(amb, aPh, c.art2.w);
	}
	return direct + amb;
}

// The cumulus layer along dir (camera-relative world, unit). steps/lsteps: primary and light samples; q: best density
// quality; jitter in [0, 1).
// foot: the radians one march sample covers (the noise mip by distance): the screen march's windDir.w, the dome's own texel
static CloudResult cloudMarch(float3 dir, CloudRay r, bool hasSeg, float t0, float t1, float mu, float ph0, float ph1, float ph2, float ph3,
                              bool hasLight, int steps, int lsteps, int q, float jitter, constant CloudParams &c, texture2d<half> weather,
                              texture3d<half> noise, float foot, float dtMaxOverride = 0.0) {
	CloudResult o;
	o.S = 0.0;
	o.T = 1.0;
	o.dist = -1.0;
	if (!hasSeg) return o;
	// inside the layer: the fog around the camera matters, the far stretch is hidden by it (and by aerial perspective)
	bool inside = t0 < 1.0;
	if (inside) t1 = min(t1, 1500.0);
	float len = t1 - t0;
	float dtMax = dtMaxOverride > 0.0 ? dtMaxOverride : (c.art3.w > 0.0 ? c.art3.w : 48.0);
	int n = clamp(int(max(float(steps) * saturate(len / 600.0), len / dtMax) + 0.999), max(steps / 2, 4), 3 * steps);
	float dt = len / float(n);
	// the fine detail (a ~30-block tile) fades out where the steps get too coarse to resolve it (it aliases into grain)
	float detail = saturate((26.0 - dt) / 14.0);
	if (detail <= 0.0) q = min(q, 1);
	float sigma = c.shape.z;
	float albedo = c.ambTop.w;
	float pw = c.look.x;
	float horiz = length(dir.xz); // (2.0.1 opt) hoisted: distXZ = t * horiz avoids per-sample sqrt
	float3 Sacc = 0.0;
	float T = 1.0, dsum = 0.0, wsum = 0.0;
	float thick = c.layer.y - c.layer.x;
	float invThick = 1.0 / thick;
	// empty air is crossed with double steps on the 2D footprint alone (a superset of the cloud: erosion only removes);
	// a hit steps back and walks on with single full-quality steps until 4 misses in a row
	bool fine = false;
	int miss = 0;
	// M3.3 (CLOUD_MODE_LIGHT2): the pending sample between two light marches (its weight, density, extinction, height, y)
	bool light2 = cloudMode(c, CLOUD_MODE_LIGHT2), haveL = false, odd = false;
	// M3.3 (CLOUD_MODE_BATCH): fetches issued together (the M3 noise sampler, dev bit OLD_MIP, and > 4 light steps keep the chain)
	bool batch = cloudMode(c, CLOUD_MODE_BATCH) && !cloudDev(c, CLOUD_DEV_OLD_MIP) && lsteps <= 4;
	float lastTauL = 0.0, lastUp = 0.0, pw0 = 0.0, pd = 0.0, pst = 0.0, ph = 0.0, py = 0.0;
	// inside the layer the steps start short and grow with distance
	float dtl = inside ? dt * 0.08 : dt;
	float t = t0 + jitter * dtl;
	int budget = 3 * n + 4 + (inside ? 24 : 0);
	// M3.3 (CLOUD_MODE_PAIR): outside the layer, the empty-air test also looks one double step ahead, both fetches issued together
	bool pair = cloudMode(c, CLOUD_MODE_PAIR) && !inside;
	for (int i = 0; i < budget && t < t1; i++) {
		if (inside) dtl = dt * clamp((t + 24.0) / 400.0, 0.08, 1.0);
		// (2.0.1 opt) distance-adaptive step growth past 2.5 km where far clouds already transition to soft M3 edges
		float stepDt = inside ? dtl : dtl * (1.0 + smoothstep(2500.0, 6000.0, t));
		float3 p = dir * t;
		float y = cloudAltitude(r, t);
		float distXZ = t * horiz;
		if (!fine && pair) {
			float tB = t + 2.0 * stepDt;
			float3 pB = dir * tB;
			float yB = cloudAltitude(r, tB);
			float hA = (y - c.layer.x) * invThick, hB = (yB - c.layer.x) * invThick;
			half4 wA = cloudWeatherAt(c.origin.xy + p.xz, hA, c, weather), wB = cloudWeatherAt(c.origin.xy + pB.xz, hB, c, weather);
			bool useB = i + 1 < budget && tB < t1;
			if (cloudDensityMath(wA, wA, wA, hA, 0, c, 1.0, distXZ) > 0.0) {
				fine = true;
				miss = 0;
				t = max(t - stepDt, t0 + jitter * dtl);
				continue;
			}
			t = tB;
			if (!useB) continue;
			i++;
			if (cloudDensityMath(wB, wB, wB, hB, 0, c, 1.0, tB * horiz) > 0.0) {
				fine = true;
				miss = 0;
				t = max(tB - stepDt, t0 + jitter * dtl);
				continue;
			}
			t = tB + 2.0 * stepDt;
			continue;
		}
		if (!fine) {
			if (cloudDensity(p, y, 0, c, weather, noise) <= 0.0) {
				t += 2.0 * stepDt;
				continue;
			}
			fine = true;
			miss = 0;
			t = max(t - stepDt, t0 + jitter * dtl);
			continue;
		}
		// mip of the noise for this sample's footprint (pixel angle x distance)
		float lod = cloudDev(c, CLOUD_DEV_OLD_MIP) ? max(log2(max(t * foot * c.art2.y, 1e-3) / CLOUD_NOISE_TEXEL), 0.0)
			: max(log2(max(t * foot * c.art2.y, 1e-3) / CLOUD_NOISE_TEXEL), 0.0) + fract(jitter * 3.17 + float(i) * 0.7548777) - 0.5;
		float above = c.layer.y - y;
		bool needL = !(light2 && haveL && !odd);
		// (2.0.1 opt) only pre-batch light fetches when already actively inside a cloud (miss == 0 && haveL): avoids 7 wasted fetches on exit misses
		bool preL = batch && needL && miss == 0 && haveL;
		float d, tauL = 0.0, dUp = 0.0;
		if (preL) {
			d = cloudDensityB(p, y, T > 0.25 ? q : 1, c, weather, noise, detail, lod, distXZ);
			tauL = cloudLightDepthB(p, y, fract(jitter + float(i) * 0.618034), lsteps, c, weather, noise, lod, p + float3(0.0, above * 0.4, 0.0),
				y + above * 0.4, hasLight, dUp);
		} else if (batch) {
			d = cloudDensityB(p, y, T > 0.25 ? q : 1, c, weather, noise, detail, lod, distXZ);
		} else {
			d = cloudDensity(p, y, T > 0.25 ? q : 1, c, weather, noise, detail, lod);
		}
		if (d <= 0.002) {
			if (++miss >= 4) fine = false;
			t += stepDt;
			continue;
		}
		miss = 0;
		float st = d * sigma * mix(1.0, c.art3.z, cloudFarK(t, c));
		float ds = clamp(c.shear.z / max(st, 1e-4), stepDt * c.shear.w, stepDt);
		float stepT = exp(-st * ds);
		float h = saturate((y - c.layer.x) * invThick);
		float wseg = T * (1.0 - stepT);
		dsum += t * wseg;
		wsum += wseg;
		T *= stepT;
		if (!needL) {
			odd = true;
			pw0 = wseg;
			pd = d;
			pst = st;
			ph = h;
			py = y;
			if (T < 0.03) break;
			t += ds;
			continue;
		}
		if (!preL) {
			if (batch) {
				tauL = cloudLightDepthB(p, y, fract(jitter + float(i) * 0.618034), lsteps, c, weather, noise, lod, p + float3(0.0, above * 0.4, 0.0),
					y + above * 0.4, hasLight, dUp);
			} else {
				tauL = hasLight ? cloudLightDepth(p, y, fract(jitter + float(i) * 0.618034), lsteps, c, weather, noise, lod) : 0.0;
				dUp = cloudDensity(p + float3(0.0, above * 0.4, 0.0), y + above * 0.4, 0, c, weather, noise);
			}
		}
		// (2.0.1 opt) dropped redundant st/max(st,1e-6) division and hoisted albedo out of loop
		if (odd) {
			Sacc += cloudSampleLight(0.5 * (lastTauL + tauL), 0.5 * (lastUp + dUp), pd, pst, ph, py, mu, pw, ph0, ph1, ph2, ph3, hasLight, c) * pw0;
			odd = false;
		}
		lastTauL = tauL;
		lastUp = dUp;
		haveL = true;
		Sacc += cloudSampleLight(tauL, dUp, d, st, h, y, mu, pw, ph0, ph1, ph2, ph3, hasLight, c) * wseg;
		if (T < 0.03) break;
		t += ds;
	}
	if (odd) Sacc += cloudSampleLight(lastTauL, lastUp, pd, pst, ph, py, mu, pw, ph0, ph1, ph2, ph3, hasLight, c) * pw0;
	o.S = Sacc * albedo;
	o.T = saturate((T - 0.03) / 0.97);
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

// ---- (2026-11) the altocumulus: a thin layer of small puffs well above the cumulus (alto.*) --------------------------------
// Portions adapted from Photon Shaders by Benjamin Stott ("sixthsurge"), MIT License, commit 26c2906e (full text:
// LICENSES/MIT-Photon.txt), include/sky/clouds/altocumulus.glsl: the layer's density (a broad coverage, the puffs where a finer noise
// passes 1 - coverage, the egg-shaped altitude carve, the Worley erosion damped in the puffs' dense cores, the edges hardening toward
// the top over a wispy base) and its march (few primary steps, more toward the horizon, a short light march). Ours: blocks, the noise
// from our weather map and 3D noise, the cirrus's frame and wind, two light samples on the puffs' 2D shape, our phase and ambient.
#define CLOUD_ALTO_NOISE (200.0 / 16384.0) // the 3D noise over the puffs: a ~82-block tile, a whole number of them per cirrus period

// The layer's frame: the cirrus's (its axis windDir.xy, the camera at cirrus.zw, wrapped). rel: camera-relative xz.
static inline float2 cloudAltoPos(float2 rel, constant CloudParams &c) {
	float2 wd = c.windDir.xy, wn = float2(-wd.y, wd.x);
	return c.cirrus.zw + float2(dot(rel, wd), dot(rel, wn));
}

// The share of the sky the layer covers around s: fields a few thousand blocks across (the weather map's b at half its frequency),
// x the amount, x alto2.w at a field's heart.
static inline float cloudAltoCover(float2 s, constant CloudParams &c, texture2d<half> weather) {
	half4 w = weather.sample(cloudRep, s * (0.5 / CLOUD_WEATHER_TILE) + float2(0.37, 0.61), level(0.0));
	return saturate(c.alto.x * c.alto2.w * smoothstep(0.3, 0.8, float(w.b)));
}

// The puffs' 2D shape at height fraction h in the layer, coverage cov (Photon's coverage test and altitude carve): g the cumulus cells
// at alto2.x (~64 blocks at 4), a the fine fBm at 1.5 (clusters and gaps), r the rows' noise (cloudAltoRows), each from the weather map.
static inline float cloudAltoShape(half g, half a, float rows, float h, float cov) {
	if (h <= 0.0 || h >= 1.0) return 0.0;
	cov *= rows;
	float d = saturate((float(g) * 0.7 + float(a) * 0.3 - (1.0 - cov)) / max(cov, 1e-3));
	d -= smoothstep(0.2, 1.0, h) * 0.6; // the egg-shaped carve
	return d * smoothstep(0.0, 0.2, h);
}

static inline half4 cloudAltoFetch(float2 s, float freq, float2 off, texture2d<half> weather) {
	return weather.sample(cloudRep, s * (freq / CLOUD_WEATHER_TILE) + off, level(0.0));
}

// (round 2, alto2.z) the coverage's factor from the rows: the cirrus fBm stretched 4:1 across the wind (bands ~150-300 blocks apart
// along it, long across it), so the puffs line up in the rows of a mackerel sky instead of an even sprinkle. rb: its fetch.
static inline float cloudAltoRows(half rb, constant CloudParams &c) {
	return mix(1.0, saturate(smoothstep(0.3, 0.7, float(rb)) * 1.6), c.alto2.z);
}

// The density's last steps: the Worley erosion (n: the 3D noise there; damped in the dense cores), the edges hardening toward the top
// over a wispy base; soft (alto2.y) scales the erosion and the edges' exponent (1 = Photon's).
static inline float cloudAltoFinish(float d, half4 n, float h, float soft) {
	float wd = 1.0 - float(n.g);
	float thin = saturate(1.0 - d);
	d = max(d - 0.66 * soft * wd * wd * thin * (2.0 - thin), 0.0);
	d = 1.0 - pow(1.0 - d, mix(3.0, 8.0, h) * soft);
	return d * (0.1 + 0.9 * smoothstep(0.2, 0.7, h));
}

// The layer along dir: (S, T, dist) as the cumulus march; jitter in [0, 1); foot: the radians one sample covers (the noise mip).
// (2.0.1 opt) reuses CloudRay, [t0, t1], ph0..ph2, hasLight; moves wl light fetch after d > 0.0 check (alongside 3D noise fetch)
static CloudResult cloudAlto(float3 dir, CloudRay r, bool hasSeg, float t0, float t1, float mu, float ph0, float ph1, float ph2, bool hasLight,
                             float jitter, constant CloudParams &c, texture2d<half> weather, texture3d<half> noise, float foot) {
	CloudResult o;
	o.S = 0.0;
	o.T = 1.0;
	o.dist = -1.0;
	if (!hasSeg) return o;
	float yb = c.alto.y, thick = c.alto.z;
	float cov = cloudAltoCover(cloudAltoPos(dir.xz * (0.5 * (t0 + t1)), c), c, weather);
	if (cov <= 0.01) return o;
	// (Photon: 12 steps toward the horizon, 6 up; here 8 and 4, jittered per frame and averaged by the history)
	int n = int(mix(8.0, 4.0, saturate(abs(dir.y) * 2.0)) + 0.5);
	float dt = (t1 - t0) / float(n);
	float3 L = c.lightDir.xyz;
	float sigma = c.alto.w, albedo = c.ambTop.w;
	half a1 = half(c.art.x), b1 = half(c.art.y);
	// the light's step in the layer's frame and height fraction
	const float LS = 10.0;
	float2 sL = float2(dot(L.xz, c.windDir.xy), dot(L.xz, float2(-c.windDir.y, c.windDir.x))) * LS;
	float hL = L.y * LS / thick;
	const float2 OFF_G = float2(0.13, 0.29), OFF_A = float2(0.71, 0.43), OFF_R = float2(0.23, 0.87);
	float freq = c.alto2.x, soft = c.alto2.y;
	half powderMix = half(saturate(mu * 1.5));
	float3 S = 0.0;
	float T = 1.0, dsum = 0.0, wsum = 0.0;
	for (int i = 0; i < n; i++) {
		float t = t0 + (float(i) + jitter) * dt;
		float y = cloudAltitude(r, t);
		float h = (y - yb) / thick;
		float2 s = cloudAltoPos(dir.xz * t, c);
		half4 w = cloudAltoFetch(s, freq, OFF_G, weather), w2 = cloudAltoFetch(s, 1.5, OFF_A, weather);
		// (the rows: across the wind, s.x along it; 6 and 1.5 x 1/4096: whole tiles per period)
		half4 wr = weather.sample(cloudRep, s * float2(6.0 / CLOUD_WEATHER_TILE, 1.5 / CLOUD_WEATHER_TILE) + OFF_R, level(0.0));
		float rows = cloudAltoRows(wr.b, c);
		float d = cloudAltoShape(w.g, w2.a, rows, h, cov);
		if (d <= 0.0) continue;
		float lod = max(log2(max(t * foot, 1e-3) * (64.0 / 81.92)), 0.0); // (the noise tile's 64 texels)
		// Issue light sample alongside 3D noise fetch only after confirming non-empty puff (saves wl on ~75% of steps)
		half4 n3 = noise.sample(cloudRepMip, float3(s.x, y, s.y) * CLOUD_ALTO_NOISE, level(lod));
		half4 wl = hasLight ? cloudAltoFetch(s + sL, freq, OFF_G, weather) : half4(0.0h);
		d = cloudAltoFinish(d, n3, h, soft);
		if (d <= 0.002) continue;
		float st = d * sigma;
		float stepT = exp(-st * dt);
		float3 direct = float3(0.0);
		if (hasLight) {
			half tauL = half(sigma * (max(cloudAltoShape(wl.g, w2.a, rows, h + hL, cov), 0.0) * LS + d * 2.0));
			half ms = exp(-tauL) * half(ph0) + a1 * exp(-b1 * tauL) * half(ph1) + (a1 * a1) * exp(-(b1 * b1) * tauL) * half(ph2);
			ms *= mix(1.0h - half(c.look.x * min(soft, 1.0)) * exp(-half(d) * 6.0h), 1.0h, powderMix);
			direct = c.light.rgb * float(ms);
		}
		half tauUp = half(d * sigma * (1.0 - h) * thick * c.art.z);
		float3 amb = (c.ambTop.rgb * (0.6 + 0.4 * h) * float(exp(-tauUp)) + c.ambBottom.rgb * 0.5) * c.ambBottom.w;
		float wseg = T * (1.0 - stepT);
		S += (direct + amb) * wseg;
		dsum += t * wseg;
		wsum += wseg;
		T *= stepT;
		if (T < 0.03) break;
	}
	o.S = S * albedo;
	o.T = T;
	o.dist = wsum > 1e-5 ? dsum / wsum : -1.0;
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

// (2.0.1 opt) True when a downward ray from below the cloud base is guaranteed to hit ground (or never reach layer.x)
static inline bool cloudRayMissesAll(float3 dir, constant CloudParams &c, float margin = 0.0) {
	if (c.layer.z >= c.layer.x) return false;
	float dy = dir.y + margin;
	if (dy >= 0.0) return false;
	if (cloudStyle(c) > 0.5) return true;
	float clear = c.layer.z - c.misc.z;
	if (clear > 0.0) return dy * dy >= 4.0 * c.layer.w * clear;
	float maxT = c.march.z * 1.6;
	return c.layer.z + dy * maxT + c.layer.w * maxT * maxT < c.layer.x;
}

// Cumulus + cirrus toward dir with aerial perspective: (S, T) and the apparent distance (-1: no cloud).
static CloudResult cloudSky(float3 dir, int steps, int lsteps, int q, float jitter, constant ShadeFrame &f, constant CloudParams &c,
                            texture2d<half> weather, texture3d<half> noise, texture2d<half> lut, sampler lutS, float foot,
                            bool allowAlto, float domeDtMax, thread float &fallbackDist) {
	CloudResult ci, cu, al;
	ci.S = 0.0; ci.T = 1.0; ci.dist = -1.0;
	al.S = 0.0; al.T = 1.0; al.dist = -1.0;
	CloudRay rs = cloudRay(dir, c);
	float cu0 = 0.0, cu1 = 0.0;
	bool hitCu = cloudStyle(c) < 0.5 && cloudSegment(rs, c.layer.x, c.layer.y, c.misc.z, c.march.z, cu0, cu1);
	fallbackDist = hitCu ? 0.5 * (cu0 + cu1) : c.march.z;
	float al0 = 0.0, al1 = 0.0;
	bool wantAlto = allowAlto && cloudStyle(c) < 0.5 && c.alto.x > 0.001;
	bool hitAl = wantAlto && cloudSegment(rs, c.alto.y, c.alto.y + c.alto.z, c.misc.z, min(c.march.z, 9000.0), al0, al1);
	bool aboveAlto = c.layer.z > c.alto.y + 0.5 * c.alto.z;
	bool batch = cloudMode(c, CLOUD_MODE_BATCH);
	// Share mu, phase octaves and hasLight across cumulus and altocumulus
	float mu = dot(dir, c.lightDir.xyz);
	bool hasLight = max(c.light.r, max(c.light.g, c.light.b)) >= 1e-5;
	float ph0 = 0.0, ph1 = 0.0, ph2 = 0.0, ph3 = 0.0;
	if (hasLight && (hitCu || hitAl)) {
		ph0 = cloudPhase(mu, 1.0, c);
		ph1 = cloudPhase(mu, 0.5, c);
		ph2 = cloudPhase(mu, 0.25, c);
		ph3 = cloudPhase(mu, 0.125, c);
	}
	float3 skyPre = 0.0;
	if (batch) {
		CloudCirrusPre pre = cloudCirrusBegin(dir, c, weather);
		if (cloudStyle(c) > 0.5 || pre.t > 0.0 || cloudDev(c, CLOUD_DEV_OLD_MARCH) || hitCu || hitAl)
			skyPre = shadeSkyLookup(dir, lut, lutS, f);
		cu = cloudStyle(c) > 0.5 ? cloudBlocky(dir, c, weather)
			: cloudMarch(dir, rs, hitCu, cu0, cu1, mu, ph0, ph1, ph2, ph3, hasLight, steps, lsteps, q, jitter, c, weather, noise, foot, domeDtMax);
		if (hitAl && (aboveAlto || cu.T > 0.015))
			al = cloudAlto(dir, rs, hitAl, al0, al1, mu, ph0, ph1, ph2, hasLight, fract(jitter + 0.381966), c, weather, noise, foot);
		if (cu.T * al.T > 0.015) ci = cloudCirrusEnd(pre, dir, c, weather);
	} else {
		cu = cloudStyle(c) > 0.5 ? cloudBlocky(dir, c, weather)
			: cloudMarch(dir, rs, hitCu, cu0, cu1, mu, ph0, ph1, ph2, ph3, hasLight, steps, lsteps, q, jitter, c, weather, noise, foot, domeDtMax);
		if (hitAl && (aboveAlto || cu.T > 0.015))
			al = cloudAlto(dir, rs, hitAl, al0, al1, mu, ph0, ph1, ph2, hasLight, fract(jitter + 0.381966), c, weather, noise, foot);
		if (cu.T * al.T > 0.015) ci = cloudCirrus(dir, c, weather);
	}
	// the clear sky behind only matters where a cloud is (aerial perspective; M3.1: no lookup for the empty rays)
	if (cu.dist >= 0.0 || ci.dist >= 0.0 || al.dist >= 0.0 || cloudDev(c, CLOUD_DEV_OLD_MARCH)) {
		float3 sky = batch ? skyPre : shadeSkyLookup(dir, lut, lutS, f);
		float hf = cloudHorizonFade(dir, c);
		if (c.hz.x > 0.0) hf *= mix(1.0, smoothstep(-0.5 * c.hz.y, c.hz.y, dir.y), c.hz.x);
		cu = cloudAerial(cu, sky, hf, c);
		ci = cloudAerial(ci, sky, hf, c);
		al = cloudAerial(al, sky, hf, c);
	}
	CloudResult o;
	float3 back = al.S + al.T * ci.S;
	if (aboveAlto) {
		o.S = al.S + al.T * (cu.S + cu.T * ci.S);
	} else {
		o.S = cu.S + cu.T * back;
	}
	o.T = cu.T * al.T * ci.T;
	o.dist = cu.dist >= 0.0 ? cu.dist : al.dist >= 0.0 ? al.dist : ci.dist;
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
	float dist [[color(1)]];  // apparent distance (blocks; R16F target, max 19200 <= 65504)
};

fragment CloudMarchOut cloud_march(CloudVsOut in [[stage_in]], constant ShadeFrame &f [[buffer(16)]], constant CloudParams &c [[buffer(0)]],
                                   texture2d<half> weather [[texture(0)]], texture3d<half> noise [[texture(1)]],
                                   texture2d<half> lut [[texture(17)]], sampler lutS [[sampler(13)]]) {
	float n = c.windDir.z;
	float2 hp = min(floor(in.position.xy) * n + c.frame.xy, c.size.xy - 1.0);
	float2 uv = (hp + 0.5) / c.size.xy;
	float3 dir = cloudDirection(uv, c);
	CloudMarchOut o;
	// (2.0.1 opt) downward rays below ground-graze angle cannot hit cumulus, altocumulus or visible cirrus
	if (!cloudDev(c, CLOUD_DEV_OLD_MARCH) && cloudRayMissesAll(dir, c)) {
		o.color = half4(0.0h, 0.0h, 0.0h, 1.0h);
		o.dist = c.march.z;
		return o;
	}
	float visit = floor(c.misc.x / (n * n));
	float seed = cloudMode(c, CLOUD_MODE_STABLE) ? shadeHash01(shadeHash3(int3(int2(hp), 0), 0x2c1b3c6du)) : shadeNoise(hp, 0);
	float jitter = fract(seed + visit * 0.6180339887);
	float fallbackDist = c.march.z;
	CloudResult r = cloudSky(dir, int(c.march.x), int(c.march.y), 2, jitter, f, c, weather, noise, lut, lutS, c.windDir.w, true, 0.0, fallbackDist);
	o.color = half4(half3(min(r.S, 60000.0)), half(r.T));
	o.dist = r.dist >= 0.0 ? r.dist : fallbackDist;
	return o;
}

// 5-tap Catmull-Rom of the history (rgb and transmittance) in FP16 math (exact float2 UVs)
static inline half4 cloudCatmullRom(texture2d<half> tex, float2 uv, float2 size) {
	float2 pos = uv * size;
	float2 t1 = floor(pos - 0.5) + 0.5;
	half2 f = half2(pos - t1);
	half2 f2 = f * f;
	half2 w0 = f * (-0.5h + f * (1.0h - 0.5h * f));
	half2 w1 = 1.0h + f2 * (-2.5h + 1.5h * f);
	half2 w2 = f * (0.5h + f * (2.0h - 1.5h * f));
	half2 w3 = f2 * (-0.5h + 0.5h * f);
	half2 w12 = w1 + w2;
	float2 inv = 1.0 / size;
	float2 t0 = (t1 - 1.0) * inv, t3 = (t1 + 2.0) * inv, t12 = (t1 + float2(w2 / w12)) * inv;
	half4 c = tex.sample(cloudClamp, float2(t12.x, t0.y)) * (w12.x * w0.y)
		+ tex.sample(cloudClamp, float2(t0.x, t12.y)) * (w0.x * w12.y)
		+ tex.sample(cloudClamp, t12) * (w12.x * w12.y)
		+ tex.sample(cloudClamp, float2(t3.x, t12.y)) * (w3.x * w12.y)
		+ tex.sample(cloudClamp, float2(t12.x, t3.y)) * (w12.x * w3.y);
	half wsum = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
	c /= wsum;
	return half4(max(c.rgb, 0.0h), saturate(c.a));
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
	bool oldTaps = cloudDev(c, CLOUD_DEV_OLD_RESOLVE);
	constexpr sampler gatherS(filter::nearest, address::clamp_to_edge);
	float2 msz = c.size.zw;
	float4 g0 = oldTaps ? float4(0.0) : curDist.gather(gatherS, float2(mp) / msz);
	float dNow = oldTaps ? curDist.read(mp).r : g0.y;
	float3 wp = shadeEye(c.invViewProj) + dir * dNow + float3(c.wind.x, 0.0, c.wind.y);
	float4 pc = c.prevViewProj * float4(wp, 1.0);
	float2 puv = pc.xy / max(pc.w, 1e-6) * 0.5 + 0.5;
	bool valid = c.frame.z < 0.5 && pc.w > 1e-4 && all(puv >= 0.0) && all(puv <= 1.0);
	half4 h = half4(0.0h, 0.0h, 0.0h, 1.0h);
	float age = 0.0;
	if (valid) {
		h = cloudCatmullRom(hist, puv, c.size.xy);
		age = float(histAge.sample(cloudClamp, puv).r) * 64.0;
		int2 mi = int2(mp), ms = int2(c.size.zw) - 1;
		int2 ax = int2(min(mi.x + 1, ms.x), mi.y), bx = int2(max(mi.x - 1, 0), mi.y);
		int2 ay = int2(mi.x, min(mi.y + 1, ms.y)), by = int2(mi.x, max(mi.y - 1, 0));
		float d1, d2, d3, d4;
		if (oldTaps) {
			d1 = curDist.read(uint2(ax)).r, d2 = curDist.read(uint2(bx)).r, d3 = curDist.read(uint2(ay)).r, d4 = curDist.read(uint2(by)).r;
		} else {
			float4 g1 = curDist.gather(gatherS, (float2(mp) + 1.0) / msz);
			d1 = g1.z;
			d2 = g0.x;
			d3 = g1.x;
			d4 = g0.z;
		}
		float dMin = min(min(min(d1, d2), min(d3, d4)), dNow), dMax = max(max(max(d1, d2), max(d3, d4)), dNow);
		if (dMax > dMin * 1.3 + 4.0) {
			half4 c1 = cur.read(uint2(ax)), c2 = cur.read(uint2(bx)), c3 = cur.read(uint2(ay)), c4 = cur.read(uint2(by));
			half4 lo = min(min(min(c1, c2), min(c3, c4)), now), hi = max(max(max(c1, c2), max(c3, c4)), now);
			half4 pad = (hi - lo) * 0.15h;
			h = clamp(h, lo - pad, hi + pad);
		}
	}
	float maxAge = abs(c.frame.w);
	CloudResolveOut o;
	if (mine) {
		float w = valid ? 1.0 / min(age + 1.0, maxAge) : 1.0;
		o.color = valid ? mix(h, now, half(w)) : now;
		o.age = half(min(age + 1.0, maxAge) / 64.0);
	} else if (valid && age > 0.5) {
		o.color = h;
		o.age = half(age / 64.0);
	} else {
		float2 mpos = (float2(px) + 0.5 - float2(slot) - 0.5) / float(n) + 0.5;
		o.color = cur.sample(cloudClamp, mpos / c.size.zw);
		o.age = 0.0h;
	}
	if (shadeBad(o.color)) o.color = half4(0.0h, 0.0h, 0.0h, 1.0h);
	return o;
}

// ---- M3.3: the resolve that carries the clouds' distance (CLOUD_MODE_STABLE) ----------------------------------------------
#define CLOUD_DIST_NONE 4095u
static inline uint cloudDistCode(float d) { return uint(clamp(log2(max(d, 1.0)) * 256.0 + 0.5, 0.0, 4094.0)); }
static inline float cloudDistDecode(uint q) { return exp2(float(q) * (1.0 / 256.0)); }

struct CloudResolveStOut {
	half4 color [[color(0)]]; // rgb scattered light (before exposure), a transmittance
	ushort data [[color(1)]]; // R16Uint: age << 12 | distance code
};

fragment CloudResolveStOut cloud_resolve_st(CloudVsOut in [[stage_in]], constant CloudParams &c [[buffer(0)]],
                                            texture2d<half> cur [[texture(0)]], texture2d<float> curDist [[texture(1)]],
                                            texture2d<half> hist [[texture(2)]], texture2d<ushort> histData [[texture(3)]]) {
	uint n = uint(c.windDir.z);
	uint2 px = uint2(in.position.xy);
	float2 uv = (float2(px) + 0.5) / c.size.xy;
	float3 dir = cloudDirection(uv, c);
	// (2.0.1 opt) downward rays well below ground-graze angle hold no clouds: skip all history/Catmull-Rom/gather fetches (~42% of pixels)
	if (!cloudDev(c, CLOUD_DEV_OLD_MARCH) && cloudRayMissesAll(dir, c, 0.025)) {
		CloudResolveStOut o;
		o.color = half4(0.0h, 0.0h, 0.0h, 1.0h);
		o.data = ushort(CLOUD_DIST_NONE);
		return o;
	}
	uint2 slot = uint2(c.frame.xy);
	uint2 mp = min(px / n, uint2(c.size.zw) - 1u);
	bool mine = all(px % n == slot);
	half4 now = cur.read(mp);
	constexpr sampler gatherS(filter::nearest, address::clamp_to_edge);
	float2 msz = c.size.zw;
	float4 g0 = float4(0.0);
	float dNow = 1.0;
	bool valid = false;
	float2 puv = float2(0.0);
	float dRep = 1.0;
	float4 A = float4(0.0), B = float4(0.0), pc = float4(0.0);
	if (c.frame.z < 0.5) {
		g0 = curDist.gather(gatherS, float2(mp) / msz);
		uint4 qu = uint4(histData.gather(gatherS, uv)) & 0xfffu;
		uint qMin = min(min(qu.x, qu.y), min(qu.z, qu.w));
		dNow = max(g0.y, 1.0);
		float3 wnd = float3(c.wind.x, 0.0, c.wind.y);
		dRep = qMin != CLOUD_DIST_NONE ? cloudDistDecode(qMin) : dNow;
		// (2.0.1 opt) compute A = prevViewProj*(dir,0) and B = prevViewProj*(eye+wnd,1) ONCE and share across pc, DRIFT, ZOOM, EDGE
		A = c.prevViewProj * float4(dir, 0.0);
		B = c.prevViewProj * float4(shadeEye(c.invViewProj) + wnd, 1.0);
		pc = dRep * A + B;
		puv = pc.xy / max(pc.w, 1e-6) * 0.5 + 0.5;
		valid = pc.w > 1e-4 && all(puv >= 0.0) && all(puv <= 1.0);
	} else {
		dNow = max(curDist.read(mp).r, 1.0);
	}
	half4 h = half4(0.0h, 0.0h, 0.0h, 1.0h);
	float age = 0.0, dOwn = dNow;
	uint qOwn = CLOUD_DIST_NONE;
	bool ownCloud = false;
	float maxAge = abs(c.frame.w);
	float drift = 0.0;
	if (valid && cloudMode(c, CLOUD_MODE_DRIFT)) {
		float2 sep = (puv - (A.xy / max(A.w, 1e-6) * 0.5 + 0.5)) * c.size.xy;
		float nearW = 1.0 - smoothstep(32.0, 128.0, dRep);
		float glowW = smoothstep(0.85, 0.97, dot(dir, c.lightDir.xyz));
		drift = smoothstep(0.5, 1.5, length(sep)) * max(nearW, glowW);
	}
	if (valid) {
		uint4 q = uint4(histData.gather(gatherS, puv));
		float2 f = fract(puv * c.size.xy - 0.5);
		float4 ages = float4(q >> 12u);
		age = mix(mix(ages.w, ages.z, f.x), mix(ages.x, ages.y, f.x), f.y);
		// (2.0.1 opt) only run zoom magnification check when FOV actually zoomed in (c.frame.w > 0; negative = steady FOV)
		if (cloudMode(c, CLOUD_MODE_ZOOM) && c.frame.w > 0.0) {
			float3 dirR = cloudDirection(uv + float2(1.0 / c.size.x, 0.0), c);
			float4 a1 = c.prevViewProj * float4(dirR, 0.0);
			float sz = A.w > 1e-4 && a1.w > 1e-4 ? length((a1.xy / a1.w - A.xy / A.w) * 0.5 * c.size.xy) : 1.0;
			age *= min(1.0, sz * sz);
		}
		uint4 qd = q & 0xfffu;
		qOwn = f.y < 0.5 ? (f.x < 0.5 ? qd.w : qd.z) : (f.x < 0.5 ? qd.x : qd.y);
		ownCloud = qOwn != CLOUD_DIST_NONE;
		if (ownCloud) dOwn = cloudDistDecode(qOwn);
		h = cloudCatmullRom(hist, puv, c.size.xy);
		int2 mi = int2(mp), ms = int2(c.size.zw) - 1;
		int2 ax = int2(min(mi.x + 1, ms.x), mi.y), bx = int2(max(mi.x - 1, 0), mi.y);
		int2 ay = int2(mi.x, min(mi.y + 1, ms.y)), by = int2(mi.x, max(mi.y - 1, 0));
		float4 g1 = curDist.gather(gatherS, (float2(mp) + 1.0) / msz);
		float d1 = g1.z, d2 = g0.x, d3 = g1.x, d4 = g0.z;
		float dMin = min(min(min(d1, d2), min(d3, d4)), g0.y), dMax = max(max(max(d1, d2), max(d3, d4)), g0.y);
		bool jump = dMax > dMin * 1.3 + 4.0;
		if (jump && cloudMode(c, CLOUD_MODE_EDGE)) {
			float4 pa = dMin * A + B, pb = dMax * A + B;
			float2 sep = (pa.xy / max(pa.w, 1e-6) - pb.xy / max(pb.w, 1e-6)) * 0.5 * c.size.xy;
			jump = dot(sep, sep) > 0.25;
		}
		if (jump || drift > 0.0) {
			half4 c1 = cur.read(uint2(ax)), c2 = cur.read(uint2(bx)), c3 = cur.read(uint2(ay)), c4 = cur.read(uint2(by));
			half4 lo = min(min(min(c1, c2), min(c3, c4)), now), hi = max(max(max(c1, c2), max(c3, c4)), now);
			half4 pad = (hi - lo) * 0.15h;
			h = jump ? clamp(h, lo - pad, hi + pad) : mix(h, clamp(h, lo - pad, hi + pad), half(drift));
		}
		age = min(age, mix(min(maxAge, 15.0), 1.0, drift));
	}
	const half clear = 0.995h;
	bool histCloud = valid && age > 0.5 && ownCloud && h.a < clear;
	CloudResolveStOut o;
	uint ageOut, qOut;
	float cap = mix(min(maxAge, 15.0), 2.0, drift);
	if (mine) {
		float w = valid ? 1.0 / min(age + 1.0, cap) : 1.0;
		o.color = valid ? mix(h, now, half(w)) : now;
		ageOut = uint(min(age + 1.0, cap) + 0.5);
		bool nowCloud = now.a < clear;
		qOut = nowCloud ? cloudDistCode(histCloud ? 1.0 / mix(1.0 / dOwn, 1.0 / dNow, w) : dNow) : histCloud ? qOwn : CLOUD_DIST_NONE;
	} else if (valid && age > 0.5) {
		o.color = h;
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
	float dummyDist = c.march.z;
	// (2.0.1 opt) skip sub-texel altocumulus and use dtMax = 64 in reflection dome
	CloudResult r = cloudSky(dir, int(c.dome.w), 2, 1, jitter, f, c, weather, noise, lut, lutS, foot, false, 64.0, dummyDist);
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
	int N = cloudDev(c, CLOUD_DEV_OLD_SHADOW) ? 6 : clamp(int(ceil((sb - sa) / 36.0)), 6, 24);
	float ds = (sb - sa) / float(N);
	float tau = 0.0;
	// (2.0.1 opt) stop once transmittance < 0.0025 (below 1 ULP of R8Unorm)
	float tauStop = 6.0 / max(c.shape.z * 0.8, 1e-4);
	float3 base = float3(rel.x, yRef - c.layer.z, rel.y);
	for (int i = 0; i < N; i++) {
		float s = sa + (float(i) + 0.5) * ds;
		float3 p = base + float3(L.x, ly, L.z) * s;
		tau += cloudDensity(p, yRef + ly * s, 1, c, weather, noise, 1.0, cloudDev(c, CLOUD_DEV_OLD_MIP) ? 1.1 : 0.0) * ds;
		if (tau >= tauStop) return 0.0h;
	}
	return half(exp(-tau * c.shape.z * 0.8));
}

#endif
