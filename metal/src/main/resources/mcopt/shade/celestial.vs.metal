// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// minecraft:pipeline/celestial (vertex; vanilla's position_tex fragment is kept). The overworld sun's textured square is
// dropped (the sky draws a round sun with limb darkening), and the moon's too when the sky draws the procedural one (M2); the moon follows the tilted sun path; the End flash draws as vanilla. Bodies are told
// apart by size: SkyRenderer scales the sun's quad by 30, the moon's by 20 and the End flash's by 60 (the length of
// ModelViewMat's first column, rotations leaving it unchanged).
struct CelestialIn { float3 Position [[attribute(0)]]; float2 UV0 [[attribute(1)]]; };
struct CelestialOut { float4 gl_Position [[position]]; float2 texCoord0 [[user(locn0)]]; };

vertex CelestialOut main0(CelestialIn in [[stage_in]], constant ShadeFrame& sf [[buffer(16)]], constant ShadeLook& sl [[buffer(17)]],
                          constant DynamicTransforms& dt [[buffer(MCOPT_SLOT_DynamicTransforms)]], constant Projection& pr [[buffer(MCOPT_SLOT_Projection)]])
{
	CelestialOut out;
	out.texCoord0 = in.UV0;
	float size = length(dt.ModelViewMat[0].xyz);
	// the sun while the sky draws its own disc (1.2.9, issue #67: mcopt.shade.sun=false keeps Minecraft's / the resource pack's sun,
	// ShadeLook.user4.y), the moon too when the sky draws its own (M2 procedural moon)
	if (sf.flags.x == SHADE_DIM_OVERWORLD && ((abs(size - 30.0) < 1.0 && sl.user4.y < 0.5) || (abs(size - 20.0) < 1.0 && (sl.tier.y & SHADE_FEATURE_STARS) != 0))) {
		out.gl_Position = SHADE_DROPPED;
		return out;
	}
	float4 viewPos = dt.ModelViewMat * float4(in.Position, 1.0);
	if (sf.flags.x == SHADE_DIM_OVERWORLD && sf.sunPath.x != 0.0) {
		// the moon (and Minecraft's sun, when kept) follows the tilted sun path (mcopt.shade.sunTilt): to world, rotate about x, back to view
		float3x3 v = float3x3(sf.view[0].xyz, sf.view[1].xyz, sf.view[2].xyz);
		float3 w = transpose(v) * viewPos.xyz;
		float s = sf.sunPath.x, c = sf.sunPath.y;
		w = float3(w.x, c * w.y - s * w.z, s * w.y + c * w.z);
		viewPos.xyz = v * w;
	}
	out.gl_Position = pr.ProjMat * viewPos;
	out.gl_Position.y = -out.gl_Position.y;
	return out;
}
