// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// Catmull-Rom history sampling (taaCatmullRom) after Matt Pettineo (MJP), "Bicubic texture filtering with the Catmull-Rom
// spline in 9 / 5 taps" (https://gist.github.com/TheRealMJP/c83b8c0f46b63f3a88a5986f4fa982b1), MIT License; the 5-tap
// variant (corners dropped and renormalised) follows Jimenez, "Filmic SMAA", SIGGRAPH 2016. Everything else here is
// original, built from public techniques: Karis 2014 (YCoCg neighbourhood rectification, luma-weighted resolve), Salvi 2016
// (variance clipping), Yang et al. 2020 (confidence-weighted temporal upsampling).
//
// mcopt native shading: temporal anti-aliasing and upscaling (TAAU, shader bible E18), compiled natively by mctaa.m.
//
// taau_fs runs once per OUTPUT pixel (native resolution) as a fragment pass into two compressible targets:
//   color(0) RGBA16Float: the resolved colour (rgb, in the input's encoding) and the pixel's history age in frames (a);
//   color(1) R16Float:    linear view depth (clip w, blocks) of the nearest input sample, for next frame's disocclusion test.
// Both are ping-ponged by mctaa.m: next frame reads them as `hist` / `histDepth`.
// taa_output_fs then copies the resolve into the game's main target with a contrast-limited sharpen.
//
// Conventions (same as every mcopt target): rows are in GL order (texture row 0 = bottom of the picture), so a pixel
// centre (x + 0.5, row + 0.5) of a W x H target is NDC ((x + 0.5) / W * 2 - 1, (row + 0.5) / H * 2 - 1) and Metal
// texture coordinates need no flip. Depth is reversed Z in [0, 1] (0 = far plane / sky).
//
// The INPUT is the jittered world render: a viewport sub-rect (0, 0, input.xy) of textures that may be larger (dynamic
// resolution renders into fixed-size targets). The scene is drawn shifted by `jitter.xy` input pixels (the projection's
// sub-pixel offset, Halton 2,3), so the input pixel centred at c + 0.5 shows the unjittered scene point c + 0.5 - jitter,
// and output pixel centre q maps to unjittered input position q * ratio.
#include <metal_stdlib>
using namespace metal;

struct TaaParams {
	float4x4 invCur;  //   0  this frame's unjittered clip -> camera-relative world
	float4x4 prevVP;  //  64  camera-relative world (this frame's camera) -> last frame's unjittered clip
	float4 curRowW;   // 128  4th row of this frame's unjittered viewProj (clip w = linear view depth, blocks)
	float4 input;     // 144  xy active input size (px), z flicker hold (0 off), w its sensitivity
	float4 output;    // 160  xy output size (px), zw 1 / output size
	float4 jitter;    // 176  xy this frame's jitter (input px), zw input px per output px (input.xy / output.xy)
	float4 blend;     // 192  x minimum blend weight of the current frame, y clip box size (sigmas), z history age cap, w 1 = no history
	float4 misc;      // 208  x history rescale (exposure now / then; M2 reads ShadeGpu.exposure at buffer(1) instead), y where the clip boost starts (box units, <= 1: 1), z reactive strength, w debug view (taau_debug_fs)
	float4 sharpen;   // 224  x strength (0 off), y current-frame weight floor in motion (full at 0.5 px/frame), z anti-flicker (0 off), w motion floor only off-centre (0 off)
	float4x4 reproj;  // 240  (FT2.8, audit idx 64) prevVP x invCur: this frame's unjittered clip -> last frame's, times h.w
	// (1.2.7 candidate 7) swaying leaves: the leaves' wobble phases this frame and last (ShadeFoliage, own/terrain.metal ownSway),
	// and xyz the camera's absolute position modulo 1024 (the wobble's wrap), w 1 = follow them (mcopt.shade.taa.leafMotion)
	float4 leafNow;   // 304
	float4 leafPrev;  // 320
	float4 leafCam;   // 336
};

// (1.2.7 candidate 7) The leaves' and vines' wobble at absolute (mod 1024) position a for phases ph, times amplitude A: own/terrain.metal
// ownSway's leaves branch, KEEP IN SYNC. The terrain's cutout pass writes 2 + A into the scene's alpha where a waving leaf is drawn.
static inline float3 taaLeafSway(float3 a, float4 ph, float A) {
	const float K = 6.2831853 / 32.0;
	float3 d;
	d.x = sin(ph.x + dot(a, K * float3(3, 2, 5))) + 0.5 * sin(ph.y + dot(a, K * float3(-7, 4, 3)));
	d.y = 0.5 * sin(ph.z + dot(a, K * float3(5, -3, 2)));
	d.z = sin(ph.y + dot(a, K * float3(-2, 5, 4))) + 0.5 * sin(ph.w + dot(a, K * float3(6, 3, -5)));
	return d * A;
}

// M3 per-object motion (bible E18 step 4, original, cheap): the entities that moved since last frame (ShadeMotion, at most
// TAA_MOVERS), as camera-relative world boxes at this frame's render position plus their render-position change this frame.
// A pixel whose reconstructed surface lies in a box is reprojected from (world - delta) instead of world: no render target,
// no change to the world passes; only translation (limb swing and turning stay with the rectification).
#define TAA_MOVERS 32
struct TaaMovers {
	uint4 count;                 // x movers
	float4 box[TAA_MOVERS * 3];  // per mover: min.xyz, max.xyz, delta.xyz (blocks, now - last frame)
};

static inline float3 taaMoverDelta(float3 world, constant TaaMovers &mv) {
	uint n = min(mv.count.x, uint(TAA_MOVERS));
	for (uint i = 0; i < n; i++) {
		float3 lo = mv.box[i * 3].xyz, hi = mv.box[i * 3 + 1].xyz;
		if (all(world >= lo) && all(world <= hi)) return mv.box[i * 3 + 2].xyz;
	}
	return float3(0.0);
}

// (1.1.1) Inf or NaN, by the bit pattern: under fast math (mctaa.m) the compiler may fold isfinite() to true, and a bad
// pixel kept in the history spreads into a growing black or white block.
static inline bool taaBad(half4 v) { return any((as_type<ushort4>(v) & ushort4(0x7c00)) == ushort4(0x7c00)); }
static inline bool taaBad(float3 v) { return any((as_type<uint3>(v) & uint3(0x7f800000)) == uint3(0x7f800000)); }

struct TaaVOut { float4 position [[position]]; };

// One triangle covering the target.
vertex TaaVOut taa_vs(uint id [[vertex_id]]) {
	float2 p = float2((id << 1) & 2, id & 2);
	TaaVOut o;
	o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
	return o;
}

// ---- colour space ---------------------------------------------------------------------------------------------------
// TAA_HDR (function constant 0, set by mctaa.m): the input is linear HDR (M2's pre-exposed scene), so samples blend in a
// range-compressed space (c / (1 + luma), Karis 2014) where one very bright sample can't dominate a neighbourhood and
// flicker; reversible. Off (M1's tonemapped RGBA8 input), colours are already bounded and blend as they are.
constant bool TAA_HDR [[function_constant(0)]];
constant bool taaHdr = is_function_constant_defined(TAA_HDR) && TAA_HDR;
// (FT2.8, audit idx 63) function constant 1 false: the resolve without the M3 movers code (mctaa.m binds it on frames with no
// mover: -0.025 ms at Retina 0.8, taatest perf TAAHDR=1); unset: with it
constant bool TAA_MOVERS_ON [[function_constant(1)]];
constant bool taaMoversOn = !is_function_constant_defined(TAA_MOVERS_ON) || TAA_MOVERS_ON;
static inline half3 taaCompress(half3 c) {
	return taaHdr ? c / (1.0h + dot(c, half3(0.2126h, 0.7152h, 0.0722h))) : c;
}
static inline float3 taaExpand(float3 c) {
	return taaHdr ? c / max(1.0 - dot(c, float3(0.2126, 0.7152, 0.0722)), 1e-4) : c;
}

// ---- history fetch: Catmull-Rom in 5 bilinear taps (MJP, MIT; see the header) ------------------------------------------
// Positions in float (they span the whole output), weights and colours in half (this pass is bound by ALU and latency, not
// bandwidth: tools/shade/taatest perf). centreA: the alpha of the centre tap, i.e. the bilinear history age, so the age
// needs no fetch of its own.
// (FT2.8, audit idx 69) Each tap rescaled and range-compressed before the weights (with TAA_HDR; Karis 2014), so the result is
// in the resolve's compressed space: on linear HDR the spline's negative outer lobes rang 1-2 px outside the sun disc and water
// glints (more than ~15x their surroundings) whenever the camera moved, below 0 per channel (dark or hue-shifted rings, fed
// back at 0.8-0.9). Only with -Dmcopt.shade.taaCompressTaps=true (else TAA_LINEAR_HISTORY, the default: FT2.7's linear filter, then compress;
// the motion shots showed no ring to remove).
// (+0.035 ms at Retina 0.8, taatest perf TAAHDR=1; a live switch between the two cost +0.1 ms: two inlined filters)
// (1.2.4, GitHub issue #8) the linear filter's taps at most 16384: the spline sums in half, and around a sun pre-exposed near
// half's 65504 (the exposure still high from a dark view) its centre weights (up to ~1.2) overflowed to Inf, then NaN, and the
// resolve stored the pixel black (max(NaN, 0) = 0) until the exposure came down: black dots in the sun, plain in XDR. 16384 is
// far past what the display shows (the tone curve and the XDR peak top out ~100 pre-exposed)
static inline half3 taaTap(half3 c, float rescale, bool comp) {
	if (!comp) return min(c, half3(16384.0h));
	float3 x = float3(c) * rescale;
	return half3(x / (1.0 + dot(x, float3(0.2126, 0.7152, 0.0722))));
}
static inline half3 taaCatmullRom(texture2d<half> tex, sampler s, float2 uv, float2 size, float2 invSize, thread half &centreA,
                                  float rescale = 1.0, bool comp = false) {
	float2 pos = uv * size;
	float2 t1 = floor(pos - 0.5) + 0.5;     // centre of the texel at grid index 1
	half2 f = half2(pos - t1);
	half2 w0 = f * (-0.5h + f * (1.0h - 0.5h * f));
	half2 w1 = 1.0h + f * f * (-2.5h + 1.5h * f);
	half2 w2 = f * (0.5h + f * (2.0h - 1.5h * f));
	half2 w3 = f * f * (-0.5h + 0.5h * f);
	half2 w12 = w1 + w2;
	float2 t0 = (t1 - 1.0) * invSize, t3 = (t1 + 2.0) * invSize, t12 = (t1 + float2(w2 / w12)) * invSize;
	half4 cc = tex.sample(s, t12);
	centreA = cc.a;
	half3 c = taaTap(tex.sample(s, float2(t12.x, t0.y)).rgb, rescale, comp) * (w12.x * w0.y)
		+ taaTap(tex.sample(s, float2(t0.x, t12.y)).rgb, rescale, comp) * (w0.x * w12.y)
		+ taaTap(cc.rgb, rescale, comp) * (w12.x * w12.y)
		+ taaTap(tex.sample(s, float2(t3.x, t12.y)).rgb, rescale, comp) * (w3.x * w12.y)
		+ taaTap(tex.sample(s, float2(t12.x, t3.y)).rgb, rescale, comp) * (w12.x * w3.y);
	// (2.0.1 opt) exact identity since w0 + w12 + w3 == 1: wsum = w12.x + w12.y - w12.x * w12.y
	half wsum = w12.x + w12.y - w12.x * w12.y;
	return max(c / wsum, 0.0h); // the spline's negative lobes can ring below 0 at hard edges
}

static inline bool taaSameLayer(float a, float b) {
	bool sa = a > 60000.0, sb = b > 60000.0;
	if (sa || sb) return sa == sb;
	return abs(a - b) <= 0.15 * min(a, b) + 0.5;
}

struct TaaOut {
	half4 color [[color(0)]];
	// (2.0.1c) RGBA16Float: r = nearest view depth (blocks, 65000 = sky; unchanged for disocclusion & water SSR),
	// g = temporally resolved near-layer coverage [0,1], b = near-layer view depth, a = far-layer view depth
	half4 depth [[color(1)]];
};

// The resolve of output pixel centre q; debug (mcopt.shade.taaDebug views) gets the colour to show instead, so the
// history itself is never polluted by a debug view.
static inline TaaOut taauResolve(float2 q, constant TaaParams &p, constant float4 &exposure, constant TaaMovers &movers, texture2d<half> cur,
                                 depth2d<float> curDepth, texture2d<half> hist, texture2d<half> histDepth, texture2d<half> reactive, thread half3 &debug)
{
	// history rescale (exposure now / when the history was made): M2 binds ShadeGpu.exposure here (x now, z last frame's),
	// M1 and the headless test (misc.x, -, 1, -)
	half rescale = exposure.x > 0.0 && exposure.z > 0.0 ? half(clamp(exposure.x / exposure.z, 0.25, 4.0)) : 1.0h;
	constexpr sampler linear(filter::linear, address::clamp_to_edge);
	float2 pin = q * p.jitter.zw + p.jitter.xy;        // that scene point in the jittered input raster (pixel units)
	int2 last = int2(p.input.xy) - 1;
	int2 base = clamp(int2(floor(pin)), int2(1), last - 1); // the 3x3 stays inside the live sub-rect (the rest is stale)

	// (2.0.1 opt) issue depth gather BEFORE 3x3 colour loop so its latency hides behind the 9 reads AND we capture the
	// nearest corner's alpha (la) directly inside the 3x3 loop, eliminating 5.9M redundant cur.gather(..., component::w) calls
	constexpr sampler point(filter::nearest, address::clamp_to_edge);
	float4 z4 = curDepth.gather(point, pin / float2(curDepth.get_width(), curDepth.get_height()));
	float zmax = max(max(z4.x, z4.y), max(z4.z, z4.w));

	// The 3x3 input neighbourhood: a reconstruction of this frame's colour at q (separable Gaussian fit of Blackman-Harris)
	half2 off = half2(float2(base) + 0.5 - pin);        // offset of the base texel's centre from pin, in (-1, 0] (wider at the edges)
	half3 ox = half3(off.x - 1.0h, off.x, off.x + 1.0h), oy = half3(off.y - 1.0h, off.y, off.y + 1.0h);
	half3 wx = exp2(-3.30377h * ox * ox), wy = exp2(-3.30377h * oy * oy);
	half3 sum = 0.0h, m1 = 0.0h, m2 = 0.0h;
	uint leafCount = 0u;
	constexpr sampler texel(coord::pixel, filter::nearest, address::clamp_to_edge);
	float2 centre = float2(base) + 0.5;
	for (int dy = 0; dy < 3; dy++) {
		half3 row = 0.0h;
		for (int dx = 0; dx < 3; dx++) { // immediate texel offsets: no address maths per tap
			// (1.2.4, issue #8) an Inf from a shader's own maths would compress to NaN: at most 60000 (NaN: 0, outweighed by its neighbours)
			half4 s = cur.sample(texel, centre, int2(dx - 1, dy - 1));
			leafCount += uint(s.a > 1.5h);
			half3 c = taaCompress(clamp(s.rgb, 0.0h, 60000.0h));
			row += c * wx[dx];
			m1 += c;
			m2 += c * c;
		}
		sum += row * wy[dy];
	}
	if (p.leafCam.w <= 0.5) leafCount = 0u;
	half wsum = (wx.x + wx.y + wx.z) * (wy.x + wy.y + wy.z);
	half wnear = max3(wx.x, wx.y, wx.z) * max3(wy.x, wy.y, wy.z);
	half3 current = sum / wsum;
	half3 mean = m1 * (1.0h / 9.0h);
	half3 sigma = sqrt(max(m2 * (1.0h / 9.0h) - mean * mean, 0.0h));

	// Camera motion from depth: this pixel's (nearest) surface in last frame's clip space
	float2 ndc = q * p.output.zw * 2.0 - 1.0;
	float4 v4 = float4(ndc, zmax, 1.0);
	float4 invWRow = float4(p.invCur[0].w, p.invCur[1].w, p.invCur[2].w, p.invCur[3].w);
	float iw = 1.0 / dot(invWRow, v4);
	float viewDepth = iw;
	float3 moved = float3(0.0);
	// (2.0.1 opt) skip cur.read entirely on non-leaf pixels (leafCount == 0u covers ~90% of the screen!)
	half la = 0.0h;
	if (leafCount > 0u && zmax > 0.0) {
		int dx0 = off.x > 0.0h ? -1 : 0, dx1 = dx0 + 1;
		int dy0 = off.y > 0.0h ? -1 : 0, dy1 = dy0 + 1;
		int2 pick = z4.x == zmax ? int2(dx0, dy1) : z4.y == zmax ? int2(dx1, dy1) : z4.z == zmax ? int2(dx1, dy0) : int2(dx0, dy0);
		la = cur.read(uint2(base + pick)).a;
	}
	bool leafMoved = la > 1.5h;
	// (2.0.1c) camStill covers both blend.w == -1 (0 movers) and -2 (movers present, e.g. villagers/mobs): outside mover
	// boxes, static pixels still use 1-read exact identity reprojection and avoid Halton-jittered depth disocclusion strobing
	bool camStill = p.blend.w < -0.5 && p.misc.w < 0.5;
	bool hasMovers = taaMoversOn && movers.count.x > 0u && zmax > 0.0;
	if (camStill && !leafMoved && hasMovers) {
		moved = taaMoverDelta((p.invCur * v4).xyz * iw, movers);
	}
	bool stillPx = camStill && !leafMoved && all(moved == float3(0.0));
	float4 prev;
	float2 uvPrev;
	if (stillPx) {
		prev = float4(ndc * iw, 0.0, iw);
		uvPrev = q * p.output.zw;
	} else {
		prev = (p.reproj * v4) * iw;
		if (hasMovers) {
			if (!camStill || leafMoved) moved = taaMoverDelta((p.invCur * v4).xyz * iw, movers);
			prev -= p.prevVP * float4(moved, 0.0);
		}
		if (leafMoved) {
			float A = float(la) - 2.0;
			float3 w = (p.invCur * v4).xyz * iw;
			float3 a = w + p.leafCam.xyz;
			float3 leafDelta = taaLeafSway(a, p.leafNow, A) - taaLeafSway(a, p.leafPrev, A);
			prev -= p.prevVP * float4(leafDelta, 0.0);
		}
		uvPrev = prev.xy / prev.w * 0.5 + 0.5;
	}

	TaaOut o;
	bool skyNow = zmax <= 0.0;
	float vdNear = skyNow ? 65000.0 : clamp(viewDepth, 0.01, 60000.0);
	float zmin = min(min(z4.x, z4.y), min(z4.z, z4.w));
	bool valid = p.blend.w < 0.5 && prev.w > 0.0 && all(uvPrev > 0.0) && all(uvPrev < 1.0);
	half age = 0.0h;
	half3 history = current;
	half disocclusion = 0.0h;
	o.depth = half4(half(vdNear), 1.0h, half(vdNear), half(vdNear));
	if (valid) {
		uint2 hp = stillPx ? uint2(q) : uint2(min(uvPrev * p.output.xy, p.output.xy - 1.0));
		half4 pd = histDepth.read(hp);
		// (2.0.1c anti-flicker) on stillPx (still camera, outside mover boxes, non-swaying surface), depth jumps across
		// static silhouettes come from Halton(2,3) jitter flipping zmax (especially on RG11B10F balanced/performance where
		// leafCount is unavailable); color variance clipping handles real block edits cleanly, so keep disocclusion = 0.
		if (!stillPx) {
			float stored = float(pd.r);
			bool skyThen = stored > 60000.0;
			float tolerance = 0.03 * prev.w + 0.1;
			disocclusion = skyNow || skyThen ? half(skyNow != skyThen) : half(saturate((abs(stored - prev.w) - tolerance) / tolerance));
			// In motion (panning, walking), when z4 straddles a silhouette with low relative parallax (<1.5 output px, e.g.
			// rotation or distant hills/horizon/leaves) and stored matches the far layer zmin, Halton jitter flipped zmax
			// across the edge rather than exposing a true disocclusion — keep history (still variance-clamped!).
			if (disocclusion > 0.0h && ((zmin <= 0.0 && zmax > 0.0) || (zmin > 0.0 && zmax > zmin * 1.15))) {
				float4 vFar = float4(ndc, zmin, 1.0);
				float iwFar = 1.0 / dot(invWRow, vFar);
				float4 prevFar = (p.reproj * vFar) * iwFar;
				float2 uvPrevFar = prevFar.xy / max(prevFar.w, 1e-4) * 0.5 + 0.5;
				float2 parallax = (uvPrevFar - uvPrev) * p.output.xy;
				if (dot(parallax, parallax) < 2.25) {
					bool farMatch = (zmin <= 0.0) ? skyThen : (!skyThen && abs(stored - prevFar.w) < 0.05 * prevFar.w + 0.15);
					if (farMatch) disocclusion = 0.0h;
				}
			}
			// Swaying alpha-cutout leaves (RGBA16F): preserve enclosed canopy-hole history under sway
			if (disocclusion > 0.0h && skyNow != skyThen && leafCount > 0u) {
				if (camStill) {
					if (leafCount >= 3u) {
						disocclusion = 0.0h;
					} else if (skyNow || zmin <= 0.0) {
						disocclusion = 0.0h;
					}
				} else if (leafCount >= 3u) {
					disocclusion = min(disocclusion, 0.15h);
				}
			}
		}
		// (2.0.1c) Temporally resolved 2-layer depth computed here so all depth temporaries die BEFORE Catmull-Rom (no register spill!)
		bool isEdgeNow = !skyNow && (zmin <= 0.0 || zmax > zmin * 1.25);
		float pN = float(pd.b), pF = float(pd.a);
		bool pTwo = pF > pN * 1.22 + 0.5;
		if (isEdgeNow || pTwo || (disocclusion < 0.5h && !taaSameLayer(vdNear, pN))) {
			float cN = vdNear, cF = vdNear, cCen = vdNear;
			half curW = 1.0h;
			if (isEdgeNow) {
				cF = zmin <= 0.0 ? 65000.0 : clamp(1.0 / dot(invWRow, float4(ndc, zmin, 1.0)), 0.01, 60000.0);
				float2 fg = fract(pin - 0.5);
				float zCen = fg.y >= 0.5 ? (fg.x >= 0.5 ? z4.y : z4.x) : (fg.x >= 0.5 ? z4.z : z4.w);
				float zSplit = zmin <= 0.0 ? 0.0 : sqrt(zmin * zmax);
				bool cenIsNear = zCen > zSplit;
				curW = cenIsNear ? 1.0h : 0.0h;
				cCen = cenIsNear ? cN : cF;
			}
			float outN = cN, outF = cF;
			half outW = curW;
			if (disocclusion < 0.5h) {
				half pW = pd.g;
				half covA = stillPx ? 0.07h : 0.30h;
				if (pTwo) {
					bool mN = taaSameLayer(cCen, pN);
					bool mF = !mN && taaSameLayer(cCen, pF);
					if (mN || mF) {
						outW = mix(pW, mN ? 1.0h : 0.0h, covA);
						outN = mN ? mix(pN, cCen, 0.25) : pN;
						outF = mF ? (pF > 60000.0 ? 65000.0 : mix(pF, cCen, 0.25)) : pF;
						if (isEdgeNow) {
							if (taaSameLayer(cN, outN)) outN = mix(outN, cN, 0.25);
							if (taaSameLayer(cF, outF)) outF = cF > 60000.0 ? 65000.0 : mix(outF, cF, 0.25);
						}
						if (outW > 0.985h) { outF = outN; outW = 1.0h; }
						else if (outW < 0.015h) { outN = outF; outW = 1.0h; }
					}
				} else if (isEdgeNow) {
					if (taaSameLayer(pN, cN)) {
						outN = mix(pN, cN, 0.25); outF = cF; outW = mix(1.0h, curW, covA);
					} else if (taaSameLayer(pN, cF)) {
						outN = cN; outF = cF > 60000.0 ? 65000.0 : mix(pN, cF, 0.25); outW = mix(0.0h, curW, covA);
					}
				} else {
					if (cN < pN) { outN = cN; outF = pN; outW = covA; }
					else { outN = pN; outF = cN; outW = 1.0h - covA; }
				}
			}
			o.depth = half4(half(vdNear), outW, half(outN), half(outF));
		}
		// (2.0.1 opt) skip 5-tap Catmull-Rom on full disocclusion, use exact 1-read on still pixels, and use 1 bilinear tap
		// on flat low-variance gradients (sky, smooth clouds, calm ocean) where bilinear and Catmull-Rom are mathematically equal
		if (disocclusion < 1.0h || p.misc.w >= 0.5) {
			if (stillPx) {
				half4 hc0 = hist.read(hp);
				age = hc0.a;
#ifndef TAA_LINEAR_HISTORY
				history = taaTap(hc0.rgb, float(rescale), taaHdr);
#else
				history = taaCompress(min(min(hc0.rgb, half3(16384.0h)) * rescale, half3(60000.0h)));
#endif
			} else if (max3(sigma.x, sigma.y, sigma.z) < max(0.003h, max3(mean.x, mean.y, mean.z) * 0.01h)) {
				half4 hc0 = hist.sample(linear, uvPrev);
				age = hc0.a;
#ifndef TAA_LINEAR_HISTORY
				history = taaTap(hc0.rgb, float(rescale), taaHdr);
#else
				history = taaCompress(min(min(hc0.rgb, half3(16384.0h)) * rescale, half3(60000.0h)));
#endif
			} else {
#ifndef TAA_LINEAR_HISTORY
				history = taaCatmullRom(hist, linear, uvPrev, p.output.xy, p.output.zw, age, float(rescale), taaHdr);
#else
				history = taaCompress(min(taaCatmullRom(hist, linear, uvPrev, p.output.xy, p.output.zw, age) * rescale, half3(60000.0h)));
#endif
			}
		}
	}
	// Rectify: the history may only take colours this frame's neighbourhood could produce (variance box). It is clipped
	// toward the mean along the line between them, which (unlike a per-channel clamp) keeps the history's hue; outside = how
	// far outside the box it was, in box units. A still camera allows a wider box (p.blend.y is set wider by the CPU), which
	// keeps thin detail stable.
	half3 extent = half(p.blend.y) * sigma + 0.002h;
	half3 v = history - mean;
	half3 a = abs(v) / extent;
	half outside = max3(a.x, a.y, a.z);
	half3 clipped = outside > 1.0h ? mean + v / outside : history;
	age *= 1.0h - disocclusion;
	// Blend weight of this frame: running average over the pixel's age, never below the minimum (responsiveness), scaled by
	// the confidence that an input sample actually landed near this output pixel (upscaling: output pixels between input
	// samples rely on the history), raised where the history had to be clipped hard (something changed: anti-ghosting)
	// and where the reactive mask says the input is not reprojectable (particles, animated translucents).
	half alpha = age < 0.5h ? 1.0h : max(1.0h / (age + 1.0h), half(p.blend.x)) * mix(0.35h, 1.0h, wnear);
	// (1.2.7 candidate 7) anti-flicker (Karis 2014, slide 43, as Blender EEVEE does it): a history near the edge of the box (or past
	// it) is where a pixel flips between being clipped and not, frame after frame: lean on the (clipped) history there instead of
	// the current frame. 1 at the box's centre, 0 at its edge, below 0 outside. Applied to the running average and the motion floor;
	// the clip boost below still lets a real change through. Gael 2026-11-06: water reflections and sunlit leaves shimmering.
	half kf = 1.0h;
	if (p.sharpen.z > 0.0) {
		const half3 L = half3(0.25h, 0.5h, 0.25h);
		half eL = max(dot(extent, L), 0.002h);
		half d = (eL - abs(dot(history - mean, L))) / eL;
		kf = mix(1.0h, saturate(4.0h * d + 0.1h), half(p.sharpen.z));
	}
	half hold = 1.0h;
	// (candidate 7) flicker hold (Photon MIT 26c2906e c4_taa_exposure get_flicker_reduction, adapted; Photon Shaders by Benjamin
	// Stott ("sixthsurge"), MIT License): an unclipped history well inside a wide box (a noisy, flickering neighbourhood: rippled
	// reflections, leaves) is kept rather than replaced; only the running average, not the motion floor or the clip boost.
	if (p.input.z > 0.0 && outside <= 1.0h) {
		half3 dc = max(extent - abs(history - mean), 0.0h);
		hold = 1.0h - half(p.input.z) * saturate(length(dc) * half(p.input.w));
	}
	alpha *= kf * hold;
	// (candidate 7) misc.y: where the boost starts. From 1 (the box's edge) it fired on every pixel that oscillates around the edge,
	// i.e. on the flicker itself; from 3 only on a real change (anti-ghosting).
	alpha = max(alpha, saturate((outside - half(max(p.misc.y, 1.0))) * 0.25h) * 0.5h);
	// Motion: every frame in motion resamples the history at a new sub-pixel offset. Catmull-Rom at a half-pixel offset
	// passes a 2.5 px period at 0.45, and fed back with a weight of 0.07 that leaves 0.12 of it: pixel-art detail melts
	// while strafing even though the reprojection is exact (taaDebug 4). A floor on the current frame's weight as soon as
	// the pixel moves (full at 0.5 px/frame) keeps it (0.2: 0.31 of a 2.5 px period, 0.9 of a 3 px one), trading a little
	// stability in motion, where shimmer is far less visible than smear.
	half floorW = 0.0h;
	if (!stillPx) {
		float motionPx = length(uvPrev * p.output.xy - q);
		floorW = half(saturate(motionPx * 2.0));
		if (p.sharpen.w > 0.0) {
			float2 px = 1.0 - abs(2.0 * fract(uvPrev * p.output.xy) - 1.0);
			floorW *= half(mix(1.0, 1.0 - sqrt(px.x * px.y), p.sharpen.w));
		}
	}
	alpha = max(alpha, half(p.sharpen.y) * floorW * kf);
	if (p.misc.z > 0.0 && alpha < 1.0h) alpha = max(alpha, reactive.read(uint2(clamp(base, int2(0), int2(reactive.get_width(), reactive.get_height()) - 1))).r * half(p.misc.z));
	half3 resolved = mix(clipped, current, saturate(alpha));
	float3 rgb = taaExpand(float3(resolved));
	half newAge = min(age + 1.0h, half(p.blend.z));
	o.color = half4(half3(max(rgb, 0.0)), newAge);
	// (FT2.8, audit idx 72) the fallback in the history's own (linear) encoding, not the range-compressed current
	// (1.1.1) tested by bits (fast math may drop isfinite), and black if the current frame is bad too (clamp may pass a NaN)
	// (1.2.4, issue #8) rgb tested too: max(NaN, 0) is 0 where NaN is kept (Precise math, IEEE), which stored a black pixel
	if (taaBad(o.color) || taaBad(rgb)) {
		o.color = half4(half3(clamp(taaExpand(float3(current)), 0.0, 60000.0)), 1.0h);
		if (taaBad(o.color)) o.color = half4(0.0h, 0.0h, 0.0h, 1.0h);
	}
	int view = int(p.misc.w);
	if (view == 5) debug = half3(saturate(abs(moved) * 4.0));                                                         // M3 movers: per-object motion
	else if (view == 1) debug = half3(mix(float3(1.0, 0.1, 0.0), float3(0.1, 1.0, 0.2), saturate(float(newAge) / p.blend.z)));   // history age
	else if (view == 2) debug = half3(saturate(float(outside) - 1.0), float(disocclusion), valid ? 0.0 : 1.0);           // rejection
	else if (view == 3) debug = half3(taaExpand(float3(current)));                                                       // no history
	else if (view == 4) debug = half3(taaExpand(float3(mix(history, current, 0.5h))));                                   // reprojection check: unclipped history over current (doubled edges = misaligned)
	else debug = o.color.rgb;
	return o;
}

fragment TaaOut taau_fs(TaaVOut in [[stage_in]], constant TaaParams &p [[buffer(0)]], constant float4 &exposure [[buffer(1)]],
                        constant TaaMovers &movers [[buffer(2)]],
                        texture2d<half> cur [[texture(0)]], depth2d<float> curDepth [[texture(1)]],
                        texture2d<half> hist [[texture(2)]], texture2d<half> histDepth [[texture(3)]],
                        texture2d<half> reactive [[texture(4)]])
{
	half3 debug;
	return taauResolve(in.position.xy, p, exposure, movers, cur, curDepth, hist, histDepth, reactive, debug);
}

// mcopt.shade.taaDebug: the same resolve, plus the debug view straight into the destination (no output pass).
struct TaaDebugOut {
	half4 color [[color(0)]];
	half4 depth [[color(1)]];
	half4 view [[color(2)]];
};

fragment TaaDebugOut taau_debug_fs(TaaVOut in [[stage_in]], constant TaaParams &p [[buffer(0)]], constant float4 &exposure [[buffer(1)]],
                                   constant TaaMovers &movers [[buffer(2)]],
                                   texture2d<half> cur [[texture(0)]], depth2d<float> curDepth [[texture(1)]],
                                   texture2d<half> hist [[texture(2)]], texture2d<half> histDepth [[texture(3)]],
                                   texture2d<half> reactive [[texture(4)]])
{
	half3 debug;
	TaaOut r = taauResolve(in.position.xy, p, exposure, movers, cur, curDepth, hist, histDepth, reactive, debug);
	TaaDebugOut o;
	o.color = r.color;
	o.depth = r.depth;
	o.view = half4(debug, 1.0h);
	return o;
}

// The resolved image -> the game's main target, with a contrast-limited sharpen (original): an unsharp mask from the
// 4-neighbour cross, weaker where the local contrast is already high, and clamped to the neighbourhood's range so it never
// overshoots into halos. Restores the crispness of pixel-art textures the temporal resolve softens.
fragment half4 taa_output_fs(TaaVOut in [[stage_in]], constant TaaParams &p [[buffer(0)]], texture2d<half> resolved [[texture(0)]])
{
	int2 c = int2(in.position.xy);
	int2 last = int2(p.output.xy) - 1;
	half3 m = resolved.read(uint2(c)).rgb;
	half amount = half(p.sharpen.x);
	if (amount <= 0.0h) return half4(m, 1.0h);
	half3 n = resolved.read(uint2(clamp(c + int2(0, 1), int2(0), last))).rgb;
	half3 s = resolved.read(uint2(clamp(c - int2(0, 1), int2(0), last))).rgb;
	half3 e = resolved.read(uint2(clamp(c + int2(1, 0), int2(0), last))).rgb;
	half3 w = resolved.read(uint2(clamp(c - int2(1, 0), int2(0), last))).rgb;
	half3 lo = min(m, min(min(n, s), min(e, w)));
	half3 hi = max(m, max(max(n, s), max(e, w)));
	half range = dot(hi - lo, half3(0.2126h, 0.7152h, 0.0722h)) / max(dot(hi, half3(0.2126h, 0.7152h, 0.0722h)), 0.05h);
	half k = amount * 2.0h * (1.0h - smoothstep(0.15h, 0.9h, range));
	half3 o = clamp(m + (m - (n + s + e + w) * 0.25h) * k, lo, hi);
	return half4(o, 1.0h);
}
