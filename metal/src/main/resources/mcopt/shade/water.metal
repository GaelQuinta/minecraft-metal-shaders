// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// mcopt native shading: the water and reflections module (shader bible E14, E15 basics, E26 surface). Original code; the
// techniques are public (Schlick 1994, Walter et al. 2007 GGX, Beer-Lambert, McGuire & Mara 2014 screen-space ray
// marching, Tessendorf 2001 deep-water dispersion, caustics as the inverse Jacobian of the refracted light field).
//
// Assembled by ShadeMsl after shade_common.metal (mcopt.metal.shade.water.ShadeWater.prelude puts the SHADE_* defines in
// front) for the translucent terrain fragment; written as a self-contained include so other water renderers (far terrain,
// Distant Horizons' transparent pass) can call the same functions.
//
// UNITS AND SPACES: shade_common.metal's. Positions are camera-relative world (blocks), +y up. Colours are linear radiance
// BEFORE exposure (what shadeLit returns); the caller applies air fog and the output transform (M1: shadeFogAir +
// shadeFinish; M2 HDR: pre-exposure and the post tonemap). Depth is reversed-Z in [0, 1] (1 near, 0 = sky/clear).
//
// INPUTS (bound by mcwater.m on every shaded encoder, fragment stage):
//   texture(18) sceneCopy  the main pass's colour attachment 0, copied at the switch to translucent terrain: the opaque
//                          scene (sky, terrain, entities) without the translucents. M1: tone-mapped sRGB in RGBA8 (read
//                          back to radiance by shadeWaterSceneRadiance); M2 HDR: pre-exposed linear radiance (MCOPT_HDR or
//                          SHADE_HDR).
//   texture(19) depthCopy  the depth attachment at the same moment (Depth32Float, reversed-Z).
//   texture(20) waves      (SHADE_WAVE_BAKE) the baked wave field, RGBA16F SHADE_WAVE_BAKE_SIZE^2 mipmapped (slope xz, height, Laplacian)
//   texture(21) coarse     the SSR march's half-size nearest depth (R32F reversed-Z), made after the copy
//   buffer(23)  ShadeWaterParams (below). state.x == 1 only after this frame's copy: otherwise callers must not read the
//                          copies (they are 1x1 dummies or last frame's).
//   prev                   (M2 HDR, optional) last frame's finished HDR world (ShadeResources.prevScene: everything incl.
//                          clouds, translucents, Distant Horizons, pre-exposed with ShadeGpu.exposure.z). Where the caller
//                          gives it (ShadeWaterIn.prevExposure > 0), SSR hits take their colour from it (reprojected with
//                          prevViewProj) and the sky reflection reads the rendered sky on screen in the reflected direction
//                          (clouds, sun disc, stars, far LODs) instead of only the atmosphere LUT.
#ifndef MCOPT_SHADE_WATER
#define MCOPT_SHADE_WATER

// (FT2.6) the live pricing / A/B switches (shade_common.metal SHADE_WDEV_IS): this module's flag defines (SHADE_WDEV_ON among them)
// come after shade_common.metal, so its test there never saw them and every variant ran as the default; defined again here
#if defined(SHADE_LEAN_ABOVE) && defined(SHADE_WDEV_ON)
#undef SHADE_WDEV_IS
#define SHADE_WDEV_IS(f, k) (shadeWdev(f) == (k))
#endif
// (pricing, 2026-11-09: -Dmcopt.shade.leanDev=SHADE_PRICE_OLD with -Dmcopt.shade.water.ssrBoth=true: candidate 7's march and no
// panorama in the dev variant, in one session with the exact march; its coarse depth is at texture(31) then)
#ifdef SHADE_PRICE_OLD
#undef SHADE_SSR_HIER
#undef SHADE_WATER_PANO
#endif
#ifndef SHADE_SSR_THICK_K
#define SHADE_SSR_THICK_K 1.0 // (FT2.6, ShadeWater: mcopt.shade.water.ssrThick) the march's thickness in steps' depth extents
#endif
#ifndef SHADE_SSR_BEHIND
#define SHADE_SSR_BEHIND 0 // (FT2.6, ShadeWater: mcopt.shade.water.ssrBehind) a miss takes the first crossing behind something
#endif
#ifndef SHADE_SSR_STEPS
#define SHADE_SSR_STEPS 16
#endif
#ifndef SHADE_SSR_SIDE
// (1.2.7 candidate 7) how far past a side screen edge (NDC) the march goes on against the edge column, and the weight it keeps at the
// end (M2.1: 1.0 and 0.5). Gael (candidate 6): turning, "los reflejos de los extremos de la cámara se recortan raro, como que se
// chupan hacia los lados": the edge column stretched outward over half the screen's mirrored band
#define SHADE_SSR_SIDE 0.25
#endif
#ifndef SHADE_SSR_SIDE_END
#define SHADE_SSR_SIDE_END 0.0
#endif
#ifndef SHADE_SSR_TOP
// (1.2.7, B3b) how far past the top screen edge (NDC) the march goes on against the top row, trusted less and less to none there.
// Half a screen at half weight (candidate 4) stretched the top row down the water in long vertical streaks whenever the view
// tilted down at a lake (Gael, 2026-11-03: "cuando empiezo a voltear hacia abajo ves cómo se hacen líneas de reflejo"): now only a
// short continuation of a hill that leaves the top of the screen, blending into the sky fallback as candidate 3 did
#define SHADE_SSR_TOP 0.15
#endif

// Mirrors mcwater.m's WaterParams (144 bytes, written by ShadeWater.frame).
struct ShadeWaterParams {
	float4 still;  // atlas uv rectangle (u0, v0, u1, v1) of minecraft:block/water_still (all 0: unknown)
	float4 flow;   // the same for minecraft:block/water_flow
	float4 state;  // x 1 when the copies hold this frame's opaque scene, y water surface height above the eye (under water),
	               // z wetness 0..1, w 1 when texture(20) holds this frame's baked waves
	float4 tune;   // x wave strength (mcopt.shade.waterWaves), y SSR max distance (blocks; (1.1) 0 = screen reflections off), z reflection strength, w caustics 0/1
	// (2026-11-02, water round 1; all read every frame, defaults = the look before it; SHADE_WATER_SWELL / SHADE_WATER_GLITTER code)
	float4 swell;  // x the swell's strength (mcopt.shade.water.swell, 0 = none), y its masking k (.swellMask, 0.45), z the light through
	               // its crests at golden hour (.swellGlow, 0), w its share in the Fresnel (.swellFresnel, 1 = physical, 0 = as without it)
	float4 swell2; // x the open-water map's mean in its outer ring, for the water beyond it (< 0: no map, the swell everywhere at its
	               // strength), y (candidate 7) the mirrored images' calm (.mirrorCalm; 0 = 0.55), z the long waves' calm (mcopt.shade.water.calm,
	               // 0.55), w the ripples' (.ripple, 2.0)
	float4 swell3; // x the swell's share in the mirrored images' direction (.swellRefl, 0.45 = the ripples' share, 1 = all of it),
	               // y the glint's glitter (.glitter, 0 = none), z the glint's base roughness factor (.glintSharp, 1 = candidate 4's), w (candidate
	               // 7) the mirrored image's temporal reprojection's weight (.reflTemporal, 0 = none; SHADE_WATER_RTR)
	float4 rhist;  // (2026-11-06, SHADE_WATER_RHIST) the reflection's own history: x its weight (mcopt.shade.water.reflHistK, 0 = off:
	               // no read, no write), y 1 when texture(29) holds last frame's (mcwater.m), z this frame's tag (+1 / -1, alternating;
	               // the texels last frame wrote carry -z), w the clamp box's scale (.reflHistBox; 0 = the code isn't compiled in)
	float4 mirror; // (2026-11-06, SHADE_WATER_MIRROR_AA) x the ripple-aware mirror normal's strength (mcopt.shade.water.mirrorAAStrength,
	               // 0 = none), y (candidate 8, SHADE_SSR_HIER) the mirrored image's footprint filter (mcopt.shade.water.reflFilter, 1; 0 = one
	               // tap per pixel), z (candidate 8, SHADE_WATER_PANO) the panorama's share off screen (mcopt.shade.water.reflPano, 1; 0 = none),
	               // w reserved
};

// (2026-11-06) the reflection history's textures (SHADE_WATER_RHIST; mcwater.m binds them, ping-pong): texture(29) last frame's,
// texture(30) this frame's, RGBA16F at the world target's size: rgb the mirrored image (radiance before exposure, before the
// Fresnel, after its temporal filter), a this frame's tag x the mirrored point's distance from the eye (60000: the sky)
#ifdef SHADE_WATER_RHIST
#define SHADE_RH_PARAMS , texture2d<half> rhPrev, texture2d<half, access::write> rhOut
#define SHADE_RH_ARGS , rhPrev, rhOut
#else
#define SHADE_RH_PARAMS
#define SHADE_RH_ARGS
#endif

constexpr sampler shadeWaterLinear(filter::linear, address::clamp_to_edge, coord::normalized);

// 1 still water, 2 flowing water, 0 another translucent sprite, -1 the sprites are unknown (resource reload).
static inline int shadeWaterSprite(float2 uv, constant ShadeWaterParams &wp) {
	if (wp.still.z <= 0.0) return -1;
	if (all(uv >= wp.still.xy) && all(uv <= wp.still.zw)) return 1;
	if (all(uv >= wp.flow.xy) && all(uv <= wp.flow.zw)) return 2;
	return 0;
}

// ---- reading the copies --------------------------------------------------------------------------------------------------
// Linear view depth (the clip w, blocks along the view axis) of a reversed-Z depth value. Renderpearl's projection keeps
// clip w = -z_view, so z_ndc = -A + B / w with A = proj[2][2], B = proj[3][2] (column-major: [column][row]).
static inline float shadeLinearW(float z, constant ShadeFrame &f) {
	return f.proj[3][2] / max(z + f.proj[2][2], 1e-7);
}

// The scene's linear view depth (clip w: blocks along the view axis) at pixel px of the rendered rect behind the
// translucents, SHADE_WATER_SKY_W where nothing was drawn (sky). The ONE place the module reads the depth copy: with far
// terrain (Distant Horizons, whose depth has its own projection) this becomes a read of the merged scene-distance image
// (far-terrain-plan section 3.2-2; convert if that image holds radial distance), and SSR, refraction, absorption and foam
// all see the LODs.
#define SHADE_WATER_SKY_W 1e6
static inline float shadeWaterSceneW(depth2d<float> depth, uint2 px, constant ShadeFrame &f) {
	float z = depth.read(px);
	return z > 0.0 ? shadeLinearW(z, f) : SHADE_WATER_SKY_W;
}

// The SSR march's coarse depth (texture(21), made right after the copy by shade_water_hz_fs): per 2x2 block of the depth
// copy the nearest surface (max reversed-Z) in R32F at half size. The march's steps read it (a quarter of the cache
// lines, so the latency-bound march runs faster); the bisection and the thickness test read the full-resolution copy.
// With far terrain this must hold the merged scene distance too (see shadeWaterSceneW).
static inline float shadeWaterCoarseW(texture2d<float> hz, uint2 px, constant ShadeFrame &f) {
	float z = hz.read(px >> 1).r;
	return z > 0.0 ? shadeLinearW(z, f) : SHADE_WATER_SKY_W;
}

// The coarse-depth pass (full-screen triangle into the half-size R32F target, mc_water_capture): the world depth at texture(0).
// (FT2.8, audit idx 61) the 2x2 block in one gather at its shared corner (clamp to edge = the reads' min(p + 1, size - 1))
fragment float shade_water_hz_fs(float4 pos [[position]], depth2d<float> d [[texture(0)]]) {
	constexpr sampler g(coord::normalized, filter::nearest, address::clamp_to_edge);
	float2 p = float2(uint2(pos.xy) * 2u);
	float4 z = d.gather(g, (p + 1.0) / float2(d.get_width(), d.get_height()));
	return max(max(z.x, z.y), max(z.z, z.w));
}

// A display-referred colour (M1's tone-mapped sRGB) back to linear radiance before exposure: undo the sRGB curve, then
// the hue-preserving tone curve on the brightest channel (shadeOutput keeps the channel ratios below its white blend),
// then the exposure. Clipped highlights come back as ~5.6 / exposure.
static inline float3 shadeWaterDisplayRadiance(half3 stored, float exposure) {
	float3 o = float3(shadeToLinear(stored));
	float mo = max(max(o.r, o.g), max(o.b, 1e-5));
	float tm = min(mo, 0.9985);
	float y = (tm + sqrt(tm * tm + 0.024144 * tm)) * (1.0 / 2.012);    // undo the toe: 1.006 y^2 - tm y - 0.006 tm = 0
	float m = -log2(max(1.0 - y, 1e-4)) * (0.69314718 / 1.1);          // undo 1 - e^-1.1x
	return o * (m / mo) / max(exposure, 1e-6);
}

// The scene copy's value back to linear radiance before exposure. M1 (RGBA8 target): the display transform undone. HDR
// target (MCOPT_HDR, the M2 base, or SHADE_HDR): the copy already holds pre-exposed linear radiance, so only the
// exposure the frame was drawn with (ShadeWaterIn.exposure: sf.time.z in M1, ShadeGpu.exposure.x in M2) is divided out.
static inline float3 shadeWaterSceneRadiance(half3 stored, float exposure) {
#if defined(MCOPT_HDR) || defined(SHADE_HDR)
	return float3(stored) / max(exposure, 1e-6);
#else
	return shadeWaterDisplayRadiance(stored, exposure);
#endif
}

// Under dynamic resolution (TAAU) the world draws into the sub-rect (0, 0, render size) of fixed-size targets, and so
// do the copies: NDC maps to that sub-rect, not to the whole texture. SHADE_WATER_SUBRECT (define it with the TAAU merge,
// where ShadeFrame.screen.xy is the live render size) switches to it; otherwise the render size is the copy's size.
// SSR step jitter: still per pixel without TAA (a fixed pattern); with TAA (SHADE_WATER_TAA) it changes every frame and the
// temporal resolve integrates it into a smooth hit/miss edge instead of the per-quad speckle.
#if defined(SHADE_WATER_TAA) && !defined(SHADE_SSR_JITTER_STILL)
#define SHADE_WATER_NOISE_FRAME(f) ((f).flags2.x)
#else
#define SHADE_WATER_NOISE_FRAME(f) 0
#endif

static inline float2 shadeWaterRenderSize(constant ShadeFrame &f, float2 textureSize) {
#ifdef SHADE_WATER_SUBRECT
	return min(f.screen.xy, textureSize);
#else
	return textureSize;
#endif
}

// ---- waves ------------------------------------------------------------------------------------------------------------------
// The surface is a sum of directional waves with sharpened crests, h_i = a_i * e^(sin(theta_i) - 1), travelling with deep-water
// dispersion (omega = sqrt(g k), slowed for a calm, Minecraft-scale look), each one pulling the next ones' sample point
// toward its crests (a little choppiness, no visible tiling). Slopes and the Laplacian (for caustics) are analytic; waves
// shorter than a few pixels' footprint fade out instead of aliasing (no TAA in M1). Directions, wavelengths, amplitudes:
// our own set, roughly along the wind toward +x+z.
#define SHADE_WAVE_COUNT 7
constant float4 SHADE_WAVES[SHADE_WAVE_COUNT] = {
	//   dir x,  dir z, wavelength, amplitude (blocks)
	float4( 0.920,  0.392, 8.70, 0.060),
	float4( 0.616,  0.788, 5.90, 0.040),
	float4( 0.993, -0.118, 3.70, 0.024),
	float4( 0.309,  0.951, 2.45, 0.015),
	float4( 0.809, -0.588, 1.55, 0.009),
	float4(-0.182,  0.983, 1.00, 0.0055),
	float4( 0.707,  0.707, 0.62, 0.0032),
};
constant float SHADE_WAVE_PHASE[SHADE_WAVE_COUNT] = {0.0, 1.7, 4.1, 2.3, 5.2, 0.6, 3.4};

// The water's animation clock in seconds (ShadeFrame.sunPath.w): real time with mcopt.shade.waterClock (M2.1; smooth even
// when the integrated server lags and resets the game time), else the game time.
static inline float shadeWaterTime(constant ShadeFrame &f) { return f.sunPath.w; }
// An angular speed (rad/s) rounded to a whole number of turns per SHADE_WATER_CLOCK_WRAP seconds (the clock's wrap,
// ShadeFrameUpdater): everything driven by the clock is periodic over the wrap, so the wrap is seamless (changes by < 0.1 %).
#define SHADE_WATER_CLOCK_WRAP 4096.0
static inline float shadeWaterOmega(float w) {
	return rint(w * (SHADE_WATER_CLOCK_WRAP / 6.2831853)) * (6.2831853 / SHADE_WATER_CLOCK_WRAP);
}
// The flowing-water drift speed (blocks/s): 1.40625 x 4096 s = 5760 blocks = 90 wave tiles (seamless wrap along an axis).
#define SHADE_WATER_FLOW_SPEED 1.40625

// Absolute world xz for camera-relative xz, wrapped every 2048 blocks (float precision; the pattern jumps once per 2048
// blocks travelled, at a wrap of the camera's block position).
static inline float2 shadeWaterXZ(float2 rel, constant ShadeFrame &f) {
	return rel + f.cameraFract.xz + fmod(f.cameraBlock.xz, 2048.0);
}

// The baked waves (SHADE_WAVE_BAKE, mcopt.shade.waterBake): the same wave set with its wave vectors snapped to a lattice
// over a SHADE_WAVE_TILE-block tile (so the field tiles), rendered once per frame into a mipmapped RGBA16F texture
// (slope xz, height, Laplacian) by shade_water_bake_fs and sampled once per pixel with hardware mips + anisotropy instead
// of evaluating 7 waves per pixel (the mips replace the footprint LOD: no shimmer far away).
#define SHADE_WAVE_TILE 64.0
constant int2 SHADE_WAVE_LATTICE[SHADE_WAVE_COUNT] = { // wave vector = 2 pi / tile * lattice (wavelengths 8.40 ... 0.62)
	int2(7, 3), int2(7, 9), int2(17, -2), int2(8, 25), int2(33, -24), int2(-12, 63), int2(73, 73),
};
constant int2 SHADE_WAVE_CREST_LATTICE[3] = { int2(-1, 1), int2(-2, 1), int2(0, 4) }; // the crest modulation, on the lattice too
// The bake can afford more waves than the per-pixel path: 7 more, off the main directions and between the main
// wavelengths, so the long crossing trains don't read as a regular diamond lattice in the glitter road.
#define SHADE_WAVE_EXTRA 7
constant int3 SHADE_WAVE_EXTRA_LATTICE[SHADE_WAVE_EXTRA] = { // lattice x, z, amplitude in 1/10000 blocks
	int3(5, -1, 330), int3(-3, 8, 260), int3(10, -10, 180), int3(4, 13, 150), int3(19, 11, 110), int3(-20, 25, 75), int3(45, 20, 50),
};

// speed: the time scale of the whole set (1 for the long waves; the detail layer runs faster, see
// shade_water_bake_detail_fs), phase: added to every wave's phase. Every angular speed is rounded by shadeWaterOmega
// (seamless clock wrap).
static float2 shadeWavesTiled(float2 x, float t, float speed, float phase, thread float &lap, thread float &height, bool extras = true) {
	float2 g = 0.0;
	lap = 0.0;
	height = 0.0;
	const float base = 6.2831853 / SHADE_WAVE_TILE;
#ifdef SHADE_WATER_SMOOTH
	// FT1.3 (style photon): bend the crests with a slow phase warp that still tiles (wave vectors on the lattice; as Photon
	// perturbs its waves' phase with noise, our own code): long straight crests crossing each other read as a regular diamond
	// lattice once the surface is calm enough to mirror (sunset_water, wp2)
	float2 warp = float2(sin(dot(float2(2.0, 1.0) * base, x) + t * shadeWaterOmega(0.05 * speed) + phase),
	                     sin(dot(float2(-1.0, 3.0) * base, x) - t * shadeWaterOmega(0.04 * speed) + 1.3 + phase)) * 1.7
	             + float2(sin(dot(float2(5.0, -3.0) * base, x) + t * shadeWaterOmega(0.09 * speed) + 2.1),
	                      sin(dot(float2(4.0, 6.0) * base, x) - t * shadeWaterOmega(0.07 * speed) + 0.4)) * 0.6;
	x += warp;
#endif
	for (int i = 0; i < SHADE_WAVE_COUNT; i++) {
		float2 kv = float2(SHADE_WAVE_LATTICE[i]) * base;
		float k = length(kv);
		float2 dir = kv / k;
		float a = SHADE_WAVES[i].w * (i == 0 ? 0.75 : i == 1 ? 0.8 : 1.0); // the two longest trains share their energy with the extras
		if (i < 3) a *= 0.55 + 0.45 * sin(dot(float2(SHADE_WAVE_CREST_LATTICE[i]) * base, x) + SHADE_WAVE_PHASE[i] * 2.3 + phase + t * shadeWaterOmega(0.13 * speed));
		float omega = shadeWaterOmega(sqrt(9.81 * k) * 0.62 * speed);
		float th = dot(kv, x) + omega * t + SHADE_WAVE_PHASE[i] + phase;
		float c;
		float s = sincos(th, c);
		float e = exp(s - 1.0);
		g += dir * (a * k * c * e);
		lap += a * k * k * (c * c - s) * e;
		height += a * e;
		x -= dir * (c * e * a * 1.6);
	}
	for (int i = 0; i < (extras ? SHADE_WAVE_EXTRA : 0); i++) {
		int3 l = SHADE_WAVE_EXTRA_LATTICE[i];
		float2 kv = float2(l.xy) * base;
		float k = length(kv);
		float a = float(l.z) * 1e-4;
		float th = dot(kv, x) + shadeWaterOmega(sqrt(9.81 * k) * 0.62 * speed) * t + float(i) * 2.17 + phase;
		float c;
		float s = sincos(th, c);
		float e = exp(s - 1.0);
		g += kv * (a * c * e);
		lap += a * k * k * (c * c - s) * e;
		height += a * e;
	}
	return g;
}

// The bake pass (full-screen triangle into the SHADE_WAVE_BAKE_SIZE^2 wave texture, ShadeWater.bake): ShadeFrame at buffer(16).
#ifndef SHADE_WAVE_BAKE_SIZE
#define SHADE_WAVE_BAKE_SIZE 1024
#endif
fragment half4 shade_water_bake_fs(float4 pos [[position]], constant ShadeFrame &f [[buffer(16)]]) {
	float2 x = pos.xy * (SHADE_WAVE_TILE / float(SHADE_WAVE_BAKE_SIZE));
	float lap, height;
	float2 g = shadeWavesTiled(x, shadeWaterTime(f), 1.0, 0.0, lap, height);
	return half4(half2(g), half(height), half(lap));
}
// M2.1 (SHADE_WATER_DETAIL): the fine-ripple layer, the same set baked into its own texture (texture(22)) with the time
// running SHADE_WATER_DETAIL_SPEED times faster. It is sampled SHADE_WATER_DETAIL_SCALE times smaller, and deep-water
// ripples that are s times shorter move sqrt(s) times faster (omega = sqrt(g k)): sampled from the long waves' texture they
// crawled in slow motion (read as gel). A phase offset decorrelates it from the long layer. Cheaper than the long layer
// (it is baked every frame too): SHADE_WATER_DETAIL_SIZE^2 (256: 13 texels per block once scaled, more than the 1/16-block
// pixel grid needs) and only the 7 main waves (the extras break up the long trains' lattice far away, where the detail
// has faded out).
#define SHADE_WATER_DETAIL_SPEED 1.82
#ifndef SHADE_WATER_DETAIL_SIZE
#define SHADE_WATER_DETAIL_SIZE 256
#endif
fragment half4 shade_water_bake_detail_fs(float4 pos [[position]], constant ShadeFrame &f [[buffer(16)]]) {
	float2 x = pos.xy * (SHADE_WAVE_TILE / float(SHADE_WATER_DETAIL_SIZE));
	float lap, height;
#ifdef SHADE_WATER_DETAIL_EXTRAS
	float2 g = shadeWavesTiled(x, shadeWaterTime(f), SHADE_WATER_DETAIL_SPEED, 2.4, lap, height, true);
#else
	float2 g = shadeWavesTiled(x, shadeWaterTime(f), SHADE_WATER_DETAIL_SPEED, 2.4, lap, height, false);
#endif
	return half4(half2(g), half(height), half(lap));
}
constexpr sampler shadeWaveSampler(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(8));

// Slope (dh/dx, dh/dz) of the surface at absolute xz; lap = the height's Laplacian, height = h. strength scales the
// amplitudes; footprint: blocks per pixel (wave LOD), 0 for none.
static float2 shadeWaves(float2 x, float t, float strength, float footprint, thread float &lap, thread float &height) {
	float2 g = 0.0;
	lap = 0.0;
	height = 0.0;
	for (int i = 0; i < SHADE_WAVE_COUNT; i++) {
		float4 w = SHADE_WAVES[i];
		float lod = saturate(w.z / max(footprint * 3.0, 1e-4) - 1.0);
		float k = 6.2831853 / w.z;
		float a = w.w * strength * lod;
		if (a * k < 2e-4) continue; // its slope would not show (far away: the strength fades with distance)
		// short-crested: the 3 longest waves' amplitude swells and fades along their crests (crests ~5 wavelengths long,
		// drifting slowly), so they don't interfere into a regular lattice in the distance (the glitter road), where the
		// shorter waves have faded out (LOD) anyway
		if (i < 3) a *= 0.55 + 0.45 * sin(k * 0.21 * dot(float2(-w.y, w.x), x) + SHADE_WAVE_PHASE[i] * 2.3 + t * shadeWaterOmega(0.13));
		float omega = shadeWaterOmega(sqrt(9.81 * k) * 0.62);
		float th = k * dot(w.xy, x) + omega * t + SHADE_WAVE_PHASE[i];
		float c;
		float s = sincos(th, c);
		float e = exp(s - 1.0);
		float dh = a * k * c * e;            // slope along the wave's direction
		g += w.xy * dh;
		lap += a * k * k * (c * c - s) * e;
		height += a * e;
		x -= w.xy * (c * e * a * 1.6);       // pull the next waves toward this one's crests
	}
	return g;
}

// ---- screen-space reflections -----------------------------------------------------------------------------------------------
// March a world-space ray (from p0 along unit r, at most maxDist blocks) in screen space against the depth copy: clip-space
// end points (the far one pulled in front of the camera), the segment clipped to the screen, steps spaced denser near the
// start (contact reflections matter most), then 4 bisection steps on the first crossing behind the depth buffer and a
// thickness test in linear depth, so thin things in front of a far background don't smear into long streaks. A crossing
// that fails the thickness test keeps marching (the ray passed behind something). The march costs no more for a longer
// ray: it is in screen space, so distant shores mirror in open water as cheaply as the trees next to it.
//
// Quad-shared (SHADE_SSR_QUAD, the default): the 4 pixels of a 2x2 quad trace ONE ray (their average origin and
// direction) together, each lane marching its own quarter of the segment with a quarter of the steps; the nearest hit
// among the lanes wins and all four take it (quad shuffles). Half-resolution SSR at a quarter of the cost, without a
// separate pass or target; at Retina density, and under the waves' wobble, the 2x2 blocks don't show. Callers must reach it
// in quad-uniform control flow (the water branch is: one triangle per quad, the sprite test is made quad-uniform).

// The setup shared by both variants: screen-space start s0 and extent ds (NDC xy, depth z), false when there is nothing to
// march (the ray starts behind the camera or leaves the screen at once). screenEnd: the segment ends at a screen edge.
static inline bool shadeSsrSegment(float3 p0, float3 r, float maxDist, constant ShadeFrame &f, thread float3 &s0, thread float3 &ds,
                                   thread bool &screenEnd) {
	float4 c0 = f.viewProj * float4(p0, 1.0);
	float4 dc = f.viewProj * float4(r, 0.0);
	float len = maxDist;
	if (dc.w < 0.0) len = min(len, (c0.w - 0.1) / -dc.w * 0.95);
	if (len <= 0.05 || c0.w <= 0.05) return false;
	float4 c1 = c0 + dc * len;
	s0 = c0.xyz / c0.w;
	float3 s1 = c1.xyz / c1.w;
	float2 d = s1.xy - s0.xy;
#ifdef SHADE_SSR_EDGE
	// M2.1: only the top and bottom edges end the segment. Past a side edge the march goes on against the edge column (the
	// reads are clamped), which stands in for what is just off screen: a shore or a tree line that leaves the screen at the
	// side keeps mirroring out to the screen edge instead of fading into the sky fallback (M2's cut-off reflections).
	// 1.2.7 (audit B3b): the top edge too, a little past it against the top row (SHADE_SSR_TOP): a shore hill or a tree line that
	// rises past the top of the screen mirrored as white sky (the cloud dome) right where the rays reached the top edge
	const float side = 1.0 + SHADE_SSR_SIDE, top = 1.0 + SHADE_SSR_TOP;
#else
	const float side = 1.0, top = 1.0;
#endif
	float tx = d.x > 1e-6 ? (side - s0.x) / d.x : d.x < -1e-6 ? (-side - s0.x) / d.x : 1e6;
	float ty = d.y > 1e-6 ? (top - s0.y) / d.y : d.y < -1e-6 ? (-1.0 - s0.y) / d.y : 1e6;
	float tEnd = min(1.0, min(tx, ty));
	if (tEnd <= 0.0) return false;
	screenEnd = tEnd < 1.0;
	ds = (s1 - s0) * tEnd;
	return true;
}

// Marches chunk `chunk` of `chunks` equal parts of the step sequence (N steps in it; jitter in [0, 1) shifts them) and
// returns the first hit in it: (uv over the rendered rect, fade, segment parameter), or w < 0 for none. All N depth reads
// are issued before any test (independent loads in flight together: the march is latency-bound, an early exit per step
// serialized them), then the first crossing that passes the thickness test is refined by 4 bisection steps.
#ifdef SHADE_SSR_QUAD
#define SHADE_SSR_N (SHADE_SSR_STEPS / 4 > 2 ? SHADE_SSR_STEPS / 4 : 2)
#else
#define SHADE_SSR_N SHADE_SSR_STEPS
#endif
// (only in the variant for the camera above water, like the other 2026-10-08 savings: price6 found the full variant 1.5 ms slower)
#if defined(SHADE_SSR_RAWZ) && !defined(SHADE_SSR_NORAWZ) && defined(SHADE_LEAN_ABOVE) // (NORAWZ: -Dmcopt.shade.leanDev=SHADE_SSR_NORAWZ, in-session A/B)
// 2026-10-08 (mcopt.shade.water.rawz, default on): the same march deciding in reversed-Z depth itself. View depth is
// w = B / (z + A), decreasing in z, so "the ray is still in front of the scene" (w_ray < w_scene) is z_ray > z_scene, sky
// (z 0) included, and the crossing tests need no division per step (nor the steps' parameters kept in an array). Only the
// thickness test of the found crossing works in blocks. Same decisions as the old march, fewer registers in the water shader.
static inline float shadeSsrZ(depth2d<float> depth, float3 s, float2 size) {
	return depth.read(uint2(clamp((s.xy * 0.5 + 0.5) * size, float2(0.0), size - 1.0)));
}
static inline float shadeSsrT(float u) { return u * (0.35 + 0.65 * u); }
static float4 shadeSsrMarch(float3 s0, float3 ds, bool screenEnd, int chunk, int chunks, float jitter, constant ShadeFrame &f,
                            depth2d<float> depth, texture2d<float> hz) {
	float2 size = shadeWaterRenderSize(f, float2(depth.get_width(), depth.get_height()));
	float A = f.proj[2][2], B = f.proj[3][2];
	const int n = SHADE_SSR_N;
	float inv = 1.0 / float(n * chunks);
	float base = float(chunk * n) - jitter;
	float zs[SHADE_SSR_N + 1];
	for (int i = 1; i <= n; i++) {
		float3 s = s0 + ds * shadeSsrT((base + float(i)) * inv);
		zs[i] = hz.read(uint2(clamp((s.xy * 0.5 + 0.5) * size, float2(0.0), size - 1.0)) >> 1).r;
	}
	// FT2.6 (Gael's FT2.5 lake: white blocks in the mirrored forest): a ray that passed behind the trees' trunks and leaves failed
	// the thickness test there, marched on into the sky above them and found nothing, so the water took the sky (the clouds'
	// dome, bright white) where it should mirror the dark forest. thickK: the thickness allows this many times the step's own
	// depth extent (Photon MIT 26c2906e allows 3 steps' depth); behind: with no hit, the first crossing behind something stands
	// for what the ray met there (marked w + 10, after any real hit of the quad)
	float thickK = SHADE_SSR_THICK_K;
	bool behind = SHADE_SSR_BEHIND != 0;
	if (SHADE_WDEV_IS(f, SHADE_WDEV_SSR_OLD)) { thickK = 1.0; behind = false; }
	if (SHADE_WDEV_IS(f, SHADE_WDEV_SSR_THICK)) { thickK = 3.0; behind = false; }
	if (SHADE_WDEV_IS(f, SHADE_WDEV_SSR_BEHIND)) { thickK = 1.0; behind = true; }
	if (SHADE_WDEV_IS(f, SHADE_WDEV_SSR_BOTH)) { thickK = 3.0; behind = true; }
#ifdef SHADE_SSR_LEAN2
	// (FT2.8, audit idx 58, mcopt.shade.water.ssrLean, default on) only the fallback's crossing is kept through the loop, not a float4 (the loop is
	// the register-bound part of the water shader); its uv and fades are rebuilt after it from the same expressions
	float hiBack = -1.0;
#else
	float4 back = float4(0.0, 0.0, 0.0, -1.0);
#endif
	for (int i = 1; i <= n; i++) {
		float hi = shadeSsrT((base + float(i)) * inv);
		if (s0.z + ds.z * hi > zs[i]) continue; // still in front of what the coarse depth holds there
		float lo = shadeSsrT(max(base + float(i - 1), 0.0) * inv);
		float tPrev = lo;
#ifdef SHADE_SSR_LEAN2
		// (FT2.8, audit idx 57) the 4 bisection steps as 2 rounds of 3 reads issued together (the second step's midpoint is one of
		// two known ones): the same midpoints and decisions, half the dependent reads; the depth at the final hi is reused
		float zHi = -1.0;
		for (int j = 0; j < 2; j++) {
			float m1 = 0.5 * (lo + hi), ma = 0.5 * (lo + m1), mb = 0.5 * (m1 + hi);
			float3 s1 = s0 + ds * m1, sa = s0 + ds * ma, sb = s0 + ds * mb;
			float z1 = shadeSsrZ(depth, s1, size), za = shadeSsrZ(depth, sa, size), zb = shadeSsrZ(depth, sb, size);
			if (s1.z <= z1) {
				hi = m1;
				zHi = z1;
				if (sa.z <= za) { hi = ma; zHi = za; } else lo = ma;
			} else {
				lo = m1;
				if (sb.z <= zb) { hi = mb; zHi = zb; } else lo = mb;
			}
		}
		float3 sh = s0 + ds * hi;
		float2 uv = sh.xy * 0.5 + 0.5;
		float zh = zHi >= 0.0 ? zHi : shadeSsrZ(depth, sh, size);
#else
		for (int j = 0; j < 4; j++) {
			float m = 0.5 * (lo + hi);
			float3 sm = s0 + ds * m;
			if (sm.z <= shadeSsrZ(depth, sm, size)) hi = m; else lo = m;
		}
		float3 sh = s0 + ds * hi;
		float2 uv = sh.xy * 0.5 + 0.5;
		float zh = shadeSsrZ(depth, sh, size);
#endif
		// 1.2.7 (audit B1, Gael's white streaks next to shore grass): the coarse depth is the nearest of a 2x2 block, so the step
		// can find a "crossing" that the full-resolution depth says the ray never reached (still in front of it). The thickness
		// test below has no lower bound and took it at full weight: a false hit on the lake bottom or a far pixel, which won the
		// quad's nearest-hit vote and then failed shadeSsrBelowStart, so the whole quad mirrored the white sky. No crossing here.
		if (sh.z > zh) continue;
		float wh = zh > 0.0 ? B / max(zh + A, 1e-7) : SHADE_WATER_SKY_W;
		float wr = B / max(sh.z + A, 1e-7);
		float wp = B / max(s0.z + ds.z * tPrev + A, 1e-7);
		float thick = 0.3 + 0.02 * wh + abs(wr - wp) * thickK;
		if (wh < SHADE_WATER_SKY_W && wr - wh < thick) {
#ifdef SHADE_SSR_EDGE
			// past a side or (1.2.7, B3b) the top the edge column / row stands in, trusted less the further out; near the bottom
			// edge the hit still fades. 1.2.7 (B3a): with `behind` the crossing just past the thickness comes back at full weight
			// (below), so fading a grazing hit toward the bright sky first only drew a light ring around mirrored silhouettes.
			float off = abs(sh.x) - 1.0, offT = sh.y - 1.0;
			float fade = smoothstep(0.0, 0.07, uv.y) * mix(1.0, SHADE_SSR_SIDE_END, saturate(off / SHADE_SSR_SIDE) * saturate(off / SHADE_SSR_SIDE)) * (1.0 - smoothstep(0.0, SHADE_SSR_TOP, offT));
			fade *= mix(1.0, saturate((wh / max(wr, 1e-3) - 0.5) * 4.0), saturate(max(off, offT) * 20.0));
			if (!behind) fade *= 1.0 - smoothstep(0.6, 1.0, (wr - wh) / thick); // grazing passes fade, not pop
			uv.x = clamp(uv.x, 0.5 / size.x, 1.0 - 0.5 / size.x);
			uv.y = min(uv.y, 1.0 - 0.5 / size.y);
			if (!screenEnd) fade *= 1.0 - smoothstep(0.85, 1.0, wr / max(B / max(s0.z + ds.z + A, 1e-7), 1e-3));
#else
			float2 edge = smoothstep(0.0, 0.07, min(uv, 1.0 - uv));
			float fade = edge.x * edge.y * (1.0 - smoothstep(0.6, 1.0, (wr - wh) / thick)); // grazing passes fade, not pop
			if (!screenEnd) fade *= 1.0 - smoothstep(0.75, 1.0, hi);
#endif
			return float4(uv, fade, hi);
		}
		// the ray passed behind something thin: keep marching
		// (FT2.6.1, audit idx 32/56: only an occluder beyond the reflecting point, with the fades real hits get: past a side, an edge
		// column much nearer than the ray fades out (no sideways smear of a trunk at the screen edge), and the far end fades)
#ifdef SHADE_SSR_LEAN2
		if (behind && hiBack < 0.0 && wh < SHADE_WATER_SKY_W && wh > B / max(s0.z + A, 1e-7)) hiBack = hi;
	}
	if (hiBack < 0.0) return float4(0.0, 0.0, 0.0, -1.0);
	float3 sh = s0 + ds * hiBack;
	float2 uv = sh.xy * 0.5 + 0.5;
	float zh = shadeSsrZ(depth, sh, size);
	float wh = zh > 0.0 ? B / max(zh + A, 1e-7) : SHADE_WATER_SKY_W;
	float wr = B / max(sh.z + A, 1e-7);
	float off = abs(sh.x) - 1.0, offT = sh.y - 1.0;
	float bf = smoothstep(0.0, 0.07, uv.y) * mix(1.0, SHADE_SSR_SIDE_END, saturate(off / SHADE_SSR_SIDE) * saturate(off / SHADE_SSR_SIDE)) * (1.0 - smoothstep(0.0, SHADE_SSR_TOP, offT));
	bf *= mix(1.0, saturate((wh / max(wr, 1e-3) - 0.5) * 4.0), saturate(max(off, offT) * 20.0));
	if (!screenEnd) bf *= 1.0 - smoothstep(0.85, 1.0, wr / max(B / max(s0.z + ds.z + A, 1e-7), 1e-3));
	return float4(clamp(uv.x, 0.5 / size.x, 1.0 - 0.5 / size.x), min(uv.y, 1.0 - 0.5 / size.y), bf, hiBack + 10.0);
#else
		if (behind && back.w < 0.0 && wh < SHADE_WATER_SKY_W && wh > B / max(s0.z + A, 1e-7)) {
			float off = abs(sh.x) - 1.0;
			float bf = smoothstep(0.0, 0.07, min(uv.y, 1.0 - uv.y)) * mix(1.0, SHADE_SSR_SIDE_END, saturate(off / SHADE_SSR_SIDE) * saturate(off / SHADE_SSR_SIDE));
			bf *= mix(1.0, saturate((wh / max(wr, 1e-3) - 0.5) * 4.0), saturate(off * 20.0));
			if (!screenEnd) bf *= 1.0 - smoothstep(0.85, 1.0, wr / max(B / max(s0.z + ds.z + A, 1e-7), 1e-3));
			back = float4(clamp(uv.x, 0.5 / size.x, 1.0 - 0.5 / size.x), uv.y, bf, hi + 10.0);
		}
	}
	return back;
#endif
}
#else
static float4 shadeSsrMarch(float3 s0, float3 ds, bool screenEnd, int chunk, int chunks, float jitter, constant ShadeFrame &f,
                            depth2d<float> depth, texture2d<float> hz) {
	float2 size = shadeWaterRenderSize(f, float2(depth.get_width(), depth.get_height()));
	float A = f.proj[2][2], B = f.proj[3][2];
	const int n = SHADE_SSR_N;
	float inv = 1.0 / float(n * chunks);
	float u0 = max(float(chunk * n) - jitter, 0.0) * inv;
	float ts[SHADE_SSR_N + 1], ws[SHADE_SSR_N + 1];
	ts[0] = u0 * (0.35 + 0.65 * u0);
	ws[0] = 0.0;
	for (int i = 1; i <= n; i++) {
		float u = (float(chunk * n + i) - jitter) * inv;
		ts[i] = u * (0.35 + 0.65 * u);
		float3 s = s0 + ds * ts[i];
		ws[i] = shadeWaterCoarseW(hz, uint2(clamp((s.xy * 0.5 + 0.5) * size, float2(0.0), size - 1.0)), f);
	}
	for (int i = 1; i <= n; i++) {
		// NDC depth is affine in 1/w along the screen segment, so the ray's view depth at any step is B / (z + A)
		if (B / max(s0.z + ds.z * ts[i] + A, 1e-7) < ws[i]) continue; // still in front of what the depth copy holds there
		float lo = ts[i - 1], hi = ts[i];
		for (int j = 0; j < 4; j++) {
			float m = 0.5 * (lo + hi);
			float3 sm = s0 + ds * m;
			float wm = shadeWaterSceneW(depth, uint2(clamp((sm.xy * 0.5 + 0.5) * size, float2(0.0), size - 1.0)), f);
			if (B / max(sm.z + A, 1e-7) >= wm) hi = m; else lo = m;
		}
		float3 sh = s0 + ds * hi;
		float2 uv = sh.xy * 0.5 + 0.5;
		float wh = shadeWaterSceneW(depth, uint2(clamp(uv * size, float2(0.0), size - 1.0)), f);
		float wr = B / max(sh.z + A, 1e-7);
		if (wr < wh) continue; // (1.2.7, audit B1: as in the raw-z march, a crossing the full-resolution depth never saw)
		float wp = B / max(s0.z + ds.z * ts[i - 1] + A, 1e-7);
		float thick = 0.3 + 0.02 * wh + abs(wr - wp);
		if (wh < SHADE_WATER_SKY_W && wr - wh < thick) {
#ifdef SHADE_SSR_EDGE
			// no fade at the sides (the edge column continues them) nor (1.2.7, B3b) past the top (the top row); past a side
			// or the top the hit is the edge column / row, trusted less the further off screen the ray went (x0.5 at the
			// segment's end, NDC +-2); the far-end fade goes by distance (M2 faded by screen length: with 512-block rays a shore
			// 100-200 blocks away lost half its reflection)
			float off = abs(sh.x) - 1.0, offT = sh.y - 1.0;
			float fade = smoothstep(0.0, 0.07, uv.y) * mix(1.0, SHADE_SSR_SIDE_END, saturate(off / SHADE_SSR_SIDE) * saturate(off / SHADE_SSR_SIDE)) * (1.0 - smoothstep(0.0, SHADE_SSR_TOP, offT));
			// past a side the steps are long and the thickness test lets almost any crossing through: an edge column much
			// NEARER than the ray (a tree trunk, a shore block at the screen edge) is not what the ray would hit off screen,
			// and would smear sideways into the reflection (and flicker as things enter the edge): faded out
			fade *= mix(1.0, saturate((wh / max(wr, 1e-3) - 0.5) * 4.0), saturate(max(off, offT) * 20.0));
			fade *= 1.0 - smoothstep(0.6, 1.0, (wr - wh) / thick); // grazing passes fade, not pop
			uv.x = clamp(uv.x, 0.5 / size.x, 1.0 - 0.5 / size.x);
			uv.y = min(uv.y, 1.0 - 0.5 / size.y);
			if (!screenEnd) fade *= 1.0 - smoothstep(0.85, 1.0, wr / max(B / max(s0.z + ds.z + A, 1e-7), 1e-3));
#else
			float2 edge = smoothstep(0.0, 0.07, min(uv, 1.0 - uv));
			float fade = edge.x * edge.y * (1.0 - smoothstep(0.6, 1.0, (wr - wh) / thick)); // grazing passes fade, not pop
			if (!screenEnd) fade *= 1.0 - smoothstep(0.75, 1.0, hi);
#endif
			return float4(uv, fade, hi);
		}
		// the ray passed behind something thin: keep marching
	}
	return float4(0.0, 0.0, 0.0, -1.0);
}

#endif

// Quad reductions by xor shuffles (independent of how the hardware numbers the lanes).
static inline float shadeQuadSum(float v) { v += quad_shuffle_xor(v, 1); return v + quad_shuffle_xor(v, 2); }
static inline float3 shadeQuadSum(float3 v) { v += quad_shuffle_xor(v, 1); return v + quad_shuffle_xor(v, 2); }
static inline float shadeQuadMin(float v) { v = min(v, quad_shuffle_xor(v, 1)); return min(v, quad_shuffle_xor(v, 2)); }
static inline float shadeQuadMax(float v) { v = max(v, quad_shuffle_xor(v, 1)); return max(v, quad_shuffle_xor(v, 2)); }
static inline float4 shadeQuadSum(float4 v) { v += quad_shuffle_xor(v, 1); return v + quad_shuffle_xor(v, 2); }
static inline uint shadeQuadOr(uint v) { v |= quad_shuffle_xor(v, 1); return v | quad_shuffle_xor(v, 2); }

#ifdef SHADE_SSR_HIER
// ---- the exact march (1.2.7 candidate 8) --------------------------------------------------------------------------------------
// Gael (candidate 7, 2026-11-09): "en el reflejo de los árboles y en el reflejo de esta casita de la aldea se puede ver como un
// flickering". The march above takes 16-32 steps along a ray that crosses up to the whole screen, shifted by a different jitter
// every frame: whatever stands between two steps (a tree's crown in front of a far forest, a roof in front of the sky) is found in
// one frame and stepped over in the next, so its mirrored image is a per-frame coin toss between it and what is behind it, in 2x2
// blocks, that the TAA can only average while nothing moves. The temporal fixes of candidate 7 filtered that noise; this march
// doesn't make it. Every pixel traces its own ray to the pixel: the ray's screen segment is cut into up to SHADE_SSRH_N0 intervals
// of at most 128 pixels, those into 8 of at most 16, those into 8 of at most 2, and an interval is only opened where the ray's
// depth range over it overlaps the scene's depth range around it, read from a small pyramid of the depth copy (texture(21) in
// this mode: per 16x16 and per 128x128 pixel block the nearest and the farthest depth, shade_water_pyr_fs). Where the ray is in
// front of everything around an interval, or (already behind something) behind everything, nothing in it can be a crossing: the
// reads of one level are issued together, as in the march above. The 2-pixel samples are read from the depth copy itself; a
// crossing between two of them on one surface is placed by their secant (exact for a plane: depth is affine on screen). No
// jitter: the same view gives the same image, and a moving view moves it coherently.
#ifndef SHADE_SSRH_THICK
// What a crossing may be behind the surface it enters and still count as a hit on it (blocks, + 3 % of its distance + the ray's
// own depth step x SHADE_SSR_THICK_K): the depth copy holds one layer, and a crown or a house is not a sheet. The coarse march
// allowed its whole step (tens of blocks); farther behind than this the ray passes behind it and goes on, and where it then finds
// nothing the first such crossing stands in (SHADE_SSR_BEHIND).
#define SHADE_SSRH_THICK 2.0
#endif
#ifndef SHADE_SSRH_BUDGET
#define SHADE_SSRH_BUDGET 8 // the 16-pixel intervals a ray may open (9 reads of the depth copy each) before it gives up
#endif
#define SHADE_SSRH_N0 20      // the 128-pixel intervals at most (rays longer than 2560 pixels get longer ones)

// The pyramid (texture(21) in this mode, RG16F: r the nearest = largest reversed-Z, g the farthest; mcwater.m): for a depth copy
// of W x H, the 16-pixel blocks at (0, 0), ceil(W / 16) by bh = ceil(H / 16) texels, and the 128-pixel blocks at (0, bh). Each
// block's value is taken over the block AND half a block around it, so the one texel a point falls in bounds everything within
// half a block of that point: one read per interval (two 2x2 gathers of plain blocks cost 0.6 ms more over a lake, price-2
// 2026-11-09). Made in two passes: shade_water_pyr_fs, the plain 8-pixel blocks from the depth copy (RG16F, its own texture);
// shade_water_pyr2_fs, both block sizes from those. Halves are rounded to the safe side (nearest up, farthest down: by 2^-10
// and one subnormal step), a block of sky alone stays exactly 0.
// (A third channel, the highest world y per block, to skip blocks wholly below the reflecting water, was tried: on the dumped
// pond and sea frames it saved 5-8 % of the opened intervals for one more read per interval, sim.py 2026-11-09.)
struct ShadeSsrPyrBuild {
	int4 a; // x the block's size in 8-pixel blocks (2 or 16), yz the region's origin in the target, w how far around it (1 or 8)
	int4 b; // xy the source's valid size: the depth's rendered rect (pixels), or the 8-pixel blocks that cover it
};
fragment float4 shade_water_pyr_fs(float4 pos [[position]], depth2d<float> d [[texture(0)]], constant ShadeSsrPyrBuild &u [[buffer(0)]]) {
	constexpr sampler g(coord::normalized, filter::nearest, address::clamp_to_edge);
	int2 valid = max(u.b.xy, int2(2));
	int2 lo = min(int2(pos.xy) * 8, valid - 1), hi = min(lo + 7, valid - 1);
	float2 inv = 1.0 / float2(d.get_width(), d.get_height());
	float zn = 0.0, zf = 1.0;
	for (int y = lo.y; y <= hi.y; y += 2) {
		int gy = min(y, valid.y - 2);
		for (int x = lo.x; x <= hi.x; x += 2) {
			float4 z = d.gather(g, (float2(float(min(x, valid.x - 2)), float(gy)) + 1.0) * inv);
			zn = max(zn, max(max(z.x, z.y), max(z.z, z.w)));
			zf = min(zf, min(min(z.x, z.y), min(z.z, z.w)));
		}
	}
	return float4(zn > 0.0 ? zn * (1.0 + 1.0 / 1024.0) + 6.0e-8 : 0.0, max(zf * (1.0 - 1.0 / 1024.0) - 6.0e-8, 0.0), 0.0, 0.0);
}
fragment float4 shade_water_pyr2_fs(float4 pos [[position]], texture2d<float> b [[texture(0)]], constant ShadeSsrPyrBuild &u [[buffer(0)]]) {
	int2 valid = max(u.b.xy, int2(1));
	int2 t = int2(pos.xy) - u.a.yz;
	int2 lo = clamp(t * u.a.x - u.a.w, int2(0), valid - 1), hi = clamp(t * u.a.x + (u.a.x - 1 + u.a.w), int2(0), valid - 1);
	float2 o = float2(0.0, 1.0);
	for (int y = lo.y; y <= hi.y; y++) {
		for (int x = lo.x; x <= hi.x; x++) {
			float2 v = b.read(uint2(x, y)).xy;
			o = float2(max(o.x, v.x), min(o.y, v.y));
		}
	}
	return float4(o, 0.0, 0.0);
}

// (nearest reversed-Z, farthest) of everything within half a 16- / 128-pixel block of pixel px (inside the rendered rect); row: the
// 128-pixel blocks' first row in the texture
static inline float2 shadeSsrhRange16(texture2d<float> pyr, float2 px) { return pyr.read(uint2(px) >> 4u).xy; }
static inline float2 shadeSsrhRange128(texture2d<float> pyr, float2 px, uint row) { return pyr.read((uint2(px) >> 7u) + uint2(0u, row)).xy; }

// The camera-relative world y of the depth copy's value z at pixel position px of the rendered rect
static inline float shadeSsrhY(float2 px, float z, float2 size, constant ShadeFrame &f) {
	float4 v = float4((floor(clamp(px, float2(0.0), size - 1.0)) + 0.5) / size * 2.0 - 1.0, z, 1.0);
	return dot(float4(f.invViewProj[0].y, f.invViewProj[1].y, f.invViewProj[2].y, f.invViewProj[3].y), v)
		/ dot(float4(f.invViewProj[0].w, f.invViewProj[1].w, f.invViewProj[2].w, f.invViewProj[3].w), v);
}

// The hit of the screen segment s0 + ds t, t in 0..1 (shadeSsrSegment): (uv over the rendered rect, fade, t), w < 0 for none.
// yFloor: nothing below this camera-relative height can be hit (a ray that rises from a surface: that surface's height - 0.3;
// -1e30 for none; FT1.2's shadeSsrBelowStart, tested at each crossing).
#ifdef SHADE_SSRH_DEBUG
#define SHADE_SSRH_COUNT(c) (shadeSsrhDebug.c += 1.0)
#else
#define SHADE_SSRH_COUNT(c)
#endif
static float4 shadeSsrTrace(float3 s0, float3 ds, bool screenEnd, float yFloor, constant ShadeFrame &f, depth2d<float> depth, texture2d<float> pyr
#ifdef SHADE_SSRH_DEBUG
                            , thread float3 &shadeSsrhDebug // (mcopt.shade.water.ssrExactDebug) x 16-pixel intervals opened, y 128-pixel ones, z 1 = out of budget
#endif
                            ) {
	float2 tex = float2(depth.get_width(), depth.get_height());
	float2 size = shadeWaterRenderSize(f, tex);
	float A = f.proj[2][2], B = f.proj[3][2];
	float2 a = (s0.xy * 0.5 + 0.5) * size, d = ds.xy * 0.5 * size; // the ray in pixels: a + d t
	float2 top = size - 1.0;
	int n0 = clamp(int(ceil(length(d) * (1.0 / 128.0))), 1, SHADE_SSRH_N0);
	uint org = uint((int(tex.y) + 15) / 16); // the 128-pixel blocks' first row
	float inv0 = 1.0 / float(n0), inv1 = inv0 * 0.125, inv2 = inv1 * 0.125;
	float wStart = B / max(s0.z + A, 1e-7);
	bool behind = SHADE_SSR_BEHIND != 0;
	bool front = true; // the ray is in front of the scene where the walk stands
	float tBack = -1.0;
	int budget = SHADE_SSRH_BUDGET;
	for (int i = 0; i < n0 && budget > 0; i++) {
		float ta = float(i) * inv0;
		float za = s0.z + ds.z * ta, zb = za + ds.z * inv0;
		float2 r0 = shadeSsrhRange128(pyr, clamp(a + d * (ta + 0.5 * inv0), float2(0.0), top), org);
		if (min(za, zb) > r0.x || r0.x <= 0.0) { front = true; continue; } // in front of everything around it
		if (!front && max(za, zb) < r0.y) continue;          // still behind everything around it
		SHADE_SSRH_COUNT(y);
		float2 r1[8];
		for (int j = 0; j < 8; j++) r1[j] = shadeSsrhRange16(pyr, clamp(a + d * (ta + (float(j) + 0.5) * inv1), float2(0.0), top));
		for (int j = 0; j < 8 && budget > 0; j++) {
			float t1 = ta + float(j) * inv1;
			float z1a = s0.z + ds.z * t1, z1b = z1a + ds.z * inv1;
			if (min(z1a, z1b) > r1[j].x || r1[j].x <= 0.0) { front = true; continue; }
			if (!front && max(z1a, z1b) < r1[j].y) continue;
			budget--;
			SHADE_SSRH_COUNT(x);
			float zs[9];
			for (int k = 0; k < 9; k++) zs[k] = depth.read(uint2(clamp(a + d * (t1 + float(k) * inv2), float2(0.0), top)));
			for (int k = 0; k < 9; k++) {
				float t = t1 + float(k) * inv2;
				float zr = s0.z + ds.z * t;
				bool fr = zr > zs[k];
				// (never the sky: a ray that outruns the far plane is "behind" depth 0)
				if (front && !fr && zs[k] > 0.0 && shadeSsrhY(a + d * t, zs[k], size, f) >= yFloor) { // the ray went from in front of the scene to behind it since the last sample
					float wh = B / max(zs[k] + A, 1e-7), wr = B / max(zr + A, 1e-7);
					float thick = SHADE_SSRH_THICK + 0.03 * wh + abs(wr - B / max(zr - ds.z * inv2 + A, 1e-7)) * SHADE_SSR_THICK_K;
					if (wr - wh < thick) {
						float tH = t;
						if (k > 0 && zs[k - 1] > 0.0 && abs(B / max(zs[k - 1] + A, 1e-7) - wh) < thick) {
							float dA = zr - ds.z * inv2 - zs[k - 1], dB = zs[k] - zr; // in front by dA at the last sample, behind by dB here
							tH = t - inv2 * dB / max(dA + dB, 1e-12);
						}
						float3 sh = s0 + ds * tH;
						float2 uv = sh.xy * 0.5 + 0.5;
#ifdef SHADE_SSR_EDGE
						float off = abs(sh.x) - 1.0, offT = sh.y - 1.0;
						float fade = smoothstep(0.0, 0.07, uv.y) * mix(1.0, SHADE_SSR_SIDE_END, saturate(off / SHADE_SSR_SIDE) * saturate(off / SHADE_SSR_SIDE)) * (1.0 - smoothstep(0.0, SHADE_SSR_TOP, offT));
						fade *= mix(1.0, saturate((wh / max(wr, 1e-3) - 0.5) * 4.0), saturate(max(off, offT) * 20.0));
						if (!behind) fade *= 1.0 - smoothstep(0.6, 1.0, (wr - wh) / thick);
						uv.x = clamp(uv.x, 0.5 / size.x, 1.0 - 0.5 / size.x);
						uv.y = min(uv.y, 1.0 - 0.5 / size.y);
						if (!screenEnd) fade *= 1.0 - smoothstep(0.85, 1.0, wr / max(B / max(s0.z + ds.z + A, 1e-7), 1e-3));
#else
						float2 edge = smoothstep(0.0, 0.07, min(uv, 1.0 - uv));
						float fade = edge.x * edge.y * (1.0 - smoothstep(0.6, 1.0, (wr - wh) / thick));
						if (!screenEnd) fade *= 1.0 - smoothstep(0.75, 1.0, tH);
#endif
						return float4(uv, fade, tH);
					}
					// it passed behind something: on, and the first such thing beyond the reflecting point stands in if nothing is hit
					if (behind && tBack < 0.0 && wh > wStart) tBack = t;
				}
				front = fr;
			}
		}
	}
#ifdef SHADE_SSRH_DEBUG
	if (budget <= 0) shadeSsrhDebug.z = 1.0;
#endif
	if (tBack < 0.0) return float4(0.0, 0.0, 0.0, -1.0);
	float3 sh = s0 + ds * tBack;
	float2 uv = sh.xy * 0.5 + 0.5;
	float zh = depth.read(uint2(clamp(a + d * tBack, float2(0.0), top)));
	float wh = zh > 0.0 ? B / max(zh + A, 1e-7) : SHADE_WATER_SKY_W;
	float wr = B / max(sh.z + A, 1e-7);
	float off = abs(sh.x) - 1.0, offT = sh.y - 1.0;
	float bf = smoothstep(0.0, 0.07, uv.y) * mix(1.0, SHADE_SSR_SIDE_END, saturate(off / SHADE_SSR_SIDE) * saturate(off / SHADE_SSR_SIDE)) * (1.0 - smoothstep(0.0, SHADE_SSR_TOP, offT));
	bf *= mix(1.0, saturate((wh / max(wr, 1e-3) - 0.5) * 4.0), saturate(max(off, offT) * 20.0));
	if (!screenEnd) bf *= 1.0 - smoothstep(0.85, 1.0, wr / max(B / max(s0.z + ds.z + A, 1e-7), 1e-3));
	return float4(clamp(uv.x, 0.5 / size.x, 1.0 - 0.5 / size.x), min(uv.y, 1.0 - 0.5 / size.y), bf, tBack);
}

#ifdef SHADE_SSR_QUAD
// The same march by the 4 pixels of a 2x2 quad together (the default: the per-pixel march above cost +1.5 ms over a lake, a
// quarter of that here): they trace ONE ray (the quad's mean), each lane c doing a quarter of every level's reads (the intervals
// and samples with index = c mod 4), sharing what it found as bit masks (1 bit per interval: in front / behind; per sample: behind)
// through quad shuffles; the walk over the masks is the same in the four lanes (so every lane takes every branch around a
// shuffle together). 12 depth samples per 16-pixel interval instead of 9 (3 per lane; 1.5 pixels apart). Returns the shared hit
// (w + 10 for a crossing behind something standing in: it is not on the ray); each pixel then reads it along its own ray
// (shadeSsrT). Must be called by all four lanes with the same ray.
static float4 shadeSsrTraceQuad(float3 s0, float3 ds, bool screenEnd, float yFloor, int c, constant ShadeFrame &f, depth2d<float> depth, texture2d<float> pyr) {
	float2 tex = float2(depth.get_width(), depth.get_height());
	float2 size = shadeWaterRenderSize(f, tex);
	float A = f.proj[2][2], B = f.proj[3][2];
	float2 a = (s0.xy * 0.5 + 0.5) * size, d = ds.xy * 0.5 * size; // the ray in pixels: a + d t
	float2 top = size - 1.0;
	int n0 = clamp(int(ceil(length(d) * (1.0 / 128.0))), 1, SHADE_SSRH_N0);
	uint org = uint((int(tex.y) + 15) / 16); // the 128-pixel blocks' first row
	float inv0 = 1.0 / float(n0), inv1 = inv0 * 0.125, inv2 = inv1 * (1.0 / 11.0);
	float wStart = B / max(s0.z + A, 1e-7);
	bool behind = SHADE_SSR_BEHIND != 0;
	// the 128-pixel intervals: bit i of mF = the ray is in front of everything around interval i (or all of it is too low), of mB =
	// behind everything around it
	uint mF = 0u, mB = 0u;
	for (int i = c; i < n0; i += 4) {
		float ta = float(i) * inv0;
		float za = s0.z + ds.z * ta, zb = za + ds.z * inv0;
		float2 r0 = shadeSsrhRange128(pyr, clamp(a + d * (ta + 0.5 * inv0), float2(0.0), top), org);
		if (min(za, zb) > r0.x || r0.x <= 0.0) mF |= 1u << uint(i);
		else if (max(za, zb) < r0.y) mB |= 1u << uint(i);
	}
	mF = shadeQuadOr(mF);
	mB = shadeQuadOr(mB);
	bool front = true; // the ray is in front of the scene where the walk stands
	bool done = false;
	float tBack = -1.0;
	float3 res = 0.0;
	int budget = SHADE_SSRH_BUDGET;
	for (int i = 0; i < n0 && !done && budget > 0; i++) {
		if (((mF >> uint(i)) & 1u) != 0u) { front = true; continue; }
		if (((mB >> uint(i)) & 1u) != 0u && !front) continue;
		float ta = float(i) * inv0;
		uint f1 = 0u, b1 = 0u; // the same for its eight 16-pixel intervals
		for (int j = c; j < 8; j += 4) {
			float t1 = ta + float(j) * inv1;
			float z1a = s0.z + ds.z * t1, z1b = z1a + ds.z * inv1;
			float2 r1 = shadeSsrhRange16(pyr, clamp(a + d * (t1 + 0.5 * inv1), float2(0.0), top));
			if (min(z1a, z1b) > r1.x || r1.x <= 0.0) f1 |= 1u << uint(j);
			else if (max(z1a, z1b) < r1.y) b1 |= 1u << uint(j);
		}
		f1 = shadeQuadOr(f1);
		b1 = shadeQuadOr(b1);
		for (int j = 0; j < 8 && !done && budget > 0; j++) {
			if (((f1 >> uint(j)) & 1u) != 0u) { front = true; continue; }
			if (((b1 >> uint(j)) & 1u) != 0u && !front) continue;
			budget--;
#ifdef SHADE_PRICE_NOFINE
			continue;
#endif
			float t1 = ta + float(j) * inv1;
			// 12 samples from its start to its end: bit k = the ray is behind the depth copy at sample k
			float zl[3];
			uint bh = 0u;
			for (int m = 0; m < 3; m++) {
				int k = 4 * m + c;
				float t = t1 + float(k) * inv2;
				zl[m] = depth.read(uint2(clamp(a + d * t, float2(0.0), top)));
				if (zl[m] > 0.0 && s0.z + ds.z * t <= zl[m]) bh |= 1u << uint(k); // (never behind the sky: a ray may outrun the far plane)
			}
			uint mb = shadeQuadOr(bh);
			// the samples where it went from in front to behind (before sample 0: where the walk stood)
			uint cross = mb & ~((mb << 1u) | (front ? 0u : 1u)) & 0xfffu;
			while (cross != 0u && !done) {
				int k = int(ctz(cross));
				cross &= cross - 1u;
				float t = t1 + float(k) * inv2;
				float4 ev = float4(0.0); // from the lane that read sample k: uv, fade, 1 a hit / 2 it passed behind something
				if ((k & 3) == c) {
					float zk = zl[k >> 2], zr = s0.z + ds.z * t;
					if (shadeSsrhY(a + d * t, zk, size, f) >= yFloor) {
						float wh = B / max(zk + A, 1e-7), wr = B / max(zr + A, 1e-7);
						float thick = SHADE_SSRH_THICK + 0.03 * wh + abs(wr - B / max(zr - ds.z * inv2 + A, 1e-7)) * SHADE_SSR_THICK_K;
						if (wr - wh < thick) {
							float tH = t;
							if (k > 0) { // on one surface: where the ray meets it between the two samples (their secant)
								float zp = depth.read(uint2(clamp(a + d * (t - inv2), float2(0.0), top)));
								if (zp > 0.0 && abs(B / max(zp + A, 1e-7) - wh) < thick) {
									float dA = zr - ds.z * inv2 - zp, dB = zk - zr;
									tH = t - inv2 * saturate(dB / max(dA + dB, 1e-12));
								}
							}
							float3 sh = s0 + ds * tH;
							float2 uv = sh.xy * 0.5 + 0.5;
							float off = abs(sh.x) - 1.0, offT = sh.y - 1.0;
							float fade = smoothstep(0.0, 0.07, uv.y) * mix(1.0, SHADE_SSR_SIDE_END, saturate(off / SHADE_SSR_SIDE) * saturate(off / SHADE_SSR_SIDE)) * (1.0 - smoothstep(0.0, SHADE_SSR_TOP, offT));
							fade *= mix(1.0, saturate((wh / max(wr, 1e-3) - 0.5) * 4.0), saturate(max(off, offT) * 20.0));
							if (!behind) fade *= 1.0 - smoothstep(0.6, 1.0, (wr - wh) / thick);
							if (!screenEnd) fade *= 1.0 - smoothstep(0.85, 1.0, wr / max(B / max(s0.z + ds.z + A, 1e-7), 1e-3));
							ev = float4(clamp(uv.x, 0.5 / size.x, 1.0 - 0.5 / size.x), min(uv.y, 1.0 - 0.5 / size.y), fade, 1.0);
						} else if (behind && wh > wStart) ev.w = 2.0;
					}
				}
				ev = shadeQuadSum(ev);
				if (ev.w > 0.5 && ev.w < 1.5) {
					res = ev.xyz;
					done = true;
				} else if (ev.w > 1.5 && tBack < 0.0) tBack = t;
			}
			front = ((mb >> 11u) & 1u) == 0u;
		}
	}
	if (done) return float4(res, 1.0);
	if (tBack < 0.0) return float4(0.0, 0.0, 0.0, -1.0);
	float3 sh = s0 + ds * tBack;
	float2 uv = sh.xy * 0.5 + 0.5;
	float zh = depth.read(uint2(clamp(a + d * tBack, float2(0.0), top)));
	float wh = zh > 0.0 ? B / max(zh + A, 1e-7) : SHADE_WATER_SKY_W;
	float wr = B / max(sh.z + A, 1e-7);
	float off = abs(sh.x) - 1.0, offT = sh.y - 1.0;
	float bf = smoothstep(0.0, 0.07, uv.y) * mix(1.0, SHADE_SSR_SIDE_END, saturate(off / SHADE_SSR_SIDE) * saturate(off / SHADE_SSR_SIDE)) * (1.0 - smoothstep(0.0, SHADE_SSR_TOP, offT));
	bf *= mix(1.0, saturate((wh / max(wr, 1e-3) - 0.5) * 4.0), saturate(max(off, offT) * 20.0));
	if (!screenEnd) bf *= 1.0 - smoothstep(0.85, 1.0, wr / max(B / max(s0.z + ds.z + A, 1e-7), 1e-3));
	return float4(clamp(uv.x, 0.5 / size.x, 1.0 - 0.5 / size.x), min(uv.y, 1.0 - 0.5 / size.y), bf, 11.0);
}

#ifdef SHADE_SSRH_OWN
// The quad's search, each pixel's own hit (mcopt.shade.water.ssrOwn, the default): which intervals to open is decided together on
// the quad's mean ray as above (the blocks around an interval cover the four rays), but in an opened 16-pixel interval every
// pixel samples the depth copy along ITS OWN ray (so, dso: its own screen segment; 12 samples, 1.5 pixels apart) and finds its
// own crossing: mirrored silhouettes are decided per pixel, not for a 2x2 block at once (with moving ripples the shared hit
// flipped four pixels together: 0.47 % of the still pond's pixels kept flickering against 0.13 % traced per pixel, 2026-11-09),
// and no pixel has to re-aim a shared hit. ownOk: this pixel has a ray. Returns its hit as shadeSsrTrace does (w 11: a crossing
// behind something standing in).
#ifdef SHADE_PRICE_INLINE
#define SHADE_SSRH_CALL
#else
// (not inlined: the water shader is bound by registers, and inlined this march's loops ran with everything the surface keeps for
// later held across them; called, its own values have the registers. Pricing, 2026-11-09: see the notes)
#define SHADE_SSRH_CALL __attribute__((noinline))
#endif
static SHADE_SSRH_CALL float4 shadeSsrTraceQuadOwn(float3 s0, float3 ds, float3 so, float3 dso, bool ownOk, bool screenEnd, float yFloor, int c, constant ShadeFrame &f,
                                   depth2d<float> depth, texture2d<float> pyr) {
	float2 tex = float2(depth.get_width(), depth.get_height());
	float2 size = shadeWaterRenderSize(f, tex);
	float A = f.proj[2][2], B = f.proj[3][2];
	float2 a = (s0.xy * 0.5 + 0.5) * size, d = ds.xy * 0.5 * size;     // the quad's ray in pixels: a + d t
	float2 ao = (so.xy * 0.5 + 0.5) * size, dox = dso.xy * 0.5 * size; // this pixel's
	float2 top = size - 1.0;
	int n0 = clamp(int(ceil(length(d) * (1.0 / 128.0))), 1, SHADE_SSRH_N0);
	uint org = uint((int(tex.y) + 15) / 16); // the 128-pixel blocks' first row
	float inv0 = 1.0 / float(n0), inv1 = inv0 * 0.125, inv2 = inv1 * (1.0 / 11.0);
	float wStart = B / max(so.z + A, 1e-7);
	bool behind = SHADE_SSR_BEHIND != 0;
	uint mF = 0u, mB = 0u;
	for (int i = c; i < n0; i += 4) {
		float ta = float(i) * inv0;
		float za = s0.z + ds.z * ta, zb = za + ds.z * inv0;
		float2 r0 = shadeSsrhRange128(pyr, clamp(a + d * (ta + 0.5 * inv0), float2(0.0), top), org);
		if (min(za, zb) > r0.x || r0.x <= 0.0) mF |= 1u << uint(i);
		else if (max(za, zb) < r0.y) mB |= 1u << uint(i);
	}
	mF = shadeQuadOr(mF);
	mB = shadeQuadOr(mB);
#ifdef SHADE_PRICE_NOL1
	return float4(0.0, 0.0, 0.0, -1.0);
#endif
	bool front = true;   // this pixel's ray is in front of the scene where the walk stands
	bool done = !ownOk;  // this pixel has its answer
	bool all = false;    // every pixel of the quad has
	float tBack = -1.0;
	float3 res = 0.0;
	int budget = SHADE_SSRH_BUDGET;
	for (int i = 0; i < n0 && !all && budget > 0; i++) {
		if (((mF >> uint(i)) & 1u) != 0u) { front = true; continue; }
		if (((mB >> uint(i)) & 1u) != 0u && shadeQuadOr(uint(front && !done)) == 0u) continue; // behind everything, and no pixel was in front
		float ta = float(i) * inv0;
		uint f1 = 0u, b1 = 0u;
		for (int j = c; j < 8; j += 4) {
			float t1 = ta + float(j) * inv1;
			float z1a = s0.z + ds.z * t1, z1b = z1a + ds.z * inv1;
			float2 r1 = shadeSsrhRange16(pyr, clamp(a + d * (t1 + 0.5 * inv1), float2(0.0), top));
			if (min(z1a, z1b) > r1.x || r1.x <= 0.0) f1 |= 1u << uint(j);
			else if (max(z1a, z1b) < r1.y) b1 |= 1u << uint(j);
		}
		f1 = shadeQuadOr(f1);
		b1 = shadeQuadOr(b1);
		for (int j = 0; j < 8 && !all && budget > 0; j++) {
			if (((f1 >> uint(j)) & 1u) != 0u) { front = true; continue; }
			if (((b1 >> uint(j)) & 1u) != 0u && shadeQuadOr(uint(front && !done)) == 0u) continue;
			budget--;
#ifdef SHADE_PRICE_NOFINE
			if (false) {
#else
			if (!done) {
#endif
				float t1 = ta + float(j) * inv1;
				float zs[12];
				for (int k = 0; k < 12; k++) zs[k] = depth.read(uint2(clamp(ao + dox * (t1 + float(k) * inv2), float2(0.0), top)));
				for (int k = 0; k < 12; k++) {
					float t = t1 + float(k) * inv2;
					float zr = so.z + dso.z * t;
					bool fr = !(zs[k] > 0.0 && zr <= zs[k]); // (never behind the sky: a ray may outrun the far plane)
#ifdef SHADE_PRICE_NOCROSS
					if (false) {
#else
					if (front && !fr && shadeSsrhY(ao + dox * t, zs[k], size, f) >= yFloor) {
#endif
						float wh = B / max(zs[k] + A, 1e-7), wr = B / max(zr + A, 1e-7);
						float thick = SHADE_SSRH_THICK + 0.03 * wh + abs(wr - B / max(zr - dso.z * inv2 + A, 1e-7)) * SHADE_SSR_THICK_K;
						if (wr - wh < thick) {
							float tH = t;
							if (k > 0 && zs[k - 1] > 0.0 && abs(B / max(zs[k - 1] + A, 1e-7) - wh) < thick) { // one surface: the secant
								float dA = zr - dso.z * inv2 - zs[k - 1], dB = zs[k] - zr;
								tH = t - inv2 * saturate(dB / max(dA + dB, 1e-12));
							}
							float3 sh = so + dso * tH;
							float2 uv = sh.xy * 0.5 + 0.5;
							float off = abs(sh.x) - 1.0, offT = sh.y - 1.0;
							float fade = smoothstep(0.0, 0.07, uv.y) * mix(1.0, SHADE_SSR_SIDE_END, saturate(off / SHADE_SSR_SIDE) * saturate(off / SHADE_SSR_SIDE)) * (1.0 - smoothstep(0.0, SHADE_SSR_TOP, offT));
							fade *= mix(1.0, saturate((wh / max(wr, 1e-3) - 0.5) * 4.0), saturate(max(off, offT) * 20.0));
							if (!behind) fade *= 1.0 - smoothstep(0.6, 1.0, (wr - wh) / thick);
							if (!screenEnd) fade *= 1.0 - smoothstep(0.85, 1.0, wr / max(B / max(so.z + dso.z + A, 1e-7), 1e-3));
							res = float3(clamp(uv.x, 0.5 / size.x, 1.0 - 0.5 / size.x), min(uv.y, 1.0 - 0.5 / size.y), fade);
							done = true;
							break;
						}
						if (behind && tBack < 0.0 && wh > wStart) tBack = t;
					}
					front = fr;
				}
			}
			all = shadeQuadOr(uint(!done)) == 0u;
		}
	}
	if (done && ownOk) return float4(res, 1.0);
	if (tBack < 0.0) return float4(0.0, 0.0, 0.0, -1.0);
	float3 sh = so + dso * tBack;
	float2 uv = sh.xy * 0.5 + 0.5;
	float zh = depth.read(uint2(clamp(ao + dox * tBack, float2(0.0), top)));
	float wh = zh > 0.0 ? B / max(zh + A, 1e-7) : SHADE_WATER_SKY_W;
	float wr = B / max(sh.z + A, 1e-7);
	float off = abs(sh.x) - 1.0, offT = sh.y - 1.0;
	float bf = smoothstep(0.0, 0.07, uv.y) * mix(1.0, SHADE_SSR_SIDE_END, saturate(off / SHADE_SSR_SIDE) * saturate(off / SHADE_SSR_SIDE)) * (1.0 - smoothstep(0.0, SHADE_SSR_TOP, offT));
	bf *= mix(1.0, saturate((wh / max(wr, 1e-3) - 0.5) * 4.0), saturate(max(off, offT) * 20.0));
	if (!screenEnd) bf *= 1.0 - smoothstep(0.85, 1.0, wr / max(B / max(so.z + dso.z + A, 1e-7), 1e-3));
	return float4(clamp(uv.x, 0.5 / size.x, 1.0 - 0.5 / size.x), min(uv.y, 1.0 - 0.5 / size.y), bf, 11.0);
}
#endif
#endif
#endif

// The colour (radiance before exposure) at uv over the rendered rect of the copies: from last frame's finished HDR world
// when the caller gives one (prevExposure > 0; reprojected through the depth copy's point with prevViewProj, so it holds
// clouds, translucents and post-VL light too), else from this frame's opaque scene copy.
// M2 HDR: last frame's image is taken before the final pass, which adds the height haze and mist from depth (E06). A
// point read from it (camera-relative p, not the sky) gets that haze here, so mirrored clouds and far shores match what
// the eye sees on screen (without it, clouds the haze brightens on screen mirror as dark "mud slicks" at sunset).
// (FT2.7, audit idx 33) only over the leg from the reflecting surface o to the point (from o's height): the final pass hazes the
// water pixel itself from the camera (the water writes depth), so a haze from the camera here counted that leg twice and far
// shores mirrored milkier than the shores themselves.
static inline float3 shadeWaterHazed(float3 c, float3 p, float3 o, constant ShadeFrame &f, constant ShadeLook *L) {
	float3 s = p - o;
	if (L == nullptr || !shadeFeature(*L, SHADE_FEATURE_HAZE) || f.flags.x != SHADE_DIM_OVERWORLD || f.fogColor.a >= 0.5 || dot(s, s) <= 4.0) return c;
	float3 T;
	float3 S = shadeHazeInscatterFrom(s, f.cameraBlock.y + f.cameraFract.y + o.y, f, *L, 1.0, T);
	return c * T + S;
}

// (candidate 8) Last frame's image at uv over the footprint (fx, fy): the steps (uv units) to where the neighbouring pixels' mirrored
// rays hit. A ripple that squeezes the mirrored image makes neighbouring water pixels read points several pixels apart: one tap
// each is a point sample of a minified image, which shimmers as the ripples or the eye move (the reflections' flicker while walking,
// running and jumping, more with every ripple). Where the hits are over 1.5 pixels apart the pixel reads the 4 points a quarter of
// the way to its neighbours (a rotated grid: together the pixels cover the mirrored image without gaps or overlap); a flat mirror
// keeps its one tap and its sharpness.
static inline float3 shadeWaterPrevTaps(texture2d<half> prev, float2 uvp, float2 fx, float2 fy, bool wide) {
	if (!wide) return float3(prev.sample(shadeWaterLinear, uvp).rgb);
	float2 a = 0.375 * fx + 0.125 * fy, b = 0.125 * fx - 0.375 * fy;
	half3 c = prev.sample(shadeWaterLinear, uvp + a).rgb + prev.sample(shadeWaterLinear, uvp - a).rgb
		+ prev.sample(shadeWaterLinear, uvp + b).rgb + prev.sample(shadeWaterLinear, uvp - b).rgb;
	return float3(c) * 0.25;
}

static float3 shadeWaterHitColor(float2 uv, float3 o, float exposure, float prevExposure, constant ShadeFrame &f, constant ShadeLook *L, texture2d<half> scene,
                                 depth2d<float> depth, texture2d<half> prev, float2 fx = float2(0.0), float2 fy = float2(0.0), bool wide = false) {
	float2 tex = float2(depth.get_width(), depth.get_height());
	float2 size = shadeWaterRenderSize(f, tex);
	if (prevExposure > 0.0) {
		float z = depth.read(uint2(clamp(uv * size, float2(0.0), size - 1.0)));
		float4 wp = f.invViewProj * float4(uv * 2.0 - 1.0, z, 1.0);
		float3 pw = wp.xyz / wp.w;
		// (FT2.8, audit idx 35) last frame's image is the TAA history: steady, unjittered (as the puddles read it)
		float4 pc = (L != nullptr ? L->prevViewProjNoJitter : f.prevViewProj) * float4(pw, 1.0);
		float2 uvp = pc.xy / pc.w * 0.5 + 0.5;
		// (candidate 7) no vertical blur of the edge column's colour (tried for the side streaks while turning, research-ssr-edges.md):
		// its taps 2 % above and below landed on other surfaces (the shore's sunlit grass) and drew bright green patches on the water at
		// the sides looking down 35 degrees (bisect gbe / gbn, 2026-11-06)
#ifdef SHADE_WATER_EDGE_REFL
		// (candidate 7) last frame's image faded into this frame's copy over 2 % of the height just OUTSIDE its frame (its edge read
		// clamped; Unreal, HDRP and Godot fade by the hit's previous-frame position), not switched at the border: the switch was a seam
		// sweeping across the reflection while turning. Not inside the frame: this frame's copy is the opaque scene BEFORE the water,
		// so an edge-column hit read there showed the pond's sunlit bottom through it (bright green patches at the sides looking
		// down 20-35 degrees, ld7d / gb7d 2026-11-06), where last frame's image shows the water.
		float e = pc.w > 0.0 ? saturate(1.0 + min(min(uvp.x, 1.0 - uvp.x), min(uvp.y, 1.0 - uvp.y)) / 0.02) : 0.0;
		float3 cp = e > 0.0 ? shadeWaterPrevTaps(prev, uvp, fx, fy, wide) / prevExposure : float3(0.0);
		if (e < 1.0) {
			// FT1.2: where last frame did not see the point (the side the camera turns toward; SSR's edge-column hits past a side)
			// this frame's opaque copy, hazed like the hits read from last frame (both are taken before the final pass's haze).
			// Unhazed, the far shore and the render distance's fog band mirrored darker and clearer there: a hard slanted seam
			// on the water that swept along while turning (recording rf1-base)
			float3 cs = shadeWaterSceneRadiance(scene.sample(shadeWaterLinear, uv * size / tex).rgb, exposure);
			cp = mix(cs, cp, e);
		}
		return z > 0.0 ? shadeWaterHazed(cp, pw, o, f, L) : cp; // (FT2.8, idx 34: the sky on screen gets no haze)
#else
		if (pc.w > 0.0 && all(uvp > 0.0) && all(uvp < 1.0)) {
			float3 cp = shadeWaterPrevTaps(prev, uvp, fx, fy, wide) / prevExposure;
			return z > 0.0 ? shadeWaterHazed(cp, pw, o, f, L) : cp; // (FT2.8, idx 34: the sky on screen gets no haze)
		}
#endif
	}
	return shadeWaterSceneRadiance(scene.sample(shadeWaterLinear, uv * size / tex).rgb, exposure);
}

// The sky in the reflected direction r: the atmosphere LUT, or (prevExposure > 0) the rendered sky where r points on
// screen and nothing was drawn there (depth copy = sky): with M2 that is the sky pass, the sun disc and aureole, stars and
// Milky Way, clouds, rain and Distant Horizons' LODs (which the depth copy doesn't hold), so open water mirrors the
// clouds at sunset and the far mountains. Faded into the LUT toward the screen edges. rs: the direction for the rendered
// sky (callers pass the calmer SSR direction: mirrored clouds stay readable instead of shredding into blotches).
static float3 shadeWaterSkyRefl(float3 r, float3 rs, float3 o, float prevExposure, constant ShadeFrame &f, constant ShadeLook *L, constant ShadeResources *R,
                                texture2d<half> lut, sampler lutS, depth2d<float> depth, texture2d<half> prev) {
	float3 sky = shadeSkyLookup(r, lut, lutS, f);
	// M3: the volumetric clouds in that direction from their reflection dome (off-screen directions; on screen the rendered
	// sky below holds them, already with their aerial perspective)
	bool volumetricClouds = L != nullptr && R != nullptr && L->clouds0.w > 0.5;
#ifdef SHADE_WATER_EDGE_REFL
	// FT1.2: the dome along the rendered sky's (calm) direction rs: a cloud keeps its shape where the mirrored sky fades from
	// the screen into the dome below (along r the ripples shredded it into blotches there)
	bool domeSides = volumetricClouds && L->clouds1.x > 0.5;
	float3 rd = rs;
#else
	float3 rd = r;
#endif
	if (volumetricClouds) {
		float4 cd = shadeCloudsDome(rd, *L, R->cloudDome);
		sky = sky * cd.a + cd.rgb;
	}
	if (prevExposure > 0.0) {
		float4 c = f.viewProj * float4(rs, 0.0); // a direction: the point at infinity
		if (c.w > 1e-4) {
			float2 uv = c.xy / c.w * 0.5 + 0.5;
#ifdef SHADE_SSR_EDGE
			// M2.1: off a side the edge column stands in for the sky there (it changes slowly sideways): no side fade, the
			// weight halves by NDC +-2 (uv -0.5 / 1.5)
			float wgt = saturate(min(uv.y, 1.0 - uv.y) * 12.0) * (1.0 - 0.5 * smoothstep(0.0, 0.5, abs(uv.x - 0.5) - 0.5));
#ifdef SHADE_WATER_EDGE_REFL
			// FT1.2: with the clouds' reflection dome (the sky and its clouds by direction) the edge column smeared the clouds
			// sideways, and where the mirrored direction left the screen a hard slanted seam crossed the water (clouds appeared
			// and vanished on it while turning): the rendered sky fades into the dome over the last 1/8 of the screen instead,
			// at the sides as at the top. (SSR's terrain hits past a side still use the edge column: M2.1's shores.)
			if (domeSides) wgt = saturate(min(uv.x, 1.0 - uv.x) * 8.0) * saturate(min(uv.y, 1.0 - uv.y) * 8.0);
#endif
			uv.x = saturate(uv.x);
#else
			float2 edge = saturate(min(uv, 1.0 - uv) * 12.0);
			float wgt = edge.x * edge.y;
#endif
			if (wgt > 0.0) {
				// what is on screen in that direction counts where it is the sky, a cloud, or terrain at the edge of the
				// render distance (all of which mirror like the sky); anything nearer isn't what the water sees in that
				// direction (a tree on a hill would ghost into the reflection where SSR missed the hill): the LUT there
				float2 size = shadeWaterRenderSize(f, float2(depth.get_width(), depth.get_height()));
				float z = depth.read(uint2(clamp(uv * size, float2(0.0), size - 1.0)));
				float3 pw = float3(0.0);
				if (z > 0.0) {
					float4 h = f.invViewProj * float4(uv * 2.0 - 1.0, z, 1.0);
					pw = h.xyz / h.w;
					bool cloud = !volumetricClouds && pw.y + f.cameraBlock.y + f.cameraFract.y > 150.0; // vanilla's cloud layer (nothing else stands that high)
					if (!cloud) wgt *= smoothstep(160.0, 320.0, shadeLinearW(z, f));
				}
				if (wgt > 0.0) {
					float4 pc = (L != nullptr ? L->prevViewProjNoJitter : f.prevViewProj) * float4(rs, 0.0); // (FT2.8, idx 35)
					float2 uvp = pc.xy / max(pc.w, 1e-4) * 0.5 + 0.5;
					float3 s = float3(prev.sample(shadeWaterLinear, saturate(uvp)).rgb) / prevExposure;
					if (z > 0.0) {
						s = shadeWaterHazed(s, pw, o, f, L);
					} else if (rs.y > 0.02 && !volumetricClouds) {
						// nothing in the opaque depth copy, but clouds (drawn after it) may be in last frame's image: where it
						// differs from the plain sky in that direction, haze it as far as the cloud layer (on screen the final
						// pass hazes clouds from the main depth; unhazed they mirror as dark slabs)
						float3 plain = shadeSkyLookup(rs, lut, lutS, f);
						float ls = shadeLuma(plain);
						float cloudy = saturate(abs(shadeLuma(s) - ls) / max(ls, 1e-5) * 4.0);
						if (cloudy > 0.0) {
							float tc = min((192.5 - f.cameraBlock.y - f.cameraFract.y) / rs.y, 640.0);
							if (tc > 2.0) s = mix(s, shadeWaterHazed(s, rs * tc, float3(0.0), f, L), cloudy);
						}
					}
					sky = mix(sky, s, wgt);
				}
			}
		}
	}
	return sky;
}

#ifdef SHADE_WATER_PANO
// ---- the reflections' panorama (1.2.7 candidate 8) ----------------------------------------------------------------------------
// Gael (candidates 6, 7 and 8): "cuando estás volteando o moviéndote, los reflejos a los lados de la pantalla se cortan así raro".
// Screen-space reflections only know what is on screen: a mirrored ray that leaves it through a side finds nothing, so the trees
// and shores mirrored near the screen's sides end in the sky's reflection, along a line that sweeps over the water as the view
// turns. The panorama remembers what the view has shown: the finished image of every frame is laid into a texture by direction
// from the eye (ShadeResources.reflPano, RGBA16F SHADE_PANO_W x SHADE_PANO_H: rgb the pre-exposed colour as last frame's image
// holds it, a its distance from the eye in blocks, 60000 the sky, 0 never seen), kept where the view no longer looks and moved
// with the eye (each texel's point re-aimed from the eye's new place). A mirrored ray whose vanishing point is off screen, and
// that found nothing on screen, is marched through it (shadeWaterPano): what left the screen a moment ago still mirrors.
// u: the azimuth; v: the sine of the elevation from -0.25 to 1, as a signed square root (most rows near the horizon, where the
// shores and trees are).
#define SHADE_PANO_W 2048
#define SHADE_PANO_H 512
static inline float2 shadePanoUv(float3 d) {
	float az = atan2(d.z, d.x) * 0.15915494;
	float sy = d.y >= 0.0 ? sqrt(d.y) : -sqrt(-d.y);
	return float2(az < 0.0 ? az + 1.0 : az, saturate((sy + 0.5) * (1.0 / 1.5)));
}
static inline float3 shadePanoDir(float2 uv) {
	float sy = uv.y * 1.5 - 0.5;
	float y = sy * abs(sy);
	float rh = sqrt(max(1.0 - y * y, 0.0));
	float az = uv.x * 6.2831853;
	return float3(cos(az) * rh, y, sin(az) * rh);
}

// The update (ShadeWaterPano.update, once a frame before the world): texture(0) the panorama as it was, buffer(0) the eye's move.
struct ShadePanoParams {
	float4 move; // xyz the eye of the image laid in now - the eye the panorama stood at, w 1 = start over (nothing kept)
	float4 k;    // x how much of a texel the screen replaces per frame
};
fragment half4 shade_water_pano_fs(float4 pos [[position]], texture2d<half> was [[texture(0)]], constant ShadePanoParams &u [[buffer(0)]],
                                   constant ShadeLook &L [[buffer(17)]], constant ShadeResources &sr [[buffer(19)]]) {
	constexpr sampler wrapU(filter::linear, s_address::repeat, t_address::clamp_to_edge);
	constexpr sampler lin(filter::linear, address::clamp_to_edge);
	constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
	float3 dir = shadePanoDir(pos.xy / float2(SHADE_PANO_W, SHADE_PANO_H));
	float4 o = float4(0.0);
	if (u.move.w < 0.5) {
		o = float4(was.read(uint2(pos.xy)));
		// the eye moved: the point this direction shows now (at about the distance it showed) was seen from the old eye along another
		if (o.a > 0.5 && o.a < 50000.0 && dot(u.move.xyz, u.move.xyz) > 1e-8) {
			float3 q = dir * o.a + u.move.xyz;
			float4 w = float4(was.sample(wrapU, shadePanoUv(normalize(q)), level(0.0)));
			if (w.a > 0.5) o = float4(w.rgb, w.a < 50000.0 ? max(w.a - dot(u.move.xyz, dir), 0.6) : w.a);
		}
	}
	if (L.ssr.x > 0.5 && L.ssr.y > 0.5) { // last frame's finished image and its depth
		float4 c = L.prevViewProjNoJitter * float4(dir, 0.0);
		if (c.w > 1e-4) {
			float2 uvS = c.xy / c.w * 0.5 + 0.5;
			if (min(min(uvS.x, 1.0 - uvS.x), min(uvS.y, 1.0 - uvS.y)) > 0.004) {
				float pd = float(sr.prevDepth.sample(nearest, uvS).r);
				float dist = pd > 60000.0 ? 60000.0 : max(pd / c.w, 0.6); // (c.w: the view depth of a point 1 block along dir)
				// a texel spans ~5 image pixels across: 4 taps along the row
				float px = 1.0 / float(sr.prevScene.get_width());
				half3 col = sr.prevScene.sample(lin, uvS + float2(-1.875 * px, 0.0)).rgb + sr.prevScene.sample(lin, uvS + float2(-0.625 * px, 0.0)).rgb
					+ sr.prevScene.sample(lin, uvS + float2(0.625 * px, 0.0)).rgb + sr.prevScene.sample(lin, uvS + float2(1.875 * px, 0.0)).rgb;
				float3 cnow = min(float3(col) * 0.25, float3(60000.0));
				// (a texel that turns from sky to something solid or back starts over)
				float k = o.a > 0.5 && (o.a > 50000.0) == (dist > 50000.0) ? u.k.x : 1.0;
				o = float4(mix(o.rgb, cnow, k), dist);
			}
		}
	}
	return half4(o);
}

// What the mirrored ray p0 + r t (camera-relative, r unit and rising) meets in the panorama beyond t0 blocks (where it left the
// screen: up to there the screen march has the say): rgb its radiance before exposure (hazed over the leg from the surface, as the
// on-screen hits are), a 1, or 0 where it meets nothing the panorama holds (the sky, or directions never seen: the caller's sky
// stays). 8 steps, each 1.7 times the last, then two halvings of the step that went behind something; behind it by more than the
// depth a thing may have (2 blocks + 10 % of the distance) the ray passed it and goes on. prevExposure: the exposure last frame's
// image was drawn with (the panorama's colours are in its units).
static __attribute__((noinline)) float4 shadeWaterPano(float3 p0, float3 r, float t0, float prevExposure, constant ShadeFrame &f, constant ShadeLook *L, texture2d<half> pano) {
	constexpr sampler wrapU(filter::linear, s_address::repeat, t_address::clamp_to_edge);
	float3 o = p0 - shadeEye(f.invViewProj);
	float tp = t0 * 0.6, t = t0;
	for (int i = 0; i < 8; i++) {
		float3 q = o + r * t;
		float dq = length(q);
		float a = float(pano.sample(wrapU, shadePanoUv(q / dq), level(0.0)).a);
		if (a > 0.5 && a < dq) { // behind what was seen there: where between the last step and this one
			float lo = tp, hi = t;
			for (int j = 0; j < 2; j++) {
				float m = 0.5 * (lo + hi);
				float3 qm = o + r * m;
				float dm = length(qm);
				float am = float(pano.sample(wrapU, shadePanoUv(qm / dm), level(0.0)).a);
				if (am > 0.5 && am < dm) hi = m; else lo = m;
			}
			float3 qh = o + r * hi;
			float dh = length(qh);
			half4 c = pano.sample(wrapU, shadePanoUv(qh / dh), level(0.0));
			if (float(c.a) > 0.5 && float(c.a) < 50000.0 && dh - float(c.a) < 2.0 + 0.1 * dh) {
				float3 rgb = float3(c.rgb) / max(prevExposure, 1e-6);
				return float4(shadeWaterHazed(rgb, p0 + r * hi, p0, f, L), 1.0);
			}
		}
		tp = t;
		t *= 1.7;
		if (tp > 600.0) break;
	}
	return float4(0.0);
}
// Whether the march above is worth making for the mirrored ray p0 + r t, and from where: x how far its vanishing point is past a
// SIDE of the screen (0: inside, the screen march saw all of the ray; 1: outside), y the distance at which the ray leaves the
// screen. Only the sides: most rays that leave the screen go out through the top into the sky (looking down at a lake nearly all
// of them do, and testing those cost 0.3 ms, price-1 2026-11-09), and it is at the sides that Gael saw the reflections cut off.
static inline float2 shadeWaterPanoWanted(float3 p0, float3 r, constant ShadeFrame &f) {
	float4 dc = f.viewProj * float4(r, 0.0);
	float outside = dc.w <= 1e-4 ? 1.0 : smoothstep(0.88, 1.0, abs(dc.x) / dc.w);
	if (outside <= 0.0) return float2(0.0);
	// where x / w = +-1 or y / w = 1 along c0 + dc t: the first one ahead
	float4 c0 = f.viewProj * float4(p0, 1.0);
	float3 den = float3(dc.x - dc.w, dc.x + dc.w, dc.y - dc.w);
	float3 te = float3(c0.w - c0.x, -c0.w - c0.x, c0.w - c0.y) / select(den, float3(1e-6), abs(den) < 1e-6);
	te = select(te, float3(1e6), te <= 0.0);
	return float2(outside, clamp(min(te.x, min(te.y, te.z)), 1.0, 400.0));
}
#endif

#ifdef SHADE_WATER_EDGE_REFL
// FT1.2: a ray that rises from the surface cannot hit anything below where it started. SSR's edge-column hits past a side
// could: below the horizon the edge column holds the bottom under the water (translucent, not in the opaque copy). Read from
// last frame it showed the water drawn over that bottom; where last frame did not see it (turning) the opaque copy showed the
// bare bottom: a light slanted streak along the water's side that swept along while turning (rf1-base / rf4-new).
static inline bool shadeSsrBelowStart(float2 uv, float3 p0, float3 r, constant ShadeFrame &f, depth2d<float> depth) {
	if (r.y <= 0.0) return false;
	float2 size = shadeWaterRenderSize(f, float2(depth.get_width(), depth.get_height()));
	float z = depth.read(uint2(clamp(uv * size, float2(0.0), size - 1.0)));
	float4 h = f.invViewProj * float4(uv * 2.0 - 1.0, z, 1.0);
	return h.y / h.w < p0.y - 0.3;
}
#endif

// Radiance (before exposure) where the ray hits and a weight: 0 miss, fading to 0 toward the screen edges and the ray's far
// end, so callers blend it over their sky reflection. pixel: the fragment position (quad lane order and jitter).
// The distance from p0 to a hit at uv (blocks along the ray; -1 where the depth copy has nothing there: the sky)
static inline float shadeSsrHitT(float2 uv, float3 p0, constant ShadeFrame &f, depth2d<float> depth) {
	float2 sz = shadeWaterRenderSize(f, float2(depth.get_width(), depth.get_height()));
	float z = depth.read(uint2(clamp(uv * sz, float2(0.0), sz - 1.0)));
	if (z <= 0.0) return -1.0;
	float4 hp = f.invViewProj * float4(uv * 2.0 - 1.0, z, 1.0);
	return length(hp.xyz / hp.w - p0);
}

// tHit (candidate 7, the reflection's temporal reprojection): the hit's distance along r from p0, -1 without a hit
// footprint (candidate 8, the exact march): the scale of the footprint the hit's colour is read over (wp.mirror.y; 0 = one tap)
static float4 shadeSsrT(float3 p0, float3 r, float2 pixel, float maxDist, float exposure, float prevExposure, constant ShadeFrame &f,
                       constant ShadeLook *L, texture2d<half> scene, depth2d<float> depth, texture2d<half> prev, texture2d<float> hz,
                       thread float &tHit, float footprint = 1.0) {
	tHit = -1.0;
	float2 tex = float2(depth.get_width(), depth.get_height());
	float2 size = shadeWaterRenderSize(f, tex);
	float3 s0 = 0.0, ds = 0.0;
	bool screenEnd = false;
#ifdef SHADE_SSR_HIER
	// (candidate 8) the exact march (shadeSsrTrace / shadeSsrTraceQuad): to the pixel, without jitter. The quad works together (no
	// lane leaves before its last shuffle): with SHADE_SSR_QUAD it traces one ray, the quad's mean, and each pixel reads that hit
	// along its OWN ray at the shared distance (FT1.3's lanes: mirrored edges and textures per pixel, not in 2x2 blocks; only onto
	// the same surface, 1.2.7 B2); without it every pixel traces its own. Either way each pixel then knows where its two
	// neighbours' rays hit: the footprint its hit's colour is read over (shadeWaterPrevTaps).
	float2 sz = size;
#ifdef SHADE_SSR_QUAD
	float3 p0Own = p0, rOwn = r;
	p0 = shadeQuadSum(p0) * 0.25;
	r = normalize(shadeQuadSum(r));
#endif
	bool seg = shadeSsrSegment(p0, r, maxDist, f, s0, ds, screenEnd);
	// (FT1.2's shadeSsrBelowStart, inside the march: a ray that rises from a surface cannot hit anything below where it started)
	float yFloor = r.y > 0.0 ? p0.y - 0.3 : -1e30;
	float4 hit = float4(0.0, 0.0, 0.0, -1.0);
#ifdef SHADE_SSR_QUAD
	uint2 q = uint2(pixel);
#if defined(SHADE_SSRH_OWN) && !defined(SHADE_PRICE_SHARED)
	// (the quad's search, each pixel's own hit: no re-aiming below)
	float3 so = 0.0, dso = 0.0;
	bool endOwn = false;
	bool ownOk = shadeSsrSegment(p0Own, rOwn, maxDist, f, so, dso, endOwn);
#ifndef SHADE_PRICE_NOMARCH // (pricing, -Dmcopt.shade.leanDev=SHADE_PRICE_...: in-session A/B of the exact march's parts)
	if (seg) hit = shadeSsrTraceQuadOwn(s0, ds, so, dso, ownOk, endOwn, yFloor, int(q.x & 1u) + 2 * int(q.y & 1u), f, depth, hz);
#endif
	if (false) {
#else
#ifndef SHADE_PRICE_NOMARCH
	if (seg) hit = shadeSsrTraceQuad(s0, ds, screenEnd, yFloor, int(q.x & 1u) + 2 * int(q.y & 1u), f, depth, hz);
#endif
#ifdef SHADE_PRICE_NOLANE
	if (false) {
#else
	if (hit.w >= 0.0 && hit.w < 5.0) { // (not a crossing behind something, which is not on the ray)
#endif
#endif
		float zh = depth.read(uint2(clamp(hit.xy * sz, float2(0.0), sz - 1.0)));
		float4 hp = f.invViewProj * float4(hit.xy * 2.0 - 1.0, zh, 1.0);
		float4 cl = f.viewProj * float4(p0Own + rOwn * max(dot(hp.xyz / hp.w - p0, r), 0.0), 1.0);
		if (cl.w > 1e-4) {
			float2 uvl = cl.xy / cl.w * 0.5 + 0.5;
			if (uvl.y > 0.0 && uvl.y < 1.0) {
				float2 ul = float2(clamp(uvl.x, 0.5 / sz.x, 1.0 - 0.5 / sz.x), uvl.y);
				float zl = depth.read(uint2(clamp(ul * sz, float2(0.0), sz - 1.0)));
				float wh = shadeLinearW(zh, f), wl = shadeLinearW(zl, f);
				if (zl > 0.0 && abs(wl - wh) < max(1.5, 0.08 * wh)) hit.xy = ul;
			}
		}
	}
#elif defined(SHADE_SSRH_DEBUG)
	float3 dbg = 0.0;
	if (seg) hit = shadeSsrTrace(s0, ds, screenEnd, yFloor, f, depth, hz, dbg);
#else
	if (seg) hit = shadeSsrTrace(s0, ds, screenEnd, yFloor, f, depth, hz);
#endif
#ifdef SHADE_PRICE_NOHITSHADE
	hit.w = hit.w * 1e-9 - 1.0; // (the march ran; nothing after it does)
#endif
	float mineT = hit.w >= 0.0 ? shadeSsrHitT(hit.xy, p0, f, depth) : -1.0;
	float3 own = float3(hit.xy, mineT);
	float3 nx = quad_shuffle_xor(own, 1), ny = quad_shuffle_xor(own, 2);
#if defined(SHADE_SSRH_DEBUG) && !defined(SHADE_SSR_QUAD)
	if (f.flags.w == 10) { tHit = -2.0; return float4(dbg * float3(1.0 / 8.0, 1.0 / 8.0, 1.0), 1.0); }
#endif
	if (hit.w < 0.0) return 0.0;
#ifndef SHADE_PRICE_NOTHIT
	tHit = mineT;
#endif
	// a neighbour's hit counts where it found the same thing (about the same distance along its ray): across a mirrored silhouette
	// the step between the hits is the gap between two things, not a squeezed image
	float2 fx = 0.0, fy = 0.0;
	float tol = 0.15 * max(mineT, 0.0) + 0.5;
	if (nx.z >= 0.0 && abs(nx.z - mineT) < tol) fx = nx.xy - hit.xy;
	if (ny.z >= 0.0 && abs(ny.z - mineT) < tol) fy = ny.xy - hit.xy;
	fx *= footprint;
	fy *= footprint;
	float2 px = max(abs(fx), abs(fy)) * sz;
	float span = max(px.x, px.y);
	if (span > 12.0) { // (a runaway footprint: capped, not dropped)
		fx *= 12.0 / span;
		fy *= 12.0 / span;
	}
#ifdef SHADE_PRICE_NOCOLOR
	return float4(float3(hit.xy, 0.2) / max(exposure, 1e-6), hit.z);
#elif defined(SHADE_PRICE_NOHAZE)
	return float4(shadeWaterHitColor(hit.xy, p0, exposure, prevExposure, f, nullptr, scene, depth, prev, fx, fy, span > 1.5), hit.z);
#elif defined(SHADE_PRICE_NOTAPS)
	return float4(shadeWaterHitColor(hit.xy, p0, exposure, prevExposure, f, L, scene, depth, prev), hit.z);
#else
	return float4(shadeWaterHitColor(hit.xy, p0, exposure, prevExposure, f, L, scene, depth, prev, fx, fy, span > 1.5), hit.z);
#endif
#elif defined(SHADE_SSR_QUAD)
#ifdef SHADE_SSR_LANE
	float3 p0Own = p0, rOwn = r;
#endif
	p0 = shadeQuadSum(p0) * 0.25;
	r = normalize(shadeQuadSum(r));
	bool ok = shadeSsrSegment(p0, r, maxDist, f, s0, ds, screenEnd); // quad-uniform: same ray in all four lanes
	if (!ok) return 0.0;
	uint2 q = uint2(pixel);
	int chunk = int(q.x & 1u) + 2 * int(q.y & 1u);
	float jitter = shadeNoise(floor(pixel * 0.5), SHADE_WATER_NOISE_FRAME(f));
	float4 hit = shadeSsrMarch(s0, ds, screenEnd, chunk, 4, jitter, f, depth, hz);
	// (FT2.6: a crossing behind something, w >= 10, counts only where no lane of the quad found a real hit)
	float key = hit.w >= 10.0 ? float(chunk) + 4.0 : hit.w >= 0.0 ? float(chunk) : 8.0;
	float best = shadeQuadMin(key);
	if (best > 7.5) return 0.0;
	float3 mine = key == best ? hit.xyz : float3(0.0); // exactly one lane holds the nearest hit
	float3 h = shadeQuadSum(mine);
#ifdef SHADE_WATER_EDGE_REFL
	if (shadeSsrBelowStart(h.xy, p0, r, f, depth)) return 0.0; // quad-uniform (h, p0, r are)
#endif
#ifdef SHADE_SSR_LANE
	// FT1.3: the quad marched one shared ray, and its one hit point drew the mirrored image in 2x2-pixel blocks (jagged shores and
	// trees, mirrored clouds' edges in steps: "reflejos pixeleados"). Each lane reads the hit along its OWN ray at the shared
	// hit's distance instead: one projection per pixel, no extra march (where the distance differs within the quad, e.g. at a
	// mirrored silhouette, the lane lands on what its own ray sees there: a sharper edge)
	if (best < 3.5) { // (FT2.6.1: not for a crossing behind something, which is not on the ray)
		float2 sz = shadeWaterRenderSize(f, float2(depth.get_width(), depth.get_height()));
		float zh = depth.read(uint2(clamp(h.xy * sz, float2(0.0), sz - 1.0)));
		float4 hp = f.invViewProj * float4(h.xy * 2.0 - 1.0, zh, 1.0);
		float T = dot(hp.xyz / hp.w - p0, r);
		float4 cl = f.viewProj * float4(p0Own + rOwn * max(T, 0.0), 1.0);
		if (cl.w > 1e-4) {
			float2 uvl = cl.xy / cl.w * 0.5 + 0.5;
			// (FT2.8, audit idx 34) not onto the sky: at a mirrored silhouette a lane's own ray point can be sky, which has no depth
			// to haze from (it took the far plane's ~900 blocks of haze: a light dotted rim around mirrored crowns and shores)
			if (uvl.y > 0.0 && uvl.y < 1.0) {
				float2 ul = float2(clamp(uvl.x, 0.5 / sz.x, 1.0 - 0.5 / sz.x), uvl.y);
				// 1.2.7 (audit B2): and only onto the same surface: ripples tilt the lanes' rays apart, and 100-250 blocks out a lane
			// landed on the lake bottom or nearer foliage next to every mirrored silhouette, which read the lake's own bright
			// sky reflection from last frame (wavy white streaks inside mirrored hills)
			float zl = depth.read(uint2(clamp(ul * sz, float2(0.0), sz - 1.0)));
			float wh = shadeLinearW(zh, f), wl = shadeLinearW(zl, f);
			if (zl > 0.0 && abs(wl - wh) < max(1.5, 0.08 * wh)) h.xy = ul;
			}
		}
	}
#endif
	tHit = shadeSsrHitT(h.xy, p0, f, depth);
#ifdef SHADE_PRICE_NOHAZE
	return float4(shadeWaterHitColor(h.xy, p0, exposure, prevExposure, f, nullptr, scene, depth, prev), h.z);
#endif
	return float4(shadeWaterHitColor(h.xy, p0, exposure, prevExposure, f, L, scene, depth, prev), h.z);
#else
	if (!shadeSsrSegment(p0, r, maxDist, f, s0, ds, screenEnd)) return 0.0;
	float4 hit = shadeSsrMarch(s0, ds, screenEnd, 0, 1, shadeNoise(pixel, SHADE_WATER_NOISE_FRAME(f)), f, depth, hz);
	if (hit.w < 0.0) return 0.0;
#ifdef SHADE_WATER_EDGE_REFL
	if (shadeSsrBelowStart(hit.xy, p0, r, f, depth)) return 0.0;
#endif
	tHit = shadeSsrHitT(hit.xy, p0, f, depth);
	return float4(shadeWaterHitColor(hit.xy, p0, exposure, prevExposure, f, L, scene, depth, prev), hit.z);
#endif
}
static inline float4 shadeSsr(float3 p0, float3 r, float2 pixel, float maxDist, float exposure, float prevExposure, constant ShadeFrame &f,
                              constant ShadeLook *L, texture2d<half> scene, depth2d<float> depth, texture2d<half> prev, texture2d<float> hz) {
	float t;
	return shadeSsrT(p0, r, pixel, maxDist, exposure, prevExposure, f, L, scene, depth, prev, hz, t);
}

// ---- optics -------------------------------------------------------------------------------------------------------------------
// Schlick's Fresnel for water (n = 1.333, f0 = 0.0204), cosine on the air side.
static inline float shadeWaterFresnel(float cosT) {
	float m = 1.0 - saturate(cosT);
	float m2 = m * m;
	return 0.0204 + 0.9796 * m2 * m2 * m;
}

// GGX (Trowbridge-Reitz) specular of the sun or moon off a surface with normal n, viewed along v (camera to point),
// light from unit l; alpha = roughness^2. Radiance per unit sunColor (irradiance / pi), Smith-correlated visibility.
static inline float shadeGgxSpec(float3 n, float3 v, float3 l, float alpha) {
	float3 h = normalize(l - v);
	float nh = saturate(dot(n, h)), nl = saturate(dot(n, l)), nv = max(dot(n, -v), 1e-3);
	float a2 = alpha * alpha;
	float dd = nh * nh * (a2 - 1.0) + 1.0;
	float D = a2 / (3.14159265 * dd * dd);
	float gv = nl * sqrt(nv * nv * (1.0 - a2) + a2), gl = nv * sqrt(nl * nl * (1.0 - a2) + a2);
	float vis = 0.5 / max(gv + gl, 1e-5);
	return 3.14159265 * D * vis * nl * shadeWaterFresnel(dot(h, -v));
}

// Absorption (1/block) from the biome's water colour (the vertex tint, linear): pure water's red-first absorption plus the
// tint's own darkness per channel (vanilla's default blue gives clear teal shallows and deep blue; swamp water turns green
// and murky; warm oceans stay clear cyan).
static inline float3 shadeWaterSigmaALin(float3 tintLinear) {
	float3 t = max(tintLinear, float3(0.004));
	return float3(0.26, 0.07, 0.035) + 0.09 * -log(t);
}
static inline float3 shadeWaterSigmaA(half3 tint) {
	return shadeWaterSigmaALin(float3(shadeToLinear(tint)));
}
#define SHADE_WATER_SIGMA_S 0.022 // scattering (1/block), grey: the blue of deep water comes from absorbing red and green

// A 2D value noise in [0, 1] (smooth, cheap: four hashed lattice corners), for the foam's patches.
static inline float shadeWaterHash2(float2 c) {
	uint2 i = uint2(int2(c) + int2(32768));
	uint h = i.x * 0x8da6b343u ^ i.y * 0xd8163841u;
	h = (h ^ (h >> 15)) * 0x2c1b3c6du;
	h ^= h >> 12;
	return float(h & 0xffffu) * (1.0 / 65535.0);
}
static inline float shadeWaterValueNoise(float2 x) {
	float2 i = floor(x), fr = x - i;
	float2 u = fr * fr * (3.0 - 2.0 * fr);
	float a = shadeWaterHash2(i), b = shadeWaterHash2(i + float2(1, 0)), c = shadeWaterHash2(i + float2(0, 1)), d = shadeWaterHash2(i + float2(1, 1));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
// Camera-relative position of the depth copy's pixel q (over the rendered rect of size `size`).
static inline float3 shadeWaterViewPoint(depth2d<float> depth, uint2 q, float2 size, constant ShadeFrame &f) {
	float z = depth.read(q);
	float4 h = f.invViewProj * float4((float2(q) + 0.5) / size * 2.0 - 1.0, max(z, 1e-7), 1.0);
	return h.xyz / h.w;
}

#ifdef SHADE_WATER_DETAIL
#define SHADE_WATER_DETAIL_SCALE 3.3  // the fine ripples: the baked field this many times smaller
#define SHADE_WATER_DETAIL_AMP 0.30   // their height scale (slopes: x SHADE_WATER_DETAIL_SCALE)
#define SHADE_WATER_LONG 0.6          // the long waves' scale
#define SHADE_WATER_PIXEL 0.7         // how far the near ripples' sample point is pulled to its 1/16-block cell's centre
// The detail sample's rotation R (53 degrees) and its transpose; the detail field's coordinates for absolute xz x.
static inline float2 shadeWaterRot(float2 v) { return float2(0.6 * v.x - 0.8 * v.y, 0.8 * v.x + 0.6 * v.y); }
static inline float2 shadeWaterRotT(float2 v) { return float2(0.6 * v.x + 0.8 * v.y, -0.8 * v.x + 0.6 * v.y); }
// (no drift of its own: its layer, texture(22), is baked SHADE_WATER_DETAIL_SPEED times faster)
#ifndef SHADE_WATER_PATTERN_FAR
#define SHADE_WATER_PATTERN_FAR 0.075 // the pixel pattern ends at this footprint (blocks/pixel), faded from 0.6x of it
#endif
#ifndef SHADE_WATER_DETAIL_FAR
#define SHADE_WATER_DETAIL_FAR 96.0  // no detail sample beyond this (faded out from 0.6x of it; the wave strength is ~0.35 there, the mips
                                     // have averaged most ripples away, and the bay view costs ~0.06 ms less than at 140)
#endif
static inline float2 shadeWaterDetailXZ(float2 x) {
	return shadeWaterRot(x) * SHADE_WATER_DETAIL_SCALE + float2(23.7, 41.3);
}
#endif

// (FT2.11, mcopt.shade.water.falls = ShadeWaterIn.cave.w, Gael 2026-10-11: water "cayendo o en cascada se ve muy lisa por afuera y muy
// cuadrada") Moving water, after Photon (MIT snapshot 26c2906e: flowing water's waves run along the current and are ~2-5x stronger
// than still water's) and Complementary / BSL (their waves are laid on every face of the water, the sides too; technique only):
// All of it only in the translucent terrain's variant drawn while moving water is within ~96 blocks (WaterFlowScan; SHADE_LEAN_NOFALLS
// = none near: FT2.10's code exactly, the water shader being bound by registers), faded out from SHADE_WATER_FALL_RANGE x 2/3 to
// SHADE_WATER_FALL_RANGE blocks (inside the scanned box: the switch of variant never shows).
//  - a current (flowing water's top faces, which already carry their waves downstream) roughens them by 1 + SHADE_WATER_FLOW_ROUGH k
//    (the calm of a lake isn't a stream's). (Drawing them out along the flow into streaks was tried and dropped: +0.11 ms on every
//    water pixel, the water shader being bound by registers; Photon doesn't either: its current only aims and speeds its waves.)
//  - falling water's sides get the wave field too, finer and drawn out downward, sliding down, and white water (shadeWaterFallNormal,
//    shadeWaterFallFoam: by the terrain fragment around shadeWaterSurface).
// k: ShadeWaterIn.cave.w (1 = this look, 0 = FT2.10's).
#define SHADE_WATER_FLOW_ROUGH 1.4
#define SHADE_WATER_FALL_RANGE 96.0
// The look's strength at camera-relative p: k, faded out toward SHADE_WATER_FALL_RANGE.
static inline float shadeWaterMoving(float k, float3 p) {
	return k * (1.0 - smoothstep(SHADE_WATER_FALL_RANGE * (2.0 / 3.0), SHADE_WATER_FALL_RANGE, length(p)));
}

#ifdef SHADE_WATER_SWELL
// ---- the swell (2026-11-02, water round 1: work/notes/2026-11-02/water/DESIGN.md S1) ------------------------------------------
// The long waves above are calmed (FT1.3) and the ripples fade with distance and at grazing views, so the far sea was a perfect
// mirror (~0.05 degrees of tilt 100 blocks out from a shore). The swell is a third layer under them: 4 long waves of 23-41 blocks
// (periods 6-8 s, around the near set's mean direction +x+z), sharpened like ours (a e^(sin - 1): our own profile), on a 512-block
// lattice (periodic over shadeWaterXZ's 2048-block wrap: no jump). s1 and s2 are 21 degrees apart with close wavelengths: they
// beat into sets of bigger waves every ~5-6 crests. RMS slope 0.038 at strength 1. Added AFTER the ripples' grazing flattening:
// a 30-40 block wave bends the mirrored shores, trees and clouds in broad bands instead of shredding them, so it is not calmed
// toward the horizon; instead each train fades where a pixel spans more than 1/8..1/4 of its wavelength along it (crests that
// run along the view survive to the horizon) and what fades comes back as slope variance (a rough, not flat, surface: the
// Fresnel's cosine and the glint's width), as Distant Horizons' water already does (dh_terrain.fs.metal cosV). World-locked
// direction (a real swell comes from far storms; a 512-block pattern turning with the wind would slide). Computed by the terrain
// fragment like the fine ripples (shadeWaterDetailIn; inside shadeWaterNormal such code crashed the Metal compiler), into
// ShadeWaterIn.swell; shadeWaterAbove adds it. Live: ShadeWaterParams.swell (mcopt.shade.water.swell*), 0 = none.
#define SHADE_SWELL_COUNT 4
constant int3 SHADE_SWELL[SHADE_SWELL_COUNT] = { // 512-block lattice x, z (wavelengths 40.9, 33.8, 31.8, 22.8); slope a k in 1/1000
	int3(11, 6, 80), int3(15, 2, 56), int3(8, 14, 48), int3(19, 12, 40),
};
constant float SHADE_SWELL_PHASE[SHADE_SWELL_COUNT] = {0.9, 3.7, 5.3, 2.2};
#define SHADE_SWELL_MEAN 0.46576 // the mean of e^(sin - 1) = I0(1) / e: heights about the still level
#define SHADE_SWELL_VAR 0.1076   // the mean of (cos e^(sin - 1))^2 = I1(2) / 2 e^-2: a train's slope variance per (a k)^2
// x: absolute xz (shadeWaterXZ), t: shadeWaterTime, dxz: the position's screen derivatives (dfdx(p).xz, dfdy(p).xz), amp: the
// strength (> 0). Returns xy the slope (dh/dx, dh/dz) at amp, z the height at strength 1 (blocks about the still level), w the
// faded trains' slope variance at amp.
static float4 shadeWaterSwell(float2 x, float t, float4 dxz, float amp) {
	float4 o = 0.0;
	const float base = 6.2831853 / 512.0;
	for (int i = 0; i < SHADE_SWELL_COUNT; i++) {
		int3 l = SHADE_SWELL[i];
		float2 kv = float2(l.xy) * base;
		float k = length(kv); // (constants once unrolled)
		float2 dir = kv / k;
		float s = float(l.z) * 1e-3;
		// the pixel's extent along this train's wave vector, in wavelengths: full below 1/8, gone at 1/4
		float ext = max(abs(dot(dir, dxz.xy)), abs(dot(dir, dxz.zw))) * (k * (1.0 / 6.2831853));
		float lod = 1.0 - smoothstep(0.125, 0.25, ext);
		float th = dot(kv, x) + shadeWaterOmega(sqrt(9.81 * k) * 0.62) * t + SHADE_SWELL_PHASE[i];
		float c;
		float sn = sincos(th, c);
		float e = exp(sn - 1.0);
		float sa = s * amp;
		o.xy += dir * (sa * c * e * lod);
		o.z += (s / k) * (e - SHADE_SWELL_MEAN) * lod;
		o.w += sa * sa * SHADE_SWELL_VAR * (1.0 - lod * lod);
	}
	return o;
}
// The swell's slope s as the eye at unit view direction v (camera to point) sees it: a facet turned away from the eye by more
// than k tan(depression) would mirror below the horizon; in reality it hides behind the crest in front (Smith-like masking), so
// its slope along the view is clamped there (k 0.45 < 1/2: it mirrors just above the horizon, bright). Facets turned toward the
// eye stay: they mirror the higher, bluer sky and their Fresnel drops (the light and dark bands of a real sea at grazing views),
// and no reflected ray dips under the horizon for SSR to chase.
static inline float2 shadeWaterSwellMask(float2 s, float3 v, float k) {
	float2 vh = v.xz * rsqrt(max(dot(v.xz, v.xz), 1e-8));
	float al = dot(s, vh);
	return s + vh * (max(al, -k * (-v.y) * rsqrt(max(1.0 - v.y * v.y, 1e-6))) - al);
}
#ifdef MCOPT_HDR
// (S2) How much of the swell the water at camera-relative p gets: the open-water map near the camera (ShadeResources.waterOpen,
// WaterOpenScan: distance to the shore x the biome's gain; toroidal, 2 blocks per texel, 256 across: the 2048-block wrap of
// shadeWaterXZ is 8 tiles, so they agree), its outer ring's mean (wp.swell2.x) farther than the map reaches (faded over 96-120 blocks,
// which also hides the toroidal seam and a map a few frames behind a flight). 1 without a map (wp.swell2.x < 0).
static inline float shadeWaterOpen(float3 p, constant ShadeFrame &f, constant ShadeWaterParams &wp, texture2d<half> open) {
	if (wp.swell2.x < 0.0) return 1.0;
	constexpr sampler s(filter::linear, address::repeat, coord::normalized);
	float o = float(open.sample(s, shadeWaterXZ(p.xz, f) * (1.0 / 256.0), level(0.0)).r);
	return mix(o, wp.swell2.x, smoothstep(96.0, 120.0, length(p.xz)));
}
#endif
#endif

// ---- the surface ------------------------------------------------------------------------------------------------------------
struct ShadeWaterIn {
	float3 p;        // camera-relative position of the surface fragment
	float3 nFace;    // geometric face normal, turned toward the camera ((FT2.11) on falling water's sides tilted by their ripples: shadeWaterFallNormal)
	float footprint; // blocks per pixel on the surface (wave LOD)
	float2 flowDir;  // world xz direction of the current (flowing water's top faces), 0 for still water
	float2 pixel;    // fragment position (pixels, = memory row order of the copies)
	float depth;     // the fragment's depth (reversed-Z)
	half3 tint;      // vertex colour: biome water colour x vanilla AO
	half sky;        // sky light 0..1
	half shadow;     // sun/moon visibility at the surface (shadow map)
	half4 cave;      // (FT2.10) water the sky doesn't light (shadeWaterAbove): x the torch light's caustics weight, y the ripples' share in its
	                 // reflections, z its surroundings' share in them (the sky's shape in the place's light), w (FT2.11) moving water's look
	                 // (mcopt.shade.water.falls, ShadeLook.bloom.w; 0 = FT2.10): ripples on falling water's sides, rougher streaky currents
	float3 lit;      // light on an upward white surface (shadeLit(1, up, ...)): sun, sky and block light, radiance
	float4 dxz;      // screen derivatives of the position's xz (dfdx(p).xz, dfdy(p).xz): the baked waves' mip/anisotropy
	float exposure;  // the exposure this frame is drawn with (M1: sf.time.z; M2 HDR: ShadeGpu.exposure.x)
	float prevExposure; // M2 HDR: the exposure `prev` was drawn with (ShadeGpu.exposure.z); 0 = no prev (M1, first frame)
	constant ShadeLook *look; // M2 HDR: the art layer (haze for what is read from `prev`); nullptr otherwise
	constant ShadeResources *res; // M3 HDR: ShadeResources (the clouds' reflection dome); nullptr otherwise
	float3 fog;      // the game's fog colour as radiance before exposure (the water seen from below, the TIR fallback)
	float4 detail;   // (SHADE_WATER_DETAIL, top faces) shadeWaterDetailIn: xy fine-ripple slope (world, before the strength),
	                 // z their height, w the pixel pattern; 0 where not computed
#ifdef SHADE_WATER_SWELL
	float4 swell;    // (2026-11-02, still water's top faces seen from above) shadeWaterSwell at p; 0 = none
#endif
};

#ifdef SHADE_WATER_DETAIL
// M2.1's fine ripples on a top face (and, with the camera under water, the surface seen from below): the detail octave's slope (world units, before the wave strength), its height and the
// pixel pattern, for ShadeWaterIn.detail. The long swell alone read as smooth, blobby "clay" (and bent the bottom like
// jelly): calmer long waves plus a sample of the detail layer (the same wave set baked SHADE_WATER_DETAIL_SPEED times faster,
// shade_water_bake_detail_fs), SHADE_WATER_DETAIL_SCALE times smaller and turned 53 degrees, gives fine ripples (with their
// own mips: no shimmer far away; faded out by SHADE_WATER_DETAIL_FAR, where the waves are calm anyway). The slope of h(s R x) is s R^T grad h.
// Near the camera the sample point is pulled toward the centre of its 1/16-block cell (the block texture's pixel grid), so
// the ripples read like the pixel-art water texture, but each cell's value changes smoothly with time (no 10 fps texture
// animation steps); the snap ends before a cell gets smaller than a pixel (it would alias). Pattern: the crest-ness out to
// a footprint of SHADE_WATER_PATTERN_FAR blocks/pixel (0 farther): minus the field's Laplacian, which the shortest waves
// dominate (cell-sized features, not the swell), in standard deviations (sd 0.19). It must end with the cell snap: past
// it the unsnapped Laplacian of the two shortest (regular, plane) waves reads as a diamond lattice on mid-distance water
// (seen from a hill; out to 0.12 it did).
// Called by the terrain fragment before shadeWaterSurface: written inside shadeWaterNormal (inlined into the surface from
// above and from below, SSR, caustics), any version of it made the Metal compiler service crash building the HDR translucent
// pipeline (XPC_ERROR_CONNECTION_INTERRUPTED, macOS 26.6, M4), and as a noinline call it cost ~0.2 ms more in the bay
// view (WATER_M21.md, wp3 vs wp4).
// (no anisotropy: the long-wave sample carries it; the detail matters near the camera, where the footprint is round)
constexpr sampler shadeWaveDetailSampler(filter::linear, mip_filter::linear, address::repeat);
static inline float4 shadeWaterDetailIn(ShadeWaterIn w, constant ShadeFrame &f, texture2d<half> waves) {
	const float s = SHADE_WATER_DETAIL_SCALE;
	float far = 1.0 - smoothstep(0.6 * SHADE_WATER_DETAIL_FAR, SHADE_WATER_DETAIL_FAR, length(w.p));
	if (far <= 0.0) return float4(0.0);
	float t = shadeWaterTime(f);
	float2 xa = shadeWaterXZ(w.p.xz, f);
	float2 x = xa - w.flowDir * (t * SHADE_WATER_FLOW_SPEED); // as shadeWaterNormal: flowing water carries its waves downstream
	float2 cell = (floor(xa * 16.0) + 0.5) * (1.0 / 16.0) - w.flowDir * (t * SHADE_WATER_FLOW_SPEED);
#ifdef SHADE_WATER_SMOOTH
	// FT1.3 (style photon): no 1/16-block cells and no crest pattern: each cell tilted the reflection on its own, and mirrored
	// clouds and shores broke into small rectangles (Gael: "reflejos pixeleados")
	float q = 0.0, nearP = 0.0;
#else
	float near = 1.0 - smoothstep(0.03, 0.065, w.footprint);
	float q = near * SHADE_WATER_PIXEL;
	float nearP = 1.0 - smoothstep(0.6 * SHADE_WATER_PATTERN_FAR, SHADE_WATER_PATTERN_FAR, w.footprint);
#endif
	float g = (1.0 - q) * (s / SHADE_WAVE_TILE); // a snapped coordinate changes slower across the pixel
	half4 d = waves.sample(shadeWaveDetailSampler, shadeWaterDetailXZ(mix(x, cell, q)) * (1.0 / SHADE_WAVE_TILE),
	                       gradient2d(shadeWaterRot(w.dxz.xy) * g, shadeWaterRot(w.dxz.zw) * g));
	return float4(shadeWaterRotT(float2(d.xy)) * (s * far), float(d.z) * far, -float(d.w) * (nearP / 0.19));
}
#endif

#ifdef SHADE_WATER_SMOOTH
// FT1.3 (style photon, after Photon's calm, mirror-like water: technique only, our own code): how much of the wave slopes the
// surface shows at camera-relative p. Calmer in clear weather; patches of calmer and rougher water ~200 blocks across that
// drift slowly (wind gusts, so a still lake isn't one repeated tile); flatter at grazing view angles, where the far surface
// mirrors the sky and shores like a calm lake does (and the waves would only alias into noise).
// x: the long swell's factor; y: the fine ripples' (they make the texture: they break the mirrored images into streaks and
// the sun into sparkles, as on real water, while the calm swell keeps far shores and clouds readable).
// In clear weather the long waves' slopes are wp.swell2.z (mcopt.shade.water.calm, 0.55 x the M2.1 set) and the fine ripples'
// wp.swell2.w (mcopt.shade.water.ripple, 2.0 x the M2.1 detail layer); rain brings them to 1 and 1.3 (2026-11-02: read every frame,
// they were startup defines).
static inline float2 shadeWaterCalm(float3 p, constant ShadeFrame &f, constant ShadeWaterParams &wp) {
	float t = shadeWaterTime(f);
	float2 x = shadeWaterXZ(p.xz, f);
	float patch = shadeWaterValueNoise(x * (1.0 / 190.0) + float2(t * 0.011, t * 0.007));
	float3 v = normalize(p - shadeEye(f.invViewProj));
	float graze = 0.55 + 0.45 * smoothstep(0.0, 0.1, abs(v.y));
	float rain = saturate(wp.state.z);
	return float2(mix(wp.swell2.z, 1.0, rain) * (0.6 + 0.8 * patch), mix(wp.swell2.w, 1.3, rain) * (0.75 + 0.5 * patch)) * graze;
}
#endif

// The wave normal at camera-relative p (+y up), and the height there. detail: the weight of M2.1's fine ripples
// (SHADE_WATER_DETAIL, w.detail; 0 = M2's long waves at full strength).
static float3 shadeWaterNormal(ShadeWaterIn w, constant ShadeFrame &f, constant ShadeWaterParams &wp, texture2d<half> waves, thread float &height,
                               thread float &pattern, float detail = 1.0) {
	pattern = 0.0;
	float t = shadeWaterTime(f);
	float2 x = shadeWaterXZ(w.p.xz, f) - w.flowDir * (t * SHADE_WATER_FLOW_SPEED); // flowing water carries its waves downstream
#ifdef SHADE_LEAN_NOFALLS
	const float mv = 0.0;
#else
	float mv = shadeWaterMoving(float(w.cave.w), w.p); // (FT2.11) a current roughens them (mcopt.shade.water.falls)
#endif
#ifdef SHADE_WATER_SMOOTH
	const float fade = 1.0 / 170.0; // FT1.3: the ripples' texture carries farther (Gael's references: textured to the horizon)
#else
	const float fade = 1.0 / 90.0;
#endif
	float strength = wp.tune.x * (1.0 + 1.6 * wp.state.z) * (1.0 + (0.6 + SHADE_WATER_FLOW_ROUGH * mv) * length(w.flowDir)) * exp(-length(w.p) * fade);
#ifdef SHADE_WAVE_BAKE
	if (wp.state.w > 0.5) { // this frame's bake exists
		half4 b = waves.sample(shadeWaveSampler, x * (1.0 / SHADE_WAVE_TILE), gradient2d(w.dxz.xy * (1.0 / SHADE_WAVE_TILE), w.dxz.zw * (1.0 / SHADE_WAVE_TILE)));
		height = float(b.z) * strength;
		float2 gb = float2(b.xy) * strength;
#ifdef SHADE_WATER_DETAIL
		if (detail > 0.0) { // M2.1's fine ripples (shadeWaterDetailIn, computed by the caller)
			pattern = w.detail.w;
#ifdef SHADE_WATER_SMOOTH
			float2 calm = shadeWaterCalm(w.p, f, wp); // FT1.3: the swell calm, the ripples a little stronger (texture)
			height = (float(b.z) * (SHADE_WATER_LONG * calm.x) + w.detail.z * (SHADE_WATER_DETAIL_AMP * detail * calm.y)) * strength;
			gb = (float2(b.xy) * (SHADE_WATER_LONG * calm.x) + w.detail.xy * (SHADE_WATER_DETAIL_AMP * detail * calm.y)) * strength;
#else
			height = (float(b.z) * SHADE_WATER_LONG + w.detail.z * (SHADE_WATER_DETAIL_AMP * detail)) * strength;
			gb = (float2(b.xy) * SHADE_WATER_LONG + w.detail.xy * (SHADE_WATER_DETAIL_AMP * detail)) * strength;
#endif
		}
#ifdef SHADE_WATER_SMOOTH
		else {
			float c = shadeWaterCalm(w.p, f, wp).x;
			gb *= c;
			height *= c;
		}
#endif
#endif
		return normalize(float3(-gb.x, 1.0, -gb.y));
	}
#endif
	float lap;
	float2 g = shadeWaves(x, t, strength, w.footprint, lap, height);
#if defined(SHADE_WAVE_BAKE) && defined(SHADE_WATER_SMOOTH)
	// (FT2.8, audit idx 37) the frame water comes back after frames without it the bake was skipped: the analytic waves, scaled as
	// the baked path scales its swell (calm; x SHADE_WATER_LONG where the ripples take over), not ~3x steeper for that frame
	{
		float k = shadeWaterCalm(w.p, f, wp).x;
#ifdef SHADE_WATER_DETAIL
		if (detail > 0.0) k *= SHADE_WATER_LONG;
#endif
		g *= k;
		height *= k;
	}
#endif
	return normalize(float3(-g.x, 1.0, -g.y));
}

#ifdef SHADE_WAVE_BAKE
// (FT2.11) Falling water's sides (vertical faces of the water; FT2.10 drew them as flat glass): the baked wave field laid on the face,
// SHADE_WATER_FALL_SCALE times finer, drawn out downward by 1 / SHADE_WATER_FALL_STRETCH and sliding down at SHADE_WATER_FALL_SCROLL
// (streaks running down the fall, as the vanilla flow texture runs down in Complementary and BSL, here as waves: Gael wants the realistic
// water everywhere). Strength k (ShadeWaterIn.cave.w, faded with distance and toward grazing views, where Photon fades its waves on
// such faces too: the ripples would only alias there). White water: thin aerated streaks running down the fall faster than
// the ripples (three octaves of value noise, cells 1/7 block wide and ~3 tall), 0..SHADE_WATER_FALL_FOAM over a faint whitening of
// the whole sheet; where the streaks would shrink below a pixel they average into that sheet's mean (no flicker, no switch to glass).
// Both are done by the terrain fragment AROUND shadeWaterSurface, which stays FT2.10's: the ripples tilt the face normal it is given
// (ShadeWaterIn.nFace, used as the surface's normal on side faces), the white water is laid over its result. The water shader is bound by
// registers: this code cost every water pixel 0.1-0.3 ms in the lake spin even where it never ran, inside the function or around it
// (FT2.11 prices, LEAN_DEV): hence the variant (SHADE_LEAN_NOFALLS) when no moving water is near.
#define SHADE_WATER_FALL_SCALE 3.0
#define SHADE_WATER_FALL_STRETCH 0.3
#define SHADE_WATER_FALL_SLOPE 0.9         // the slopes' scale at k = 1 (x the finer field's own: ~8x a calm lake's ripples; t1 at 0.45 hardly showed)
#define SHADE_WATER_FALL_SCROLL (192.0 / SHADE_WATER_CLOCK_WRAP) // tiles per second down (a whole number of tiles per clock wrap: no jump)
#define SHADE_WATER_FALL_FOAM 0.32
#define SHADE_WATER_FALL_SHEET 0.07 // the whole falling sheet a little white (aerated)
#define SHADE_WATER_FOAM_SCROLL (8960.0 / SHADE_WATER_CLOCK_WRAP) // noise cells per second down (2.19; whole cells per wrap: no jump)
// Whether a water face of geometric normal ny (y component) is a falling water's side with this look on (mv = ShadeLook.bloom.w) and
// this frame's bake there.
static inline bool shadeWaterIsFall(float ny, float mv, constant ShadeWaterParams &wp) {
	return mv > 0.0 && abs(ny) < 0.5 && wp.state.w > 0.5;
}
// The face normal of a falling water's side tilted by its ripples (w: the surface as filled in for shadeWaterSurface, nFace still the
// geometric one).
static float3 shadeWaterFallNormal(ShadeWaterIn w, constant ShadeFrame &f, texture2d<half> waves) {
	float3 nf = w.nFace;
	float3 v = normalize(w.p - shadeEye(f.invViewProj));
	float3 tu = normalize(float3(-nf.z, 0.0, nf.x)); // across the fall (horizontal, in the face)
	float2 xa = shadeWaterXZ(w.p.xz, f);
	float ya = w.p.y + f.cameraFract.y + fmod(f.cameraBlock.y, 2048.0);
	float2 c = float2(dot(xa, tu.xz), ya * SHADE_WATER_FALL_STRETCH) * (SHADE_WATER_FALL_SCALE / SHADE_WAVE_TILE);
	c.y += shadeWaterTime(f) * SHADE_WATER_FALL_SCROLL;
	// the field's texels per pixel across the fall (the finer axis): its mip
	float lod = max(log2(max(w.footprint * (SHADE_WATER_FALL_SCALE * float(SHADE_WAVE_BAKE_SIZE) / SHADE_WAVE_TILE), 1e-4)), 0.0);
	half4 b = waves.sample(shadeWaveSampler, c, level(lod));
	float k = shadeWaterMoving(float(w.cave.w), w.p) * SHADE_WATER_FALL_SLOPE * exp(-length(w.p) * (1.0 / 120.0)) * smoothstep(0.0, 0.3, abs(dot(nf, v)));
	float2 s = float2(b.xy) * (float2(SHADE_WATER_FALL_SCALE, SHADE_WATER_FALL_SCALE * SHADE_WATER_FALL_STRETCH) * k);
	return normalize(nf - s.x * tu - s.y * float3(0.0, 1.0, 0.0));
}
// The white water's share at camera-relative p on a falling water's side of geometric normal nf, footprint blocks per pixel, mv the
// look's strength.
static float shadeWaterFallFoam(float3 p, float3 nf, float footprint, float mv, constant ShadeFrame &f) {
	float3 tu = normalize(float3(-nf.z, 0.0, nf.x));
	float2 xa = shadeWaterXZ(p.xz, f);
	float ya = p.y + f.cameraFract.y + fmod(f.cameraBlock.y, 2048.0);
	float2 q = float2(dot(xa, tu.xz) * 7.0, ya * 0.35 + shadeWaterTime(f) * SHADE_WATER_FOAM_SCROLL);
	float nz = 0.5 * shadeWaterValueNoise(q) + 0.3 * shadeWaterValueNoise(q * 2.0 + float2(17.3, 5.1)) + 0.2 * shadeWaterValueNoise(q * 4.0 + float2(3.7, 41.9));
	float near = 1.0 - smoothstep(0.03, 0.08, footprint); // cells of 1/7 block: below ~2 pixels across they'd alias
	return (SHADE_WATER_FALL_SHEET + SHADE_WATER_FALL_FOAM * mix(0.3, smoothstep(0.45, 0.8, nz), near)) * (min(shadeWaterMoving(mv, p), 1.5) * exp(-length(p) * (1.0 / 120.0)));
}
#endif

// Caustic focusing (1 = none) on a bottom at camera-relative pf, depth dy under the surface. The sun's rays that reach pf
// crossed the surface up-sun of it; there the waves' curvature bends them together or apart, and the light per area is the
// inverse Jacobian of the refraction mapping x -> x + dy (1 - 1/n) grad h: 1 / |det(I + k Hessian(h))|. Where the
// determinant crosses zero (focal curves) the light bunches into the bright cell network of real caustics. Evaluated on
// a set of short waves of their own (well spread directions, so cells and not a lattice), each warping the next.
#define SHADE_CAUSTIC_COUNT 6
constant float4 SHADE_CAUSTIC_WAVES[SHADE_CAUSTIC_COUNT] = {
	//   dir x,  dir z, wavelength, amplitude
	float4( 0.940,  0.342, 2.60, 0.018),
	float4(-0.276,  0.961, 2.10, 0.015),
	float4( 0.454, -0.891, 1.70, 0.012),
	float4(-0.866, -0.500, 1.37, 0.0095),
	float4( 0.643,  0.766, 1.11, 0.0075),
	float4(-0.985,  0.174, 0.89, 0.006),
};

static float shadeWaterCaustics(float3 pf, float dy, constant ShadeFrame &f, constant ShadeWaterParams &wp, float3 l) {
	float2 x = shadeWaterXZ(pf.xz + l.xz / max(l.y, 0.25) * dy, f);
	float t = shadeWaterTime(f);
	float3 hs = 0.0; // Hessian: xx, zz, xz
	for (int i = 0; i < SHADE_CAUSTIC_COUNT; i++) {
		float4 w = SHADE_CAUSTIC_WAVES[i];
		float k = 6.2831853 / w.z;
		float th = k * dot(w.xy, x) + shadeWaterOmega(sqrt(9.81 * k) * 0.55) * t + float(i) * 1.9;
		float c;
		float s = sincos(th, c);
		float e = exp(s - 1.0);
		float q = w.w * k * k * (c * c - s) * e;
		hs += q * float3(w.x * w.x, w.y * w.y, w.x * w.y);
		x -= w.xy * (c * e * w.w * 14.0); // strong mutual warping: irregular cells
	}
	float kk = min(dy, 5.0) * 0.25 * 3.2 * wp.tune.x * (1.0 + 0.8 * wp.state.z);
	float det = (1.0 + kk * hs.x) * (1.0 + kk * hs.y) - kk * kk * hs.z * hs.z;
	return min(1.0 / max(abs(det), 0.18), 4.0);
}

// (candidate 7) how far the mirrored images' normal is pulled toward the face's (the ripples' share in the reflection direction:
// 1 - this): wp.swell2.y (mcopt.shade.water.mirrorCalm), 0.55 before candidate 7 (and where the value is unset)
static inline float shadeWaterMirrorCalm(constant ShadeWaterParams &wp) { return wp.swell2.y > 0.0 ? wp.swell2.y : 0.55; }

#ifdef SHADE_WATER_MIRROR_AA
// (2026-11-06; research-taa-flicker.md fix 5, after Kaplanyan et al. 2016 and Tokuyoshi & Kaplanyan 2019/2021 specular antialiasing:
// technique only, our own code) The shading normal's spread across this 2x2 quad (its differences to the horizontal and vertical
// neighbours): ripples smaller than a pixel turn n a different way in each pixel and from frame to frame (the camera moves the
// samples over them), so they flip the mirrored ray and the glint's facet. Its variance (capped at 0.18) x wp.mirror.x calms the
// mirrored images' normal toward the face's (all the way at the cap) and widens the glint's lobe (alpha^2 + it); ripples a few
// pixels wide differ little between neighbours and keep their tilt. Every lane must call it (quad shuffles).
static inline float shadeWaterRippleVar(float3 n, constant ShadeWaterParams &wp) {
	float3 dx = n - quad_shuffle_xor(n, 1), dy = n - quad_shuffle_xor(n, 2);
	return min(0.5 * (dot(dx, dx) + dot(dy, dy)), 0.18) * wp.mirror.x;
}
static inline float shadeWaterCalmAA(float calm, float kr2) { return min(calm + (1.0 - calm) * kr2 * (1.0 / 0.18), 1.0); }
#define SHADE_MIRROR_CALM(wp, w) shadeWaterCalmAA(shadeWaterMirrorCalm(wp) - 0.4 * float((w).cave.y), rippleVar)
#else
#define SHADE_MIRROR_CALM(wp, w) (shadeWaterMirrorCalm(wp) - 0.4 * float((w).cave.y))
#endif

#ifdef SHADE_WATER_SWELL
// (2026-11-02, water round 1; STUDY.md "what we could do: water" item 2) The normal the mirrored images (SSR, the rendered sky)
// follow: calmer than the shading's for the ripples (n mixed toward the face's by calm: they wobble the images instead of shredding
// them), and the swell's slope sw (as added to n) at its own share (wp.swell3.x, mcopt.shade.water.swellRefl): 0.45 = as the
// ripples' (the swell is part of n); 1 = all of it: a long smooth wave bends whole shores and clouds without breaking them, so the
// far sea shows the sky's light-and-dark bands as Complementary's does (study only). The atmosphere LUT's direction is
// mix(rs, rr, 0.6): it follows 0.4 + 0.6 x share of the swell (0.67 at 0.45, all of it at 1), the ripples as before. The glint keeps
// the shading normal n (the swell whole, the ripples whole: the sun's own glitter road).
static inline float3 shadeWaterMirrorN(float3 n, float3 nFace, float calm, float2 sw, float share) {
	if (all(sw == 0.0)) return normalize(mix(n, nFace, calm));
	float3 nr = normalize(mix(normalize(n * (1.0 / n.y) + float3(sw.x, 0.0, sw.y)), nFace, calm)); // the ripples' part, calmed
	return normalize(nr * (1.0 / nr.y) + float3(-sw.x, 0.0, -sw.y) * share);
}
#endif

// Water seen from above (or a side face): reflection (SSR over the sky, sun glint), refraction of the bottom, absorption and
// in-scattering along the path through the water, caustics on the bottom, shoreline foam. Composites what is behind the
// water itself (draw with alpha 1). Radiance before exposure, without air fog between the camera and the surface.
static float3 shadeWaterAbove(ShadeWaterIn w, constant ShadeFrame &f, constant ShadeWaterParams &wp, texture2d<half> lut, sampler lutS,
                              texture2d<half> scene, depth2d<float> depth, texture2d<half> prev, texture2d<half> waves, texture2d<float> hz SHADE_RH_PARAMS) {
	float3 pe = w.p - shadeEye(f.invViewProj); // from the eye: view bobbing moves it (shade_common.metal)
	float dist = length(pe);
	float3 v = pe / max(dist, 1e-4);
	bool top = w.nFace.y > 0.5;
	float height = 0.0, pattern = 0.0;
	float3 n = w.nFace;
#ifdef SHADE_WATER_SWELL
	float cosV0 = 0.0; // (2026-11-02) the cosine without the swell, where there is one (wp.swell.w)
	float2 sw = 0.0;   // the swell's slope as added to n (masked)
#endif
	if (top) {
		n = shadeWaterNormal(w, f, wp, waves, height, pattern);
#if defined(SHADE_WEATHER) && defined(SHADE_RIPPLES)
		// M3 weather: raindrop rings on water under open sky (weather_surface.metal), faded out where they would alias
		if (wp.state.z > 0.02 && w.sky > 0.95h) {
			float rf = 1.0 - smoothstep(0.03, 0.06, w.footprint);
			if (rf > 0.0) {
				float2 rs = shadeWxRipples(shadeWxXZ(w.p.xz, f), f.sunPath.w, min(wp.state.z * 1.1, 1.0), w.footprint) * (rf * 1.4);
				n = normalize(n + float3(-rs.x, 0.0, -rs.y));
			}
		}
#endif
		// grazing angles: normals average out across a pixel and the far water calms into a mirror
		float graze = 1.0 - saturate(-v.y);
		n = normalize(mix(n, float3(0.0, 1.0, 0.0), 0.8 * graze * graze * graze * graze));
#ifdef SHADE_WATER_SWELL
		// (2026-11-02) the swell after that flattening (a 23-41 block wave doesn't average out across a pixel; where it would, the
		// caller's shadeWaterSwell has faded it into roughness), as the eye sees it (masked), its slope added to the ripples'
		if (any(w.swell != 0.0)) {
			cosV0 = max(dot(-v, n), 0.02);
			sw = shadeWaterSwellMask(w.swell.xy, v, wp.swell.y);
			n = normalize(n * (1.0 / n.y) + float3(-sw.x, 0.0, -sw.y));
		}
#endif
	}
	float cosV = max(dot(-v, n), 0.02);
#ifdef SHADE_WATER_SWELL
	if (cosV0 > 0.0) {
		// its share in the Fresnel (wp.swell.w: 1 physical, facets toward the eye mirror less and show the body; 0 the cosine without
		// it), and the trains a pixel averages over make the surface rough there, not flat
		float c = mix(cosV0, cosV, wp.swell.w);
		cosV = sqrt(c * c + w.swell.w * wp.swell.w);
	}
#endif
#ifdef SHADE_WATER_MIRROR_AA
	float rippleVar = shadeWaterRippleVar(n, wp); // (2026-11-06) the ripples a pixel can't resolve (quad-uniform here)
#endif
	float fres = min(shadeWaterFresnel(cosV) * wp.tune.z, 1.0); // (1.2.7, audit B12: the Reflections slider above 100 % made the
	// mix below extrapolate, the water brighter than the sky it mirrors, a white band toward the horizon)
#ifdef SHADE_LEAN_ABOVE
	// reflected images stay readable: SSR and the rendered sky follow a calmer normal than the shading (ripples wobble,
	// don't shred). (FT2.10, w.cave.y) Where no sky lights the water the reflected walls and torches are all its surface shows:
	// they follow the ripples like the sky's reflection on a lake shows its waves
#ifdef SHADE_WATER_SWELL
	float3 rr = reflect(v, shadeWaterMirrorN(n, w.nFace, SHADE_MIRROR_CALM(wp, w), sw, wp.swell3.x)); // (2026-11-02: the swell at its own share)
#else
	float3 rr = reflect(v, normalize(mix(n, w.nFace, SHADE_MIRROR_CALM(wp, w))));
#endif
	rr = normalize(float3(rr.x, max(rr.y, 0.01), rr.z));
#endif
	float tHit = -1.0; // (candidate 7) the SSR hit's distance along the mirrored ray (-1: the sky, or no march)
#if defined(SHADE_SSR) && defined(SHADE_LEAN_ABOVE)
	// looking steeply down (within ~45 degrees of straight down) the surface reflects 2% and what it would mirror is mostly
	// behind the camera: no march there, faded in up to ~50 degrees (quad-uniform: SSR's lanes work together). Marched
	// first, before the refraction and the body (2026-10-08, price5: -0.08 ms over the lake, the same image): fewer of their
	// values are live across the march (the water shader is bound by registers)
	float4 ssrHit = float4(0.0);
	float ssrW = 0.0;
	float fq = shadeQuadMax(shadeWaterFresnel(cosV));
	if (fq > 0.022 && wp.tune.y > 0.0 && !SHADE_WDEV_IS(f, SHADE_WDEV_NO_SSR)) { // (1.1) tune.y 0: the player turned screen reflections off
		ssrHit = shadeSsrT(w.p + n * 0.02, rr, w.pixel, wp.tune.y, w.exposure, w.prevExposure, f, w.look, scene, depth, prev, hz, tHit, wp.mirror.y);
		ssrW = ssrHit.a * smoothstep(0.022, 0.03, fq);
	}
#endif

	// --- what is behind the surface: refraction, absorption, in-scattering, caustics
	float2 tex = float2(scene.get_width(), scene.get_height());
	float2 size = shadeWaterRenderSize(f, tex);
	float2 uv = w.pixel / size; // over the rendered rect
	float wSurf = shadeLinearW(w.depth, f);
	float w0 = shadeWaterSceneW(depth, uint2(min(w.pixel, size - 1.0)), f);
	float dw0 = w0 < SHADE_WATER_SKY_W ? w0 - wSurf : 64.0;
	// only the waves' tilt shifts the bottom (a flat surface doesn't), more for deeper water, in view space
	float3 tilt = (f.view * float4(n - w.nFace, 0.0)).xyz;
#ifdef SHADE_WATER_DETAIL
	float2 shift = tilt.xy * (0.16 * min(max(dw0, 0.0), 4.0)); // M2.1: a small shift (M2's bent underwater blocks like jelly)
#else
	float2 shift = tilt.xy * (0.4 * min(max(dw0, 0.0), 6.0));
#endif
	if (w.look != nullptr) shift *= w.look->user1.w; // (1.1) user1.w: the player's refraction
	float2 uvR = uv + float2(f.proj[0][0] * shift.x, f.proj[1][1] * shift.y) * (0.5 / max(wSurf, 0.5));
	uvR = clamp(uvR, 0.5 / size, 1.0 - 0.5 / size);
	float wR = shadeWaterSceneW(depth, uint2(uvR * size), f);
	if (wR < wSurf) { // the shifted sample is in front of the water: no refraction there
		uvR = uv;
		wR = w0;
	}
	bool hasFloor = wR < SHADE_WATER_SKY_W; // something behind the water (else the sky: deep water to the horizon)
	float lView = hasFloor ? max(wR - wSurf, 0.0) * dist / max(wSurf, 1e-3) : 1e4;
	float dy = top ? lView * saturate(-v.y) : lView * 0.5;
	float3 sigmaA = shadeWaterSigmaA(w.tint);
	if (w.look != nullptr) {
		// (1.1) the player's water colour and clarity (ShadeSettings): ShadeLook.vl = the colour as a biome water colour would be
		// (linear) and its weight (0 = the biome's own); grade0.w divides the absorption (1 = as released)
		float4 uw = w.look->vl;
		if (uw.w > 0.0) sigmaA = mix(sigmaA, shadeWaterSigmaALin(uw.rgb), uw.w);
		float clarity = w.look->grade0.w;
		if (clarity > 0.0) sigmaA /= clarity;
	}
	float3 sigmaT = sigmaA + SHADE_WATER_SIGMA_S;
	float3 bottom = shadeWaterSceneRadiance(scene.sample(shadeWaterLinear, uvR * size / tex).rgb, w.exposure);
#ifdef SHADE_CAUSTICS
	if (top && wp.tune.w > 0.0 && dy > 0.05 && dy < 18.0) {
		float sunL = f.lightDirWorld.w > 0.5 ? smoothstep(0.1, 0.8, float(w.shadow)) * saturate(f.lightDirWorld.y * 4.0) * smoothstep(0.55, 0.9, float(w.sky)) : 0.0;
		// (FT2.10, w.cave.x) torchlight is bent by the ripples too: where it lights the bottom (block light; caves, a strip of water in
		// a base, a pool at night) its caustics play there like the sun's in a lake, the waves' texture under water the sky can't
		// show it by (Gael 2026-10-10: a strip of water in his base looked like flat glass next to the lakes)
		float torchL = float(w.cave.x) * (1.0 - sunL);
		float light = sunL + torchL;
		float fade = light * exp(-dy * 0.2) * saturate(dy * 3.0) * (1.0 - smoothstep(0.04, 0.12, w.footprint)); // fine lines alias far away
		if (fade > 0.02) { // deep, shaded or far bottoms: not worth the waves
			// (the torch's light comes from above and around: its focus straight down)
			float3 cl = sunL >= torchL ? f.lightDirWorld.xyz : float3(0.0, 1.0, 0.0);
			float c = shadeWaterCaustics(w.p + v * lView, dy, f, wp, cl);
			bottom *= mix(1.0, c * 0.8, min(0.75 * fade * wp.tune.w, 1.0)); // ~energy neutral: the focus averages a bit over 1 ((1.1) tune.w: user.caustics)
		}
	}
#endif
	float3 tBottom = exp(-sigmaT * (lView + dy)); // down to the bottom along the view, and the light's way down to it
	float3 tView = exp(-sigmaT * min(lView, 512.0));
	// light scattered toward the eye inside the water: what reaches a mean depth of ~2 blocks, single-scattering albedo
	float3 inScatter = w.lit * exp(-sigmaT * 2.0) * (SHADE_WATER_SIGMA_S / sigmaT) * 0.8;
	float3 body = bottom * tBottom + inScatter * (1.0 - tView);
#ifdef SHADE_WATER_DETAIL
	// M2.1: the surface's own pixel texture near the camera (1/16-block cells following the ripples, see shadeWaterDetailIn):
	// crests a little lighter, troughs a little darker, the sharpest crests as light specks (in the water's own hue), like
	// the block texture's light pixels but moving smoothly
	body *= 1.0 + 0.13 * clamp(pattern, -1.5, 2.5) + 0.35 * smoothstep(0.9, 2.0, pattern);
#endif
#ifdef SHADE_WATER_SWELL
	// (2026-11-02, S3; mcopt.shade.water.swellGlow, 0 = none) light through the crests: at golden hour, with the low sun ahead, the thin
	// tops of the swell's faces turned toward the eye glow in the water's own colour (turquoise for the default water), the backlit
	// wave. Sunlight that crossed ~1.5 blocks of crest, scattered forward (x4 stands for the forward-peaked phase function), into the
	// body, so exactly where those facets mirror less (1 - F). It follows the swell's LOD (fades with it far away) and the shadows
	// (terrain and clouds) at the surface.
	if (top && wp.swell.z > 0.0 && f.lightDirWorld.w > 0.5 && any(w.swell.xy != 0.0)) {
		float3 l = f.lightDirWorld.xyz;
		float2 vh = v.xz * rsqrt(max(dot(v.xz, v.xz), 1e-8)), lh = l.xz * rsqrt(max(dot(l.xz, l.xz), 1e-8));
		float ahead = saturate(dot(vh, lh));                                          // the sun behind the waves
		float low = smoothstep(0.0, 0.05, l.y) * (1.0 - smoothstep(0.12, 0.45, l.y)); // golden hour only
		float crest = saturate(w.swell.z * 2.5 + 0.5);                                 // 0 trough .. 1 crest
		float face = saturate(dot(w.swell.xy, vh) * 20.0);                             // the face toward the eye
		float g = wp.swell.z * ahead * ahead * ahead * low * crest * crest * face * float(w.shadow);
		if (g > 0.0) body += f.sunColor.rgb * exp(-sigmaT * 1.5) * (SHADE_WATER_SIGMA_S / sigmaT) * (4.0 * g);
	}
#endif

	// --- reflection: the sky (only as open as the sky light says), SSR over it, the sun's glint
	float open = float(shadeSkyCurve(w.sky));
	float3 r = reflect(v, n);
	float3 rs = float3(r.x, abs(r.y), r.z);
#ifndef SHADE_LEAN_ABOVE
	// reflected images stay readable: SSR and the rendered sky follow a calmer normal than the shading (ripples wobble,
	// don't shred); FT2.10: more of the ripples where no sky lights the water (w.cave.y, as above)
#ifdef SHADE_WATER_SWELL
	float3 rr = reflect(v, shadeWaterMirrorN(n, w.nFace, SHADE_MIRROR_CALM(wp, w), sw, wp.swell3.x)); // (2026-11-02: the swell at its own share)
#else
	float3 rr = reflect(v, normalize(mix(n, w.nFace, SHADE_MIRROR_CALM(wp, w))));
#endif
	rr = normalize(float3(rr.x, max(rr.y, 0.01), rr.z));
#endif
	// the LUT sky follows a calmer direction too: the rippled one smeared the low sun's aureole over the near water as a
	// milky veil (the glint below is what carries the sun's sparkle)
	float3 rl = normalize(mix(rs, rr, 0.6));
	float3 refl = shadeWaterSkyRefl(rl, rr, w.p, w.prevExposure, f, w.look, w.res, lut, lutS, depth, prev) * open;
	// (FT2.10, w.cave.z) where no sky lights the water, what it mirrors beyond SSR (off screen, behind the camera) was black: the
	// waves had nothing to show by, and a strip of water in a cave read as flat dark glass next to a lake's rippled sky (Gael
	// 2026-10-10: "debería de verse así con la textura realista siempre, aunque solo sea una fila"). Its surroundings instead: the
	// clear sky's shape (bright toward the horizon, dimmer above, as walls lit around and a darker ceiling) in the light and colour
	// of the place (the surface's own light, torches), as lit walls of albedo ~0.5. The same ripples then show as on a lake
	if (w.cave.z > 0.0h) {
		float sk = shadeLuma(shadeSkyLookup(float3(rl.x, max(rl.y, 0.0), rl.z), lut, lutS, f));
		float3 env = w.lit * (0.5 * sk / max(shadeLuma(f.ambientSky.rgb), 1e-6));
		refl = mix(refl, env, float(w.cave.z));
	}
	float hitWeight = 0.0;
#ifdef SHADE_SSR
#ifdef SHADE_LEAN_ABOVE
	hitWeight = ssrW;
#ifdef SHADE_WATER_PANO
	// (candidate 8) a mirrored ray that leaves the screen (its vanishing point is outside it) and found nothing on it: what the
	// panorama remembers there, under whatever the screen march did find (its hits past a side fade out toward the edge column's end)
	float panoW = 0.0;
#ifndef SHADE_PRICE_NOPANO
	if (top && hitWeight < 0.999 && wp.mirror.z > 0.0 && w.res != nullptr && w.look != nullptr && w.prevExposure > 0.0 && fq > 0.022) {
		float2 want = shadeWaterPanoWanted(w.p, rr, f);
		if (want.x > 0.0) {
			float4 pn = shadeWaterPano(w.p + n * 0.02, rr, want.y, w.prevExposure, f, w.look, w.res->reflPano);
			panoW = pn.a * want.x * min(wp.mirror.z, 1.0);
			refl = mix(refl, pn.rgb, panoW);
		}
	}
#endif
	refl = mix(refl, ssrHit.rgb, hitWeight);
	hitWeight = max(hitWeight, panoW); // (the glint is hidden there too)
#else
	refl = mix(refl, ssrHit.rgb, hitWeight);
#endif
#else
	// looking steeply down (within ~45 degrees of straight down) the surface reflects 2% and what it would mirror is mostly
	// behind the camera: no march there, faded in up to ~50 degrees (quad-uniform: SSR's lanes work together)
	float fq = shadeQuadMax(shadeWaterFresnel(cosV));
	if (fq > 0.022 && wp.tune.y > 0.0 && !SHADE_WDEV_IS(f, SHADE_WDEV_NO_SSR)) { // (1.1) tune.y 0: the player turned screen reflections off
		float4 hit = shadeSsrT(w.p + n * 0.02, rr, w.pixel, wp.tune.y, w.exposure, w.prevExposure, f, w.look, scene, depth, prev, hz, tHit, wp.mirror.y);
		hitWeight = hit.a * smoothstep(0.022, 0.03, fq);
		refl = mix(refl, hit.rgb, hitWeight);
	}
#endif
#endif
#ifdef SHADE_WATER_RHIST
	// (2026-11-06; work/notes/2026-11-06/research-taa-flicker.md fix 2, after Frostbite's SSSR "reflection depth" reprojection and NRD's
	// virtual motion: techniques only, our own code) The mirrored image's OWN history. Gael still saw the reflections near the camera
	// shimmer walking, running and jumping: the TAA reprojects a water pixel by its surface, but what it mirrors moves on screen as the
	// point behind the mirror (the virtual point, along the view ray at the eye's distance + the hit's), so the TAA clips that history
	// away; and SHADE_WATER_RTR below blends the whole colour by the Fresnel (0.8 F: ~10 % history 20-25 degrees above the surface).
	// Here the reflection term alone (before the Fresnel) keeps a history at the world target's resolution (mcwater.m, ping-pong):
	// read where the virtual point was last frame (the sky: its direction at infinity) in last frame's jittered raster, from texels
	// last frame wrote (their tag) for about the same virtual distance, kept inside this 2x2 quad's range of reflections widened by
	// wp.rhist.w (no ghost of anything it doesn't show now), blended by wp.rhist.x. Then written back for the next frame (top faces in
	// front of the opaque scene only).
	if (wp.rhist.x > 0.0) {
		float3 rlo = float3(shadeQuadMin(refl.r), shadeQuadMin(refl.g), shadeQuadMin(refl.b)); // (every lane: quad-uniform)
		float3 rhi = float3(shadeQuadMax(refl.r), shadeQuadMax(refl.g), shadeQuadMax(refl.b));
		bool hitV = hitWeight > 0.5 && tHit > 0.0;
		float vNow = hitV ? min(dist + tHit, 50000.0) : 60000.0;
		bool front = wSurf <= w0 * 1.0005 + 0.01; // this fragment is in front of the opaque scene (else the depth test drops it)
		if (top && front && wp.rhist.y > 0.5 && w.look != nullptr) {
			float4 pc = w.look->prevViewProjNoJitter * (hitV ? float4(w.p + v * tHit, 1.0) : float4(v, 0.0));
			if (pc.w > 1e-4) {
				// last frame's jittered raster: its pixel centre c + 0.5 showed the unjittered point c + 0.5 - jitter (ShadeFrame.jitter.zw)
				float2 tp = ((pc.xy / pc.w + f.jitter.zw) * 0.5 + 0.5) * size - 0.5;
				float2 b0 = floor(tp), fr = tp - b0;
				float3 acc = 0.0;
				float wsum = 0.0;
				for (int k = 0; k < 4; k++) {
					int2 q = int2(b0) + int2(k & 1, k >> 1);
					if (any(q < 0) || any(float2(q) > size - 1.0)) continue;
					half4 h = rhPrev.read(uint2(q));
					float a = float(h.a) * -wp.rhist.z; // > 0: written last frame
					float wk = ((k & 1) != 0 ? fr.x : 1.0 - fr.x) * ((k >> 1) != 0 ? fr.y : 1.0 - fr.y);
					if (a > 0.0 && abs(a - vNow) < 0.2 * vNow + 1.0) {
						acc += float3(h.rgb) * wk;
						wsum += wk;
					}
				}
				if (wsum > 0.3) {
					float3 pad = ((rhi - rlo) * 0.5 + rhi * 0.05) * wp.rhist.w;
					refl = mix(refl, clamp(acc / wsum, rlo - pad, rhi + pad), wp.rhist.x * saturate(wsum * 2.0 - 0.6));
				}
			}
		}
		if (top && front) rhOut.write(half4(half3(clamp(refl, 0.0, 60000.0)), half(vNow * wp.rhist.z)), uint2(w.pixel));
	}
#endif
	// the sun's (or moon's) glint: rougher with distance (normals average out: long glitter roads) and in rain; it carries
	// its own Fresnel, hidden where SSR found something in front of the sky
#ifdef SHADE_WATER_GLINT_GRAZE
	// M3 (mcopt.shade.waterGlintGraze): the widening only at grazing views, where a pixel's footprint stretches along the
	// view over many waves (low over the sea: the glitter road as before). Seen from high up the waves are resolved: the
	// widened lobe lit the near water from a low sun as a broad glow, which the terrain's long sunset shadows cut into
	// bright rectangles (Gael's sunset report, 2026-10-07)
	float far = saturate(dist / 110.0) * (1.0 - smoothstep(0.1, 0.4, -v.y));
#else
	float far = saturate(dist / 110.0);
#endif
	// (candidate 5, Gael's Photon references: the sun's road there is a narrow column of separate bright dashes) the base roughness
	// x wp.swell3.z (mcopt.shade.water.glintSharp): the resolved ripples already spread the road; 0.035 drew each facet's sun ~4x the
	// sun disk, a broad smooth ribbon
	float alpha = 0.035 * wp.swell3.z + 0.10 * far + 0.06 * wp.state.z;
#ifdef SHADE_WATER_SWELL
	alpha = sqrt(alpha * alpha + w.swell.w); // (2026-11-02) the swell a pixel averages over widens the glitter road
#endif
#ifdef SHADE_WATER_MIRROR_AA
	alpha = sqrt(alpha * alpha + rippleVar); // (2026-11-06) and so do the ripples a pixel can't resolve
#endif
	float spec = shadeGgxSpec(n, v, f.lightDirWorld.xyz, alpha);
#if defined(SHADE_WATER_GLITTER) && defined(SHADE_WATER_DETAIL)
	// (2026-11-02; STUDY.md "what we could do: water" item 3, after Complementary's sparkle term: technique only, our own code;
	// mcopt.shade.water.glitter, 0 = none) glitter: the glint times a facet contrast ((n_r.l) / (n.l))^4 from a rougher normal n_r:
	// facets tilted toward the sun light up, those tilted away go dark, so near the camera the road breaks into sparkles. n_r is n
	// plus the fine ripples' slope turned 90 degrees, at 1.5x the waves' strength: the same ripple features, but a tilt uncorrelated
	// with n's (a rougher normal made of n's own ripples would light exactly the facets the glint already picks, n ~ h, and only
	// reshape the road). Divided by its mean for that spread (E(1 + d)^4 = 1 + 6 s2 + 3 s2^2; s2 = the extra tilt's variance along
	// the sun, RMS ripple slope 0.077 per axis x 1.5 x the waves' strength, less what the mips average away at this footprint and
	// the ripples' own fade with distance, over (n.l)^2), so the road keeps ~0.8-0.95 of its energy (a Monte Carlo of the formula, sun
	// elevation sine 0.05-0.8; ~6-8 % of the road's pixels over 3x at golden hour). With a grazing sun the extra tilt is capped so
	// that spread stays <= 0.3 (else a few clamped sparkles and a dark road). It fades back to the plain glint by 0.6 blocks per pixel
	// (no sub-pixel sparkles to flicker under TAAU): far away the road stays smooth.
	if (top && wp.swell3.y > 0.0 && spec > 0.0) {
		float near = (1.0 - smoothstep(0.08, 0.6, w.footprint)) * wp.swell3.y;
		if (near > 0.0) {
			float3 l = f.lightDirWorld.xyz;
			float nl = max(dot(n, l), 0.02);
			float k = min(1.5 * wp.tune.x, 7.1 * nl * rsqrt(max(1.0 - nl * nl, 1e-4))); // (the cap: 0.0059 k^2 (1 - nl^2) / nl^2 <= 0.3)
			float3 nr = normalize(n * (1.0 / max(n.y, 0.1)) + float3(w.detail.y * k, 0.0, -w.detail.x * k)); // + the ripples' slope turned 90 degrees
			float r = max(dot(nr, l), 0.0) / nl;
			float dfar = 1.0 - smoothstep(0.6 * SHADE_WATER_DETAIL_FAR, SHADE_WATER_DETAIL_FAR, length(w.p));
			float keep = saturate(log2(1.9 / max(w.footprint, 1e-3)) * (1.0 / 4.3)); // the ripple octaves the mips keep
			float s2 = 0.0059 * k * k * dfar * dfar * keep * saturate(1.0 - nl * nl) / (nl * nl);
			float contrast = (r * r) * (r * r) / (1.0 + 6.0 * s2 + 3.0 * s2 * s2);
			spec *= clamp(1.0 + (contrast - 1.0) * near, 0.0, 16.0);
		}
	}
#endif
	float soft = smoothstep(0.15, 0.85, float(w.shadow));
	float3 glint = f.sunColor.rgb * min(spec, 60.0) * soft * open * (1.0 - hitWeight);

	float3 color = mix(body, refl, fres) + glint * (wp.tune.z * (w.look != nullptr ? w.look->user2.x : 1.0)); // (1.1) user2.x: the glint
	if (f.flags.w == 5) return float3(hitWeight, fres, 0.0) / max(w.exposure, 1e-3);                               // debug: SSR hits, Fresnel
#if defined(SHADE_WATER_PANO) && defined(SHADE_LEAN_ABOVE)
	if (f.flags.w == 11) return float3(panoW, ssrW, 0.1) / max(w.exposure, 1e-3);                                   // debug: the panorama's share, the screen march's
#endif
#if defined(SHADE_SSRH_DEBUG) && defined(SHADE_LEAN_ABOVE)
	if (f.flags.w == 10) return (tHit == -2.0 ? ssrHit.rgb : float3(0.0, 0.0, 0.2)) / max(w.exposure, 1e-3);         // debug: the exact march's work
#endif
	if (f.flags.w == 6) return float3(saturate(lView / 16.0), saturate(dy / 8.0), hasFloor ? 0.0 : 1.0) / max(w.exposure, 1e-3); // debug: path, depth

#ifdef SHADE_WATER_RTR
	// (candidate 7, Gael 2026-11-04: "un parpadeo o una titilación en el mar… en los reflejos… cuando te estás moviendo, cuando salta,
	// cuando corre") The mirrored image's own temporal reprojection. The TAA reprojects a water pixel by its surface, but what it
	// mirrors moves on screen as a point behind the mirror, the surface's distance plus the reflected ray's farther: walking,
	// jumping or running, its history held the wrong part of the reflection, the variance clip threw it out, and the reflection
	// was this frame's alone (the SSR's quad and step noise, its screen-edge column) frame after frame: shimmer. Here last frame's
	// image (the TAA's steady output) is read where that mirrored point was (along the view ray at dist + the hit's distance; the
	// sky's at infinity: a direction), kept inside this 2x2 quad's range of colours (no ghost of anything the reflection didn't
	// show), and blended in by the reflection's share (fres) x wp.swell3.w (mcopt.shade.water.reflTemporal; 0 = candidate 6).
	// Only where last frame saw water at about the same distance there (its depth copy, ShadeResources.prevDepth).
	{
		float3 qlo = float3(shadeQuadMin(color.r), shadeQuadMin(color.g), shadeQuadMin(color.b));
		float3 qhi = float3(shadeQuadMax(color.r), shadeQuadMax(color.g), shadeQuadMax(color.b));
		float kT = wp.swell3.w * fres;
		if (top && kT > 0.0 && w.prevExposure > 0.0 && w.look != nullptr && w.res != nullptr && w.look->ssr.y > 0.5) {
			bool far = !(hitWeight > 0.5 && tHit > 0.0);
			float4 pc = w.look->prevViewProjNoJitter * (far ? float4(v, 0.0) : float4(w.p + v * tHit, 1.0));
			float2 uvp = pc.xy / pc.w * 0.5 + 0.5;
			if (pc.w > 0.0 && all(uvp > 0.0) && all(uvp < 1.0)) {
				constexpr sampler nearestClamp(filter::nearest, address::clamp_to_edge, coord::normalized);
				float pd = float(w.res->prevDepth.sample(nearestClamp, uvp).r);
				float vd = abs((f.view * float4(pe, 0.0)).z); // this surface point's view depth (prevDepth's measure)
				if (pd < 60000.0 && abs(pd - vd) < 0.3 * vd + 1.0) {
					float3 hp = float3(prev.sample(shadeWaterLinear, uvp).rgb) / w.prevExposure;
					float3 pad = (qhi - qlo) * 0.25 + qhi * 0.02;
					color = mix(color, clamp(hp, qlo - pad, qhi + pad), kT);
				}
			}
		}
	}
#endif

#ifdef SHADE_FOAM
	if (top && hasFloor && dist < 28.0) {
		// where the bottom comes up to the surface: sparse, broken patches that drift with the water (a scrolling two-octave
		// value noise and the wave crests), only over a floor that faces up (a submerged wall is no beach), fading out with
		// distance (no thin bright contour lines along every shore)
		float shore = min(dy, lView * 0.7);
		float edge = 0.10 + 0.16 * saturate(height * 9.0);
		float foam = (1.0 - smoothstep(0.0, edge, shore)) * smoothstep(0.0, 0.03, shore + 0.02);
		if (foam > 0.01) {
			float2 x = shadeWaterXZ(w.p.xz, f);
			float t = shadeWaterTime(f);
			float nz = 0.65 * shadeWaterValueNoise(x * 1.7 + float2(t * 0.11, t * 0.07)) + 0.35 * shadeWaterValueNoise(x * 4.3 - float2(t * 0.17, -t * 0.13));
			foam *= smoothstep(0.42, 0.72, nz) * saturate(height * 12.0 + 0.3);
			// the floor's facing from the depth copy (two neighbours): walls and steep drops get none
			uint2 q = uint2(min(uvR * size, size - 2.0));
			float3 f0 = shadeWaterViewPoint(depth, q, size, f), fx = shadeWaterViewPoint(depth, q + uint2(1, 0), size, f),
			       fz = shadeWaterViewPoint(depth, q + uint2(0, 1), size, f);
			float3 fn = cross(fx - f0, fz - f0);
			float upness = abs(fn.y) / max(length(fn), 1e-6);
			foam *= smoothstep(0.55, 0.85, upness) * (1.0 - smoothstep(16.0, 28.0, dist));
			color = mix(color, w.lit * 0.5, foam * (w.look != nullptr ? 0.3 * w.look->user1.z : 0.3)); // (1.1) user1.z: foam
		}
	}
#endif
	return color;
}

// The surface seen from below (the camera under water): inside Snell's window (48.6 degrees around the normal) the world
// above, refracted (the scene copy, or the sky where the copy has none); outside it total internal reflection mirrors the
// water below (SSR into the underwater scene, else the water's own colour). The vanilla underwater fog then applies
// between the camera and the surface (shadeFinish).
static float3 shadeWaterBelow(ShadeWaterIn w, constant ShadeFrame &f, constant ShadeWaterParams &wp, texture2d<half> lut, sampler lutS,
                              texture2d<half> scene, depth2d<float> depth, texture2d<half> prev, texture2d<half> waves, texture2d<float> hz) {
	float3 pe = w.p - shadeEye(f.invViewProj); // from the eye: view bobbing moves it (shade_common.metal)
	float dist = length(pe);
	float3 v = pe / max(dist, 1e-4);
	float height;
	float pattern;
	// (M2.1: the fine ripples from below too, a bit calmer: the long swell alone made blobby clay edges at Snell's window)
	float3 up = shadeWaterNormal(w, f, wp, waves, height, pattern, 0.6);
	up = normalize(float3(up.x * 1.8, up.y, up.z * 1.8)); // from below the ripples bend the light more visibly
	float3 n = -up; // toward the camera
	float3 t = refract(v, n, 1.333);
	bool tir = dot(t, t) < 1e-6;
	float fres = tir ? 1.0 : shadeWaterFresnel(dot(t, up));
	float2 tex = float2(scene.get_width(), scene.get_height());
	float2 size = shadeWaterRenderSize(f, tex);
	float2 uv = w.pixel / size;
	// the world above through the window: the copy behind the surface, shifted by the waves' tilt
	float3 above = 0.0;
	if (!tir) {
		float3 tilt = (f.view * float4(up - float3(0.0, 1.0, 0.0), 0.0)).xyz;
		float wSurf = shadeLinearW(w.depth, f);
		float2 uvR = clamp(uv + float2(f.proj[0][0] * tilt.x, f.proj[1][1] * tilt.y) * (1.2 / max(wSurf, 0.5)), 0.5 / size, 1.0 - 0.5 / size);
		float wR = shadeWaterSceneW(depth, uint2(uvR * size), f);
		float3 sky = shadeSkyLookup(t, lut, lutS, f);
		// the sun seen through the rippled window: a small hot core and a soft glare around the refracted direction, so
		// the ripples break it into dancing sparkles
		float ct = dot(t, f.lightDirWorld.xyz);
		// (a tight glare: the wide one read as a flat white disc once bloom spread it)
		if (f.lightDirWorld.w > 0.5) sky += f.sunColor.rgb * (exp((ct - 1.0) * 6000.0) * 30.0 + exp((ct - 1.0) * 400.0) * 0.35) * float(w.shadow);
		above = wR < SHADE_WATER_SKY_W ? shadeWaterSceneRadiance(scene.sample(shadeWaterLinear, uvR * size / tex).rgb, w.exposure) : sky;
		above *= float(shadeSkyCurve(w.sky)) * 0.6 + 0.4;
	}
	// the water below, mirrored
	float3 below = w.fog * (0.65 + 0.5 * saturate(height * 7.0 + 0.3)); // the mirror ripples
#ifdef SHADE_SSR
	if (shadeQuadMax(fres) > 0.05 && wp.tune.y > 0.0) { // quad-uniform (SSR's lanes work together)
		float4 hit = shadeSsr(w.p + n * 0.02, reflect(v, n), w.pixel, min(wp.tune.y, 48.0), w.exposure, 0.0, f, w.look, scene, depth, prev, hz);
		below = mix(below, hit.rgb, hit.a);
	}
#endif
	return mix(above, below, fres);
}

// Entry point for the translucent terrain fragment: picks the side the camera is on.
static float3 shadeWaterSurface(ShadeWaterIn w, constant ShadeFrame &f, constant ShadeWaterParams &wp, texture2d<half> lut, sampler lutS,
                                texture2d<half> scene, depth2d<float> depth, texture2d<half> prev, texture2d<half> waves, texture2d<float> hz SHADE_RH_PARAMS) {
	if (SHADE_CAMERA_UNDERWATER(f) && w.nFace.y < -0.5) return shadeWaterBelow(w, f, wp, lut, lutS, scene, depth, prev, waves, hz);
	return shadeWaterAbove(w, f, wp, lut, lutS, scene, depth, prev, waves, hz SHADE_RH_ARGS);
}

// ---- glossy translucents (bible E15 basics) ------------------------------------------------------------------------------
// Stained glass, ice, slime, honey: smooth dielectric faces (n = 1.5, f0 = 0.04) get a mirror reflection on top of their
// own lit, alpha-blended colour: the sky (as open as the sky light says), SSR where the ray finds something on screen, and
// the sun's highlight. The surface's transmittance (1 - alpha) is kept and the reflected light is added in front of it
// (out alpha = alpha + (1 - alpha) F, colour = what makes src alpha blending give lit alpha (1 - F) + reflection F + glint),
// so clear panes turn mirror-like at grazing angles like real windows. radiance/alpha: the face's lit colour and alpha.
static float4 shadeGlossy(float3 radiance, float alpha, float3 p, float3 n, float2 pixel, half sky, half shadow, float exposure,
                          float prevExposure, constant ShadeFrame &f, constant ShadeLook *L, constant ShadeResources *R, constant ShadeWaterParams &wp,
                          texture2d<half> lut, sampler lutS, texture2d<half> scene, depth2d<float> depth, texture2d<half> prev, texture2d<float> hz) {
	float3 pe = p - shadeEye(f.invViewProj); // from the eye: view bobbing moves it (shade_common.metal)
	float dist = length(pe);
	float3 v = pe / max(dist, 1e-4);
	float cosV = saturate(dot(-v, n));
	float m = 1.0 - cosV;
	float m2 = m * m;
	float fres = (0.04 + 0.96 * m2 * m2 * m) * wp.tune.z;
	float open = float(shadeSkyCurve(sky));
	float3 r = reflect(v, n);
	float3 refl = shadeWaterSkyRefl(float3(r.x, abs(r.y), r.z), float3(r.x, abs(r.y), r.z), p, prevExposure, f, L, R, lut, lutS, depth, prev) * open;
	float hitWeight = 0.0;
#ifdef SHADE_SSR
	if (wp.state.x > 0.5 && wp.tune.y > 0.0 && shadeQuadMax(fres) > 0.03) { // quad-uniform (SSR's lanes work together)
		float4 hit = shadeSsr(p + n * 0.02, r, pixel, min(wp.tune.y, 128.0), exposure, prevExposure, f, L, scene, depth, prev, hz);
		hitWeight = hit.a;
		refl = mix(refl, hit.rgb, hit.a);
	}
#endif
	float3 glint = f.sunColor.rgb * min(shadeGgxSpec(n, v, f.lightDirWorld.xyz, 0.03), 40.0) * smoothstep(0.15, 0.85, float(shadow)) * open
		* (1.0 - hitWeight) * (f.lightDirWorld.w > 0.5 ? 1.0 : 0.3);
	// shadeGgxSpec carries water's Fresnel (f0 0.02): glass reflects about twice as much at normal incidence
	float3 front = radiance * alpha * (1.0 - fres) + refl * fres + glint * 2.0 * wp.tune.z;
	float outA = alpha + (1.0 - alpha) * fres;
	return float4(front / max(outA, 1e-3), outA);
}

// World xz direction in which the atlas v coordinate grows across this face (the flowing water sprite is laid along the
// current), from the screen derivatives of position and uv; 0 where it isn't defined.
static inline float2 shadeWaterFlowDir(float3 dpx, float3 dpy, float2 duvx, float2 duvy) {
	float2 a = dpx.xz, b = dpy.xz;
	float det = a.x * b.y - a.y * b.x;
	if (abs(det) < 1e-12) return 0.0;
	float2 g = float2(duvx.y * b.y - duvy.y * a.y, -duvx.y * b.x + duvy.y * a.x) / det;
	float l = length(g);
	return l > 1e-6 ? g / l : float2(0.0);
}

#endif
