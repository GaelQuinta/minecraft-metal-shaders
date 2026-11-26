// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// M3.3 (dims): the aurora at reduced resolution (mcopt.metal.shade.dims.ShadeAurora, mcopt.shade.aurora.half). One
// full-screen pass into an RGBA16F texture a fraction of the output size, before the world pass: each texel takes
// shadeAurora (shade_dims.metal, M3.2's function unchanged) for its direction in this frame's jittered view, the same
// rays the sky pass derives its directions from (sky.vs.metal: shadeViewRay of uv * 2 - 1). The sky pass then reads it with
// one bilinear tap at the pixel's screen position (shadeAuroraTex). Pre-exposure radiance, like the sky it is added to.
// Source order: ShadeRender.prelude() + shade_post.metal (shade_fs_vs) + this file.

fragment half4 shade_aurora_pass(ShadeFsOut in [[stage_in]], constant ShadeFrame &f [[buffer(16)]], constant ShadeLook &L [[buffer(17)]],
                                 constant ShadeResources &sr [[buffer(19)]]) {
	float3 dir = normalize(shadeViewRay(in.uv * 2.0 - 1.0, f.invViewProj));
	// (2.0.1 fix) the texel's footprint in the aurora shell's plane (dir.xz / dy, dy clamped like shadeAurora), taken here in
	// uniform control flow so the derivatives are defined: shadeAurora band-limits the curtains and rays with it
	float2 q = dir.xz / max(dir.y, 0.05);
	float qfw = max(max(length(dfdx(q)), length(dfdy(q))), 1e-6);
	return half4(half3(shadeAurora(dir, f, L, sr.milkyWay, in.position.xy, qfw)), 1.0h);
}
