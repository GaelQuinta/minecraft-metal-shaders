// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// Volumetric light (mcopt.metal.shade.vl, resources/mcopt/shade/vl.metal): the passes' pipelines, their targets and the
// per-frame encoding. Everything is encoded on the frame's command buffer (mc_frame_cmd ends whatever the backend had
// open; its next pass opens a new encoder), between the level and the hand:
//   canopy (compute, 64 threads) -> march (VL res) -> temporal (VL res, history ping-pong) -> composite (full res, onto the
//   game's main colour with programmable blending: load, store).
// VL-resolution targets are private RenderTarget|ShaderRead RGBA16Float (compressible; lossy with -Dmcopt.shade.vl.lossy).
// Manual retain/release (the dylib builds with -fno-objc-arc).
#import "mcmetal.h"

int mc_shade_bind_render(id<MTLRenderCommandEncoder> r);
int mc_shade_bind_compute(id<MTLComputeCommandEncoder> c);

typedef struct {
	id<MTLLibrary> lib;
	id<MTLRenderPipelineState> march, temporal, composite, temporalFold; // temporalFold: M2 fold (flag 16), MRT history + lightT
	id<MTLRenderPipelineState> veilDown, veilBlurH, veilBlurV;          // fold: the shafts' local contrast (VlParams.hp, vl.metal vlVeilR)
	id<MTLRenderPipelineState> radial;                                  // fold (FT2.3): the blur along the light's lines (vl_radial)
	MTLPixelFormat compositeFormat;
	int compositeHdr;
	id<MTLComputePipelineState> canopy;
	id<MTLComputePipelineState> shadeGridK;  // (godrays v3) the shade grid for the air mode (vl_shade_grid; HDR only, optional)
	id<MTLTexture> shadeGrid;                // its 3D R8 target (VL_GRID_X x Y x Z, vl.metal), made with the kernel
	id<MTLTexture> raw, hist[2], sky[2]; // sky: R8 sky masks (march output, read by the next frame's crepuscular taps)
	id<MTLTexture> lightT;               // fold: light (before exposure) + canopy mist transmittance, for ShadePost's final pass
	id<MTLTexture> veil[2];              // fold: the local mean of r at a quarter of the VL resolution (R16F; [0] = the result)
	int veilRan;                         // the veil passes ran last frame (else veil[0] is stale: the fold skips the contrast once)
	id<MTLTexture> lightR;               // fold (FT2.3): lightT blurred along the light's lines (what the final pass reads when it ran)
	int radialRan;                       // the radial pass ran this frame (mc_vl_outputs hands lightR out)
	int histOnly;                        // (FT2.8) the fold wrote no light + T this frame (T = 1): mc_vl_outputs hands the history out
	// (2026-11, VlParams.air8.z) the forest air dims the scene: the march's optical depth (R16F, its third target) and the fold's
	// filtered one (ping-pong with hist: its history)
	id<MTLTexture> od, odHist[2];
	int odRan;                           // the fold kept an od history last frame (else air8.z goes negative: none to read)
	int width, height, cur, lossy;
	id<MTLBuffer> state;  // VlState: the canopy factor (GPU-written, read by the march)
	// GPU timer (flag 8, -Dmcopt.shade.vl.gpuTimer): per-pass fragment start/end timestamps, a ring of 4 frames x 3 passes
	id<MTLCounterSampleBuffer> times;
	int timesTried, timeFrame;
	MTLTimestamp cpu0, gpu0;
	double timeSum[3];
	int timeCount;
	uint64_t timeLast[4];
} VlState;

#define VL_TIME_RING 4

static id<MTLRenderPipelineState> pso(id<MTLDevice> dev, id<MTLLibrary> lib, NSString *fragment, MTLPixelFormat format, int hdr,
	char *err, int errCap) {
	NSError *e = nil;
	MTLFunctionConstantValues *fc = [[MTLFunctionConstantValues new] autorelease];
	bool h = hdr != 0;
	[fc setConstantValue:&h type:MTLDataTypeBool atIndex:0];
	id<MTLFunction> fs = [lib newFunctionWithName:fragment constantValues:fc error:&e];
	if (!fs) {
		snprintf(err, errCap, "%s: %s", fragment.UTF8String, e.localizedDescription.UTF8String);
		return nil;
	}
	MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor new] autorelease];
	pd.label = fragment;
	pd.vertexFunction = [[lib newFunctionWithName:@"vl_vs"] autorelease];
	pd.fragmentFunction = [fs autorelease];
	pd.colorAttachments[0].pixelFormat = format;
	if ([fragment isEqualToString:@"vl_march"]) pd.colorAttachments[1].pixelFormat = MTLPixelFormatR8Unorm;
	if ([fragment isEqualToString:@"vl_temporal_fold"]) pd.colorAttachments[1].pixelFormat = MTLPixelFormatRGBA16Float;
	// (2026-11) the od of what dims the scene (VlParams.air8.z): the march's and the fold's filtered one
	if ([fragment isEqualToString:@"vl_march"] || [fragment isEqualToString:@"vl_temporal_fold"]) pd.colorAttachments[2].pixelFormat = MTLPixelFormatR16Float;
	if ([fragment hasPrefix:@"vl_veil_"]) pd.colorAttachments[0].pixelFormat = MTLPixelFormatR16Float;
	if ([fragment isEqualToString:@"vl_radial"]) pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
	if ([fragment isEqualToString:@"vl_composite_hdr"]) {
		pd.colorAttachments[0].blendingEnabled = YES;  // M2: scene * T (source alpha) + light, into the pre-exposed HDR scene
		pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
		pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorZero;
		pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
	}
	id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
	if (!p) snprintf(err, errCap, "%s pipeline: %s", fragment.UTF8String, e.localizedDescription.UTF8String);
	return p;
}

// Compiles the passes (source = ShadeMsl.prelude + vl.metal). flags: 1 lossy VL targets, 2 HDR (M2: the canopy kernel also
// writes ShadeGpu.scene.y, buffer 18). NULL with the message in err on failure.
VlState *mc_vl_new(Ctx *ctx, const char *source, int flags, char *err, int errCap) {
	int lossy = flags & 1, hdr = (flags & 2) != 0;
	@autoreleasepool {
		MTLCompileOptions *o = [[MTLCompileOptions new] autorelease];
		o.languageVersion = MTLLanguageVersion3_0;
		o.mathMode = mc_math();
		NSError *e = nil;
		id<MTLLibrary> lib = [ctx->device newLibraryWithSource:[NSString stringWithUTF8String:source] options:o error:&e];
		if (!lib) {
			snprintf(err, errCap, "%s", e.localizedDescription.UTF8String);
			return NULL;
		}
		VlState *s = calloc(1, sizeof(VlState));
		s->lib = lib;
		s->lossy = lossy;
		s->march = pso(ctx->device, lib, @"vl_march", MTLPixelFormatRGBA16Float, hdr, err, errCap);
		s->temporal = s->march ? pso(ctx->device, lib, @"vl_temporal", MTLPixelFormatRGBA16Float, hdr, err, errCap) : nil;
		if (hdr && s->temporal) {
			s->temporalFold = pso(ctx->device, lib, @"vl_temporal_fold", MTLPixelFormatRGBA16Float, hdr, err, errCap);
			// (optional: without them the fold just never applies the shafts' local contrast)
			char e2[256];
			s->veilDown = s->temporalFold ? pso(ctx->device, lib, @"vl_veil_down", MTLPixelFormatR16Float, hdr, e2, sizeof(e2)) : nil;
			s->veilBlurH = s->veilDown ? pso(ctx->device, lib, @"vl_veil_blur_h", MTLPixelFormatR16Float, hdr, e2, sizeof(e2)) : nil;
			s->veilBlurV = s->veilBlurH ? pso(ctx->device, lib, @"vl_veil_blur_v", MTLPixelFormatR16Float, hdr, e2, sizeof(e2)) : nil;
			s->radial = s->temporalFold ? pso(ctx->device, lib, @"vl_radial", MTLPixelFormatRGBA16Float, hdr, e2, sizeof(e2)) : nil;
			if (!s->temporalFold) {
				[s->march release];
				[s->temporal release];
				[lib release];
				free(s);
				return NULL;
			}
		}
		MTLFunctionConstantValues *fc = [[MTLFunctionConstantValues new] autorelease];
		bool h = hdr != 0;
		[fc setConstantValue:&h type:MTLDataTypeBool atIndex:0];
		id<MTLFunction> k = [[lib newFunctionWithName:@"vl_canopy" constantValues:fc error:&e] autorelease];
		s->canopy = k ? [ctx->device newComputePipelineStateWithFunction:k error:&e] : nil;
		if (hdr) {
			// (godrays v3, optional: without it the air mode has no forest air)
			NSError *e3 = nil;
			id<MTLFunction> g = [[lib newFunctionWithName:@"vl_shade_grid" constantValues:fc error:&e3] autorelease];
			s->shadeGridK = g ? [ctx->device newComputePipelineStateWithFunction:g error:&e3] : nil;
			if (s->shadeGridK) {
				MTLTextureDescriptor *td = [MTLTextureDescriptor new];
				td.textureType = MTLTextureType3D;
				td.pixelFormat = MTLPixelFormatR8Unorm;
				td.width = 64;  // VL_GRID_X
				td.height = 32; // VL_GRID_Y
				td.depth = 64;  // VL_GRID_Z
				td.storageMode = MTLStorageModePrivate;
				td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
				s->shadeGrid = [ctx->device newTextureWithDescriptor:td];
				[td release];
				s->shadeGrid.label = @"mcopt shade: VL shade grid";
			}
		}
		if (!s->march || !s->temporal || !s->canopy) {
			if (!s->canopy && s->march && s->temporal) snprintf(err, errCap, "vl_canopy: %s", e ? e.localizedDescription.UTF8String : "missing");
			[s->march release];
			[s->temporal release];
			[s->canopy release];
			[lib release];
			free(s);
			return NULL;
		}
		s->state = [ctx->device newBufferWithLength:16 options:MTLResourceStorageModeShared];
		memset(s->state.contents, 0, 16);
		s->state.label = @"mcopt shade: VL state";
		return s;
	}
}

void mc_vl_free(VlState *s) {
	if (!s) return;
	[s->lib release];
	[s->march release];
	[s->temporal release];
	[s->composite release];
	[s->temporalFold release];
	[s->veilDown release];
	[s->veilBlurH release];
	[s->veilBlurV release];
	[s->radial release];
	[s->lightR release];
	[s->canopy release];
	[s->shadeGridK release];
	[s->shadeGrid release];
	[s->raw release];
	[s->lightT release];
	[s->veil[0] release];
	[s->veil[1] release];
	[s->hist[0] release];
	[s->hist[1] release];
	[s->sky[0] release];
	[s->sky[1] release];
	[s->od release];
	[s->odHist[0] release];
	[s->odHist[1] release];
	[s->state release];
	[s->times release];
	free(s);
}

static void timesInit(VlState *s, id<MTLDevice> device) {
	s->timesTried = 1;
	if (![device supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) return;
	@autoreleasepool {
		for (id<MTLCounterSet> set in device.counterSets) {
			if (![set.name isEqualToString:MTLCommonCounterSetTimestamp]) continue;
			MTLCounterSampleBufferDescriptor *d = [[MTLCounterSampleBufferDescriptor new] autorelease];
			d.counterSet = set;
			d.storageMode = MTLStorageModeShared;
			d.sampleCount = VL_TIME_RING * 6;
			s->times = [device newCounterSampleBufferWithDescriptor:d error:nil];
			[device sampleTimestamps:&s->cpu0 gpuTimestamp:&s->gpu0];
			break;
		}
	}
}

// Adds ring slot r's three pass times (ms) to the sums once that frame completed (its samples are new and ordered).
static void timesCollect(VlState *s, id<MTLDevice> device, int r) {
	MTLTimestamp cpu1, gpu1;
	[device sampleTimestamps:&cpu1 gpuTimestamp:&gpu1];
	if (gpu1 <= s->gpu0 || cpu1 <= s->cpu0) return;
	double nsPerTick = (double) (cpu1 - s->cpu0) / (double) (gpu1 - s->gpu0);
	@autoreleasepool {
		NSData *data = [s->times resolveCounterRange:NSMakeRange((NSUInteger) (6 * r), 6)];
		if (data.length < 6 * sizeof(MTLCounterResultTimestamp)) return;
		const MTLCounterResultTimestamp *ts = data.bytes;
		if (ts[0].timestamp == MTLCounterErrorValue || ts[0].timestamp == 0 || ts[0].timestamp == s->timeLast[r]) return;
		for (int i = 0; i < 4; i++) if (ts[i].timestamp == MTLCounterErrorValue || ts[i].timestamp == 0) return;
		s->timeLast[r] = ts[0].timestamp;
		for (int p = 0; p < 3; p++) {
			uint64_t a = ts[2 * p].timestamp, b = ts[2 * p + 1].timestamp;
			if (a == MTLCounterErrorValue || b == MTLCounterErrorValue || a == 0) continue; // no composite pass (fold)
			if (b > a) s->timeSum[p] += (double) (b - a) * nsPerTick / 1e6;
		}
		s->timeCount++;
	}
}

// Average GPU ms of march, temporal and composite (fragment stage start to end) since the last call, and how many frames
// that covers (out[3]); zeros without -Dmcopt.shade.vl.gpuTimer or timestamp support.
void mc_vl_times(VlState *s, float *out) {
	int n = s->timeCount;
	for (int p = 0; p < 3; p++) {
		out[p] = n > 0 ? (float) (s->timeSum[p] / n) : 0.0f;
		s->timeSum[p] = 0;
	}
	out[3] = (float) n;
	s->timeCount = 0;
}

static id<MTLTexture> target(id<MTLDevice> dev, MTLPixelFormat format, int w, int h, int lossy, NSString *label) {
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
	td.storageMode = MTLStorageModePrivate;
	td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
	if (lossy) {
		if (@available(macOS 15.0, *)) td.compressionType = MTLTextureCompressionTypeLossy;
	}
	id<MTLTexture> t = [dev newTextureWithDescriptor:td];
	t.label = label;
	return t;
}

// (2026-11) out2: a third colour target, stored when store2 (else only in tile memory: the pipeline has it, nothing reads it);
// t3, t4: more inputs (the fold's od textures)
static void pass(id<MTLCommandBuffer> cb, id<MTLTexture> out, id<MTLTexture> out1, MTLLoadAction load, id<MTLRenderPipelineState> p,
	NSString *label, const void *params, int paramBytes, id<MTLBuffer> state, id<MTLTexture> t0, id<MTLTexture> t1,
	id<MTLCounterSampleBuffer> times, int sample, int liveW, int liveH, id<MTLTexture> t2, id<MTLTexture> out2, int store2,
	id<MTLTexture> t3, id<MTLTexture> t4) {
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	if (times) {
		rp.sampleBufferAttachments[0].sampleBuffer = times;
		rp.sampleBufferAttachments[0].startOfVertexSampleIndex = MTLCounterDontSample;
		rp.sampleBufferAttachments[0].endOfVertexSampleIndex = MTLCounterDontSample;
		rp.sampleBufferAttachments[0].startOfFragmentSampleIndex = (NSUInteger) sample;
		rp.sampleBufferAttachments[0].endOfFragmentSampleIndex = (NSUInteger) sample + 1;
	}
	rp.colorAttachments[0].texture = out;
	rp.colorAttachments[0].loadAction = load;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	if (out1) {
		rp.colorAttachments[1].texture = out1;
		rp.colorAttachments[1].loadAction = MTLLoadActionDontCare;
		rp.colorAttachments[1].storeAction = MTLStoreActionStore;
	}
	if (out2) {
		rp.colorAttachments[2].texture = out2;
		rp.colorAttachments[2].loadAction = MTLLoadActionDontCare;
		rp.colorAttachments[2].storeAction = store2 ? MTLStoreActionStore : MTLStoreActionDontCare;
	}
	// the live part of the VL targets (TAAU dynamic resolution: they are allocated for the largest render scale); (FT2.7, audit
	// idx 5) as the render area too, not only the viewport: the tiles past it were loaded and stored for nothing
	int sub = liveW > 0 && liveH > 0 && (liveW < (int) out.width || liveH < (int) out.height);
	if (sub) {
		rp.renderTargetWidth = (NSUInteger) MIN(liveW, (int) out.width);
		rp.renderTargetHeight = (NSUInteger) MIN(liveH, (int) out.height);
	}
	id<MTLRenderCommandEncoder> r = [cb renderCommandEncoderWithDescriptor:rp];
	r.label = label;
	[r setRenderPipelineState:p];
	if (sub) {
		[r setViewport:(MTLViewport) {0, 0, MIN(liveW, (int) out.width), MIN(liveH, (int) out.height), 0, 1}];
	}
	mc_shade_bind_render(r);
	[r setFragmentBytes:params length:paramBytes atIndex:0];
	if (state) [r setFragmentBuffer:state offset:0 atIndex:1];
	if (t0) [r setFragmentTexture:t0 atIndex:0];
	if (t1) [r setFragmentTexture:t1 atIndex:1];
	if (t2) [r setFragmentTexture:t2 atIndex:2];
	if (t3) [r setFragmentTexture:t3 atIndex:3];
	if (t4) [r setFragmentTexture:t4 atIndex:4];
	[r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	[r endEncoding];
}

// One frame of volumetric light onto color (the game's main colour, read and written in place) from depth (its depth).
// params: VlParams (vl.metal), paramBytes of it; vlWidth x vlHeight the march resolution. flags: 1 canopy pass,
// 2 drop the history, 4 HDR composite (scene * T + light; M2), 8 GPU timer (mc_vl_times), 16 fold (M2, needs a state made
// with HDR: no composite pass, the temporal pass also writes lightT for ShadePost's final pass, see mc_vl_outputs). Returns 0, or -1 when the composite pipeline can't be built (err).
// liveW x liveH: the part of the vlWidth x vlHeight targets the march and temporal passes cover (VlParams.size.xy; the
// targets keep their size while the render scale moves); 0 = all of it.
int mc_vl_render(Enc *enc, VlState *s, id<MTLTexture> color, id<MTLTexture> depth, const void *params, int paramBytes, int vlWidth,
	int vlHeight, int liveW, int liveH, int flags, char *err, int errCap) {
	@autoreleasepool {
		id<MTLDevice> dev = enc->ctx->device;
		int hdr = (flags & 4) != 0, fold = (flags & 16) != 0 && s->temporalFold;
		if (!fold && (!s->composite || s->compositeFormat != color.pixelFormat || s->compositeHdr != hdr)) {
			[s->composite release];
			s->composite = pso(dev, s->lib, hdr ? @"vl_composite_hdr" : @"vl_composite", color.pixelFormat, hdr, err, errCap);
			s->compositeFormat = color.pixelFormat;
			s->compositeHdr = hdr;
			if (!s->composite) return -1;
		}
		int reset = (flags & 2) != 0;
		if (!s->raw || s->width != vlWidth || s->height != vlHeight) {
			[s->raw release];
			[s->hist[0] release];
			[s->hist[1] release];
			[s->sky[0] release];
			[s->sky[1] release];
			[s->lightT release];
			s->lightT = nil;
			[s->veil[0] release];
			[s->veil[1] release];
			s->veil[0] = s->veil[1] = nil;
			[s->lightR release];
			s->lightR = nil;
			[s->od release];
			[s->odHist[0] release];
			[s->odHist[1] release];
			s->odHist[0] = s->odHist[1] = nil;
			s->odRan = 0;
			s->raw = target(dev, MTLPixelFormatRGBA16Float, vlWidth, vlHeight, s->lossy, @"mcopt shade: VL march");
			s->hist[0] = target(dev, MTLPixelFormatRGBA16Float, vlWidth, vlHeight, s->lossy, @"mcopt shade: VL history A");
			s->hist[1] = target(dev, MTLPixelFormatRGBA16Float, vlWidth, vlHeight, s->lossy, @"mcopt shade: VL history B");
			s->sky[0] = target(dev, MTLPixelFormatR8Unorm, vlWidth, vlHeight, 0, @"mcopt shade: VL sky mask A");
			s->sky[1] = target(dev, MTLPixelFormatR8Unorm, vlWidth, vlHeight, 0, @"mcopt shade: VL sky mask B");
			s->od = target(dev, MTLPixelFormatR16Float, vlWidth, vlHeight, 0, @"mcopt shade: VL scene dimming od");
			if (s->temporalFold) {
				s->odHist[0] = target(dev, MTLPixelFormatR16Float, vlWidth, vlHeight, 0, @"mcopt shade: VL scene dimming od history A");
				s->odHist[1] = target(dev, MTLPixelFormatR16Float, vlWidth, vlHeight, 0, @"mcopt shade: VL scene dimming od history B");
			}
			if (s->temporalFold) s->lightT = target(dev, MTLPixelFormatRGBA16Float, vlWidth, vlHeight, s->lossy, @"mcopt shade: VL light + T");
			if (s->radial) s->lightR = target(dev, MTLPixelFormatRGBA16Float, vlWidth, vlHeight, s->lossy, @"mcopt shade: VL light + T (radial)");
			if (s->veilBlurV) {
				s->veil[0] = target(dev, MTLPixelFormatR16Float, (vlWidth + 3) / 4, (vlHeight + 3) / 4, 0, @"mcopt shade: VL veil A");
				s->veil[1] = target(dev, MTLPixelFormatR16Float, (vlWidth + 3) / 4, (vlHeight + 3) / 4, 0, @"mcopt shade: VL veil B");
			}
			s->veilRan = 0;
			s->width = vlWidth;
			s->height = vlHeight;
			reset = 1;
		}
		float local[128]; // VlParams: 512 bytes since 2026-11 (air8), all of it; the next float4 needs float local[160]
		if (paramBytes > (int) sizeof(local)) paramBytes = sizeof(local);
		memcpy(local, params, paramBytes);
		if (reset && paramBytes >= 38 * 4) local[37] = 1.0f; // VlParams.temporal.y: the temporal pass drops the history
		params = local;
		id<MTLCommandBuffer> cb = mc_frame_cmd(enc);
		// (godrays v3) VlParams.air.x (float 88): the air mode; its shade grid first (a camera-centred 64 x 32 x 64 block of cells)
		int air = s->shadeGridK && s->shadeGrid && paramBytes >= 89 * 4 && local[88] > 0.5f;
		// (2026-11) VlParams.air8.z (float 126): the forest air dims the scene (air mode, fold): the march stores its od, the fold
		// filters it into T (no plain temporal pass then, below)
		int dim = (flags & 16) != 0 && s->temporalFold && s->odHist[0] && paramBytes >= 127 * 4 && local[88] > 0.5f && local[126] != 0.0f;
		// (FT2.8, audit idx 6) the canopy factor (1 threadgroup, writes the state buffer) and the shade grid (writes the grid
		// texture) are independent: one concurrent encoder, so the tiny canopy group overlaps the grid's instead of a pass of its own
		if ((flags & 1) || air) {
			id<MTLComputeCommandEncoder> c = [cb computeCommandEncoderWithDispatchType:MTLDispatchTypeConcurrent];
			c.label = air ? @"mcopt shade: VL canopy + shade grid" : @"mcopt shade: VL canopy";
			mc_shade_bind_compute(c);
			[c setBytes:params length:paramBytes atIndex:0];
			if (flags & 1) {
				[c setComputePipelineState:s->canopy];
				[c setBuffer:s->state offset:0 atIndex:1];
				[c dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
			}
			if (air) {
				[c setComputePipelineState:s->shadeGridK];
				[c setTexture:s->shadeGrid atIndex:0];
				// a quarter of the z slices per frame (VlParams.air4.w, float 111: which; < 0 = all of them, after a reset)
				int all = paramBytes >= 112 * 4 && local[111] < 0.0f;
				[c dispatchThreadgroups:MTLSizeMake(64 / 4, 32 / 4, all ? 64 / 4 : 64 / 16) threadsPerThreadgroup:MTLSizeMake(4, 4, 4)];
			}
			[c endEncoding];
		}
		int next = 1 - s->cur;
		id<MTLCounterSampleBuffer> times = nil;
		int base = 0;
		if (flags & 8) {
			if (!s->timesTried) timesInit(s, dev);
			if (s->times) {
				int r = s->timeFrame % VL_TIME_RING;
				if (s->timeFrame >= VL_TIME_RING) timesCollect(s, dev, r); // this slot's frame was VL_TIME_RING frames ago: done
				s->timeFrame++;
				times = s->times;
				base = 6 * r;
			}
		}
		// the march writes this frame's sky mask and reads last frame's (the crepuscular streaks' occluders)
		pass(cb, s->raw, s->sky[next], MTLLoadActionDontCare, s->march, @"mcopt shade: VL march", params, paramBytes, s->state, depth, s->sky[s->cur],
			times, base, liveW, liveH, s->shadeGrid, s->od, dim, nil, nil);
		if (fold) {
			// M2 fold: no full-resolution pass here; ShadePost's final pass upsamples lightT (mc_vl_outputs)
			// (2026-10-09) VlParams.hp.w (float 79): the shafts' local contrast, from last frame's veil (skipped once when it's stale)
			int hp = s->veilBlurV && paramBytes >= 80 * 4 && local[79] > 0.5f;
			if (hp && !s->veilRan) local[79] = 0.0f;
			int radialOn = s->radial && s->lightR && paramBytes >= 84 * 4 && local[83] > 0.5f;
			// (FT2.8, audit idx 2) the air mode (VlParams.air.x, float 88) without the canopy mist's extinction (mist.z, float 54),
			// the local contrast or the radial blur: the fold's light + T would be an exact copy of the history (T = 1). The plain
			// temporal pass then (one target less to write), and the final pass reads the history for both (mc_vl_outputs: the
			// same texture twice tells ShadePost T = 1)
			// (2026-11) nor the forest air's dimming (air8.z, dim)
			s->histOnly = !hp && !radialOn && !dim && paramBytes >= 89 * 4 && local[88] > 0.5f && local[54] == 0.0f;
			if (s->histOnly) {
				pass(cb, s->hist[next], nil, MTLLoadActionDontCare, s->temporal, @"mcopt shade: VL temporal", params, paramBytes, nil, s->raw,
					s->hist[s->cur], times, base + 2, liveW, liveH, nil, nil, 0, nil, nil);
			} else {
				// (2026-11) no od history kept last frame (dim just came on, a resize): air8.z negative, the fold uses this frame's od
				if (dim && !s->odRan && local[126] > 0.0f) local[126] = -local[126];
				pass(cb, s->hist[next], s->lightT, MTLLoadActionDontCare, s->temporalFold, @"mcopt shade: VL temporal", params, paramBytes, s->state,
					s->raw, s->hist[s->cur], times, base + 2, liveW, liveH, s->veil[0], s->odHist[next], dim, s->od, s->odHist[s->cur]);
			}
			s->odRan = dim && !s->histOnly;
			if (hp) {
				// this frame's veil for the next one: the 4x4 means of the new history, then the blur (quarter resolution)
				int qw = ((liveW > 0 ? liveW : vlWidth) + 3) / 4, qh = ((liveH > 0 ? liveH : vlHeight) + 3) / 4;
				pass(cb, s->veil[0], nil, MTLLoadActionDontCare, s->veilDown, @"mcopt shade: VL veil", params, paramBytes, nil, s->hist[next], nil,
					nil, 0, qw, qh, nil, nil, 0, nil, nil);
				pass(cb, s->veil[1], nil, MTLLoadActionDontCare, s->veilBlurH, @"mcopt shade: VL veil blur", params, paramBytes, nil, s->veil[0], nil,
					nil, 0, qw, qh, nil, nil, 0, nil, nil);
				pass(cb, s->veil[0], nil, MTLLoadActionDontCare, s->veilBlurV, @"mcopt shade: VL veil blur", params, paramBytes, nil, s->veil[1], nil,
					nil, 0, qw, qh, nil, nil, 0, nil, nil);
			}
			s->veilRan = hp;
			// (FT2.3) VlParams.radial.w (float 83): the blur along the light's lines, lightT -> lightR (the final pass reads lightR)
			s->radialRan = radialOn;
			if (s->radialRan) {
				pass(cb, s->lightR, nil, MTLLoadActionDontCare, s->radial, @"mcopt shade: VL radial", params, paramBytes, nil, s->lightT, s->hist[next],
					nil, 0, liveW, liveH, nil, nil, 0, nil, nil);
			}
		} else {
			s->histOnly = 0;
			s->odRan = 0;
			pass(cb, s->hist[next], nil, MTLLoadActionDontCare, s->temporal, @"mcopt shade: VL temporal", params, paramBytes, nil, s->raw,
				s->hist[s->cur], times, base + 2, liveW, liveH, nil, nil, 0, nil, nil);
			pass(cb, color, nil, MTLLoadActionLoad, s->composite, @"mcopt shade: VL composite", params, paramBytes, s->state, s->hist[next], depth,
				times, base + 4, 0, 0, nil, nil, 0, nil, nil);
		}
		s->cur = next;
		return 0;
	}
}

// After an mc_vl_render with flag 16 (fold): out[0] = the light + T texture, out[1] = the history it matches (a = distance).
void mc_vl_outputs(VlState *s, uint64_t *out) {
	out[0] = (uint64_t) (s->histOnly ? s->hist[s->cur] : s->radialRan ? s->lightR : s->lightT);
	out[1] = (uint64_t) s->hist[s->cur];
}

// The canopy factor the GPU wrote (smoothed, raw shadowed fraction) as of the last completed frame, for logs and tests.
void mc_vl_canopy(VlState *s, float *out) {
	const float *c = (const float *) s->state.contents;
	out[0] = c[0];
	out[1] = c[1];
}
