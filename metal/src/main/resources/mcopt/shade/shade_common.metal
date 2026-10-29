// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// mcopt native shading (-Dmcopt.shade=true): what every shaded pipeline shares. The Java side (mcopt.metal.shade.ShadeMsl)
// prepends this file, unchanged, to each shader that uses it, after "#define MCOPT_SHADE" and the MCOPT_SLOT_* defines.
//
// Global bindings, set on every render encoder for both stages (mcshade.m, ShadeBindings):
//   buffer(16)   constant ShadeFrame&        this frame's values (layout below = ShadeFrame.java's packer)
//   texture(16)  depth2d_array<float>        sun/moon shadow map, one slice per cascade (see SHADOW MAP CONVENTION)
//   sampler(12)  comparison sampler          linear (2x2 hardware PCF), clamp to edge, MTLCompareFunctionGreaterEqual
//   texture(17)  texture2d<half>             sky-view LUT (RGBA16Float, SHADE_LUT_W x SHADE_LUT_H): the atmosphere's radiance
//                                            for the upper hemisphere, rendered once per frame (sky_lut.metal) before the sky
//   sampler(13)  linear, clamp to edge       for the LUT
// Slots 16-19 (buffers, textures) and samplers 12-15 are reserved for shade.
//
// SPACES. "World" below means camera-relative world space: world axes (+y up, the sun sets toward -x), origin at the
// camera. Sodium terrain vertices, the sky and the shadow matrices all use it. Absolute = cameraBlock + cameraFract + P.
// Clip space is renderpearl's: reversed Z in [0, 1] (near = 1, far = 0), GL row order (y up); hand-written vertex shaders
// negate gl_Position.y like SPIRV-Cross does for the game's own.
//
// SHADOW MAP CONVENTION (shared with the shadow pass, mcopt.metal.shade.shadow / mcshadow.m):
//   shadowViewProj[c] maps camera-relative world to the shadow clip space of cascade c: orthographic, x and y in [-1, 1],
//   z in [0, 1] REVERSED (1 = nearest to the light, cleared to 0, depth test GreaterEqual). The shadow pass's own vertex
//   shader writes that clip position as is (it does NOT negate y), so texel (u, v) = (x * 0.5 + 0.5, 0.5 - y * 0.5) in
//   Metal texture coordinates (v down) — see shadeShadowUV. A receiver is lit when its (biased) depth >= the stored one.
//   Cascades are chosen by their box (shadeShadow), not by distance: slice 0 = near cascade (redrawn every frame, pushed
//   ahead of the view), slice 1 = far cascade (centered on the camera, redrawn every few frames, world-anchored). The map
//   is cleared to 0 (no caster); casters are biased at raster time (constant + slope), receivers add shadeShadow's offset.
//   The compare sampler compares ref OP texel (GreaterEqual: lit when ref >= stored). Only light-facing faces cast.
//   lightDirWorld is the shadow pass's own (quantized, at least 2 degrees up) light direction, so N.L and shadows agree.
//   Full rationale: SHADOW.md (the shadow contract) and shade_shadow.metal.
#ifndef MCOPT_SHADE_COMMON
#define MCOPT_SHADE_COMMON
#include <metal_stdlib>
using namespace metal;

// ---- per-frame values -------------------------------------------------------------------------------------------------
// Byte offsets are fixed: mcopt.metal.shade.ShadeFrame (Java) writes exactly this layout, 1024 bytes. Change both together.
struct ShadeFrame {
	float4x4 view;              //   0  world -> view (rotation only)
	float4x4 proj;              //  64  view -> clip as the world is drawn (view bobbing, hurt tilt and nausea included);
	                            //      the TAA sub-pixel jitter (mcopt.shade.taa) is in it (jitter.xy)
	float4x4 viewProj;          // 128  proj * view
	float4x4 invViewProj;       // 192  inverse(viewProj): clip -> world
	float4x4 prevViewProj;      // 256  last frame's viewProj, re-based on this frame's camera: world (now) -> last frame's clip
	float4x4 shadowViewProj[2]; // 320  world -> shadow clip per cascade (identity while shadows are off)
	float4 cameraBlock;         // 448  xyz floor(camera position) (exact below 2^24), w texture gradient scale for the TAA render
	                            //      scale (mip bias log2 of it; 1 at native; M2: moves to ShadeLook.renderScale)
	float4 cameraFract;         // 464  xyz camera position - cameraBlock, w camera height above sea level (y - 63) in blocks
	float4 sunDirWorld;         // 480  xyz unit vector toward the sun, w = its y (sine of the sun's elevation)
	float4 sunDirView;          // 496  xyz the same in view space, w 0
	float4 moonDirWorld;        // 512  xyz unit vector toward the moon, w moon phase brightness (0 new .. 1 full)
	float4 lightDirWorld;       // 528  xyz the light that shines and casts shadows: the sun by day, the moon by night; w 1 sun, 0 moon
	float4 sunColor;            // 544  rgb light from lightDirWorld (sun or moon) reaching the ground: linear, pre-exposure, divided by
	                            //      pi (a white Lambert surface facing it reflects exactly this), after the atmosphere and weather; w luminance
	float4 ambientSky;          // 560  rgb sky light on an upward surface (irradiance / pi) at sky light 15, w 0
	float4 ambientGround;       // 576  rgb light bounced up from the ground (irradiance / pi) on a downward surface at sky light 15, w 0
	float4 ambientBlock;        // 592  rgb block light (torches) at block light 15, linear; w minimum ambient (caves; brightness option, night vision)
	float4 fogColor;            // 608  rgb the game's fog colour (sRGB, as vanilla uses it); a how much of it to use instead of the
	                            //      atmosphere (1 under water / in lava / powder snow, with blindness or darkness, and outside the overworld)
	float4 fogRange;            // 624  x environmental start, y environmental end, z render distance start, w render distance end (blocks)
	float4 fogSky;              // 640  x vanilla sky fog end, y cloud fog end, z aerial haze density (1/blocks), w haze strength 0..1
	float4 skyColor;            // 656  rgb the game's sky colour (sRGB), a 1 - rain
	float4 zenithColor;         // 672  rgb atmosphere radiance straight up (linear, pre-exposure), w opposite sunset chroma (1 default)
	float4 horizon[8];          // 688  rgb atmosphere radiance on the horizon (linear, pre-exposure) for directions with x = -1 .. 1
	                            //      (index i <-> x = i / 3.5 - 1; the sun moves in the x-y plane, so x alone sets the angle to it)
	float4 cascadeSplits;       // 816  x, y distance (blocks) within which cascade 0 / 1 covers every direction; z, w blocks per texel of cascade 0 / 1
	float4 shadowParams;        // 832  x 1 / map size, y map size (texels), z depth bias (clip z), w normal offset (texels)
	float4 screen;              // 848  xy render size (pixels: the live sub-rect under TAA dynamic resolution), zw 1 / size
	float4 time;                // 864  x day time: 0 noon, 0.25 sunset, 0.5 midnight, 0.75 sunrise; y game time in seconds (wraps every hour);
	                            //      z exposure (pre-tonemap scale, eye-adapted); w partial tick
	float4 weather;             // 880  x rain 0..1, y thunder 0..1, z night vision 0..1, w star brightness
	float4 jitter;              // 896  xy NDC jitter in proj this frame, zw last frame's (0 without TAA)
	float4 atmosphere;          // 912  x sun intensity, y moon intensity, z Mie amount (haze, rain), w sky brightness multiplier
	float4 ambientToward;       // 928  rgb sky (+ half the ground's) light on a vertical face turned toward the sun's azimuth (shadeSkyAxis), w 0
	float4 ambientAway;         // 944  rgb the same for a vertical face turned away from it, w 0
	int4 flags;                 // 960  x dimension (0 overworld, 1 nether / no sky, 2 end), y fog type (0 air, 1 water, 2 lava, 3 powder snow),
	                            //      z shadows enabled (0/1), w debug mode (0 off, 1 shadow map, 2 normals, 3 lighting only)
	int4 flags2;                // 976  x frame index (wraps), y underwater (0/1), z cascade count, w sky light at the camera (0..15)
	float4 sunPath;             // 992  x sin, y cos of the sun path tilt (mcopt.shade.sunTilt: the sun and moon orbit rotated about
	                            //      world x, toward +z at noon), z dev bits (mcopt.shade.dev, for pricing features: SHADE_DEV_*),
	                            //      w the water's animation clock in seconds (real time with mcopt.shade.waterClock)
	float4 wxLine;              // 1008 (2026-10-11, M3 weather; mcopt.shade.snowLine) the camera biome's snow line, absolute world y:
	                            //      x the lowest snow cover reaches, y the highest rain's wetness and puddles reach (each kept from
	                            //      the last time it snowed / rained; +-1e4 = everywhere / nowhere), z blend half-width (blocks),
	                            //      w bits: 1 = the snow line is on (else no height limit, M3's look), 2 = (2026-10-12,
	                            //      mcopt.shade.wetWalls) wet walls without the glossy film, mirror rays below the horizon see the ground,
	                            //      4 = (mcopt.shade.wetVegLight) wet vegetation darkens a third as much, 8 = (mcopt.shade.wetVegPuddles)
	                            //      grass tops hold about a third of the puddles, shallower
};

// (2026-10-11, ShadeFrame.wxLine) how much of the snow cover (x) and of the rain's wetness and puddles (y) reaches a surface at
// absolute height yAbs: snow above the camera biome's snow line (blended over the game's +-8 blocks of noise), rain fully up to
// the line and fading over the 16 blocks above it (rain still falls on some columns there; better wet than white)
static inline half2 shadeWxReach(float yAbs, constant ShadeFrame &f) {
	if ((int(f.wxLine.w + 0.5) & 1) == 0) return half2(1.0h);
	return half2(half(smoothstep(f.wxLine.x - f.wxLine.z, f.wxLine.x + f.wxLine.z, yAbs)),
	             half(1.0 - smoothstep(f.wxLine.y, f.wxLine.y + 2.0 * f.wxLine.z, yAbs)));
}

// (2026-10-12, ShadeFrame.wxLine.w bit 2, mcopt.shade.wetWalls) the wet walls / downward mirror rays fix (weather_surface.metal)
static inline bool shadeWxWalls(constant ShadeFrame &f) { return (int(f.wxLine.w + 0.5) & 2) != 0; }
static inline bool shadeWxVegLight(constant ShadeFrame &f) { return (int(f.wxLine.w + 0.5) & 4) != 0; }
static inline bool shadeWxVegPuddles(constant ShadeFrame &f) { return (int(f.wxLine.w + 0.5) & 8) != 0; }
// How much albedo reads as vegetation (grass tops, leaves): green over red and blue, relative to green (weather_surface.metal)
static inline half shadeWxVegHue(half3 albedo) {
	half g = max(albedo.g, 0.001h);
	return saturate(((g - max(albedo.r, albedo.b)) / g - 0.1h) * 2.5h);
}

// mcopt.shade.dev bits (sunPath.z): switch features off to price them in game; 0 in normal use.
#define SHADE_DEV_NO_FOG_LUT 1    // terrain fog without the LUT lookup (constant horizon colour)
#define SHADE_DEV_NO_SHADOW 2     // terrain without shadow map lookups
#define SHADE_DEV_FLAT_SKY 4      // sky pixels: the zenith colour only
#define SHADE_DEV_NO_WATER 8      // no water reflection
#define SHADE_DEV_FLAT_LIGHT 16   // terrain: albedo * constant (no lighting, fog or tone curve maths)
// M3 weather (weather_surface.metal, weather.metal); high bits so other modules' new bits don't collide
#define SHADE_DEV_WX_NO_SSR 1024      // puddles reflect the sky only (no march of last frame's image)
#define SHADE_DEV_WX_NO_RIPPLES 2048  // no raindrop rings on puddles
#define SHADE_DEV_WX_DRY 4096         // terrain stays dry (no wet layer, puddles, snow)
#define SHADE_DEV_WX_PLAIN_RAIN 8192  // rain streaks shaded the M2 way (no sky lookup)
#define SHADE_DEV_WX_NO_TINT 16384    // no coloured shadows: no tint lookup on the terrain, no tint pass (ShadowPass)
#define SHADE_DEV_WX_ANALYTIC 32768   // puddle/snow noise evaluated per pixel instead of the baked tile
#define SHADE_DEV_WX_NO_SSR_GATE 65536 // puddle reflections marched on every puddle pixel (not only where Fresnel shows them)
// M3 weather budget gates: always on with SHADE_WX_LITE (mcopt.shade.weatherLite, default on for performance and balanced);
// on quality/ultra these dev bits switch them on for pricing (mcbench weather price phases wxrain_c32 / c64 / c128 / c224)
#define SHADE_DEV_WX_SUN_GATE 32       // no sun highlight on wet surfaces in heavy rain (the sun is behind the clouds: <= 32 %)
#define SHADE_DEV_WX_RIPPLE_GATE 64    // raindrop rings only where the puddle mirror shows them (flat Fresnel x puddle >= 0.02)
#define SHADE_DEV_WX_LITE_RAIN 128     // rain streaks lit by the sky's mean light, no sky-view LUT lookup per fragment
#define SHADE_DEV_WX_RAIN_TINT 256     // coloured shadows fade out in heavy rain (the direct sun they colour is <= 32 % there)
#define SHADE_DEV_WX_FILM_SKY 512      // heavy rain: wet films off the puddles reflect the overcast sky's mean light (no LUT lookup)
#define SHADE_DEV_WX_SSR_GATE2 131072  // puddle reflections marched where F x P >= 0.05 (ramp to 0.09) instead of 0.035 (to 0.07)
// M3.3 rain budget options (weather_surface.metal; on by mcopt.shade.rainBudget at startup, or by these bits for pricing)
#define SHADE_DEV_WX_SSR_GATE3 262144   // puddle reflections marched where F x P >= 0.06 (ramp to 0.10) instead of 0.05 (to 0.09)
#define SHADE_DEV_WX_RIPPLE_NEAR 524288 // raindrop rings fade out over 0.02-0.045 blocks per pixel (~10 blocks) instead of 0.03-0.06
#define SHADE_DEV_WX_SSR_STEPS8 1048576 // puddle reflections: 8 march steps (2 per quad lane) instead of SHADE_PUDDLE_STEPS
static inline bool shadeDev(constant ShadeFrame &f, int bit) { return (int(f.sunPath.z) & bit) != 0; }
// The camera is under water (ShadeFrame.flags2.y). 2026-10-08: the translucent terrain's LEAN_ABOVE variant (ShadeLean) is
// only drawn while it is not, so there the view-from-below code compiles out.
#ifdef SHADE_LEAN_ABOVE
#define SHADE_CAMERA_UNDERWATER(f) false
#else
#define SHADE_CAMERA_UNDERWATER(f) ((f).flags2.y != 0)
#endif
// 2026-10-08 optimisation pricing (water.metal, terrain): bits 21-23 of mcopt.shade.dev hold one variant number (0 = none;
// sunPath.z is a float, exact up to 2^24, so there is no room for more single bits). SHADE_WDEV_*: what that variant leaves out.
#define SHADE_WDEV_NO_SSR 1       // water: no screen-space march (sky / rendered-sky reflection only)
#define SHADE_WDEV_SSR_OLD 2      // (FT2.6) water SSR: FT2.5's thickness (1 step) and no fallback behind (was free: price3, no
                                  // bisection -0.18 ms, 2 steps -0.07)
#define SHADE_WDEV_SSR_THICK 3    // (FT2.6) water SSR: thickness 3 steps, no fallback behind
#define SHADE_WDEV_SSR_BEHIND 4   // (FT2.6) water SSR: thickness 1 step, a miss takes the first crossing behind something (was free:
                                  // price3 "notex", the block texture no longer sampled on water pixels, -0.11 ms)
#define SHADE_WDEV_SSR_BOTH 5     // (FT2.6) water SSR: both (was free: price3, the crossing refined by 2 rounds of 3 parallel
                                  // reads instead of 4 dependent ones: -0.05 ms)
#define SHADE_WDEV_NO_FOG 6       // water: no air fog on the water pixel itself (shadeFogAir2)
#define SHADE_WDEV_NO_DETAIL 7    // water: no fine-ripple sample (the long swell only)
// (2026-10-08 price1/price2 within noise: the clouds' dome, the rendered-sky reflection, caustics, M3.4's soft shadow; -0.05 to
// -0.1: anisotropic waves, refraction shift, the per-lane hit reprojection, haze on SSR hits. A test inside shadeWaterHazed
// crashed the Metal compiler service building the HDR translucent pipeline.)
// (FT2.8, audit idx 95/108) bit 23 is also ShadeDims' FLAG_DIMS_LIT in the Nether/End: the variants are read in the overworld
// only, and shadeDimsLit outside it only (shade_dims.metal), so neither can take the other's bit.
static inline int shadeWdev(constant ShadeFrame &f) { return f.flags.x == 0 ? (int(f.sunPath.z) >> 21) & 7 : 0; }
// Only with -Dmcopt.shade.wdev=true (SHADE_WDEV_ON: present they cost ~0.09 ms in the lake spin, price5c), and only in the
// variant for the camera above water (the full variant keeps FT1.3's code: the water shader is register-bound, price6).
#if defined(SHADE_LEAN_ABOVE) && defined(SHADE_WDEV_ON)
#define SHADE_WDEV_IS(f, k) (shadeWdev(f) == (k))
#else
#define SHADE_WDEV_IS(f, k) false
#endif

// (1.1.1) Inf/NaN tests that fast math can't remove. The shade libraries compile with MTLMathModeFast, under which the
// compiler may assume no Inf or NaN and fold isfinite() to true (a newer compiler, macOS 27's for one, may start doing so):
// one bad pixel in a temporal history would then spread frame after frame as a growing black or white block. An all-ones
// exponent is Inf or NaN; the integer test survives any float optimization.
static inline bool shadeBad(half4 v) { return any((as_type<ushort4>(v) & ushort4(0x7c00)) == ushort4(0x7c00)); }
static inline bool shadeBad(float3 v) { return any((as_type<uint3>(v) & uint3(0x7f800000)) == uint3(0x7f800000)); }

// ---- view rays ----------------------------------------------------------------------------------------------------------
// The eye, camera-relative world (blocks) from an inverse view-projection: the camera's origin, except that view bobbing
// (GameRenderer.bobView, multiplied into the projection) moves it by up to ~0.1 block. The projection's centre maps to clip
// (0, 0, c, 0), so it is the inverse's third column (homogeneous); the TAA jitter (a clip-space shear) leaves it in place.
static inline float3 shadeEye(float4x4 invViewProj) { float4 e = invViewProj[2]; return e.xyz / e.w; }
// The view ray through NDC point ndc (camera-relative world, not normalized): from the eye through the pixel. The point at
// NDC depth 0.5 alone (reversed Z, near 0.05) is only ~0.1 block in front of the eye: taken as a direction from the camera's
// origin it swung by up to ~45 degrees with view bobbing (walking on the ground: the whole sky turned, Gael 2026-10-08).
// Affine in ndc (a plane minus a constant): a vertex shader may interpolate it across a full-screen triangle.
static inline float3 shadeViewRay(float2 ndc, float4x4 invViewProj) {
	float4 w = invViewProj * float4(ndc, 0.5, 1.0);
	return w.xyz / w.w - shadeEye(invViewProj);
}

#define SHADE_DIM_OVERWORLD 0
#define SHADE_DIM_NETHER 1
#define SHADE_DIM_END 2

// ---- colour -------------------------------------------------------------------------------------------------------------
static inline half3 shadeToLinear(half3 c) { return c * c * (c * 0.305306011h + 0.682171111h) + c * 0.012522878h; } // close fit of the sRGB curve
static inline half3 shadeToSrgb(half3 c) {
	half3 s1 = sqrt(c), s2 = sqrt(s1), s3 = sqrt(s2);
	return saturate(half(0.585122381) * s1 + half(0.783140355) * s2 - half(0.368262736) * s3); // close fit of the inverse sRGB curve
}
static inline float shadeLuma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
static inline half shadeLumaH(half3 c) { return dot(c, half3(0.2126h, 0.7152h, 0.0722h)); }

// Tone curve on linear values: an exponential shoulder (1 - e^-1.1x) with a slight toe (y^2 / (y + 0.006)), so shadows keep depth and
// highlights roll off instead of clipping. Applied hue-preservingly (shadeOutput): the brightest channel goes through the
// curve and the others keep their ratio to it, so saturated colours (a sunset horizon, a low sun) keep their hue instead of
// clipping a channel to 0 or turning yellow-white; only near the top of the range does the colour blend toward the
// per-channel result (bright light desaturates, like film). Night: a dim-light shift (rods) toward a cool grey, driven by
// the scene's own luminance before exposure. LDR output (M1); M2 moves this to an HDR target and a post pass.
static inline float shadeCurve(float x) {
	float y = 1.0 - exp2(-1.5869637 * max(x, 0.0)); // 1 - e^-1.1x
	return y * y * 1.006 / (y + 0.006);
}
static inline float3 shadeCurve3(float3 x) {
	float3 y = 1.0 - exp2(-1.5869637 * max(x, 0.0));
	return y * y * 1.006 / (y + 0.006);
}

// Linear radiance (pre-exposure) -> the sRGB value the RGBA8 target stores.
static inline float3 shadeOutput(float3 radiance, constant ShadeFrame &f) {
	float3 c = max(radiance, 0.0);
	float lin = shadeLuma(c);                                                         // absolute (pre-exposure) luminance
	float rods = (1.0 - smoothstep(0.004, 0.04, lin)) * 0.55;
	c = mix(c, float3(lin) * float3(0.72, 0.88, 1.3), rods) * f.time.z;
	float m = max(max(c.r, c.g), max(c.b, 1e-6));
	float tm = shadeCurve(m);
	float3 o = c * (tm / m);
	if (tm > 0.6) o = mix(o, shadeCurve3(c), smoothstep(0.6, 1.0, tm) * 0.6); // only bright pixels pay for the per-channel curve
	return float3(shadeToSrgb(half3(saturate(o))));
}

// The same curve for a single colour on the CPU side: ShadeFrame.output (underwater fog colour) mirrors shadeOutput.

// ---- atmosphere ---------------------------------------------------------------------------------------------------------
// Single scattering in a Rayleigh + Mie + ozone atmosphere (units: km), integrated along the view ray with 8 samples; the
// light's optical depth at each sample is analytic (Chapman function approximation for an exponential atmosphere, with the
// tangent-point form below the local horizon and the planet's shadow). ShadeSky.java mirrors this exactly for the sun,
// ambient and horizon colours, so the sky, the terrain's light and its fog agree.
#define SHADE_R_GROUND 6360.0f
#define SHADE_R_TOP 6420.0f
#define SHADE_ALTITUDE 0.5f
#define SHADE_H_R 8.0f
#define SHADE_H_M 1.2f
#define SHADE_MIE_G 0.78f
#define SHADE_SAMPLES 8
#define SHADE_SKY_SATURATION 1.3f
constant float3 SHADE_BETA_R = float3(5.802e-3, 13.558e-3, 33.1e-3);
constant float SHADE_BETA_M = 3.996e-3;
constant float SHADE_BETA_M_EXT = 4.440e-3;
constant float3 SHADE_BETA_O = float3(0.650e-3, 1.881e-3, 0.085e-3) * 2.2; // ozone, riding on the Rayleigh density profile

// Column (km of sea-level-equivalent air) from radius r toward a direction at cosine mu to the vertical, density scale h.
static inline float shadeColumn(float r, float mu, float h) {
	float c = sqrt(r / h * 1.5707963);
	if (mu >= 0.0) return h * exp((SHADE_R_GROUND - r) / h) * c / ((c - 1.0) * mu + 1.0);
	float rt = r * sqrt(max(1.0 - mu * mu, 0.0)); // the ray's lowest point
	// Through the planet (its shadow): instead of no light at all, the grazing column plus extinction growing with depth
	// into the shadow, a cheap stand-in for the multiple scattering that keeps twilight blue rather than black.
	float deep = max(SHADE_R_GROUND - rt, 0.0);
	rt = max(rt, SHADE_R_GROUND);
	float ct = sqrt(rt / h * 1.5707963);
	return h * (2.0 * ct * exp((SHADE_R_GROUND - rt) / h) - exp((SHADE_R_GROUND - r) / h) * c / ((c - 1.0) * -mu + 1.0)) + deep * 1.5;
}

static inline float shadePhaseR(float mu) { return 0.0596831 * (1.0 + mu * mu); }
static inline float shadePhaseM(float mu, float g) { // Cornette-Shanks
	float g2 = g * g;
	return 0.1193662 * (1.0 - g2) * (1.0 + mu * mu) / ((2.0 + g2) * pow(max(1.0 + g2 - 2.0 * g * mu, 1e-4), 1.5));
}

// Radiance scattered toward the camera along dir by a light of the given intensity from lightDir. mie scales the Mie
// coefficients (haze, rain). transmittance: of the view ray, through the whole atmosphere (0 toward the ground).
static float3 shadeScatter(float3 dir, float3 lightDir, float intensity, float mie, thread float3 &transmittance) {
	float r0 = SHADE_R_GROUND + SHADE_ALTITUDE;
	float b = r0 * dir.y;
	float tEnd = -b + sqrt(max(b * b - r0 * r0 + SHADE_R_TOP * SHADE_R_TOP, 0.0));
	float dg = b * b - r0 * r0 + SHADE_R_GROUND * SHADE_R_GROUND;
	bool ground = dir.y < 0.0 && dg > 0.0;
	if (ground) tEnd = -b - sqrt(dg);
	float mu = dot(dir, lightDir);
	float pr = shadePhaseR(mu), pm = shadePhaseM(mu, SHADE_MIE_G);
	float betaM = SHADE_BETA_M * mie, betaMExt = SHADE_BETA_M_EXT * mie;
	float odR = 0.0, odM = 0.0, tPrev = 0.0;
	float3 sumR = 0.0, sumM = 0.0;
	for (int i = 0; i < SHADE_SAMPLES; i++) {
		float u = float(i + 1) / float(SHADE_SAMPLES);
		float t = tEnd * u * u, dt = t - tPrev, tm = 0.5 * (t + tPrev);
		tPrev = t;
		float3 p = float3(0.0, r0, 0.0) + dir * tm;
		float r = length(p);
		float dR = exp((SHADE_R_GROUND - r) / SHADE_H_R) * dt, dM = exp((SHADE_R_GROUND - r) / SHADE_H_M) * dt;
		float muL = dot(p, lightDir) / r;
		float cR = odR + 0.5 * dR + shadeColumn(r, muL, SHADE_H_R), cM = odM + 0.5 * dM + shadeColumn(r, muL, SHADE_H_M);
		float3 t3 = exp(-(SHADE_BETA_R + SHADE_BETA_O) * cR - betaMExt * cM);
		sumR += t3 * dR;
		sumM += t3 * dM;
		odR += dR;
		odM += dM;
	}
	transmittance = ground ? float3(0.0) : exp(-(SHADE_BETA_R + SHADE_BETA_O) * odR - betaMExt * odM);
	return intensity * (SHADE_BETA_R * pr * sumR + betaM * pm * sumM);
}

// Art grade on the single-scattering sky while the sun is low (ShadeSky.goldenHour mirrors it): warmer toward the horizon,
// so a sunset reads golden and pink instead of a blue sky with a thin yellow line; nothing by day, at night or in rain.
static inline float3 shadeGoldenHour(float dirY, float sunY, float rain) {
	float w = (1.0 - smoothstep(0.02, 0.32, sunY)) * smoothstep(-0.16, -0.02, sunY) * (1.0 - rain);
	float h = 1.0 - saturate(abs(dirY));
	return mix(float3(1.0), float3(1.45, 1.02, 0.72), w * (0.55 + 0.45 * h * h * h));
}

// M3 sunset art (mcopt.shade.sunsetArt; ShadeSky.radiance mirrors it): the golden-hour grade follows the sun's azimuth, as
// real skies and the studied packs do (BSL / Complementary: the bright band widens toward the sun), instead of warming every
// azimuth alike (a flat orange ring around the horizon): a broad gold-orange glow toward the sun whose band reaches higher,
// peach on the sides, and opposite the sun a thin rose-lilac band (the Belt of Venus) over a cooler horizon.
static inline float3 shadeSunsetGrade(float3 dir, float3 sun, float sunY, float rain) {
	float w = (1.0 - smoothstep(0.02, 0.32, sunY)) * smoothstep(-0.16, -0.02, sunY) * (1.0 - rain);
	float h = 1.0 - saturate(abs(dir.y));
	float dl = dot(dir.xz, dir.xz), sl = dot(sun.xz, sun.xz);
	float toward = dl > 1e-8 && sl > 1e-8 ? dot(dir.xz, sun.xz) * rsqrt(dl * sl) * 0.5 + 0.5 : 0.5;
	float band = pow(max(h, 1e-4), mix(9.0, 2.0, toward * toward));
	float3 col = toward > 0.5 ? mix(float3(1.40, 0.97, 0.82), float3(1.50, 0.96, 0.72), pow(toward * 2.0 - 1.0, 2.5))
	                          : mix(float3(1.18, 0.90, 1.06), float3(1.40, 0.97, 0.82), toward * 2.0);
	// a wide gold halo around the sun (the warm glow the studied packs wrap around a low sun)
	float glow = pow(saturate(dot(dir, normalize(sun))), 10.0);
	col = mix(col, float3(1.55, 1.0, 0.70), glow * 0.4);
	return mix(float3(1.0), col, w * saturate(0.2 + 0.8 * band + 0.4 * glow));
}

// Keep the RGB atmosphere's blue-to-gold transition from peaking in green, including pale sky.
// Atmospheric radiance only: foliage and other green materials must not pass through this correction.
// ShadeSky.radiance mirrors it for ambient lighting. Also used after the LUT's directional grade.
static inline float3 shadeSunsetHue(float3 sky, float sunY) {
	float transition = (1.0 - smoothstep(0.32, 0.50, sunY)) * smoothstep(-0.16, -0.02, sunY);
	if (transition <= 0.0) return sky;
	float before = shadeLuma(sky);
	sky.g -= max(sky.g - 0.96 * max(sky.r, sky.b), 0.0) * transition;
	return sky * (before / max(shadeLuma(sky), 1e-8));
}

// M3 sunset art: a low sun's horizon reads warm peach-gold, never pure saturated amber (the long path leaves almost no blue;
// the studied packs keep some in it): while the sun is low, very saturated sky gives part of its chroma back to its
// luminance, and the warm hue leans from lemon toward peach. ShadeSky.radiance mirrors it.
static inline float3 shadeSunsetChroma(float3 sky, float sunY, float rain) {
	float w = (1.0 - smoothstep(0.02, 0.32, sunY)) * smoothstep(-0.16, -0.02, sunY) * (1.0 - rain);
	float mx = max(max(sky.r, sky.g), sky.b), mn = min(min(sky.r, sky.g), sky.b);
	if (w <= 0.0 || mx <= 1e-6) return sky;
	float k = smoothstep(0.55, 1.0, 1.0 - mn / mx) * w;
	float l = dot(sky, float3(0.2126, 0.7152, 0.0722));
	float3 c = (sky - l) * (1.0 - 0.36 * k);
	c.g -= 0.06 * k * max(c.r, 0.0); // lemon -> peach
	return max(l + c, 0.0);
}

// M3 sunset art: the golden-hour sky's warm band reaches higher (Photon's "horizon stretch", mu <- mu^1.25, to admire the
// sunset without looking down), more toward the sun: the direction the LUT samples the atmosphere at for a view direction.
static inline float3 shadeSunsetStretch(float3 dir, float3 sun, float sunY, float rain) {
	float w = (1.0 - smoothstep(0.02, 0.32, sunY)) * smoothstep(-0.16, -0.02, sunY) * (1.0 - rain);
	if (w <= 0.0 || dir.y <= 0.0) return dir;
	float dl = dot(dir.xz, dir.xz), sl = dot(sun.xz, sun.xz);
	float toward = dl > 1e-8 && sl > 1e-8 ? dot(dir.xz, sun.xz) * rsqrt(dl * sl) * 0.5 + 0.5 : 0.5;
	float y = pow(dir.y, 1.0 + (mix(1.15, 1.45, toward * toward) - 1.0) * w);
	return float3(dir.xz * sqrt(max(1.0 - y * y, 0.0) / max(dl, 1e-8)), y).xzy;
}

// The sky's radiance along dir (no sun disc): sun and moon scattering, faint airglow, overcast in rain. Linear, pre-exposure.
// art: M3 sunset art (shadeSunsetGrade) instead of M2's shadeGoldenHour.
static inline float3 shadeAwaySunset(float3 sky, float3 dir, constant ShadeFrame &f) {
	if (f.zenithColor.w >= 1.0) return sky;
	float dl = dot(dir.xz, dir.xz), sl = dot(f.sunDirWorld.xz, f.sunDirWorld.xz);
	float az = dl > 1e-8 && sl > 1e-8 ? dot(dir.xz, f.sunDirWorld.xz) * rsqrt(dl * sl) : 0.0;
	float k = (1.0 - saturate(f.zenithColor.w)) * (1.0 - smoothstep(-0.2, 0.4, az))
	        * (1.0 - smoothstep(0.02, 0.32, f.sunDirWorld.w)) * smoothstep(-0.16, -0.02, f.sunDirWorld.w) * (1.0 - f.weather.x);
	return mix(sky, float3(shadeLuma(sky)), k);
}
static float3 shadeSkyRadiance(float3 dir, constant ShadeFrame &f, thread float3 &transmittance, bool art = false, bool gradeAway = true) {
	float3 sky = float3(0.0);
	float3 tr = float3(1.0);
	float mie = f.atmosphere.z;
	if (f.sunDirWorld.w > -0.22) sky += shadeScatter(dir, f.sunDirWorld.xyz, f.atmosphere.x, mie, tr);
	if (f.atmosphere.y > 0.0) sky += shadeScatter(dir, f.moonDirWorld.xyz, f.atmosphere.y, mie, tr) * float3(0.85, 0.95, 1.25);
	sky += float3(0.0003, 0.00045, 0.0009) * (1.0 - 0.5 * f.weather.x);  // airglow: the night sky is never black
	float rain = f.weather.x;
	float l = shadeLuma(sky);
	sky = max(l + (sky - l) * SHADE_SKY_SATURATION, sky * 0.5); // ShadeSky.SKY_SATURATION, never below half the channel
	sky *= art ? shadeSunsetGrade(dir, f.sunDirWorld.xyz, f.sunDirWorld.w, rain) : shadeGoldenHour(dir.y, f.sunDirWorld.w, rain);
	if (art) sky = shadeSunsetChroma(sky, f.sunDirWorld.w, rain);
	sky = mix(sky, float3(l) * float3(0.92, 0.96, 1.0) * (1.0 - 0.45 * f.weather.y), rain * 0.75) * f.atmosphere.w;
	if (art) sky = shadeSunsetHue(sky, f.sunDirWorld.w);
	transmittance = tr;
	return gradeAway ? shadeAwaySunset(sky, dir, f) : sky;
}

// The atmosphere on the horizon toward dir, from the per-frame table (what the terrain fogs into).
static inline float3 shadeHorizon(float3 dir, constant ShadeFrame &f) {
	float2 d = normalize(dir.xz + float2(1e-5, 0.0));
	float x = clamp((d.x + 1.0) * 3.5, 0.0, 6.999);
	int i = int(x);
	return mix(f.horizon[i].xyz, f.horizon[i + 1].xyz, x - float(i));
}

// Unit horizontal vector toward the sun's azimuth (+x when the sun is straight up; the sky is round then anyway).
static inline float2 shadeSkyAxis(constant ShadeFrame &f) {
	float2 a = f.sunDirWorld.xz;
	float l = length(a);
	return l > 1e-3 ? a / l : float2(1.0, 0.0);
}

// ---- lighting -----------------------------------------------------------------------------------------------------------
// Light levels arrive as Sodium's lightmap coordinates (0..240 for levels 0..15), normalized to 0..1.
static inline half shadeSkyCurve(half s) { return s / (half(4.0) - half(3.0) * s); }    // vanilla's brightness curve
static inline half shadeBlockCurve(half b) {                                               // vanilla's, steeper: pools with edges
	half v = b / (half(4.0) - half(3.0) * b);
	return v * v * (half(0.5) + half(0.5) * v);
}

// Vanilla's directional face shade for a face normal (what the face-shade-off mixin removed from the vertex colours),
// for the dimensions that keep vanilla-style lighting: down, up, north/south, west/east.
static inline half shadeVanillaFace(half3 n, int dimension) {
	half3 a = abs(n);
	half up = dimension == SHADE_DIM_NETHER ? half(0.9) : half(1.0), down = dimension == SHADE_DIM_NETHER ? half(0.9) : half(0.5);
	half y = n.y > half(0.0) ? up : down;
	return (a.x * half(0.6) + a.z * half(0.8) + a.y * y) / max(a.x + a.y + a.z, half(1e-3));
}

// Interleaved gradient noise (Jimenez 2014): a per-pixel rotation that TAA (M2) will average out.
static inline float shadeNoise(float2 pixel, int frame) {
	pixel += float(frame & 63) * 5.588238;
	return fract(52.9829189 * fract(dot(pixel, float2(0.06711056, 0.00583715))));
}

// Overworld light on a surface (linear radiance, pre-exposure). albedo linear; n unit face normal; sky, block light 0..1;
// shadow the light's visibility; thin: crossed plants and other slanted two-sided cutouts (light passes through, no hard
// terminator); foliage: axis-aligned cutout faces (leaves, vines): wrapped light, so canopies glow a little where the light
// passes through them instead of going flat on the sides and undersides (the map still shadows what's inside).
static float3 shadeLit(half3 albedo, half3 n, half sky, half block, half shadow, bool thin, bool foliage, constant ShadeFrame &f) {
	half nl = half(dot(float3(n), f.lightDirWorld.xyz));
	// thin plants: light through them from either side; leaves: wrapped a little, plus light transmitted through faces
	// turned away from it (backlit canopies glow)
	half ndl = thin ? half(0.3) + half(0.5) * abs(nl) : foliage ? half(0.25) + half(0.75) * saturate(nl) + half(0.5) * saturate(-nl) : saturate(nl);
	// Direct light needs open sky: with a shadow map the map does the work and this only keeps sunlight out of caves; without
	// one, sky light is the only hint of what's overhead.
	half gate = f.flags.z != 0 ? smoothstep(half(0.3), half(0.8), sky) : sky * sky * sky * sky;
	half3 direct = half3(f.sunColor.xyz) * (ndl * shadow * gate);
	float2 axis = shadeSkyAxis(f);
	half towardSun = half(dot(float2(n.xz), axis)) * half(0.5) + half(0.5);
	half3 side = mix(half3(f.ambientAway.xyz), half3(f.ambientToward.xyz), towardSun);
	half3 ambient = n.y >= half(0.0) ? mix(side, half3(f.ambientSky.xyz), n.y) : mix(side, half3(f.ambientGround.xyz), -n.y);
	ambient *= shadeSkyCurve(sky) * (foliage ? half(1.35) : half(1.0)); // leaves scatter the sky's light too
	half3 torch = half3(f.ambientBlock.xyz) * shadeBlockCurve(block);
	if (SHADE_CAMERA_UNDERWATER(f)) { // the camera is under water: daylight arrives filtered by the water above, blue-green and weaker
		direct *= half3(0.22h, 0.5h, 0.62h);
		ambient *= half3(0.35h, 0.62h, 0.8h);
	}
	return float3(albedo) * float3(direct + ambient + torch + half(f.ambientBlock.w));
}

// Vanilla's fog amount for terrain at camera-relative p: the larger of environmental (spherical) and render-distance
// (cylindrical) linear fogs, the same as the game's shaders.
static inline float shadeVanillaFog(float3 p, float2 env, float2 renderDistance) {
	float spherical = length(p), cylindrical = max(length(p.xz), abs(p.y));
	float a = saturate((spherical - env.x) / max(env.y - env.x, 1e-3));
	float b = saturate((cylindrical - renderDistance.x) / max(renderDistance.y - renderDistance.x, 1e-3));
	return max(a, b);
}

// ---- sky-view LUT -------------------------------------------------------------------------------------------------------
// Texel (u, v) holds shadeSkyRadiance toward: azimuth phi = 2 asin(u) away from the sun's (u = sin(phi / 2): linear near
// the sun, where the Mie glow needs texels, and a sqrt instead of an acos to look up; the sky is mirror-symmetric about the
// vertical plane through the sun, and the moon sits in that plane too), and height dir.y = v^2 (dense near the horizon; a
// sqrt to look up, no asin: the lookup runs for every sky and fogged terrain pixel).
#define SHADE_LUT_W 128
#define SHADE_LUT_H 80

static inline float3 shadeLutDirection(float2 uv, constant ShadeFrame &f) {
	float2 axis = shadeSkyAxis(f);
	float phi = 2.0 * asin(saturate(uv.x)), y = uv.y * uv.y, c = sqrt(max(1.0 - y * y, 0.0));
	float2 h = axis * cos(phi) + float2(-axis.y, axis.x) * sin(phi);
	return float3(h.x * c, y, h.y * c);
}

// The atmosphere's radiance toward dir (linear, pre-exposure) from the LUT; directions below the horizon read the horizon
// row, darkened with depth (the ground's haze). The sky and the terrain's fog both come from here, so they meet exactly.
// (FT2.12) uMin > 0: the azimuth no nearer the sun than u = uMin (0.7071 = 90 degrees from it), i.e. the sky without its glow
// around the sun (the forward Mie lobe, the sunset's bright horizon there); farther from the sun the same value
static inline float3 shadeSkyLookup(float3 dir, texture2d<half> lut, sampler s, constant ShadeFrame &f, float uMin = 0.0) {
	float2 axis = shadeSkyAxis(f);
	float2 hz = dir.xz;
	float hl2 = dot(hz, hz);
	float c = hl2 > 1e-8 ? dot(hz, axis) * rsqrt(hl2) : 1.0;
	float u = max(sqrt(saturate(0.5 - 0.5 * c)), uMin);
	float v = sqrt(saturate(dir.y));
	float2 uv = (float2(u, v) * float2(SHADE_LUT_W - 1, SHADE_LUT_H - 1) + 0.5) / float2(SHADE_LUT_W, SHADE_LUT_H);
	float3 sky = float3(lut.sample(s, uv, level(0.0)).rgb);
	return dir.y < 0.0 ? sky * mix(1.0, 0.55, saturate(-dir.y * 3.0)) : sky;
}

// Air fog for lit terrain (pre-exposure): fade into the sky behind it (the LUT toward p), with vanilla's distances
// (vanillaFog) plus a light aerial haze, so far terrain melts into the sky exactly where the sky meets the horizon.
static inline float3 shadeFogAir(float3 radiance, float3 p, float vanillaFog, texture2d<half> lut, sampler s, constant ShadeFrame &f) {
	float haze = (1.0 - exp(-length(p) * f.fogSky.z)) * f.fogSky.w;
	float a = max(vanillaFog, haze) * (1.0 - f.fogColor.a);
	if (shadeDev(f, SHADE_DEV_NO_FOG_LUT)) return mix(radiance, f.horizon[4].rgb, a);
	return a > 0.002 ? mix(radiance, shadeSkyLookup(normalize(p), lut, s, f), a) : radiance; // near the camera: no lookup
}

// Final colour of a shaded surface: exposure, tone curve, sRGB, then the game's own fog colour where it applies (water,
// lava, blindness...; f.fogColor.a), mixed after the tone curve like vanilla mixes it into its LDR colours.
static inline float3 shadeFinish(float3 radiance, float vanillaFog, constant ShadeFrame &f) {
	float3 c = shadeOutput(radiance, f);
	float a = vanillaFog * f.fogColor.a;
	// in water the fog takes red first, then green (the fog colour is the shaded water colour, ShadeFrame.waterFog)
	float3 t = f.flags.y == 1 ? pow(1.0 - a, float3(2.6, 1.25, 1.0)) : float3(1.0 - a);
	return c * t + f.fogColor.rgb * (1.0 - t);
}

// ---- water (M1: a still-water stand-in until M2's real water) ------------------------------------------------------------
// Gentle wave normal for a water surface at camera-relative p: a few long sines over absolute world xz (whole cycles per 64
// blocks, so the camera's block position can wrap at 64 exactly), fading flat with distance so nothing aliases without TAA.
static float3 shadeWaterNormal(float3 p, constant ShadeFrame &f) {
	float2 w = p.xz + f.cameraFract.xz + fmod(f.cameraBlock.xz, 64.0);
	float t = f.time.y;
	const float k = 6.2831853 / 64.0;
	float2 d1 = float2(7.0, 3.0) * k, d2 = float2(-4.0, 9.0) * k, d3 = float2(13.0, -11.0) * k, d4 = float2(-19.0, -6.0) * k;
	float2 g = d1 * cos(dot(d1, w) + t * 1.1) * 0.050 + d2 * cos(dot(d2, w) + t * 1.4) * 0.040
	         + d3 * cos(dot(d3, w) + t * 1.9) * 0.022 + d4 * cos(dot(d4, w) + t * 2.3) * 0.016;
	float fade = 1.0 / (1.0 + length(p) * 0.03);
	return normalize(float3(-g.x * fade, 1.0, -g.y * fade));
}

// A water surface seen from above. Its body colour is a physically tinted base (the biome's water tint as absorption, lit
// by the sky and a little sun) carrying only a trace of vanilla's texture (no tiled specks), under a Fresnel reflection of
// the atmosphere (the sky-view LUT: water picks up the sky's colour, grey in rain) and a sun glint: an energy-normalized
// lobe that widens with distance and wave slope (no clipped slab far away), clamped, with the shadow softened so its edge
// doesn't step with shadow texels. Reflections only where the sky is open (sky light). Returns radiance and the alpha to
// draw with: lower than vanilla's (the bottom shows through near the shore), the reflection opaque in proportion to its
// Fresnel weight. No terrain in the reflection (M2: SSR).
static float4 shadeWater(float3 lit, half3 tint, half texLuma, float alpha, float3 p, half sky, half shadow, texture2d<half> lut, sampler s,
                         constant ShadeFrame &f) {
	float3 pe = p - shadeEye(f.invViewProj); // from the eye: view bobbing moves it
	float d = length(pe);
	float3 v = pe / max(d, 1e-4);
	float3 n = shadeWaterNormal(p, f);
	float cosT = saturate(dot(-v, n));
	float fr = 0.025 + 0.975 * pow(1.0 - cosT, 4.0);
	float3 r = reflect(v, n);
	r.y = abs(r.y);
	float open = float(shadeSkyCurve(sky));
	float3 refl = shadeSkyLookup(r, lut, s, f) * open;
	float rl = saturate(dot(r, f.lightDirWorld.xyz));
	float e = mix(1200.0, 90.0, saturate(d / 90.0));                         // sharp near, broad and dim far away
	float glint = min(pow(rl, e) * (e + 8.0) * 0.04, 40.0);                  // ~normalized Blinn-Phong lobe, clamped
	float soft = smoothstep(0.15, 0.85, float(shadow));
	refl += f.sunColor.rgb * (glint * soft * open);
	fr *= 0.35 + 0.65 * open;
	// body: deep water absorbs red first; the tint's hue, a little of the texture's variation
	float3 tl = float3(shadeToLinear(tint));
	float3 body = mix(float3(shadeLuma(tl)), tl, 0.45) * float3(0.5, 0.85, 0.95) * (0.85 + 0.3 * float(texLuma));
	float3 radiance = lit * body;
	float bodyAlpha = alpha * 0.75;
	float a = fr + (1.0 - fr) * bodyAlpha;
	return float4((refl * fr + radiance * bodyAlpha * (1.0 - fr)) / max(a, 1e-3), a);
}

// ---- sky ------------------------------------------------------------------------------------------------------------------
#define SHADE_SUN_RADIUS 0.0262f // radians (1.5 degrees: bigger than the real sun, smaller than vanilla's square)

// The sky's final colour toward unit dir (sRGB, what the target stores): the atmosphere (LUT), the sun disc with limb
// darkening in the colour of the light reaching the ground, and the game's fog colour under water and the like.
static float3 shadeSkyColor(float3 dir, texture2d<half> lut, sampler s, constant ShadeFrame &f) {
	if (shadeDev(f, SHADE_DEV_FLAT_SKY)) return float3(0.3, 0.5, 0.8);
	float3 sky = shadeSkyLookup(dir, lut, s, f);
	float cosA = dot(dir, f.sunDirWorld.xyz);
	float x = (1.0 - cosA) / (1.0 - cos(SHADE_SUN_RADIUS)); // ~ (angle / radius)^2
	if (x < 1.3 && f.lightDirWorld.w > 0.5 && dir.y > -0.02) {
		float limb = 0.4 + 0.6 * sqrt(saturate(1.0 - x));
		float disc = (1.0 - smoothstep(0.85, 1.3, x)) * limb;
		sky += f.sunColor.rgb * (40.0 * disc);
	}
	float vanillaSky = dir.y <= 0.0 ? 1.0 : saturate(min(16.0 / max(dir.y, 1e-3), 512.0) / max(f.fogSky.x, 1.0));
	return shadeFinish(sky, vanillaSky, f);
}

// ---- shadows ------------------------------------------------------------------------------------------------------------
// Receiver side of the shadow pass (mcopt.metal.shade.shadow.ShadowPass, mcshadow.m). The same maths as shade_shadow.metal
// (which the headless shadow test uses), on ShadeFrame fields: box-based cascade choice (the near cascade is pushed ahead
// of the view, so a distance test would waste it), a blend band between the cascades, a depth-range fallback to the far
// cascade, a receiver offset along the normal plus toward the light growing with tan(theta), and a 3x3 tent of hardware
// 2x2 PCF taps per cascade (deterministic: no noise to shimmer while M1 has no TAA).
static inline float2 shadeShadowUV(float3 clip) { return float2(clip.x * 0.5 + 0.5, 0.5 - clip.y * 0.5); }

// One cascade: visibility, and m = how far out in its square the point is (>= 1: outside it or its depth range).
static inline float shadeShadowCascade(depth2d_array<float> map, sampler cmp, uint layer, float4x4 vp, float3 p, float3 offset,
                                       float texelUv, float spread, thread float &m) {
	float4 c = vp * float4(p + offset, 1.0);
	m = max(abs(c.x), abs(c.y));
	if (c.z <= 0.0 || c.z >= 1.0) m = 2.0;
	if (m >= 1.0) return 1.0;
	float2 uv = shadeShadowUV(c.xyz);
	float h = spread * texelUv;
	float s = map.sample_compare(cmp, uv + float2(-h, -h), layer, c.z);
	s += map.sample_compare(cmp, uv + float2(h, -h), layer, c.z);
	s += map.sample_compare(cmp, uv + float2(-h, h), layer, c.z);
	s += map.sample_compare(cmp, uv + float2(h, h), layer, c.z);
	return s * 0.25;
}

// Visibility (0 shadowed .. 1 lit) of camera-relative world point p with unit face normal n (facing the camera) from the
// light (f.lightDirWorld). thin: two-sided foliage, offset toward the light only. 1 when shadows are off, past the far
// cascade (fading out over its outer 15%), and for faces turned away from the light (N.L is 0 there anyway).
static half shadeShadow(depth2d_array<float> map, sampler cmp, constant ShadeFrame &f, float3 p, half3 n, bool thin) {
	if (f.flags.z == 0 || shadeDev(f, SHADE_DEV_NO_SHADOW)) return half(1.0);
	float3 L = f.lightDirWorld.xyz;
	float nl = thin ? 1.0 : dot(float3(n), L);
	if (nl <= 0.0) return half(1.0);
	float tanT = clamp(sqrt(max(1.0 - nl * nl, 0.0)) / max(nl, 0.02), 0.0, 12.0);
	float3 dir = thin ? L * 1.5 : float3(n) * 0.75 + L * (0.5 + 0.75 * tanT); // offset per texel of world size
	float texelUv = f.shadowParams.x;
	float m0, m1;
	float near = shadeShadowCascade(map, cmp, 0u, f.shadowViewProj[0], p, dir * f.cascadeSplits.z, texelUv, 0.75, m0);
	if (m0 < 0.85) return half(near);
	float far = shadeShadowCascade(map, cmp, 1u, f.shadowViewProj[1], p, dir * f.cascadeSplits.w, texelUv, 0.5, m1);
	far = mix(far, 1.0, smoothstep(0.85, 1.0, m1));
	return half(m0 >= 1.0 ? far : mix(near, far, smoothstep(0.85, 1.0, m0)));
}

// M3.4 (water, mcopt.shade.waterShadowSoft): one cascade's visibility over a disc of the horizontal plane around p (a water
// surface): 4 taps on a Vogel disc of radius r blocks, turned per pixel and frame (TAAU averages them into a smooth edge),
// in place of shadeShadow's 4-tap tent (same fetches: 8 taps cost +0.42 ms on a half-water view). The map is orthographic,
// so a tap at p + (dx, 0, dz) projects to c0 + dx vp[0] + dz vp[2]: its depth is the plane's there (no acne on a flat
// receiver seen by a low sun).
// (FT2.8, audit idx 97; contact > 0, ShadeLook.waterShadow.z, mcopt.shade.waterShadowContact, live) the penumbra grows with the
// caster's distance toward the light: contact blocks of radius per block (r at r / contact blocks). The disc is shrunk to the
// caster at its centre (one gather), and a tap counts a caster only if it is far enough above the plane to throw a penumbra that
// wide (its compare depth raised by d / contact blocks). Without this a bank more than a block above the water put the disc's
// inland taps under it (inside the bank: shadowed whatever the sun) and drew a soft dark band along every such shore, on the
// side facing the sun too; long shadows of far islands keep their full softness.
static inline float shadeShadowCascadeDisc(depth2d_array<float> map, sampler cmp, uint layer, float4x4 vp, float3 p, float3 offset, float r,
                                           float turn, thread float &m, float contact = 0.0, float3 L = float3(0.0)) {
	float4 c0 = vp * float4(p + offset, 1.0);
	m = max(abs(c0.x), abs(c0.y));
	if (c0.z <= 0.0 || c0.z >= 1.0) m = 2.0;
	if (m >= 1.0) return 1.0;
	float3 ax = vp[0].xyz, az = vp[2].xyz;
	float zPerBlock = 0.0;
	if (contact > 0.0) {
		// orthographic: the map's depth grows by this per block toward the light (reversed Z: nearer the light = larger)
		zPerBlock = max(dot(float3(vp[0].z, vp[1].z, vp[2].z), L), 1e-7);
		constexpr sampler pt(coord::normalized, filter::nearest, address::clamp_to_edge);
		float4 zc = map.gather(pt, shadeShadowUV(c0.xyz), layer);
		float db = (max(max(zc.x, zc.y), max(zc.z, zc.w)) - c0.z) / zPerBlock; // the centre's nearest caster above, blocks
		if (db > 0.02) r = clamp(db * contact, 0.1, r);
	}
	float s = 0.0;
	for (int i = 0; i < 4; i++) {
		float a = (float(i) + turn) * 2.39996323, d = r * sqrt((float(i) + 0.5) * 0.25);
		float3 c = c0.xyz + ax * (cos(a) * d) + az * (sin(a) * d);
		float ref = contact > 0.0 ? c.z + zPerBlock * (d / contact) : c.z;
		s += map.sample_compare(cmp, shadeShadowUV(c), layer, ref);
	}
	return s * 0.25;
}

// M3.4 (water): shadeShadow for an up-facing water surface with a soft edge of radius r blocks. Distant blocky casters (an
// island under a low sun) cut the sun's glint on the water along their block outline; real waves and the sun's own size
// blur that edge over a block or two (water only: sodium_terrain.fs.metal waterFull; r <= 0 = shadeShadow, M3.3).
static half shadeShadowSoft(depth2d_array<float> map, sampler cmp, constant ShadeFrame &f, float3 p, half3 n, float r, float2 pixel,
                            float contact = 0.0) {
	if (f.flags.z == 0 || shadeDev(f, SHADE_DEV_NO_SHADOW)) return half(1.0);
	float3 L = f.lightDirWorld.xyz;
	float nl = dot(float3(n), L);
	if (nl <= 0.0) return half(1.0);
	float tanT = clamp(sqrt(max(1.0 - nl * nl, 0.0)) / max(nl, 0.02), 0.0, 12.0);
	float3 dir = float3(n) * 0.75 + L * (0.5 + 0.75 * tanT);
	float turn = shadeNoise(pixel, f.flags2.x);
	// the far cascade only: its texels are ~4x the near one's, so a disc of a block or two spans a few texels (cache-friendly;
	// the near cascade's detail is what the softening removes anyway). Points it doesn't cover keep shadeShadow.
	float m1;
	float far = shadeShadowCascadeDisc(map, cmp, 1u, f.shadowViewProj[1], p, dir * f.cascadeSplits.w, r, turn, m1, contact, L);
	if (m1 >= 1.0) return shadeShadow(map, cmp, f, p, n, false);
	return half(mix(far, 1.0, smoothstep(0.85, 1.0, m1)));
}

#endif
