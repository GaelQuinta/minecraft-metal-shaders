// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// M3 (bible E17): entities, block entities (chests, signs, item frames, banners), dropped items, armour, moving blocks and
// particles lit by OUR lighting model in the HDR world target, instead of vanilla's two fixed "cardinal" lights times the
// lightmap. mcopt.metal.shade.ShadeEntity patches the game's own SPIR-V-Cross stages for the HDR variants of those pipelines
// (their RGBA8 pipelines, used by the GUI and the first-person hand, stay vanilla):
//   vertex:   + camera-relative world position, world normal (0 when the vertex format has none), the raw vertex colour (no
//               cardinal light) and the lightmap coordinates / 240 (x block, y sky) as extra outputs (locn 12-15);
//   fragment: after the game's own colour (alpha, cutout discard and dissolve stay the game's), the colour is replaced by
//               shadeEntityShade(): albedo = texture x raw colour x ColorModulator with the hurt / creeper overlay, lit by
//               shadeLit2 (sun or moon N.L with the shadow map, directional sky light, warm fill, block light curve, cave
//               minimum), + the dynamic lights (m3-lights' irradiance volume), fogged like terrain (shadeFogAir2) and exposed (shadeFinish2).
// Outside the overworld the game's colour is kept (as terrain does), converted to scene-linear, unless the dims module lights
// the Nether / End per pixel (shadeLitDims, like their terrain).
#ifndef MCOPT_SHADE_ENTITY
#define MCOPT_SHADE_ENTITY

#define SHADE_ENT_ENTITY 0    // mobs, players, block entities, armour, items: real vertex normals
#define SHADE_ENT_BLOCK 1     // moving / falling blocks (no normal attribute: flat normal from the position's derivatives)
#define SHADE_ENT_PARTICLE 2  // particles (camera-facing quads: lit as thin two-sided surfaces)
#define SHADE_ENT_HAND 3      // the first-person hand and held items (MCOPT_HAND: after the final pass, into RGBA8)

// M3 dynamic lights (m3-lights, dynlight.metal; SHADE_DYNLIGHT is defined by its prelude when the module is on): the
// module's light list and irradiance volume, appended to the patched entry point by ShadeEntity.fragmentPatch (buffer 24,
// textures 23-25: free in these stages) and passed through to shadeEntityShade.
#ifdef SHADE_DYNLIGHT
#define SHADE_ENT_DL_PARAMS , constant ShadeDynLights &dl, texture3d<half> dlIrr, texture3d<half> dlDir
#define SHADE_ENT_DL_ARGS , mcoptDL, mcoptDLIrr, mcoptDLDir
#else
#define SHADE_ENT_DL_PARAMS
#define SHADE_ENT_DL_ARGS
#endif

// MCOPT_HAND: the hand draws after the final pass into the display-referred main target: shade in HDR, then the same display
// transform as the world (Shade Filmic + grade, shadeDisplay) and the sRGB encoding; no fog (bible E17).
static inline float4 shadeEntityOut(float3 preExposed, float alpha, constant ShadeLook &L) {
#ifdef MCOPT_HAND
	return float4(shadeLinearToSrgbExact(saturate(shadeDisplay(preExposed, L))), alpha);
#else
	return float4(preExposed, alpha);
#endif
}

// vanilla: the game's final colour (display-referred sRGB, fogged), only its alpha is kept (and its colour outside the
// overworld); albedoSrgb: texture x raw vertex colour x ColorModulator (display-encoded, as vanilla multiplies it); overlay:
// vanilla's overlay texel (rgb, a = 1 - overlay strength; (0,0,0,1) for none); p: camera-relative world position; nv: world
// normal (0: derive one); light: lightmap coordinates / 240 (x block, y sky); fog: x/y environmental start/end, z/w render
// distance start/end (the Fog uniform).
static float4 shadeEntityShade(float4 vanilla, float4 albedoSrgb, float4 overlay, float3 p, float3 nv, float2 light, bool front, float4 frag,
                               int kind, float4 fog, texture2d<half> lut, sampler lutS, depth2d_array<float> shadowMap, sampler cmp,
                               constant ShadeFrame &f, constant ShadeLook &L, constant ShadeGpu &g, constant ShadeResources &R SHADE_ENT_DL_PARAMS) {
	// flat normal for formats without one (before any early return: the whole 2x2 quad takes part)
	float3 dpx = dfdx(p), dpy = dfdy(p);
#ifdef MCOPT_HAND
	if (f.flags.x != SHADE_DIM_OVERWORLD || shadeDev(f, SHADE_DEV_FLAT_LIGHT)) return vanilla;
	const bool dimsLit = false;
#else
	// Nether / End: the game's colour, unless the dims module (M3 skydims) lights the terrain there per pixel: then entities
	// and particles take the same light (shadeLitDims) and the final pass fogs them (else they read as dark, unfogged specks
	// over the dimension's lit haze)
	bool dimsLit = f.flags.x != SHADE_DIM_OVERWORLD && shadeDimsLit(f);
	if ((f.flags.x != SHADE_DIM_OVERWORLD && !dimsLit) || shadeDev(f, SHADE_DEV_FLAT_LIGHT)) return float4(shadeVanillaOut(vanilla.rgb, L), vanilla.a);
#endif
	float3 n;
	bool thin = kind == SHADE_ENT_PARTICLE;
	if ((kind == SHADE_ENT_ENTITY || kind == SHADE_ENT_HAND) && dot(nv, nv) > 0.01) {
		n = normalize(nv);
		if (!front) n = -n; // two-sided parts (no-cull pipelines) seen from behind
	} else {
		float3 nf = cross(dpx, dpy);
		n = nf * rsqrt(max(dot(nf, nf), 1e-30));
		if (dot(n, p) > 0.0) n = -n; // toward the camera
	}
	half3 c = half3(saturate(mix(overlay.rgb, albedoSrgb.rgb, overlay.a)));
	half3 albedo = shadeToLinear(c);
#ifndef MCOPT_HAND
	// M3.3 (mcopt.shade.dims.motes): the Nether's dark suspended particles (warped spores, ash) lifted to a luminance floor
	if (kind == SHADE_ENT_PARTICLE && dimsLit && shadeDimKind(L) == 1 && shadeDimsBit(L, SHADE_DIMS_MOTES)) albedo = shadeDimsMote(albedo);
#endif
	int debug = f.flags.w;
	if (debug == 3) albedo = half3(0.45h);
	half block = half(saturate(light.x)), sky = half(saturate(light.y));
	float ex = shadeExposure(f, g);
	// full-bright particles (flames, lava drips, sparks, enchanting glyphs: the game gives them lightmap 15/15) glow
	if (kind == SHADE_ENT_PARTICLE && light.x > 0.99 && light.y > 0.99) {
		float3 rad = float3(albedo) * float3(f.ambientBlock.xyz) * 2.6 + float3(albedo) * 0.6;
		return shadeEntityOut(shadeFinish2(rad, 0.0, f, L, ex), vanilla.a, L);
	}
	half3 hn = half3(n);
	half shadow;
	float3 radiance;
	if (dimsLit) { // the Nether (no shadows) / the End (its key light's shadow map)
		shadow = f.flags.x == SHADE_DIM_END ? shadeShadow(shadowMap, cmp, f, p, hn, thin) : half(1.0);
		radiance = shadeLitDims(albedo, hn, block, shadow, thin, false, p, f, L);
	} else {
#ifndef MCOPT_HAND
		// (FT2.8, audit idx 99) the receiver 0.1 block toward the light: the entity casters are last frame's positions, so a mob,
		// player, horse or boat moving away from the light was shadowed by its own one-frame-old copy (its sun-facing side dark
		// or banded at sunset; the depth tolerance was ~0.07 block, a sprint is ~0.09 block per frame at 60 fps)
		float3 ps = p + f.lightDirWorld.xyz * 0.1;
#else
		float3 ps = p;
#endif
		shadow = sky <= 0.3h ? half(1.0) : shadeShadow(shadowMap, cmp, f, ps, hn, thin);
#ifndef MCOPT_HAND
		// M3 clouds: the volumetric clouds' shadow on mobs like on the terrain (1 when the clouds are off; not the hand: hand-space p)
		if (sky > 0.3h) shadow *= half(shadeCloudShadow(p, L, R.cloudShadow));
#endif
		radiance = shadeLit2(albedo, hn, sky, block, shadow, thin, false, f, L);
		// (FT2.7, audit idx 74) a lightning flash lights mobs, players and chests like the terrain (weather_surface.metal shadeWxFlash):
		// they stood dark on the flashing ground. Not the hand's normal (hand space): a fixed 0.65 there
		if (L.flash.w > 0.0) {
			half gk = shadeSkyCurve(sky);
#ifdef MCOPT_HAND
			float ndl = 0.65;
#else
			float ndl = saturate(dot(n, L.flash.xyz)) * 0.65 + 0.35;
#endif
			radiance += float3(albedo) * float3(0.78, 0.86, 1.0) * (L.flash.w * ndl * float(gk * gk));
		}
	}
	int dynKind = kind == SHADE_ENT_PARTICLE ? SHADE_DYN_PARTICLE : kind == SHADE_ENT_HAND ? SHADE_DYN_HAND : SHADE_DYN_ENTITY;
	radiance += shadeDynamicLights(shadeDynIn(p, n, float3(albedo), frag.xy, sky, block, dynKind), f, L, &R);
#ifdef SHADE_DYNLIGHT
	// the dynamic lights as the terrain takes them (irradiance volume, per pixel). Not the hand: its p is hand space, and
	// m3-lights' DynLightEntityRendererMixin already raised the local player's packed light (block light here) to the
	// dynamic level at the player.
	if (kind != SHADE_ENT_HAND) radiance += float3(albedo) * shadeDynamicLightsVol(dl, dlIrr, dlDir, p, n, thin, block, f.ambientBlock.xyz);
#endif
#ifdef MCOPT_HAND
	float vanillaFog = 0.0; // the hand gets no fog
#else
	float vanillaFog = shadeVanillaFog(p, fog.xy, fog.zw);
	if (!dimsLit) radiance = shadeFogAir2(radiance, p, vanillaFog, 0.0, lut, lutS, f, L, &R); // (with the clouds' aerial view) Nether/End: the final pass fogs
#endif
	float3 rgb = shadeFinish2(radiance, vanillaFog, f, L, ex);
	if (debug == 2) rgb = shadeVanillaOut(n * 0.5 + 0.5, L);
	if (debug == 1) rgb = shadeVanillaOut(float3(0.25 + 0.75 * float(shadow)), L);
	return shadeEntityOut(rgb, vanilla.a, L);
}

#endif
