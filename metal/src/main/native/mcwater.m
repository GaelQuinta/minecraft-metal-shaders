// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// Native shading's water module (-Dmcopt.shade=true, mcopt.shade.water; Java side mcopt.metal.shade.water.ShadeWater,
// shader side resources/mcopt/shade/water.metal). Two jobs:
//
//  1. The scene copy (bible hook H6): when the main pass switches to Sodium's translucent terrain, the open render encoder
//     is ended (its attachments stored), colour attachment 0 and the depth attachment are copied with one blit encoder
//     into textures of the same format and size (private, ShaderRead only, so they stay losslessly compressed), and the
//     pass is reopened on the same attachments with their contents loaded back. The water draws that follow read what
//     is behind and around them (refraction, absorption, foam, screen-space reflections) from the copies.
//  2. The bindings, fragment stage only, on every render encoder native shading binds (ShadeBindings.bind):
//       texture(18)  sceneCopy  texture2d<half>  the copy of colour attachment 0 (a 1x1 dummy until the first capture)
//       texture(19)  depthCopy  depth2d<float>   the copy of the depth attachment (a 1x1 dummy until the first capture)
//       buffer(23)   ShadeWaterParams (112 bytes, setFragmentBytes): this frame's water sprite rectangles and state; its
//                    state.x is 1 only after this frame's capture, so shaders never trust last frame's copies.
//     Slots: the bible reserves texture(17-19) for pass-local inputs (17 is M1's sky LUT); buffer 23 is free in every
//     pipeline that binds shade globals (far terrain's own pipelines use 22-28 but rebind shade after drawing).
// Manual retain/release (the dylib builds with -fno-objc-arc), like the other files.
#import "mcmetal.h"

typedef struct {
	float still[4];  // atlas uv rectangle (u0, v0, u1, v1) of minecraft:block/water_still
	float flow[4];   // the same for minecraft:block/water_flow
	float state[4];  // x copies valid this frame (0/1), y water surface height above the eye (camera-relative y, under water), z wetness, w 0
	float tune[4];   // x wave strength, y SSR max distance (blocks), z reflection strength, w caustic strength
	float swell[4];  // (2026-11-02, water round 1) the swell: strength, masking k, crest glow, Fresnel share
	float swell2[4]; // x open-water map's outer-ring mean (< 0: no map), y reserved, z calm, w ripple
	float swell3[4]; // x the swell's share in the mirrored images' direction, y the glint's glitter, zw reserved
} WaterParams;

typedef struct {
	id<MTLTexture> color, depth;            // the copies (recreated when the attachments' size or format change)
	id<MTLTexture> dummyColor, dummyDepth;  // bound until the first capture
	id<MTLTexture> waves;                   // the baked wave field (RGBA16F 512^2 or 1024^2 by preset, mipmapped), rendered by ShadeWater.bake
	id<MTLTexture> detail;                  // M2.1: the fine-ripple layer (same format, the waves baked faster), texture(22)
	int detailBaked;                        // detail was rendered this frame (else texture(22) falls back to waves)
	id<MTLTexture> hz, dummyHz;             // the SSR march's half-size nearest depth (R32F reversed-Z), made after each copy
	id<MTLRenderPipelineState> hzPso;       // water.metal shade_water_hz_fs (set by ShadeWater; no coarse depth without it)
	WaterParams params;
	int captures;
} WaterState;

// The one state mc_water_bind binds from (set by mc_water_new).
static WaterState *water;

WaterState *mc_water_new(Ctx *ctx) {
	@autoreleasepool {
		WaterState *s = calloc(1, sizeof(WaterState));
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
		td.storageMode = MTLStorageModePrivate;
		td.usage = MTLTextureUsageShaderRead;
		s->dummyColor = [ctx->device newTextureWithDescriptor:td];
		s->dummyColor.label = @"mcopt shade water: no scene copy";
		td.pixelFormat = MTLPixelFormatDepth32Float;
		s->dummyDepth = [ctx->device newTextureWithDescriptor:td];
		s->dummyDepth.label = @"mcopt shade water: no depth copy";
		td.pixelFormat = MTLPixelFormatR32Float;
		td.storageMode = MTLStorageModeShared;
		s->dummyHz = [ctx->device newTextureWithDescriptor:td];
		float zero = 0.0f; // reads as sky: SSR finds nothing
		[s->dummyHz replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&zero bytesPerRow:4];
		s->dummyHz.label = @"mcopt shade water: no coarse depth";
		water = s;
		return s;
	}
}

void mc_water_free(WaterState *s) {
	if (!s) return;
	if (water == s) water = NULL;
	[s->color release];
	[s->depth release];
	[s->dummyColor release];
	[s->dummyDepth release];
	[s->waves release];
	[s->detail release];
	[s->hz release];
	[s->dummyHz release];
	[s->hzPso release];
	free(s);
}

// This frame's parameters (28 floats: still, flow, state, tune, swell, swell2, swell3); state.x (copies valid) is cleared until the capture.
void mc_water_params(WaterState *s, const float *p) {
	memcpy(&s->params, p, sizeof(WaterParams));
	s->params.state[0] = 0.0f;
}

static id<MTLTexture> copyTarget(Ctx *ctx, id<MTLTexture> old, id<MTLTexture> like, NSString *label) {
	if (old && old.width == like.width && old.height == like.height && old.pixelFormat == like.pixelFormat) return old;
	[old release];
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:like.pixelFormat width:like.width height:like.height mipmapped:NO];
	td.storageMode = MTLStorageModePrivate;
	td.usage = MTLTextureUsageShaderRead;  // no ShaderWrite / PixelFormatView: keeps lossless compression
	id<MTLTexture> t = [ctx->device newTextureWithDescriptor:td];
	t.label = label;
	return t;
}

// Binds the copies (or the dummies) and the parameters into enc's open render encoder, fragment stage.
void mc_water_bind(Enc *enc) {
	id<MTLRenderCommandEncoder> r = enc->render;
	WaterState *s = water;
	if (!r || !s) return;
	int valid = s->params.state[0] > 0.5f;
	[r setFragmentTexture:valid ? s->color : s->dummyColor atIndex:18];
	[r setFragmentTexture:valid ? s->depth : s->dummyDepth atIndex:19];
	[r setFragmentTexture:s->params.state[3] > 0.5f ? s->waves : s->dummyColor atIndex:20];
	[r setFragmentTexture:s->params.state[3] > 0.5f ? (s->detailBaked && s->detail ? s->detail : s->waves) : s->dummyColor atIndex:22];
	[r setFragmentTexture:valid && s->hz && s->hzPso ? s->hz : s->dummyHz atIndex:21];
	[r setFragmentBytes:&s->params length:sizeof(WaterParams) atIndex:23];
}

// The scene copy at the switch to translucent terrain: ends the open render encoder (stored), copies colour attachment 0
// and the depth attachment, reopens the pass (loaded back) and binds the copies. Returns 1 when it did (the caller must
// then restore its encoder state: pipeline, uniforms, scissor, vertex buffers, shade globals), 0 when there was nothing
// to copy (no open encoder, no depth or colour attachment, or a memoryless one), with the encoder untouched.
int mc_water_capture(Enc *enc, WaterState *s) {
	if (!enc->render || !enc->depth || enc->colorCount < 1 || !enc->colors[0]) return 0;
	id<MTLTexture> color = enc->colors[0], depth = enc->depth;
	if (color.storageMode == MTLStorageModeMemoryless || depth.storageMode == MTLStorageModeMemoryless || color.sampleCount != 1 || depth.sampleCount != 1) return 0;
	@autoreleasepool {
		s->color = copyTarget(enc->ctx, s->color, color, @"mcopt shade water: scene copy");
		s->depth = copyTarget(enc->ctx, s->depth, depth, @"mcopt shade water: depth copy");
		if (!s->color || !s->depth) return 0;
		id<MTLCommandBuffer> cb = mc_frame_cmd(enc);  // ends the render encoder: every live attachment is stored
		// only the pass's viewport: under TAAU dynamic resolution the world draws into a sub-rect of fixed-size targets
		// (the shaders map NDC to that sub-rect, SHADE_WATER_SUBRECT), so the rest is stale and never read
		NSUInteger cw = enc->width > 0 ? MIN((NSUInteger) enc->width, MIN(color.width, depth.width)) : MIN(color.width, depth.width);
		NSUInteger ch = enc->height > 0 ? MIN((NSUInteger) enc->height, MIN(color.height, depth.height)) : MIN(color.height, depth.height);
		bool whole = cw == color.width && ch == color.height && cw == depth.width && ch == depth.height;
		// (FT2.8, audit idx 61) the coarse depth first, from the attachment itself (the same texels as the copy): it then depends
		// only on the ended world encoder and can run alongside the ~0.37 ms copy below instead of waiting for all of it
		if (s->hzPso) {
			NSUInteger hw = (depth.width + 1) / 2, hh = (depth.height + 1) / 2;
			if (!s->hz || s->hz.width != hw || s->hz.height != hh) {
				[s->hz release];
				MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:hw height:hh mipmapped:NO];
				td.storageMode = MTLStorageModePrivate;
				td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
				s->hz = [enc->ctx->device newTextureWithDescriptor:td];
				s->hz.label = @"mcopt shade water: coarse depth";
			}
			MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
			rp.colorAttachments[0].texture = s->hz;
			rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
			rp.colorAttachments[0].storeAction = MTLStoreActionStore;
			id<MTLRenderCommandEncoder> r = [cb renderCommandEncoderWithDescriptor:rp];
			r.label = @"mcopt shade water: coarse depth";
			if (!whole) [r setViewport:(MTLViewport) {0, 0, (double) ((cw + 1) / 2), (double) ((ch + 1) / 2), 0, 1}];
			[r setRenderPipelineState:s->hzPso];
			[r setFragmentTexture:depth atIndex:0];
			[r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
			[r endEncoding];
		}
		id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
		b.label = @"mcopt shade water: scene copy";
		if (whole) {
			[b copyFromTexture:color toTexture:s->color];
			[b copyFromTexture:depth toTexture:s->depth];
		} else {
			[b copyFromTexture:color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(cw, ch, 1)
				toTexture:s->color destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
			[b copyFromTexture:depth sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(cw, ch, 1)
				toTexture:s->depth destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
		}
		[b endEncoding];
		mc_reopen_why = "after water copy";
		mc_render_reopen(enc);
	}
	s->params.state[0] = 1.0f;
	s->captures++;
	mc_water_bind(enc);
	return 1;
}

// The coarse-depth pipeline (a ShadeRender pipeline handle: water.metal shade_water_hz_fs into R32Float); retained.
void mc_water_set_hz(WaterState *s, id<MTLRenderPipelineState> pso) {
	[pso retain];
	[s->hzPso release];
	s->hzPso = pso;
}

// The baked wave field's texture (size^2, made on first use): ShadeWater.bake renders mip 0 with a ShadeRender pass, then calls
// mc_water_waves_done. RenderTarget|ShaderRead, private, losslessly compressed.
static id<MTLTexture> wavesTexture(Ctx *ctx, int size, NSString *label) {
	if (size < 64) size = 64;
	@autoreleasepool {
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:size height:size mipmapped:YES];
		td.storageMode = MTLStorageModePrivate;
		td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
		id<MTLTexture> t = [ctx->device newTextureWithDescriptor:td];
		t.label = label;
		return t;
	}
}

id<MTLTexture> mc_water_waves(Ctx *ctx, WaterState *s, int size) {
	if (!s->waves) s->waves = wavesTexture(ctx, size, @"mcopt shade water: baked waves");
	return s->waves;
}

// M2.1: the fine-ripple layer's texture (same size and format), rendered right after the long waves' (ShadeWater.bake);
// mc_water_waves_done makes its mips too. Bound at texture(22) when it was rendered this frame.
id<MTLTexture> mc_water_waves_detail(Ctx *ctx, WaterState *s, int size) {
	if (!s->detail) s->detail = wavesTexture(ctx, size, @"mcopt shade water: baked ripples");
	s->detailBaked = 1;
	return s->detail;
}

// After the bake pass wrote mip 0: the mip chain (one blit), and the shaders may sample it this frame (state.w).
void mc_water_waves_done(Enc *enc, WaterState *s) {
	if (!s->waves) return;
	@autoreleasepool {
		id<MTLCommandBuffer> cb = mc_frame_cmd(enc);
		id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
		b.label = @"mcopt shade water: wave mips";
		[b generateMipmapsForTexture:s->waves];
		if (s->detailBaked && s->detail) [b generateMipmapsForTexture:s->detail];
		[b endEncoding];
	}
	s->params.state[3] = 1.0f;
}

id<MTLTexture> mc_water_scene_copy(WaterState *s) { return s->color; }
id<MTLTexture> mc_water_depth_copy(WaterState *s) { return s->depth; }
