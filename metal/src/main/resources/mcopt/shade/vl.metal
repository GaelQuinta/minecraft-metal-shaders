// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// Volumetric light ("god rays", shader bible E07), compiled natively by mcvl.m after shade_common.metal. Original code from
// public techniques: single scattering in a participating medium (Hillaire 2015, "Physically based and unified volumetric
// rendering in Frostbite": energy-conserving per-segment integration), Henyey-Greenstein phase, interleaved gradient noise
// (Jimenez 2014) with an R1 temporal offset, neighbourhood-clamped temporal reprojection (Karis 2014), and the screen-space
// radial occlusion march for crepuscular rays (Mitchell, GPU Gems 3 ch. 13).
// Portions adapted from Photon Shaders by Benjamin Stott ("sixthsurge"), MIT License, commit 26c2906e
// (include/fog/air_fog_vl.glsl; full text: LICENSES/MIT-Photon.txt): the air mode's approach (one march of the whole air, haze and
// mist by height, from the camera to the scene with the sun's shadow at every step, the per-step energy-conserving integral
// carrying the transmittance) and the forest air's phase function: a forward and a backward Henyey-Greenstein lobe (0.7 / 0.3,
// g 0.5 / -0.2) summed over four octaves of a multiple-scattering approximation (each half the light, g x 0.7). Everything else
// is original (Apache-2.0).
//
// Passes, all fragment passes into private RenderTarget|ShaderRead targets (compressible: apple-gpu.md section 0.2):
//   vl_canopy   (compute, 1 threadgroup of 64) how much of the air around the camera is in shadow -> the "canopy factor"
//               (forests, overhangs, cave mouths -> strong shafts; open plains -> subtle), smoothed over seconds, in a
//               16-byte state buffer read by the march.
//   vl_march    (VL resolution, e.g. 1/2 of the target) per pixel: ray-march the local mist from the camera to the scene
//               depth through the sun's shadow map (near cascade where it covers, else far) -> in-scattered light; plus a
//               short screen-space march toward the sun on the depth buffer (crepuscular streaks beyond the shadow range)
//               and, under water, caustic-modulated shafts. rgb = in-scattered radiance (linear, pre-exposure), a = the
//               scene distance this pixel marched to (blocks; 1e4 = sky), used by the temporal and upsample passes.
//   vl_temporal (VL resolution) 3x3 depth-aware filter of the noisy march + reprojected history (ShadeFrame.prevViewProj),
//               clamped to the 3x3 neighbourhood's range and rejected on distance mismatch. Writes the new history.
//   vl_composite (full resolution) depth-aware bilateral upsample of the history; then
//               - vl_composite (M1 / mcopt.shade.hdr=false): adds the light *before* M1's output curve: the target's sRGB value is mapped
//                 back to exposed radiance through the inverse of shadeOutput's curve, the light (x exposure) is added, and
//                 the difference of the two forward curves is added to the pixel (so no light = the exact same pixel);
//                 programmable blending ([[color(0)]]) on the game's RGBA8 main target, blue-noise-ish dither against banding.
//               - vl_composite_hdr (M2 with mcopt.shade.vl.fold=false or a debug view): returns the light x exposure and
//                 the canopy mist's transmittance T for blending (One, SourceAlpha: scene * T + light) into the
//                 pre-exposed HDR world target (RG11B10F / RGBA16F), before bloom and the tone map.
//   M2 default ("fold"): no composite pass; vl_temporal_fold also writes lightT (light + T at VL resolution) and the post
//   chain's final pass (shade_post.metal shadeVlUpsample, ShadePost.setVolumetric) upsamples and blends it. VL_HDR
//   (function constant 0) = built for M2: the canopy kernel also writes ShadeGpu.scene.y. See VL.md section 5.
// Bindings: ShadeFrame at buffer(16), shadow map texture(16) + compare sampler(12) (mc_shade_bind_*), VlParams at buffer(0),
// the canopy state at buffer(1); pass inputs at texture(0..1); M2: ShadeGpu at buffer(18) (HDR composite, canopy kernel).

#ifndef MCOPT_SHADE_VL
#define MCOPT_SHADE_VL

constant bool VL_HDR [[function_constant(0)]];

// Per-frame parameters (mcopt.metal.shade.vl.ShadeVl packs exactly this layout; 29 x float4 = 464 bytes since FT2.6).
struct VlParams {
	float4 size;      //   0 xy VL live size (px: the part of the VL targets this frame covers), zw full-resolution live size (px)
	float4 shape;     //  16 x strength, y max march distance (blocks), z step count, w forward HG g
	float4 medium;    //  32 x haze sigma_s at its base (1/block), y mist sigma_s at its base, z mist base y (camera-relative), w mist scale height
	float4 haze;      //  48 x haze base y (camera-relative), y haze scale height, z isotropic share, w back-lobe share
	float4 light;     //  64 rgb light colour (linear irradiance / pi, art-graded, pre-exposure), w canopy mist sigma_s at canopy 1 (1/block)
	float4 crep;      //  80 x screen-space ray strength (0 = off), y taps, z on-screen weight of the light, w angular falloff
	float4 sunPx;     //  96 xy the light's position in full-res target pixels (Metal rows), z history clamp allowance of a still
	                  //     view (share of the neighbourhood mean; 0 = the plain clamp, M2.1), w bits (M2.2; 0 = M2.1): 1 the clamp
	                  //     box over the 3x3 neighbourhood (else the filter's plus), 2 the history fetched from the texels at
	                  //     this point's distance (else one bilinear sample), 4 the crepuscular taps offset per texel over a
	                  //     [FT2.3: 32 the main march's offset per texel, 64 shafts from the far cascade only]
	                  //     bilinear sky mask (else one offset per frame, point reads), 8 the canopy mist's own steps offset
	                  //     per texel (else the march's per-frame offset), 16 the same for the march under water
	float4 water;     // 112 rgb extinction under water (1/block), w scattering (1/block)
	float4 water2;    // 128 x surface y (camera-relative), y underwater (0/1), z max distance under water, w caustic strength
	float4 temporal;  // 144 x history weight, y reset (1 = drop history), z frame index, w time (s, wraps)
	float4 camDelta;  // 160 xyz camera position now - last frame (blocks), w canopy smoothing factor this frame, rising (0..1)
	float4 gate;      // 176 x open-air layers' (haze, mist) strength, y canopy mist strength, z canopy override (< 0: GPU value), w debug view
	float4 extra;     // 192 x canopy reset (1 = snap), y canopy mist scale height (blocks), z canopy smoothing factor, falling,
	                  //     w canopy mist steps (its own linear march over the first 2.5 ranges; 0 = on the main march)
	float4 mist;      // 208 x canopy mist range (blocks: density e^(-t/range) from the camera), y its top above the eye (blocks),
	                  //     z scene extinction by the canopy mist (0/1), w its extinction relative to its scattering (art: < 1
	                  //     keeps the veil light while the shafts stay bright)
	float4 mistAmb;   // 224 rgb ambient (sky) light of the shadowed canopy mist (irradiance / pi, pre-exposure), w share of the
	                  //     open-air haze's unshadowed glow left out (the sky and M1's haze have it already)
	float4 carve;     // 240 x canopy mist carve k: keep max(lit - k unshadowed, 0) / (1 - k) of it (0 = all; M2 > 0: the
	                  //     uniform part goes, rays crossing shadows darken -> visible beams), y the same for the caustic
	                  //     shafts under water (relative to the light without caustics), zw the part of the history texture
	                  //     last frame covered (uv scale; the targets are allocated for the largest render scale, size.xy is
	                  //     this frame's live part)
	float4 art;       // 256 M3.3 (HDR; 1, 0, 0, 0 = M3.2): x gain of the sky's dark crepuscular rays (mcopt.shade.vl.skyRays, dev), y
	                  //     their extra gain over the open sky (ShadeVl: mcopt.shade.vl.sunsetRays - 1 in the golden hour with the
	                  //     sunset art; weighted by the pixel's own cloud transmittance squared, so the clouds keep M3.2's shading),
	                  //     z 1: that extra from the taps past the pixel's own neighbourhood (mcopt.shade.vl.sunsetFar), w > 0 its
	                  //     falloff exponent around the sun (mcopt.shade.vl.sunsetFall; 0 = crep.w)
	float4 tune;      // 272 (2026-10-09) x the canopy factor's floor (the canopy mist also outside a canopy, at least this much of
	                  //     it: mcopt.shade.vl.canopyMin), y the open-air cut and z the canopy mist's carve away from the light (the
	                  //     mistAmb.w / carve.x values hold toward it; between by the angle: mcopt.shade.vl.openCutSide / carveSide),
	                  //     w the far march's end (blocks; 0 = none): past the main march, rays that go on (sky, far terrain) take
	                  //     VL_FAR_STEPS more steps through the open air with the clouds' shadow only (sunset rays from cloud gaps)
	float4 tune2;     // 288 x the far march's density gain (the evening haze toward the low sun), y its own cut (the share of its
	                  //     unshadowed glow left out), z (2026-10-09) the shafts' soft edge: radius (blocks) of a per-step offset
	                  //     of the shadow lookups across the light direction (0 = sharp, mcopt.shade.vl.soft), w (FT2.3) the
	                  //     radial blur's tap spacing (VL pixels)
	float4 hp;        // 304 (2026-10-09) the shafts' local contrast (fold): x keep, the share of the local mean glow kept; y gain of
	                  //     what stands out of it (a beam); z the veil blur's tap spacing (quarter-resolution texels); w 1 = on.
	                  //     In full from a canopy factor of 0.2 (under trees; open land keeps the plain light). See vlVeilR.
	float4 radial;    // 320 (FT2.3) the light direction's vanishing point in homogeneous NDC: xy = (viewProj * (L, 0)).xy, z its w
	                  //     (all scaled alike), w taps on each side of the radial blur (0 = off). See vl_radial.
	float4 look2;     // 336 (FT2.3) x gain of the screen-space crepuscular streaks in front of geometry (HDR; 0 = none); (FT2.6) the shade
	                  //     grid's canopy test (vl_shade_grid): y the top of its box above a cell (blocks; <= grid2.w: off, FT2.5), zw the
	                  //     sunlit share of that box from which the cell starts to read as sunlit land, and fully
	float4 air;       // 352 (godrays v3, HDR) the air mode (x 1 = on, see vl_march): y min steps, z steps per block marched, w max steps
	float4 air2;      // 368 (godrays v3) x the march's end (blocks: the render distance), y the light the shadows may take out of a
	                  //     sky pixel (share of the haze's unshadowed sunlit part), z gain of that shadowed part (1 = physical),
	                  //     w gain of the forest air's sunlit part
	float4 grid;      // 384 (godrays v3) the shade grid (vl_shade_grid): xyz its corner (camera-relative, blocks; snapped to whole cells
	                  //     in the world, so it holds still as the camera moves), w its cell size (blocks)
	float4 grid2;     // 400 xyz where the corner cell sits in the texture (the grid wraps around: a cell's texel is its world cell
	                  //     index mod VL_GRID_*, so a camera move only brings in new cells), w how far around a cell its taps reach
	float4 air3;      // 416 (godrays v3) the forest air: x the lit share around a point (the grid) at or below which it is at full
	                  //     density, y the share at or above which it is gone (open sunlit land: no veil), z its fade-in from the
	                  //     camera (blocks; 0 = none), w its sky-lit share (the canopy hides most of the sky)
	float4 air4;      // 432 (godrays v3) the forest air: x its share over open sunlit land (0 = only where the shade grid says shade,
	                  //     1 = everywhere alike), y its phase's forward g (0 = Photon's two lobes over four octaves), z the
	                  //     isotropic share with that lobe, w which quarter of the grid's cells this frame refreshes (z slices
	                  //     z % 4 == w; < 0: all of them, after a reset)
	float4 air5;      // 448 (FT2.6) the forest air's fade-out with the distance from the camera: x from, y to (blocks; y <= x: none); z its
	                  //     share with the camera in the open (canopy factor 0; 1 = everywhere alike, FT2.5), w how far sideways the shade
	                  //     grid's canopy test reaches (blocks; 0 = grid2.w)
	float4 air6;      // 464 (FT2.7, audit idx 16) the canopy test as columns: x how many (0 = FT2.6's solid box), y taps up each one,
	                  //     z their distance from the cell's axis (blocks; 0 = 3/4 of the canopy test's reach), w > 0: sky pixels stop
	                  //     their air-mode march where it can no longer add anything (audit idx 0)
	float4 air7;      // 480 (FT2.7) x the canopy test's columns start this high above the cell (blocks; 0 = grid2.w), y > 0: only a
	                  //     blocker within that many blocks toward the light shades a column's tap (leaves above, not a far tree), z > 0:
	                  //     the columns and FT2.6's box both (the lesser open share), w > 0: the crepuscular taps march last frame's
	                  //     sky mask where this pixel and the sun were last frame (audit idx 21)
};
// The shade grid (godrays v3): a camera-centred block of cells holding the share of sunlit points around each (R8, trilinear)
#define VL_GRID_X 64
#define VL_GRID_Y 32
#define VL_GRID_Z 64
#define VL_GRID_TAPS 24
#define VL_GRID_TAPS_UP 12 // (FT2.6) the canopy test's taps, in the box above (look2.y)
#define VL_GRID_ROUNDS 4
#define VL_FAR_STEPS 8

struct VlState { float4 canopy; }; // x smoothed canopy factor 0..1, y raw shadowed fraction, zw 0

struct VlOut { float4 position [[position]]; };

vertex VlOut vl_vs(uint vid [[vertex_id]]) {
	VlOut o;
	o.position = float4(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0, 0.0, 1.0);
	return o;
}

// ---- helpers -----------------------------------------------------------------------------------------------------------
static inline float vlHG(float mu, float g) {
	float g2 = g * g;
	float x = max(1.0 + g2 - 2.0 * g * mu, 1e-4);
	return 0.0795775 * (1.0 - g2) * rsqrt(x * x * x); // (1 - g^2) / (4 pi x^1.5)
}

// Phase: a forward Henyey-Greenstein lobe (strong toward the light), a weak back lobe and an isotropic share (light that
// scattered more than once; keeps shafts visible from the side, not only looking into the sun).
static inline float vlPhase(float mu, constant VlParams &p) {
	float iso = p.haze.z, back = p.haze.w;
	return (1.0 - iso - back) * vlHG(mu, p.shape.w) + back * vlHG(mu, -0.25) + iso * 0.0795775;
}

// World direction (camera-relative, unit) and distance (blocks; 1e4 for the sky) of full-res pixel px with depth d.
static inline float3 vlDirection(float2 ndc, constant ShadeFrame &f) {
	return normalize(shadeViewRay(ndc, f.invViewProj)); // from the eye: view bobbing moves it (shade_common.metal)
}
static inline float vlDistance(float2 ndc, float depth, constant ShadeFrame &f) {
	if (depth <= 0.0) return 1e4;
	float4 h = f.invViewProj * float4(ndc, depth, 1.0);
	return min(length(h.xyz / h.w), 1e4);
}

// Sun visibility at a point given its two cascade clip positions (ortho: linear in the march distance). Near cascade
// (alpha-tested leaves: shafts through canopy gaps) where it covers, else the far one; above everything the map holds =
// lit, below its depth range = shadowed (underground), outside the far square = lit.
// (FT2.3, farOnly: the far cascade alone, where leaves are whole blocks: shafts only through real gaps in the foliage, not a
// mini shaft through every hole of the leaf texture, which at the VL resolution read as pixel noise: Gael, "pixeleados")
static inline float vlShadow(depth2d_array<float> map, sampler cmp, float3 c0, float3 c1, bool farOnly = false) {
	if (!farOnly && max(abs(c0.x), abs(c0.y)) < 0.97 && c0.z > 0.0 && c0.z < 1.0) return map.sample_compare(cmp, shadeShadowUV(c0), 0u, c0.z);
	if (max(abs(c1.x), abs(c1.y)) >= 0.995) return 1.0;
	if (c1.z >= 1.0) return 1.0;
	if (c1.z <= 0.0) return 0.0;
	return map.sample_compare(cmp, shadeShadowUV(c1), 1u, c1.z);
}

// Procedural caustics on the water surface plane (original): a domain-warped sum of three sines whose zero set forms a
// bright web with sharp ridges (r^4: mean about 0.21, 17% of the plane above 0.5). Two scales multiplied: broad cells
// (about 13 blocks) shape the shafts seen from afar, a finer web (about 5 blocks) breaks them into curtains; mean about 1,
// dark gaps about 0.1. q in blocks, t in seconds.
// Half precision (the per-step cost under water): time enters as phases wrapped to [0, 2 pi) in float (tp: x..w = the five
// time terms, see vlCausticPhases), positions stay below a few hundred, so half's resolution is plenty for the sines.
static inline half vlCausticWeb(half2 p, half4 tp, half tp4) {
	p += 0.55h * half2(sin(p.y * 1.31h + tp.x), sin(p.x * 1.17h - tp.y));
	half a = sin(p.x * 1.9h + tp.z) + sin(p.y * 2.1h - tp.w) + sin((p.x - p.y) * 1.45h + tp4);
	half r = saturate(1.0h - abs(a) * 0.55h);
	r *= r;
	return r * r;
}
static inline void vlCausticPhases(float t, thread half4 &a, thread half &a4, thread half4 &b, thread half &b4) {
	// t = the water's clock (ShadeFrame.waterTime: real time, wrapped every 4096 s); every speed is a whole number of turns per
	// 4096 s (about 0.83, 0.71, 0.9, 1.05, 0.6 rad/s and 1.3x those), so the wrap is seamless
	const float TAU = 6.2831853;
	float s = t * (1.0 / 4096.0);
	a = half4(TAU * fract(s * float4(541.0, 463.0, 587.0, 684.0)));
	a4 = half(TAU * fract(s * 391.0));
	b = half4(TAU * fract(s * float4(703.0, 602.0, 763.0, 890.0)));
	b4 = half(TAU * fract(s * 508.0));
}
static inline half vlCaustic(float2 q, half4 ta, half ta4, half4 tb, half tb4) {
	half broad = 0.25h + 3.6h * vlCausticWeb(half2(q * 0.22), ta, ta4);
	half fine = 0.5h + 2.4h * vlCausticWeb(half2(q * 0.55 + 37.0), tb, tb4);
	return broad * fine;
}

static inline float vlNoise(float2 px, float frame) {
	// IGN, decorrelated per frame by the R1 sequence (golden ratio)
	float n = fract(52.9829189 * fract(dot(px, float2(0.06711056, 0.00583715))));
	return fract(n + frame * 0.6180339887);
}

// ---- canopy factor --------------------------------------------------------------------------------------------------------
kernel void vl_canopy(uint tid [[thread_index_in_threadgroup]], uint lane [[thread_index_in_simdgroup]],
                      uint sg [[simdgroup_index_in_threadgroup]],
                      constant ShadeFrame &f [[buffer(16)]], depth2d_array<float> map [[texture(16)]],
                      constant VlParams &p [[buffer(0)]], device VlState *state [[buffer(1)]],
                      device ShadeGpu *gpu [[buffer(18), function_constant(VL_HDR)]]) {
	threadgroup float partial[2];
	// 64 points: four rings of 16 (radius 3, 7, 11 and 15 blocks), alternating 1.5 and 5 blocks above the eye (below a
	// tree canopy, in the air the shafts would cross), in the far cascade.
	uint ringIdx = tid >> 4u;
	float ring = 3.0 + 4.0 * float(ringIdx);
	float h = (tid & 1u) != 0u ? 5.0 : 1.5;
	float a = float(tid & 15u) * (6.2831853 / 16.0) + float(ringIdx) * 0.39;
	float3 pt = float3(cos(a) * ring, h, sin(a) * ring);
	float shadowed = 0.0;
	if (f.flags.z != 0) {
		float4 c = f.shadowViewProj[1] * float4(pt, 1.0);
		if (max(abs(c.x), abs(c.y)) < 0.995 && c.z < 1.0) {
			if (c.z <= 0.0) {
				shadowed = 1.0;
			} else {
				float2 uv = shadeShadowUV(c.xyz);
				uint2 texel = uint2(clamp(uv * f.shadowParams.y, 0.0, f.shadowParams.y - 1.0));
				shadowed = map.read(texel, 1u) > c.z + 1e-5 ? 1.0 : 0.0; // stored nearer the light than the point: shadowed
			}
		}
	}
	float s = simd_sum(shadowed);
	if (lane == 0u) partial[sg] = s;
	threadgroup_barrier(mem_flags::mem_threadgroup);
	if (tid == 0u) {
		float frac = (partial[0] + partial[1]) / 64.0;
		float target = smoothstep(0.12, 0.5, frac);
		float old = state->canopy.x;
		// rise quickly (stepping under trees), fade slowly (leaving them)
		float k = p.extra.x > 0.5 ? 1.0 : (target > old ? p.camDelta.w : p.extra.z);
		float canopy = mix(old, target, k);
		state->canopy = float4(canopy, frac, 0.0, 0.0);
		if (VL_HDR) gpu->scene.y = canopy; // M2: ShadeGpu.scene.y for other passes (E06 mist, fog glow)
	}
}

// ---- shade grid (godrays v3) ---------------------------------------------------------------------------------------------
// The forest air (vl_march's air mode) is humid air under the trees: dense where most of the air around a point lies in the
// shade (under a canopy, between trunks, under an overhang), thin over open sunlit land. Lit air is a uniform glow (Gael's
// "lente empañado"), so a medium as dense over a sunny clearing as under the trees veils the view; this one lights up only as
// the shafts that cross the shade. One thread per cell: VL_GRID_TAPS points around its centre (a 3D R-sequence over a box of
// +-grid2.w blocks across, from half a block to grid2.w above: taps underground would read open land as shade) looked up in
// the far cascade (whole-block leaves), lit share -> R8. The taps sit at fixed offsets from cells snapped to the world, so the
// grid holds still as the camera moves (no flicker; it follows the shadow map's own steps). The texture wraps around (a cell's
// texel = its world cell index mod the grid's size), so a quarter of the cells per frame keeps it current (the shade changes
// slowly; cells that just came in at the far edge, faded there, wait at most 4 frames); after a reset all of them.
// One shade grid tap: 1 where the sun reaches point q (far cascade, linear compare), outside the far square or above it lit.
static inline float vlGridTap(float3 q, constant ShadeFrame &f, depth2d_array<float> map) {
	constexpr sampler cmpLin(coord::normalized, filter::linear, address::clamp_to_edge, compare_func::greater_equal);
	float4 h = f.shadowViewProj[1] * float4(q, 1.0);
	if (max(abs(h.x), abs(h.y)) >= 0.995 || h.z >= 1.0) return 1.0;
	return h.z > 0.0 ? map.sample_compare(cmpLin, shadeShadowUV(h.xyz), 1u, h.z) : 0.0;
}

// (FT2.7) the same, but only a blocker within dmax blocks toward the light counts as shade (the far cascade's depth: zB blocks per
// unit; a 2x2 gather): leaves over the point, not a tree's shadow from far off at a low sun
static inline float vlGridTapNear(float3 q, constant ShadeFrame &f, depth2d_array<float> map, float zB, float dmax) {
	constexpr sampler pt(filter::nearest, address::clamp_to_edge);
	float4 h = f.shadowViewProj[1] * float4(q, 1.0);
	if (max(abs(h.x), abs(h.y)) >= 0.995 || h.z >= 1.0) return 1.0;
	if (h.z <= 0.0) return 0.0;
	float4 d = map.gather(pt, shadeShadowUV(h.xyz), 1u);
	float4 near = select(float4(0.0), float4(1.0), d > h.z && (d - h.z) * zB < dmax);
	return 1.0 - dot(near, float4(0.25));
}

kernel void vl_shade_grid(uint3 tid [[thread_position_in_grid]], constant ShadeFrame &f [[buffer(16)]], constant VlParams &p [[buffer(0)]],
                          depth2d_array<float> map [[texture(16)]], texture3d<half, access::write> grid [[texture(0)]]) {
	uint3 gid = p.air4.w < 0.0 ? tid : uint3(tid.x, tid.y, tid.z * VL_GRID_ROUNDS + uint(p.air4.w));
	if (gid.x >= VL_GRID_X || gid.y >= VL_GRID_Y || gid.z >= VL_GRID_Z) return;
	float3 c = p.grid.xyz + (float3(gid) + 0.5) * p.grid.w;
	float r = p.grid2.w;
	float lit = 0.0;
	if (f.flags.z == 0) {
		lit = float(VL_GRID_TAPS);
	} else {
		for (int k = 0; k < VL_GRID_TAPS; k++) {
			float3 u = fract(0.5 + float(k) * float3(0.8191725134, 0.6710436067, 0.5497004779));
			lit += vlGridTap(c + float3((u.x * 2.0 - 1.0) * r, 0.5 + u.y * (r - 0.5), (u.z * 2.0 - 1.0) * r), f, map);
		}
	}
	float share = lit / float(VL_GRID_TAPS);
	// (FT2.6, look2.y > r) the canopy test: the share of sunlit points in a box above that one, from r up to look2.y blocks. Under
	// trees the canopy shades it (a gap in the canopy too: its ring of leaves lies within the box); over a sunlit crest, in a wide
	// clearing or at the sunlit edge of a hill's shadow the sky is open above. There the low box alone read the hill's own
	// shadow beside and below the air as shade, so the air got the forest's density and glowed toward the sun as white puffs
	// along every ridge (Gael's FT2.5 screenshots 3-5): where the box above is mostly sunlit (look2.z..w) the cell reads as
	// sunlit land
	// (air5.w > 0: the box reaches that far sideways, else r: wide enough to hold the ring of leaves around a big gap in the canopy,
	// where the shafts are)
	// (FT2.7, air6.x > 0: audit idx 16) as columns, not a box: oak and birch leaves sit 3-7 blocks above the ground, so most of
	// the box (4-16 blocks above a cell near the ground) lay above them, in the sun, and the autumn forest read as sunlit land
	// (its shafts were gone). A column is open only where all its taps are lit (one shaded tap = leaves or an overhang above
	// the cell, at any height up to look2.y); its taps are packed toward the low end (where short canopies are) and it stops
	// at its first shaded one. The open share of the columns plays the box's lit share.
	// Default (rounds r1-r4 / gs1-gs4, notes/canopy-cols-2026-10-09): ONE column on the cell's axis from 1.5 blocks up, 5 taps,
	// counting only a blocker within 12 blocks toward the sun (air7.y: leaves over the cell; at a low sun a far tree's shadow
	// across the column had made the air over crests forest = halos and plumes). Gael's taiga: the veil at or below FT2.6's
	// (p3 0.6 -> 0.05, p4 0.7 -> 0.2); his autumn forest: the shafts back (g2 rays 1.83 -> 1.97, FT2.5 1.94).
	float up = p.look2.y, rUp = p.air5.w > 0.0 ? p.air5.w : r;
	// (FT2.8, audit idx 4: not where every low tap is already lit, share ~1, the most of open land: the test can only raise share;
	// not merely >= air3.y, since the grid is sampled trilinearly and a higher share there still moves the values toward a neighbour)
	if (up > r && f.flags.z != 0 && share < 0.999) {
		float open = 0.0;
		int cols = min(int(p.air6.x), 12);
		if (cols > 0) {
			int taps = clamp(int(p.air6.y), 2, 6);
			float rho = cols == 1 ? 0.0 : p.air6.z > 0.0 ? p.air6.z : 0.75 * rUp, lo = p.air7.x > 0.0 ? p.air7.x : r; // (1: the cell's own axis)
			float3 m2 = float3(f.shadowViewProj[1][0][2], f.shadowViewProj[1][1][2], f.shadowViewProj[1][2][2]);
			float zB = 1.0 / max(length(m2), 1e-6), dmax = p.air7.y;
			for (int i = 0; i < cols; i++) {
				float a = (float(i) + 0.5) * (6.2831853 / float(cols));
				float2 o = float2(cos(a), sin(a)) * rho;
				float col = 1.0;
				for (int j = 0; j < taps && col > 0.02; j++) {
					float s = float(j) / float(taps - 1);
					float3 q = c + float3(o.x, lo + s * s * (up - lo), o.y);
					col = min(col, dmax > 0.0 ? vlGridTapNear(q, f, map, zB, dmax) : vlGridTap(q, f, map));
				}
				open += col;
			}
			open /= float(cols);
			// (air7.z > 0) both tests: open land only where the box above is mostly lit too (FT2.6's crests that cast the shafts
			// toward the sun stay forest; leaves right above a cell make it forest even where the box above them is lit)
			if (p.air7.z > 0.0) {
				float box = 0.0;
				for (int k = 0; k < VL_GRID_TAPS_UP; k++) {
					float3 u = fract(0.5 + (float(k) + 0.37) * float3(0.8191725134, 0.6710436067, 0.5497004779));
					box += vlGridTap(c + float3((u.x * 2.0 - 1.0) * rUp, r + u.y * (up - r), (u.z * 2.0 - 1.0) * rUp), f, map);
				}
				open = min(open, box / float(VL_GRID_TAPS_UP));
			}
		} else {
			for (int k = 0; k < VL_GRID_TAPS_UP; k++) {
				float3 u = fract(0.5 + (float(k) + 0.37) * float3(0.8191725134, 0.6710436067, 0.5497004779));
				open += vlGridTap(c + float3((u.x * 2.0 - 1.0) * rUp, r + u.y * (up - r), (u.z * 2.0 - 1.0) * rUp), f, map);
			}
			open /= float(VL_GRID_TAPS_UP);
		}
		share = max(share, smoothstep(p.look2.z, p.look2.w, open));
	}
	grid.write(half4(half(share)), (gid + uint3(p.grid2.xyz)) % uint3(VL_GRID_X, VL_GRID_Y, VL_GRID_Z));
}

// Canopy mist: the humid air under trees and overhangs, around the camera, scaled by the canopy factor. Density
// sigma(t) = s * e^(-t / R) * e^(-max(y - top, 0) / H) along a ray (y = dir.y * t, camera-relative): it fades with the
// distance from the camera (the mist is where the trees are) and above the canopy. Optical depth over [0, D], closed form
// (the march samples the same density, the composite takes the scene's extinction from this, at full resolution).
static inline float vlMistDensity(float t, float y, constant VlParams &p) {
	return exp(-t / p.mist.x - max(y - p.mist.y, 0.0) / p.extra.y);
}
static inline float vlMistDepth(float3 dir, float D, constant VlParams &p) {
	float R = p.mist.x, H = p.extra.y;
	float t1 = dir.y > 1e-4 ? min(p.mist.y / dir.y, D) : D; // below the top of the layer up to t1
	float od = R * (1.0 - exp(-t1 / R));
	if (D > t1) {
		float k = 1.0 / R + dir.y / H;
		od += exp(-t1 / R) * (1.0 - exp(-(D - t1) * k)) / k;
	}
	return od;
}

// ---- march ----------------------------------------------------------------------------------------------------------------
struct VlMarchOut {
	half4 light [[color(0)]]; // rgb in-scattered radiance, a marched distance
	half sky [[color(1)]];    // 1 where the pixel is sky (R8Unorm): next frame's crepuscular taps read this
};

fragment VlMarchOut vl_march(VlOut in [[stage_in]], constant ShadeFrame &f [[buffer(16)]], constant VlParams &p [[buffer(0)]],
                        constant VlState &st [[buffer(1)]], depth2d<float> depth [[texture(0)]], texture2d<half> prevSky [[texture(1)]],
                        depth2d_array<float> map [[texture(16)]], sampler cmp [[sampler(12)]],
                        constant ShadeLook &sl [[buffer(17)]], constant ShadeResources &sr [[buffer(19)]],
                        texture3d<half> shadeGrid [[texture(2)]], texture2d<half> skyLut [[texture(17)]], sampler lutS [[sampler(13)]]) {
	float2 scale = p.size.zw / p.size.xy;
	// the full-res pixel this VL pixel stands for (the same one the upsample assumes)
	uint2 fpx = uint2(min(floor(in.position.xy * scale), p.size.zw - 1.0));
	float2 fpos = float2(fpx) + 0.5;
	float2 ndc = fpos / p.size.zw * 2.0 - 1.0;
	float d = depth.read(fpx);
	float3 dir = vlDirection(ndc, f);
	float dist = vlDistance(ndc, d, f);
	// Step jitter: a per-frame offset (R1 sequence, integrated by the temporal pass) plus a quarter-step IGN spread across
	// pixels. Neighbouring rays then sample nearly the same depths, so their shadow-map fetches stay in cache: full
	// per-pixel jitter made the march 2-3x slower on a real (blocky, 16 MB) shadow map (tools/shade/vlbench.sh).
	float xi = fract(p.temporal.z * 0.6180339887 + 0.25 * vlNoise(in.position.xy, 0.0));
	// (2026-10-09, sunPx.w bit 32, look development) each texel's own offset (IGN + R1) for the main march too: the shared one
	// moves every ray of a neighbourhood across the leaf shadows together (structure that the temporal clamp can't average)
	if ((int(p.sunPx.w) & 32) != 0) xi = vlNoise(in.position.xy + 3.0, p.temporal.z);
	float3 L = f.lightDirWorld.xyz;
	float mu = dot(dir, L);
	float canopy = p.gate.z >= 0.0 ? p.gate.z : max(st.canopy.x, p.tune.x);
	float3 scatter = float3(0.0);
	bool underwater = p.water2.y > 0.5;
	int n = int(p.shape.z);
	float3 c0o = (f.shadowViewProj[0] * float4(0.0, 0.0, 0.0, 1.0)).xyz, c0d = (f.shadowViewProj[0] * float4(dir, 0.0)).xyz;
	float3 c1o = (f.shadowViewProj[1] * float4(0.0, 0.0, 0.0, 1.0)).xyz, c1d = (f.shadowViewProj[1] * float4(dir, 0.0)).xyz;
	bool shadows = f.flags.z != 0;
	bool farOnly = (int(p.sunPx.w) & 64) != 0; // (FT2.3) shafts from the far cascade only (see vlShadow)
	// (2026-10-09, tune2.z) soft shafts: each step looks the shadow up a little across the light direction (a Vogel disk of radius
	// tune2.z blocks, turned per texel and frame), so a shaft's edge is a gradient of ~2 radii instead of a cut (Gael: the lit air
	// under a big gap read as a hard-edged glass sheet); the temporal pass averages it. o0/o1: one block along e1/e2 in each
	// cascade's clip xy
	float softR = p.tune2.z;
	float2 o0a = 0.0, o0b = 0.0, o1a = 0.0, o1b = 0.0;
	float softRot = 0.0;
	if (softR > 0.0) {
		float3 e1 = normalize(abs(L.y) < 0.95 ? cross(L, float3(0.0, 1.0, 0.0)) : cross(L, float3(1.0, 0.0, 0.0)));
		float3 e2 = cross(L, e1);
		o0a = (f.shadowViewProj[0] * float4(e1 * softR, 0.0)).xy;
		o0b = (f.shadowViewProj[0] * float4(e2 * softR, 0.0)).xy;
		o1a = (f.shadowViewProj[1] * float4(e1 * softR, 0.0)).xy;
		o1b = (f.shadowViewProj[1] * float4(e2 * softR, 0.0)).xy;
		softRot = 6.2831853 * vlNoise(in.position.xy + 29.0, p.temporal.z);
	}
	ShadeCloudRay cloudRay = {};
	// M3.1: the cloud shadow is fetched on at most every other lit step and held for the next one (its texels are 4 blocks, the
	// shafts from cloud gaps tens of blocks wide; the steps jitter per frame). SHADE_CLOUD_DEV_OLD_VL: every lit step (M3);
	// SHADE_CLOUD_DEV_NO_VL: no clouds in VL (pricing)
	bool vlClouds = VL_HDR && !shadeCloudDev(sl, SHADE_CLOUD_DEV_NO_VL);
	int cloudEvery = VL_HDR && shadeCloudDev(sl, SHADE_CLOUD_DEV_OLD_VL) ? 1 : 2;
	int cloudAt = -8;
	float cloudHeld = 1.0;
	if (VL_HDR) cloudRay = shadeCloudRay(dir, sl); // (ShadeLook is read only in the HDR variant)

	if (VL_HDR && !underwater && p.air.x > 0.5) {
		// Air mode (godrays v3, 2026-10-09; Photon's approach, see the header). Gael on FT2.2-2.3's shafts: "pixeleados, bugueados,
		// manchas; deberían ser líneas de luz continuas como las de la vida real". Those came from a mist around the camera (cut a
		// few blocks above the eye, fading with the distance from it: smoke columns), carved and contrast-boosted into beams
		// (hard-edged sheets), while the final pass's haze (E06) glowed in the sun everywhere, shadow or not (the veil under the
		// trees). Here the one air the final pass fogs with (E06's haze and mist, ShadeLook: the same heights and densities) is
		// marched to the scene with the sun's shadow at every step, plus the forest's humid air: dense where the air around a
		// point lies mostly in the shade (the shade grid, vl_shade_grid), thin over open sunlit land (lit air there would only be
		// a veil). No carve, no local contrast: lit air is bright, shadowed air is not, so a shaft is lit air between shadowed air,
		// from the gap in the canopy down to the ground.
		// Output: what the shadows take out of the haze's sunlit glow (negative: the final pass adds that glow unshadowed at full
		// resolution, crisp at every edge) + the forest air's light (sun and a share of the sky). Open land in full sun: nothing
		// (the final pass's haze as it was).
		float yc = f.cameraBlock.y + f.cameraFract.y;
		float3 sigR = sl.fogR.rgb;
		float hR = sl.fogR.w, y0R = sl.fogMisc.x;
		float sigM = sl.fogM.x, hM = sl.fogM.y, y0M = sl.fogM.z, alM = sl.fogM.w;
		float local = p.light.w;
		bool skyPx = d <= 0.0;
		constexpr sampler gridLin(filter::linear, address::repeat);
		float3 gridSpan = p.grid.w * float3(VL_GRID_X, VL_GRID_Y, VL_GRID_Z);
		float3 gridWrap = p.grid2.xyz / float3(VL_GRID_X, VL_GRID_Y, VL_GRID_Z);
		float litK = 1.0 / max(p.air3.y - p.air3.x, 1e-3);
		float D = min(dist, p.air2.x);
		int na = clamp(int(p.air.y + p.air.z * D), 2, int(max(p.air.w, 2.0)));
		float invN = 1.0 / float(na);
		// (one transmittance for all three channels, from the haze's luminance: its colour matters in what it scatters, its
		// extinction over the march is at most ~0.1, so a grey one costs nothing visible and a third of the exp per step)
		float trans = 1.0, mistAll = 0.0, mistLit = 0.0, forestLit = 0.0, forestAll = 0.0;
		float hazeAll = 0.0, hazeLit = 0.0; // (FT2.7, audit idx 1: scalars, times sigR once after the loop)
		float apAll = 0.0, apLit = 0.0; // (FT2.12) the ray's length and its sunlit part (the aerial blend's glow, uniform along it)
		float lumR = dot(sigR, float3(0.2126, 0.7152, 0.0722));
		float prevB = 0.0;
		// (FT2.7, audit idx 0; air6.w > 0) a sky pixel with airSkyCut and airBase 0: past the shade grid (and the forest air's
		// fade-out) every step only feeds sums the sky multiplies by 0 (shadowed *= air2.y below; outside the grid dF = air4.x = 0),
		// so its march stops there. The same image; the far steps (far cascade, cloud shadows) were ~0.2 ms where half the view is sky
		float tStop = D;
		if (skyPx && p.air6.w > 0.0 && p.air2.y == 0.0 && p.air4.x <= 0.0) {
			float3 ex = select(-p.grid.xyz, p.grid.xyz + gridSpan, dir > 0.0) / max(abs(dir), 1e-6); // the camera is inside the grid
			tStop = min(min(ex.x, min(ex.y, ex.z)) + 1.0, D);
			if (p.air5.y > p.air5.x) tStop = min(tStop, p.air5.y);
			if (local <= 0.0) tStop = 0.0;
		}
		for (int i = 0; i < na; i++) {
			// quadratic spacing (dense near the camera, where the trees' shadows are), each texel offset on its own (bit 32)
			float u1 = float(i + 1) * invN, u = (float(i) + xi) * invN;
			float b1 = D * u1 * u1, t = D * u * u, dt = b1 - prevB;
			if (t > tStop) break;
			prevB = b1;
			float y = yc + dir.y * t;
			float fR = exp(-max(y - y0R, 0.0) / hR);
			float dM = sigM * exp(-max(y - y0M, 0.0) / hM);
			// the forest air: the lit share around this point (the grid, trilinear) -> full density at or below air3.x, air4.x of it
			// at or above air3.y (open sunlit land); past the grid (faded over its last 8 blocks) air4.x; faded in from the camera
			// (air3.z: the near field stays crisp)
			float dF = 0.0;
			if (local > 0.0) {
				float3 g = (dir * t - p.grid.xyz) / gridSpan;
				float3 edge = min(g, 1.0 - g) * gridSpan;
				float inGrid = saturate(min(edge.x, min(edge.y, edge.z)) * 0.125); // (outside: air4.x alone)
				float shade = p.air4.x;
				if (inGrid > 0.0) shade = mix(p.air4.x, max(saturate((p.air3.y - float(shadeGrid.sample(gridLin, g + gridWrap).r)) * litK), p.air4.x), inGrid);
				dF = local * shade * (p.air3.z > 0.0 ? saturate(t / p.air3.z) : 1.0);
				// (FT2.6, air5) faded out far from the camera: the humid air of the forest around the player, not puffs over distant
				// ridges
				if (p.air5.y > p.air5.x) dF *= 1.0 - smoothstep(p.air5.x, p.air5.y, t);
				// (FT2.6, air5.z < 1) with the camera in the open (the canopy factor, vl_canopy) only that share of it: the shafts are
				// strongest in the forest around you (Complementary's "scene-aware" idea), not as lone plumes on a ridge far away
				dF *= mix(p.air5.z, 1.0, saturate(canopy));
			}
			float ext = lumR * fR + dM + dF * p.mist.w;
			float3 q0 = c0o + c0d * t, q1 = c1o + c1d * t;
			if (softR > 0.0) {
				float a = softRot + 2.3999632 * float(i), r = sqrt(fract((float(i) + 0.5) * 0.618034 + softRot));
				float2 cs = float2(cos(a), sin(a)) * r;
				q0.xy += o0a * cs.x + o0b * cs.y;
				q1.xy += o1a * cs.x + o1b * cs.y;
			}
			float v = shadows ? vlShadow(map, cmp, q0, q1, farOnly) : 1.0;
			if (vlClouds && v > 0.0) {
				if (i - cloudAt >= cloudEvery) {
					cloudHeld = shadeCloudShadowRay(cloudRay, t, sl, sr.cloudShadow);
					cloudAt = i;
				}
				v *= cloudHeld;
			}
			// energy-conserving segment integral (1 - e^-sigma dt) / sigma, times the transmittance so far
			float stepT = exp(-ext * dt);
			float seg = trans * (1.0 - stepT) / max(ext, 1e-9);
			float segR = fR * seg;
			hazeAll += segR;
			hazeLit += v * segR;
			mistAll += dM * seg;
			mistLit += v * dM * seg;
			apAll += dt;
			apLit += v * dt;
			forestLit += v * dF * seg;
			forestAll += dF * seg;
			trans *= stepT;
		}
		float3 hA = hazeAll * sigR, hL = hazeLit * sigR;
		// E06's phase functions, multiple-scattering boosts and evening glow (shade_m2.metal shadeHazeInscatter): its sunlit part
		// times (lit - all) = what the shadows take out of it
		float phR = 0.0596831 * (1.0 + mu * mu);
		float phM = 0.8 * shadeHG(mu, SHADE_HAZE_MIE_G) + 0.2 * shadeHG(mu, -0.2);
		float glow = 1.0 + sl.fogMisc.w;
		// (FT2.10) the sunlight the final pass's haze has around the camera (shadeAirSun: none in a cave), so only what it added is
		// taken out (else the shadows darkened a cave's walls down to the floor of what they may take, mcopt.shade.vl.airFloor)
		float3 E = f.sunColor.rgb * (3.14159265 * shadeAirSun(sl));
		float3 shadowed = E * ((hL - hA) * (phR * 2.0) + (mistLit - mistAll) * (phM * glow * alM / (1.0 - 0.5 * alM)));
		// (FT2.12) and the aerial blend's glow around the sun (shade_m2.metal shadeAerialSunGlow; the terrain mixed it in unshadowed)
		// by the share of the ray in shade: its density (fogSky.z, ~1/1250 per block) is even along the ray. A sun set behind a
		// mountain no longer glows through it (Gael 2026-10-11)
		// (only where some of the ray is in shade: the lookups cost ~0.03 ms over the whole view)
		if (!skyPx && apLit < apAll * 0.999) shadowed -= shadeAerialSunGlow(dir * dist, skyLut, lutS, f, sl) * ((apAll - apLit) / apAll);
		// on the sky the haze's glow is the sky model's own: the shadows take out a share of it (air2.y; dark rays from the trees'
		// and hills' shadows across the glow around the sun)
		if (skyPx) shadowed *= p.air2.y;
		// the forest air: Photon's two-lobe Mie phase over four multiple-scattering octaves (see the header)
		// (air4.y > 0: one forward lobe of that g plus an isotropic share air4.z instead, x 1.875 = the octaves' total)
		float phF = 0.0, octave = 1.0, aniso = 1.0;
		if (p.air4.y > 0.0) {
			phF = 1.875 * ((1.0 - p.air4.z) * vlHG(mu, p.air4.y) + p.air4.z * 0.0795775);
		} else {
			for (int k = 0; k < 4; k++) {
				phF += octave * (0.7 * vlHG(mu, 0.5 * aniso) + 0.3 * vlHG(mu, -0.2 * aniso));
				octave *= 0.5;
				aniso *= 0.7;
			}
		}
		// (its sky-lit part: the final pass haze's sky radiance, ambientSky x 0.9, the share the canopy leaves, air3.w; FT2.9: as far as
		// the sky lights the air around the camera, shadeAirSky: a cave is all shade, so the forest air filled it with sky-blue fog)
		float3 forest = p.light.rgb * (3.14159265 * phF * glow) * forestLit + f.ambientSky.rgb * (0.9 * p.air3.w * shadeAirSky(sl)) * forestAll;
		scatter = shadowed * p.air2.z + forest * (p.air2.w * p.shape.x);
	} else if (!underwater) {
		float D = min(dist, p.shape.y);
		float mist = p.medium.y;
		// canopy mist: the humid air under trees and overhangs, around the camera's height (not the sea's)
		float local = p.light.w * canopy;
		int nNear = int(p.extra.w);
		// the canopy mist (density e^(-t/R) from the camera) gets its own linear march over its first 2.5 R (~92 % of it):
		// the main march's quadratic spacing put only ~5 of its samples there, too few to resolve the leaf gaps into beams
		float localMain = nNear > 0 ? 0.0 : local;
		float sumOpen = 0.0, sumOpenLit = 0.0, sumLocal = 0.0, sumLocalAll = 0.0, trans = 1.0, prevB = 0.0;
		float invN = 1.0 / float(n);
		// (the main march keeps the shared offset: per texel it cost 0.15-0.2 ms in the forest views, from the cache misses
		// of its far steps, for no measurable gain once the canopy mist's steps are per texel; VL_FLICKER.md)
		for (int i = 0; i < n; i++) {
			float u1 = float(i + 1) * invN, u = (float(i) + xi) * invN;
			float b1 = D * u1 * u1, t = D * u * u, dt = b1 - prevB;
			prevB = b1;
			float y = dir.y * t;
			float sOpen = p.medium.x * exp(-max(y - p.haze.x, 0.0) / p.haze.y) + mist * exp(-max(y - p.medium.z, 0.0) / p.medium.w);
			float sLocal = localMain * vlMistDensity(t, y, p);
			float sigma = sOpen + sLocal;
			float3 q0 = c0o + c0d * t, q1 = c1o + c1d * t;
			if (softR > 0.0) {
				float a = softRot + 2.3999632 * float(i), r = sqrt(fract((float(i) + 0.5) * 0.618034 + softRot));
				float2 cs = float2(cos(a), sin(a)) * r;
				q0.xy += o0a * cs.x + o0b * cs.y;
				q1.xy += o1a * cs.x + o1b * cs.y;
			}
			float v = shadows ? vlShadow(map, cmp, q0, q1, farOnly) : 1.0;
			// M3: the volumetric clouds' shadows carve the air into shafts too (crepuscular rays from cloud gaps)
			// (only where the sun reaches: no fetch in the terrain's shadow)
			if (vlClouds && v > 0.0) {
				if (i - cloudAt >= cloudEvery) {
					cloudHeld = shadeCloudShadowRay(cloudRay, t, sl, sr.cloudShadow);
					cloudAt = i;
				}
				v *= cloudHeld;
			}
			// energy-conserving segment integral: (1 - e^-sigma dt) / sigma, times the transmittance so far, split by layer
			float seg = trans * (1.0 - exp(-sigma * dt)) / max(sigma, 1e-9);
			sumOpen += sOpen * seg;
			sumOpenLit += v * sOpen * seg;
			sumLocal += v * sLocal * seg;
			sumLocalAll += sLocal * seg;
			trans *= exp(-(sOpen + sLocal * p.mist.w) * dt);
		}
		// (2026-10-09) the far march: at the golden hour (ShadeVl sets tune.w) the rays from gaps between the clouds cross
		// hundreds of blocks of air toward the low sun; past the main march's range (and the shadow map's) only the clouds'
		// shadow carves the open air there. Same medium and integral, continuing the transmittance.
		float farOpen = 0.0, farLit = 0.0;
		if (VL_HDR && vlClouds && p.tune.w > D + 1.0 && dist > D + 1.0) {
			float Df = min(dist, p.tune.w), dtf = (Df - D) / float(VL_FAR_STEPS);
			for (int i = 0; i < VL_FAR_STEPS; i++) {
				float t = D + (float(i) + xi) * dtf;
				float y = dir.y * t;
				float sOpen = (p.medium.x * exp(-max(y - p.haze.x, 0.0) / p.haze.y) + mist * exp(-max(y - p.medium.z, 0.0) / p.medium.w)) * p.tune2.x;
				float v = shadeCloudShadowRay(cloudRay, t, sl, sr.cloudShadow);
				float seg = trans * (1.0 - exp(-sOpen * dtf)) / max(sOpen, 1e-9);
				farOpen += sOpen * seg;
				farLit += v * sOpen * seg;
				trans *= exp(-sOpen * dtf);
			}
		}
		if (nNear > 0 && local > 1e-7) {
			float Dn = min(D, 2.5 * p.mist.x), dtn = Dn / float(nNear), tl = 1.0;
			// M2.2 (sunPx.w bit 8): each texel's own offset (IGN + R1). With the march's shared per-frame offset every ray of a
			// neighbourhood crossed the leaf shadows at the same depths, so the light of the whole neighbourhood rose and fell
			// together: the temporal clamp, built from the neighbours, followed that noise and the beams and the veil over the sky
			// flickered (the carve's 1 / (1 - k) gain made it worse). Its few steps stay within the near cascade around the camera.
			float xn = (int(p.sunPx.w) & 8) != 0 ? vlNoise(in.position.xy + 7.0, p.temporal.z) : fract(xi + 0.5);
			for (int j = 0; j < nNear; j++) {
				float t = (float(j) + xn) * dtn;
				float sLocal = local * vlMistDensity(t, dir.y * t, p);
				float3 q0 = c0o + c0d * t, q1 = c1o + c1d * t;
				if (softR > 0.0) {
					float a = softRot + 2.3999632 * float(j + 7), r = sqrt(fract((float(j) + 0.25) * 0.618034 + softRot * 0.37));
					float2 cs = float2(cos(a), sin(a)) * r;
					q0.xy += o0a * cs.x + o0b * cs.y;
					q1.xy += o1a * cs.x + o1b * cs.y;
				}
				float v = shadows ? vlShadow(map, cmp, q0, q1, farOnly) : 1.0;
				float seg = tl * (1.0 - exp(-sLocal * dtn)) / max(sLocal, 1e-9);
				sumLocal += v * sLocal * seg;
				sumLocalAll += sLocal * seg;
				tl *= exp(-sLocal * p.mist.w * dtn);
			}
		}
		// The open-air haze's sun glow is already in the sky and M1's aerial haze: keep only what the shadows carve out of
		// it (the lit part above a share of its unshadowed value) so shafts read as structure, not as a milky veil. The
		// canopy mist (ours alone) counts fully. Each layer has its art gate.
		// (2026-10-09) the cuts by the angle to the light: looking toward it the lit air's forward glow would veil the view (the
		// sunset washed into gold), so most of it stays out there; from the side that glow is weak and a lower cut lets the
		// shadowed and lit air read as beams (Gael: "se ven poquito")
		float sunward = smoothstep(0.35, 0.9, mu);
		float openCut = mix(p.tune.y, p.mistAmb.w, sunward);
		float openPart = max(sumOpenLit - openCut * sumOpen, 0.0) + max(farLit - p.tune2.y * farOpen, 0.0);
		float k = mix(p.tune.z, p.carve.x, sunward);
		sumLocal = max(sumLocal - k * sumLocalAll, 0.0) / (1.0 - k);
		scatter = p.light.rgb * (3.14159265 * vlPhase(mu, p) * (openPart * p.gate.x + sumLocal * p.gate.y) * p.shape.x);
	} else {
		// Under water: the medium is the water; sunlight reaches each point through the water above it (extinction along the
		// refracted-ish path to the surface) and arrives patterned by the surface's caustics, which stay constant along the
		// light direction: curtains of light (shafts) that sway with the waves.
		float D = min(dist, p.water2.z);
		float3 ext = p.water.rgb;
		float3 sum = float3(0.0), sumAll = float3(0.0);
		int nw = n + 2;
		float prevB = 0.0, invN = 1.0 / float(nw);
		half4 ta, tb;
		half ta4, tb4;
		vlCausticPhases(p.temporal.w, ta, ta4, tb, tb4);
		float ly = max(L.y, 0.12);
		// M2.2 (sunPx.w bit 16): each texel's own offset, like the canopy mist's steps (the curtains flickered under the
		// shared per-frame offset)
		float xw = (int(p.sunPx.w) & 16) != 0 ? vlNoise(in.position.xy + 13.0, p.temporal.z) : xi;
		for (int i = 0; i < nw; i++) {
			float u1 = float(i + 1) * invN, u = (float(i) + xw) * invN;
			float b1 = D * u1 * u1, t = D * u * u, dt = b1 - prevB;
			prevB = b1;
			float3 pt = dir * t;
			float below = max(p.water2.x - pt.y, 0.0);
			float path = below / ly;
			float2 q = pt.xz + L.xz * path + f.cameraFract.xz + fmod(f.cameraBlock.xz, 256.0);
			// the waves focus the light over a few blocks (no pattern right under the surface), then it spreads out again
			half hb = half(min(below, 60.0));
			half c = mix(1.0h, vlCaustic(q, ta, ta4, tb, tb4), half(p.water2.w) * (1.0h - exp2(-0.5771h * hb)) * exp2(-0.0721h * hb));
			float v = shadows ? vlShadow(map, cmp, c0o + c0d * t, c1o + c1d * t) : 1.0;
			float3 tr = float3(exp2(half3(-1.442695 * ext * min(path + t, 200.0)))) * (v * dt);
			sum += tr * float(c);
			sumAll += tr;
		}
		// carve (M2): drop part of the uniform glow so the caustic curtains read as shafts
		sum = max(sum - p.carve.y * sumAll, 0.0) / (1.0 - p.carve.y);
		float phase = 0.75 * vlHG(mu, 0.65) + 0.25 * 0.0795775;
		scatter = p.light.rgb * sum * (p.water.w * 3.14159265 * phase * p.shape.x) * float(L.y > 0.0);
	}

	// this pixel's own cloud transmittance where it shows sky (1 = clear; the sky mask for the next frame, below)
	half skyT = d <= 0.0 ? (VL_HDR && !shadeCloudDev(sl, SHADE_CLOUD_DEV_NO_VL) ? half(shadeCloudsScreen(dir, sl, sr.cloudScreen).a) : 1.0h) : 0.0h;
	// Crepuscular streaks: march toward the light over last frame's sky mask (VL resolution, one byte per texel: a sixteenth
	// of the bytes of the full-res depth, cache-friendly); sky seen along the way lets light through. Skipped on a reset.
	// (FT2.7, audit idx 3: not on geometry when its streaks' gain look2.x is 0, the HDR default: the taps' result was times 0)
	if (p.crep.x > 0.0 && p.crep.z > 0.0 && !underwater && p.temporal.y < 0.5 && (d <= 0.0 || !VL_HDR || p.look2.x != 0.0)) {
		float2 toV = (p.sunPx.xy - fpos) / scale, fv = in.position.xy;
		// (FT2.7, audit idx 21; air7.w > 0) the mask is last frame's: march its pixels, from where this pixel's direction and the
		// sun were last frame (a turn maps sky directions by a homography: the segment to the sun stays a segment), at last
		// frame's live size. This frame's pixels made the dark sky rays lag their clouds and trees by a frame of the turn
		float2 prevLiveV = p.carve.z > 0.0 ? p.carve.zw * float2(prevSky.get_width(), prevSky.get_height()) : p.size.xy;
		float2 liveV = p.size.xy;
		if (p.air7.w > 0.0) {
			float4 pcP = f.prevViewProj * float4(dir, 0.0), pcS = f.prevViewProj * float4(L, 0.0);
			if (pcP.w > 1e-4 && pcS.w > 1e-4) {
				fv = (pcP.xy / pcP.w * 0.5 + 0.5) * prevLiveV;
				toV = (pcS.xy / pcS.w * 0.5 + 0.5) * prevLiveV - fv;
				liveV = prevLiveV;
			}
		}
		int taps = int(p.crep.y);
		float open = 0.0, wsum = 0.0, w = 1.0;
		// M3.3 (art.z): the same taps without the first quarter (the pixel's own neighbourhood): how much of the way toward
		// the sun is open, for the golden-hour gain over the open sky (a clear pixel's own mask no longer dilutes the
		// shadow of a cloud between it and the sun)
		float openFar = 0.0, wFar = 0.0;
		int kFar = max(taps / 4, 1);
		// M2.2 (sunPx.w bit 4): each texel's own tap offset (IGN + R1) and a bilinear mask: the shared per-frame offset moved
		// every tap of a neighbourhood across the leaf holes together, so the neighbourhood clamp could not see that noise and
		// the dark sky rays and the streaks changed every frame; the mask is small (R8 at VL resolution), so the scattered
		// taps stay in cache
		bool smoothTaps = (int(p.sunPx.w) & 4) != 0;
		float xc = smoothTaps ? vlNoise(in.position.xy, p.temporal.z) : xi;
		constexpr sampler maskLin(filter::linear, address::clamp_to_edge);
		float2 maskTexel = 1.0 / float2(prevSky.get_width(), prevSky.get_height());
		for (int k = 0; k < taps; k++) {
			float s = (float(k) + xc) / float(taps);
			float2 q = fv + toV * (s * s);
			if (all(q >= 0.0) && all(q < liveV)) {
				float m = smoothTaps ? float(prevSky.sample(maskLin, clamp(q, 0.5, liveV - 0.5) * maskTexel).r)
				                     : float(prevSky.read(uint2(q)).r);
				open += m * w;
				if (k >= kFar) openFar += m * w;
			}
			wsum += w;
			if (k >= kFar) wFar += w;
			w *= 0.92;
		}
		open /= max(wsum, 1e-4);
		openFar /= max(wFar, 1e-4);
		float ang = saturate(mu);
		float fall = pow(ang, p.crep.w);
		if (d <= 0.0) {
			// the sky: the sky model already has the sun's glow; the streaks there are the shadows of the clouds and hills
			// between the sun and the air (Photon's dark rays across the aureole). Negative light: the final pass subtracts it
			// (floored at a share of the pixel), so open sky keeps its colour
			// (M3.3: x art.x (dev), plus the golden-hour gain art.y over the open sky, weighted by T^2 (T, this pixel's own cloud
			// transmittance: the clouds, whose bodies this same term shades, keep M3.2's look); art.z 1: that extra from the taps
			// past the pixel's own neighbourhood (openFar); art.w > 0: its own falloff exponent around the sun (reaches
			// further than crep.w). art = (1, 0, 0, 0) is M3.2's line exactly)
			float fallX = p.art.w > 0.0 ? pow(ang, p.art.w) : fall;
			float extra = p.art.y * float(skyT * skyT) * (1.0 - (p.art.z > 0.5 ? openFar : open)) * fallX;
			if (VL_HDR) scatter -= p.light.rgb * (((1.0 - open) * fall + extra) * p.crep.x * p.crep.z * 1.5 * p.art.x);
			else scatter += p.light.rgb * (open * fall * p.crep.x * p.crep.z * 0.8);
		} else {
			// in front of near geometry (a trunk against the low sun gets streaks across it), fading in over the first blocks:
			// only light coming through gaps (above the typical openness), not a uniform glow
			float reach = saturate((dist + 6.0) / 48.0);
			float gaps = VL_HDR ? saturate((open - 0.25) / 0.75) : open;
			// (FT2.3: x look2.x, 0 by default: these screen-space streaks drew light across trunks in front of the sun, Gael:
			// "están atravesando el árbol"; the shadow-map shafts already carry the light between the camera and a surface)
			scatter += p.light.rgb * (gaps * fall * p.crep.x * p.crep.z * reach * (VL_HDR ? p.look2.x : 1.0));
		}
	}
	VlMarchOut o;
	o.light = half4(half3(clamp(scatter, -30000.0, 30000.0)), half(dist));
	// the sky mask: how open the sky is here; M3: the volumetric clouds' transmittance there, so next frame's crepuscular
	// taps toward the sun see the clouds (dark rays across the aureole from the clouds around the sun)
	o.sky = skyT;
	return o;
}

// ---- temporal -------------------------------------------------------------------------------------------------------------
static inline half4 vlTemporalRaw(VlOut in, constant ShadeFrame &f, constant VlParams &p, texture2d<half> raw, texture2d<half> history) {
	constexpr sampler lin(filter::linear, address::clamp_to_edge);
	int2 px = int2(in.position.xy);
	int2 hi = int2(p.size.xy) - 1;
	half4 c = raw.read(uint2(px));
	float d = float(c.a);
	float3 sum = float3(c.rgb) * 2.0;
	float wsum = 2.0;
	float3 mn = float3(c.rgb), mx = mn;
	// a plus of 5 taps with a tight depth weight (a 3x3 smoothed the beams away; the history does the denoising)
	const int2 taps[4] = {int2(1, 0), int2(-1, 0), int2(0, 1), int2(0, -1)};
	for (int k = 0; k < 4; k++) {
		half4 s = raw.read(uint2(clamp(px + taps[k], int2(0), hi)));
		float w = exp(-abs(float(s.a) - d) / (0.03 * d + 0.3));
		sum += float3(s.rgb) * w;
		wsum += w;
		if (w > 0.35) {
			mn = min(mn, float3(s.rgb));
			mx = max(mx, float3(s.rgb));
		}
	}
	// M2.2: the clamp box over the full 3x3 again (as before M2's review), only the filter stays a plus: the plus's box
	// was so tight that the history snapped to each frame's noise (shafts flickering at leaf edges)
	if ((int(p.sunPx.w) & 1) != 0) {
		const int2 diag[4] = {int2(1, 1), int2(-1, 1), int2(1, -1), int2(-1, -1)};
		for (int k = 0; k < 4; k++) {
			half4 s = raw.read(uint2(clamp(px + diag[k], int2(0), hi)));
			if (abs(float(s.a) - d) < 1.05 * (0.03 * d + 0.3)) { // the plus's depth tolerance (its w > 0.35)
				mn = min(mn, float3(s.rgb));
				mx = max(mx, float3(s.rgb));
			}
		}
	}
	float3 cur = sum / wsum;
	if (p.temporal.y > 0.5) return half4(half3(cur), half(d));
	// reproject: this pixel's point in last frame's clip space
	float2 scale = p.size.zw / p.size.xy;
	float2 fpos = floor(in.position.xy * scale) + 0.5;
	float2 ndc = fpos / p.size.zw * 2.0 - 1.0;
	float3 dir = vlDirection(ndc, f);
	bool sky = d >= 9000.0;
	// (the point from the eye, where the march starts: view bobbing moves it up to 0.1 block, ~0.5 degrees at 10 blocks; from
	// the camera's origin the history trailed the bob while walking, 2026-10-09)
	float4 pc = sky ? f.prevViewProj * float4(dir, 0.0) : f.prevViewProj * float4(shadeEye(f.invViewProj) + dir * d, 1.0);
	if (pc.w <= 1e-4) return half4(half3(cur), half(d));
	float2 puv = (pc.xy / pc.w) * 0.5 + 0.5;
	if (any(puv < 0.0) || any(puv > 1.0)) return half4(half3(cur), half(d));
	// the history covers the live part of its target that last frame used (TAAU dynamic resolution: carve.zw)
	float2 hs = p.carve.z > 0.0 ? p.carve.zw : float2(1.0);
	float2 hdim = float2(history.get_width(), history.get_height());
	float2 hTexel = 0.5 / hdim;
	float dPrev = sky ? 1e4 : length(dir * d + p.camDelta.xyz);
	float tol = 0.08 * dPrev + 0.6;
	half4 h;
	bool valid;
	if ((int(p.sunPx.w) & 2) != 0) {
		// M2.2: the bilinear footprint's texels at this point's distance only. A plain bilinear fetch blended the distances of a
		// leaf and the sky behind it into one that matched neither, so every texel near a leaf edge lost its history and showed
		// this frame's raw march; under TAAU the jitter moves the leaf edges by a sub-pixel every frame, so the texels along
		// them alternated leaf/sky and their light jumped between the two raw values (shafts flickering at the leaf edges).
		float2 huv = clamp(puv * hs, hTexel, hs - hTexel);
		float2 hp = huv * hdim - 0.5;
		float2 hfl = floor(hp), hfr = hp - hfl;
		// the footprint's four distances in one fetch (order (0,1) (1,1) (1,0) (0,0)): all at this distance (most texels) ->
		// one hardware-filtered sample
		float4 hd4 = float4(history.gather(lin, (hfl + 1.0) / hdim, int2(0), component::w));
		if (all(abs(hd4 - dPrev) < tol)) {
			h = history.sample(lin, huv);
			valid = true;
		} else {
			int2 hb = int2(hfl), hhi = int2(hs * hdim + 0.5) - 1;
			float4 acc = 0.0;
			float wacc = 0.0;
			for (int j = 0; j <= 1; j++) {
				for (int i = 0; i <= 1; i++) {
					half4 s = history.read(uint2(clamp(hb + int2(i, j), int2(0), hhi)));
					float bw = (i == 0 ? 1.0 - hfr.x : hfr.x) * (j == 0 ? 1.0 - hfr.y : hfr.y) + 1e-4;
					if (abs(float(s.a) - dPrev) < tol) {
						acc += float4(s) * bw;
						wacc += bw;
					}
				}
			}
			valid = wacc > 0.0;
			h = half4(acc / max(wacc, 1e-6));
		}
	} else {
		h = history.sample(lin, clamp(puv * hs, hTexel, hs - hTexel));
		valid = abs(float(h.a) - dPrev) < tol;
	}
	if (!valid) return half4(half3(cur), half(d));
	// widen the box a little (the march is noisy; a tight box would flicker)
	float3 mid = 0.5 * (mn + mx), ext = 0.5 * (mx - mn) * 1.35 + 0.002 * (abs(mid) + 0.001);
	// Still view (M2.2): the march's jitter is coherent (one step offset for the whole frame, so neighbouring rays sample the same
	// depths and the shadow fetches stay in cache): its error is the same for a texel and its neighbours, so the box above,
	// built from this frame's neighbours, moves with it and clamps the history onto this frame's noise. The shafts through
	// leaf gaps, the dark sky rays and the screen-space streaks then changed every frame (flicker, wobble). Where the history
	// lands on this texel (the reprojection moved it less than ~1 VL pixel) the box widens by a share of its mean, so the
	// history can average the jitter out; under motion the plain box (no ghosting).
	if (p.sunPx.z > 0.0) {
		float2 moved = puv * p.size.zw / scale - in.position.xy;
		float still = 1.0 - smoothstep(0.75, 2.0, length(moved));
		ext += still * p.sunPx.z * (abs(mid) + 0.5 * (mx - mn));
	}
	float3 hc = clamp(float3(h.rgb), mid - ext, mid + ext);
	return half4(half3(mix(cur, hc, p.temporal.x)), half(d));
}

// (1.1.1) what the history keeps is never Inf or NaN (shadeBad: fast math may drop isfinite); a bad texel becomes no light at
// the sky's distance, and the next frames refill it
static inline half4 vlTemporal(VlOut in, constant ShadeFrame &f, constant VlParams &p, texture2d<half> raw, texture2d<half> history) {
	half4 r = vlTemporalRaw(in, f, p, raw, history);
	return shadeBad(r) ? half4(0.0h, 0.0h, 0.0h, 10000.0h) : r;
}

fragment half4 vl_temporal(VlOut in [[stage_in]], constant ShadeFrame &f [[buffer(16)]], constant VlParams &p [[buffer(0)]],
                           texture2d<half> raw [[texture(0)]], texture2d<half> history [[texture(1)]]) {
	return vlTemporal(in, f, p, raw, history);
}

// M2 "fold" (ShadePost.setVolumetric): the temporal pass also writes what the final pass blends in, at VL resolution:
// rgb = in-scattered light incl. the canopy mist's sky-lit veil (radiance before exposure), a = the canopy mist's
// transmittance T (analytic, per VL texel; the final pass upsamples it depth-aware with the history's distances).
struct VlFoldOut {
	half4 history [[color(0)]];
	half4 lightT [[color(1)]];
};

// The shafts' local contrast (2026-10-09, Gael: the stronger god rays veiled the view "como un lente empanado"). Where a ray
// crosses tens of blocks of lit mist (a low sun under the trees, the lit clearing behind a trunk) the in-scattered light is a
// uniform glow: no per-pixel measure tells it from a beam (both are lit air along the ray), only its surroundings do. So
// each VL texel is compared with the local mean of r = (in-scattered luminance) / (the canopy mist's optical depth along the
// ray + half a block): how lit the air along the ray is, the same for a ray that ends on a leaf a block away and one that
// crosses the forest (their mean has no halo at depth edges). With rbar that mean, the light becomes
//   max(gain * l - (gain - keep) * rbar * R, 0):  keep x a uniform glow (r = rbar), more than before for a beam (r > rbar),
// nothing for air darker than ~(gain - keep) / gain of its surroundings: visible shafts without the veil. rbar = last frame's
// (vl_veil_down + 2 blur passes at a quarter of the VL resolution, after this pass; low frequency, so one frame late is fine).
static inline float vlVeilR(float3 light, float3 dir, float dist, constant VlParams &p) {
	return max(dot(light, float3(0.2126, 0.7152, 0.0722)), 0.0) / (vlMistDepth(dir, min(dist, p.shape.y), p) + 0.5);
}

fragment VlFoldOut vl_temporal_fold(VlOut in [[stage_in]], constant ShadeFrame &f [[buffer(16)]], constant VlParams &p [[buffer(0)]],
                                    constant VlState &st [[buffer(1)]], texture2d<half> raw [[texture(0)]], texture2d<half> history [[texture(1)]],
                                    texture2d<half> veil [[texture(2)]]) {
	VlFoldOut o;
	o.history = vlTemporal(in, f, p, raw, history);
	float3 light = float3(o.history.rgb);
	float T = 1.0;
	float canopy = p.gate.z >= 0.0 ? p.gate.z : max(st.canopy.x, p.tune.x);
	float mistK = p.light.w * canopy * p.mist.w * p.mist.z;
	bool air = p.water2.y < 0.5;
	bool hp = p.hp.w > 0.5 && p.temporal.y < 0.5 && air && canopy > 0.01;
	if ((mistK > 1e-5 && air) || hp) {
		float2 fpos = floor(in.position.xy * (p.size.zw / p.size.xy)) + 0.5;
		float2 ndc = fpos / p.size.zw * 2.0 - 1.0;
		float3 dir = vlDirection(ndc, f);
		float dist = float(o.history.a);
		if (hp) {
			float l = dot(light, float3(0.2126, 0.7152, 0.0722));
			if (l > 0.0) {
				constexpr sampler lin(filter::linear, address::clamp_to_edge);
				float2 vs = float2(veil.get_width(), veil.get_height());
				float2 live = ceil(p.size.xy * 0.25);
				float rbar = float(veil.sample(lin, clamp(in.position.xy * 0.25, float2(0.5), live - 0.5) / vs).r);
				// in full from a canopy factor of 0.2: walking out of a forest the factor fades over ~4 s, and the canopy mist
				// (2.5x FT2.1's) must not glow over the clearing meanwhile (final4b: lake right after the overhang)
				float hw = saturate(canopy * 5.0);
				float keep = mix(1.0, p.hp.x, hw), gain = mix(1.0, p.hp.y, hw);
				float R = vlMistDepth(dir, min(dist, p.shape.y), p) + 0.5;
				light *= max(gain - (gain - keep) * rbar * R / l, 0.0);
			}
		}
		if (mistK > 1e-5 && air) {
			T = exp2(-1.442695 * mistK * vlMistDepth(dir, min(dist, p.shape.y), p));
			light += p.mistAmb.rgb * (1.0 - T);
		}
	}
	o.lightT = half4(half3(min(light, 30000.0)), half(T));
	return o;
}

// The shafts' continuity (FT2.3, Gael 2026-10-09: "deberían ser líneas de luz continuas como las de la vida real, las del shader
// parecen manchas"). Every shaft is a line along the light direction L, so on screen it lies on a line through L's vanishing
// point V (the sun, the point opposite it behind the camera, or parallel lines when V is at infinity): at NDC x the line's
// direction is V.xy - x V.w. A symmetric Gaussian blur along that line joins the march's patches (low resolution, jittered steps,
// leaf-sized gaps) into continuous lines while a shaft's edge across it stays; taps at another depth (a trunk in front of the
// air) count a tenth. Light + T in, the same out (T, analytic, is kept as is).
fragment half4 vl_radial(VlOut in [[stage_in]], constant VlParams &p [[buffer(0)]], texture2d<half> lightT [[texture(0)]],
                         texture2d<half> hist [[texture(1)]]) {
	constexpr sampler lin(filter::linear, address::clamp_to_edge);
	float2 pos = in.position.xy;
	half4 c = lightT.read(uint2(pos));
	int n = int(p.radial.w);
	float2 ndc = pos / p.size.xy * 2.0 - 1.0;
	float2 d = (p.radial.xy - ndc * p.radial.z) * p.size.xy;
	float len = length(d);
	if (n <= 0 || len < 1e-4) return c;
	d *= p.tune2.w / len;
	float dc = float(hist.read(uint2(pos)).a);
	float tol = 0.06 * dc + 0.6;
	float2 tex = 1.0 / float2(lightT.get_width(), lightT.get_height());
	float2 hi = p.size.xy - 0.5;
	int2 last = int2(p.size.xy) - 1;
	float3 sum = float3(c.rgb);
	float wsum = 1.0, inv = 2.0 / float(n * n);
	for (int k = 1; k <= n; k++) {
		float wk = exp(-float(k * k) * inv);
		for (int sg = -1; sg <= 1; sg += 2) {
			float2 q = clamp(pos + d * float(k * sg), float2(0.5), hi);
			float ds = float(hist.read(uint2(clamp(int2(q), int2(0), last))).a);
			float w = wk * (abs(ds - dc) < tol ? 1.0 : 0.1);
			sum += float3(lightT.sample(lin, q * tex).rgb) * w;
			wsum += w;
		}
	}
	return half4(half3(sum / wsum), c.a);
}

// The veil (see vlVeilR), 1: the mean r of each 4x4 block of this frame's VL history (quarter resolution, R16F).
fragment half vl_veil_down(VlOut in [[stage_in]], constant ShadeFrame &f [[buffer(16)]], constant VlParams &p [[buffer(0)]],
                           texture2d<half> history [[texture(0)]]) {
	int2 base = int2(in.position.xy) * 4, hi = int2(p.size.xy) - 1;
	float2 scale = p.size.zw / p.size.xy;
	float sum = 0.0;
	for (int j = 0; j < 4; j++) {
		for (int i = 0; i < 4; i++) {
			int2 q = min(base + int2(i, j), hi);
			half4 h = history.read(uint2(q));
			float2 fpos = floor((float2(q) + 0.5) * scale) + 0.5;
			sum += vlVeilR(float3(h.rgb), vlDirection(fpos / p.size.zw * 2.0 - 1.0, f), float(h.a), p);
		}
	}
	return half(min(sum * (1.0 / 16.0), 60000.0));
}

// 2 and 3: a separable 9-tap Gaussian (sigma ~ 1.75 taps), taps hp.z quarter-resolution texels apart (bilinear between them),
// within the live part.
static inline half vlVeilBlur(float2 pos, float2 axis, constant VlParams &p, texture2d<half> src) {
	constexpr sampler lin(filter::linear, address::clamp_to_edge);
	float2 vs = float2(src.get_width(), src.get_height());
	float2 lo = float2(0.5), hi = ceil(p.size.xy * 0.25) - 0.5;
	const float w[5] = {0.2270270, 0.1945946, 0.1216216, 0.0540541, 0.0162162};
	float sum = w[0] * float(src.sample(lin, pos / vs).r);
	for (int k = 1; k < 5; k++) {
		float2 o = axis * (float(k) * p.hp.z);
		sum += w[k] * (float(src.sample(lin, clamp(pos + o, lo, hi) / vs).r) + float(src.sample(lin, clamp(pos - o, lo, hi) / vs).r));
	}
	return half(sum);
}
fragment half vl_veil_blur_h(VlOut in [[stage_in]], constant VlParams &p [[buffer(0)]], texture2d<half> src [[texture(0)]]) {
	return vlVeilBlur(in.position.xy, float2(1.0, 0.0), p, src);
}
fragment half vl_veil_blur_v(VlOut in [[stage_in]], constant VlParams &p [[buffer(0)]], texture2d<half> src [[texture(0)]]) {
	return vlVeilBlur(in.position.xy, float2(0.0, 1.0), p, src);
}

// ---- composite ------------------------------------------------------------------------------------------------------------
// Full resolution, so everything here is half precision (twice the ALU rate on Apple GPUs) and transcendental-light.
// Exposed radiance -> sRGB: the hue-preserving part of M1's output curve (shade_common.metal shadeOutput, without the night
// shift and without its per-channel blend toward white above 0.6: the composite only adds the *difference* of two of these,
// so the pixel keeps M1's exact value and only the added light is shaped by this simpler curve; 0.2 ms less at native).
static inline half3 vlForward(half3 c) {
	half m = max(max(c.r, c.g), max(c.b, 1e-4h));
	half y = 1.0h - exp2(-1.5869637h * m);
	half tm = y * y * 1.006h / (y + 0.006h);
	return shadeToSrgb(saturate(c * (tm / m)));
}

// sRGB -> exposed radiance: the inverse of the hue-preserving part of vlForward (the brightest channel through the inverse
// curve, the others keep their ratio). Approximate near white, where the per-channel blend starts; the composite only uses
// it through a difference of two forward curves, which cancels the error where little light is added.
static inline half3 vlInverse(half3 s) {
	half3 lin = shadeToLinear(s);
	half m = max(max(lin.r, lin.g), max(lin.b, 1e-4h));
	// y^2 * 1.006 / (y + 0.006) = m  ->  y = (m + sqrt(m^2 + 4 * 1.006 * 0.006 m)) / (2 * 1.006)
	half y = min((m + sqrt(m * m + 0.024144h * m)) * 0.4970179h, 0.996h);
	half x = -log2(1.0h - y) * 0.6301338h;
	return lin * (x / m);
}

// Depth-aware upsample of the VL history to full-res pixel pos (distance dist): bilinear x depth similarity (a cheap
// rational falloff instead of exp).
static inline half3 vlUpsample(texture2d<half> vl, float2 pos, float dist, constant VlParams &p) {
	float2 lp = pos * (p.size.xy / p.size.zw) - 0.5;
	float2 fl = floor(lp);
	half2 fr = half2(lp - fl);
	int2 base = int2(fl), hi = int2(p.size.xy) - 1;
	// Keep depth math in float. At a near leaf against the sky, diff / tolerance exceeds half's range when cubed;
	// its weight must become zero, never poison the weighted sum with Inf/NaN (issue #19).
	float tolerance = 0.04 * dist + 0.15;
	float hd = min(dist, 3e4);
	half3 sum = 0.0h, bestC = 0.0h;
	float wsum = 0.0, best = 6e4, bestD = 1.0;
	for (int j = 0; j <= 1; j++) {
		for (int i = 0; i <= 1; i++) {
			half4 s = vl.read(uint2(clamp(base + int2(i, j), int2(0), hi)));
			half bw = (i == 0 ? 1.0h - fr.x : fr.x) * (j == 0 ? 1.0h - fr.y : fr.y) + 1e-3h;
			float diff = abs(float(s.a) - hd);
			float x = min(diff / tolerance, 128.0);
			float w = float(bw) / (1.0 + x * x * (1.0 + x));
			sum += s.rgb * half(w);
			wsum += w;
			if (diff < best) {
				best = diff;
				bestC = s.rgb;
				bestD = s.a;
			}
		}
	}
	if (wsum > 0.02) return sum / half(wsum);
	// A sub-resolution sky gap can have four foreground leaves in its bilinear footprint. Reusing their light gives a
	// leaf-sized orange rectangle in the sky. Search only at these discontinuities, with a strict depth test. Farther
	// samples have a spatial penalty; they must never bridge a wall/leaf to the sky. This costs nothing on smooth surfaces.
	const int2 probes[4] = {int2(-1, 0), int2(2, 1), int2(0, 2), int2(1, -1)};
	for (int k = 0; k < 4; k++) {
		half4 s = vl.read(uint2(clamp(base + probes[k], int2(0), hi)));
		if (abs(float(s.a) - hd) < tolerance) return s.rgb;
	}
	// No background observation is safer than inventing distant light from an occluding leaf. Foreground sub-pixel geometry still
	// uses the length-limited fallback, preserving the old anti-halo treatment without spreading foreground shafts.
	if (hd > bestD + tolerance) return half3(0.0h);
	// no low-res sample at this depth (a thin leaf against the sky): the closest one, scaled by how much air this pixel's
	// ray actually crosses (in-scattering grows with the marched length) so foliage edges get no halo
	float maxD = p.shape.y;
	return bestC * half(saturate((min(hd, maxD) + 0.5) / (min(bestD, maxD) + 0.5)));
}

// The light added at full-resolution pixel px (pre-exposed: x exposure) and the canopy mist's transmittance T.
static inline half3 vlCompositeLight(float2 pos, float dist, float2 ndc, float exposure, constant ShadeFrame &f, constant VlParams &p,
                                     constant VlState &st, texture2d<half> vl, thread half &T) {
	half3 light = max(vlUpsample(vl, pos, dist, p), 0.0h) * half(exposure); // (the sky's negative streaks are for the fold only)
	// the canopy mist dims what is behind it (full resolution, analytic: crisp at every edge) toward its sky-lit colour;
	// the sun-lit part of it is in the march
	T = 1.0h;
	float canopy = p.gate.z >= 0.0 ? p.gate.z : max(st.canopy.x, p.tune.x);
	float mistK = p.light.w * canopy * p.mist.w * p.mist.z;
	if (mistK > 1e-5 && p.water2.y < 0.5) {
		T = half(exp2(-1.442695 * mistK * vlMistDepth(vlDirection(ndc, f), min(dist, p.shape.y), p)));
		light += half3(p.mistAmb.rgb * exposure) * (1.0h - T);
	}
	return light;
}

// M1 (LDR main target, programmable blending): the light added before M1's output curve, exposure ShadeFrame.time.z.
fragment half4 vl_composite(VlOut in [[stage_in]], half4 dst [[color(0)]], constant ShadeFrame &f [[buffer(16)]],
                             constant VlParams &p [[buffer(0)]], constant VlState &st [[buffer(1)]], texture2d<half> vl [[texture(0)]],
                             depth2d<float> depth [[texture(1)]]) {
	uint2 px = uint2(in.position.xy);
	float2 ndc = in.position.xy / p.size.zw * 2.0 - 1.0;
	float dist = vlDistance(ndc, depth.read(px), f);
	half T;
	half3 light = vlCompositeLight(in.position.xy, dist, ndc, f.time.z, f, p, st, vl, T);
	if (p.gate.w == 1.0) return half4(vlForward(light), 1.0h);   // debug: the light alone
	if (p.gate.w == 2.0) return half4(half3(saturate(dist / p.shape.y)), 1.0h); // debug: marched distance
	if (p.gate.w == 3.0) return half4(half3(T), 1.0h);                 // debug: canopy mist transmittance
	// below ~half an 8-bit step anywhere on the curve: leave the pixel alone (open plains at noon: most of the screen)
	if (max(light.r, max(light.g, light.b)) < half(1.0 / 1024.0) && T > 0.999h) return dst;
	half3 e = vlInverse(dst.rgb);
	half3 o = dst.rgb + (vlForward(e * T + light) - vlForward(e));
	// dither (triangular, +-1 LSB) so smooth shafts don't band in 8 bits
	float n0 = vlNoise(in.position.xy, p.temporal.z), n1 = vlNoise(in.position.xy + 17.0, p.temporal.z + 3.0);
	o += half(n0 + n1 - 1.0) * (1.0h / 255.0h);
	return half4(saturate(o), dst.a);
}

// M2 (HDR world target, before bloom and the tone map): returns (light, T) for the fixed-function blend
// src * One + dst * SourceAlpha = scene * T + light, in pre-exposed radiance (ShadeGpu.exposure.x). No read of the target
// (RG11B10F or RGBA16F), so no programmable-blending dependency: a plain full-resolution blend.
fragment half4 vl_composite_hdr(VlOut in [[stage_in]], constant ShadeFrame &f [[buffer(16)]], constant ShadeGpu &g [[buffer(18)]],
                                 constant VlParams &p [[buffer(0)]], constant VlState &st [[buffer(1)]], texture2d<half> vl [[texture(0)]],
                                 depth2d<float> depth [[texture(1)]]) {
	uint2 px = uint2(in.position.xy);
	float2 ndc = in.position.xy / p.size.zw * 2.0 - 1.0;
	float dist = vlDistance(ndc, depth.read(px), f);
	half T;
	half3 light = vlCompositeLight(in.position.xy, dist, ndc, g.exposure.x, f, p, st, vl, T);
	if (p.gate.w == 1.0) return half4(light, 0.0h);                                    // debug: the light alone
	if (p.gate.w == 2.0) return half4(half3(saturate(dist / p.shape.y) * 0.5), 0.0h);  // debug: marched distance
	if (p.gate.w == 3.0) return half4(half3(T * 0.5h), 0.0h);                          // debug: canopy mist transmittance
	return half4(min(light, half3(30000.0h)), T);
}

#endif
