// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// minecraft:pipeline/sky (fragment): the atmosphere (sky-view LUT) with M2's procedural sun disc and aureole, moon with
// phases, stars and the Milky Way (shadeSkyRadiance2), through shadeFinish2 (pre-exposed radiance in the HDR target,
// M1's tone curve in RGBA8), and the game's fog colour under water and the like. The dark disc stays black, fading into the
// sky's horizon the way vanilla fades it into its fog. Outside the overworld (not expected: other skyboxes don't use this
// pipeline) it is vanilla's sky.
struct SkyOut {
	float4 position [[position]];
	float3 dir [[user(locn0)]];
	float3 vanilla [[user(locn1)]];
};

static float3 shadeSkyPixel(float3 dir, texture2d<half> skyLut, sampler skyLutSmplr, constant ShadeFrame &sf, constant ShadeLook &sl, float ex,
                            constant ShadeResources &sr, float2 pixel) {
#ifdef MCOPT_HDR
	// (2.0.1 opt) sample volumetric clouds first: opaque cloud cores (clouds.a <= 0.001) skip sky LUT, sun/moon/stars/Milky Way and aurora completely (DH-safe)
	float4 clouds = shadeCloudDev(sl, SHADE_CLOUD_DEV_NO_SKY) ? float4(0.0, 0.0, 0.0, 1.0) : shadeCloudsScreen(dir, sl, sr.cloudScreen);
	float3 sky = clouds.rgb;
	if (clouds.a > 0.001) {
		float pixelAngle = 2.0 * atan(1.0 / max(abs(sf.proj[1][1]), 1e-3)) * sf.screen.w;
		float3 back = shadeSkyRadiance2(dir, skyLut, skyLutSmplr, sf, sl, sr.milkyWay, pixelAngle);
		// M3 aurora (shade_dims.metal; ShadeLook.night.z, 0 unless it shows tonight): emission over the night sky
		if (sl.night.z > 0.002) {
			if (shadeDimsBit(sl, SHADE_DIMS_AURORA_TEX)) back += shadeAuroraTex(dir, sf, sr, pixel);
#ifndef SHADE_LEAN_NOAURORA // M3.1: the sky's lean variant while no aurora shows (ShadeLean)
			else back += shadeAurora(dir, sf, sl, sr.milkyWay, pixel);
#endif
		}
		sky += back * clouds.a;
	}
	// (FT2.7, audit idx 74/8) the flash after the clouds: added before them, the storm's cloud deck hid it (the ground flashed, the
	// sky stayed dark); the deck glows most (here, not in the clouds' pass: their history would smear the ~0.15 s afterglow)
	if (sl.flash.w > 0.0) {
		float3 fl = float3(0.78, 0.86, 1.0) * (sl.flash.w * 0.35 * (0.35 + 0.65 * pow(saturate(dot(dir, sl.flash.xyz) * 0.5 + 0.5), 3.0)));
		sky += fl * (sl.clouds0.w > 0.5 ? 0.4 + 0.6 * (1.0 - clouds.a) : 1.0);
	}
#else
	float pixelAngle = 2.0 * atan(1.0 / max(abs(sf.proj[1][1]), 1e-3)) * sf.screen.w;
	float3 sky = shadeSkyRadiance2(dir, skyLut, skyLutSmplr, sf, sl, sr.milkyWay, pixelAngle);
	if (sl.night.z > 0.002) {
		if (shadeDimsBit(sl, SHADE_DIMS_AURORA_TEX)) sky += shadeAuroraTex(dir, sf, sr, pixel);
#ifndef SHADE_LEAN_NOAURORA
		else sky += shadeAurora(dir, sf, sl, sr.milkyWay, pixel);
#endif
	}
	if (sl.flash.w > 0.0)
		sky += float3(0.78, 0.86, 1.0) * (sl.flash.w * 0.35 * (0.35 + 0.65 * pow(saturate(dot(dir, sl.flash.xyz) * 0.5 + 0.5), 3.0)));
#endif
	float vanillaSky = dir.y <= 0.0 ? 1.0 : saturate(min(16.0 / max(dir.y, 1e-3), 512.0) / max(sf.fogSky.x, 1.0));
	return shadeFinish2(sky, vanillaSky, sf, sl, ex);
}

fragment float4 main0(SkyOut in [[stage_in]], constant ShadeFrame& sf [[buffer(16)]], constant ShadeLook& sl [[buffer(17)]],
                      constant ShadeGpu& sg [[buffer(18)]], constant ShadeResources& sr [[buffer(19)]],
                      texture2d<half> skyLut [[texture(17)]], sampler skyLutSmplr [[sampler(13)]],
                      constant Fog& fog [[buffer(MCOPT_SLOT_Fog)]], constant DynamicTransforms& dt [[buffer(MCOPT_SLOT_DynamicTransforms)]])
{
	float ex = shadeExposure(sf, sg);
	if (sf.flags.x != SHADE_DIM_OVERWORLD) {
		float a = saturate(in.vanilla.y / max(fog.FogSkyEnd, 1e-3));
		float b = in.vanilla.z >= fog.FogSkyEnd ? 1.0 : 0.0;
		float fogValue = max(a, b);
		return float4(mix(shadeVanillaOut(dt.ColorModulator.rgb, sl), shadeVanillaOut(fog.FogColor.rgb, sl), fogValue * fog.FogColor.a),
			dt.ColorModulator.a);
	}
	// (2.0.1 opt) single shadeSkyPixel call site: halves sky fragment shader code size and register pressure
	float3 sky = shadeSkyPixel(normalize(in.dir), skyLut, skyLutSmplr, sf, sl, ex, sr, in.position.xy);
	if (in.vanilla.x > 0.5) {
		float a = saturate(in.vanilla.y / max(fog.FogSkyEnd, 1e-3));
		float b = in.vanilla.z >= fog.FogSkyEnd ? 1.0 : 0.0;
		float fogValue = max(a, b);
		return float4(mix(shadeVanillaOut(dt.ColorModulator.rgb, sl), sky, fogValue), dt.ColorModulator.a);
	}
	return float4(sky, 1.0);
}
