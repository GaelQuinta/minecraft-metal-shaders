// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// (1.2.8, issue #61, Gael 2026-11-14) Coloured block light: placed lights whose colour is far from a torch's light their
// surroundings in it, near and far: soul fire blue, redstone torches red, copper torches and lanterns green, nether portals,
// crying obsidian and amethyst purple, the green and the pink froglight, sea lanterns and conduits cyan. Vanilla's block light
// is one number per block, without a colour; this keeps a colour for it in a volume around the camera.
//
// The technique is the one the voxel shader packs use (Photon's light propagation volume, Complementary's coloured lighting:
// a volume of blocks around the player, light spread from block to block each frame, faded out at the volume's edge), here
// with vanilla's own rule instead of their averaging, per colour channel: a block's level is the brightest of its six
// neighbours' less one (more through blocks that dim light, none through opaque ones), or its own emission. Levels are kept
// per channel in log2 units (a light's colour is its channels' offsets below its brightest one), so a light keeps its exact
// colour all the way out, two lights mix where they meet, and the brightest channel is vanilla's level, which the shading
// compares with the surface's own block light (mcopt.metal.shade.light.ColorLights has the CPU side).
//
// Two cascades, each a toroidal 3D texture (RGBA8: a channel's level as (level + 16) x 8, 0 = no light; a cell's texel is its world
// coordinates modulo the texture's size, so the windows follow the camera without moving data): fine, a cell per block over 16 x 8 x
// 16 sections around the camera (256 x 128 x 256 blocks); coarse, a cell per 4^3 blocks over 12 x 4 x 12 coarse sections of 64 blocks
// (768 x 256 x 768), for what is past the fine one up to the render distance. The shading reads each with one hardware-filtered
// sample. Only the 16^3-cell slots near a coloured light are spread (ColorLights: the rest hold no colour). An opaque cell holds the
// light on its faces (its brightest open neighbour's, less one) but passes none on, so the filtering next to a wall keeps the light.
#ifndef MCOPT_SHADE_COLORLIGHT
#define MCOPT_SHADE_COLORLIGHT
#include <metal_stdlib>
using namespace metal;

// Byte layout = ColorLights.header (80 bytes).
struct ShadeColorLights {
	int4 fineMin;    // xyz the fine window's first section (world section coordinates), w 1 = on
	int4 fineDim;    // xyz sections per axis, w 0
	int4 coarseMin;  // xyz the coarse window's first coarse section (64-block units), w the coarse slots' first cell (fine slots x 4096)
	int4 coarseDim;  // xyz coarse sections per axis, w 0
	float4 tune;     // x strength (mcopt.shade.coloredLights.strength; 0 = off), y glow (.glow), z the edge band (blocks), w 0
};

#define SHADE_CL_BIAS 16.0
#define SHADE_CL_DARK_BELOW ((SHADE_CL_BIAS - 3.0) * 8.0) // a cell whose brightest channel is under level -3 holds no light

// Per class (ColorLights.CLASSES): xyz the channels' offsets below the brightest (log2 of the light's colour relative to a torch's,
// over its brightest channel), w the least level it spreads at (a redstone torch is level 7 in vanilla: in this shading's block
// light curve that lit almost nothing, so its red would never show; amethyst 5 likewise).
constant float4 SHADE_CL_CLASS[8] = {
	float4( 0.000,  0.000,  0.000,  0.0), // 0 torch-coloured (everything else that emits light)
	float4(-4.131, -1.679,  0.000,  0.0), // 1 soul fire (0.19, 1.04, 3.33)
	float4( 0.000, -2.000, -1.690, 11.0), // 2 redstone (1.0, 0.25, 0.31)
	float4(-1.826,  0.000, -0.210,  0.0), // 3 copper (0.375, 1.33, 1.15)
	float4(-2.874, -2.563,  0.000,  8.0), // 4 purple: nether portal, crying obsidian, amethyst (0.54, 0.67, 3.96)
	float4(-2.136, -0.234,  0.000,  0.0), // 5 verdant froglight (0.38, 1.42, 1.67)
	float4(-2.164, -1.883,  0.000,  0.0), // 6 pearlescent froglight (0.79, 0.96, 3.54)
	float4(-2.987, -1.572,  0.000,  0.0), // 7 sea lantern, conduit (0.42, 1.12, 3.33)
};
// A torch-relative colour's luminance (the torch colour ShadeFrame.blockLight 2.4, 1.2, 0.48 times Rec. 709, normalised): 1 for a
// torch, so a coloured light is as bright as a torch of its level, only its colour differs.
constant float3 SHADE_CL_LUMW = float3(0.3636, 0.6117, 0.0247);


static inline int3 shadeClMod(int3 a, int3 m) {
	int3 r = a % m;
	return select(r, r + m, r < 0);
}

// The slot of world section (or coarse section) s in the window (min mn, size dm), -1 outside it.
static inline int shadeClSlot(int3 s, int4 mn, int4 dm) {
	int3 r = s - mn.xyz;
	if (any(r < 0) || any(r >= dm.xyz)) return -1;
	int3 m = shadeClMod(s, dm.xyz);
	return (m.y * dm.z + m.z) * dm.x + m.x;
}

static inline uint shadeClCell(int3 v) { // within its section: the palette's order (y, z, x)
	int3 l = v & 15;
	return uint((l.y * 16 + l.z) * 16 + l.x);
}

#ifdef SHADE_CL_KERNELS
// One step of the spread for the cells of the listed slots (threadgroups of 8^3: eight a slot). list: per entry the slot, bit 31
// set for a coarse one. A cell reads its six neighbours as they are now (other threads may have written theirs this step: either
// value is a valid one, and the spread only converges faster), across slots, nothing from outside the window or from an opaque cell.
kernel void shade_cl_flood(uint3 tg3 [[threadgroup_position_in_grid]], uint3 tid [[thread_position_in_threadgroup]],
                           constant ShadeColorLights &H [[buffer(0)]], device const uchar *ids [[buffer(2)]], device const uint *list [[buffer(3)]],
                           texture3d<float, access::read_write> fineTex [[texture(0)]], texture3d<float, access::read_write> coarseTex [[texture(1)]]) {
	uint tg = tg3.x, entry = list[tg >> 3], brick = tg & 7u;
	bool coarse = (entry >> 31) != 0u;
	int slot = int(entry & 0x7FFFFFFFu);
	int4 mn = coarse ? H.coarseMin : H.fineMin, dm = coarse ? H.coarseDim : H.fineDim;
	uint base = coarse ? uint(H.coarseMin.w) : 0u;
	int3 size = dm.xyz * 16;
	int3 sc = int3(slot % dm.x, slot / (dm.x * dm.z), (slot / dm.x) % dm.z);
	int3 ws = mn.xyz + shadeClMod(sc - mn.xyz, dm.xyz); // the world section this slot holds
	int3 l = int3(brick & 1u, (brick >> 1) & 1u, brick >> 2) * 8 + int3(tid);
	int3 v = ws * 16 + l;
	uint id = ids[base + uint(slot) * 4096u + shadeClCell(v)];
	uint3 m = uint3(0u);
	const int3 dirs[6] = {int3(1, 0, 0), int3(-1, 0, 0), int3(0, 1, 0), int3(0, -1, 0), int3(0, 0, 1), int3(0, 0, -1)};
	uint own = base + uint(slot) * 4096u;
	int3 tex0 = sc * 16;
	for (int k = 0; k < 6; k++) {
		int3 nl = l + dirs[k];
		uint3 t;
		uint nid;
		if (all(nl >= 0) && all(nl < 16)) { // the same slot (most neighbours): no division
			nid = ids[own + uint((nl.y * 16 + nl.z) * 16 + nl.x)];
			t = uint3(tex0 + nl);
		} else {
			int3 nv = v + dirs[k];
			int ns = shadeClSlot(nv >> 4, mn, dm);
			if (ns < 0) continue;
			nid = ids[base + uint(ns) * 4096u + shadeClCell(nv)];
			t = uint3(shadeClMod(nv, size));
		}
		if (nid == 15u) continue;
		float4 c = coarse ? coarseTex.read(t) : fineTex.read(t);
		m = max(m, uint3(rint(c.rgb * 255.0)));
	}
	uint step = (id >= 1u && id <= 14u ? id : 1u) * (coarse ? 4u : 1u) * 8u;
	uint3 r = select(m - step, uint3(0u), m < step);
	if (id >= 16u) {
		float4 c = SHADE_CL_CLASS[min((id - 16u) >> 4, 7u)];
		float lv = max(float((id - 16u) & 15u), c.w);
		r = max(r, uint3(clamp((lv + SHADE_CL_BIAS + c.xyz) * 8.0, 0.0, 255.0)));
	}
	if (float(max(r.x, max(r.y, r.z))) < SHADE_CL_DARK_BELOW) r = uint3(0u);
	uint3 t = uint3(sc * 16 + l);
	float4 o = float4(float3(r) * (1.0 / 255.0), 0.0);
	if (coarse) coarseTex.write(o, t);
	else fineTex.write(o, t);
}

// The listed slots emptied (a slot that now holds another world section, or no longer near a coloured light).
kernel void shade_cl_clear(uint3 tg3 [[threadgroup_position_in_grid]], uint3 tid [[thread_position_in_threadgroup]],
                           constant ShadeColorLights &H [[buffer(0)]], device const uint *list [[buffer(3)]],
                           texture3d<float, access::read_write> fineTex [[texture(0)]], texture3d<float, access::read_write> coarseTex [[texture(1)]]) {
	uint tg = tg3.x, entry = list[tg >> 3], brick = tg & 7u;
	bool coarse = (entry >> 31) != 0u;
	int slot = int(entry & 0x7FFFFFFFu);
	int4 dm = coarse ? H.coarseDim : H.fineDim;
	int3 sc = int3(slot % dm.x, slot / (dm.x * dm.z), (slot / dm.x) % dm.z);
	uint3 t = uint3(sc * 16 + int3(brick & 1u, (brick >> 1) & 1u, brick >> 2) * 8 + int3(tid));
	if (coarse) coarseTex.write(float4(0.0), t);
	else fineTex.write(float4(0.0), t);
}
#else

// The cascade's light at a point, one hardware-filtered sample: xyz the light per channel (2^(level - 15): 1 at level 15), 0 where
// none. qi + qf: the point in blocks (qi integer); the texel is the cell's world coordinates modulo the texture (toroidal: the
// sampler repeats).
static float3 shadeClSample(constant ShadeColorLights &H, texture3d<float> tex, int3 qi, float3 qf, bool coarse) {
	int4 dm = coarse ? H.coarseDim : H.fineDim;
	int3 sz = dm.xyz * 16;
	// (2.0.1 opt) fine dims (16, 8, 16) * 16 = (256, 128, 256) are powers of two: bitwise mask avoids 3 integer divisions per vertex
	float3 c = coarse ? float3(shadeClMod(qi >> 2, sz)) + (float3(qi & 3) + qf) * 0.25 : float3(qi & (sz - 1)) + qf;
	constexpr sampler s(filter::linear, address::repeat, coord::normalized);
	float3 lv = tex.sample(s, c / float3(sz)).rgb * (255.0 / 8.0) - SHADE_CL_BIAS;
	return max(lv.x, max(lv.y, lv.z)) < -2.5 ? float3(0.0) : exp2(lv - 15.0);
}

// How far point qi (blocks) is inside a window (blocks per section unit u), in blocks: < 0 outside.
static inline float shadeClInside(int3 qi, int4 mn, int4 dm, int u) {
	int3 lo = qi - mn.xyz * u, hi = (mn.xyz + dm.xyz) * u - 1 - qi;
	return float(min(min(min(lo.x, lo.z), min(hi.x, hi.z)), min(lo.y, hi.y)));
}

// What the coloured light adds to a surface's block-light term, in the units shadeLit2's torch term uses (times albedo x
// ShadeFrame.ambientBlock), at point qi + qf (blocks, qi integer: own terrain's vertex stage evaluates it at each vertex, as vanilla
// lights its vertices; shade_own_fs adds it per pixel), block its vanilla block light 0..1. Where the light reaching it is a torch's,
// nothing; where it is a coloured light's, the torch term turned into that colour at the same brightness, and for the lights that
// spread brighter than vanilla (SHADE_CL_CLASS w) the extra light in their colour. Away from such lights, or where vanilla's light
// is clearly brighter than the volume's (a light it doesn't know yet), nothing.
static float3 shadeColorLightAt(constant ShadeColorLights &H, texture3d<float> fineTex, texture3d<float> coarseTex, int3 qi, float3 qf,
                                float block) {
	if (H.fineMin.w == 0 || H.tune.x <= 0.0 || block < 0.02) return float3(0.0);
	float band = max(H.tune.z, 1.0);
	float wFine = saturate(shadeClInside(qi, H.fineMin, H.fineDim, 16) / band);
	float3 L = 0.0;
	if (wFine > 0.0 && H.fineDim.w != 0) L = shadeClSample(H, fineTex, qi, qf, false) * wFine;
	if (wFine < 1.0 && H.coarseDim.w != 0) {
		float wCoarse = saturate(shadeClInside(qi, H.coarseMin, H.coarseDim, 64) / (2.0 * band));
		if (wCoarse > 0.0) L += shadeClSample(H, coarseTex, qi, qf, true) * (wCoarse * (1.0 - wFine));
	}
	float lmax = max(L.x, max(L.y, L.z));
	if (lmax <= 1e-6) return float3(0.0);
	float level = 15.0 + log2(lmax);
	float3 hue = L / lmax;
	float3 tint = hue / max(dot(hue, SHADE_CL_LUMW), 1e-3);
	float bl = block * 15.0;
	// how surely the surface's own block light is these lights': full while their level is within one of it, none once vanilla's is
	// three brighter (a torch the volume doesn't hold yet: a section not read, past the window)
	float w = saturate(1.0 - (bl - level - 1.0) * 0.5) * H.tune.x;
	float b7 = block * block * block;
	b7 = b7 * b7 * block;
	float F = (2.2 * b7 + 0.55 * pow(max(block, 1e-3), 2.4)) * (1.0 / 2.75);
	float3 add = F * w * (tint - 1.0);
	if (level > bl + 0.25 && H.tune.y > 0.0) {
		// the boosted lights' own light past vanilla's (only a coloured one: a torch-coloured light has no saturation)
		float c = saturate(level / 15.0), c7 = c * c * c;
		c7 = c7 * c7 * c;
		float Fc = (2.2 * c7 + 0.55 * pow(max(c, 1e-3), 2.4)) * (1.0 / 2.75);
		float sat = saturate((1.0 - min(hue.x, min(hue.y, hue.z))) * 2.0);
		add += max(Fc - F, 0.0) * sat * H.tune.y * H.tune.x * tint;
	}
	return add;
}
#endif
#endif
