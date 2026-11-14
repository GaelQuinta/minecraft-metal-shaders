// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// Native shading's dynamic lights (-Dmcopt.shade=true, mcopt.shade.dynLights; Java side mcopt.metal.shade.light.DynLights,
// shader side resources/mcopt/shade/dynlight.metal and dynlight_vis.metal):
//   - a ring of shared buffers with each frame's lights and light grid (ShadeDynLights, written by the CPU in place),
//   - the block occupancy around the camera (128^3 bits, kept by the CPU from chunk sections in its own memory and copied
//     into the next slot of a ring of shared buffers on the frames that compute visibility after it changed: a buffer the GPU
//     may still be reading is never written),
//   - the visibility volumes: a 3D R8 texture, 32 x 32 x (32 x slabs), one 32^3 slab per occluded light, computed once per
//     frame before the world passes (shade_dl_vis),
// bound on every render encoder native shading binds (ShadeBindings.bind), vertex and fragment stages:
//   buffer(24)  this frame's ShadeDynLights      texture(23)  the visibility volumes
//   texture(24), texture(25) (fragment only): the irradiance volume (rgb light, mean light direction) the terrain samples
// Both slots are unused by the game's pipelines (uniforms and samplers from 0, Sodium's 20-22/26, vertex buffers 27-30,
// water's 18-23); far terrain's own pipelines use 24 but rebind shade after drawing.
// Manual retain/release (the dylib builds with -fno-objc-arc), like the other files.
#import "mcmetal.h"
#include <stdio.h>

#define DL_RING_MAX 8
#define DL_FLOOD_WORDS 6728 // dynlight_vis.metal DL_FWORDS: 32 x 29 x 29 bytes

typedef struct {
	id<MTLBuffer> ring[DL_RING_MAX];
	int ringSize, slot;
	id<MTLBuffer> occupancy[DL_RING_MAX];
	int occSlot, occBytes;
	id<MTLTexture> vis;
	int slabs;
	id<MTLComputePipelineState> visPso, irrPso;
	id<MTLComputePipelineState> floodPso, floodOutPso; // (FT2.11) shade_dl_flood(_out): the volumes as light spreads through air; nil = rays only
	id<MTLBuffer> ways;                               // (FT2.11) the flood's ways, DL_FLOOD_WORDS per slab
	id<MTLTexture> irr, dir;  // the irradiance volume: rgb light, mean light direction (one voxel per block)
} DlState;

// The one state mc_dl_bind binds from (set by mc_dl_new), or the fallback: when the module failed to start, the shaders
// still declare its slots, so a zeroed light buffer (no lights: every shader leaves at its first test) and 1-voxel volumes
// are bound instead of nothing (mc_dl_fallback).
static DlState *dl, *fb;

// source: dynlight.metal (with SHADE_DL_KERNELS) + dynlight_vis.metal; irrW x irrH x irrD: the irradiance volume; bytes: the ShadeDynLights size; ring: slots (> frames in flight); slabs: visibility volumes
// (<= 64); occBytes: the occupancy buffer's size. NULL with the compiler's message in err.
DlState *mc_dl_new(Ctx *ctx, const char *source, int bytes, int ring, int slabs, int occBytes, int irrW, int irrH, int irrD, char *err, int errCap) {
	@autoreleasepool {
		MTLCompileOptions *o = [[MTLCompileOptions new] autorelease];
		o.languageVersion = MTLLanguageVersion3_0;
		o.mathMode = mc_math();
		NSError *e = nil;
		id<MTLLibrary> lib = [[ctx->device newLibraryWithSource:[NSString stringWithUTF8String:source] options:o error:&e] autorelease];
		if (!lib) {
			snprintf(err, errCap, "%s", e.localizedDescription.UTF8String);
			return NULL;
		}
		id<MTLFunction> fn = [[lib newFunctionWithName:@"shade_dl_vis"] autorelease];
		id<MTLComputePipelineState> pso = fn ? [ctx->device newComputePipelineStateWithFunction:fn error:&e] : nil;
		if (!pso) {
			snprintf(err, errCap, "shade_dl_vis: %s", e ? e.localizedDescription.UTF8String : "missing");
			return NULL;
		}
		id<MTLFunction> fi = [[lib newFunctionWithName:@"shade_dl_irr"] autorelease];
		id<MTLComputePipelineState> ipso = fi ? [ctx->device newComputePipelineStateWithFunction:fi error:&e] : nil;
		if (!ipso) {
			[pso release];
			snprintf(err, errCap, "shade_dl_irr: %s", e ? e.localizedDescription.UTF8String : "missing");
			return NULL;
		}
		DlState *s = calloc(1, sizeof(DlState));
		s->visPso = pso;
		s->irrPso = ipso;
		// (FT2.11) the flood fill (27 KB of threadgroup memory per volume): without it the volumes stay rays (mc_dl_has_flood tells Java)
		id<MTLFunction> ff = [[lib newFunctionWithName:@"shade_dl_flood"] autorelease];
		id<MTLFunction> fo = [[lib newFunctionWithName:@"shade_dl_flood_out"] autorelease];
		e = nil;
		s->floodPso = ff ? [ctx->device newComputePipelineStateWithFunction:ff error:&e] : nil;
		s->floodOutPso = s->floodPso && fo ? [ctx->device newComputePipelineStateWithFunction:fo error:&e] : nil;
		if (!s->floodOutPso) {
			fprintf(stderr, "[mcopt] shade: dynamic light flood fill unavailable (rays only): %s\n", e ? e.localizedDescription.UTF8String : "missing");
			[s->floodPso release];
			s->floodPso = nil;
		}
		s->ringSize = ring < 2 ? 2 : ring > DL_RING_MAX ? DL_RING_MAX : ring;
		for (int i = 0; i < s->ringSize; i++) {
			s->ring[i] = [ctx->device newBufferWithLength:bytes options:MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined];
			memset(s->ring[i].contents, 0, bytes);
			s->ring[i].label = @"mcopt shade: dynamic lights";
		}
		s->occBytes = occBytes;
		for (int i = 0; i < s->ringSize; i++) {
			s->occupancy[i] = [ctx->device newBufferWithLength:occBytes options:MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined];
			memset(s->occupancy[i].contents, 0, occBytes);
			s->occupancy[i].label = @"mcopt shade: block occupancy";
		}
		s->slabs = slabs < 1 ? 1 : slabs > 64 ? 64 : slabs;
		if (s->floodPso) {
			s->ways = [ctx->device newBufferWithLength:(NSUInteger) s->slabs * DL_FLOOD_WORDS * 4 options:MTLResourceStorageModePrivate];
			s->ways.label = @"mcopt shade: dynamic light flood";
		}
		MTLTextureDescriptor *td = [[MTLTextureDescriptor new] autorelease];
		td.textureType = MTLTextureType3D;
		td.pixelFormat = MTLPixelFormatR8Unorm;
		td.width = 32;
		td.height = 32;
		td.depth = 32 * s->slabs;
		td.storageMode = MTLStorageModePrivate;
		td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
		s->vis = [ctx->device newTextureWithDescriptor:td];
		s->vis.label = @"mcopt shade: dynamic light visibility";
		td.width = irrW;
		td.height = irrH;
		td.depth = irrD;
		td.pixelFormat = MTLPixelFormatRGBA16Float;
		s->irr = [ctx->device newTextureWithDescriptor:td];
		s->irr.label = @"mcopt shade: dynamic light irradiance";
		s->dir = [ctx->device newTextureWithDescriptor:td];
		s->dir.label = @"mcopt shade: dynamic light direction";
		dl = s;
		return s;
	}
}

void mc_dl_free(DlState *s) {
	if (!s) return;
	if (dl == s) dl = NULL;
	for (int i = 0; i < s->ringSize; i++) {
		[s->ring[i] release];
		[s->occupancy[i] release];
	}
	[s->vis release];
	[s->visPso release];
	[s->irrPso release];
	[s->floodPso release];
	[s->floodOutPso release];
	[s->ways release];
	[s->irr release];
	[s->dir release];
	free(s);
}

// CPU address of ring slot i (0..ring-1).
void *mc_dl_contents(DlState *s, int i) {
	return i >= 0 && i < s->ringSize ? s->ring[i].contents : NULL;
}

// The CPU's block occupancy (occBytes at src) into the next occupancy slot, which mc_dl_vis reads from now on. Called only on
// frames that compute visibility after the occupancy changed; the ring (more slots than frames in flight) keeps the slot a
// frame still on the GPU reads untouched.
void mc_dl_occupancy(DlState *s, const void *src) {
	if (!s || !src) return;
	s->occSlot = (s->occSlot + 1) % s->ringSize;
	memcpy(s->occupancy[s->occSlot].contents, src, (size_t) s->occBytes);
}

// The fallback bindings (see fb): a zeroed ShadeDynLights of bytes and 1-voxel volumes. 0 on failure.
int mc_dl_fallback(Ctx *ctx, int bytes) {
	if (fb) return 1;
	@autoreleasepool {
		DlState *s = calloc(1, sizeof(DlState));
		s->ringSize = 1;
		s->ring[0] = [ctx->device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
		if (!s->ring[0]) {
			free(s);
			return 0;
		}
		memset(s->ring[0].contents, 0, bytes);
		s->ring[0].label = @"mcopt shade: dynamic lights (off)";
		MTLTextureDescriptor *td = [[MTLTextureDescriptor new] autorelease];
		td.textureType = MTLTextureType3D;
		td.pixelFormat = MTLPixelFormatR8Unorm;
		td.width = td.height = td.depth = 1;
		td.storageMode = MTLStorageModePrivate;
		td.usage = MTLTextureUsageShaderRead;
		s->vis = [ctx->device newTextureWithDescriptor:td];
		td.pixelFormat = MTLPixelFormatRGBA16Float;
		s->irr = [ctx->device newTextureWithDescriptor:td];
		s->dir = [ctx->device newTextureWithDescriptor:td];
		fb = s;
		return 1;
	}
}

// The ring slot encoders bind from now on.
void mc_dl_slot(DlState *s, int slot) {
	if (slot >= 0 && slot < s->ringSize) s->slot = slot;
}

// Binds this frame's lights and the visibility volumes into enc's open render encoder (vertex and fragment stages).
void mc_dl_bind(Enc *enc) {
	id<MTLRenderCommandEncoder> r = enc->render;
	DlState *s = dl ? dl : fb;
	if (!r || !s) return;
	id<MTLBuffer> b = s->ring[s->slot];
	[r setVertexBuffer:b offset:0 atIndex:24];
	[r setFragmentBuffer:b offset:0 atIndex:24];
	[r setVertexTexture:s->vis atIndex:23];
	[r setFragmentTexture:s->vis atIndex:23];
	[r setFragmentTexture:s->irr atIndex:24];
	[r setFragmentTexture:s->dir atIndex:25];
}

// (FT2.11) 1 when the flood fill's pipeline exists (DlVisParams.info.y = 1 is honoured), else 0.
int mc_dl_has_flood(DlState *s) {
	return s && s->floodPso && s->floodOutPso && s->ways ? 1 : 0;
}

// The visibility volumes for this frame (params: DlVisParams, volumes of them), on the frame's command buffer before the
// world passes (ends any open render encoder; the backend reopens its own). (FT2.11) DlVisParams.info.y = 1: as light spreads
// through air (shade_dl_flood, one threadgroup per volume), else along rays (shade_dl_vis).
void mc_dl_vis(Enc *enc, DlState *s, const void *params, int length, int volumes) {
	if (!s || volumes <= 0) return;
	if (volumes > s->slabs) volumes = s->slabs;
	bool flood = length >= 8 && ((const uint32_t *) params)[1] == 1u && mc_dl_has_flood(s);
	@autoreleasepool {
		id<MTLCommandBuffer> cb = mc_frame_cmd(enc);
		id<MTLComputeCommandEncoder> c = [cb computeCommandEncoder];
		c.label = flood ? @"mcopt shade: dynamic light flood" : @"mcopt shade: dynamic light visibility";
		[c setComputePipelineState:flood ? s->floodPso : s->visPso];
		[c setBytes:params length:length atIndex:0];
		[c setBuffer:s->occupancy[s->occSlot] offset:0 atIndex:1];
		[c setTexture:s->vis atIndex:0];
		if (flood) {
			// the ways (a threadgroup per volume), then the slabs from them (a thread per voxel; the serial encoder orders the two)
			NSUInteger n = s->floodPso.maxTotalThreadsPerThreadgroup;
			n = n >= 1024 ? 1024 : n / 32 * 32;
			if (n < 32) n = 32;
			[c setBuffer:s->ways offset:0 atIndex:2];
			[c dispatchThreadgroups:MTLSizeMake((NSUInteger) volumes, 1, 1) threadsPerThreadgroup:MTLSizeMake(n, 1, 1)];
			[c setComputePipelineState:s->floodOutPso];
			[c dispatchThreads:MTLSizeMake(32, 32, 32 * volumes) threadsPerThreadgroup:MTLSizeMake(8, 8, 4)];
		} else {
			[c dispatchThreads:MTLSizeMake(32, 32, 32 * volumes) threadsPerThreadgroup:MTLSizeMake(8, 8, 4)];
		}
		[c endEncoding];
	}
}

// The irradiance volume from this frame's lights (ring slot s->slot) and the visibility slabs, after mc_dl_vis: only the
// box of voxels (x0, y0, z0) + (w, h, d) is rewritten (the lights' reach, united with last frame's box by the caller so what
// was lit there is cleared; everything outside stays 0).
void mc_dl_irr(Enc *enc, DlState *s, int x0, int y0, int z0, int w, int h, int d) {
	if (!s || w <= 0 || h <= 0 || d <= 0) return;
	@autoreleasepool {
		id<MTLCommandBuffer> cb = mc_frame_cmd(enc);
		id<MTLComputeCommandEncoder> c = [cb computeCommandEncoder];
		c.label = @"mcopt shade: dynamic light irradiance";
		[c setComputePipelineState:s->irrPso];
		[c setBuffer:s->ring[s->slot] offset:0 atIndex:0];
		[c setTexture:s->vis atIndex:0];
		[c setTexture:s->irr atIndex:1];
		[c setTexture:s->dir atIndex:2];
		uint32_t box[4] = {(uint32_t) x0, (uint32_t) y0, (uint32_t) z0, 0};
		[c setBytes:box length:sizeof(box) atIndex:1];
		[c dispatchThreads:MTLSizeMake(w, h, d) threadsPerThreadgroup:MTLSizeMake(8, 8, 4)];
		[c endEncoding];
	}
}
