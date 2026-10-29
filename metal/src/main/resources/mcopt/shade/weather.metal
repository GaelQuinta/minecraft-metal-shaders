// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// Rain and snow (minecraft:pipeline/weather), applied to the result of vanilla's generated fragment shader (ShadeMsl.weather
// patches the call in): in the overworld the streaks become grey-white, about as bright as the sky behind them (plus a
// little sun), through the same exposure and tone curve, and more transparent; vanilla's look elsewhere.
// M3 weather (SHADE_WEATHER): the streaks scatter light from the surrounding sky, with restrained directional highlights,
// the sun's forward glow, torch light from vanilla's lightmap, the lightning
// flash, and fade a little in light rain; the vertex stage (shadeRainSlant, ShadeMsl.weatherVertex) leans them with the wind.
#ifndef MCOPT_SHADE_WEATHER
#define MCOPT_SHADE_WEATHER
static float4 shadeWeather(float4 c, constant ShadeFrame &f, constant ShadeLook &L, constant ShadeGpu &g) {
	if (f.flags.x != SHADE_DIM_OVERWORLD || f.fogColor.a > 0.5) return float4(shadeVanillaOut(c.rgb, L), c.a);
	float l = shadeLuma(c.rgb);
	// drops scatter the overcast sky's light toward the eye (and a little sun, forward): at about the sky's own radiance, so
	// streaks read slightly brighter than the clouds behind them, never as dark bars
	float3 light = f.ambientSky.rgb * 1.15 + f.sunColor.rgb * 0.35;
	float3 lit = shadeOut(light * (0.8 + 0.35 * l) * float3(0.97, 0.99, 1.0), f, shadeExposure(f, g));
	return float4(lit, c.a * 0.55);
}

#ifdef SHADE_WEATHER
// the budget gates (SHADE_DEV_WX_SUN_GATE, RIPPLE_GATE, LITE_RAIN): always on with SHADE_WX_LITE, else per dev bit
#ifndef SHADE_WX_BUDGET
#ifdef SHADE_WX_LITE
#define SHADE_WX_BUDGET(f, bit) true
#else
#define SHADE_WX_BUDGET(f, bit) shadeDev(f, bit)
#endif
#endif

// pixel: the fragment position ([[position]]); lut: the sky-view LUT. c: vanilla's result (texture x vertex colour x lightmap x
// fog), whose luminance carries the lightmap (torches near the streak) and the texture's streak shape.
static float4 shadeWeather3(float4 c, float4 pixel, constant ShadeFrame &f, constant ShadeLook &L, constant ShadeGpu &g, texture2d<half> lut,
                            sampler lutS) {
	if (f.flags.x != SHADE_DIM_OVERWORLD || f.fogColor.a > 0.5) return float4(shadeVanillaOut(c.rgb, L), c.a);
	if (shadeDev(f, SHADE_DEV_WX_PLAIN_RAIN)) return shadeWeather(c, f, L, g);
	if (c.a < 0.004) return float4(0.0); // the rain texture is mostly clear: no lighting for the empty texels between streaks
	// the view direction (GL row order: the pixel row counts from the bottom of the view) and the distance (reversed Z)
	float2 ndc = float2(pixel.x * f.screen.z * 2.0 - 1.0, pixel.y * f.screen.w * 2.0 - 1.0);
	float3 v = normalize(shadeViewRay(ndc, f.invViewProj));
	float dist = f.proj[3][2] / max(pixel.z + f.proj[2][2], 1e-7);
	float l = shadeLuma(c.rgb);
	float snowK = saturate(L.wind.w);
	float3 skyMean = f.ambientSky.rgb;
	// (SHADE_DEV_WX_LITE_RAIN: the overcast sky's mean light a little raised instead of the LUT in the streak's direction)
	float3 sky = SHADE_WX_BUDGET(f, SHADE_DEV_WX_LITE_RAIN) ? skyMean * 1.12 : shadeSkyLookup(float3(v.x, max(v.y, 0.02), v.z), lut, lutS, f);
	// forward scattering of the sun through the drops (a soft glow toward the sun), and the flash
	float mu = dot(v, f.lightDirWorld.xyz);
	float3 sun = f.sunColor.rgb * (0.03 + 0.45 * shadeHG(mu, 0.6));
	float3 snowLight = max(sky, skyMean) * 1.02 + sun;
	// Drops scatter the surrounding light. A bright horizon LUT texel should not turn an entire rain column into a lamp.
	float skyLimit = 1.5 * shadeLuma(skyMean) + 0.02;
	float3 rainSky = sky * min(1.0, skyLimit / max(shadeLuma(sky), 1e-5));
	float3 rainLight = mix(skyMean, rainSky, 0.35) * 0.85
		+ f.sunColor.rgb * (0.02 + 0.18 * shadeHG(mu, 0.45));
	float3 light = mix(rainLight, snowLight, snowK) + float3(0.78, 0.86, 1.0) * (L.flash.w * 0.6);
	// torch light: vanilla's lightmap brightens the streak beyond what the sky alone gives (warm, like the block light); tuned
	// for the blue rain texture (mean luma 0.4): the white snow texture would trip it in daylight, so not while it snows
	float torch = max(l - 0.75, 0.0) * 2.0 * (1.0 - snowK);
	light += f.ambientBlock.rgb * torch * 0.6;
	float3 lit = shadeOut(light * (0.9 + 0.2 * l) * float3(0.97, 0.99, 1.0), f, shadeExposure(f, g));
	// thin and glassy: mostly transparent, and the columns right in front of the eye (a block wide on screen) fade out
	// (snow: flakes are opaque, about M2.1's 0.55; L.wet.w is 0 while it snows)
	// Keep the texture's feathered edges faint; distant overlapping streaks dissolve instead of forming a white curtain.
	float rainAlpha = (0.14 + 0.16 * saturate(L.wet.w)) * (0.65 + 0.35 * saturate(c.a))
		* smoothstep(0.7, 3.5, dist) * mix(1.0, 0.45, smoothstep(12.0, 32.0, dist));
	float a = c.a * mix(rainAlpha, 0.55 * smoothstep(1.2, 4.5, dist), snowK);
	return float4(lit, a);
}
#endif

// Rain leans with the wind (ShadeLook.wind: xy direction, z slant in blocks per block of fall): higher up a column is further
// upwind. Positions are camera-relative, so the streaks at eye height stay where vanilla put them.
static inline float3 shadeRainSlant(float3 p, constant ShadeLook &L) {
	float k = L.wind.z;
	if (k <= 0.0) return p;
	return float3(p.x - L.wind.x * k * p.y, p.y, p.z - L.wind.y * k * p.y);
}
#endif
