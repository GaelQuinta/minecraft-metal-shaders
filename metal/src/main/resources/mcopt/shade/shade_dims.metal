// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// M3 sky, dimensions and camera media (bible E04 aurora, E24 Nether, E25 End, E26 media), loaded after shade_m2.metal in
// ShadeMsl.prelude(). Everything here is original. CPU side: mcopt.metal.shade.dims.ShadeDims.
//
// DATA. Outside the overworld (sunPath.z bit SHADE_FLAG_DIMS_LIT set) ShadeFrame carries the dimension instead of the sun:
//   sunColor / lightDirWorld   Nether: 0 / up; End: the violet key light ("a dead star", fixed direction, casts shadows)
//   ambientSky/Ground/Toward/Away   the dimension ambient (Nether: biome palette over a warm neutral; End: violet)
//   horizon[i] (M1's deprecated horizon table, unused there) = the palette, pre-exposure radiance:
//     SHADE_DP_FOG 0  fog in-scatter (both)          SHADE_DP_LAVA 1  lava up-light at the lava sea (Nether)
//     SHADE_DP_ACCENT 2 Nether biome accent | End sky zenith   3 End sky horizon   4 End beams   5 End filaments
//     6, 7 End nebula hues
// ShadeLook: dimTint = (fog extinction 1/block, lava sea y, border fog radius in blocks (0 off), w: kind + 4 x the M3.3 bits;
// kind (shadeDimKind) 1 Nether / 2 End / 3 End without a sky pass: vanilla skips the sky during the dragon fight, the final
// pass paints shadeEndSky on empty pixels; 0 in the overworld; bits SHADE_DIMS_* (shadeDimsBit), live per frame);
// flash = (End flash direction, intensity), written only while the dims are lit (in the overworld the field is the weather
// module's lightning); night.z = aurora strength 0..1.
// NOISE. ShadeResources.milkyWay's alpha holds a tileable fbm (baked with the Milky Way, shade_post.metal): shadeDimsNoise.
#ifndef MCOPT_SHADE_DIMS
#define MCOPT_SHADE_DIMS

#define SHADE_FLAG_DIMS_LIT (1 << 23)     // sunPath.z bit: Nether/End terrain is lit per pixel (mcopt.shade.dims); state flags count
                                          // down from 1 << 23, mcopt.shade.dev toggles up from 1 (weather: 1024-65536)
#define SHADE_FEATURE_DIMS (1 << 20)      // ShadeLook.tier.y: the Nether/End looks
#define SHADE_FEATURE_MEDIA (1 << 21)     // camera inside lava / powder snow
#define SHADE_FEATURE_SHIMMER (1 << 22)   // heat shimmer over distant Nether terrain
#define SHADE_DP_FOG 0
#define SHADE_DP_LAVA 1
#define SHADE_DP_ACCENT 2

static inline bool shadeDimsLit(constant ShadeFrame &f) { return f.flags.x != SHADE_DIM_OVERWORLD && (int(f.sunPath.z) & SHADE_FLAG_DIMS_LIT) != 0; }
// M3.3: ShadeLook.dimTint.w = kind + 4 x bits (an exact small float)
#define SHADE_DIMS_MOTES 1        // Nether: dark suspended particles lifted to a luminance floor (mcopt.shade.dims.motes)
#define SHADE_DIMS_AURORA_TEX 2   // overworld: the sky pass samples the reduced-resolution aurora (ShadeResources.aurora; mcopt.shade.aurora.half)
#define SHADE_DIMS_DH_SKY 4       // End + Distant Horizons: the final pass paints the End sky where the clear colour still shows (mcopt.shade.dhClear)
static inline int shadeDimKind(constant ShadeLook &L) { return int(L.dimTint.w) & 3; }
static inline bool shadeDimsBit(constant ShadeLook &L, int b) { return ((int(L.dimTint.w) >> 2) & b) != 0; }

// M3.3: vanilla's suspended Nether motes are near black (warped spores 0.1 / 0.1 / 0.3, ash 0..0.5 grey): made for its
// near-black fog, they read as dark specks in our lit haze. Their albedo's luminance is lifted to a floor, the hue kept
// (warped spores read blue, as the wiki describes them; ash grey); brighter particles are untouched.
static inline half3 shadeDimsMote(half3 a) {
	half l = dot(a, half3(0.2126h, 0.7152h, 0.0722h));
	const half lift = 0.16h;
	if (l >= lift) return a;
	half3 hue = a * (lift / max(l, 0.002h));
	hue = hue / max(1.0h, max(hue.x, max(hue.y, hue.z)));          // a saturated hue may not exceed 1
	return mix(half3(lift), hue, saturate(l * 80.0h));              // no hue in a black: grey
}

// ---- tileable noise ---------------------------------------------------------------------------------------------------------
// Value noise on a lattice wrapped every `period` cells (so the bake tiles), in cell units.
static inline float shadeDimsPeriodicValue(float2 p, int2 period, uint salt) {
	float2 i = floor(p), fr = p - i;
	float2 u = fr * fr * (3.0 - 2.0 * fr);
	int2 c = int2(i);
	int2 c0 = ((c % period) + period) % period, c1 = (((c + 1) % period) + period) % period;
	float a = shadeHash01(shadeHash3(int3(c0.x, c0.y, 0), salt)), b = shadeHash01(shadeHash3(int3(c1.x, c0.y, 0), salt));
	float cc = shadeHash01(shadeHash3(int3(c0.x, c1.y, 0), salt)), d = shadeHash01(shadeHash3(int3(c1.x, c1.y, 0), salt));
	return mix(mix(a, b, u.x), mix(cc, d, u.x), u.y);
}

// The baked noise: 5 octaves over uv in [0, 1)^2, base lattice 16 x 8 cells (square cells on the 1024 x 512 texture).
static inline float shadeDimsBakeNoise(float2 uv) {
	float s = 0.0, a = 0.5, n = 0.0;
	int2 period = int2(16, 8);
	for (int o = 0; o < 5; o++) {
		s += a * shadeDimsPeriodicValue(uv * float2(period), period, 0x2c1b3c6du + uint(o) * 977u);
		n += a;
		a *= 0.5;
		period *= 2;
	}
	return saturate((s / n - 0.5) * 1.9 + 0.5);
}

// The baked noise at p, in units of its base cell (1 = 1/16 of the texture's width). Tiles every 16 x 8 units.
static inline float shadeDimsNoise(texture2d<half> mw, float2 p) {
	constexpr sampler rep(filter::linear, address::repeat);
	return float(mw.sample(rep, p * float2(1.0 / 16.0, 1.0 / 8.0), level(0.0)).a);
}

// ---- lighting in the Nether and the End (E24, E25) ---------------------------------------------------------------------------
// shadeLit2 with no sky light and no sun gives the block light, the cave floor (and anything later modules add there);
// shadeLitDimsExtra is what the dimension adds on top: its ambient (up / down / sides), the Nether's lava up-light (warm
// light from below, strongest near the lava sea, a slow flicker), the End's key light (shadowed) and its flash.
// p: camera-relative position. The terrain shader calls shadeLit2 once for every dimension (sky light and shadow 0 here)
// and adds this term, so shadeLit2 is inlined once (code size / registers of the overworld path unchanged).
static float3 shadeLitDimsExtra(half3 albedo, half3 n, half shadow, bool thin, bool foliage, float3 p, constant ShadeFrame &f,
                                constant ShadeLook &L) {
	float3 nn = float3(n);
	float3 side = 0.5 * (f.ambientToward.rgb + f.ambientAway.rgb);
	float3 light = nn.y >= 0.0 ? mix(side, f.ambientSky.rgb, nn.y) : mix(side, f.ambientGround.rgb, -nn.y);
	if (foliage || thin) light *= 1.15;
	float yAbs = f.cameraBlock.y + f.cameraFract.y + p.y;
	if (shadeDimKind(L) == 1) {
		// Nether: lava below lights ceilings and undersides
		float up = thin ? 0.5 : saturate(0.55 - 0.45 * nn.y);
		float h = exp(-max(yAbs - L.dimTint.y, 0.0) / 30.0);
		float t = f.time.y;
		float flick = 0.88 + 0.12 * sin(t * 1.3 + (f.cameraBlock.x + p.x) * 0.07) * sin(t * 0.7 + (f.cameraBlock.z + p.z) * 0.05);
		light += f.horizon[SHADE_DP_LAVA].rgb * (up * h * flick);
	} else {
		float3 Ld = f.lightDirWorld.xyz;
		float nl = dot(nn, Ld);
		float ndl = thin ? 0.3 + 0.5 * abs(nl) : foliage ? 0.25 + 0.75 * saturate(nl) + 0.5 * saturate(-nl) : (nl > 0.0 ? (nl + 0.08) / 1.08 : 0.0);
		light += f.sunColor.rgb * (ndl * float(shadow));
		if (L.flash.w > 0.0) light += float3(0.55, 0.75, 1.0) * (L.flash.w * 1.4 * saturate(dot(nn, L.flash.xyz) * 0.6 + 0.4));
	}
	float face = 1.0 - 0.06 * abs(nn.x) * (1.0 - abs(nn.y));
	return float3(albedo) * light * face;
}

// The whole Nether/End lighting of a surface (for callers that don't share a shadeLit2 call with the overworld path).
static float3 shadeLitDims(half3 albedo, half3 n, half block, half shadow, bool thin, bool foliage, float3 p, constant ShadeFrame &f,
                           constant ShadeLook &L) {
	return shadeLit2(albedo, n, half(0.0), block, half(0.0), thin, foliage, f, L) + shadeLitDimsExtra(albedo, n, shadow, thin, foliage, p, f, L);
}

// Stars for the End (no atmosphere: no twinkle, no extinction): the overworld's cube-map cells (shadeStars), but only the
// cell the direction falls in (stars sit 0.2-0.8 into their cell and are small: sigma <= 0.8 cell), and the colour from a
// three-way mix instead of Planck's law. A quarter of shadeStars' cost.
static float3 shadeEndStars(float3 s, float sigmaCells) {
	float3 a = abs(s);
	float2 uv; uint face;
	if (a.x >= a.y && a.x >= a.z) { uv = s.yz / a.x; face = s.x > 0.0 ? 0u : 1u; }
	else if (a.y >= a.z) { uv = s.xz / a.y; face = s.y > 0.0 ? 2u : 3u; }
	else { uv = s.xy / a.z; face = s.z > 0.0 ? 4u : 5u; }
	float2 cell = (uv * 0.5 + 0.5) * 420.0;
	int2 c = int2(floor(cell));
	uint h = shadeHash3(int3(c, int(face)), 0x3c6ef372u);
	if (shadeHash01(h) > 0.09) return float3(0.0);
	float2 pos = float2(c) + 0.2 + 0.6 * float2(shadeHash01(h ^ 0x68e31da4u), shadeHash01(h ^ 0xb5297a4du));
	float2 dd = cell - pos;
	float flux = exp2(-1.328771 * (-1.0 + 7.5 * pow(shadeHash01(h ^ 0x1b56c4e9u), 0.45)));
	float pick = shadeHash01(h ^ 0x7f4a7c15u);
	float3 col = pick < 0.5 ? mix(float3(1.25, 0.95, 0.75), float3(1.0), pick * 2.0) : mix(float3(1.0), float3(0.75, 0.85, 1.3), pick * 2.0 - 1.0);
	return col * (flux * exp(-0.5 * dot(dd, dd) / (sigmaCells * sigmaCells)));
}

// ---- the End sky (E25) ---------------------------------------------------------------------------------------------------------
// Deep indigo gradient, a slowly turning nebula (two hues, domain-warped noise in an equirectangular map: the longitude
// multipliers are whole numbers so it wraps), sharp stars, and luminous curtains ("beams") rising from the void around the
// island, brightening with the End flash. Pre-exposure radiance.
static float3 shadeEndSky(float3 dir, constant ShadeFrame &f, constant ShadeLook &L, texture2d<half> mw, float pixelAngle) {
	float y = clamp(dir.y, -1.0, 1.0);
	float e = asin(y);
	float3 sky = mix(f.horizon[2].rgb, f.horizon[3].rgb, pow(saturate(1.0 - abs(y)), 3.0));
	sky *= y < 0.0 ? mix(1.0, 0.3, saturate(-y * 1.6)) : 1.0; // the void below is darker
	float t = L.clock2.x; // the sky's slow real-time clock (smooth; FT2.8: no jump at the water clock's 4096-s wrap)
	float lon = atan2(dir.z, dir.x) * 0.15915494 + 0.5; // 0..1
	float lat = e * 0.31830989 + 0.5;
	float2 q = float2(lon + t * 0.0004, lat);
	float w = shadeDimsNoise(mw, q * float2(32.0, 16.0) + float2(3.1, 0.7));
	float nb = shadeDimsNoise(mw, q * float2(16.0, 12.0) + float2(w * 1.6, w * 0.9));
	float band = exp(-abs(e - 0.35) / 0.55);
	float neb = smoothstep(0.72, 1.0, nb * 0.75 + w * 0.4) * band;
	// below the horizon the nebula and the stars fade out (a hint in the void, not clouds under the island; 15 % at 25
	// degrees down): the beams rise from there
	float below = mix(1.0, 0.15, smoothstep(0.0, 0.45, -e));
	sky += mix(f.horizon[6].rgb, f.horizon[7].rgb, smoothstep(0.3, 0.75, w)) * (neb * 0.55 * below);
	// stars (the overworld's field, brighter and denser looking: no atmosphere)
	float sigma = clamp(0.7 * pixelAngle / (1.5707963 / 420.0), 0.25, 0.8);
	sky += shadeEndStars(dir, sigma) * (0.8 * (1.0 - 0.6 * neb) * below);
	// beams: ridged noise around the horizon, rising from below it
	float flash = L.flash.w;
	float az = lon;
	// (FT2.8, audit idx 93: only where they can show, -0.3 < e < 0.25; the rise below is 0 elsewhere: the same sky)
	if (e > -0.3 && e < 0.25) {
	float r1 = shadeDimsNoise(mw, float2(az * 64.0, t * 0.02));
	float r2 = shadeDimsNoise(mw, float2(az * 160.0, t * 0.035 + 3.0));
	// sparse: groups of beams where a slow azimuth noise is high (not a wall of stripes all around), low over the horizon
	float groups = smoothstep(0.5, 0.75, shadeDimsNoise(mw, float2(az * 12.0, t * 0.006 + 7.0)));
	float beam = pow(saturate(1.0 - abs(2.0 * r1 - 1.0)), 12.0) * groups;
	float fil = pow(saturate(1.0 - abs(2.0 * r2 - 1.0)), 24.0) * groups;
	float rise = smoothstep(-0.3, -0.04, e) * exp(-max(e + 0.04, 0.0) / (0.05 + 0.07 * r1)) * (1.0 - smoothstep(0.04, 0.25, e));
	float calm = 1.0 + 1.5 * flash;
	sky += (f.horizon[4].rgb * beam * 0.3 + f.horizon[5].rgb * fil * 0.2) * (rise * calm);
	}
	if (flash > 0.0) {
		float c = saturate(dot(dir, L.flash.xyz));
		sky += float3(0.55, 0.7, 1.0) * (flash * (pow(c, 96.0) * 14.0 + pow(c, 6.0) * 0.5)) * length(f.horizon[4].rgb);
	}
	return sky;
}

// ---- aurora (E04) -----------------------------------------------------------------------------------------------------------
// Curtains in a thin shell high above (a flat "virtual" layer: no terrain occlusion beyond the sky test): the ray crosses the
// shell in N steps (blue-noise dithered); at each the curtain field is a domain-warped noise whose 0.5 contour is the
// curtain line, streaked by noise that depends only on the horizontal position (vertical rays), coloured by height in the
// shell (violet lower fringe, green body, crimson top). Pure emission. Pre-exposure radiance x ShadeLook.night.z.
// Colour x envelope of the 6 shell layers (violet lower fringe, green body peaking at 22 percent, crimson top), precomputed
// from g = exp(-(h - 0.22)^2 / 0.04), v = exp(-h^2 / 0.006), r = smoothstep(0.45, 0.95, h) / 2 at h = (i + 0.5) / 6.
constant float3 SHADE_AURORA_LAYERS[6] = {
	float3(0.2310, 0.7023, 0.5336),
	float3(0.1956, 0.9778, 0.4400),
	float3(0.0760, 0.3802, 0.1711),
	float3(0.0938, 0.0554, 0.0467),
	float3(0.2093, 0.0466, 0.0735),
	float3(0.1119, 0.0246, 0.0392)};

// M3.2's aurora: evaluated per pixel in the sky pass (mcopt.shade.aurora.half=false; qfw 0: unchanged), or by the M3.3
// reduced-resolution pass (aurora.metal, ShadeAurora) for the texel's direction.
// qfw (2.0.1 fix): the reduced pass's texel footprint in the shell's plane, max |d(dir.xz / dy)| per texel (aurora.metal,
// fwidth before any branch); 0 = per-pixel path. One texel there spans 3-4 output pixels and is bilinearly stretched, so the
// per-frame dither and anything finer than a texel can't be integrated by TAA: near the horizon (footprint ~ 1 / dy^2) the
// curtain contour and the vertical rays aliased into vertical streaks and a crawling moire. With qfw > 0: a fixed mid-layer
// offset, the curtain line widened by the noise change across the texel and across a layer step (mean-preserving: the
// peak drops as the line widens, so a sub-texel line becomes a soft band of the same average glow), and the rays' contrast
// faded one octave of the baked fbm per doubling of the footprint past its finest cell.
static float3 shadeAurora(float3 dir, constant ShadeFrame &f, constant ShadeLook &L, texture2d<half> mw, float2 pixel, float qfw = 0.0) {
	float s = L.night.z;
	if (s <= 0.002 || dir.y < 0.02) return float3(0.0);
	// 6 layers through the shell, the sample height dithered per pixel and frame (TAA integrates it)
	const float h0 = 1.0, h1 = 1.9;
	float dy = max(dir.y, 0.05);
	float k0 = h0 / dy * 0.55, k1 = h1 / dy * 0.55;
	float t = L.clock2.x; // (FT2.8, audit idx 78) the sky's slow clock: the curtains no longer reshuffle every 68 min
	bool reduced = qfw > 0.0;
	float jitter = reduced ? 0.5 : shadeNoise(pixel, f.flags2.x);
	float2 drift = float2(t * 0.0021, t * 0.0009);
	// the domain warp and the vertical rays vary slowly through the shell: once per pixel, at its middle
	float2 mid = dir.xz * (0.5 * (k0 + k1)) + drift;
	float warp = shadeDimsNoise(mw, mid * 0.6 + float2(t * 0.0031, 0.0)) * 0.9;
	float2 step = dir.xz * ((k1 - k0) * 0.9 / 6.0);
	float2 p = dir.xz * (k0 * 0.9) + drift * 0.9 + warp + step * jitter;
	// line sharpness and peak: 548.224 = 1 / (2 ln2 sigma^2), sigma 0.0363 in noise value. Reduced pass: sigma'^2 = sigma^2 +
	// (spread of the noise value over the texel and over one layer step)^2 / 8, the baked fbm's gradient taken as ~1 per unit
	// (5 value-noise octaves, contrast 1.9); the peak x sigma / sigma' keeps the line's integral
	half kLine = 548.224h, peak = 1.0h;
	if (reduced) {
		const float sigma2 = 1.0 / (2.0 * 0.693147 * 548.224);
		float spread = qfw * 0.55 * 0.9 * (0.5 * (h0 + h1)) + length(step);
		float r = sigma2 / (sigma2 + spread * spread * 0.125);
		kLine = half(548.224 * r);
		peak = half(sqrt(r));
	}
	half3 sum = half3(0.0h);
	for (int i = 0; i < 6; i++) {
		half c = half(shadeDimsNoise(mw, p) - 0.5);
		sum += half3(SHADE_AURORA_LAYERS[i]) * exp2(-c * c * kLine);
		p += step;
	}
	sum *= peak;
	// (2.0.1 opt) skip vertical-ray noise fetch on dark sky pixels between curtains (~70% of sky)
	if (max(sum.x, max(sum.y, sum.z)) <= 1e-4h) return float3(0.0);
	float rn = shadeDimsNoise(mw, mid * 9.0 + float2(0.0, t * 0.012));
	if (reduced) {
		// footprint of mid * 9 in baked-noise texels (64 per unit; the finest octave's cell is 4): full contrast up to 2,
		// none at 64 (the coarsest cell), toward the fbm's mean 0.5
		float texels = qfw * 0.55 * (0.5 * (h0 + h1)) * 9.0 * 64.0;
		rn = mix(0.5, rn, saturate(1.0 - log2(max(texels * 0.5, 1.0)) * 0.2));
	}
	float rays = 0.35 + 0.65 * rn;
	float horizon = smoothstep(0.02, 0.18, dir.y);
	return float3(sum) * (rays * s * horizon * 0.12);
}

// M3.3 (mcopt.shade.aurora.half, default true; ShadeLook bit SHADE_DIMS_AURORA_TEX, set only in frames whose aurora pass
// ran): the sky pass, a full-screen triangle that every pixel pays before the terrain covers most of it, takes the aurora
// from ShadeResources.aurora (aurora.metal: shadeAurora at a fraction of the output resolution, this frame's jittered view)
// with one bilinear tap at the pixel's screen position, instead of evaluating it per pixel. pixel: the render-target pixel.
static inline float3 shadeAuroraTex(float3 dir, constant ShadeFrame &f, constant ShadeResources &sr, float2 pixel) {
	if (dir.y < 0.02) return float3(0.0);
	constexpr sampler auroraClamp(filter::linear, address::clamp_to_edge);
	return float3(sr.aurora.sample(auroraClamp, pixel * f.screen.zw, level(0.0)).rgb);
}

// ---- fog in the Nether and the End (final pass, from depth) ----------------------------------------------------------------
// Nether: a layered haze, denser toward the lava sea and broken up by drifting noise, glowing warm low down; distance
// dissolves into coloured smoke (bible E24). End: a thin violet haze that meets the sky's horizon. Both end in a 4th-power
// fog toward the render distance. c: exposed scene colour; geo: the pixel has depth (wp valid); keepSky: Distant Horizons
// drew its LODs where the depth is empty (leave those pixels). Returns the exposed colour.
// (FT2.8, border false: Distant Horizons' LODs, audit idx 101: the medium without the render distance's closing border, whose r^4
// would turn every LOD into flat smoke)
static float3 shadeDimsFog(float3 c, float3 wp, bool geo, constant ShadeFrame &f, constant ShadeLook &L, float ex, bool keepSky,
                           texture2d<half> mw, bool border = true) {
	float sigma = L.dimTint.x;
	bool nether = shadeDimKind(L) == 1;
	float yc = f.cameraBlock.y + f.cameraFract.y;
	float3 S = f.horizon[SHADE_DP_FOG].rgb;
	float3 lava = f.horizon[SHADE_DP_LAVA].rgb;
	if (!geo) {
		if (!nether || keepSky) return c;
		float g = exp(-max(yc - L.dimTint.y, 0.0) / 40.0);
		return (S + lava * (0.06 * g)) * ex; // the Nether's void: smoke all the way
	}
	float d = length(wp);
	float3 v = wp / max(d, 1e-4);
	float tau = sigma * d;
	if (nether) tau += sigma * 1.0 * shadeLayerDepth(yc, v.y, d, L.dimTint.y + 6.0, 16.0);
	float3 mid = float3(f.cameraBlock.xyz) + f.cameraFract.xyz + wp * 0.5;
	float n = shadeDimsNoise(mw, mid.xz * (1.0 / 40.0) + float2(mid.y * (1.0 / 70.0), 0.0) + L.clock2.x * float2(0.004, 0.0017)); // (FT2.8: the sky's slow clock, no jump)
	tau *= 0.6 + 0.8 * n;
	float T = exp(-tau);
	float3 Sc = S;
	if (nether) {
		float ym = yc + wp.y * 0.5;
		float g = exp(-max(ym - L.dimTint.y, 0.0) / 30.0);
		Sc = S * (0.8 + 0.4 * n) + lava * (0.065 * g); // less lava glow in the haze: less of an orange wash over the lava sea
	}
	float3 o = c * T + Sc * ex * (1.0 - T);
	if (border && L.dimTint.z > 0.0) {
		float r = max(length(wp.xz), abs(wp.y)) / L.dimTint.z;
		float b = saturate(r * r * r * r);
		float3 edge = nether ? Sc : f.horizon[3].rgb;
		o = mix(o, edge * ex, b);
	}
	return o;
}

// Heat shimmer over distant Nether terrain: a pixel offset (output pixels), growing with distance.
static inline float2 shadeShimmer(float2 uv, float dist, constant ShadeFrame &f, texture2d<half> mw) {
	float k = saturate((dist - 24.0) / 64.0);
	if (k <= 0.0) return float2(0.0);
	float t = f.sunPath.w;
	float a = shadeDimsNoise(mw, uv * float2(48.0, 30.0) + float2(0.0, t * 0.9));
	float b = shadeDimsNoise(mw, uv * float2(48.0, 30.0) + float2(7.3, t * 0.7));
	return (float2(a, b) - 0.5) * (1.4 * k);
}

// ---- camera inside a medium (E26) -------------------------------------------------------------------------------------------
// Lava: a glowing, slowly churning orange (brighter than paper white: it blooms, and in XDR it really glows) with darker
// crimson edges; powder snow: a bright cold frost with soft crystalline variation. dist: blocks to the surface (1e4 sky).
// Water keeps the water module's own treatment. Returns the exposed colour.
static float3 shadeMedia(float3 c, float2 uv, float dist, constant ShadeFrame &f, texture2d<half> mw) {
	int type = f.flags.y;
	float t = f.sunPath.w;
	float2 r = (uv - 0.5) * float2(1.5, 1.0);
	float edge = smoothstep(0.25, 0.85, length(r));
	if (type == 2) {
		float n1 = shadeDimsNoise(mw, uv * float2(5.0, 3.0) + float2(t * 0.03, -t * 0.12));
		float n2 = shadeDimsNoise(mw, uv * float2(12.0, 8.0) + float2(-t * 0.05, -t * 0.22) + n1 * 1.3);
		float glow = 0.9 + 1.8 * n1 * n2 + 0.5 * smoothstep(0.55, 0.9, n2);
		float3 lava = float3(1.0, 0.26, 0.03) * (0.3 * glow) * mix(1.0, 0.45, edge) + float3(0.18, 0.015, 0.0) * edge;
		float T = exp(-2.5 * dist);
		return mix(lava, c, T);
	}
	if (type == 3) {
		float n1 = shadeDimsNoise(mw, uv * float2(24.0, 16.0));
		float n2 = shadeDimsNoise(mw, uv * float2(70.0, 44.0) + n1);
		float frost = 0.78 + 0.12 * n1 + 0.18 * smoothstep(0.7, 0.95, n2) + 0.15 * edge;
		float3 snow = float3(0.84, 0.9, 1.0) * frost;
		float T = exp(-1.2 * dist) * (1.0 - 0.6 * edge);
		return mix(snow, c, T);
	}
	return c;
}

#endif
