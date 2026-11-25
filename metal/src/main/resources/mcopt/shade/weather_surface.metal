// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// mcopt native shading, M3 weather (shader bible E13 + E08's coloured shadows), the receiver side: wet surfaces, puddles
// with reflections, raindrop ripples, snow cover, lightning light, and the tint of light that came through stained glass or
// water (the shadow pass's tint map). Original code; the techniques are public (Schlick 1994, Walter et al. 2007 GGX,
// Lagarde 2011 roughness-aware Fresnel, McGuire & Mara 2014 screen-space marching, value noise).
//
// Assembled by ShadeMsl.terrain after the prelude (shade_look + shade_common + shade_m2) and before water.metal, with the
// SHADE_WEATHER defines (mcopt.metal.shade.weather.ShadeWeather.prelude) in front. Inputs:
//   ShadeLook.wet    x wetness 0..1, y puddles 0..1, z snow cover 0..1, w rain intensity (smoothed rain level, + thunder)
//   ShadeLook.wind   xy wind direction (unit, world xz), z rain slant (horizontal blocks per block of fall), w snowfall at the camera 0..1
//   ShadeLook.flash  xyz unit direction toward the lightning (camera-relative), w its light (radiance on a white surface
//                    facing it, before exposure)
//   ShadeLook.ssr.y  1 when ShadeResources.prevDepth (5) holds the linear view depth of ShadeResources.prevScene (TAA history)
//   ShadeResources   prevScene (1), prevDepth (5, R16F, blocks along last frame's view axis), shadowTint (6, RGBA16F: rgb
//                    the transmittance of the translucent casters, a their reversed-Z light depth, near cascade only)
// UNITS: as shade_common.metal (camera-relative world, blocks; radiance before exposure; reversed-Z).
#ifndef MCOPT_SHADE_WEATHER_SURFACE
#define MCOPT_SHADE_WEATHER_SURFACE

#ifndef SHADE_PUDDLE_STEPS
#define SHADE_PUDDLE_STEPS 10
#endif
#ifndef SHADE_PUDDLE_DIST
#define SHADE_PUDDLE_DIST 64.0
#endif
// steps per lane: with the quad-shared march each lane takes a quarter of the ray
#ifdef SHADE_PUDDLE_QUAD
#define SHADE_PUDDLE_N (SHADE_PUDDLE_STEPS / 4 > 2 ? SHADE_PUDDLE_STEPS / 4 : 2)
#else
#define SHADE_PUDDLE_N SHADE_PUDDLE_STEPS
#endif

// the budget gates (SHADE_DEV_WX_SUN_GATE, RIPPLE_GATE, LITE_RAIN): always on with SHADE_WX_LITE, else per dev bit
#ifndef SHADE_WX_BUDGET
#ifdef SHADE_WX_LITE
#define SHADE_WX_BUDGET(f, bit) true
#else
#define SHADE_WX_BUDGET(f, bit) shadeDev(f, bit)
#endif
#endif

// M3.3 rain budget options (mcopt.shade.rainBudget: ShadeWeather defines SHADE_WX_B_GATE / _RIPPLE / _STEPS). For pricing in
// one session (mcopt.shade.rainBudget.dev: SHADE_WX_B_DEV) each is also switched by its dev bit; without either the options
// are constant false, so the compiled shader is M3.2's.
#if defined(SHADE_WX_B_GATE)
#define SHADE_WX_B_GATE_ON(f) true
#elif defined(SHADE_WX_B_DEV)
#define SHADE_WX_B_GATE_ON(f) shadeDev(f, SHADE_DEV_WX_SSR_GATE3)
#else
#define SHADE_WX_B_GATE_ON(f) false
#endif
#if defined(SHADE_WX_B_RIPPLE)
#define SHADE_WX_B_RIPPLE_ON(f) true
#elif defined(SHADE_WX_B_DEV)
#define SHADE_WX_B_RIPPLE_ON(f) shadeDev(f, SHADE_DEV_WX_RIPPLE_NEAR)
#else
#define SHADE_WX_B_RIPPLE_ON(f) false
#endif
#if defined(SHADE_WX_B_STEPS)
#define SHADE_WX_B_STEPS_ON(f) true
#elif defined(SHADE_WX_B_DEV)
#define SHADE_WX_B_STEPS_ON(f) shadeDev(f, SHADE_DEV_WX_SSR_STEPS8)
#else
#define SHADE_WX_B_STEPS_ON(f) false
#endif

constexpr sampler shadeWxLinear(filter::linear, address::clamp_to_edge, coord::normalized);
constexpr sampler shadeWxNearest(filter::nearest, address::clamp_to_edge, coord::normalized);

// ---- noise on the absolute world xz -------------------------------------------------------------------------------------
// The camera block wraps every 4096 blocks; every lattice below has a period that divides 4096, so the wrap is seamless.
static inline float2 shadeWxXZ(float2 rel, constant ShadeFrame &f) {
	return rel + f.cameraFract.xz + fmod(f.cameraBlock.xz, 4096.0);
}

static inline float shadeWxHash(int2 c, uint salt) {
	return shadeHash01(shadeHash(uint(c.x) * 0x8da6b343u ^ shadeHash(uint(c.y) * 0xd8163841u ^ salt)));
}

// Value noise (smooth, 0..1) over cells of size 1 in x, wrapping every mask + 1 cells.
static inline float shadeWxValue(float2 x, int mask, uint salt) {
	float2 i = floor(x), u = x - i;
	u = u * u * (3.0 - 2.0 * u);
	int2 c = int2(i);
	float a = shadeWxHash(c & mask, salt), b = shadeWxHash((c + int2(1, 0)) & mask, salt);
	float d = shadeWxHash((c + int2(0, 1)) & mask, salt), e = shadeWxHash((c + int2(1, 1)) & mask, salt);
	return mix(mix(a, b, u.x), mix(d, e, u.x), u.y);
}

// The puddle field: puddles 2-6 blocks across (8-block cells), lobes (4) and ragged rims (2), on a 32-block swell that makes
// some stretches of ground wetter than others. About 0.5 on average (std 0.14): threshold 0.6 covers ~30 % of open ground.
// Every lattice wraps every SHADE_WX_NOISE_TILE (256) blocks, so the field can be baked into one tile (shade_wx_noise_fs).
#define SHADE_WX_NOISE_TILE 256.0
#define SHADE_WX_NOISE_SIZE 1024
static inline float shadeWxPuddleField(float2 xa) {
	// (the swell's seed was picked so the bench's rain pose has puddles in view: 37 % of the ground there, 31 % on average)
	float big = shadeWxValue(xa * (1.0 / 32.0), 7, 0xfbb04194u);
	return 0.5 * shadeWxValue(xa * 0.125, 31, 0x51ed270bu) + 0.3 * shadeWxValue(xa * 0.25, 63, 0x2c1b3c6du)
		+ 0.2 * shadeWxValue(xa * 0.5, 127, 0x297a2d39u) + 0.25 * (big - 0.5);
}

// Snow drifts: patchy, with the puddle field's hollows filling first.
static inline float shadeWxSnowDrift(float2 xa) {
	return shadeWxValue(xa * 0.5, 127, 0x1f83d9abu) * 0.6 + shadeWxPuddleField(xa + 37.0) * 0.4;
}

// The bake (ShadeWeather.bakeNoise, once): r = puddle field, g = snow drift over one 256-block tile, 4 texels per block
// (RG16F 1024^2, 4 MB). The terrain samples it bilinearly (repeat) instead of evaluating 6 value noises (24 hashes) per pixel.
// Only in the bake's own library (SHADE_WX_NOISE_BAKE): the terrain libraries don't carry the extra entry point.
#ifdef SHADE_WX_NOISE_BAKE
fragment half4 shade_wx_noise_fs(float4 pos [[position]]) {
	float2 xa = pos.xy * (SHADE_WX_NOISE_TILE / float(SHADE_WX_NOISE_SIZE));
	return half4(half(shadeWxPuddleField(xa)), half(shadeWxSnowDrift(xa)), 0.0h, 1.0h);
}
#endif

constexpr sampler shadeWxRepeat(filter::linear, address::repeat, coord::normalized);

// (puddle field, snow drift) at absolute xz: the baked tile when the caller has it (ShadeResources.weatherNoise), else analytic.
// LDR variants (no ShadeResources, so no tile): a lite field, only the one that is needed, from 3 (puddles) or 2 (snow) value
// noises instead of 9 (the same 8/4-block shapes and 32-block swell, without the 2-block ragged rims).
static inline float2 shadeWxFields(float2 xa, texture2d<half> noise, bool baked, bool puddly, bool snowy) {
	if (baked) return float2(noise.sample(shadeWxRepeat, xa * (1.0 / SHADE_WX_NOISE_TILE), level(0.0)).rg);
#ifndef MCOPT_HDR
	float2 r = float2(0.0);
	if (puddly) r.x = 0.62 * shadeWxValue(xa * 0.125, 31, 0x51ed270bu) + 0.38 * shadeWxValue(xa * 0.25, 63, 0x2c1b3c6du)
		+ 0.25 * (shadeWxValue(xa * (1.0 / 32.0), 7, 0xfbb04194u) - 0.5);
	if (snowy) r.y = shadeWxValue(xa * 0.5, 127, 0x1f83d9abu) * 0.6 + shadeWxValue((xa + 37.0) * 0.125, 31, 0x51ed270bu) * 0.4;
	return r;
#else
	return float2(shadeWxPuddleField(xa), shadeWxSnowDrift(xa));
#endif
}

// ---- raindrop ripples -----------------------------------------------------------------------------------------------------
// Two staggered grids of 0.7-block cells; each cell gets a drop every 0.55-1.05 s (fewer in light rain), at a random point
// of its central half, which spreads a ring at 0.42 blocks/s that fades in about half a second and never leaves the cell.
// Ring profile: a damped sine packet around the radius rho, h = a sin(2 pi e / lambda) exp(-(e / w)^2), e = r - rho; the
// slope comes from its analytic derivative. Returns the height gradient (dh/dx, dh/dz) in blocks per block.
#define SHADE_RIPPLE_CELL 0.7
#ifndef SHADE_RIPPLE_LAYERS
#define SHADE_RIPPLE_LAYERS 2
#endif
static float2 shadeWxRipples(float2 xa, float t, float rate, float footprint) {
	float2 g = float2(0.0);
	// farther away the rings widen with the pixel footprint (a band-limited ring instead of an aliasing one), weaker by the
	// same factor so the slope energy stays comparable
	float widen = max(1.0, footprint * (1.0 / 0.011));
	const float C = SHADE_RIPPLE_CELL;
	float lambda = 0.075 * widen, wid = 0.055 * widen, k = 6.2831853 / lambda;
	for (int layer = 0; layer < SHADE_RIPPLE_LAYERS; layer++) {
		float2 q = xa * (1.0 / C) + (layer == 0 ? float2(0.0) : float2(0.5, 0.37));
		float2 ci = floor(q);
		float2 lp = (q - ci) * C;
		uint h = shadeHash3(int3(int2(ci) & 8191, layer), 0x6a09e667u);
#if SHADE_RIPPLE_LAYERS < 2
		float period = 0.33 + 0.28 * shadeHash01(h); // one grid (performance, balanced): drops come faster, about as many rings
#else
		float period = 0.45 + 0.4 * shadeHash01(h);
#endif
		float ph = t / period + shadeHash01(h ^ 0xbb67ae85u);
		float n = floor(ph);
		float age = (ph - n) * period;
		uint hk = shadeHash(h ^ (uint(int(n)) * 0x9e3779b9u));
		if (shadeHash01(hk) > rate) continue;
		float2 c0 = (0.3 + 0.4 * float2(shadeHash01(hk ^ 0x3c6ef372u), shadeHash01(hk ^ 0xa54ff53au))) * C;
		float2 d = lp - c0;
		float r = length(d);
		float e = r - age * 0.42;
		// (2.0.1 opt) Gaussian envelope is < 0.002 beyond 2.5*wid: skip exp + sincos completely!
		if (abs(e) > 2.5 * wid) continue;
		float invW2 = 1.0 / (wid * wid);
		float env = exp2((-age * 5.0 - e * e * invW2) * 1.44269504) * (1.0 - smoothstep(0.2 * C, 0.29 * C, r));
		float s;
		float c = sincos(k * e, s);
		float dh = env * (k * c - 2.0 * e * invW2 * s);
		g += dh * d / max(r, 1e-4);
	}
	return g * (0.0055 / widen);
}

// M3.3 wet ground (mcopt.shade.wetAll; ShadeWeather defines SHADE_WET_ALL when it is on at startup, else this file is
// M3.2's): in rain the whole open ground gets a water film (darker, a Fresnel sheen of the sky, the sun's highlight, film
// reflections where they show), puddles are the deeper, mirror-like water in its low spots with a wetter rim around them.
// Its per-frame state is ShadeLook.water (576, reserved for the water module and unused by it; ShadeWeather.pack writes it):
//   x 1 = the wet-all look this frame (0 = M3.2's look: an in-session A/B), y soaked film roughness of stone, paths, wood and
//   sand, z the extra roughness of vegetation (grass tops), w film reflections' gate on F x k x gloss (0 = no film reflections)
#ifdef SHADE_WET_ALL
#define SHADE_WET_ALL_ON(L) ((L).water.x > 0.5)
#else
#define SHADE_WET_ALL_ON(L) false
#endif

// ---- wet surfaces and puddles -----------------------------------------------------------------------------------------------
struct ShadeWet {
	half omega;   // wetness of this surface 0..1 (darkening, gloss)
	half puddle;  // standing water 0..1
	half snow;    // snow cover 0..1
	float2 slope; // ripple height gradient on puddles (world xz)
	// M3.3 wet ground (SHADE_WET_ALL_ON; 0 otherwise): film 1 = the surface takes the soaked-ground film (solid blocks, not
	// crossed plants or leaves); low 0..1 = how near the puddle threshold the field is here (the wetter rim, film -> puddle);
	// var = the puddle field's slow variation (-0.3..0.3: hollows hold a smoother film)
	half film;
	half low;
	half var;
	half dark; // extra darkening exponent of the film (ShadeLook.waterAbs.x: mcopt.shade.wetDark, 0.2)
	half tex;  // the texel's height proxy -1..1 (sodium_terrain.fs.metal, shadeWetTexHeight): + raised (drier), - a crevice (wetter)
	half grain; // (2026-10-11, SHADE_SNOW_GRAIN) the texel against its sprite's mean - 1, -0.5..0.5: the block's texture under the snow
	half vegK;  // (2026-10-12, shadeWxVegLight) 1: vegetation's albedo darkens a third as much (shadeWetAlbedo)
	half veg;   // (2.0.1 opt) cached shadeWxVegHue(albedo) reused by shadeWetAlbedo & shadeWetShade
};

// (M3.3 wet ground) the texel's height proxy: its luminance against its sprite's mean (the atlas' coarsest mip), scaled by
// ShadeLook.waterAbs.z, -1..1: brighter texels stand out of the film, darker ones hold water
static inline half shadeWetTexHeight(half3 texel, half3 mean, constant ShadeLook &L) {
	return half(clamp((float(shadeLumaH(texel)) / max(float(shadeLumaH(mean)), 0.02) - 1.0) * L.waterAbs.z, -1.0, 1.0));
}

// How wet the surface at camera-relative p is. n: snapped face normal (toward the camera); sky: sky light 0..1 (rain only
// reaches sky light 15: open sky; 14 under an overhang's edge gets a little); thin: crossed plants; foliage: leaves and the
// like (no puddles; they get wet and snow-covered); footprint: blocks per pixel (ripples fade where they would alias).
// veg: shadeWxVegHue of the surface's albedo (2026-10-12, shadeWxVegPuddles: fewer, shallower puddles on grass tops).
static ShadeWet shadeWetSurface(float3 p, half3 n, half sky, bool thin, bool foliage, float footprint, constant ShadeFrame &f,
                                constant ShadeLook &L, texture2d<half> noise, bool baked, half veg = 0.0h) {
	ShadeWet w;
	w.omega = 0.0h;
	w.puddle = 0.0h;
	w.snow = 0.0h;
	w.slope = float2(0.0);
	w.film = 0.0h; // (M3.3 wet ground)
	w.low = 0.0h;
	w.var = 0.0h;
	w.dark = 0.0h;
	w.tex = 0.0h;
	w.grain = 0.0h;
	w.vegK = shadeWxVegLight(f) ? 1.0h : 0.0h;
	w.veg = veg;
	half open = smoothstep(0.90h, 0.995h, sky);
	if (open <= 0.0h || shadeDev(f, SHADE_DEV_WX_DRY)) return w;
	half face = n.y > 0.5h ? 1.0h : n.y < -0.5h ? 0.0h : 0.55h; // walls get wet streaks, undersides stay dry
	half2 reach = shadeWxReach(p.y + f.cameraFract.y + f.cameraBlock.y, f); // (2026-10-11) x snow, y rain
	half rainHere = reach.y;
	w.omega = half(L.wet.x) * open * face * (thin ? 0.45h : foliage ? 0.7h : 1.0h) * rainHere;
	// (M3.3 wet ground: solid blocks take the soaked film; crossed plants and leaves keep M3.2's light film)
	// (2026-10-12, shadeWxWalls; Gael: a pit's wet walls looked whitish, "as if reflecting something that isn't there") only the
	// up faces: water runs off walls, which keep the darkening and a faint rough sheen (as Photon, BSL and SEUS: puddles and
	// smoothness on up faces only)
	if (SHADE_WET_ALL_ON(L) && !thin && !foliage && (n.y > 0.5h || !shadeWxWalls(f))) {
		w.film = 1.0h;
		w.dark = half(L.waterAbs.x);
	}
	float2 xa = shadeWxXZ(p.xz, f);
	bool snowy = false, puddly = false;
#ifdef SHADE_SNOW_COVER
	snowy = L.wet.z > 0.001 && n.y > 0.5h && reach.x > 0.0h;
#endif
#ifdef SHADE_PUDDLES
	puddly = L.wet.y > 0.001 && n.y > 0.5h && !thin && !foliage && sky > 0.95h && rainHere > 0.0h;
#endif
	float2 fields = snowy || puddly ? shadeWxFields(xa, noise, baked && !shadeDev(f, SHADE_DEV_WX_ANALYTIC), puddly, snowy) : float2(0.0);
#ifdef SHADE_SNOW_COVER
	if (snowy) {
		float drift = fields.y;
		// (FT2.8, audit idx 90: the last 2.5 % fades out instead of the deepest drifts' cores vanishing in one frame)
		w.snow = half(smoothstep(1.0 - float(L.wet.z) * 1.15, 1.15 - float(L.wet.z) * 1.15, drift + 0.15) * saturate(float(L.wet.z) * 40.0)) * open * reach.x;
		w.omega *= 1.0h - w.snow;
	}
#endif
#ifdef SHADE_PUDDLES
	if (puddly) {
		float field = fields.x;
		float t = mix(0.80, 0.575, float(L.wet.y)); // ~30 % of open ground at full puddles (25 % at 0.60)
		// (2026-10-12, Gael: rain looked odd; at grazing views the puddles on lawns read as glass slabs) water soaks into a lawn
		// and the blades stand out of what pools: grass tops hold about a third of the puddles (threshold +0.12), x0.7 deep
		half vegP = shadeWxVegPuddles(f) ? veg : 0.0h;
		t += 0.12 * float(vegP);
		// (FT2.8, audit idx 90) times the puddles' last 2.5 %: the field's cores (~0.5 % of open ground) stayed full mirrors down to
		// puddles 0 and blinked out at once when the weather turned dry
		half P = half(smoothstep(t, t + 0.035, field) * saturate(float(L.wet.y) * 40.0)) * smoothstep(0.95h, 0.995h, sky) * (1.0h - w.snow) * rainHere
			* (1.0h - 0.3h * vegP);
		// a darker wet rim around each puddle, and the ground between them stays a little wetter
		w.omega = max(w.omega, half(smoothstep(t - 0.07, t, field)) * half(L.wet.y) * open * rainHere);
		w.puddle = P;
		if (SHADE_WET_ALL_ON(L)) {
			// (M3.3 wet ground) the film thickens toward the puddles over the field's last ShadeLook.waterAbs.w below the threshold
			// (0.12: about half a block to two blocks around each puddle: a smooth film -> standing water rim), and hollows hold a
			// smoother film than its rises (blocks-wide patches: no pixel noise)
			w.low = half(smoothstep(t - L.waterAbs.w, t, field)) * half(L.wet.y) * open * (1.0h - w.snow) * rainHere; // (band: ShadeLook.waterAbs.w)
			w.var = half(clamp(field - 0.5, -0.3, 0.3));
		}
#ifdef SHADE_RIPPLES
		// (M3.3 SHADE_WX_B_RIPPLE: the rings fade out nearer, over 0.02-0.045 blocks per pixel: none beyond ~10 blocks)
		float2 rippleFade = SHADE_WX_B_RIPPLE_ON(f) ? float2(0.02, 0.045) : float2(0.03, 0.06);
		float fade = 1.0 - smoothstep(rippleFade.x, rippleFade.y, footprint);
		if (SHADE_WX_BUDGET(f, SHADE_DEV_WX_RIPPLE_GATE)) {
			// rings show in what the puddle mirrors: where the flat water's Fresnel x P is ~2 % (looking down near the feet)
			// they only stir a uniform overcast sky; fade them in over F*P 0.02-0.035 (the march's gate starts at 0.035)
			float cv = saturate(-p.y * rsqrt(max(dot(p, p), 1e-6)));
			float m = 1.0 - cv;
			float Ff = 0.02 + 0.95 * m * m * m * m * m;
			fade *= smoothstep(0.02, 0.035, Ff * float(P));
		}
		if (P > 0.0h && L.wet.w > 0.01 && fade > 0.0 && !shadeDev(f, SHADE_DEV_WX_NO_RIPPLES)) w.slope = shadeWxRipples(xa, f.sunPath.w, min(L.wet.w * 1.1, 1.0), footprint) * (fade * 1.6);
#endif
	}
#endif
	return w;
}

// Wet albedo: porous surfaces darken (light scatters longer under the water film and is absorbed), standing water dims what
// is under it a little more; snow covers it.
static inline half3 shadeWetAlbedo(half3 albedo, ShadeWet w) {
	half3 a = albedo;
	half om = w.omega * (1.0h - 0.67h * w.vegK * w.veg);
	// (2.0.1 opt) combine wetness and film-darkening pows into a single pow()
	if (om > 0.0h) {
		half ex = 1.0h + 0.65h * om;
		if (w.film > 0.0h && w.dark != 0.0h) ex *= 1.0h + w.dark * om;
		a = pow(max(a, half3(1e-4h)), half3(ex)) * (1.0h - 0.08h * om);
	}
	if (w.film > 0.0h) {
		a *= (1.0h - 0.12h * w.low) * (1.0h - 0.2h * w.puddle);
	} else if (w.puddle > 0.0h) a *= 1.0h - 0.3h * w.puddle;
	if (w.snow > 0.0h) a = mix(a, half3(0.86h, 0.88h, 0.92h) * (1.0h + 0.35h * w.grain), w.snow);
	return a;
}

// Fresnel of a water film (f0 0.02), roughness-aware (Lagarde 2011): rough films don't reach a full mirror at grazing angles.
static inline float shadeWxFresnel(float cosT, float rough) {
	float m = 1.0 - saturate(cosT);
	float m2 = m * m;
	return 0.02 + (max(1.0 - rough, 0.02) - 0.02) * m2 * m2 * m;
}

// GGX specular of the sun or moon (radiance per unit sunColor), Smith-correlated visibility, times n.l.
static inline float shadeWxGgx(float3 n, float3 v, float3 l, float alpha) {
	float3 h = normalize(l - v);
	float nh = saturate(dot(n, h)), nl = saturate(dot(n, l)), nv = max(dot(n, -v), 1e-3);
	float a2 = alpha * alpha;
	float dd = nh * nh * (a2 - 1.0) + 1.0;
	float D = a2 / (3.14159265 * dd * dd);
	float gv = nl * sqrt(nv * nv * (1.0 - a2) + a2), gl = nv * sqrt(nl * nl * (1.0 - a2) + a2);
	return 3.14159265 * D * (0.5 / max(gv + gl, 1e-5)) * nl;
}

// ---- reflections from last frame's image ------------------------------------------------------------------------------------
// The opaque pass has no copy of this frame yet, so puddles reflect LAST frame's finished world (ShadeResources.prevScene:
// the TAA history, pre-exposed with ShadeGpu.exposure.z) and march its depth (prevDepth: the linear view depth TAA keeps for
// the same pixels). The ray (camera-relative, this frame) goes through last frame's unjittered clip space
// (ShadeLook.prevViewProjNoJitter, re-based on this frame's camera); 1/w is affine along the projected segment, so the ray's
// depth at each step is exact. Hits get the base's haze added (prevScene is taken before the final pass adds it). Returns
// (radiance before exposure, weight); weight 0 = no hit (callers keep their sky reflection).
// One chunk (of `chunks` equal parts) of the march: n steps with a nonlinear spacing (dense near the start), the first crossing
// refined by 3 bisection steps and checked for thickness. Returns (uv, fade, 1) or w < 0; hitPoint = the camera-relative hit.
// (M3.3: N = the steps per lane as a template parameter, so SHADE_WX_B_STEPS' shorter march is a second unrolled copy)
template <int N>
static float4 shadeWxHistMarch(float3 p, float3 r, float maxDist, int chunk, int chunks, float jitter, constant ShadeLook &L,
                               texture2d<half> histDepth, thread float3 &hitPoint) {
	float4 c0 = L.prevViewProjNoJitter * float4(p, 1.0);
	float4 dc = L.prevViewProjNoJitter * float4(r, 0.0);
	float len = maxDist;
	if (dc.w < 0.0) len = min(len, (c0.w - 0.2) / -dc.w * 0.9);
	if (len <= 0.2 || c0.w <= 0.1) return float4(0.0, 0.0, 0.0, -1.0);
	float4 c1 = c0 + dc * len;
	float2 s0 = c0.xy / c0.w, s1 = c1.xy / c1.w;
	float iw0 = 1.0 / c0.w, iw1 = 1.0 / c1.w;
	float2 d = s1 - s0;
	float tx = d.x > 1e-6 ? (1.0 - s0.x) / d.x : d.x < -1e-6 ? (-1.0 - s0.x) / d.x : 1e6;
	float ty = d.y > 1e-6 ? (1.0 - s0.y) / d.y : d.y < -1e-6 ? (-1.0 - s0.y) / d.y : 1e6;
	float tEnd = min(1.0, min(tx, ty));
	if (tEnd <= 0.0) return float4(0.0, 0.0, 0.0, -1.0);
	bool screenEnd = tEnd < 1.0;
	const int n = N;
	float inv = 1.0 / float(n * chunks);
	float u0 = max(float(chunk * n) - jitter, 0.0) * inv;
	float tPrev = u0 * (0.3 + 0.7 * u0) * tEnd;
	// (FT2.7, audit idx 75/88, as the water's FT2.6/2.6.1 fix) the first crossing behind real geometry beyond the start point (a
	// trunk, leaves), kept as a fallback (w 11) with the hit's fades: a ray that passed behind them fell back to the bright sky
	float4 back = float4(0.0, 0.0, 0.0, -1.0);
	float3 backPoint = float3(0.0);
	for (int i = 1; i <= n; i++) {
		float u = (float(chunk * n + i) - jitter) * inv;
		float t = u * (0.3 + 0.7 * u) * tEnd;
		float2 s = s0 + d * t;
		float wr = 1.0 / mix(iw0, iw1, t);
		float ws = float(histDepth.sample(shadeWxNearest, s * 0.5 + 0.5, level(0.0)).r);
		if (wr <= ws + 0.05 + 0.004 * ws) {
			tPrev = t;
			continue;
		}
		// behind something: refine between the last step in front and this one
		float lo = tPrev, hi = t, wHi = ws;
		for (int j = 0; j < 3; j++) {
			float m = 0.5 * (lo + hi);
			float2 sm = s0 + d * m;
			float wm = 1.0 / mix(iw0, iw1, m);
			float dm = float(histDepth.sample(shadeWxNearest, sm * 0.5 + 0.5, level(0.0)).r);
			if (wm > dm) { hi = m; wHi = dm; } else lo = m;
		}
		float2 sh = s0 + d * hi;
		float2 uv = sh * 0.5 + 0.5;
		float wh = wHi;
		float wrh = 1.0 / mix(iw0, iw1, hi);
		float wp = 1.0 / mix(iw0, iw1, tPrev);
		float thick = 0.35 + 0.025 * wh + abs(wrh - wp) * 3.0; // (FT2.7: x3 step extents, as the water since FT2.6, Photon MIT)
		if (wh > 30000.0 || wrh - wh > thick) { // passed behind a thin thing, or the sky: keep marching
			if (back.w < 0.0 && wh < 30000.0 && wh > c0.w) {
				float2 eb = smoothstep(0.0, 0.06, min(uv, 1.0 - uv));
				float bf = eb.x * eb.y;
				if (!screenEnd) bf *= 1.0 - smoothstep(0.75, 1.0, hi / tEnd);
				back = float4(uv, bf, 11.0);
				backPoint = p + r * (len * hi * iw1 / mix(iw0, iw1, hi));
			}
			tPrev = t;
			continue;
		}
		float2 edge = smoothstep(0.0, 0.06, min(uv, 1.0 - uv));
		float fade = edge.x * edge.y * (1.0 - smoothstep(0.6, 1.0, (wrh - wh) / thick));
		if (!screenEnd) fade *= 1.0 - smoothstep(0.75, 1.0, hi / tEnd);
		// screen parameter -> ray parameter: lambda = t / w1 / lerp(1 / w0, 1 / w1, t)
		hitPoint = p + r * (len * hi * iw1 / mix(iw0, iw1, hi));
		return float4(uv, fade, 1.0);
	}
	if (back.w > 0.0) hitPoint = backPoint;
	return back;
}

// Quad reductions by xor shuffles (the lanes of one 2x2 pixel quad of one triangle).
static inline float shadeWxQuadMax(float v) { v = max(v, quad_shuffle_xor(v, 1)); return max(v, quad_shuffle_xor(v, 2)); }
static inline float shadeWxQuadMin(float v) { v = min(v, quad_shuffle_xor(v, 1)); return min(v, quad_shuffle_xor(v, 2)); }
static inline float3 shadeWxQuadSum(float3 v) { v += quad_shuffle_xor(v, 1); return v + quad_shuffle_xor(v, 2); }

// Puddle reflection from last frame's image. Per pixel, or (SHADE_PUDDLE_QUAD) the 2x2 quad traces one ray (its mean origin
// and direction), each lane marching a quarter of it: half-resolution reflections for a quarter of the cost (the ripples'
// wobble and TAAU hide the 2x2 blocks). Must be reached in quad-uniform control flow when SHADE_PUDDLE_QUAD is defined.
// Returns (radiance before exposure, weight); weight 0 = no hit (callers keep their sky reflection).
static float4 shadeWxHistSsr(float3 p, float3 r, float2 pixel, float maxDist, float prevExposure, constant ShadeFrame &f, constant ShadeLook &L,
                             texture2d<half> hist, texture2d<half> histDepth, float streak = 0.0) {
	float3 hp = float3(0.0);
#ifdef SHADE_PUDDLE_QUAD
	float3 pq = shadeWxQuadSum(p) * 0.25;
	float3 rq = normalize(shadeWxQuadSum(r));
	uint2 q = uint2(pixel);
	int chunk = int(q.x & 1u) + 2 * int(q.y & 1u);
	float jq = shadeNoise(floor(pixel * 0.5), f.flags2.x);
	// (M3.3 SHADE_WX_B_STEPS: 8 steps, 2 per lane; quad-uniform: a per-frame setting)
	float4 h = SHADE_WX_B_STEPS_ON(f) ? shadeWxHistMarch<2>(pq, rq, maxDist, chunk, 4, jq, L, histDepth, hp)
	                                  : shadeWxHistMarch<SHADE_PUDDLE_N>(pq, rq, maxDist, chunk, 4, jq, L, histDepth, hp);
	// (FT2.7: a fallback behind something, w 11, counts only where no lane of the quad found a real hit)
	float key = h.w > 10.0 ? float(chunk) + 4.0 : h.w > 0.0 ? float(chunk) : 8.0;
	float best = shadeWxQuadMin(key);
	if (best > 7.5) return float4(0.0);
	bool mine = key == best; // exactly one lane holds the nearest hit
	float3 a = shadeWxQuadSum(mine ? float3(h.xyz) : float3(0.0));
	hp = shadeWxQuadSum(mine ? hp : float3(0.0));
	h = float4(a, 1.0);
#else
	float jp = shadeNoise(pixel, f.flags2.x);
	float4 h = SHADE_WX_B_STEPS_ON(f) ? shadeWxHistMarch<8>(p, r, maxDist, 0, 1, jp, L, histDepth, hp)
	                                  : shadeWxHistMarch<SHADE_PUDDLE_N>(p, r, maxDist, 0, 1, jp, L, histDepth, hp);
	if (h.w < 0.0) return float4(0.0);
#endif
	float3 c = float3(hist.sample(shadeWxLinear, h.xy, level(0.0)).rgb) / prevExposure;
	if (streak > 0.0) { // (M3.3 film reflections: streak = uv half-length along the screen's vertical)
		c = c * 0.5 + (float3(hist.sample(shadeWxLinear, h.xy + float2(0.0, streak), level(0.0)).rgb)
			+ float3(hist.sample(shadeWxLinear, h.xy - float2(0.0, streak), level(0.0)).rgb)) * (0.25 / prevExposure);
	}
	// prevScene is taken before the final pass adds the haze: add it for the hit's distance, as the eye sees it on screen
	// (FT2.7, audit idx 33 for puddles: only from the wet surface to the hit; the final pass hazes the surface itself)
	if (shadeFeature(L, SHADE_FEATURE_HAZE) && f.fogColor.a < 0.5) {
#ifdef SHADE_PUDDLE_QUAD
		float3 o = pq;
#else
		float3 o = p;
#endif
		float3 T;
		float3 S = shadeHazeInscatterFrom(hp - o, f.cameraBlock.y + f.cameraFract.y + o.y, f, L, 1.0, T);
		c = c * T + S;
	}
	return float4(c, h.z);
}

// The sky in reflected direction r: the atmosphere LUT, or last frame's rendered sky where r lands on screen and the history
// depth says sky or clouds there (clouds, sun aureole, stars, rain over the sky).
static float3 shadeWxSkyRefl(float3 r, float prevExposure, bool histOk, constant ShadeFrame &f, constant ShadeLook &L, texture2d<half> lut, sampler lutS,
                             texture2d<half> hist, texture2d<half> histDepth) {
	float3 sky = shadeSkyLookup(float3(r.x, max(r.y, 0.0), r.z), lut, lutS, f);
	if (histOk) {
		float4 c = L.prevViewProjNoJitter * float4(r, 0.0);
		if (c.w > 1e-4) {
			float2 uv = c.xy / c.w * 0.5 + 0.5;
			float2 edge = saturate(min(uv, 1.0 - uv) * 12.0);
			float wgt = edge.x * edge.y;
			if (wgt > 0.0 && float(histDepth.sample(shadeWxNearest, uv, level(0.0)).r) > 1000.0) {
				sky = mix(sky, float3(hist.sample(shadeWxLinear, uv, level(0.0)).rgb) / prevExposure, wgt);
			}
		}
	}
	return sky;
}

// ---- shading the wet layer ------------------------------------------------------------------------------------------------
struct ShadeWetLight {
	float3 p;          // camera-relative position
	half3 n;           // snapped face normal (toward the camera)
	half sky;          // sky light 0..1
	half shadow;       // sun/moon visibility
	float2 pixel;      // fragment position
	float prevExposure;// ShadeGpu.exposure.z when prevScene is valid, else 0
	bool histOk;       // prevDepth matches prevScene (ShadeLook.ssr.y)
};

// The water film's specular on top of the diffuse radiance: sky (or SSR on puddles) reflection and the sun's highlight, with
// the diffuse part dimmed by what the film reflects. Radiance before exposure.
static float3 shadeWetShade(float3 radiance, half3 albedo, ShadeWet w, ShadeWetLight in, constant ShadeFrame &f, constant ShadeLook &L, texture2d<half> lut,
                            sampler lutS, texture2d<half> hist, texture2d<half> histDepth) {
	half wet = max(w.omega, w.puddle);
#if defined(SHADE_PUDDLE_SSR) && defined(SHADE_PUDDLE_QUAD)
	// the quad-shared march needs all four lanes: only a quad without any puddle may leave early
	bool quadPuddle = L.wet.y > 0.001 && shadeWxQuadMax(float(w.puddle)) > 0.02;
	// (M3.3 wet ground) film reflections share the march: a quad with a soaked up-facing film stays as well (per frame first)
	bool quadFilm = SHADE_WET_ALL_ON(L) && L.water.w > 0.0 && shadeWxQuadMax(in.n.y > 0.5h ? float(w.film * w.omega) : 0.0) > 0.3;
	if (wet <= 0.004h && !quadPuddle && !quadFilm) return radiance;
#else
	if (wet <= 0.004h) return radiance;
#endif
	float3 pe = in.p - shadeEye(f.invViewProj); // from the eye: view bobbing moves it (shade_common.metal)
	float dist = length(pe);
	float3 v = pe / max(dist, 1e-4);
	float3 nf = float3(in.n);
	float3 n = nf;
	float P = float(w.puddle);
	if (P > 0.0) n = normalize(float3(-w.slope.x * P, 1.0, -w.slope.y * P));
	// roughness: damp ground 0.8, soaked 0.38, standing water 0.03 (the ripples add their own detail); vegetation (grass tops,
	// leaves: green albedo) holds less of a film than stone, wood or paths
	float veg = saturate((float(albedo.g) - max(float(albedo.r), float(albedo.b))) * 8.0);
	float rough = mix(min(mix(0.8, 0.38, float(w.omega)) + 0.25 * veg, 0.95), 0.03, P);
	bool walls = shadeWxWalls(f);
	if (walls && nf.y < 0.5) rough = max(rough, 0.75); // (2026-10-12) walls and undersides: a damp, rough surface
	// (M3.3 wet ground) solid ground soaks into a smooth film (ShadeLook.water.y: ~0.2 on stone, paths, wood, sand; vegetation
	// + water.z, so grass tops are glossy but rougher), smoother in the field's hollows and toward standing water over the rim
	// (low), then the puddle's 0.03; the film covers the ground (k) as it soaks
	// Grass tops are not a flat sheet of water: blades stand out of it, so vegetation keeps a share of the film (waterAbs.y)
	// and a rougher one; by hue (green over red and blue, relative to green), so the darkened wet albedo still counts
	float film = 0.0;
	if (w.film > 0.0h) {
		float vegR = float(w.veg);
		float soak = saturate(float(w.omega) * 1.15);
		float tx = float(w.tex) * (1.0 - float(w.low)); // (texel relief: raised texels rougher and partly dry, crevices smoother)
		float rS = clamp(L.water.y + L.water.z * vegR - 0.25 * float(w.var) + 0.18 * tx, 0.06, 0.6);
		float low2 = float(w.low) * float(w.low); // (the rim turns into standing water only close to the puddle's edge)
		rough = mix(mix(mix(0.8, rS, soak), 0.06, low2), 0.03, P);
		film = max(soak * mix(1.0, L.waterAbs.y, vegR) * (1.0 - 0.35 * saturate(tx)), low2);
	}
	float cosV = max(dot(-v, n), 0.02);
	float F = shadeWxFresnel(cosV, rough);
	float3 r = reflect(v, n);
	if (dot(r, nf) < 0.02) r = normalize(r + nf * (0.02 - dot(r, nf))); // ripples must not send the mirror ray into the ground
	float open = float(shadeSkyCurve(in.sky));
	// rough films see a blurred sky: toward the sky's mean light (ambientSky ~ irradiance / pi); the roughest (soaked grass,
	// damp ground: rough >= 0.625) see only that, so the sky lookups are skipped there
	float blur = saturate(rough * 1.6);
	// (SHADE_DEV_WX_FILM_SKY: in heavy rain the overcast sky is about uniform, so films off the puddles see its mean light)
	// (fades in over rain 0.6-0.8, so the switch doesn't pop; per frame, so the skip above 0.8 is uniform)
	if (P <= 0.0 && SHADE_WX_BUDGET(f, SHADE_DEV_WX_FILM_SKY)) blur = max(blur, smoothstep(0.6, 0.8, L.wet.w));
	// (FT2.8, audit idx 92) the sky reflection after the march, and only where the march's hit doesn't cover it all (wHit < 1):
	// the same result, no LUT / history taps under a fully reflected scene
	float3 hitC = float3(0.0);
	float wHit = 0.0;
#ifdef SHADE_PUDDLE_SSR
	// The march only where the mirror shows: the film reflects F (2 % looking straight down, ~10 % at 65 degrees from the
	// normal, all of it at grazing angles), so where F * P < 0.035 the sky reflection alone is within a few percent of what
	// the march would add, and the march is skipped (most of the puddle pixels near the feet); a soft ramp up to 0.07.
	// (SHADE_DEV_WX_SSR_GATE2: from F * P 0.05, ramp to 0.09: puddles within ~4.5 blocks of the feet reflect 2-5 % and keep
	// the sky reflection alone; the grazing views where the mirror shows are marched as before)
	float2 gate = SHADE_WX_BUDGET(f, SHADE_DEV_WX_SSR_GATE2) ? float2(0.05, 0.09) : float2(0.035, 0.07);
	// (M3.3 SHADE_WX_B_GATE: from F * P 0.06, ramp to 0.10: puddles within ~3 blocks of the feet lose a ~5 % reflection)
	if (SHADE_WX_B_GATE_ON(f)) gate = float2(0.06, 0.10);
	float ssrW = shadeDev(f, SHADE_DEV_WX_NO_SSR_GATE) ? (P > 0.02 ? 1.0 : 0.0) : smoothstep(gate.x, gate.y, F * P);
	// (M3.3 wet ground) film reflections on up-facing soaked ground, only where the sheen shows them: F x k x gloss from
	// ShadeLook.water.w (ramp to 1.8x), gloss fading them out on rough films (0.2: 0.88, grass ~0.3: 0.5, >= 0.42: none)
	float filmW = 0.0;
	if (film > 0.0 && L.water.w > 0.0 && nf.y > 0.5) filmW = smoothstep(L.water.w, L.water.w * 1.8, F * film * saturate((0.42 - rough) * 4.0)) * (1.0 - P);
	ssrW = max(ssrW, filmW);
#ifdef SHADE_PUDDLE_QUAD
	// quadPuddle first: lanes of a quad without puddles may have returned above, and shuffles must not read them
	if ((quadPuddle || quadFilm) && shadeWxQuadMax(ssrW) > 0.0 && in.histOk && in.prevExposure > 0.0 && !shadeDev(f, SHADE_DEV_WX_NO_SSR)) { // quad-uniform (quadPuddle, histOk, prevExposure, dev: per frame)
#else
	if (ssrW > 0.0 && in.histOk && in.prevExposure > 0.0 && !shadeDev(f, SHADE_DEV_WX_NO_SSR)) {
#endif
		// (M3.3: a film's rougher reflection is smeared along the screen's vertical, the plane of incidence of a floor)
		float streak = filmW > 0.0 ? 0.014 * saturate(rough * 3.3) * (1.0 - P) : 0.0;
		float4 hit = shadeWxHistSsr(in.p, r, in.pixel, SHADE_PUDDLE_DIST, in.prevExposure, f, L, hist, histDepth, streak);
		hitC = hit.rgb;
		wHit = hit.w * ssrW;
	}
#endif
	float3 refl = float3(0.0);
	if (wHit < 1.0) {
		refl = blur < 1.0 ? shadeWxSkyRefl(r, in.prevExposure, in.histOk && P > 0.0, f, L, lut, lutS, hist, histDepth) : float3(0.0);
		refl = mix(refl, float3(f.ambientSky.rgb) * 1.1, blur) * open;
		// (2026-10-12, shadeWxWalls) a mirror ray below the horizon sees the ground (a pit's floor, the far wall, the slope below
		// a terrace), not the sky: shadeWxSkyRefl clamps it to the horizon, the brightest part of an overcast sky, which lit wet
		// walls seen from above whitish. Toward the ground's bounced light instead, over +-0.15 around the horizon
		if (walls) refl = mix(float3(f.ambientGround.rgb) * open, refl, smoothstep(-0.15, 0.15, r.y));
	}
	refl = mix(refl, hitC, wHit);
	if (wet <= 0.004h) return radiance;
	// the sun's (or moon's) highlight: a mirror-sharp glint on puddles, a broad sheen on wet ground
	float a = max(rough * rough, 0.0025);
	float3 sun = float3(0.0);
	// (SHADE_DEV_WX_SUN_GATE: in heavy rain the sun is behind the clouds, the highlight fades out over rain 0.5-0.8 and is not
	// computed above it; per frame, so the branch is uniform)
	float sunW = SHADE_WX_BUDGET(f, SHADE_DEV_WX_SUN_GATE) ? 1.0 - smoothstep(0.5, 0.8, L.wet.w) : 1.0;
	if (sunW > 0.0) sun = float3(f.sunColor.rgb) * (min(shadeWxGgx(n, v, f.lightDirWorld.xyz, a), 60.0) * float(in.shadow)
		* float(smoothstep(0.3h, 0.8h, in.sky)) * sunW);
	float k = mix(w.film > 0.0h ? film : float(w.omega) * 0.65 * (1.0 - 0.5 * veg), 1.0, P); // (M3.3: the film's k)
	return radiance * (1.0 - F * k) + (refl * F + sun * F) * k;
}

// ---- lightning ------------------------------------------------------------------------------------------------------------
// A flash lights everything under open sky from the bolt's direction (no shadows: it's brief and the clouds spread it).
static inline float3 shadeWxFlash(half3 albedo, half3 n, half sky, constant ShadeLook &L) {
	if (L.flash.w <= 0.0) return float3(0.0);
	float ndl = saturate(dot(float3(n), L.flash.xyz)) * 0.65 + 0.35;
	half g = shadeSkyCurve(sky);
	return float3(albedo) * float3(0.78, 0.86, 1.0) * (L.flash.w * ndl * float(g * g));
}

// ---- coloured shadows (E08) --------------------------------------------------------------------------------------------------
// The light that reached p through stained glass, ice or water: the near cascade's tint map (ShadowPass, the translucent
// casters' transmittance with the light depth of the one nearest the light in alpha). Only below a caster: the receiver must
// be farther from the light than it by a quarter block (and the map fades out with the near cascade's edge). 1 = untinted.
// L.tintRect: the casters' rectangle in the same light clip space (ShadowPass): receivers outside it skip the sample.
static half3 shadeShadowTint(float3 p, half3 n, constant ShadeFrame &f, constant ShadeLook &L, texture2d<half> tint) {
	// (SHADE_DEV_WX_RAIN_TINT: in heavy rain the sun behind the clouds gives a third of its light or less: the tint fades out
	// over rain 0.5-0.8 and is not looked up above it; per frame, so the branch is uniform)
	float rw = SHADE_WX_BUDGET(f, SHADE_DEV_WX_RAIN_TINT) ? 1.0 - smoothstep(0.5, 0.8, L.wet.w) : 1.0;
	if (rw <= 0.0) return half3(1.0h);
	float4 c = f.shadowViewProj[0] * float4(p + float3(n) * (0.75 * f.cascadeSplits.z), 1.0);
	if (any(c.xy < L.tintRect.xy) || any(c.xy > L.tintRect.zw)) return half3(1.0h);
	float m = max(abs(c.x), abs(c.y));
	if (m >= 1.0 || c.z <= 0.0 || c.z >= 1.0) return half3(1.0h);
	// M3.3 (ssr.w = 2, mcopt.shade.tintSub): the tint pass drew only the casters' rectangle, its top-left corner at texel (0, 0)
	// and at the near cascade's texel size (ShadowPass.tintSubMatrix); 1 = M3.2: the map spans the whole near cascade
	float2 tuv = L.ssr.w > 1.5 ? float2(0.5 * (c.x - L.tintRect.x), 0.5 * (L.tintRect.w - c.y)) : shadeShadowUV(c.xyz);
	half4 t = tint.sample(shadeWxLinear, tuv, level(0.0));
	float zBlocks = 1.0 / max(length(float3(f.shadowViewProj[0][0][2], f.shadowViewProj[0][1][2], f.shadowViewProj[0][2][2])), 1e-6);
	float gate = saturate(((float(t.a) - c.z) * zBlocks - 0.25) * 4.0) * (1.0 - smoothstep(0.85, 1.0, m));
	// coloured light keeps part of its brightness (a red pane lights the floor red, not dark brown): luminance pulled halfway
	// back toward white light, at most x2.2 per channel
	half3 T = t.rgb * min(rsqrt(max(dot(t.rgb, half3(0.2126h, 0.7152h, 0.0722h)), 0.05h)), 2.2h);
	return mix(half3(1.0h), T, half(gate * rw));
}

// The direct light's share of shadeLit2 that the tint changes (the same sun term: wrap, gate, shadow), times (tint - 1):
// added to shadeLit2's result, it turns the light that came through glass into the glass's colour.
static inline float3 shadeShadowTintDelta(half3 albedo, half3 n, half sky, half shadow, half3 tint, bool thin, bool foliage, constant ShadeFrame &f) {
	if (all(tint == half3(1.0h))) return float3(0.0); // outside the casters' rectangle or above them
	half nl = half(dot(float3(n), f.lightDirWorld.xyz));
	half ndl = thin ? half(0.3) + half(0.5) * abs(nl)
		: foliage ? half(0.25) + half(0.75) * saturate(nl) + half(0.5) * saturate(-nl)
		: (nl > half(0.0) ? (nl + half(0.08)) / half(1.08) : half(0.0));
	half gate = smoothstep(half(0.3), half(0.8), sky);
	if (SHADE_CAMERA_UNDERWATER(f)) gate *= 0.5h;
	return float3(albedo * half3(f.sunColor.rgb) * (ndl * shadow * gate) * (tint - 1.0h));
}

#endif
