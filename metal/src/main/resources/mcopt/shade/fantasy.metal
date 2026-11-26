// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// The Fantasy style's optional painterly brush (mcopt.metal.shade.ShadePainterly; mcopt.shade.fantasy.painterly, 0 by
// default: with 0 the passes are never encoded on the command encoder, so it costs nothing). Two full-screen passes over the
// HDR world, after the TAA resolve and before bloom, so the strokes are painted in scene radiance and the tone map keeps
// their shapes:
//
//   shade_painterly_tensor  half size: the structure tensor of the luminance, smoothed (its xy = the double-angle vector, z =
//                           anisotropy 0..1: how edge-like the neighbourhood is). Gives the brush its orientation and how far
//                           to stretch it (round in flat regions such as the sky, an ellipse along an edge).
//   shade_painterly         8-sector oriented Kuwahara: an elliptical neighbourhood turned by the tensor's angle, divided into
//                           8 overlapping wedges; each wedge's mean colour is weighted by 1 / (1 + (variance x k)^q), so the
//                           flat side of every edge wins. The result reads as broad painted strokes instead of the 4-square
//                           mosaic of a plain Kuwahara. A little paper grain on top. The brush shrinks with distance so far
//                           hillsides stay readable; the sky (no depth) keeps a small brush, which is what paints the clouds.
//
// The technique (Kuwahara filtering, its anisotropic generalisation and the structure tensor) is public: Kuwahara et al. 1976;
// the anisotropic/oriented generalisation follows the painterly post-processing literature, e.g. Kyprianidis, "Image and Video
// Abstraction" (Computers & Graphics 2010). This Metal implementation is original.
#ifndef MCOPT_SHADE_FANTASY
#define MCOPT_SHADE_FANTASY
#include <metal_stdlib>
using namespace metal;

// 6 taps per wedge: 48 texture reads per pixel. Kept small on purpose: Apple GPUs lose occupancy quickly with long loops of
// dependent texture reads, and a wedge's mean converges fast (the weighting is one scalar per wedge).
#define SHADE_PAINT_TAPS 6
#define SHADE_PAINT_SECTORS 8

struct ShadePaintOut { float4 position [[position]]; float2 uv; };

vertex ShadePaintOut shade_painterly_vs(uint vid [[vertex_id]]) {
	ShadePaintOut o;
	float2 p = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);
	o.position = float4(p, 0.0, 1.0);
	o.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5); // GL row order, as everywhere in the post chain
	return o;
}

constexpr sampler shadePaintClamp(filter::linear, address::clamp_to_edge);

static inline float shadePaintLuma(texture2d<half> src, float2 uv) {
	return float(dot(float3(src.sample(shadePaintClamp, uv).rgb), float3(0.2126, 0.7152, 0.0722)));
}

// p: x = 1 / source width, y = 1 / source height (the HDR image's texel size). Runs at half the source's size.
fragment half4 shade_painterly_tensor(ShadePaintOut in [[stage_in]], texture2d<half> src [[texture(0)]],
                                      constant float4 &p [[buffer(0)]]) {
	// the gradient of the luminance at 4 neighbours, its outer products averaged over a 3x3 of this half-size grid (each step
	// is two texels of the source): the tensor smoothed over ~6 source texels, stable across a stroke
	float2 o = p.xy * 2.0;
	float sumXX = 0.0, sumYY = 0.0, sumXY = 0.0;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			float2 c = in.uv + float2(float(i), float(j)) * o;
			float lx = (shadePaintLuma(src, c + float2(o.x, 0.0)) - shadePaintLuma(src, c - float2(o.x, 0.0))) * 0.5;
			float ly = (shadePaintLuma(src, c + float2(0.0, o.y)) - shadePaintLuma(src, c - float2(0.0, o.y))) * 0.5;
			sumXX += lx * lx;
			sumYY += ly * ly;
			sumXY += lx * ly;
		}
	}
	float tr = sumXX + sumYY;
	float diff = sumXX - sumYY, off = 2.0 * sumXY;
	// 1 for a clean edge (one gradient direction), 0 for a flat patch or isotropic noise
	float aniso = tr > 1e-9 ? clamp(sqrt(diff * diff + off * off) / tr, 0.0, 1.0) : 0.0;
	// Store the double-angle vector NORMALISED. diff and off grow with the square of the luminance gradient, so a bright
	// specular highlight (radiance in the thousands) pushes them past half precision's 65504: the target is RGBA16F and
	// the overflow is stored as +inf, atan2(inf, inf) is NaN, and the NaN angle turns the whole pixel into garbage that
	// reads as colour noise. Dividing by tr first keeps xy on the unit circle (only the direction and aniso are used).
	// A flat patch writes (0, 0) here on purpose (inv is 0); the paint pass reads that as "no edge". tr is NaN when a tap
	// was Inf/NaN, and NaN > 1e-9 is false, so this yields (NaN*0, NaN*0) = NaN: guard the trace so a corrupt texel can
	// only cost this patch its orientation, never emit a NaN that the paint pass would sample with.
	if (!(tr > 1e-9)) return half4(half3(0.0h), 0.0h);
	float inv = 1.0 / tr;
	return half4(half3(diff * inv, off * inv, aniso), 0.0h);
}

// p: x brush radius (px), y painterly strength 0..1, z paper grain 0..1, w the distance (blocks) where the brush has shrunk to
// its smallest (farther terrain is not painted). q: xy the live part of the depth texture this image maps into (TAAU: the
// scene is the output-size history, the depth this frame's live sub-rect). Writes pre-exposed radiance, like the image it reads.
struct ShadePaintParams { float4 p; float4 q; };

fragment float4 shade_painterly(ShadePaintOut in [[stage_in]], texture2d<half> hdr [[texture(0)]], texture2d<half> tensor [[texture(1)]],
                                depth2d<float> depth [[texture(2)]], constant ShadePaintParams &P [[buffer(0)]],
                                constant ShadeFrame &f [[buffer(16)]], constant ShadeLook &L [[buffer(17)]]) {
	float3 base = float3(hdr.sample(shadePaintClamp, in.uv).rgb);
	float strength = saturate(P.p.y);
	if (strength <= 0.0) return float4(base, 1.0);
	// this pixel's scene distance (blocks); the sky (no depth, reversed Z: 0) gets the far value, so its clouds take a small brush.
	// Under TAAU the depth is this frame's jittered raster (shade_post.metal: the pixel's scene point sits half a jitter further on)
	float2 dsize = float2(depth.get_width(), depth.get_height());
	float2 duv = P.q.w > 0.5 ? clamp(in.uv + 0.5 * f.jitter.xy, 0.0, 1.0) : in.uv;
	float d = depth.read(uint2(min(duv * P.q.xy * dsize, dsize - 1.0)));
	float dist = 1e4;
	if (d > 0.0) {
		float4 w = f.invViewProj * float4(in.uv * 2.0 - 1.0, d, 1.0);
		dist = length(w.xyz / w.w);
	}
	half4 tn = tensor.sample(shadePaintClamp, in.uv);
	// A zero double-angle vector means "no edge" (a flat patch, the common case: the tensor writes 0/0 when its 3x3 gradient
	// trace is under 1e-9, and also for a corrupt texel). atan2(0, 0) is NaN on Apple GPUs, and a NaN angle poisons the whole
	// pixel: NaN reaches the tap offsets, and sampling with a NaN coordinate returns the texture's CORNER texel. A flat region
	// therefore painted with whatever sat in that corner (measured: a dark 0.002 cave whose corner texel was white came out
	// solid white; a red corner, red), and it changed with the camera as that corner's content moved. isfinite also covers a
	// NaN tensor from a corrupt scene texel. No edge: 0 is a stable, arbitrary orientation for a circular brush.
	float2 dbl = float2(tn.x, tn.y);
	float angle = length(dbl) > 1e-6 ? 0.5 * atan2(dbl.y, dbl.x) : 0.0;
	float aniso = clamp(float(tn.z), 0.0, 1.0);
	// (Apple tip: keep the brush small and let it shrink with distance: a few dependent reads stay cheap, occupancy stays high)
	float radius = P.p.x * mix(1.0, 0.55, smoothstep(P.p.w * 0.3, P.p.w, dist));
	float a = radius * (1.0 + aniso);       // along the edge
	float b = radius / (1.0 + 0.6 * aniso); // across it
	float ca = cos(angle), sa = sin(angle);
	float2 texel = 1.0 / float2(hdr.get_width(), hdr.get_height());
	float3 outColor = float3(0.0);
	float totalW = 0.0;
	for (int k = 0; k < SHADE_PAINT_SECTORS; k++) {
		float centre = (float(k) + 0.5) * (6.2831853 / float(SHADE_PAINT_SECTORS));
		float3 mean = float3(0.0), sq = float3(0.0);
		for (int i = 0; i < SHADE_PAINT_TAPS; i++) {
			// inside the wedge: a small fan of angles, radii on a sqrt ramp so the stroke's outer part is covered too
			float t0 = (float(i) + 0.5) * (1.0 / float(SHADE_PAINT_TAPS));
			float ang = centre + (t0 - 0.5) * (0.8 * 6.2831853 / float(SHADE_PAINT_SECTORS));
			float r = sqrt(t0);
			float2 local = float2(cos(ang), sin(ang)) * r;
			float2 off = float2(local.x * a * ca - local.y * b * sa, local.x * a * sa + local.y * b * ca) * texel;
			float3 s = float3(hdr.sample(shadePaintClamp, in.uv + off).rgb);
			// A non-finite texel (the HDR target can hold Inf/NaN: half overflow near 30000, a bad resolve) must not enter the
			// statistics. Apple's min()/max() return the SECOND operand when the first is NaN, so min(Inf, 30000) is 30000 and
			// min(NaN, 30000) is also 30000: a corrupt texel would read as a legitimate white sample, the wedge's variance would
			// blow up, and the painted result became a bright blotch (measured 5796 out of a flat 0.002 cave). Selecting on a
			// finite test instead of clamping drops the sample to the pixel's own value, which is what the neighbouring wedges
			// are made of, so a corrupt texel only costs a little smoothness.
			float3 c = all(isfinite(s)) ? min(s, float3(30000.0)) : base;
			mean += c;
			sq += c * c;
		}
		mean *= 1.0 / float(SHADE_PAINT_TAPS);
		sq *= 1.0 / float(SHADE_PAINT_TAPS);
		float3 v = max(sq - mean * mean, float3(0.0));
		float sigma2 = v.r + v.g + v.b;
		// The variance is ABSOLUTE (the technique's own weighting), clamped before the pow so a bright patch cannot overflow
		// the exponent into Inf. An earlier attempt divided it by the wedge's mean^2 to make the weight contrast-relative;
		// that broke the dark end: with a floor of 1e-4 the mean^2 of a cave pixel (4e-6) is swamped 25x, so the "relative"
		// form silently fell back to an absolute one scaled 3000x larger, which flattened every dark wedge to weight ~1 and
		// passed single bright texels through untouched instead of averaging them away (the opposite of what the brush is for).
		float t = min(sigma2 * 1000.0, 1e4);
		// q = 4 (the technique's sharpness): a flat wedge (a stroke's inside) wins over one that straddles an edge
		float wgt = 1.0 / (1.0 + pow(t, 4.0));
		outColor += mean * wgt;
		totalW += wgt;
	}
	// If every wedge is high-contrast the weights all vanish; fall back to the unpainted pixel instead of dividing by zero.
	float3 painted = totalW > 1e-6 ? outColor / totalW : base;
	float3 c = mix(base, painted, strength);
	// a little paper grain, gated by the luminance so the shadows stay soft: a hash per pixel and a slow fibre wave
	uint h = shadeHash(uint(in.position.x) * 1973u ^ uint(in.position.y) * 9277u ^ 0x9e3779b9u);
	float paper = (shadeHash01(h) - 0.5) * 0.030;
	float fibre = sin(in.position.x * 0.9 + in.position.y * 0.35) * sin(in.position.x * 0.13 - in.position.y * 0.7) * 0.012;
	float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
	c *= 1.0 + (paper + fibre) * P.p.z * strength * saturate(lum * 4.0);
	return float4(max(c, float3(0.0)), 1.0);
}

#endif
