// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// minecraft:pipeline/celestial (fragment), 1.2.9 (issue #67). Everything but Minecraft's kept sun is vanilla's position_tex
// fragment exactly (texture, discard where its alpha is 0, x ColorModulator): the moon, the End flash, other dimensions. The
// sun quad, while the player keeps Minecraft's / the resource pack's sun (mcopt.shade.sun=false; ShadeLook.user4.y = its gain,
// mcopt.shade.sunTexGain), is drawn like the sky's own disc: the texture (linearized) x the sun's colour x that gain, which
// follows the day (warm and dim low down, gone with the light at night) and fades in rain as the disc does (x (1 - 0.9 rain)),
// exposed into the HDR target, and times the volumetric clouds' transmittance toward the pixel (shadeCloudsScreen, as
// sky.fs.metal composites the clouds over its disc). The blend is additive (OVERLAY), so the clouds drawn already stay in front.
struct CelestialOut { float4 gl_Position [[position]]; float2 texCoord0 [[user(locn0)]]; float sunK [[user(locn1)]]; float3 dir [[user(locn2)]]; };

fragment float4 main0(CelestialOut in [[stage_in]], constant ShadeFrame& sf [[buffer(16)]], constant ShadeLook& sl [[buffer(17)]],
                      constant ShadeGpu& sg [[buffer(18)]], constant ShadeResources& sr [[buffer(19)]],
                      constant DynamicTransforms& dt [[buffer(MCOPT_SLOT_DynamicTransforms)]],
                      texture2d<float> Sampler0 [[texture(MCOPT_SLOT_Sampler0)]], sampler Sampler0Smplr [[sampler(MCOPT_SLOT_Sampler0)]])
{
	float4 color = Sampler0.sample(Sampler0Smplr, in.texCoord0);
	if (color.a == 0.0) discard_fragment();
	if (in.sunK < 0.5 || sl.user4.y < 0.5) return color * dt.ColorModulator;
#ifdef MCOPT_HDR
	float3 dir = normalize(in.dir);
	float3 sunLight = sf.lightDirWorld.w > 0.5 ? sf.sunColor.rgb : float3(0.0);
	float above = smoothstep(-0.03, 0.01, dir.y);
	float3 tex = pow(max(color.rgb * dt.ColorModulator.rgb, 0.0), float3(2.2));
	float3 rad = sunLight * (sl.user4.y * (1.0 - 0.9 * sf.weather.x)) * tex * above;
	float4 clouds = shadeCloudDev(sl, SHADE_CLOUD_DEV_NO_SKY) ? float4(0.0, 0.0, 0.0, 1.0) : shadeCloudsScreen(dir, sl, sr.cloudScreen);
	return float4(shadeOut(rad * clouds.a, sf, shadeExposure(sf, sg)), color.a * dt.ColorModulator.a);
#else
	return color * dt.ColorModulator;
#endif
}
