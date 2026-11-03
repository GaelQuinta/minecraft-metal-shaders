// Copyright 2026 mcopt-shade contributors. Licensed under the Apache License, Version 2.0.
//
// FT1: fragment stage for Distant Horizons' LOD terrain, lit by the shade model (written for mcopt; DH's own stage is
// replaced, only its uniform block layout is shared). The LOD gets what Sodium's terrain gets, minus what a LOD has no
// data for: sun / moon N.L and sky / ground ambient by its sky light (shadeLit2), warm block light by its block light, the
// volumetric clouds' shadow, the aerial perspective and haze toward the sky behind (shadeFogAir2, which in this RGBA8
// compile also applies the height haze the final pass gives the world: the final pass skips DH's pixels, not in its
// depth), the game's fog under water / in lava. No terrain shadow lookup (the cascades end long before the LODs start).
//
// Output: DH composites its LODs into the frame's display-referred main colour, which ShadePost's bridge decodes back
// into the HDR world target (shade_bridge_decode: shadeLdrToHdr). So the LOD writes its pre-exposed radiance through the
// same display transform the bridge's encode uses: it comes back as that radiance (8-bit display steps).
// Prepended: "#define MCOPT_SHADE", the shade prelude and the MCOPT_SLOT_* defines of the pipeline's uniforms.

struct DhFrag {        // DH's "fragUniformBlock"
	float clipDistance;
	float noiseIntensity;
	int noiseSteps;
	int noiseDropoff;
	uint dither;
	uint noiseEnabled;
};

struct DhIn {
	float3 p [[user(locn0)]];
	float3 cell [[user(locn1)]];
	half4 color [[user(locn2)]];
	uint pk [[user(locn3), flat]]; // (FT2.8) light nibbles, face, tile: dh_terrain.vs
};

// face 0..5: down, up, north (-z), south (+z), west (-x), east (+x)
static inline half3 dhNormal(uint face) {
	switch (face) {
		case 0u: return half3(0.0h, -1.0h, 0.0h);
		case 1u: return half3(0.0h, 1.0h, 0.0h);
		case 2u: return half3(0.0h, 0.0h, -1.0h);
		case 3u: return half3(0.0h, 0.0h, 1.0h);
		case 4u: return half3(-1.0h, 0.0h, 0.0h);
		default: return half3(1.0h, 0.0h, 0.0h);
	}
}

// where in its 16x16 texture tile a face point falls (upright on the sides, as the block's own texture is drawn)
static inline float2 dhTileUv(float3 cell, uint face) {
	float3 q = fract(cell);
	float2 uv = face <= 1u ? q.xz : face <= 3u ? float2(q.x, 1.0 - q.y) : float2(q.z, 1.0 - q.y);
	if (face == 0u) uv.y = 1.0 - uv.y;
	if (face == 2u || face == 5u) uv.x = 1.0 - uv.x;
	return uv;
}

// (FT2.8, audit idx 107) dhTileUv's axes without the wrap: the tile sample's mip gradients (implicit ones jump by a whole
// tile across every block edge, so the 2x2 quads there took mip ~4, the tile's flat mean: a 1-px grid along the block edges
// of the nearer LODs that crawled with the TAAU jitter)
static inline float2 dhFaceCoord(float3 cell, uint face) {
	return face <= 1u ? cell.xz : face <= 3u ? cell.xy : cell.zy;
}

// 4x4 ordered threshold (0..15 / 16), for the dithered hand-over to the game's own chunks
static inline float dhBayer(float2 px) {
	uint2 i = uint2(px) & 3u;
	uint b = ((i.x ^ i.y) & 1u) << 3 | (i.y & 1u) << 2 | ((i.x ^ i.y) & 2u) | (i.y & 2u) >> 1;
	return float(b) / 16.0;
}

#ifdef SHADE_DH_TRANSLUCENT
// (1.2.7 candidate 6; water DESIGN.md S6) the near water's swell on the LODs' sea, so the far sea keeps its long bands and there is no
// seam where the chunks end. KEEP IN SYNC with water.metal (SHADE_SWELL / SHADE_SWELL_PHASE / shadeWaterSwell / shadeWaterSwellMask,
// shadeWaterOmega, shadeWaterXZ): the same 4 waves on the same 512-block lattice, the same clock and the same pixel-footprint fade,
// so at the edge of the chunks both draw the same surface. (water.metal is not in this library: a copy, prefixed dh.)
constant int3 DH_SWELL[4] = { int3(11, 6, 80), int3(15, 2, 56), int3(8, 14, 48), int3(19, 12, 40) };
constant float DH_SWELL_PHASE[4] = {0.9, 3.7, 5.3, 2.2};
static inline float dhWaterOmega(float w) { return rint(w * (4096.0 / 6.2831853)) * (6.2831853 / 4096.0); }
// xy the slope at amp, w the faded trains' slope variance at amp (water.metal shadeWaterSwell without the height)
static float4 dhWaterSwell(float2 x, float t, float4 dxz, float amp) {
	float4 o = 0.0;
	const float base = 6.2831853 / 512.0;
	for (int i = 0; i < 4; i++) {
		int3 l = DH_SWELL[i];
		float2 kv = float2(l.xy) * base;
		float k = length(kv);
		float2 dir = kv / k;
		float s = float(l.z) * 1e-3;
		float ext = max(abs(dot(dir, dxz.xy)), abs(dot(dir, dxz.zw))) * (k * (1.0 / 6.2831853));
		float lod = 1.0 - smoothstep(0.125, 0.25, ext);
		float th = dot(kv, x) + dhWaterOmega(sqrt(9.81 * k) * 0.62) * t + DH_SWELL_PHASE[i];
		float c;
		float sn = sincos(th, c);
		float e = exp(sn - 1.0);
		float sa = s * amp;
		o.xy += dir * (sa * c * e * lod);
		o.w += sa * sa * 0.1076 * (1.0 - lod * lod);
	}
	return o;
}
static inline float2 dhWaterSwellMask(float2 s, float3 v, float k) {
	float2 vh = v.xz * rsqrt(max(dot(v.xz, v.xz), 1e-8));
	float al = dot(s, vh);
	return s + vh * (max(al, -k * (-v.y) * rsqrt(max(1.0 - v.y * v.y, 1e-6))) - al);
}
#endif

fragment float4 main0(DhIn in [[stage_in]], constant DhFrag &u [[buffer(MCOPT_SLOT_fragUniformBlock)]],
                      texture2d<float> atlas [[texture(MCOPT_SLOT_uBlockAtlas)]], sampler atlasSmplr [[sampler(MCOPT_SLOT_uBlockAtlas)]],
                      constant ShadeFrame &sf [[buffer(16)]], constant ShadeLook &sl [[buffer(17)]], constant ShadeGpu &sg [[buffer(18)]],
                      constant ShadeResources &sr [[buffer(19)]], texture2d<half> skyLut [[texture(17)]], sampler skyLutSmplr [[sampler(13)]],
                      texture2d<float> lightMap [[texture(MCOPT_SLOT_uLightMap)]], sampler lightMapSmplr [[sampler(MCOPT_SLOT_uLightMap)]],
                      float4 fragCoord [[position]]) {
	uint face = (in.pk >> 8) & 7u, tile = in.pk >> 11, l = in.pk & 0xFFu;
#ifdef SHADE_DH_SKY_HIGH
	half2 light = half2(half(l & 15u), half(l >> 4)) / 15.0h;
#else
	half2 light = half2(half(l >> 4), half(l & 15u)) / 15.0h; // x block light, y sky light, 0..1
#endif
	float3 p = in.p;
	float d = length(p);
	// the tile's mip gradients, before any discard (the whole 2x2 quad takes part), as at native resolution under TAAU
	// (cameraBlock.w: the render scale, mip bias log2(scale), like Sodium's terrain)
	float2 fc = dhFaceCoord(in.cell, face);
	float mipScale = (sf.cameraBlock.w > 0.0 ? sf.cameraBlock.w : 1.0) * 16.0;
	float2 tdx = dfdx(fc) * mipScale, tdy = dfdy(fc) * mipScale;
#ifdef SHADE_DH_TRANSLUCENT
	float4 pdxz = float4(dfdx(p).xz, dfdy(p).xz); // (candidate 6) the swell's footprint, here where the whole quad runs
#endif
	// the game's chunks own everything nearer than DH's clip distance: a hard cut, or a dithered one over 1-1.5x of it
	// (SHADE_DH_NOCLIP, dev: none, to price the discard: a pipeline that may discard loses the GPU's hidden-surface removal)
#ifndef SHADE_DH_NOCLIP
	if (u.dither != 0u) {
		if (smoothstep(u.clipDistance, u.clipDistance * 1.5, d) <= dhBayer(fragCoord.xy) + 0.001) discard_fragment();
	} else if (u.clipDistance > 0.0 && d < u.clipDistance) {
		discard_fragment();
	}
#endif
	// albedo: the block's colour, with the tile's detail around it (the tile stores the texture relative to its mean,
	// 0.5 = the mean: x2), weighed by the tile's alpha
	half3 srgb = in.color.rgb;
	if (tile != 0u) {
		float2 cellOrigin = float2(float(tile & 255u), float(tile >> 8)) * 16.0;
		float2 asz = float2(atlas.get_width(), atlas.get_height());
		float4 t = atlas.sample(atlasSmplr, (cellOrigin + dhTileUv(in.cell, face) * 16.0) / asz, gradient2d(tdx / asz, tdy / asz));
		srgb = mix(srgb, saturate(srgb * half3(t.rgb) * 2.0h), half(t.a));
	}
	// not lit by the shade model (Nether / End without the dims module's light, the setup fallback's vanilla frames): the
	// game's lightmap, as DH draws it, and the game's fog colour over the environmental range
	if (sf.flags.x > SHADE_DIM_END || (sf.flags.x != SHADE_DIM_OVERWORLD && !shadeDimsLit(sf))) {
		// the game's lightmap at those levels (u = block light, v = sky light, texel centres), as DH draws it
		float3 v = float3(srgb) * lightMap.sample(lightMapSmplr, (float2(light) * 15.0 + 0.5) / 16.0, level(0.0)).rgb;
		float fa = saturate((d - sf.fogRange.x) / max(sf.fogRange.y - sf.fogRange.x, 1.0)) * sf.fogColor.a;
		return float4(mix(v, sf.fogColor.rgb, fa), in.color.a);
	}
	half3 n = dhNormal(face);
	half block = light.x, sky = light.y;
	half3 albedo = shadeToLinear(srgb);
	bool overworld = sf.flags.x == SHADE_DIM_OVERWORLD;
	float ex = max(sg.exposure.x, 1e-6);
	float3 radiance;
	half outAlpha = in.color.a;
	if (!overworld) {
		// Nether / End with the dims module: the dimension's own light (shade_dims.metal), as Sodium's terrain without sky light
		radiance = shadeLit2(albedo, n, half(0.0), block, half(0.0), false, false, sf, sl);
		radiance += shadeLitDimsExtra(albedo, n, half(1.0), false, false, p, sf, sl);
	} else {
		// no terrain shadow map out here: direct light where the sky is open (shadeLit2 gates it by sky light), dimmed by
		// the volumetric clouds' shadow
		half shadow = sky > 0.3h ? half(shadeCloudShadow(p, sl, sr.cloudShadow)) : half(1.0);
#ifndef SHADE_DH_TRANSLUCENT
		// (FT2.8, audit idx 103) the weather layer's cheap uniform part (weather_surface.metal shadeWetSurface / shadeWetAlbedo, which
		// the LODs don't include): wet ground darkens and up faces take the snow cover's mean, so no dry, bright ring of LODs stands
		// behind the rain-darkened (or snow-covered) near terrain
		if (sl.wet.x > 0.0 || sl.wet.z > 0.001) {
			half open = smoothstep(0.90h, 0.995h, sky);
			half face = n.y > 0.5h ? 1.0h : n.y < -0.5h ? 0.0h : 0.55h;
			half2 reach = shadeWxReach(p.y + sf.cameraFract.y + sf.cameraBlock.y, sf); // (2026-10-11) snow above the snow line, rain below
			half snow = n.y > 0.5h && sl.wet.z > 0.001
				? half(smoothstep(1.0 - float(sl.wet.z) * 1.15, 1.15 - float(sl.wet.z) * 1.15, 0.65) * saturate(float(sl.wet.z) * 40.0)) * open * reach.x : 0.0h;
			half om = half(sl.wet.x) * open * face * (1.0h - snow) * reach.y;
			if (shadeWxVegLight(sf)) om *= 1.0h - 0.67h * shadeWxVegHue(albedo); // (2026-10-12) like shadeWetAlbedo: no seam at the chunks' edge
			if (om > 0.0h) albedo = pow(max(albedo, half3(1e-4h)), half3(1.0h + 0.65h * om)) * (1.0h - 0.08h * om);
			if (snow > 0.0h) albedo = mix(albedo, half3(0.86h, 0.88h, 0.92h), snow);
		}
#endif
#ifdef SHADE_DH_TRANSLUCENT
		// (1.1) the player's water colour (ShadeSettings; ShadeLook.vl: linear, weight in w): the LODs' water takes its hue and keeps
		// DH's brightness, so the far sea matches the near water's chosen colour
		if (face == 1u && in.color.a < 0.99h && sl.vl.w > 0.0) {
			float3 u = sl.vl.rgb;
			float k = shadeLuma(float3(albedo)) / max(shadeLuma(u), 1e-3);
			albedo = half3(mix(float3(albedo), min(u * k, float3(1.0)), sl.vl.w));
		}
#endif
		radiance = shadeLit2(albedo, n, sky, block, shadow, false, false, sf, sl);
		// (FT2.7, audit idx 74) a lightning flash lights the LODs like the terrain (shadeWxFlash): no dark seam at the chunks' edge
		if (sl.flash.w > 0.0) {
			half gk = shadeSkyCurve(sky);
			radiance += float3(albedo) * float3(0.78, 0.86, 1.0) * (sl.flash.w * (saturate(dot(float3(n), sl.flash.xyz)) * 0.65 + 0.35) * float(gk * gk));
		}
#ifdef SHADE_DH_TRANSLUCENT
		// FT2.5: the LODs' water (DH's translucent top faces) mirrors the sky like the near water (water.metal): Schlick's
		// Fresnel for water, the atmosphere and the volumetric clouds (their reflection dome) in the mirrored direction, the
		// sun's glint with the near water's far roughness (its glitter road goes on past the chunks). A flat surface out
		// here: waves average out over a LOD pixel. The reflection draws opaque in proportion to its Fresnel weight, as the
		// near water's does; DH's water colour (lit) shows through the rest. No terrain in it (no depth for SSR out here).
		if (face == 1u && in.color.a < 0.99h && !shadeDev(sf, SHADE_DEV_FLAT_LIGHT)) {
			float3 v = p / max(d, 1e-4);
			// the waves a LOD pixel averages over (slope ~0.2): at grazing views the facets that face the eye reflect at a
			// steeper angle (less: Fresnel ~0.34, not 1) and higher into the sky (bluer than the horizon). As a flat mirror the far
			// sea took the whole white horizon haze and read as milk (w1, Gael 2026-10-09: "se ve rara")
			const float slope2 = 0.2 * 0.2;
			// (candidate 6, S6) the swell as the near water draws it past 120 blocks (sl.user2.z: its strength x the open sea's share x
			// the wet, ShadeWater.dhSwell; 0 = candidate 5's flat statistical sea): the Fresnel with all of its slope, the mirrored
			// direction with its share (sl.user2.w, mcopt.shade.water.swellRefl) as the near water's, the faded trains as roughness
			float3 ns = float3(0.0, 1.0, 0.0), nr = ns;
			float lost = 0.0;
			if (sl.user2.z > 0.0) {
				float t = sf.sunPath.w;
				float2 x = p.xz + sf.cameraFract.xz + fmod(sf.cameraBlock.xz, 2048.0);
				float4 sw = dhWaterSwell(x, t, pdxz, sl.user2.z * (1.0 + 0.6 * sf.weather.y));
				float2 s = dhWaterSwellMask(sw.xy, v, 0.45);
				ns = normalize(float3(-s.x, 1.0, -s.y));
				nr = normalize(float3(-s.x * sl.user2.w, 1.0, -s.y * sl.user2.w));
				lost = sw.w;
			}
			float c0 = max(dot(-v, ns), 0.0), cr = max(dot(-v, nr), 0.0);
			float cosV = sqrt(c0 * c0 + slope2 + lost);
			float cosR = sqrt(cr * cr + slope2 + lost);
			float3 rf = reflect(v, nr);
			float3 r = float3(rf.xz * (sqrt(max(1.0 - cosR * cosR, 0.0)) / max(length(rf.xz), 1e-4)), cosR).xzy;
			float open = float(shadeSkyCurve(sky));
			float m = 1.0 - saturate(cosV);
			// (1.1) user1.x: the player's reflection strength (the near water's tune.z), at most a full mirror
			float fr = min((0.0204 + 0.9796 * m * m * m * m * m) * (0.35 + 0.65 * open) * sl.user1.x, 1.0);
			// (FT2.8, audit idx 115) the screen-space part first; the sky LUT and the clouds' dome only where it doesn't cover it all
			float3 scr = float3(0.0);
			float wS = 0.0;
			// w3 (Gael: the far sea's reflections looked low quality, a flat colour): where the flat mirror direction is on
			// screen, the rendered sky there (last frame's HDR image, as the near water's shadeWaterSkyRefl does): the clouds at
			// full resolution, the sunset's colours, the far islands (LODs are not in the depth: they count as sky). Anything the
			// depth holds nearer than ~500 blocks (the game's own chunks) is not what the far sea mirrors: the dome / LUT there.
			// Faded out over the last 1/8 of the screen. Needs TAAU's depth of that image (ShadeLook.ssr.y).
			if (sl.ssr.x > 0.5 && sl.ssr.y > 0.5 && sl.user1.y > 0.5) { // (1.1) user1.y 0: the player chose sky-only reflections
				float3 rm = reflect(v, nr); // (candidate 6: along the swell's share; the flat mirror without it)
				float4 pc = sl.prevViewProjNoJitter * float4(rm, 0.0); // (FT2.8, as audit idx 35: the TAA history is unjittered)
				if (pc.w > 1e-4) {
					// (FT2.8, audit idx 117) the edge fade from where the texel is actually read (last frame's, unclamped), not this
					// frame's position: border pixels smeared in while turning
					float2 uvp0 = pc.xy / pc.w * 0.5 + 0.5;
					float wgt = saturate(min(uvp0.x, 1.0 - uvp0.x) * 8.0) * saturate(min(uvp0.y, 1.0 - uvp0.y) * 8.0);
					float2 uvp = saturate(uvp0);
					constexpr sampler lin(filter::linear, address::clamp_to_edge, coord::normalized);
					// (FT2.8, audit idx 105) the nearest surface of the footprint, not a bilinear mean: at a near hill's silhouette the
					// mean of sky and hill passed as sky and pulled the hill into the far sea's reflection
					constexpr sampler nearestClamp(filter::nearest, address::clamp_to_edge, coord::normalized);
					if (wgt > 0.0) {
						half4 dz = sr.prevDepth.gather(nearestClamp, uvp);
						wgt *= smoothstep(400.0, 600.0, float(min(min(dz.x, dz.y), min(dz.z, dz.w))));
					}
					// (FT2.8, audit idx 104) not the sun's / moon's disc: the glint below already stands for the sun on this wavy sea, and
					// the disc mirrored sharp from last frame's image counted it twice (and popped at the screen-edge fade)
					wgt *= 1.0 - smoothstep(cos(4.0 * sl.sunGeom.y), cos(1.5 * sl.sunGeom.y), dot(rm, sf.sunDirWorld.xyz));
					wgt *= 1.0 - smoothstep(cos(4.0 * sl.sunGeom.z), cos(1.5 * sl.sunGeom.z), dot(rm, sf.moonDirWorld.xyz));
					if (wgt > 0.0) {
						scr = float3(sr.prevScene.sample(lin, uvp).rgb) / max(sg.exposure.z, 1e-6);
						wS = wgt;
					}
				}
			}
			float3 refl = scr;
			if (wS < 1.0) {
				float3 skyR = shadeSkyLookup(r, skyLut, skyLutSmplr, sf);
				float4 cd = shadeCloudsDome(r, sl, sr.cloudDome);
				refl = mix(skyR * cd.a + cd.rgb, scr, wS);
			}
			refl *= open;
			// GGX glint (normal up), alpha 0.135: the near water's at 110+ blocks
			float3 l = sf.lightDirWorld.xyz, h = normalize(l - v);
			float nh = saturate(dot(ns, h)), nl = saturate(dot(ns, l)), nv = max(dot(ns, -v), 1e-3); // (candidate 6: the swell's normal; up without it)
			const float a2 = 0.135 * 0.135 * 0.135 * 0.135 + lost; // (candidate 6) + the swell the pixel averages over, as the near water's
			float dd = nh * nh * (a2 - 1.0) + 1.0;
			float vis = 0.5 / max(nl * sqrt(nv * nv * (1.0 - a2) + a2) + nv * sqrt(nl * nl * (1.0 - a2) + a2), 1e-5);
			float mh = 1.0 - saturate(dot(h, -v));
			float spec = a2 / (dd * dd) * vis * nl * (0.0204 + 0.9796 * mh * mh * mh * mh * mh);
			float3 glint = sf.sunColor.rgb * min(spec, 60.0) * float(smoothstep(0.15h, 0.85h, shadow)) * open * (sl.user1.x * sl.user2.x); // (1.1) as the near water's
			float ba = float(in.color.a);
			float aw = fr + (1.0 - fr) * ba;
			radiance = (refl * fr + radiance * ba * (1.0 - fr) + glint) / max(aw, 1e-3);
			outAlpha = half(aw);
		}
#endif
		radiance = shadeFogAir2(radiance, p, 0.0, 0.0, skyLut, skyLutSmplr, sf, sl, &sr);
	}
	if (shadeDev(sf, SHADE_DEV_FLAT_LIGHT)) radiance = float3(albedo) * sf.ambientSky.xyz;
	if (sf.flags.w == 2) radiance = (float3(n) * 0.5 + 0.5) / ex * 0.18; // debug view 2: normals
	float3 c = min(max(radiance, 0.0) * ex, 60000.0);
	// (FT2.8, audit idx 101) the Nether's / End's medium on the LODs too (the final pass gives it to the near terrain from the main
	// depth, which holds no LODs): sharp unhazed LOD terrain stood behind a wall of smoke at the render distance
	if (!overworld) c = shadeDimsFog(c, p, true, sf, sl, ex, false, sr.milkyWay, false);
	// the game's own fog (under water, in lava / powder snow, blindness; outside the overworld) over the environmental range
	float a = sf.fogColor.a * saturate((d - sf.fogRange.x) / max(sf.fogRange.y - sf.fogRange.x, 1.0));
	if (a > 0.0) {
		float3 t = sf.flags.y == 1 ? pow(1.0 - a, float3(2.6, 1.25, 1.0)) : float3(1.0 - a);
		c = c * t + shadeLdrToHdr(sf.fogColor.rgb, sl) * (1.0 - t);
	}
	return float4(shadeLinearToSrgbExact(saturate(shadeDisplay(c, sl))), outAlpha);
}
