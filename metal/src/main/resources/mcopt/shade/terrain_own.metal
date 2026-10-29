// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// Native shading's terrain fragment stage on mcopt 0.3's own near-terrain renderer (v12 port, P2/P3): the texel lit per pixel
// in the overworld (sun or moon light with the shadow map, directional sky light by sky level, warm block light, vanilla's
// baked AO kept in the vertex colour, wet surfaces / puddles / snow, dynamic lights, glowing blocks, coloured shadows, the
// lightning's flash, height haze and fog into the sky); the Nether and the End lit by the dims module or, without it,
// vanilla's lightmapped colour; then exposure (pre-exposed radiance into the HDR world target with MCOPT_HDR, M1's tone curve
// into RGBA8 without). The translucent variant (SHADE_OWN_TRANSLUCENT) adds the water module (SHADE_WATER: waves, reflections,
// refraction, absorption, caustics, foam, falls, the surface from below), M1's water stand-in and the glossy translucents.
// Debug views (mcopt.shade.debug): 1 shadow / cascades, 2 normals, 3 lighting only, 7 water, 8 weather.
//
// Up to 1.1 this shading lived in sodium_terrain.fs.metal, inside Sodium's (PolyForm Shield) shader; only mcopt-shade's own
// lines came over, rewritten against own's vertex data. The texture sampling (soSampleNearestG, soSampleRgss) is adapted from
// mcopt's own/terrain.metal (Apache-2.0, Noah Dunnagan), with the TAA mip scale and the RGSS gate added.
//
// Built as a library of its own per variant (ShadeTerrain, ShadeMsl.ownFragmentSource): "#define MCOPT_HDR" for the HDR world
// target, the lean defines (ShadeLean: SHADE_LEAN_*), [SHADE_OWN_TRANSLUCENT,] ShadeMsl.prelude(), the weather module, [the
// water module,] then this file. mcown.m draws own_vs (own/terrain.metal, built with MCOPT_SHADE) with shade_own_fs as the
// fragment stage of solid, cutout and translucent draws, specialized with the same function constants as own's stages: the
// stage_in below names VOut's members as own_vs writes them (the colour as float4 or half4 by F_HALF, the chunk's visibility
// only outside F_LEAN), so the two link. Slots: own's game uniforms at buffers 28-30, its atlas at texture 26 / sampler 14
// and its lightmap at texture 27 / sampler 15 (mcown.m with a shade library); the shade globals where every shaded pipeline
// has them (shade_common.metal).
//
// What own's vertices carry and what was rebuilt from them (Sodium gave these directly):
//   - the face normal: from the camera-relative position's screen derivatives (shadePos), as before: exact for planar quads;
//   - block and sky light: own's light bytes (vanilla's UV2, 0-240) as shadeLight, the same scale as Sodium's;
//   - the vertex colour: biome tint x vanilla's AO (and the "up" face's shade: ShadeFaceShadeMixin flattens the rest), without
//     the lightmap (own_vs leaves it out under MCOPT_SHADE); outside the overworld without the dims module the lightmap is
//     sampled here, per pixel, from the interpolated light (Sodium's path multiplied it per vertex);
//   - the chunk's fade-in: vanilla's chunk visibility (own's chunkVisibility; 1 in F_LEAN units, which are faded in);
//   - no block id: water by its atlas sprites, foliage = the cutout pass and not slanted, glowing blocks by their texels.

#include <metal_stdlib>
using namespace metal;

// own's draw-kind function constants (mcown.m ownStage sets them for both stages alike)
constant bool SO_CUTOUT [[function_constant(0)]];
constant float SO_CUTOUT_LIMIT [[function_constant(5)]];  // vanilla's ALPHA_CUTOUT: 0.5 cutout, 0.1 translucent
constant bool SO_HALF_SET [[function_constant(9)]];
constant bool SO_LEAN_SET [[function_constant(10)]];
constant bool SO_POSONLY_SET [[function_constant(14)]];
constant bool SO_HALF = is_function_constant_defined(SO_HALF_SET) && SO_HALF_SET;
constant bool SO_LEAN = is_function_constant_defined(SO_LEAN_SET) && SO_LEAN_SET;
constant bool SO_VARY = !(is_function_constant_defined(SO_POSONLY_SET) && SO_POSONLY_SET);
constant bool SO_RICH = !SO_LEAN && SO_VARY;
constant bool SO_FLOATCOLOR = !SO_HALF && SO_VARY;
constant bool SO_HALFCOLOR = SO_HALF && SO_VARY;
// the cutout pass (leaves, vines, plants): cutout at vanilla's 0.5
constant bool SO_CUTOUT_PASS = SO_CUTOUT && SO_CUTOUT_LIMIT > 0.25;

// own/terrain.metal's VOut, the members this stage reads (names and types as own_vs writes them)
struct ShadeOwnIn {
	float4 fragCoord [[position]];
	float4 vertexColor [[function_constant(SO_FLOATCOLOR)]];
	half4 vertexColorH [[function_constant(SO_HALFCOLOR)]];
	float2 texCoord0 [[function_constant(SO_VARY)]];
	float chunkVisibility [[function_constant(SO_RICH)]];
	float3 shadePos [[function_constant(SO_VARY)]];   // camera-relative world position
	half2 shadeLight [[function_constant(SO_VARY)]];  // block, sky light 0..1
};

// vanilla's std140 uniform blocks as own binds them (own/terrain.metal Globals, Terrain, Fog)
struct SoGlobals {
	packed_int3 CameraBlockPos;
	float GlintAlpha;
	packed_float3 CameraOffset;
	float GameTime;
	float2 ScreenSize;
	int MenuBlurRadius;
	int UseRgss;
};
struct SoTerrain {
	float4x4 ModelViewMat;
	int2 TextureSize;
};
struct SoFog {
	packed_float4 FogColor;
	float FogEnvironmentalStart, FogEnvironmentalEnd, FogRenderDistanceStart, FogRenderDistanceEnd, FogSkyEnd, FogCloudsEnd;
};

// own's anti-aliased nearest sample (own/terrain.metal sampleNearestG): du, dv are the gradients to sample with
static float4 soSampleNearestG(texture2d<float> source, sampler s, float2 uv, float2 pixelSize, float2 du, float2 dv, float2 texelScreenSize) {
	float2 uvTexelCoords = uv / pixelSize;
	float2 texelCenter = round(uvTexelCoords) - 0.5f;
	float2 texelOffset = uvTexelCoords - texelCenter;
	texelOffset = (texelOffset - 0.5f) * pixelSize / texelScreenSize + 0.5f;
	texelOffset = clamp(texelOffset, 0.0f, 1.0f);
	return source.sample(s, (texelCenter + texelOffset) * pixelSize, gradient2d(du, dv));
}

// own's RGSS sample (own/terrain.metal sampleRGSS) with the gradients given (the TAA mip scale is in them) and the
// mcopt-shade FT2.8 gate (audit idx 82): the nearest tap only where it still counts (blend < 1), the 8 RGSS taps only where
// they do (blend > 0: none wherever a texel covers a pixel or more, most of the near view at Retina). The same image.
static float4 soSampleRgss(texture2d<float> source, sampler s, float2 uv, float2 pixelSize, float2 du, float2 dv) {
	float2 texelScreenSize = sqrt(du * du + dv * dv);
	float minPixelSize = min(pixelSize.x, pixelSize.y);
	float blend = smoothstep(minPixelSize, minPixelSize * 2.0, max(texelScreenSize.x, texelScreenSize.y));
	float4 color = float4(0.0);
	if (blend < 1.0) color = soSampleNearestG(source, s, uv, pixelSize, du, dv, texelScreenSize);
	if (blend > 0.0) {
		float minDerivative = min(length(du), length(dv)), maxDerivative = max(length(du), length(dv));
		float mipExact = max(0.0, log2(sqrt(minDerivative * maxDerivative) / minPixelSize));
		float mipLow = floor(mipExact);
		const float2 offsets[4] = {float2(0.125, 0.375), float2(-0.125, -0.375), float2(0.375, -0.125), float2(-0.375, 0.125)};
#ifdef SHADE_RGSS_ONE
		// (v12, ShadeMsl: on unless -Dmcopt.shade.rgssOne=false) 4 taps at the nearest whole mip instead of 8 across two: as 1.1
		float4 rgss = float4(0.0);
		for (int i = 0; i < 4; ++i) rgss += source.sample(s, uv + offsets[i] * pixelSize, level(floor(mipExact + 0.5)));
		rgss *= 0.25;
#else
		float4 low = float4(0.0), high = float4(0.0);
		for (int i = 0; i < 4; ++i) {
			float2 at = uv + offsets[i] * pixelSize;
			low += source.sample(s, at, level(mipLow));
			high += source.sample(s, at, level(mipLow + 1.0));
		}
		float4 rgss = mix(low, high, fract(mipExact)) * 0.25;
#endif
		color = blend >= 1.0 ? rgss : mix(color, rgss, blend);
	}
	return color;
}

// M3.1 lean variants (ShadeLean, the defines in front): code this frame cannot use is compiled out (SHADE_LEAN_OW: overworld,
// no Nether/End paths; SHADE_LEAN_DRY: no rain, wetness or snow cover; SHADE_LEAN_NODL: no dynamic light in range;
// SHADE_LEAN_NETHER: the Nether's; SHADE_LEAN_ABOVE / _NOFALLS: the water seen from above / without moving water near).
#ifdef SHADE_LEAN_NODL
#undef SHADE_DYNLIGHT
#endif

static inline float soPbrGgx(float3 n, float3 v, float3 l, float alpha) {
	float3 h = normalize(l - v);
	float nh = saturate(dot(n, h)), nl = saturate(dot(n, l)), nv = max(dot(n, -v), 1e-3);
	float a2 = alpha * alpha;
	float dd = nh * nh * (a2 - 1.0) + 1.0;
	float D = a2 / (3.14159265 * dd * dd);
	float gv = nl * sqrt(nv * nv * (1.0 - a2) + a2), gl = nv * sqrt(nl * nl * (1.0 - a2) + a2);
	return 3.14159265 * D * (0.5 / max(gv + gl, 1e-5)) * nl;
}


fragment float4 shade_own_fs(ShadeOwnIn in [[stage_in]], constant SoGlobals &g [[buffer(28)]], constant SoTerrain &t [[buffer(29)]],
	constant SoFog &fog [[buffer(30)]], texture2d<float> atlas [[texture(26)]], sampler atlasSampler [[sampler(14)]],
	texture2d<float> lightmap [[texture(27)]], sampler lightSampler [[sampler(15)]],
	constant ShadeFrame &sf [[buffer(16)]], constant ShadeLook &sl [[buffer(17)]], constant ShadeGpu &sg [[buffer(18)]],
	depth2d_array<float> shadowMap [[texture(16)]], sampler shadowCompare [[sampler(12)]],
	texture2d<half> skyLut [[texture(17)]], sampler skyLutSmplr [[sampler(13)]]
#ifdef SHADE_DYNLIGHT
	, constant ShadeDynLights &dl [[buffer(24)]], texture3d<half> dlVis [[texture(23)]], texture3d<half> dlIrr [[texture(24)]]
	, texture3d<half> dlDir [[texture(25)]]
#endif
#ifdef SHADE_WATER
	, texture2d<half> sceneCopy [[texture(18)]], depth2d<float> depthCopy [[texture(19)]], constant ShadeWaterParams &wp [[buffer(23)]]
	, texture2d<half> waterWaves [[texture(20)]], texture2d<float> waterCoarse [[texture(21)]], texture2d<half> waterDetail [[texture(22)]]
#endif
#ifdef MCOPT_HDR
	, constant ShadeResources &sr [[buffer(19)]]
#endif
	) {
	float2 uv = in.texCoord0;
	float2 pixelSize = 1.0 / float2(t.TextureSize);
	float2 du = dfdx(uv);
	float2 pbrDu = du;
	float2 dv = dfdy(uv);
	float2 pbrDv = dv;
	float3 p = in.shadePos;
	half blockLight = in.shadeLight.x, skyLight = in.shadeLight.y;
	half fade = SO_RICH ? half(in.chunkVisibility) : half(1.0); // the chunk's fade-in (1: faded in)
	float4 vertexColor = SO_HALF ? float4(in.vertexColorH) : in.vertexColor;
	float3 dpx = dfdx(p), dpy = dfdy(p);
	float3 nf = cross(dpx, dpy); // before any discard: the whole 2x2 quad takes part
#ifdef SHADE_WATER
	float waterFootprint = max(length(dpx), length(dpy));
	float2 waterFlow = shadeWaterFlowDir(dpx, dpy, du, dv);
#endif
	// TAA render scale (cameraBlock.w, 1 at native): gradients as at native resolution, i.e. mip bias log2(scale), so textures
	// keep their native sharpness; the jitter and the temporal resolve take care of the extra texture aliasing
	float mipScale = sf.cameraBlock.w > 0.0 ? sf.cameraBlock.w : 1.0;
	du *= mipScale;
	dv *= mipScale;
#if defined(SHADE_WATER) && defined(SHADE_LEAN_ABOVE)
	// the water module: water by its sprites (every face; vertex colour guess while the sprites are unknown), shaded in full
	// when this frame's scene copy exists, else M1's stand-in for top faces seen from above. Quad-uniform (one triangle per 2x2
	// quad; helper lanes' extrapolated uv may leave the sprite): SSR's lanes work together. Water pixels never use the block
	// texture (the module shades them from its own waves): not sampled there (2026-10-08: -0.11 ms in the lake spin). Only in
	// the variant for the camera above water: the full variant keeps FT1.3's code (the water shader is register-bound)
	int waterSprite = int(shadeQuadMax(float(shadeWaterSprite(uv, wp))));
	bool waterFull = waterSprite > 0 && wp.state.x > 0.5 && !shadeDev(sf, SHADE_DEV_NO_WATER);
	bool skipTex = waterFull;
#else
	const bool skipTex = false;
#endif
	float4 texel = float4(1.0);
	if (!skipTex) {
		if (g.UseRgss == 1) {
			texel = soSampleRgss(atlas, atlasSampler, uv, pixelSize, du, dv);
		} else {
			texel = soSampleNearestG(atlas, atlasSampler, uv, pixelSize, du, dv, sqrt(du * du + dv * dv));
		}
	}
	float4 color = texel * vertexColor;
#ifdef SHADE_OWN_NONCE
	if (in.fragCoord.x < -float(SHADE_OWN_NONCE)) discard_fragment(); // (dev: -Dmcopt.shade.terrain.nonce, a cold Metal cache)
#endif
	if (SO_CUTOUT && color.a < SO_CUTOUT_LIMIT) discard_fragment();
	float2 envFog = float2(fog.FogEnvironmentalStart, fog.FogEnvironmentalEnd), renderFog = float2(fog.FogRenderDistanceStart, fog.FogRenderDistanceEnd);
	float4 fogColor = float4(fog.FogColor);
	// (FT2.8, audit idx 60) vanilla's fog amount where it is used (the Nether/End's unlit path, then after the shading): not live
	// through the water's SSR march
#define SHADE_FOG_VALUE (max(shadeVanillaFog(p, envFog, renderFog), 1.0 - float(fade)))
	// The face normal from the position's screen derivatives: a 2x2 pixel quad always shades one triangle, so this is that
	// triangle's plane (flat, exact). Its sign is arbitrary: turned toward the camera, which also lights both sides of
	// two-sided cutouts. Axis-aligned faces (nearly all of them) are snapped to their axis.
	nf *= rsqrt(max(dot(nf, nf), 1e-30));
	if (dot(nf, p) > 0.0) nf = -nf;
	half3 n = half3(nf);
	half3 a = abs(n);
	half amax = max(max(a.x, a.y), a.z);
	bool thin = amax < 0.9h; // crossed plants and other slanted cutouts
	if (!thin) n = half3(a.x == amax ? sign(n.x) : 0.0h, a.x != amax && a.y == amax ? sign(n.y) : 0.0h, a.x != amax && a.y != amax ? sign(n.z) : 0.0h);
	// outside the overworld: vanilla's lightmapped colour, unless the dims module (M3, shade_dims.metal) lights it below
#ifdef SHADE_LEAN_OW
	const bool dims = false;
#elif defined(SHADE_LEAN_NETHER)
	const bool dims = true; // M3.3: the Nether's lean variant (ShadeLean): no sun, shadow map, clouds or overworld fog code
#else
	bool dims = sf.flags.x != SHADE_DIM_OVERWORLD;
#endif
	if (dims && !shadeDimsLit(sf)) {
		// vanilla's lightmap (own's vertices leave it out under shading: sampled here from the interpolated light) and its
		// directional face shade (ShadeFaceShadeMixin flattened it in the vertices)
		float2 lightUv = clamp(float2(in.shadeLight) * (240.0 / 256.0) + 0.5 / 16.0, float2(0.5 / 16.0), float2(15.5 / 16.0));
		color.rgb *= lightmap.sample(lightSampler, lightUv, level(0.0)).rgb * float(shadeVanillaFace(n, sf.flags.x));
#ifdef SHADE_DYNLIGHT
		{
			// vanilla's colour carries its lightmap (block light curve b / (4 - 3b), the dimension's ambient floor): a carried
			// light raises it toward the level reaching it (display-referred: sqrt of the response, warm like the lightmap)
			float3 dyn = shadeDynamicLightsVol(dl, dlIrr, dlDir, p, float3(n), thin, half(0.0));
			if (dyn.x + dyn.y + dyn.z > 1e-4) {
				float b = float(blockLight), have = max(b / (4.0 - 3.0 * b), 0.12);
				float3 want = sqrt(dyn) * float3(1.0, 0.86, 0.72);
				color.rgb *= min(max(want / have, 1.0), 12.0);
			}
		}
#endif
		float fogValue = SHADE_FOG_VALUE;
		return float4(shadeVanillaOut(mix(color.rgb, fogColor.rgb, float3(fogValue * fogColor.a)), sl), color.a);
	}
	if (shadeDev(sf, SHADE_DEV_FLAT_LIGHT)) return float4(shadeVanillaOut(color.rgb, sl), color.a);
	float ex = shadeExposure(sf, sg);
	// the biome tint (grass, leaves, vines) pulled 22% toward its luma before it multiplies the texture: vanilla's colour map,
	// linearized, is a neon green under real lighting; untinted blocks (grey AO only) are unchanged
	half3 vtint = half3(vertexColor.rgb);
	half vchroma = max3(vtint.r, vtint.g, vtint.b) - min3(vtint.r, vtint.g, vtint.b);
	if (vchroma > half(0.06)) vtint = mix(half3(shadeLumaH(vtint)), vtint, half(0.78));
	half3 albedo = shadeToLinear(half3(texel.rgb) * vtint);
	int debug = sf.flags.w;
	if (debug == 3) albedo = half3(0.45h);
	bool foliage = SO_CUTOUT_PASS && !thin; // the cutout pass (not translucent): leaves, vines and the like
#if defined(SHADE_WATER) && !defined(SHADE_LEAN_ABOVE)
	// the water module: water by its sprites (as above), quad-uniform
	int waterSprite = int(shadeQuadMax(float(shadeWaterSprite(uv, wp))));
	bool waterFull = waterSprite > 0 && wp.state.x > 0.5 && !shadeDev(sf, SHADE_DEV_NO_WATER);
#elif !defined(SHADE_WATER)
	bool waterFull = false; // (LEAN_ABOVE: waterSprite / waterFull are found above, before the texture sampling)
#endif
	// no map lookups where the direct light is gated off anyway (caves, under overhangs: sky light below ~4); the water module
	// only gates its glint and caustics with it: M1's 4-tap tent there instead of PCSS (the End has no sky light: its key
	// light's map is looked up everywhere, with full sky for the far fallback)
#ifdef SHADE_LEAN_OW
	const bool endLit = false, netherLit = false;
#elif defined(SHADE_LEAN_NETHER)
	const bool endLit = false, netherLit = true;
#else
	bool endLit = sf.flags.x == SHADE_DIM_END, netherLit = sf.flags.x == SHADE_DIM_NETHER;
#endif
	half shadowSky = endLit ? half(1.0) : skyLight;
	half shadow = (skyLight <= 0.3h && !endLit) || netherLit ? half(1.0)
		// M3.4 (mcopt.shade.waterShadowSoft, ShadeLook.waterShadow.x, read every frame): up-facing water gets a soft-edged shadow
		: waterFull ? (n.y > 0.5h && sl.waterShadow.x > 0.0 ? shadeShadowSoft(shadowMap, shadowCompare, sf, p, n, sl.waterShadow.x, in.fragCoord.xy, sl.waterShadow.z)
		                                                    : shadeShadow(shadowMap, shadowCompare, sf, p, n, false))
		: shadeShadow2(shadowMap, shadowCompare, sf, sl, p, n, thin || foliage, foliage, in.fragCoord.xy, shadowSky);
#ifdef MCOPT_HDR
	// M3: the volumetric clouds' shadows (shade_clouds.metal; 1 when they are off); overworld only (only where the sun or moon
	// still reaches: a pixel already in terrain shadow needs no cloud-map fetch)
	if (!dims && skyLight > 0.3h && shadow > 0.0h) shadow *= half(shadeCloudShadow(p, sl, sr.cloudShadow));
#endif
	float alpha = color.a;
#ifdef SHADE_OWN_TRANSLUCENT
	// the translucent pass: water (a top face tinted by the biome's water colour; stained glass and ice have white vertex
	// colours) gets its own body colour, a sky reflection and a sun glint, seen from above water (M1's stand-in)
	half3 tint = half3(vertexColor.rgb);
	bool water = n.y > 0.5h && max3(tint.r, tint.g, tint.b) - min3(tint.r, tint.g, tint.b) > 0.08h && !SHADE_CAMERA_UNDERWATER(sf)
		&& !shadeDev(sf, SHADE_DEV_NO_WATER);
#ifdef SHADE_WATER
	if (waterSprite == 0) water = false;
#endif
#else
	bool water = false;
#endif
	// labPBR: derivatives are captured before discard; shadows continue to use the geometric normal.
	half3 materialN = n;
	float4 materialS = float4(0.0);
	float materialAo = 1.0;
#if defined(MCOPT_HDR) && defined(SHADE_PBR)
	bool pbr = any(abs(sl.user3.yzw) > 0.0) && !waterFull && !water;
	if (pbr) {
		if (abs(sl.user3.y) > 0.0) {
			float4 nm = g.UseRgss == 1 ? soSampleRgss(sr.pbrNormal, atlasSampler, uv, pixelSize, du, dv)
			    : soSampleNearestG(sr.pbrNormal, atlasSampler, uv, pixelSize, du, dv, sqrt(du*du+dv*dv));
			float2 xy = nm.rg * 2.0 - 1.0;
			// Make the canonical flat 128,128 exactly neutral.
			if (all(abs(nm.rg - 128.0/255.0) < 0.001)) xy = float2(0.0);
			if (sl.user3.y < 0.0) xy.y = -xy.y;
			xy *= abs(sl.user3.y);
			float3 nn = normalize(float3(xy, sqrt(max(1.0-dot(xy,xy), 0.001))));
			float det = pbrDu.x*pbrDv.y - pbrDu.y*pbrDv.x;
			float3 T = (dpx*pbrDv.y - dpy*pbrDu.y) * sign(det);
			float3 B = (dpy*pbrDu.x - dpx*pbrDv.x) * sign(det);
			T -= float3(n)*dot(T,float3(n)); B -= float3(n)*dot(B,float3(n));
			if (dot(T,T)>1e-20 && dot(B,B)>1e-20)
				materialN = half3(normalize(normalize(T)*nn.x + normalize(B)*nn.y + float3(n)*nn.z));
			materialAo = mix(1.0, nm.b, min(abs(sl.user3.y),1.0));
		}
		if (sl.user3.z > 0.0 || sl.user3.w > 0.0)
			materialS = g.UseRgss == 1 ? soSampleRgss(sr.pbrSpecular, atlasSampler, uv, pixelSize, du, dv)
			    : soSampleNearestG(sr.pbrSpecular, atlasSampler, uv, pixelSize, du, dv, sqrt(du*du+dv*dv));
	}
#endif
	float3 radiance;
#ifdef SHADE_WATER
	if (waterFull) {
		half3 up = half3(0.0h, 1.0h, 0.0h);
		ShadeWaterIn wi;
		wi.p = p;
		wi.nFace = float3(n);
		wi.footprint = waterFootprint;
		wi.flowDir = waterSprite == 2 && n.y > 0.5h ? waterFlow : float2(0.0);
		wi.pixel = in.fragCoord.xy;
		wi.depth = in.fragCoord.z;
		wi.tint = tint;
		wi.sky = skyLight;
		wi.shadow = shadow;
		// (FT2.10) water the sky doesn't light (caves, cellars, a strip in a base): x the torch light's caustics on its bottom
		// (block light, mcopt.shade.water.torchCaustics: ShadeLook.waterShadow.w), y how far its reflections follow the ripples
		// (sky light under 0.5, mcopt.shade.water.caveRipples: ShadeLook.eye.z), z its surroundings' share in them
		// (mcopt.shade.water.caveSky: ShadeLook.eye.y). See shadeWaterAbove. w (FT2.11): moving water's look (falling water's
		// sides, currents; mcopt.shade.water.falls: ShadeLook.bloom.w)
		{
			float b = float(blockLight), s = saturate(float(skyLight) * 2.0), c = 1.0 - s * s;
			wi.cave = half4(half(smoothstep(0.3, 0.8, b) * sl.waterShadow.w), half(c * sl.eye.z), half(saturate(c * sl.eye.y)), half(sl.bloom.w));
		}
		wi.dxz = float4(dpx.xz, dpy.xz);
		wi.detail = float4(0.0);
#ifdef SHADE_WATER_DETAIL
		// M2.1 fine ripples (baked waves): top faces, and the surface seen from below with the camera under water
		if (!SHADE_WDEV_IS(sf, SHADE_WDEV_NO_DETAIL) && (n.y > 0.5h || (n.y < -0.5h && SHADE_CAMERA_UNDERWATER(sf))) && wp.state.w > 0.5) wi.detail = shadeWaterDetailIn(wi, sf, waterDetail);
#endif
#if defined(SHADE_WAVE_BAKE) && !defined(SHADE_LEAN_NOFALLS)
		// (FT2.11) falling water's sides (only in the variant drawn while moving water is near: WaterFlowScan): the ripples tilt
		// the face normal the surface is shaded with (shadeWaterFallNormal)
		if (shadeWaterIsFall(float(n.y), sl.bloom.w, wp)) wi.nFace = shadeWaterFallNormal(wi, sf, waterWaves);
#endif
		wi.lit = shadeLit2(half3(1.0h), up, skyLight, blockLight, shadow, false, false, sf, sl);
#ifdef SHADE_DYNLIGHT
		float3 dlSpec = float3(0.0);
		if (n.y > 0.5h) { // the surface seen from above: torchlight on the water body and its glint on the ripples
			float3 V = -normalize(p - shadeEye(sf.invViewProj)); // toward the eye (view bobbing moves it)
			float3 dlN = normalize(float3(0.0, 1.0, 0.0) + float3(wi.detail.x, 0.0, wi.detail.y) * 0.35);
			wi.lit += sf.ambientBlock.xyz * shadeDynamicLightsSpec(dl, dlVis, p, dlN, blockLight, V, 160.0, dlSpec);
			float fres = 0.02 + 0.98 * pow(1.0 - saturate(dot(dlN, V)), 5.0);
			dlSpec *= sf.ambientBlock.xyz * (0.25 + 3.0 * fres);
		} else {
			wi.lit += sf.ambientBlock.xyz * shadeDynamicLightsVol(dl, dlIrr, dlDir, p, float3(n), false, blockLight);
		}
#endif
		wi.exposure = ex;
#ifdef MCOPT_HDR
#ifdef SHADE_SSR_PREV
		// last frame's finished HDR world (ShadeLook.ssr.x: it was written): SSR colour, rendered sky in the reflections
		wi.prevExposure = sl.ssr.x > 0.5 ? sg.exposure.z : 0.0;
		wi.look = &sl;
#else
		wi.prevExposure = 0.0;
		wi.look = nullptr;
#endif
		wi.res = &sr;
		wi.fog = SHADE_CAMERA_UNDERWATER(sf) ? shadeLdrToHdr(sf.fogColor.rgb, sl) / max(ex, 1e-6) : float3(0.0); // only read from below
		texture2d<half> prevScene = sr.prevScene;
#else
		wi.prevExposure = 0.0;
		wi.look = nullptr;
		wi.res = nullptr;
		wi.fog = SHADE_CAMERA_UNDERWATER(sf) ? shadeWaterDisplayRadiance(half3(sf.fogColor.rgb), ex) : float3(0.0);
		texture2d<half> prevScene = sceneCopy;
#endif
		radiance = shadeWaterSurface(wi, sf, wp, skyLut, skyLutSmplr, sceneCopy, depthCopy, prevScene, waterWaves, waterCoarse);
#if defined(SHADE_WAVE_BAKE) && !defined(SHADE_LEAN_NOFALLS)
		// (FT2.11) and its white water over the result, lit like the shore's foam (wi.lit is live to the water's end anyway)
		if (shadeWaterIsFall(float(n.y), sl.bloom.w, wp)) radiance = mix(radiance, wi.lit * 0.55, shadeWaterFallFoam(p, float3(n), waterFootprint, sl.bloom.w, sf));
#endif
#ifdef SHADE_DYNLIGHT
		radiance += dlSpec;
#endif
		alpha = 1.0; // the water composited what is behind it from the scene copy
		if (debug == 7) radiance = float3(saturate(wi.footprint * 4.0), float(waterSprite == 2), saturate(length(p) / 128.0)) / max(ex, 1e-3);
	} else
#endif
	if (water) {
#ifdef SHADE_OWN_TRANSLUCENT
		float3 lit = shadeLit2(half3(1.0h), n, skyLight, blockLight, shadow, false, false, sf, sl);
#ifdef SHADE_DYNLIGHT
		lit += sf.ambientBlock.xyz * shadeDynamicLightsVol(dl, dlIrr, dlDir, p, float3(n), false, blockLight);
#endif
		float4 w = shadeWater(lit, tint, shadeLumaH(half3(texel.rgb)), alpha, p, skyLight, shadow, skyLut, skyLutSmplr, sf);
		radiance = w.rgb;
		alpha = w.a;
#endif
	} else {
#if defined(SHADE_WEATHER) && !defined(SHADE_LEAN_DRY)
		// M3 weather (weather_surface.metal): rain-soaked, darker albedo, puddles on open top faces, snow cover
#ifdef MCOPT_HDR
		ShadeWet wet = shadeWetSurface(p, n, skyLight, thin, foliage, max(length(dpx), length(dpy)), sf, sl, sr.weatherNoise, sl.ssr.z > 0.5, shadeWxVegHue(albedo));
#else
		ShadeWet wet = shadeWetSurface(p, n, skyLight, thin, foliage, max(length(dpx), length(dpy)), sf, sl, skyLut, false, shadeWxVegHue(albedo));
#endif
#ifdef SHADE_WET_ALL
		// M3.3 wet ground: the film gathers in the texture's darker texels (a height proxy: the texel against its sprite's mean,
		// the atlas' coarsest mip; far away the texture's own mip evens it out) instead of lying on the block like varnish
		if (wet.film > 0.0h && wet.omega > 0.05h && sl.waterAbs.z > 0.0)
			wet.tex = shadeWetTexHeight(half3(texel.rgb), half3(atlas.sample(atlasSampler, uv, level(4.0)).rgb), sl);
#endif
#ifdef SHADE_SNOW_GRAIN
		// (2026-10-11) the snow cover keeps a trace of the block's texture (the texel against its sprite's mean): snow lying on
		// the block instead of a flat white sheet
		if (wet.snow > 0.0h)
			wet.grain = half(clamp(float(shadeLumaH(half3(texel.rgb))) / max(float(shadeLumaH(half3(atlas.sample(atlasSampler, uv, level(4.0)).rgb))), 0.02) - 1.0, -0.5, 0.5));
#endif
		half3 wetAlbedo = debug == 3 ? albedo : shadeWetAlbedo(albedo, wet);
#else
		half3 wetAlbedo = albedo;
#endif
		// Nether/End (dims module): shadeLit2 without sky light and sun, plus the dimension's own light (shadeLitDimsExtra)
		radiance = shadeLit2(wetAlbedo, materialN, dims ? half(0.0) : skyLight, blockLight, dims ? half(0.0) : shadow, thin, foliage, sf, sl);
		if (dims) radiance += shadeLitDimsExtra(wetAlbedo, materialN, shadow, thin, foliage, p, sf, sl);
#ifdef SHADE_DYNLIGHT
		radiance += float3(wetAlbedo) * sf.ambientBlock.xyz * shadeDynamicLightsVol(dl, dlIrr, dlDir, p, float3(materialN), thin, blockLight);
#endif
#if defined(MCOPT_HDR) && defined(SHADE_PBR)
		if (pbr) {
			float3 materialLit = radiance;
			radiance *= materialAo;
			// G is linear F0 below 230, otherwise an albedo-coloured conductor.
			bool metal = materialS.g * 255.0 > 229.5;
			float3 F0 = metal ? float3(albedo) : float3(materialS.g);
			if (sl.user3.z > 0.0 && max3(F0.r,F0.g,F0.b) > 0.0) {
				float rough = max((1.0-materialS.r)*(1.0-materialS.r), 0.045);
				float3 N = float3(materialN), V = normalize(p-shadeEye(sf.invViewProj));
				float nv = saturate(dot(N,-V));
				float3 F = F0 + (1.0-F0)*pow(1.0-nv,5.0);
				float3 R = reflect(V,N);
				float3 env = mix(shadeSkyLookup(float3(R.x,max(R.y,0.0),R.z),skyLut,skyLutSmplr,sf),
				    sf.ambientSky.rgb, saturate(rough*1.6));
				float open = float(shadeSkyCurve(skyLight));
				// Nether/End have their own ambient environment, even with zero vanilla skylight.
				if (dims) env = mix(sf.ambientGround.rgb,sf.ambientSky.rgb,saturate(R.y*0.5+0.5));
				else env = mix(sf.ambientGround.rgb,env,smoothstep(-0.15,0.15,R.y))*open;
				// Approximate the local reflected fill from the lighting already evaluated above (torches, held lights,
				// cave minimum). A conductor in a lit cave must not become black just because it sees no sky.
				env += materialLit / max(float3(wetAlbedo),0.02) * ((1.0-open)*0.5);
				float3 direct = dims ? float3(0.0) : sf.sunColor.rgb * min(soPbrGgx(N,V,sf.lightDirWorld.xyz,max(rough*rough,0.0025)),60.0)
				    * float(shadow)*float(smoothstep(0.3h,0.8h,skyLight))*(1.0-sl.wet.w);
				radiance = radiance*(1.0-min(sl.user3.z,1.0)*(metal ? float3(1.0) : F0))
				    + (env*F*materialAo+direct*F)*sl.user3.z;
			}
			float emission = materialS.a; // CPU decoded labPBR A=255 to zero before filtering
			radiance += float3(albedo)*sf.ambientBlock.xyz*(emission*4.0*sl.user3.w);
		}
#endif
		// Light sources until a material mask: at block light 14-15, bright warm texels (torch and lantern flames, glowstone, lava,
		// shroomlights) glow instead of being lit like the rest of the block (stronger in the Nether).
		half tl = shadeLumaH(half3(texel.rgb));
		if (blockLight > 0.92h && texel.r > 0.9 && tl > 0.62h && texel.r > texel.b + 0.12)
			radiance += float3(albedo) * float3(sf.ambientBlock.xyz) * ((netherLit ? 3.1 : 2.2) * sl.user0.w); // (1.1) user0.w: glowing blocks
#ifdef SHADE_WEATHER
#if defined(SHADE_COLOR_SHADOW) && defined(MCOPT_HDR)
		// light that came through stained glass, ice or water takes their colour (the shadow pass's tint map, near cascade)
		if (!dims && shadow > 0.0h && skyLight > 0.3h && sl.ssr.w > 0.5 && !shadeDev(sf, SHADE_DEV_WX_NO_TINT))
			radiance += shadeShadowTintDelta(wetAlbedo, n, skyLight, shadow, shadeShadowTint(p, n, sf, sl, sr.shadowTint), thin, foliage, sf);
#endif
#if defined(SHADE_LIGHTNING) && !defined(SHADE_LEAN_DRY)
		if (!dims) radiance += shadeWxFlash(wetAlbedo, n, skyLight, sl); // ShadeLook.flash is the End flash in the End
#endif
#ifndef SHADE_LEAN_DRY
		{
			ShadeWetLight wl;
			wl.p = p;
			wl.n = n;
			wl.sky = skyLight;
			wl.shadow = shadow;
			wl.pixel = in.fragCoord.xy;
#ifdef MCOPT_HDR
			wl.prevExposure = sl.ssr.x > 0.5 ? sg.exposure.z : 0.0;
			wl.histOk = sl.ssr.x > 0.5 && sl.ssr.y > 0.5;
			radiance = shadeWetShade(radiance, wetAlbedo, wet, wl, sf, sl, skyLut, skyLutSmplr, sr.prevScene, sr.prevDepth);
#else
			wl.prevExposure = 0.0;
			wl.histOk = false;
			radiance = shadeWetShade(radiance, wetAlbedo, wet, wl, sf, sl, skyLut, skyLutSmplr, skyLut, skyLut);
#endif
		}
		if (debug == 8) radiance = float3(float(wet.omega), float(wet.puddle), float(wet.snow)) * 0.25 / max(ex, 1e-3);
#endif
#endif
#if defined(SHADE_WATER) && defined(SHADE_GLOSSY)
		// the water module's glossy translucents (stained glass, ice, slime, honey): mirror reflection over the lit colour
		if (!thin && !shadeDev(sf, SHADE_DEV_NO_WATER)) {
#ifdef MCOPT_HDR
#ifdef SHADE_SSR_PREV
			float prevEx = sl.ssr.x > 0.5 ? sg.exposure.z : 0.0;
#else
			float prevEx = 0.0;
#endif
			float4 gl = shadeGlossy(radiance, alpha, p, float3(n), in.fragCoord.xy, skyLight, shadow, ex, prevEx, sf, &sl, &sr, wp, skyLut,
			                        skyLutSmplr, sceneCopy, depthCopy, sr.prevScene, waterCoarse);
#else
			float4 gl = shadeGlossy(radiance, alpha, p, float3(n), in.fragCoord.xy, skyLight, shadow, ex, 0.0, sf, nullptr, nullptr, wp, skyLut,
			                        skyLutSmplr, sceneCopy, depthCopy, sceneCopy, waterCoarse);
#endif
			radiance = gl.rgb;
			alpha = gl.a;
		}
#endif
	}
	float fogValue = SHADE_FOG_VALUE;
#undef SHADE_FOG_VALUE
	if (!dims && !(waterFull && SHADE_WDEV_IS(sf, SHADE_WDEV_NO_FOG))) { // Nether/End: the final pass fogs
#ifdef MCOPT_HDR
		radiance = shadeFogAir2(radiance, p, fogValue, 1.0 - float(fade), skyLut, skyLutSmplr, sf, sl, &sr);
#else
		radiance = shadeFogAir2(radiance, p, fogValue, 1.0 - float(fade), skyLut, skyLutSmplr, sf, sl);
#endif
	}
	float3 rgb = shadeFinish2(radiance, fogValue, sf, sl, ex);
	if (debug == 2) rgb = shadeVanillaOut(float3(n) * 0.5 + 0.5, sl);
	if (debug == 1) {
		float d = length(p);
		float3 tint1 = sf.flags.z == 0 ? float3(1.0, 0.3, 0.3) : d < sf.cascadeSplits.x ? float3(0.4, 1.0, 0.4) : d < sf.cascadeSplits.y ? float3(0.4, 0.6, 1.0) : float3(1.0);
		rgb = shadeVanillaOut(tint1 * (0.25 + 0.75 * float(shadow)), sl);
	}
	return float4(rgb, alpha);
}
