// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// M2 shading functions, loaded after shade_look.metal and shade_common.metal (ShadeMsl.prelude):
//   - output: shadeOut / shadeFinish2 write pre-exposed linear radiance when the pipeline is built for the HDR world target
//     (MCOPT_HDR, defined by the format adapter for those variants), else M1's tone curve into RGBA8;
//   - lighting model v2 (shadeLit2), PCSS-lite shadows (shadeShadow2), height haze + mist + border fog (shadeFogAir2),
//   - the sky: procedural sun disc and aureole, moon with phases, stars and the Milky Way (shadeSkyColor2).
// Everything here is original (techniques: Lottes 2016, Hillaire 2015, Jimenez 2014 IGN, Neckel & Labs limb darkening,
// Lommel-Seeliger, Planck's law; see the bible's E01-E09). The integer hash is Chris Wellons' "lowbias32" (public domain).
#ifndef MCOPT_SHADE_M2
#define MCOPT_SHADE_M2

// ---- small utilities --------------------------------------------------------------------------------------------------
static inline uint shadeHash(uint x) { // lowbias32 (C. Wellons, public domain)
	x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16;
	return x;
}
static inline float shadeHash01(uint x) { return float(shadeHash(x) >> 8) * (1.0 / 16777216.0); }
static inline uint shadeHash3(int3 c, uint salt) {
	return shadeHash(uint(c.x) * 0x8da6b343u ^ shadeHash(uint(c.y) * 0xd8163841u ^ shadeHash(uint(c.z) * 0xcb1ab31fu ^ salt)));
}
static inline bool shadeFeature(constant ShadeLook &L, int bit) { return (L.tier.y & bit) != 0; }

// Henyey-Greenstein phase (1/sr).
static inline float shadeHG(float mu, float g) {
	float g2 = g * g;
	float x = max(1.0 + g2 - 2.0 * g * mu, 1e-4);
	return 0.0795775 * (1.0 - g2) / (x * sqrt(x)); // x^1.5 without pow's log and exp (2026-10-08: the haze runs it per pixel)
}

// ---- output ---------------------------------------------------------------------------------------------------------------
// The exposure shaded radiance is scaled by: the GPU's auto-exposure in the HDR target (ShadeGpu.exposure.x, last frame's
// result), M1's CPU exposure in the RGBA8 path.
static inline float shadeExposure(constant ShadeFrame &f, constant ShadeGpu &g) {
#ifdef MCOPT_HDR
	return g.exposure.x;
#else
	return f.time.z;
#endif
}

// Shaded radiance (linear, not yet exposed) -> what the target stores: pre-exposed radiance (HDR) or M1's tone-mapped sRGB.
static inline float3 shadeOut(float3 radiance, constant ShadeFrame &f, float ex) {
#ifdef MCOPT_HDR
	return min(max(radiance, 0.0) * ex, 60000.0);
#else
	return shadeOutput(radiance, f);
#endif
}

// A display-referred (sRGB, vanilla-lit) colour -> what the target stores.
static inline float3 shadeVanillaOut(float3 srgb, constant ShadeLook &L) {
#ifdef MCOPT_HDR
	return shadeLdrToHdr(srgb, L);
#else
	return srgb;
#endif
}

// shadeFinish for both targets: exposure (+ tone curve in RGBA8), then the game's own fog colour where it applies.
static inline float3 shadeFinish2(float3 radiance, float vanillaFog, constant ShadeFrame &f, constant ShadeLook &L, float ex) {
#ifdef MCOPT_HDR
	float3 c = shadeOut(radiance, f, ex);
	float a = vanillaFog * f.fogColor.a;
	if (a <= 0.0) return c;
	float3 t = f.flags.y == 1 ? pow(1.0 - a, float3(2.6, 1.25, 1.0)) : float3(1.0 - a);
	return c * t + shadeLdrToHdr(f.fogColor.rgb, L) * (1.0 - t);
#else
	return shadeFinish(radiance, vanillaFog, f);
#endif
}

// ---- lighting model v2 (E09 steps 1-7, 11) -------------------------------------------------------------------------------
// M1's directional sky light and foliage terms, plus: a slight wrap on the sun term, the art layer's ambient tint, a warm
// fill in shadow (light bounced off the sunlit surroundings), a broader block-light curve (hot core, long tail) that fades a
// little by day, a cool minimum light in caves, and a gentle east/west face separation for readability. Light levels 0..1.
// (1.2.9 candidate 4) How much of the new look's two close-up terms (the foliage sheen and the side faces' darkening) a fragment at
// camera-relative p gets: all of it up to half of look2a.w blocks, none past look2a.w (0 = everywhere, candidate 3). On far
// hillsides the two made every terrace's sunlit top and its grass tufts stand out as bright lines over darkened sides ("el borde
// superior de los bloques a lo lejos se ve como que brilla", Gael 2026-11-23: top/median luminance 1.52 against 1.34 in 1.2.8).
static inline float shadeLook2Near(float3 p, constant ShadeLook &L) {
	return L.look2a.w > 0.0 ? 1.0 - smoothstep(0.5 * L.look2a.w, L.look2a.w, length(p)) : 1.0;
}

static float3 shadeLit2(half3 albedo, half3 n, half sky, half block, half shadow, bool thin, bool foliage, constant ShadeFrame &f,
                        constant ShadeLook &L, float look2Near = 1.0) {
	if (!shadeFeature(L, SHADE_FEATURE_LIGHT_V2)) return shadeLit(albedo, n, sky, block, shadow, thin, foliage, f);
	float3 Ld = f.lightDirWorld.xyz;
	half nl = half(dot(float3(n), Ld));
	half ndl = thin ? half(0.3) + half(0.5) * abs(nl)
		: foliage ? half(0.25) + half(0.75) * saturate(nl) + half(0.5 * L.user0.z) * saturate(-nl) // (1.1) user0.z: leaves' light through them
		: (nl > half(0.0) ? (nl + half(0.08)) / half(1.08) : half(0.0));
	half gate = f.flags.z != 0 ? smoothstep(half(0.3), half(0.8), sky) : sky * sky * sky * sky;
	half3 sun = half3(f.sunColor.xyz);
	half3 direct = sun * (ndl * shadow * gate);
	float2 axis = shadeSkyAxis(f);
	half towardSun = half(dot(float2(n.xz), axis)) * half(0.5) + half(0.5);
	half3 side = mix(half3(f.ambientAway.xyz), half3(f.ambientToward.xyz), towardSun);
	half3 ambient = n.y >= half(0.0) ? mix(side, half3(f.ambientSky.xyz), n.y) : mix(side, half3(f.ambientGround.xyz), -n.y);
	half g = shadeSkyCurve(sky);
	ambient *= g * (foliage ? half(1.0 + 0.35 * L.user0.z) : half(1.0)) * half3(L.ambientArt.rgb);
	// warm fill where the sun doesn't reach: what the sunlit ground and walls around bounce back
	half3 fill = sun * (half(L.ambientArt.w) * (half(1.0) - shadow * saturate(nl)) * g * g * gate) * half3(L.bounce.rgb);
	// block light: F(b) = 2.2 b^7 + 0.55 b^2.4 (normalized to 1 at b = 1), a little weaker in daylight
	// (2.0.1 opt) outdoor pixels with block == 0 skip pow(block, 2.4) + smoothstep completely (exact in FP16)
	half3 torch = half3(0.0h);
	if (block > half(0.0)) {
		half b7 = block * block * block; b7 = b7 * b7 * block;
		half F = (half(2.2) * b7 + half(0.55) * pow(max(block, half(1e-3)), half(2.4))) * half(1.0 / 2.75);
		half day = half(saturate(f.sunDirWorld.w * 4.0 + 0.2));
		torch = half3(f.ambientBlock.xyz) * F * (half(1.0) - half(0.25) * smoothstep(half(0.5), half(1.0), sky) * day);
	}
	half3 minimum = half(f.ambientBlock.w) * mix(half3(0.9h, 1.0h, 1.38h), half3(1.0h), g); // caves: a cool floor
	if (L.user3.x > 0.0) {
		// Use the surface's skylight, never the camera's: a bright garden seen through a doorway stays bright.
		// Open shade retains sky fill; enclosed surfaces lose more of the artistic ambient and bounce.
		half natural = half(min(L.user3.x, 1.0));
		ambient *= mix(half(1.0), mix(half(0.45), half(0.85), g), natural);
		fill *= mix(half(1.0), mix(half(0.35), half(0.65), g), natural);
		minimum *= mix(half(1.0), half(0.65), natural);
		if (L.user3.x > 1.0) {
			// Above the original Natural look, use another positive attenuation rather than extrapolate
			// the first blend through zero. Torch light and direct sun visibility remain intact.
			half extra = half(L.user3.x - 1.0);
			ambient *= mix(half(1.0), mix(half(0.65), half(0.90), g), extra);
			fill *= mix(half(1.0), mix(half(0.60), half(0.85), g), extra);
			minimum *= mix(half(1.0), half(0.75), extra);
		}
	}
	if (SHADE_CAMERA_UNDERWATER(f)) { // the camera is under water: daylight arrives filtered by the water above
		direct *= half3(0.22h, 0.5h, 0.62h);
		ambient *= half3(0.35h, 0.62h, 0.8h);
		fill *= half3(0.3h, 0.55h, 0.7h);
	}
	half face = half(1.0) - half(0.06) * abs(n.x) * (half(1.0) - abs(n.y));
	if (L.look2a.y > 0.0 && !thin) face *= half(1.0 - L.look2a.y * look2Near * (1.0 - abs(float(n.y)))); // (1.2.9 look pass) side faces darker
	float3 lit = float3(albedo) * float3((direct + ambient + fill + torch + minimum) * face);
	// (1.2.9 look pass, Look2 sheen; ShadeLook.look2a.x, 0 = 1.2.8) plants and leaves against the sun: light scattered forward through
	// the thin blades, in the light's colour partly tinted by the plant's own hue (look2a.z: a yellow-green glow), plants x1, leaves x0.5
	if ((thin || foliage) && L.look2a.x > 0.0 && !SHADE_CAMERA_UNDERWATER(f))
		lit += float3(sun) * mix(float3(1.0), saturate(float3(albedo) / max(dot(float3(albedo), float3(0.2126, 0.7152, 0.0722)), 0.02)) , L.look2a.z)
			* (L.look2a.x * look2Near * float(shadow * gate) * (thin ? 1.0 : 0.5));
	return lit;
}

// (1.2.8, issue #61) shadeLit2's sun term alone (the same terms: keep the two in step): what the caustics under water modulate.
static half3 shadeLit2Direct(half3 n, half sky, half shadow, bool thin, bool foliage, constant ShadeFrame &f, constant ShadeLook &L) {
	if (!shadeFeature(L, SHADE_FEATURE_LIGHT_V2)) return half3(0.0h);
	half nl = half(dot(float3(n), f.lightDirWorld.xyz));
	half ndl = thin ? half(0.3) + half(0.5) * abs(nl)
		: foliage ? half(0.25) + half(0.75) * saturate(nl) + half(0.5 * L.user0.z) * saturate(-nl)
		: (nl > half(0.0) ? (nl + half(0.08)) / half(1.08) : half(0.0));
	half gate = f.flags.z != 0 ? smoothstep(half(0.3), half(0.8), sky) : sky * sky * sky * sky;
	half3 direct = half3(f.sunColor.xyz) * (ndl * shadow * gate);
	if (SHADE_CAMERA_UNDERWATER(f)) direct *= half3(0.22h, 0.5h, 0.62h);
	return direct * (half(1.0) - half(0.06) * abs(n.x) * (half(1.0) - abs(n.y)));
}

// Caustic focusing (1 = none) at world xz x (wrapped, as water.metal's shadeWaterXZ) under kk = depth x wave strength: the sun's
// rays bent by the waves' curvature bunch together or spread apart; the light per area is the inverse Jacobian of the refraction
// mapping, 1 / |det(I + kk Hessian(h))|, on a set of short waves of its own (well spread directions, each warping the next:
// irregular cells, not a lattice). t: the water clock (ShadeFrame.sunPath.w). Shared by the bottom seen through the surface
// (water.metal shadeWaterCaustics) and, from 1.2.8, the bottom seen from under water (terrain_own.metal).
#define SHADE_CAUSTIC_COUNT 6
// (2.0.1 opt) precomputed caustic wave constants: xy = dir, z = k = 2pi/wl, w = omega (rounded to whole turns/4096s)
constant float4 SHADE_CAUSTIC_K[SHADE_CAUSTIC_COUNT] = {
	float4( 0.940,  0.342, 2.41660973, 2.67833043),
	float4(-0.276,  0.961, 2.99199300, 2.97900703),
	float4( 0.454, -0.891, 3.69599135, 3.31190018),
	float4(-0.866, -0.500, 4.58626664, 3.68928179),
	float4( 0.643,  0.766, 5.66052730, 4.09887836),
	float4(-0.985,  0.174, 7.05975876, 4.57597128),
};
// x = a * k * k, y = a * 14.0, z = phase
constant float3 SHADE_CAUSTIC_A[SHADE_CAUSTIC_COUNT] = {
	float3(0.10512004, 0.2520, 0.0),
	float3(0.13428033, 0.2100, 1.9),
	float3(0.16392423, 0.1680, 3.8),
	float3(0.19982147, 0.1330, 5.7),
	float3(0.24031177, 0.1050, 7.6),
	float3(0.29904116, 0.0840, 9.5),
};

static float shadeCausticFocus(float2 x, float t, float kk) {
	half3 hs = 0.0h; // Hessian: xx, zz, xz
	for (int i = 0; i < SHADE_CAUSTIC_COUNT; i++) {
		float4 w = SHADE_CAUSTIC_K[i];
		float3 a = SHADE_CAUSTIC_A[i];
		float th = w.z * dot(w.xy, x) + w.w * t + a.z;
		float c;
		float s = sincos(th, c);
		half e = exp2(half(s - 1.0) * 1.442695h);
		half q = half(a.x) * half(c * c - s) * e;
		half2 wd = half2(w.xy);
		hs += q * half3(wd.x * wd.x, wd.y * wd.y, wd.x * wd.y);
		x -= w.xy * (c * float(e) * a.y); // strong mutual warping: irregular cells
	}
	float det = (1.0 + kk * float(hs.x)) * (1.0 + kk * float(hs.y)) - kk * kk * float(hs.z) * float(hs.z);
	return min(1.0 / max(abs(det), 0.18), 4.0);
}

// (1.2.8, Gael at 1080p: "caustics only show from under water") How the caustics thin out with the pixel's footprint (blocks per
// pixel): their bright lines (~0.15 block) under ~2 pixels would alias, so first the focus softens (x: the scale of kk, broader and
// dimmer cells, as the pattern blurred), and only much further it fades (y). 1.2.7 faded them out at 0.04-0.12 blocks a pixel: at
// 1080p from ~8 blocks, so from above the water they hardly showed.
static inline float2 shadeCausticLod(float footprint) {
	return float2(1.0 - 0.7 * smoothstep(0.04, 0.16, footprint), 1.0 - smoothstep(0.16, 0.32, footprint));
}

// (1.2.8) The head of water.metal's ShadeWaterParams (fragment buffer 23 on every shaded encoder while the water module runs,
// mcwater.m mc_water_bind), for stages built without the water module: state.y the water surface above the eye (camera-relative,
// under water), state.z wetness, tune.x wave strength, tune.w caustics strength.
struct ShadeWaterHead {
	float4 still, flow, state, tune;
};

// ---- PCSS-lite shadows (E08) ---------------------------------------------------------------------------------------------
// Near cascade: blocker search (2 gathers = 8 depths within the sun's angular radius scaled to 16 blocks), penumbra from the
// mean blocker distance, a Vogel disc of hardware 2x2 PCF taps rotated per pixel (interleaved gradient noise), and contact
// sharpening so tiny penumbrae stay crisp. The far cascade keeps M1's 4-tap tent. Same cascade choice, blend band and receiver
// offsets as M1 (shadeShadow); past the far cascade, sky light stands in for the map.
constant float2 SHADE_VOGEL[16] = {
	float2(0.1768, 0.0000), float2(-0.2263, 0.2072), float2(0.0388, -0.3934), float2(0.2990, 0.3399),
	float2(-0.5175, -0.0889), float2(0.4563, -0.3366), float2(-0.1529, 0.5996), float2(-0.3555, -0.5671),
	float2(0.6847, 0.2108), float2(-0.6649, 0.3468), float2(0.2700, -0.7279), float2(0.3346, 0.7428),
	float2(-0.7958, -0.2903), float2(0.8215, -0.3082), float2(-0.3472, 0.8343), float2(-0.2857, -0.9108)};

// 8 taps of a Vogel disc (golden angle, r = sqrt((i + 0.5) / 8)), each a hardware 2x2 PCF
constant float2 SHADE_VOGEL8[8] = {
	float2(0.2500, 0.0000), float2(-0.3201, 0.2931), float2(0.0549, -0.5564), float2(0.4228, 0.4807),
	float2(-0.7319, -0.1257), float2(0.6453, -0.4760), float2(-0.2162, 0.8480), float2(-0.5028, -0.8020)};
#define SHADE_PCSS_TAPS 8
#define SHADE_PCSS_FAR 40.0 // blocks: PCSS within, M1's tent beyond

static half shadeShadow2(depth2d_array<float> map, sampler cmp, constant ShadeFrame &f, constant ShadeLook &L, float3 p, half3 n, bool thin,
                         bool foliage, float2 pixel, half sky) {
	if (f.flags.z == 0 || shadeDev(f, SHADE_DEV_NO_SHADOW)) return half(1.0);
	if (!shadeFeature(L, SHADE_FEATURE_PCSS)) return shadeShadow(map, cmp, f, p, n, thin);
	float3 Ld = f.lightDirWorld.xyz;
	float nl = thin ? 1.0 : dot(float3(n), Ld);
	if (nl <= 0.0) return half(1.0);
	float tanT = clamp(sqrt(max(1.0 - nl * nl, 0.0)) / max(nl, 0.02), 0.0, 12.0);
	float3 dir = thin ? Ld * 1.5 : float3(n) * 0.75 + Ld * (0.5 + 0.75 * tanT);
	float texelUv = f.shadowParams.x;
	// near cascade
	float4 c = f.shadowViewProj[0] * float4(p + dir * f.cascadeSplits.z, 1.0);
	float m0 = max(abs(c.x), abs(c.y));
	if (c.z <= 0.0 || c.z >= 1.0) m0 = 2.0;
	float nearVis = 1.0;
	float p2 = dot(p, p);
	if (m0 < 1.0 && p2 > SHADE_PCSS_FAR * SHADE_PCSS_FAR) {
		// past PCSS range penumbrae are about a pixel wide: M1's 4-tap tent
		float mm;
		nearVis = shadeShadowCascade(map, cmp, 0u, f.shadowViewProj[0], p, dir * f.cascadeSplits.z, texelUv, 0.75, mm);
		if (m0 < 0.85) return half(nearVis);
	} else if (m0 < 1.0) {
		float2 uv = shadeShadowUV(c.xyz);
		float blocksPerTexel = f.cascadeSplits.z;
		float zBlocks = 1.0 / max(length(float3(f.shadowViewProj[0][0][2], f.shadowViewProj[0][1][2], f.shadowViewProj[0][2][2])), 1e-6);
		float tanSun = tan(L.user0.x * 1.6) * (foliage ? 1.5 : 1.0); // (1.1) user0.x: the sun's radius for the penumbra (user.shadowSoftness), not the disc's
		float searchTex = clamp(tanSun * 16.0 / blocksPerTexel, 1.5, 6.0);
#ifdef SHADE_PCSS_TAA
		// (FT2.8, audit idx 96) a new rotation every frame under TAA (the project's rule, as the water's SSR): a fixed one gave each
		// render pixel the same disc every frame, a screen-locked grain along shadow edges that TAAU converged on instead of averaging
		float rot = shadeNoise(pixel, f.flags2.x) * 6.2831853;
#else
		float rot = shadeNoise(pixel, 0) * 6.2831853;
#endif
		float csX, csY = sincos(rot, csX);
		float2x2 R = float2x2(csX, csY, -csY, csX);
		constexpr sampler pt(filter::nearest, address::clamp_to_edge);
		float2 o = R * float2(0.7, 0.25) * searchTex * texelUv;
		float4 d0 = map.gather(pt, uv + o, 0u);
		float4 d1 = map.gather(pt, uv - o, 0u);
		float4 b0 = select(float4(0.0), float4(1.0), d0 > c.z), b1 = select(float4(0.0), float4(1.0), d1 > c.z);
		float count = dot(b0 + b1, float4(1.0));
		if (count > 0.0) {
			float zb = (dot(d0, b0) + dot(d1, b1)) / count;
			// (1.2.9 candidate 8, ShadeLook.look2b.w = mcopt.shade.shadowMinBlur, blocks; 0 = before) a smallest penumbra: the shadow of
			// something right on the ground (a tuft of grass, a flower) is all contact, so it stayed as sharp as the shadow map and
			// showed the plant's cut-out texture as a jagged dark stain with holes (Gael 2026-11-24: "la sombra se sobrelapa sobre la
			// textura del pasto y se ve raro"). With a floor on the blur its edge is soft and the thin blades and holes average out
			// (a little lighter); shadows cast from higher up already have a wider penumbra and do not change.
			float minTex = min(L.look2b.w / blocksPerTexel, searchTex);
			float wTex = clamp((zb - c.z) * zBlocks * tanSun / blocksPerTexel, max(0.6, minTex), searchTex);
			float s = 0.0;
			for (int i = 0; i < SHADE_PCSS_TAPS; i++) s += map.sample_compare(cmp, uv + R * SHADE_VOGEL8[i] * (wTex * texelUv), 0u, c.z);
			s *= 1.0 / float(SHADE_PCSS_TAPS);
			float k = clamp(2.0 / wTex, 1.0, 3.0);
			nearVis = saturate((s - 0.5) * k + 0.5);
		} else {
			nearVis = map.sample_compare(cmp, uv, 0u, c.z); // nothing nearer the light around: lit, unless right at an edge
		}
		// (FT2.8, audit idx 98) faded into M1's tent over the last 6 blocks before SHADE_PCSS_FAR, not a step: a ring where the
		// shadows' softness dropped 2-3x at 40 blocks
		if (p2 > (SHADE_PCSS_FAR - 6.0) * (SHADE_PCSS_FAR - 6.0)) {
			float lp = sqrt(p2);
			float mt;
			float tent = shadeShadowCascade(map, cmp, 0u, f.shadowViewProj[0], p, dir * f.cascadeSplits.z, texelUv, 0.75, mt);
			nearVis = mix(nearVis, tent, smoothstep(SHADE_PCSS_FAR - 6.0, SHADE_PCSS_FAR, lp));
		}
		if (m0 < 0.85) return half(nearVis);
	}
	float m1;
	float far = shadeShadowCascade(map, cmp, 1u, f.shadowViewProj[1], p, dir * f.cascadeSplits.w, texelUv, 0.5, m1);
	// past the far cascade: sky light says whether it's open (no pop to fully lit)
	far = mix(far, float(smoothstep(half(0.75), half(0.95), sky)), smoothstep(0.85, 1.0, m1));
	return half(m0 >= 1.0 ? far : mix(nearVis, far, smoothstep(0.85, 1.0, m0)));
}

// ---- height haze, mist and border fog (E06) ------------------------------------------------------------------------------
// Optical depth (in blocks at density 1) of a layer with density exp(-max(y - y0, 0) / H) along a ray from absolute height yc,
// unit direction y component dy, length t: closed form, split where the ray crosses the base (full density below it).
static inline float shadeLayerDepth(float yc, float dy, float t, float y0, float H) {
	float y1 = yc + dy * t;
	float lo = min(yc, y1), hi = max(yc, y1);
	if (hi - lo < 1e-3 * max(t, 1.0)) return t * exp(-max(0.5 * (yc + y1) - y0, 0.0) / H);
	float below = clamp(y0 - lo, 0.0, hi - lo);
	float a = max(lo, y0);
	float above = hi > a ? H * (exp(-(a - y0) / H) - exp(-(hi - y0) / H)) : 0.0;
	return (below + above) * t / (hi - lo);
}

// Transmittance of the local haze + mist between the camera and camera-relative p (for fog glow and the VL module).
static inline float3 shadeHazeTransmittance(float3 p, constant ShadeFrame &f, constant ShadeLook &L) {
	float t = length(p);
	float dy = p.y / max(t, 1e-4);
	float yc = f.cameraBlock.y + f.cameraFract.y;
	float dR = shadeLayerDepth(yc, dy, t, L.fogMisc.x, L.fogR.w);
	float dM = shadeLayerDepth(yc, dy, t, L.fogM.z, L.fogM.y);
	return exp(-(L.fogR.rgb * dR + L.fogM.x * dM));
}

// Light scattered toward the camera by the haze (Rayleigh-like, bluish) and the mist (Mie, forward-scattering) between the
// camera and p, and their transmittance: sun (or moon) through the phase function, sky light isotropically, a cheap multiple
// scattering boost, and the evening glow around sunset. sunVis scales the sun term (the VL module owns the shadowed part).
// (FT2.7) shadeHazeInscatterFrom: the same over a segment p that starts yc (absolute height) instead of at the camera.
// (FT2.12) Ssun: the sun's (or moon's) part of what it returns, the glow the VL air mode's shadows may take back out (shade_post.metal)
static float3 shadeHazeInscatterFrom(float3 p, float yc, constant ShadeFrame &f, constant ShadeLook &L, float sunVis, thread float3 &T,
                                     thread float3 &Ssun) {
	float t = length(p);
	float3 v = p / max(t, 1e-4);
	float dR = shadeLayerDepth(yc, v.y, t, L.fogMisc.x, L.fogR.w);
	float dM = shadeLayerDepth(yc, v.y, t, L.fogM.z, L.fogM.y);
	float3 tauR = L.fogR.rgb * dR;
	float tauM = L.fogM.x * dM;
	float3 tau = tauR + tauM;
	T = exp(-tau);
	float nu = dot(v, f.lightDirWorld.xyz);
	float phR = 0.0596831 * (1.0 + nu * nu);
#ifndef SHADE_HAZE_MIE_G
#define SHADE_HAZE_MIE_G 0.76
#endif
	// (FT1.3: 0.5 by default, mcopt.shade.hazeMieG: toward a low sun 0.76 washed far terrain out to cream white, Gael)
	float phM = 0.8 * shadeHG(nu, SHADE_HAZE_MIE_G) + 0.2 * shadeHG(nu, -0.2);
	float airSun = shadeAirSun(L);
	float3 E = f.sunColor.rgb * (3.14159265 * sunVis * airSun); // irradiance from the light (sunColor is light / pi); FT2.10: none in caves
	float3 sky = f.ambientSky.rgb * (0.9 * shadeAirSky(L)); // mean sky radiance (ambientSky ~ irradiance / pi); FT2.9: none in caves
	float glow = 1.0 + L.fogMisc.w; // (ShadeLook: strength x exp(-((sun elevation in degrees + 1) / 2.5)^2), once per frame)
	float aM = L.fogM.w;
	float3 sR = (E * phR + sky) * (1.0 / (1.0 - 0.5));
	// (1.2.9, mcopt.shade.mistSun, ShadeLook.user4.w; 1 = before) the mist's sunlit part times a multiple-scattering gain: Photon's
	// air fog sums four octaves of the sun's scattering (1 + 1/2 + 1/4 + 1/8 = 1.875), so its low-sun mist is warm and sun-coloured,
	// where ours was mostly the sky's blue-grey ambient. Adapted from Photon Shaders by Benjamin Stott ("sixthsurge"), MIT License,
	// commit 26c2906e (LICENSES/MIT-Photon.txt): include/fog/air_fog_vl.glsl (the multiple scattering loop's total)
	float msGain = L.user4.w > 0.0 ? L.user4.w : 1.0;
	float3 sM = (E * phM * glow * msGain + sky) * aM / (1.0 - 0.5 * aM);
	float3 w = (1.0 - T) / max(tau, 1e-6);
	Ssun = w * E * (tauR * (phR * 2.0) + tauM * (phM * glow * msGain * aM / (1.0 - 0.5 * aM)));
	// (FT2.10) what the cave air scatters instead: neutral grey at a share of the minimum cave light (L.eye.x, BSL's "minimum light
	// x 0.5" fog colour, Photon's faint dark cave fog), so far walls fade into the cave's darkness, never into a tint
	float cave = (1.0 - airSun) * L.eye.x * f.ambientBlock.w;
	return w * (tauR * sR + tauM * sM) + (1.0 - T) * cave;
}
static float3 shadeHazeInscatterFrom(float3 p, float yc, constant ShadeFrame &f, constant ShadeLook &L, float sunVis, thread float3 &T) {
	float3 Ssun;
	return shadeHazeInscatterFrom(p, yc, f, L, sunVis, T, Ssun);
}
static float3 shadeHazeInscatter(float3 p, constant ShadeFrame &f, constant ShadeLook &L, float sunVis, thread float3 &T) {
	return shadeHazeInscatterFrom(p, f.cameraBlock.y + f.cameraFract.y, f, L, sunVis, T);
}
static float3 shadeHazeInscatter(float3 p, constant ShadeFrame &f, constant ShadeLook &L, float sunVis, thread float3 &T, thread float3 &Ssun) {
	return shadeHazeInscatterFrom(p, f.cameraBlock.y + f.cameraFract.y, f, L, sunVis, T, Ssun);
}

// Air fog for lit surfaces (pre-exposure radiance): M1's aerial blend into the sky behind (sky-view LUT), then the local
// haze and mist, then a chunk-shaped border fog into the sky's horizon (vanilla render distance only: when another mod
// moves vanilla's fog away, e.g. Distant Horizons, fogMisc.z is 0 and M1's vanilla fog distance stays). vanillaFog: M1's
// fog amount (environmental and render distance and the chunk fade-in); chunkFade: 1 - the chunk's fade-in alone.
// M3: R (ShadeResources, may be nullptr): the sky behind includes the volumetric clouds there (distant terrain melts into the
// cloudy sky the sky pass drew, not into a clear one).
static float3 shadeFogAir2(float3 radiance, float3 p, float vanillaFog, float chunkFade, texture2d<half> lut, sampler s,
                           constant ShadeFrame &f, constant ShadeLook &L, constant ShadeResources *R = nullptr) {
	if (!shadeFeature(L, SHADE_FEATURE_HAZE)) return shadeFogAir(radiance, p, vanillaFog, lut, s, f);
	float d = length(p);
	float3 v = p / max(d, 1e-4);
	bool air = f.fogColor.a < 0.5;
	float ap = (1.0 - exp(-d * f.fogSky.z)) * f.fogSky.w * (1.0 - f.fogColor.a);
	// (FT2.9, mcopt.shade.caveAir) the sky behind only as far as the air is lit by the sky (none from inside a cave), and faded in
	// over ap 0.002-0.004 (~5-10 blocks) instead of starting at once: in a cave, under its high exposure, the step at ~5 blocks
	// showed as a sphere around the player (bright sky behind the walls past it, Gael 2026-10-10)
	bool smoothAir = shadeAirSmooth(L);
	if (smoothAir) ap *= shadeAirSky(L);
	float apMix = smoothAir ? ap * 0.6 * smoothstep(0.002, 0.004, ap) : (ap > 0.002 ? ap * 0.6 : 0.0);
	if (shadeCloudDev(L, SHADE_CLOUD_DEV_NO_AP)) apMix = 0.0;
	float3 skyBehind = float3(0.0);
	// the border fog's amount (applied last, below): computed first, the clouds' lookup needs it
	float edge = 0.0;
	if (air) {
		if (L.fogMisc.z > 0.0) { // border fog: l4 norm on xz (square like the loaded chunks), into the horizon sky
			float2 q = p.xz * p.xz;
			float l4 = sqrt(sqrt(dot(q, q)));
			float Rb = L.fogMisc.z;
			edge = max(smoothstep(L.fogMisc.y * Rb, Rb, l4), chunkFade);
		} else {
			edge = vanillaFog;
		}
	}
	// the sky behind (with the clouds) only where a blend below can use it (audit idx 86: not for every fragment while the
	// border fog is on; terrain within ~5.6 blocks has ap < 0.002 and no border fog). Vanilla's fog (fogMisc.z = 0, DH) keeps
	// its own clear-sky lookup below, as before.
	bool needSky = apMix > 0.0 || (air && L.fogMisc.z > 0.0 && edge > 0.002);
	if (needSky) {
		float3 vs = float3(v.x, max(v.y, 0.0), v.z);
		skyBehind = shadeSkyLookup(vs, lut, s, f);
		if (R != nullptr && L.clouds0.w > 0.5) {
			// the clouds the sky pass drew in this pixel's own direction v, not in the clamped one: below the horizon vs is the
			// horizon at the same azimuth, so every pixel of land and sea under a horizon cloud (or gap) took that cloud's value
			// = thin vertical streaks across the sea and bright columns over the far terrain at sunset (Gael, 2026-10-07).
			// Below the horizon, from under the layer, the march has faded the clouds into the horizon haze already (nothing
			// there to streak); from inside or above the layer the clouds below the horizon are in front of the terrain
			// (cloud_over composites them), not behind it: none here.
			float wc = v.y >= 0.0 ? 1.0 : smoothstep(0.0, 24.0, L.clouds0.x);
			// M3.1: the clouds reach this pixel only through the blend weights below (ap x 0.6 toward the sky behind: under ~5 %
			// within the render distance; the border fog's edge: up to all of it). Where both are tiny the clouds' part cannot
			// show: no lookup there (terrain nearer than ~75 blocks), faded in over 1.5-3.5 % so no contour appears; the border
			// fog keeps the full clouds. (SHADE_CLOUD_DEV_OLD_FOG: M3, a lookup for every pixel)
			// (FT2.10; SHADE_CLOUD_DEV_EARLY_FOG: FT2.9) only once the terrain is mostly gone (edge 0.7 -> 1, squared: Complementary's
			// skyFade ramp): a mountain near the render distance fades into the clear sky, not into the clouds behind it. With the
			// clouds from the fog's start the half-faded peaks showed the cloud layer through them, strongest at sunset and
			// sunrise, when the low clouds toward the sun are bright against their dark undersides (Gael 2026-10-10)
			if (!shadeCloudDev(L, SHADE_CLOUD_DEV_OLD_FOG)) {
				if (shadeCloudDev(L, SHADE_CLOUD_DEV_EARLY_FOG)) {
					wc *= smoothstep(0.015, 0.035, max(ap * 0.6, edge));
				} else {
					float late = saturate(edge * 3.333333 - 2.333333);
					// (1.2.9, mcopt.shade.clouds.fogBlend, ShadeLook.user4.z: 0 FT2.10's late ramp everywhere, 1 the clouds from the
					// fog's start everywhere, 2 = default: late only toward a low sun) With the late ramp the land at the border faded
					// into the CLEAR sky while the sky next to it showed clouds: pale blue ghosts of hills, with a hard outline, in front
					// of white clouds, at any hour (Gael 2026-11-23). The early blend fades the land into exactly what is behind it;
					// the late one is kept only where it was needed: toward a sun under ~15-30 degrees, whose bright cloud edges
					// showed through half-faded peaks (2026-10-10).
					float3 ld = f.lightDirWorld.xyz;
					float glare = (1.0 - smoothstep(0.26, 0.5, ld.y)) *
						smoothstep(-0.2, 0.5, dot(v.xz, ld.xz) * rsqrt(max(dot(v.xz, v.xz) * dot(ld.xz, ld.xz), 1e-8)));
					float lateW = L.user4.z > 1.5 ? glare : (L.user4.z > 0.5 ? 0.0 : 1.0);
					// (1.2.9 candidate 3) in mode 2 the early blend follows the border fog's edge alone: the aerial blend's share (ap x 0.6,
					// under 5 %) is too small to show a cloud, and with it every terrain pixel past ~75 blocks looked the clouds up
					// (+0.21 ms on the perf spin at native resolution, run c2-attrib); now only the border band does
					float earlyW = L.user4.z > 1.5 ? smoothstep(0.002, 0.03, edge) : smoothstep(0.015, 0.035, max(ap * 0.6, edge));
					wc *= mix(earlyW, late * late, lateW);
				}
			}
			if (shadeCloudDev(L, SHADE_CLOUD_DEV_NO_FOG)) wc = 0.0;
			if (wc > 0.0) {
				float4 cl = shadeCloudsScreen(v, L, R->cloudScreen);
				// (1.2.9 candidate 6, fogBlend 3 = default) while the land is still mostly there it fades into a SOFT image of the clouds
				// behind it (the reflection dome, 128 x 64 texels for the whole sky; four spread taps of the screen's clouds when the
				// dome is off or toward the horizon), and into the sharp one only over the last quarter of the fade. With the sharp
				// clouds from the start the half-faded mountain showed every cloud's outline through it ("como que las nubes
				// atraviesan la montaña", Gael 2026-11-23); into a soft one it reads as haze thickening, and at the end the land is
				// exactly the sky behind it (no ghost, as fogBlend 2). Only the border band reaches here (wc > 0).
				if (L.user4.z > 2.5) {
					float sharp = smoothstep(0.75, 1.0, edge);
					if (sharp < 1.0) {
						float4 soft;
						if (L.clouds1.x > 0.5 && v.y > 0.03) {
							soft = shadeCloudsDome(v, L, R->cloudDome);
						} else {
							float3 t1 = normalize(cross(v, float3(0.0, 1.0, 0.0)) + float3(1e-5, 0.0, 0.0));
							float3 t2 = cross(v, t1);
							soft = 0.25 * (shadeCloudsScreen(normalize(v + 0.07 * (t1 + t2)), L, R->cloudScreen) + shadeCloudsScreen(normalize(v + 0.07 * (t1 - t2)), L, R->cloudScreen)
								+ shadeCloudsScreen(normalize(v - 0.07 * (t1 + t2)), L, R->cloudScreen) + shadeCloudsScreen(normalize(v - 0.07 * (t1 - t2)), L, R->cloudScreen));
						}
						cl = mix(soft, cl, sharp);
					}
				}
				skyBehind = skyBehind * mix(1.0, cl.a, wc) + cl.rgb * wc;
			}
		}
	}
	if (apMix > 0.0) radiance = mix(radiance, skyBehind, apMix);
#ifndef MCOPT_HDR
	// (in the HDR target the final pass applies the haze once per pixel, from depth: no cost per overdrawn fragment)
	if (air && (smoothAir || d > 2.0)) {
		float3 T;
		float3 S = shadeHazeInscatter(p, f, L, 1.0, T);
		radiance = radiance * T + S;
	}
#endif
	if (air && edge > 0.002) radiance = mix(radiance, needSky ? skyBehind : shadeSkyLookup(float3(v.x, max(v.y, 0.0), v.z), lut, s, f), edge);
	return radiance;
}

// (FT2.12) The glow around the sun in shadeFogAir2's aerial blend (the land at camera-relative p mixed toward the sky behind it):
// its part above that sky 90 degrees from the sun's azimuth, as it reaches the pixel (pre-exposure radiance; 0 away from the sun).
// That glow is sunlight scattered by the air, like the haze's: the VL air mode takes out its share in the shadows along the ray
// (vl.metal) and the final pass lets it take at most this (shade_post.metal). Before, it reached the land unshadowed: toward a sun
// set behind a mountain the mountain's face glowed orange through it (Gael 2026-10-11, a snowy canyon at sunset). In open sunlit
// air it stays. SHADE_CLOUD_DEV_AP_SUN (mcopt.shade.aerialSun=true): none, FT2.11.
static inline float3 shadeAerialSunGlow(float3 p, texture2d<half> lut, sampler s, constant ShadeFrame &f, constant ShadeLook &L) {
	if (shadeCloudDev(L, SHADE_CLOUD_DEV_AP_SUN) || shadeCloudDev(L, SHADE_CLOUD_DEV_NO_AP) || !shadeFeature(L, SHADE_FEATURE_HAZE)) return float3(0.0);
	float d = length(p);
	float3 v = p / max(d, 1e-4);
	if (dot(v.xz, shadeSkyAxis(f)) <= 0.0) return float3(0.0);
	// (shadeFogAir2's blend weight, the same terms)
	float ap = (1.0 - exp(-d * f.fogSky.z)) * f.fogSky.w * (1.0 - f.fogColor.a);
	bool smoothAir = shadeAirSmooth(L);
	if (smoothAir) ap *= shadeAirSky(L);
	float apMix = smoothAir ? ap * 0.6 * smoothstep(0.002, 0.004, ap) : (ap > 0.002 ? ap * 0.6 : 0.0);
	if (apMix <= 0.0) return float3(0.0);
	float3 vs = float3(v.x, max(v.y, 0.0), v.z);
	return apMix * max(shadeSkyLookup(vs, lut, s, f) - shadeSkyLookup(vs, lut, s, f, 0.7071068), 0.0);
}

// ---- sky (E03, E04) -------------------------------------------------------------------------------------------------------
// Planck's law sampled at 3 wavelengths (610, 550, 465 nm), normalized to luminance 1, then pulled toward white (three
// samples over-saturate): a star's colour from its temperature.
static inline float3 shadeBlackbody(float kelvin) {
	// (2.0.1 opt) precomputed c2*log2(e)/lam and relative 1/lam^5 weights using hardware exp2
	const float3 kLog = float3(34028.05, 37740.20, 44638.94); // 1.4388e-2 * log2(e) / lam
	const float3 wLam = float3(0.594726, 1.000000, 2.313734); // (550/lam)^5
	float3 e = exp2(kLog / kelvin) - 1.0;
	float3 b = wLam / e;
	b /= max(dot(b, float3(0.2126, 0.7152, 0.0722)), 1e-30);
	return mix(float3(1.0), b, 0.55);
}

// Stars in star space s (unit): a cube map of cells (N per face side), at most one star per cell, tested in the 2x2 cells
// nearest the direction. Magnitudes skewed to faint ones, temperature mixture of cool, sun-like and hot stars, a Gaussian
// spot of sigma cells, twinkle growing with the airmass. Returns radiance (unscaled).
static float3 shadeStars(float3 s, float airmass, float time, float sigmaCells) {
	float3 a = abs(s);
	float2 uv; uint face;
	if (a.x >= a.y && a.x >= a.z) { uv = s.yz / a.x; face = s.x > 0.0 ? 0u : 1u; }
	else if (a.y >= a.z) { uv = s.xz / a.y; face = s.y > 0.0 ? 2u : 3u; }
	else { uv = s.xy / a.z; face = s.z > 0.0 ? 4u : 5u; }
	const float N = 420.0;
	float2 cell = (uv * 0.5 + 0.5) * N;
	float2 base = floor(cell - 0.5);
	float sig2 = sigmaCells * sigmaCells;
	float maxR2 = 9.0 * sig2;
	float inv2Sig2 = -0.72134752 / sig2; // -0.5 * log2(e) / sig2
	float t7 = time * 7.0;
	float twAmp = 0.35 * min(airmass, 4.0);
	float3 sum = float3(0.0);
	for (int j = 0; j < 4; j++) {
		int2 c = int2(base) + int2(j & 1, j >> 1);
		uint h = shadeHash3(int3(c, int(face)), 0x5bd1e995u);
		if (shadeHash01(h) > 0.07) continue;
		float2 pos = float2(c) + 0.2 + 0.6 * float2(shadeHash01(h ^ 0x68e31da4u), shadeHash01(h ^ 0xb5297a4du));
		float2 dd = cell - pos;
		float r2 = dot(dd, dd);
		if (r2 > maxR2) continue;
		float mag = -1.0 + 7.5 * pow(shadeHash01(h ^ 0x1b56c4e9u), 0.45);
		float flux = exp2(-1.328771 * mag); // 10^(-0.4 m)
		float pick = shadeHash01(h ^ 0x7f4a7c15u);
		float kelvin = pick < 0.55 ? mix(3200.0, 5200.0, pick * (1.0 / 0.55)) : pick < 0.9 ? mix(5200.0, 7500.0, (pick - 0.55) * (1.0 / 0.35))
			: mix(7500.0, 15000.0, (pick - 0.9) * 10.0);
		float ph = t7 + shadeHash01(h ^ 0x2545f491u) * 64.0;
		float pf = floor(ph);
		float tw0 = shadeHash01(h ^ uint(pf)), tw1 = shadeHash01(h ^ uint(pf + 1.0));
		float twinkle = 1.0 + twAmp * (mix(tw0, tw1, ph - pf) - 0.5);
		sum += shadeBlackbody(kelvin) * (flux * twinkle * exp2(r2 * inv2Sig2));
	}
	return sum;
}

// The Milky Way, baked into ShadeResources.milkyWay (equirectangular in galactic longitude/latitude; shade_post.metal's
// bake): the band sits 62.9 degrees from the sun path, wheeling with the stars.
static inline float3 shadeMilkyWay(float3 s, texture2d<half> mw) {
	const float ct = 0.4540, st = 0.8910; // cos, sin 62.9 deg
	float3 g = float3(s.x, ct * s.y - st * s.z, st * s.y + ct * s.z);
	float lon = atan2(g.y, g.x), lat = asin(clamp(g.z, -1.0, 1.0));
	constexpr sampler lin(filter::linear, address::repeat);
	return float3(mw.sample(lin, float2(lon * 0.1591549 + 0.5, lat * 0.3183099 + 0.5), level(0.0)).rgb);
}

// The moon's disc, procedural: maria (low-frequency patches) and craters (bowls with bright rims) on a sphere, lit by the
// sun from the phase angle (0 full .. pi new) with the Lommel-Seeliger law, plus earthshine on the dark side. md: unit
// direction to the moon; q: the view direction's offset from it in the moon's tangent frame, in disc radii. Radiance.
static float3 shadeMoonDisc(float2 q, float3 md, float3 pole, float phase) {
	float r2 = dot(q, q);
	float mu = sqrt(max(1.0 - r2, 0.0));
	// sphere normal in a frame: x right, y up (toward the pole), z toward the viewer
	float3 nrm = float3(q, mu);
	// sun direction on the moon: from the viewer (full) rotating to behind it (new) about the up axis
	float3 ls = float3(sin(phase), 0.0, cos(phase));
	float mu0 = dot(nrm, ls);
	float2 sp = float2(atan2(nrm.x, nrm.z), asin(clamp(nrm.y, -1.0, 1.0))); // selenographic-ish coordinates
	// albedo: maria from a few smooth bumps, craters from hashed cells
	float maria = 0.0;
	maria += smoothstep(0.55, 0.15, length(sp - float2(-0.35, 0.25)));
	maria += 0.8 * smoothstep(0.45, 0.1, length(sp - float2(0.25, 0.35)));
	maria += 0.7 * smoothstep(0.40, 0.05, length(sp - float2(0.05, -0.2)));
	maria += 0.5 * smoothstep(0.30, 0.05, length(sp - float2(-0.55, -0.35)));
	float albedo = mix(0.17, 0.09, saturate(maria));
	float2 cg = sp * 7.0;
	float2 ci = floor(cg);
	for (int j = 0; j < 4; j++) {
		float2 c = ci + float2(j & 1, j >> 1) - 0.5;
		uint h = shadeHash3(int3(int2(c), 7), 0x9e3779b9u);
		float2 center = c + 0.5 + 0.4 * (float2(shadeHash01(h), shadeHash01(h ^ 0x85ebca6bu)) - 0.5);
		float rad = 0.12 + 0.25 * shadeHash01(h ^ 0xc2b2ae35u);
		float d = length(cg - center) / rad;
		albedo *= d < 1.0 ? mix(0.82, 1.0, d * d) : 1.0 + 0.25 * exp(-(d - 1.0) * (d - 1.0) * 30.0);
	}
	float lit = mu0 > 0.0 ? mu0 / (mu0 + max(mu, 0.05)) : 0.0;
	float earthshine = 0.012;
	float limb = smoothstep(1.0, 0.97, sqrt(r2));
	return float3(albedo * (lit * 3.2 + earthshine)) * limb;
}

// The overworld sky's radiance toward unit dir (pre-exposure): the atmosphere (sky-view LUT), a procedural sun disc with
// per-channel limb darkening and its Mie aureole, the moon, stars and the Milky Way at night. pixelAngle: radians per pixel.
static float3 shadeSkyRadiance2(float3 dir, texture2d<half> lut, sampler s, constant ShadeFrame &f, constant ShadeLook &L,
                                texture2d<half> milkyWay, float pixelAngle) {
	if (shadeDev(f, SHADE_DEV_FLAT_SKY)) return float3(0.3, 0.5, 0.8);
	float3 sky = shadeSkyLookup(dir, lut, s, f);
	float rain = f.weather.x;
	float above = smoothstep(-0.03, 0.01, dir.y);
	// sun: disc + aureole
	float3 sd = f.sunDirWorld.xyz;
	float cosA = dot(dir, sd);
	float sunUp = smoothstep(-0.12, 0.0, sd.y);
	if (sunUp > 0.0 && f.sunColor.w >= 0.0) {
		float3 sunLight = f.lightDirWorld.w > 0.5 ? f.sunColor.rgb : float3(0.0);
		float aureole = (shadeHG(cosA, 0.85) - shadeHG(cosA, 0.6)) * 0.35 * f.atmosphere.z * (1.0 - 0.7 * rain);
		sky += sunLight * max(aureole, 0.0) * above;
		float rs = L.sunGeom.y;
		float ang = acos(clamp(cosA, -1.0, 1.0));
		float rho = ang / rs;
		if (rho < 1.3 && L.user4.y < 0.5) { // (1.2.9, issue #67) user4.y 1: Minecraft's sun draws instead (celestial.vs.metal), the aureole stays
			float w = 1.5 * pixelAngle / rs;
			float mu = sqrt(saturate(1.0 - rho * rho));
			float3 u = float3(0.40, 0.55, 0.70), v = float3(0.25, 0.20, 0.12);
			float3 I = 1.0 - u * (1.0 - mu) - v * (1.0 - mu) * (1.0 - mu);
			float edge = smoothstep(1.0 + w, 1.0 - w, rho);
			sky += sunLight * (160.0 * (1.0 - 0.9 * rain)) * I * edge * above;
		}
	}
	bool procedural = shadeFeature(L, SHADE_FEATURE_STARS);
	float night = L.night.x;
	if (procedural && dir.y > -0.03 && (night > 0.0 || dot(dir, f.moonDirWorld.xyz) > 0.999)) {
		// star space (wheels with the tilted sun path)
		float3 st = float3(dot(L.celestial[0].xyz, dir), dot(L.celestial[1].xyz, dir), dot(L.celestial[2].xyz, dir));
		float clear = (1.0 - rain) * above;
		float airmass = 1.0 / max(dir.y, 0.05);
		float ext = exp(-0.12 * min(airmass, 12.0));
		// (FT2.8, audit idx 79) what lies BEHIND the moon (stars, Milky Way) kept apart: the disc hides it, not the air in front
		float3 behind = float3(0.0);
		if (night > 0.0 && clear > 0.0) {
			float sigma = clamp(0.7 * pixelAngle / (1.5707963 / 420.0), 0.25, 0.8);
			float3 stars = shadeStars(st, airmass, f.time.y, sigma);
			float3 mw = shadeMilkyWay(st, milkyWay) * L.night.y;
			behind = (stars * 0.9 + mw) * (night * clear * ext);
		}
		float cover = 0.0;
		float3 moonLight = float3(0.0);
		// moon
		float3 md = f.moonDirWorld.xyz;
		float rm = L.sunGeom.z;
		float cm = dot(dir, md);
		if (cm > cos(rm * 1.2)) {
			float3 up = normalize(L.celestial[2].xyz - md * dot(L.celestial[2].xyz, md));
			float3 right = cross(up, md);
			float2 q = float2(dot(dir, right), dot(dir, up)) / sin(rm);
			if (dot(q, q) < 1.0) {
				float3 moon = shadeMoonDisc(q, md, up, L.night.w) * float3(0.92, 0.96, 1.05);
				float moonUp = smoothstep(-0.02, 0.02, md.y);
				// (the whole sky x 0.2 inside the disc darkened the twilight air in front of it: a dark disc above the antisolar
				// horizon at dusk, on the unlit part of the moon)
				cover = moonUp * (1.0 - smoothstep(0.9, 1.0, length(q)));
				moonLight = moon * 0.9 * (1.0 - 0.85 * rain);
			}
		}
		sky += behind * (1.0 - cover) + moonLight * cover;
	}
	return sky;
}

#endif
