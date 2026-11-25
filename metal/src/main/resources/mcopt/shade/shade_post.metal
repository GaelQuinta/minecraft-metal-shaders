// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// M2 post passes (compiled once by mcshade.m after shade_look + shade_common + shade_m2; driven by
// mcopt.metal.shade.ShadePost). All full-screen work is fragment passes into compressible render targets (apple-gpu §0.2).
//   shade_fs_vs              full-screen triangle (uv = (pixel + 0.5) / size, GL row order: no flip)
//   shade_bloom_down0        HDR scene -> bloom level 0 (half size): 13-tap downsample with a Karis average (no fireflies)
//   shade_bloom_down         level i -> i + 1: 13-tap downsample (Jimenez 2014, "Next generation post processing in CoD:AW")
//   shade_bloom_up           U_i = w_i L_i + tent(U_i+1): the octave spectrum accumulated from the smallest level up
//   shade_final              bloom (energy-conserving lerp) + fog glow, Purkinje, vignette, vibrance, Shade Filmic, dither -> RGBA8 sRGB
//   shade_bridge_encode      HDR -> RGBA8 display values (what a mod drawing display-referred colours, e.g. Distant Horizons, sees)
//   shade_bridge_decode      RGBA8 -> HDR where that mod changed a pixel (programmable blending reads the HDR value)
//   shade_histogram          compute: log-luminance histogram of bloom level 2 into ShadeGpu
//   shade_exposure           compute (1 thread): metered exposure, bounded around the reference, adapted -> ShadeGpu.exposure
//   shade_milkyway_bake      the Milky Way texture (once)
// The bloom composite follows the idea of SE Natural Bloom & Dirty Lens (c) 2019 sonicether, MIT License: a lerp toward
// the blurred image instead of an additive threshold, with octave weights i^s and a fog-weighted extra; the code is ours.

struct ShadeFsOut { float4 position [[position]]; float2 uv; };

vertex ShadeFsOut shade_fs_vs(uint vid [[vertex_id]]) {
	ShadeFsOut o;
	float2 p = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);
	o.position = float4(p, 0.0, 1.0);
	o.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5); // Metal texture coordinates of the target pixel (same orientation as the source)
	return o;
}

constexpr sampler shadeLinearClamp(filter::linear, address::clamp_to_edge);

// 13 taps: a 4x4 box from 4 bilinear taps in the middle, and 4 overlapping 2x2 boxes at the corners and edges.
static inline half3 shadeDown13(texture2d<half> src, float2 uv, float2 texel, bool karis) {
	half3 a = src.sample(shadeLinearClamp, uv + texel * float2(-2, -2)).rgb;
	half3 b = src.sample(shadeLinearClamp, uv + texel * float2(0, -2)).rgb;
	half3 c = src.sample(shadeLinearClamp, uv + texel * float2(2, -2)).rgb;
	half3 d = src.sample(shadeLinearClamp, uv + texel * float2(-2, 0)).rgb;
	half3 e = src.sample(shadeLinearClamp, uv).rgb;
	half3 f = src.sample(shadeLinearClamp, uv + texel * float2(2, 0)).rgb;
	half3 g = src.sample(shadeLinearClamp, uv + texel * float2(-2, 2)).rgb;
	half3 h = src.sample(shadeLinearClamp, uv + texel * float2(0, 2)).rgb;
	half3 i = src.sample(shadeLinearClamp, uv + texel * float2(2, 2)).rgb;
	half3 j = src.sample(shadeLinearClamp, uv + texel * float2(-1, -1)).rgb;
	half3 k = src.sample(shadeLinearClamp, uv + texel * float2(1, -1)).rgb;
	half3 l = src.sample(shadeLinearClamp, uv + texel * float2(-1, 1)).rgb;
	half3 m = src.sample(shadeLinearClamp, uv + texel * float2(1, 1)).rgb;
	half3 g0 = (j + k + l + m) * 0.25h, g1 = (a + b + d + e) * 0.25h, g2 = (b + c + e + f) * 0.25h, g3 = (d + e + g + h) * 0.25h, g4 = (e + f + h + i) * 0.25h;
	if (!karis) return g0 * 0.5h + (g1 + g2 + g3 + g4) * 0.125h;
	half w0 = 1.0h / (1.0h + shadeLumaH(g0)), w1 = 1.0h / (1.0h + shadeLumaH(g1)), w2 = 1.0h / (1.0h + shadeLumaH(g2)),
	     w3 = 1.0h / (1.0h + shadeLumaH(g3)), w4 = 1.0h / (1.0h + shadeLumaH(g4));
	w0 *= 0.5h; w1 *= 0.125h; w2 *= 0.125h; w3 *= 0.125h; w4 *= 0.125h;
	return (g0 * w0 + g1 * w1 + g2 * w2 + g3 * w3 + g4 * w4) / (w0 + w1 + w2 + w3 + w4);
}

// The first level reads the full-resolution scene: 4 bilinear taps (a 4x4 texel box), each Karis-weighted 1 / (1 + luma) so
// a few very bright texels (the sun, specular sparkles) can't flicker the whole bloom; the 13-tap filter takes over below.
// p.xy: the part of src's uv range that holds the image (TAAU: the live sub-rect of the internal-resolution HDR world,
// whose stale border must not bleed in; 1, 1 otherwise). Level 0 itself is half the output size.
fragment half4 shade_bloom_down0(ShadeFsOut in [[stage_in]], texture2d<half> src [[texture(0)]], constant float4 &p [[buffer(0)]],
                                  device ShadeGpu &gw [[buffer(18)]]) {
	float2 texel = 1.0 / float2(src.get_width(), src.get_height());
	float2 uv = in.uv * p.xy, lo = texel, hi = p.xy - texel;
	half3 a = min(src.sample(shadeLinearClamp, clamp(uv + texel * float2(-1, -1), lo, hi)).rgb, half3(30000.0h));
	half3 b = min(src.sample(shadeLinearClamp, clamp(uv + texel * float2(1, -1), lo, hi)).rgb, half3(30000.0h));
	half3 c = min(src.sample(shadeLinearClamp, clamp(uv + texel * float2(-1, 1), lo, hi)).rgb, half3(30000.0h));
	half3 d = min(src.sample(shadeLinearClamp, clamp(uv + texel * float2(1, 1), lo, hi)).rgb, half3(30000.0h));
	half wa = 1.0h / (1.0h + shadeLumaH(a)), wb = 1.0h / (1.0h + shadeLumaH(b)), wc = 1.0h / (1.0h + shadeLumaH(c)), wd = 1.0h / (1.0h + shadeLumaH(d));
	// M3.3 (mcopt.shade.xdrSkip): does any pixel come near the XDR knee this frame (p.z: the threshold, 0 = not asked)? One
	// atomic per SIMD group that sees one; ShadeXdr reads ShadeGpu.xdrHot a frame or two later and keeps the XDR path on.
	if (p.z > 0.0) {
		float m = float(max(max(shadeLumaH(a), shadeLumaH(b)), max(shadeLumaH(c), shadeLumaH(d))));
		// (audit idx 44: read before writing, so once one group set the flag the others don't queue a same-word RMW in L2)
		if (simd_any(m > p.z) && simd_is_first()
		    && atomic_load_explicit((device atomic_uint *) &gw.xdrHot, memory_order_relaxed) == 0u)
			atomic_fetch_or_explicit((device atomic_uint *) &gw.xdrHot, 1u, memory_order_relaxed);
	}
	return half4((a * wa + b * wb + c * wc + d * wd) / (wa + wb + wc + wd), 1.0h);
}

fragment half4 shade_bloom_down(ShadeFsOut in [[stage_in]], texture2d<half> src [[texture(0)]]) {
	float2 texel = 1.0 / float2(src.get_width(), src.get_height());
	return half4(shadeDown13(src, in.uv, texel, false), 1.0h);
}

// x: weight of this level, y: weight of the coarser accumulation (1, or 0 for the coarsest level)
struct ShadeBloomUp { float4 w; };

fragment half4 shade_bloom_up(ShadeFsOut in [[stage_in]], texture2d<half> level [[texture(0)]], texture2d<half> coarser [[texture(1)]],
                              constant ShadeBloomUp &p [[buffer(0)]]) {
	half3 l = level.sample(shadeLinearClamp, in.uv).rgb;
	float2 t = 1.0 / float2(coarser.get_width(), coarser.get_height());
	// (2.0.1 opt) variance-matched 4-tap bilinear tent (sigma^2 = 0.5 texel^2, matching the 3x3 tent with 55% fewer taps);
	// each tap weighted by 0.25h before sum and combined in FP32 capped at 60000 so sun cores never overflow half/RG11B10F (issue #8)
	float2 o = t * 0.70710678;
	half3 u = coarser.sample(shadeLinearClamp, in.uv + o).rgb * 0.25h
	        + coarser.sample(shadeLinearClamp, in.uv - o).rgb * 0.25h
	        + coarser.sample(shadeLinearClamp, in.uv + float2(o.x, -o.y)).rgb * 0.25h
	        + coarser.sample(shadeLinearClamp, in.uv + float2(-o.x, o.y)).rgb * 0.25h;
	return half4(half3(min(float3(l) * p.w.x + float3(u) * p.w.y, 60000.0)), 1.0h);
}

// p: x 1 / (sum of the bloom weights), y bloom on (0/1), z frame index, w debug view; q: x weight of bloom level 0, y the
// volumetric light's upsample mode and z its depth tolerance scale (2026-10-09 look development: shadeVlUpsample);
// v: x volumetric light folded in (0/1, ShadePost.setVolumetric), y its max march distance (blocks), zw the live part of the
// VL textures (uv scale);
// r: xy the live render size in depth (TAAU dynamic resolution: the sub-rect of the fixed-size world depth this frame drew;
// output uv maps into it), z sharpen strength (TAAU: scene is the resolved history, sharpened here; 0 off), w bits (an exact
// small float): 1 = Distant Horizons drew this frame (M3: the Nether fog leaves the pixels where depth is empty); 2 (TAAU,
// M2.2; 0 = M2.1) depth and the volumetric light read where this frame's jittered raster shows the pixel's scene point;
// x (M3 XDR, shade_final_xdr): x on, y highlight peak (x SDR white), z knee (exposed scene luminance), w octaves to the peak;
// Full-scene mode uses x = (2, peak, curve b, curve beta), a.w = scene brightness.
// a (godrays v3): x > 0 the volumetric light's air mode (vl.metal: the shadows take the haze's sunlit glow out of the air, so its
// light is negative on surfaces too): the floor of a surface's light it may leave (share; the sky keeps 0.55), y (FT2.7) its edge
// fix bits (audit idx 47: 1 read at the haze edge's keys, 2 the fallbacks' negative part uncapped), zw 0
struct ShadeFinalParams { float4 p; float4 q; float4 v; float4 r; float4 x; float4 a; };

// Contrast-limited sharpen of the resolved TAAU history (original; was the TAAU module's output pass, folded in here: one
// full-resolution pass less): an unsharp mask from the 4-neighbour cross, weaker where the local contrast is already high,
// clamped to the neighbourhood's range so it never overshoots into halos. Restores the crispness of pixel-art textures the
// temporal resolve softens. Linear pre-exposed HDR: the contrast measure is relative, so it behaves the same at any level.
// (v12-opt) LEAN: the four neighbours by nearest samples at immediate texel offsets, clamped to the edge by the sampler (the same
// texels as the clamped reads, without their address maths: -0.02..-0.04 ms at 3024x1964, the same image)
template <bool LEAN = false>
static inline half3 shadeSharpen(texture2d<half> img, uint2 px, half3 m, half amount) {
	half3 n, s, e, w;
	if (LEAN) {
		constexpr sampler pxs(coord::pixel, filter::nearest, address::clamp_to_edge);
		float2 cc = float2(px) + 0.5;
		n = img.sample(pxs, cc, int2(0, 1)).rgb;
		s = img.sample(pxs, cc, int2(0, -1)).rgb;
		e = img.sample(pxs, cc, int2(1, 0)).rgb;
		w = img.sample(pxs, cc, int2(-1, 0)).rgb;
	} else {
		int2 c = int2(px), last = int2(img.get_width(), img.get_height()) - 1;
		n = img.read(uint2(min(c + int2(0, 1), last))).rgb;
		s = img.read(uint2(max(c - int2(0, 1), int2(0)))).rgb;
		e = img.read(uint2(min(c + int2(1, 0), last))).rgb;
		w = img.read(uint2(max(c - int2(1, 0), int2(0)))).rgb;
	}
	half3 lo = min(m, min(min(n, s), min(e, w)));
	half3 hi = max(m, max(max(n, s), max(e, w)));
	half range = dot(hi - lo, half3(0.2126h, 0.7152h, 0.0722h)) / max(dot(hi, half3(0.2126h, 0.7152h, 0.0722h)), 0.02h);
	half k = amount * 2.0h * (1.0h - smoothstep(0.15h, 0.9h, range));
	return clamp(m + (m - (n + s + e + w) * 0.25h) * k, lo, hi);
}

// Volumetric light folded into the final pass (the VL module's low-resolution result, ShadePost.setVolumetric): vlT holds
// rgb = in-scattered light (radiance before exposure), a = transmittance of its medium; vlD the matching VL history, a =
// the distance each texel marched (blocks, 1e4 = sky). Depth-aware bilinear upsample to the pixel at uv with scene distance
// dist: bilinear x distance similarity; where no low-resolution texel is at this depth (a thin leaf against the sky), the
// closest one, its light scaled by how much air this pixel's ray crosses (no halos around foliage).
// (2026-10-09, look development, live: mode = mcopt.shade.vl.upMode, tolScale = mcopt.shade.vl.upTol) mode 0: as below; 1: where no
// texel is at this depth, the bilinear blend of the four, each scaled by its own air ratio (not the closest one alone: on leaves
// against bright shafts it switched pixel by pixel, the "dots"); 2: plain bilinear (no depth test: halos, no dots); 3: plain
// bilinear scaled by the air ratio of the footprint's mean distance
// (FT2.7, audit idx 47; airNeg: the air mode's light, negative where the shadows take the haze's glow out) in the fallbacks below the
// negative part is scaled by the air ratio uncapped (up to 16): a pixel farther than every texel (a gap between leaves, the far side
// of a silhouette) gets the final pass's full haze glow, so it needs the full shadowed share of it taken out, not the near texels'
// (a bright rim on near leaves toward a low sun). The positive part stays capped at 1 (FT2.2: x4 positive extrapolation made rings)
static inline half3 shadeVlScaled(half3 rgb, half rr, bool airNeg) {
	return airNeg ? max(rgb, 0.0h) * saturate(rr) + min(rgb, 0.0h) * min(rr, 16.0h) : rgb * saturate(rr);
}
static inline half4 shadeVlUpsample(texture2d<half> vlT, texture2d<half> vlD, float2 uv, float dist, float maxD, float2 uvScale,
                                    float mode = 0.0, float tolScale = 1.0, bool airNeg = false) {
	// the live part of the VL targets (TAAU dynamic resolution: allocated for the largest scale; uvScale = live / allocated)
	float2 dim = float2(vlT.get_width(), vlT.get_height());
	uv = min(uv * uvScale, uvScale - 0.5 / dim);
	float tolerance = (0.04 * dist + 0.15) * max(tolScale, 0.05);
	float hd = min(dist, 3e4);
	// the four distances of the bilinear footprint in one fetch (gather order: (0,1) (1,1) (1,0) (0,0)); when all of them
	// are at this pixel's depth (most of the screen) one hardware-filtered sample does it
	half4 dd = vlD.gather(shadeLinearClamp, uv, int2(0), component::w);
	if (mode > 1.5 && mode < 3.5) {
		half4 s = vlT.sample(shadeLinearClamp, uv);
		if (mode < 2.5) return s;
		float2 lp3 = uv * dim - 0.5;
		half2 fr3 = half2(lp3 - floor(lp3));
		half4 bw4 = half4((1.0h - fr3.x) * fr3.y, fr3.x * fr3.y, fr3.x * (1.0h - fr3.y), (1.0h - fr3.x) * (1.0h - fr3.y)); // gather order
		float mD = maxD, avgD = dot(float4(bw4), min(float4(dd), mD));
		return half4(s.rgb * half(clamp((min(hd, mD) + 0.5) / (avgD + 0.5), 0.0, 4.0)), s.a);
	}
	if (all(abs(float4(dd) - hd) < 0.5 * tolerance)) return vlT.sample(shadeLinearClamp, uv);
	// (2.0.1 opt) defer bilinear-grid coordinate math past the smooth fast path and cache the 2x2 reads for fallback reuse
	float2 lp = uv * dim - 0.5;
	float2 fl = floor(lp);
	half2 fr = half2(lp - fl);
	int2 base = int2(fl), hi = int2(dim * uvScale) - 1;
	half4 sum = 0.0h, bestC = half4(0.0h, 0.0h, 0.0h, 1.0h);
	half4 sv[4];
	half wsum = 0.0h;
	float best = 6e4, bestD = 1.0;
	for (int j = 0; j <= 1; j++) {
		for (int i = 0; i <= 1; i++) {
			uint2 q = uint2(clamp(base + int2(i, j), int2(0), hi));
			half4 s = vlT.read(q);
			sv[j * 2 + i] = s;
			half sd = j == 0 ? (i == 0 ? dd.w : dd.z) : (i == 0 ? dd.x : dd.y);
			half bw = (i == 0 ? 1.0h - fr.x : fr.x) * (j == 0 ? 1.0h - fr.y : fr.y) + 1e-3h;
			float diff = abs(float(sd) - hd);
			half x = half(min(diff / tolerance, 32.0)); // cubic <= 33792: finite in half, unlike an unbounded depth ratio
			half w = bw / (1.0h + x * x * (1.0h + x));
			sum += s * half(w);
			wsum += w;
			if (diff < best) {
				best = diff;
				bestC = s;
				bestD = sd;
			}
		}
	}
	// (1.2.7 candidate 7, mcopt.shade.vl.upMode 4) A pixel the four don't see (a canopy gap, a leaf's rim: the VL texels are 3x the
	// pixels) used to pick its value by thresholds: the four's weights over 0.02, else the first of four probes at its depth, else the
	// air ratio. Swaying leaves move those depths every frame, so gap pixels jumped between the far air's light and the leaves' (sunlit
	// orange specks flickering in the canopy at sunset, Gael 2026-11-04; and this pass runs after the TAA, nothing smooths it). Here
	// every candidate counts by the same depth weight: the four and eight probes up to 3 texels out, one weighted mean, and the air
	// ratio only fades in where none of them is near this pixel's depth.
	if (mode > 3.5) {
		const int2 ring[8] = {int2(-1, 0), int2(2, 1), int2(0, 2), int2(1, -1), int2(-2, -1), int2(3, 0), int2(1, 3), int2(-1, 2)};
		for (int k = 0; k < 8; k++) {
			uint2 q = uint2(clamp(base + ring[k], int2(0), hi));
			half4 s = vlT.read(q);
			float diff = abs(float(vlD.read(q).a) - hd);
			half x = half(min(diff / tolerance, 32.0));
			half w = 0.35h / (1.0h + x * x * (1.0h + x));
			sum += s * w;
			wsum += w;
		}
		half4 mean = wsum > 1e-4h ? sum / wsum : bestC;
		half4 ratio = 0.0h;
		half bsum = 0.0h;
		float mD = maxD;
		for (int j = 0; j <= 1; j++) {
			for (int i = 0; i <= 1; i++) {
				half4 s = sv[j * 2 + i];
				half sd = j == 0 ? (i == 0 ? dd.w : dd.z) : (i == 0 ? dd.x : dd.y);
				half bw = (i == 0 ? 1.0h - fr.x : fr.x) * (j == 0 ? 1.0h - fr.y : fr.y) + 1e-3h;
				ratio += half4(shadeVlScaled(s.rgb, half((min(hd, mD) + 0.5) / (min(float(sd), mD) + 0.5)), airNeg), s.a) * bw;
				bsum += bw;
			}
		}
		return mix(ratio / bsum, mean, smoothstep(0.0h, 0.08h, wsum));
	}
	// (2.0.1 anti-flicker) Fast path for normal edges where at least one of the 2x2 VL texels matches this pixel's depth.
	// On thin 1-3 px leaf holes (wsum < 0.15h, <2% of screen), replace the old binary wsum>0.02 and first-hit probe cliffs
	// with smooth cubic depth-weighted probes (faded continuously from wsum=0.15h) and a smooth blend into the air-ratio fallback.
	if (wsum >= 0.15h) return sum / wsum;
	half probeFade = 1.0h - smoothstep(0.06h, 0.15h, wsum);
	if (probeFade > 0.0h) {
		const int2 probes[4] = {int2(-1, 0), int2(2, 1), int2(0, 2), int2(1, -1)};
		for (int k = 0; k < 4; k++) {
			uint2 q = uint2(clamp(base + probes[k], int2(0), hi));
			float diff = abs(float(vlD.read(q).a) - hd);
			half x = half(min(diff / tolerance, 32.0));
			half w = (0.45h * probeFade) / (1.0h + x * x * (1.0h + x));
			if (w > 1e-4h) {
				sum += vlT.read(q) * w;
				wsum += w;
			}
		}
		if (wsum >= 0.15h) return sum / wsum;
	}
	half4 mean = wsum > 1e-4h ? sum / wsum : bestC;
	half blendMean = smoothstep(0.0h, 0.15h, wsum);
	if (mode < 0.5 && hd > bestD + tolerance) return mix(half4(0.0h, 0.0h, 0.0h, 1.0h), mean, blendMean);
	float mD = maxD;
	if (mode > 0.5) { // the four by their bilinear weights, each scaled by its own air ratio
		half4 acc = 0.0h;
		half bsum = 0.0h;
		for (int j = 0; j <= 1; j++) {
			for (int i = 0; i <= 1; i++) {
				half4 s = sv[j * 2 + i];
				half sd = j == 0 ? (i == 0 ? dd.w : dd.z) : (i == 0 ? dd.x : dd.y);
				half bw = (i == 0 ? 1.0h - fr.x : fr.x) * (j == 0 ? 1.0h - fr.y : fr.y) + 1e-3h;
				acc += half4(shadeVlScaled(s.rgb, half((min(hd, mD) + 0.5) / (min(float(sd), mD) + 0.5)), airNeg), s.a) * bw;
				bsum += bw;
			}
		}
		return mix(acc / bsum, mean, blendMean);
	}
	return mix(half4(shadeVlScaled(bestC.rgb, half((min(hd, mD) + 0.5) / (min(bestD, mD) + 0.5)), airNeg), bestC.a), mean, blendMean);
}

// Camera-relative world position of the pixel at uv = (pixel + 0.5) / size with reversed-Z depth d. Targets hold GL row
// order (row 0 = the bottom of the view), so the NDC is uv * 2 - 1 with no flip.
static inline float3 shadeWorldFromDepth(float2 uv, float d, constant ShadeFrame &f) {
	float2 ndc = uv * 2.0 - 1.0;
	float4 w = f.invViewProj * float4(ndc, d, 1.0);
	return w.xyz / w.w;
}

// (1.2.9, mcopt.shade.skyHaze, ShadeLook.user4.x) The haze and the mist over the sky too, as far as the loaded terrain reaches along
// the pixel's ray (the border fog's l4 radius; steep rays at most 4 radii, where the layers' depth has long converged), and the
// terrain's own never from farther than that. Before, the sky got none (its LUT has the atmosphere) while terrain got all of its
// distance's: a hill at the render distance, already faded into the sky by the border fog, still took the haze of ~250 blocks on
// top (dimmed, plus a pale blue glow): a pale ghost with a hard outline in front of the clouds, and in the morning's mist far land
// whiter than the sky behind it (Gael 2026-11-23: "a lo lejos el fog hace que las montañas se vean raras"). Now the land at the
// border and the sky behind it get the same haze, so the land fades into it without an outline, and the low sky is hazy when
// the land is (Photon puts its analytic fog in its sky map for the same reason; own code). Only with the border fog (fogMisc.z > 0):
// with Distant Horizons the LODs fill the distance and fog themselves.
static inline float shadeL4(float2 a) { float2 q = a * a; return sqrt(sqrt(dot(q, q))); }
static inline float3 shadeHazeSkyEnd(float3 ray, constant ShadeLook &L) {
	float3 v = normalize(ray);
	return v * (L.fogMisc.z / max(shadeL4(v.xz), 0.25));
}
static inline float3 shadeHazeBorderClamp(float3 p, constant ShadeLook &L) {
	return p * min(1.0, L.fogMisc.z / max(shadeL4(p.xz), 1e-3));
}
// (1.2.9 candidate 3, user4.x = 2, the default) The cheap way to the same end: the sky gets no haze (as in 1.2.8) and the terrain's
// own fades out across the border fog's band, by the share of the terrain the border fog keeps (shadeFogAir2's edge without the
// chunk fade), so the land already faded into the sky carries none. The sky's haze (user4.x = 1) cost +0.23 ms on the perf spin at
// native resolution (run c2-attrib: every sky pixel of the output evaluates the layers and both phase functions).
static inline float shadeHazeBorderKeep(float3 p, constant ShadeLook &L) {
	float Rb = L.fogMisc.z;
	float loR = L.fogMisc.y * Rb;
	// (2.0.1 opt) L4(p.xz) <= L2(p.xz) always, so within the inner radius smoothstep is identically 0 (saves 2 sqrt on ~80% of terrain)
	if (dot(p.xz, p.xz) <= loR * loR) return 1.0;
	return 1.0 - smoothstep(loR, Rb, shadeL4(p.xz));
}

// (2.0.1 opt) Out-of-line cold helpers keep rare edge/sunset-clamp paths out of the main shader's live register set.
static __attribute__((noinline)) float3 shadeAerialSunGlowCold(float3 wp, texture2d<half> skyLut, sampler lutS,
                                                               constant ShadeFrame &f, constant ShadeLook &L) {
	return shadeAerialSunGlow(wp, skyLut, lutS, f, L);
}

#ifdef SHADE_HAZE_EDGE
static __attribute__((noinline)) void shadeHazeEdgeSlow(float2 uv, float2 dsize, uint2 t0, float4 dq, float4 wq, float hazeNear,
                                                        bool skyHaze, bool hazeFade, constant ShadeFrame &f, constant ShadeLook &L,
                                                        thread float3 &Ts, thread float3 &Ss, thread float3 &Us, thread float4 &dkq) {
	uint2 t1 = t0 + 1u;
	float3 vEdge = normalize(shadeViewRay(uv * 2.0 - 1.0, f.invViewProj));
	float ycEdge = f.cameraBlock.y + f.cameraFract.y;
	float nu = dot(vEdge, f.lightDirWorld.xyz);
	float phR = 0.0596831 * (1.0 + nu * nu);
	float phM = 0.8 * shadeHG(nu, SHADE_HAZE_MIE_G) + 0.2 * shadeHG(nu, -0.2);
	float airSun = shadeAirSun(L);
	float3 E = f.sunColor.rgb * (3.14159265 * airSun);
	float3 skyE = f.ambientSky.rgb * (0.9 * shadeAirSky(L));
	float glow = 1.0 + L.fogMisc.w;
	float aM = L.fogM.w;
	float msGain = L.user4.w > 0.0 ? L.user4.w : 1.0;
	float aMScale = aM / (1.0 - 0.5 * aM);
	float3 sR = (E * phR + skyE) * 2.0;
	float3 sM = (E * phM * glow * msGain + skyE) * aMScale;
	float3 sunR = E * (phR * 2.0), sunM = E * (phM * glow * msGain * aMScale);
	float cave = (1.0 - airSun) * L.eye.x * f.ambientBlock.w;
	Ts = 0.0; Ss = 0.0; Us = 0.0;
	for (int k = 0; k < 4; k++) {
		float3 Tk = float3(1.0), Sk = float3(0.0), Uk = float3(0.0);
		uint2 tk = uint2(k & 1 ? t1.x : t0.x, k & 2 ? t1.y : t0.y);
		float3 pk = float3(0.0);
		bool eval = false;
		if (dq[k] > 0.0) {
			pk = shadeWorldFromDepth((float2(tk) + 0.5) / dsize, dq[k], f);
			dkq[k] = length(pk);
			if (skyHaze) pk = shadeHazeBorderClamp(pk, L);
			eval = dot(pk, pk) > hazeNear;
		} else if (skyHaze) {
			pk = shadeHazeSkyEnd(shadeViewRay((float2(tk) + 0.5) / dsize * 2.0 - 1.0, f.invViewProj), L);
			eval = true;
		}
		if (eval) {
			float tLen = length(pk);
			float dy = pk.y / max(tLen, 1e-4);
			float dR = shadeLayerDepth(ycEdge, dy, tLen, L.fogMisc.x, L.fogR.w);
			float dM = shadeLayerDepth(ycEdge, dy, tLen, L.fogM.z, L.fogM.y);
			float3 tauR = L.fogR.rgb * dR;
			float tauM = L.fogM.x * dM;
			float3 tau = tauR + tauM;
			Tk = exp(-tau);
			float3 w = (1.0 - Tk) / max(tau, 1e-6);
			Uk = w * (tauR * sunR + tauM * sunM);
			Sk = w * (tauR * sR + tauM * sM) + (1.0 - Tk) * cave;
			if (hazeFade && dq[k] > 0.0) { float kk = shadeHazeBorderKeep(pk, L); Tk = mix(float3(1.0), Tk, kk); Sk *= kk; Uk *= kk; }
		}
		Ts += Tk * wq[k];
		Ss += Sk * wq[k];
		Us += Uk * wq[k];
	}
}
#endif

// Everything of the final pass before the display transform: the exposed scene colour (haze, the dimension fogs, camera
// media, VL, bloom, Purkinje, vignette, vibrance). lum: the scene luminance before exposure (debug view 4).
// DIMS (M3): compiled with the Nether/End fog, End sky, heat shimmer and camera media; the overworld variant (DIMS false)
// carries none of that code (ShadePost picks the variant per frame), so the overworld's final pass costs what it did in M2.1.
// LEAN (v12-opt, shade_final_lean / shade_final_xdr_lean; ShadePost picks them while the settings are the defaults they assume,
// mcopt.shade.finalLean): the volumetric light's edge fix off (a.y 0), its upsample mode 1 (q.y 1) and no debug view, as
// constants: the same image, without the code those settings never run (and the edge fix's per-texel keys it kept live).
template <bool DIMS, bool LEAN = false>
static float3 shadeFinalScene(ShadeFsOut in, texture2d<half> scene, texture2d<half> bloom, depth2d<float> depth, texture2d<half> bloom0,
                              texture2d<half> vlT, texture2d<half> vlD, constant ShadeFinalParams &P, constant ShadeFrame &f,
                              constant ShadeLook &L, constant ShadeGpu &g, constant ShadeResources &sr, thread float &lum,
                              texture2d<half> skyLut, sampler lutS) {
	uint2 px = uint2(in.position.xy);
	float ex = max(g.exposure.x, 1e-6);
	// height haze and mist (E06) from depth, once per pixel (the shaded pipelines skip it in the HDR target): surfaces in the
	// air only (under water / in lava the game's fog owns it), not the sky (the atmosphere has its own) nor Distant Horizons'
	// LODs (not in this depth; DH fogs them). Depth may be smaller than the image (a resolver's output over the internal world).
	float2 dsize = P.r.x > 0.0 ? P.r.xy : float2(depth.get_width(), depth.get_height());
	int rw = int(P.r.w);
	// M2.2 (r.w bit 2, TAAU): depth and the volumetric light are this frame's jittered raster, which shows this output pixel's
	// scene point jitter.xy / 2 (uv) further on; reading them at in.uv moved them against the steady resolved image by up to
	// half a render pixel every frame (god rays wobbling at their edges and at the leaves)
	float2 uv = (rw & 2) != 0 ? clamp(in.uv + 0.5 * f.jitter.xy, 0.0, 1.0) : in.uv;
#ifdef SHADE_HAZE_EDGE
	// the 2x2 depth texels around uv (the haze's edge test below) in one gather, and this pixel's own (nearest) texel picked
	// from them: one fetch instead of five, the same values (tp <= dsize - 1.001 keeps t0 + 1 inside the live rect; the
	// nearest texel floor(uv * dsize) is t0 + (fw >= 0.5) per axis; gather order: (t0.x, t1.y) (t1.x, t1.y) (t1.x, t0.y) (t0.x, t0.y))
	float2 tp = clamp(uv * dsize - 0.5, float2(0.0), dsize - 1.001);
	uint2 t0 = uint2(tp);
	float2 fw = tp - float2(t0);
	constexpr sampler gatherClamp(coord::normalized, address::clamp_to_edge, filter::nearest);
	float4 dg = depth.gather(gatherClamp, (float2(t0) + 1.0) / float2(depth.get_width(), depth.get_height()));
	float4 dq = float4(dg.w, dg.z, dg.x, dg.y); // t0, (t1.x, t0.y), (t0.x, t1.y), t1
	float d = fw.y >= 0.5 ? (fw.x >= 0.5 ? dq.w : dq.z) : (fw.x >= 0.5 ? dq.y : dq.x);
#else
	uint2 dpx = min(uint2(uv * dsize), uint2(dsize) - 1u);
	float d = depth.read(dpx);
#endif
	bool dims = DIMS && (L.tier.y & SHADE_FEATURE_DIMS) != 0 && L.dimTint.x > 0.0 && f.flags.x != SHADE_DIM_OVERWORLD;
	uint2 sp = px;
	if (dims && (L.tier.y & SHADE_FEATURE_SHIMMER) != 0 && shadeDimKind(L) == 1 && d > 0.0) {
		// M3 heat shimmer over distant Nether terrain (shade_dims.metal): this pixel shows a slightly displaced one (still
		// sharpened below, like every other pixel: the shimmer must not soften the Nether next to the overworld)
		float dist = length(shadeWorldFromDepth(in.uv, d, f));
		sp = uint2(clamp(int2(px) + int2(round(shadeShimmer(in.uv, dist, f, sr.milkyWay))), int2(0), int2(scene.get_width(), scene.get_height()) - 1));
	}
	half3 c0;
	if (LEAN) { // (v12-opt) a nearest sample at the texel's centre: the same texel, no address maths (shadeSharpen<LEAN>)
		constexpr sampler pxc(coord::pixel, filter::nearest, address::clamp_to_edge);
		c0 = scene.sample(pxc, float2(sp) + 0.5).rgb;
	} else {
		c0 = scene.read(sp).rgb;
	}
	if (P.r.z > 0.0) c0 = shadeSharpen<LEAN>(scene, sp, c0, half(P.r.z));
	float3 c = float3(c0);
	float3 T = float3(1.0);
	bool hazeOn = (L.tier.y & SHADE_FEATURE_HAZE) != 0 && f.flags.x == SHADE_DIM_OVERWORLD && f.fogColor.a < 0.5;
	// (FT2.9, mcopt.shade.caveAir) the haze from the camera on, not from 2 blocks: the VL's air mode takes the shadowed sun glow out
	// of the whole ray, so within 2 blocks it darkened the pixel and past them the glow came in at once: in a cave (high exposure)
	// a sphere 2 blocks around the player (Gael 2026-10-10). Its sky glow follows the eye's sky light (shadeAirSky)
	float hazeNear = shadeAirSmooth(L) ? 0.0 : 4.0;
	float3 wp = d > 0.0 ? shadeWorldFromDepth(uv, d, f) : float3(0.0);
	// (FT2.7, audit idx 47) where the haze below blends the 2x2 depth texels (an edge), their distances and weights: the air mode's
	// VL is then read at the same keys, so what its shadows take out matches the haze glow that was added
	bool hazeEdge = false;
	float4 dkq = float4(1e4), wqq = float4(0.0);
	// (FT2.12) the sunlit part of the haze glow added here (exposed): at most this much is what the VL air mode's shadows take out
	float3 sunGlow = float3(0.0);
	// (2.0.1 anti-flicker) on 2x2 sky/foreground silhouette pixels (1-px leaf holes, canopy rims), blend VL, dark-ray clamp,
	// and bloom fog weight continuously by the same bilinear terrain coverage wTerr used for haze (instead of binary nearest depth d)
	bool vlSkyEdge = false;
	float vlTerrW = d > 0.0 ? 1.0 : 0.0;
	float3 vlTerrWp = wp;
	const bool skyHaze = !LEAN && hazeOn && L.user4.x > 0.5 && L.user4.x < 1.5 && L.fogMisc.z > 0.0; // (1.2.9, see shadeHazeSkyEnd)
	bool hazeFade = hazeOn && L.user4.x > 1.5 && L.fogMisc.z > 0.0; // (1.2.9 candidate 3, see shadeHazeBorderKeep)
#ifdef SHADE_HAZE_EDGE
	if (hazeOn) {
		// FT1.3: the depth is this frame's jittered raster at the render scale and the colour the resolved (TAAU) image, so the
		// nearest depth texel switched the haze on and off pixel by pixel along a silhouette that is antialiased in the colour:
		// far terrain against the sky (sunset, toward the sun) got a rim of bright and dark dots (Gael). The 2x2 texels around:
		// where they agree (almost everywhere) one evaluation as before; along an edge each terrain texel's haze is weighted
		// bilinearly (the sky's texels add none), so the haze fades across the edge as the colour does
		// (dq, t0, fw: read above with the pixel's own depth)
		float dlo = min(min(dq.x, dq.y), min(dq.z, dq.w)), dhi = max(max(dq.x, dq.y), max(dq.z, dq.w));
		// (2.0.1 opt) skip near-field (<12 blocks) terrain-vs-terrain depth edges where haze differs by <0.2%, and unify
		// single-surface sky silhouettes into 1 haze eval instead of up to 3; push multi-depth 4-corner fallback out-of-line
		float nearCut = f.proj[3][2] > 0.0 ? (f.proj[3][2] * (1.0 / 12.0) - f.proj[2][2]) : 1.0;
		if (dhi > 0.0 && (dlo <= 0.0 || (dlo <= nearCut && dhi > dlo * 1.25))) {
			float4 wq = float4((1.0 - fw.x) * (1.0 - fw.y), fw.x * (1.0 - fw.y), (1.0 - fw.x) * fw.y, fw.x * fw.y);
			float dMinPos = min(min(dq.x > 0.0 ? dq.x : 2.0, dq.y > 0.0 ? dq.y : 2.0),
			                    min(dq.z > 0.0 ? dq.z : 2.0, dq.w > 0.0 ? dq.w : 2.0));
			if (dlo <= 0.0 && !skyHaze && (LEAN || P.a.x <= 0.0 || (int(P.a.y) & 1) == 0) && dhi <= dMinPos * 1.25) {
				float wTerr = (dq.x > 0.0 ? wq.x : 0.0) + (dq.y > 0.0 ? wq.y : 0.0)
				            + (dq.z > 0.0 ? wq.z : 0.0) + (dq.w > 0.0 ? wq.w : 0.0);
				float3 pRep = d > 0.0 ? wp : shadeWorldFromDepth(uv, dhi, f);
				vlSkyEdge = wTerr > 0.02 && wTerr < 0.98;
				vlTerrW = wTerr;
				vlTerrWp = pRep;
				if (dot(pRep, pRep) > hazeNear) {
					float3 Tk, Uk;
					float3 Sk = shadeHazeInscatter(pRep, f, L, 1.0, Tk, Uk);
					if (hazeFade) { float kk = shadeHazeBorderKeep(pRep, L); Tk = mix(float3(1.0), Tk, kk); Sk *= kk; Uk *= kk; }
					T = mix(float3(1.0), Tk, wTerr);
					c = c * T + Sk * (wTerr * ex);
					sunGlow = Uk * (wTerr * ex);
				}
			} else {
				float3 Ts, Ss, Us;
				shadeHazeEdgeSlow(uv, dsize, t0, dq, wq, hazeNear, skyHaze, hazeFade, f, L, Ts, Ss, Us, dkq);
				T = Ts;
				c = c * Ts + Ss * ex;
				sunGlow = Us * ex;
				hazeEdge = true;
				wqq = wq;
				if (dlo <= 0.0) {
					float wT = (dq.x > 0.0 ? wq.x : 0.0) + (dq.y > 0.0 ? wq.y : 0.0)
					         + (dq.z > 0.0 ? wq.z : 0.0) + (dq.w > 0.0 ? wq.w : 0.0);
					vlSkyEdge = wT > 0.02 && wT < 0.98;
					vlTerrW = wT;
					vlTerrWp = d > 0.0 ? wp : shadeWorldFromDepth(uv, dhi, f);
				}
			}
		} else if (d > 0.0 && dot(wp, wp) > hazeNear) {
			float3 U;
			float3 S = shadeHazeInscatter(skyHaze ? shadeHazeBorderClamp(wp, L) : wp, f, L, 1.0, T, U);
			if (hazeFade) { float kk = shadeHazeBorderKeep(wp, L); T = mix(float3(1.0), T, kk); S *= kk; U *= kk; }
			c = c * T + S * ex;
			sunGlow = U * ex;
		} else if (skyHaze && d <= 0.0) {
			float3 U;
			float3 S = shadeHazeInscatter(shadeHazeSkyEnd(shadeViewRay(uv * 2.0 - 1.0, f.invViewProj), L), f, L, 1.0, T, U);
			c = c * T + S * ex;
			sunGlow = U * ex;
		}
	}
#else
	if (d > 0.0 && hazeOn) {
		if (dot(wp, wp) > hazeNear) {
			float3 U;
			float3 S = shadeHazeInscatter(skyHaze ? shadeHazeBorderClamp(wp, L) : wp, f, L, 1.0, T, U);
			if (hazeFade) { float kk = shadeHazeBorderKeep(wp, L); T = mix(float3(1.0), T, kk); S *= kk; U *= kk; }
			c = c * T + S * ex;
			sunGlow = U * ex;
		}
	} else if (skyHaze) {
		float3 U;
		float3 S = shadeHazeInscatter(shadeHazeSkyEnd(shadeViewRay(uv * 2.0 - 1.0, f.invViewProj), L), f, L, 1.0, T, U);
		c = c * T + S * ex;
		sunGlow = U * ex;
	}
#endif
	// M3: the End's sky where vanilla drew none (the dragon fight), then the Nether's layered glowing haze / the End's violet
	// haze (shade_dims.metal), in open air
	// r.w is a bit field: 1 = Distant Horizons drew into this frame (its LODs sit where depth is empty), 2 = M2.2's VL unjitter
	bool dhDrew = (int(P.r.w) & 1) != 0;
	// M3.3 (mcopt.shade.dhClear): with DH in the frame, the sky still goes where nothing drew: the pixel holds the frame's clear
	// colour (vanilla's fog colour, which ShadePost's bridge now applies to the HDR target), not one of DH's LODs (brighter)
	bool endSkyHere = !dhDrew || (shadeDimsBit(L, SHADE_DIMS_DH_SKY) && shadeLuma(c) <= shadeLuma(shadeLdrToHdr(f.fogColor.rgb, L)) * 1.5 + 1e-4);
	if (dims && d <= 0.0 && shadeDimKind(L) == 3 && f.flags.y == 0 && endSkyHere) {
		float pixelAngle = 2.0 * atan(1.0 / max(abs(f.proj[1][1]), 1e-3)) / float(scene.get_height());
		// (FT2.8, audit idx 80: the jitter-corrected uv, as depth and the VL here: the End's stars and beams shifted every frame)
		c = shadeEndSky(normalize(shadeViewRay(uv * 2.0 - 1.0, f.invViewProj)), f, L, sr.milkyWay, pixelAngle) * ex;
	}
	if (dims && f.flags.y == 0) {
		c = shadeDimsFog(c, wp, d > 0.0, f, L, ex, dhDrew, sr.milkyWay);
		T = float3(d > 0.0 ? exp(-L.dimTint.x * length(wp)) : 0.0);
	}
	// M3: the camera inside lava or powder snow (E26)
	if (DIMS && (L.tier.y & SHADE_FEATURE_MEDIA) != 0 && (f.flags.y == 2 || f.flags.y == 3)) c = shadeMedia(c, in.uv, d > 0.0 ? length(wp) : 1e4, f, sr.milkyWay);
	// volumetric light (god rays, canopy mist; VL module): its medium is the air near the camera, in front of the haze
	float tv = 1.0;
	if (P.v.x > 0.5) {
		float2 vlScale = P.v.z > 0.0 ? P.v.zw : float2(1.0);
		// (FT2.7, audit idx 47; a.y bits, mcopt.shade.vl.edgeFix: 1 the haze edge's keys, 2 the fallback's negative part uncapped)
		const int edgeFix = LEAN ? 0 : (P.a.x > 0.0 ? int(P.a.y) : 0);
		const float upMode = LEAN ? 1.0 : P.q.y;
		half4 v;
		if (hazeEdge && (edgeFix & 1) != 0) {
			v = 0.0h;
			for (int k = 0; k < 4; k++) {
				if (wqq[k] > 0.0) v += shadeVlUpsample(vlT, vlD, uv, dkq[k], P.v.y, vlScale, upMode, P.q.z, (edgeFix & 2) != 0) * half(wqq[k]);
			}
		} else if (vlSkyEdge) {
			half4 vSky = shadeVlUpsample(vlT, vlD, uv, 1e4, P.v.y, vlScale, upMode, P.q.z, (edgeFix & 2) != 0);
			half4 vTerr = shadeVlUpsample(vlT, vlD, uv, length(vlTerrWp), P.v.y, vlScale, upMode, P.q.z, (edgeFix & 2) != 0);
			v = mix(vSky, vTerr, half(vlTerrW));
		} else {
			v = shadeVlUpsample(vlT, vlD, uv, d > 0.0 ? length(wp) : 1e4, P.v.y, vlScale, upMode, P.q.z, (edgeFix & 2) != 0);
		}
		tv = P.v.x > 1.5 ? 1.0 : float(v.a); // (v.x 2: vlT is the history, a = distance; no medium dims the scene: FT2.8 idx 2)
		// v.rgb < 0 on the sky: the crepuscular shadows (dark rays), floored at 55 % of the pixel
		float3 lit = c * tv;
		float3 add = clamp(float3(v.rgb) * ex, -30000.0, 30000.0);
		// (2026-10-09, q.w > 0) a soft knee on the light it adds: luminance l -> l / sqrt(1 + (l / knee)^2), linear for the
		// shafts (small l), at most the knee where a ray crosses tens of blocks of lit mist (a uniform glow that veiled the
		// view: Gael, "como un lente empanado")
		if (P.q.w > 0.0) {
			float la = shadeLuma(max(add, 0.0)) / P.q.w;
			add *= rsqrt(1.0 + la * la);
		}
		// (FT2.12, a.z > 0: mcopt.shade.vl.airClamp) on a surface the shadows take out at most the sunlit haze glow added to this
		// pixel above, all of it if the air is all in shadow, and never anything of the surface itself. FT2.11 (a.z 0): at most
		// 70 % of the pixel (airFloor 0.3), so where that glow outshone the surface, toward a sun set behind a mountain, 30 % of it
		// stayed: an orange halo through the mountain (Gael 2026-10-11, a snowy canyon at sunset)
		// (the aerial blend's glow around the sun too, which the air mode's shadows now take out as well: shadeAerialSunGlow; looked up
		// only where the light taken out exceeds the haze's glow, the bound's only use: else lit + add is above the bound anyway)
		float3 loSky = lit * 0.55;
		float3 lo = (P.a.x > 0.0 && (d > 0.0 || vlSkyEdge)) ? lit * P.a.x : loSky;
		if (P.a.z > 0.0 && P.a.x > 0.0 && (d > 0.0 || vlSkyEdge)) {
			lo = max(lit - sunGlow * tv, 0.0);
			if (any(add < -sunGlow * tv)) lo = max(lo - shadeAerialSunGlowCold(vlTerrWp, skyLut, lutS, f, L) * (ex * tv * vlTerrW), 0.0);
		}
		if (vlSkyEdge) lo = mix(loSky, lo, vlTerrW);
		c = max(lit + add, lo);
	}
	if (P.p.y > 0.5) {
		float3 b = float3(bloom.sample(shadeLinearClamp, in.uv).rgb + bloom0.sample(shadeLinearClamp, in.uv).rgb * half(P.q.x)) * P.p.x;
		// fog glow: the haze and the canopy mist both soften what is behind them
		float mSky = L.bloom.z * (0.25 + 0.75 * (1.0 - tv));
		float mTerr = L.bloom.z * (1.0 - shadeLuma(T) * tv);
		float m = L.bloom.x + (vlSkyEdge ? mix(mSky, mTerr, vlTerrW) : (d > 0.0 ? mTerr : mSky));
		c = mix(c, b, saturate(m));
	}
	// (2.0.1 opt) Purkinje, vignette, vibrance in FP16 on Apple9 dual-issue ALUs (luma/ex kept FP32 for debug/threshold precision)
	half3 ch = half3(min(max(c, 0.0), 60000.0));
	half lch = shadeLumaH(ch);
	lum = float(lch) / ex;
	if (lum < 0.04 && L.grade1.w > 0.0) { // (FT2.8, audit idx 39: elsewhere a mix by 0, the same pixel)
		half rods = half((1.0 - smoothstep(0.004, 0.04, lum)) * L.grade1.w);
		ch = mix(ch, half3(lch) * half3(0.72h, 0.88h, 1.3h), rods);
		lch = shadeLumaH(ch);
	}
	// vignette (sparing what is bright); (2.0.1 opt) sub-bit-exact x^2.4 fit avoids pow(log2+exp2) at full output resolution
	half2 rh = half2((in.uv - 0.5) * float2(float(scene.get_width()) / float(scene.get_height()), 1.0));
	half vx = saturate(length(rh) * 1.25h);
	half vr = (vx * vx) * (0.8h * sqrt(vx) + 0.2h);
	half vig = 1.0h - half(L.user0.y) * vr * (1.0h - 0.5h * saturate(lch - 1.0h)); // (1.1) user0.y: the vignette (0.12 as released)
	ch *= vig;
	// vibrance: saturate the less saturated colours more
	half Y = lch * vig;
	half mx = max(max(ch.r, ch.g), ch.b), mn = min(min(ch.r, ch.g), ch.b);
	half chroma = (mx - mn) / max(mx, 1e-4h);
	ch = max(Y + (ch - Y) * (1.0h + half(L.grade0.z) * (1.0h - saturate(chroma * half(1.0 / 0.6)))), 0.0h);
	return float3(ch);
}

// Smooth, monotonic shadow toe: derivative 1 - exp(-y / phi) is nonnegative. The old -3 exponent reversed the darkest
// tones (a brighter texel could become darker), accentuating fine texture in shadows. Beyond 16 phi the lift rounds away.
static inline float3 shadeBlackFloor(float3 y, float phi) {
	if (phi > 0.0 && any(y < 16.0 * phi)) y += phi * exp(-y / max(phi, 1e-6));
	return y;
}

static inline half3 shadeLinearToSrgbFast(half3 y) {
	half3 hi = 1.055h * exp2(log2(max(y, 1e-6h)) * half(1.0 / 2.4)) - 0.055h;
	return select(hi, y * 12.92h, y <= 0.0031308h);
}

// The SDR display value -> what main stores: black floor, sRGB, triangular dither (+-1 LSB), debug view 4.
template <bool LEAN = false>
static inline float3 shadeFinalEncode(float3 y, float4 position, constant ShadeFinalParams &P, constant ShadeLook &L, float lum) {
	y = shadeBlackFloor(y, L.grade2.w);
	half3 srgb = shadeLinearToSrgbFast(half3(saturate(y)));
	// (2.0.1 opt) single-IGN triangular dither (+-1 LSB, identical PDF with 1 IGN hash instead of 2)
	half n = half(shadeNoise(position.xy, int(P.p.z))) * 2.0h - 1.0h;
	half tri = sign(n) * (1.0h - sqrt(max(1.0h - abs(n), 0.0h)));
	srgb += tri * half(L.output.z / 255.0);
	if (!LEAN && P.p.w == 4.0) srgb = half3(half(saturate(log2(max(lum, 1e-6)) / 16.0 + 0.6))); // debug: luminance (log)
	return float3(saturate(srgb));
}

#define SHADE_FINAL_ARGS ShadeFsOut in [[stage_in]], texture2d<half> scene [[texture(0)]], texture2d<half> bloom [[texture(1)]], \
	depth2d<float> depth [[texture(2)]], texture2d<half> bloom0 [[texture(3)]], texture2d<half> vlT [[texture(4)]], \
	texture2d<half> vlD [[texture(5)]], constant ShadeFinalParams &P [[buffer(0)]], constant ShadeFrame &f [[buffer(16)]], \
	constant ShadeLook &L [[buffer(17)]], constant ShadeGpu &g [[buffer(18)]], constant ShadeResources &sr [[buffer(19)]], \
	texture2d<half> skyLut [[texture(17)]], sampler lutS [[sampler(13)]]

template <bool DIMS, bool LEAN = false>
static inline float4 shadeFinalSdr(ShadeFsOut in, texture2d<half> scene, texture2d<half> bloom, depth2d<float> depth, texture2d<half> bloom0,
                                   texture2d<half> vlT, texture2d<half> vlD, constant ShadeFinalParams &P, constant ShadeFrame &f,
                                   constant ShadeLook &L, constant ShadeGpu &g, constant ShadeResources &sr, texture2d<half> skyLut, sampler lutS) {
	float lum;
	float3 c = shadeFinalScene<DIMS, LEAN>(in, scene, bloom, depth, bloom0, vlT, vlD, P, f, L, g, sr, lum, skyLut, lutS);
	return float4(shadeFinalEncode<LEAN>(shadeDisplay(c, L), in.position, P, L, lum), 1.0);
}

fragment float4 shade_final(SHADE_FINAL_ARGS) { return shadeFinalSdr<false>(in, scene, bloom, depth, bloom0, vlT, vlD, P, f, L, g, sr, skyLut, lutS); }
fragment float4 shade_final_dims(SHADE_FINAL_ARGS) { return shadeFinalSdr<true>(in, scene, bloom, depth, bloom0, vlT, vlD, P, f, L, g, sr, skyLut, lutS); }
fragment float4 shade_final_lean(SHADE_FINAL_ARGS) { return shadeFinalSdr<false, true>(in, scene, bloom, depth, bloom0, vlT, vlD, P, f, L, g, sr, skyLut, lutS); }

// M3 XDR (E23; mcxdr.m composes at present): main gets the same SDR image with alpha 0 (what later draws -- hand, GUI --
// cover gets alpha > 0), the second target the highlights' brightness above it, in linear Rec.709 (>= 0): the SDR curve
// is kept up to a knee (white surfaces at noon, the sky: full-screen brightness stays where it is), and above it the luminance
// rises toward the peak over P.x.w octaves (the sun, glints, lava, torches, bloom cores), in the SDR pixel's own hue.
struct ShadeFinalXdrOut { float4 sdr [[color(0)]]; half4 excess [[color(1)]]; };

template <bool DIMS, bool LEAN = false>
static inline ShadeFinalXdrOut shadeFinalXdr(ShadeFsOut in, texture2d<half> scene, texture2d<half> bloom, depth2d<float> depth,
                                             texture2d<half> bloom0, texture2d<half> vlT, texture2d<half> vlD, constant ShadeFinalParams &P,
                                             constant ShadeFrame &f, constant ShadeLook &L, constant ShadeGpu &g, constant ShadeResources &sr,
                                             texture2d<half> skyLut, sampler lutS) {
	float lum;
	float3 c = shadeFinalScene<DIMS, LEAN>(in, scene, bloom, depth, bloom0, vlT, vlD, P, f, L, g, sr, lum, skyLut, lutS);
	float3 y = shadeDisplay(c, L);
	// (FT2.8, audit idx 39) only above the knee with a peak over SDR white: elsewhere h, boost and the excess are 0
	float lc = shadeLuma(c), h = 0.0, boost = 0.0;
	float3 excess = float3(0.0);
	if (lc > P.x.z && P.x.y > 1.0) {
		h = saturate(log2(max(lc, 1e-6) / P.x.z) / P.x.w);
		boost = (P.x.y - 1.0) * h * h * (3.0 - 2.0 * h);
		excess = y / max(shadeLuma(y), 0.05) * boost;
	}
	ShadeFinalXdrOut o;
	o.sdr = float4(shadeFinalEncode<LEAN>(y, in.position, P, L, lum), 0.0);
	if (!LEAN && P.p.w == 8.0) o.sdr = float4(saturate(float3(boost / max(P.x.y - 1.0, 1e-3), h, 0.0)), 0.0); // debug: XDR boost, knee
	o.excess = half4(half3(min(max(excess, 0.0), 60000.0)), 1.0h);
	return o;
}

// Full-scene HDR uses a separate display curve; the SDR curve and its inverse stay
// unchanged for screenshots, vanilla passes and the Distant Horizons bridge.
// P.x = (2, peak, curve b, curve beta); P.a.w = scene exposure multiplier.
static inline float3 shadeFullHdr(float3 scene, constant ShadeLook &L, constant ShadeFinalParams &P) {
	float3 c = max(shadeRows(L.gradeIn, max(scene * P.a.w, 0.0)), 0.0);
	c = shadeLottes(c, float4(L.tonemap.xy, P.x.zw));
	float3 y = max(shadeRows(L.gradeOut, c), 0.0);
	y = max(y * L.grade3.rgb + L.grade2.rgb, 0.0);
	y = shadeBlackFloor(y, L.grade2.w);
	// Hue-preserving peak bound after grading; never independently clip colour channels.
	return y / max(1.0, max(max(y.r, y.g), y.b) / P.x.y);
}

template <bool DIMS, bool LEAN = false>
static inline ShadeFinalXdrOut shadeFinalHdr(ShadeFsOut in, texture2d<half> scene, texture2d<half> bloom, depth2d<float> depth,
                                             texture2d<half> bloom0, texture2d<half> vlT, texture2d<half> vlD,
                                             constant ShadeFinalParams &P, constant ShadeFrame &f, constant ShadeLook &L,
                                             constant ShadeGpu &g, constant ShadeResources &sr, texture2d<half> skyLut, sampler lutS) {
	float lum;
	float3 c = shadeFinalScene<DIMS, LEAN>(in, scene, bloom, depth, bloom0, vlT, vlD, P, f, L, g, sr, lum, skyLut, lutS);
	ShadeFinalXdrOut o;
	// Compatibility image, with alpha reserved for subsequent hand/HUD coverage.
	o.sdr = float4(shadeFinalEncode<LEAN>(shadeDisplay(c, L), in.position, P, L, lum), 0.0);
	// Unlike the highlights mode, this is the complete display-linear world image.
	o.excess = half4(half3(shadeFullHdr(c, L, P)), 1.0h);
	return o;
}

fragment ShadeFinalXdrOut shade_final_hdr(SHADE_FINAL_ARGS) { return shadeFinalHdr<false>(in, scene, bloom, depth, bloom0, vlT, vlD, P, f, L, g, sr, skyLut, lutS); }
fragment ShadeFinalXdrOut shade_final_hdr_dims(SHADE_FINAL_ARGS) { return shadeFinalHdr<true>(in, scene, bloom, depth, bloom0, vlT, vlD, P, f, L, g, sr, skyLut, lutS); }
fragment ShadeFinalXdrOut shade_final_hdr_lean(SHADE_FINAL_ARGS) { return shadeFinalHdr<false, true>(in, scene, bloom, depth, bloom0, vlT, vlD, P, f, L, g, sr, skyLut, lutS); }

fragment ShadeFinalXdrOut shade_final_xdr(SHADE_FINAL_ARGS) { return shadeFinalXdr<false>(in, scene, bloom, depth, bloom0, vlT, vlD, P, f, L, g, sr, skyLut, lutS); }
fragment ShadeFinalXdrOut shade_final_xdr_dims(SHADE_FINAL_ARGS) { return shadeFinalXdr<true>(in, scene, bloom, depth, bloom0, vlT, vlD, P, f, L, g, sr, skyLut, lutS); }
fragment ShadeFinalXdrOut shade_final_xdr_lean(SHADE_FINAL_ARGS) { return shadeFinalXdr<false, true>(in, scene, bloom, depth, bloom0, vlT, vlD, P, f, L, g, sr, skyLut, lutS); }

// ---- bridge for mods that draw display-referred colours over the HDR world (Distant Horizons) ---------------------------
fragment float4 shade_bridge_encode(ShadeFsOut in [[stage_in]], texture2d<half> scene [[texture(0)]], constant ShadeLook &L [[buffer(17)]]) {
	float3 c = float3(scene.read(uint2(in.position.xy)).rgb);
	return float4(shadeLinearToSrgbExact(saturate(shadeDisplay(c, L))), 1.0);
}

// The HDR value stays where the mod left the bridge's value untouched (within 1.5 LSB of what encode wrote); elsewhere the
// mod's colour comes in through the inverse display transform, like any unshaded pipeline's.
fragment float4 shade_bridge_decode(ShadeFsOut in [[stage_in]], float4 hdr [[color(0)]], texture2d<half> ldr [[texture(0)]],
                                    constant ShadeLook &L [[buffer(17)]]) {
	float3 now = float3(ldr.read(uint2(in.position.xy)).rgb);
	float3 was = round(shadeLinearToSrgbExact(saturate(shadeDisplay(hdr.rgb, L))) * 255.0) / 255.0;
	if (all(abs(now - was) < 1.5 / 255.0)) return hdr;
	return float4(shadeLdrToHdr(now, L), hdr.a);
}

// ---- auto-exposure (E20) -------------------------------------------------------------------------------------------------
#define SHADE_HIST_MIN -14.0
#define SHADE_HIST_MAX 8.0

kernel void shade_histogram(texture2d<half> src [[texture(0)]], device ShadeGpu &g [[buffer(18)]], uint2 id [[thread_position_in_grid]],
                            uint lid [[thread_index_in_threadgroup]]) {
	threadgroup atomic_uint bins[64];
	if (lid < 64) atomic_store_explicit(&bins[lid], 0u, memory_order_relaxed);
	threadgroup_barrier(mem_flags::mem_threadgroup);
	uint w = src.get_width(), h = src.get_height();
	// (2.0.1 opt) 2x2 rotating strided grid dispatched at ((w+1)/2, (h+1)/2) + log2 subtraction instead of division per thread
	uint phase = uint(g.scene.w) & 3u;
	uint2 p = id * 2u + uint2(phase & 1u, (phase >> 1u) & 1u);
	if (p.x < w && p.y < h) {
		float logEx = log2(max(g.exposure.x, 1e-6));
		float logLum = log2(max(float(shadeLumaH(src.read(p).rgb)), 1e-7)) - logEx;
		float t = (logLum - SHADE_HIST_MIN) * (1.0 / (SHADE_HIST_MAX - SHADE_HIST_MIN));
		uint bin = uint(clamp(t * 64.0, 0.0, 63.0));
		float2 r = (float2(p) + 0.5) / float2(w, h) - 0.5;
		float weight = exp(-dot(r, r) * (1.0 / 0.3));
		// (FT2.8, audit idx 53: no "hand's corner" de-weight: in GL row order r.y > 0.2 is the TOP right, usually sky, and the hand is
		// drawn after the final pass, never in this image)
		atomic_fetch_add_explicit(&bins[bin], uint(weight * 16.0 + 0.5), memory_order_relaxed);
	}
	threadgroup_barrier(mem_flags::mem_threadgroup);
	if (lid < 64) {
		uint v = atomic_load_explicit(&bins[lid], memory_order_relaxed);
		if (v != 0) atomic_fetch_add_explicit((device atomic_uint *)&g.histogram[lid], v, memory_order_relaxed);
	}
}

kernel void shade_exposure(device ShadeGpu &g [[buffer(18)]], constant ShadeLook &L [[buffer(17)]], uint id [[thread_position_in_grid]]) {
	if (id != 0) return;
	float total = 0.0;
	for (int i = 0; i < 64; i++) total += float(g.histogram[i]);
	float logRef = log2(max(L.exposureRef.x, 1e-6)) + L.grade0.x;
	float target = logRef;
	float mean = g.scene.x;
	if (total > 0.0) {
		// Current meters the 40th..92nd percentiles. Natural includes more bright window detail,
		// still ignoring the brightest 2% (sun/small emissives) and the darkest pockets.
		float upper = L.user3.x > 0.0 ? mix(0.92, 0.98, min(L.user3.x, 1.0)) : 0.92;
		float lo = total * 0.40, hi = total * upper, acc = 0.0, sum = 0.0, wsum = 0.0;
		for (int i = 0; i < 64; i++) {
			float n = float(g.histogram[i]);
			float a = max(lo - acc, 0.0), b = min(hi - acc, n);
			float take = max(b - a, 0.0);
			float l = SHADE_HIST_MIN + (float(i) + 0.5) / 64.0 * (SHADE_HIST_MAX - SHADE_HIST_MIN);
			sum += take * l;
			wsum += take;
			acc += n;
		}
		if (wsum > 0.0) mean = sum / wsum;
		float metered = log2(max(L.exposureRef.z, 1e-4)) - mean;
		float lambda = L.exposureRef.y;
		target = lambda * metered + (1.0 - lambda) * logRef;
		target = clamp(target, logRef - L.exposureCfg.x, logRef + L.exposureCfg.y);
	}
	float now = log2(max(g.exposure.x, 1e-6));
	float next;
	if (L.exposureRef.w > 0.5 || !(now > -30.0 && now < 30.0)) {
		next = target;
	} else {
		float tau = target > now ? L.exposureCfg.z : L.exposureCfg.w;
		next = now + (target - now) * (1.0 - exp(-L.dt.x / max(tau, 1e-3)));
	}
	g.exposure = float4(exp2(next), exp2(target), g.exposure.x, next);
	g.scene.x = mean;
	g.scene.w += 1.0;
	for (int i = 0; i < 64; i++) g.histogram[i] = 0u;
}

// ---- the Milky Way (E04), baked once into an equirectangular texture in galactic longitude/latitude ---------------------
static float shadeValueNoise(float3 x, uint salt) {
	float3 i = floor(x), fr = x - i;
	float3 u = fr * fr * (3.0 - 2.0 * fr);
	int3 c = int3(i);
	float n000 = shadeHash01(shadeHash3(c, salt)), n100 = shadeHash01(shadeHash3(c + int3(1, 0, 0), salt));
	float n010 = shadeHash01(shadeHash3(c + int3(0, 1, 0), salt)), n110 = shadeHash01(shadeHash3(c + int3(1, 1, 0), salt));
	float n001 = shadeHash01(shadeHash3(c + int3(0, 0, 1), salt)), n101 = shadeHash01(shadeHash3(c + int3(1, 0, 1), salt));
	float n011 = shadeHash01(shadeHash3(c + int3(0, 1, 1), salt)), n111 = shadeHash01(shadeHash3(c + int3(1, 1, 1), salt));
	return mix(mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y), mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y), u.z);
}
static float shadeFbm(float3 x, int octaves, uint salt) {
	float s = 0.0, a = 0.5, n = 0.0;
	for (int i = 0; i < octaves; i++) {
		s += a * shadeValueNoise(x, salt + uint(i) * 101u);
		n += a;
		x = x * 2.03 + 17.1;
		a *= 0.5;
	}
	return s / n;
}

fragment half4 shade_milkyway_bake(ShadeFsOut in [[stage_in]]) {
	float lon = (in.uv.x - 0.5) * 6.2831853, lat = (in.uv.y - 0.5) * 3.1415927;
	float3 dir = float3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat));
	float lc = abs(lon);                       // angle to the galactic centre (at lon 0)
	float b = abs(lat) * 57.29578, l = lc * 57.29578;
	float disc = exp(-b / (3.0 + 3.0 * pow(cos(lon * 0.5), 2.0))) * (0.6 + 0.4 * shadeFbm(dir * 6.0, 4, 11u));
	float bulge = 2.2 * exp(-(l * l / 144.0 + b * b / 36.0));
	float dust = 1.0 - 0.75 * (1.0 - abs(2.0 * shadeFbm(dir * 9.0, 3, 23u) - 1.0)) * exp(-b / 2.0);
	float clouds = 0.3 * pow(shadeFbm(dir * 40.0, 2, 37u), 4.0) * exp(-b / 8.0);
	float v = (disc + bulge) * dust + clouds;
	float3 col = mix(float3(1.0, 0.86, 0.66), float3(0.74, 0.82, 1.0), saturate(l / 70.0));
	// alpha (M3): a tileable fbm over the texture for the sky effects (shade_dims.metal shadeDimsNoise: aurora, End nebula
	// and beams, Nether fog, media), so they need no texture of their own
	return half4(half3(col * v * 0.035), half(shadeDimsBakeNoise(in.uv)));
}

// ---- output resolution (2026-10-09, ShadeOutput) -------------------------------------------------------------------------
// The final pass's image at the chosen output size (display-referred RGBA8, the same encoding as the window's target) -> the
// window: Catmull-Rom from 5 bilinear reads (the 9-tap trick with the corner taps dropped, after Matt Pettineo's gist, MIT, as
// taa.metal's history fetch), clamped to the range of the 2x2 texels around (no ringing at hard edges: block outlines, the
// sun's disc), then a contrast-limited sharpen over the 4 neighbouring texels (like shadeSharpen: less where the contrast is
// already high, never past the neighbourhood). P.x: sharpen amount; alpha (XDR: 0, the hand and GUI draw over it) passes through.
fragment float4 shade_upscale(ShadeFsOut in [[stage_in]], texture2d<float> src [[texture(0)]], constant float4 &P [[buffer(0)]]) {
	float2 size = float2(src.get_width(), src.get_height()), inv = 1.0 / size;
	float2 sp = in.uv * size;
	float2 t1 = floor(sp - 0.5) + 0.5;
	float2 fr = sp - t1;
	float2 w0 = fr * (-0.5 + fr * (1.0 - 0.5 * fr));
	float2 w1 = 1.0 + fr * fr * (-2.5 + 1.5 * fr);
	float2 w2 = fr * (0.5 + fr * (2.0 - 1.5 * fr));
	float2 w3 = fr * fr * (-0.5 + 0.5 * fr);
	float2 w12 = w1 + w2;
	float2 t0 = (t1 - 1.0) * inv, t3 = (t1 + 2.0) * inv, t12 = (t1 + w2 / w12) * inv;
	float4 a = src.sample(shadeLinearClamp, float2(t12.x, t0.y)), b = src.sample(shadeLinearClamp, float2(t0.x, t12.y));
	float4 c = src.sample(shadeLinearClamp, t12), d = src.sample(shadeLinearClamp, float2(t3.x, t12.y));
	float4 e = src.sample(shadeLinearClamp, float2(t12.x, t3.y));
	float wa = w12.x * w0.y, wb = w0.x * w12.y, wc = w12.x * w12.y, wd = w3.x * w12.y, we = w12.x * w3.y;
	float3 cr = (a.rgb * wa + b.rgb * wb + c.rgb * wc + d.rgb * wd + e.rgb * we) / (wa + wb + wc + wd + we);
	// the 2x2 texels around this pixel: the range the result may span
	float2 base = t1 * inv;
	float3 q0 = src.sample(shadeLinearClamp, base).rgb, q1 = src.sample(shadeLinearClamp, base + float2(inv.x, 0.0)).rgb;
	float3 q2 = src.sample(shadeLinearClamp, base + float2(0.0, inv.y)).rgb, q3 = src.sample(shadeLinearClamp, base + inv).rgb;
	float3 lo = min(min(q0, q1), min(q2, q3)), hi = max(max(q0, q1), max(q2, q3));
	cr = clamp(cr, lo, hi);
	// contrast-limited sharpen against the 4-neighbour mean one source texel away
	float3 n = src.sample(shadeLinearClamp, in.uv + float2(0.0, inv.y)).rgb, s = src.sample(shadeLinearClamp, in.uv - float2(0.0, inv.y)).rgb;
	float3 ea = src.sample(shadeLinearClamp, in.uv + float2(inv.x, 0.0)).rgb, wv = src.sample(shadeLinearClamp, in.uv - float2(inv.x, 0.0)).rgb;
	float3 nlo = min(lo, min(min(n, s), min(ea, wv))), nhi = max(hi, max(max(n, s), max(ea, wv)));
	float range = dot(nhi - nlo, float3(0.2126, 0.7152, 0.0722)) / max(dot(nhi, float3(0.2126, 0.7152, 0.0722)), 0.02);
	float k = P.x * 2.0 * (1.0 - smoothstep(0.15, 0.9, range));
	float3 o = clamp(cr + (cr - (n + s + ea + wv) * 0.25) * k, nlo, nhi);
	return float4(o, c.a);
}
