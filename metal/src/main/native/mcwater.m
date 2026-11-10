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
//       buffer(23)   ShadeWaterParams (144 bytes, setFragmentBytes): this frame's water sprite rectangles and state; its
//                    state.x is 1 only after this frame's capture, so shaders never trust last frame's copies.
//       texture(29)  (2026-11-06, water.metal SHADE_WATER_RHIST; only while its code is compiled in: params.rhist.w > 0) the
//                    reflection's own history last frame wrote (RGBA16F, the world target's size), texture(30) this frame's
//                    (written by the water's fragments: ShaderWrite). The two swap roles once per frame (mc_water_params).
//     Slots: the bible reserves texture(17-19) for pass-local inputs (17 is M1's sky LUT); buffer 23 is free in every
//     pipeline that binds shade globals (far terrain's own pipelines use 22-28 but rebind shade after drawing).
// Manual retain/release (the dylib builds with -fno-objc-arc), like the other files.
#import "mcmetal.h"

int mc_shade_bind_render(id<MTLRenderCommandEncoder> r); // mcshade.m: the shade globals (ShadeFrame at buffer(16)) on an encoder of our own

typedef struct {
	float still[4];  // atlas uv rectangle (u0, v0, u1, v1) of minecraft:block/water_still
	float flow[4];   // the same for minecraft:block/water_flow
	float state[4];  // x copies valid this frame (0/1), y water surface height above the eye (camera-relative y, under water), z wetness, w 0
	float tune[4];   // x wave strength, y SSR max distance (blocks), z reflection strength, w caustic strength
	float swell[4];  // (2026-11-02, water round 1) the swell: strength, masking k, crest glow, Fresnel share
	float swell2[4]; // x open-water map's outer-ring mean (< 0: no map), y reserved, z calm, w ripple
	float swell3[4]; // x the swell's share in the mirrored images' direction, y the glint's glitter, zw reserved
	float rhist[4];  // (2026-11-06) the reflection history: x weight (0 = off), y last frame's valid (set here), z this frame's tag (here), w box (> 0: compiled in)
	float mirror[4]; // (2026-11-06) x the ripple-aware mirror normal's strength, yzw reserved
} WaterParams;

typedef struct {
	id<MTLTexture> color, depth;            // the copies (recreated when the attachments' size or format change)
	id<MTLTexture> dummyColor, dummyDepth;  // bound until the first capture
	id<MTLTexture> waves;                   // the baked wave field (RGBA16F 512^2 or 1024^2 by preset, mipmapped), rendered by ShadeWater.bake
	id<MTLTexture> detail;                  // M2.1: the fine-ripple layer (same format, the waves baked faster), texture(22)
	int detailBaked;                        // detail was rendered this frame (else texture(22) falls back to waves)
	id<MTLTexture> hz, dummyHz;             // the SSR march's half-size nearest depth (R32F reversed-Z), made after each copy
	id<MTLRenderPipelineState> hzPso;       // water.metal shade_water_hz_fs (set by ShadeWater; no coarse depth without it)
	// (1.2.7 candidate 8, SHADE_SSR_HIER) the exact march's depth pyramid instead: one RGBA32F texture (nearest and farthest reversed-Z
	// and the highest world y per 16x16 and per 128x128 pixel block of the depth copy; layout: water.metal ShadeSsrPyrBuild), bound at
	// texture(21) in hz's place. pyrTop: the 128-pixel blocks' own small target (they are made from the 16-pixel ones, then copied in).
	id<MTLTexture> pyr, pyrTop;
	id<MTLRenderPipelineState> pyrPso, pyr2Pso; // water.metal shade_water_pyr_fs / shade_water_pyr2_fs (set by ShadeWater in that mode)
	WaterParams params;
	int captures;
	// (2026-11-06, SHADE_WATER_RHIST) the reflection history's ping-pong pair (made at the first capture with params.rhist.x > 0,
	// remade when the world target's size changes), which one this frame writes, and whether a capture (= water drawing with it)
	// happened this frame / last frame. dummyRh: a 1x1 writable stand-in for texture(30) before the pair exists.
	id<MTLTexture> rh[2], dummyRh;
	int rhCur, rhCaptured;
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
		td.pixelFormat = MTLPixelFormatRGBA16Float;
		td.storageMode = MTLStorageModePrivate;
		td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
		s->dummyRh = [ctx->device newTextureWithDescriptor:td];
		s->dummyRh.label = @"mcopt shade water: no reflection history";
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
	[s->pyr release];
	[s->pyrTop release];
	[s->pyrPso release];
	[s->pyr2Pso release];
	[s->rh[0] release];
	[s->rh[1] release];
	[s->dummyRh release];
	free(s);
}

// This frame's parameters (36 floats: still, flow, state, tune, swell, swell2, swell3, rhist, mirror); state.x (copies valid) is cleared until the
// capture. Called once per frame, before anything draws: the reflection history's pair swaps roles here (rhist.y: what is now last
// frame's was written by a capture last frame; rhist.z: the tag this frame's texels get, the opposite of last frame's).
void mc_water_params(WaterState *s, const float *p) {
	memcpy(&s->params, p, sizeof(WaterParams));
	s->params.state[0] = 0.0f;
	s->rhCur ^= 1;
	s->params.rhist[1] = s->rhCaptured && s->rh[0] && s->rh[1] ? 1.0f : 0.0f;
	s->params.rhist[2] = s->rhCur ? 1.0f : -1.0f;
	s->rhCaptured = 0;
}

// (2026-11-06) the reflection history's pair at the world target's size (ShaderRead | ShaderWrite, private; not compressible, which
// the fragment writes rule out anyway); 1 when it was (re)made: nothing in it is last frame's then.
static int rhistTargets(Ctx *ctx, WaterState *s, NSUInteger w, NSUInteger h) {
	if (s->rh[0] && s->rh[1] && s->rh[0].width == w && s->rh[0].height == h) return 0;
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:w height:h mipmapped:NO];
	td.storageMode = MTLStorageModePrivate;
	td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget; // (RenderTarget: the clear when new)
	for (int i = 0; i < 2; i++) {
		[s->rh[i] release];
		s->rh[i] = [ctx->device newTextureWithDescriptor:td];
		s->rh[i].label = i ? @"mcopt shade water: reflection history B" : @"mcopt shade water: reflection history A";
	}
	return 1;
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
	[r setFragmentTexture:valid && s->pyr && s->pyrPso && s->pyr2Pso ? s->pyr : valid && s->hz && s->hzPso ? s->hz : s->dummyHz atIndex:21];
	[r setFragmentBytes:&s->params length:sizeof(WaterParams) atIndex:23];
	if (s->params.rhist[3] > 0.0f) { // (2026-11-06) the reflection history's code is compiled in (SHADE_WATER_RHIST)
		int have = s->rh[0] && s->rh[1];
		[r setFragmentTexture:have ? s->rh[s->rhCur ^ 1] : s->dummyColor atIndex:29];
		[r setFragmentTexture:have ? s->rh[s->rhCur] : s->dummyRh atIndex:30];
	}
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
		if (s->pyrPso && s->pyr2Pso) {
			// (candidate 8) the exact march's pyramid: the 16-pixel blocks from the depth attachment, the 128-pixel blocks from those
			// (into their own small target, copied into its region). The regions' spare texels (one past the rendered rect; the
			// 128-pixel blocks also one before it) repeat the rect's edge: the march's 2x2 gathers stay inside what this frame wrote
			NSUInteger bw = (depth.width + 15) / 16 + 1, bh = (depth.height + 15) / 16 + 1;
			NSUInteger tw = (depth.width + 127) / 128 + 2, th = (depth.height + 127) / 128 + 2;
			NSUInteger pw = MAX(bw, tw), ph = bh + th;
			if (!s->pyr || s->pyr.width != pw || s->pyr.height != ph) {
				[s->pyr release];
				[s->pyrTop release];
				MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:pw height:ph mipmapped:NO];
				td.storageMode = MTLStorageModePrivate;
				td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
				s->pyr = [enc->ctx->device newTextureWithDescriptor:td];
				s->pyr.label = @"mcopt shade water: depth pyramid";
				td.width = tw;
				td.height = th;
				s->pyrTop = [enc->ctx->device newTextureWithDescriptor:td];
				s->pyrTop.label = @"mcopt shade water: depth pyramid, 128-pixel blocks";
			}
			NSUInteger vw = (cw + 15) / 16 + 1, vh = (ch + 15) / 16 + 1;       // the 16-pixel blocks written this frame
			NSUInteger uw = (cw + 127) / 128 + 2, uh = (ch + 127) / 128 + 2;   // the 128-pixel ones
			for (int level = 0; level < 2; level++) {
				MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
				rp.colorAttachments[0].texture = level ? s->pyrTop : s->pyr;
				rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
				rp.colorAttachments[0].storeAction = MTLStoreActionStore;
				id<MTLRenderCommandEncoder> r = [cb renderCommandEncoderWithDescriptor:rp];
				r.label = level ? @"mcopt shade water: depth pyramid 128" : @"mcopt shade water: depth pyramid 16";
				[r setRenderPipelineState:level ? s->pyr2Pso : s->pyrPso];
				if (level) [r setFragmentTexture:s->pyr atIndex:0];
				else {
					mc_shade_bind_render(r); // ShadeFrame at buffer(16): the heights
					[r setFragmentTexture:depth atIndex:0];
				}
				int32_t u[8] = {level ? 8 : 16, 0, 0, level ? -1 : 0, (int32_t) (level ? vw - 1 : cw), (int32_t) (level ? vh - 1 : ch), 0, 0};
				NSUInteger w = level ? uw : vw, h = level ? uh : vh;
				[r setViewport:(MTLViewport) {0, 0, (double) w, (double) h, 0, 1}];
				[r setScissorRect:(MTLScissorRect) {0, 0, w, h}];
				[r setFragmentBytes:u length:sizeof(u) atIndex:0];
				[r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
				[r endEncoding];
			}
			id<MTLBlitCommandEncoder> pb = [cb blitCommandEncoder];
			pb.label = @"mcopt shade water: depth pyramid 128 into place";
			[pb copyFromTexture:s->pyrTop sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(uw, uh, 1)
				toTexture:s->pyr destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, bh, 0)];
			[pb endEncoding];
		} else if (s->hzPso) {
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
		// (2026-11-06) the reflection history: its pair at the attachment's size (the water writes at its fragment's pixel), cleared
		// when new (tag 0: no texel of it passes for last frame's)
		if (s->params.rhist[0] > 0.0f && s->params.rhist[3] > 0.0f) {
			if (rhistTargets(enc->ctx, s, color.width, color.height)) {
				s->params.rhist[1] = 0.0f;
				for (int i = 0; i < 2; i++) {
					if (!s->rh[i]) continue;
					MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
					rp.colorAttachments[0].texture = s->rh[i];
					rp.colorAttachments[0].loadAction = MTLLoadActionClear;
					rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
					rp.colorAttachments[0].storeAction = MTLStoreActionStore;
					id<MTLRenderCommandEncoder> c = [cb renderCommandEncoderWithDescriptor:rp];
					c.label = @"mcopt shade water: reflection history clear";
					[c endEncoding];
				}
			}
			if (!s->rh[0] || !s->rh[1]) s->params.rhist[1] = 0.0f;
			s->rhCaptured = s->rh[0] && s->rh[1];
		}
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

// (candidate 8) the exact march's depth pyramid pipelines (water.metal shade_water_pyr_fs / _pyr2_fs into RGBA32Float); retained. With it set the
// capture makes the pyramid instead of the coarse depth.
void mc_water_set_pyr(WaterState *s, id<MTLRenderPipelineState> pso, id<MTLRenderPipelineState> pso2) {
	[pso retain];
	[pso2 retain];
	[s->pyrPso release];
	[s->pyr2Pso release];
	s->pyrPso = pso;
	s->pyr2Pso = pso2;
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
