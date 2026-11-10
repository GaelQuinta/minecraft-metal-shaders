// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// M3 volumetric clouds (E05; mcopt.metal.shade.clouds.ShadeClouds, resources/mcopt/shade/clouds.metal): the noise bakes
// (once, on a command buffer of their own), and per frame on the frame's command buffer, before the sky pass: the cloud
// shadow map, the checkerboard march, the history resolve and the reflection dome, each a full-screen fragment pass into
// private render targets with the shade globals bound (mc_shade_bind_render: ShadeFrame, the sky LUT...). The Java side
// publishes the outputs in ShadeResources (12 shadow, 13 dome, 14 screen history). Manual retain/release (-fno-objc-arc).
#import "mcmetal.h"

int mc_shade_bind_render(id<MTLRenderCommandEncoder> r);

#define CLOUD_TIME_RING 4
#define CLOUD_PASSES 4

typedef struct {
	id<MTLLibrary> lib;
	id<MTLComputePipelineState> bakeNoise, bakeWeather;
	id<MTLRenderPipelineState> march, resolve, dome, shadow;
	id<MTLRenderPipelineState> resolveSt; // M3.3 cloud_resolve_st (flag 16): its data target is R16Uint (age + the clouds' distance)
	// (v12-opt, mc_clouds_lean) the march and resolves specialized for one set of dev bits, mode bits and style (clouds.metal
	// CLOUD_FC_*), bound (flag 64) on the frames whose CloudParams carry exactly those values
	id<MTLRenderPipelineState> marchLean, resolveLean, resolveStLean;
	int leanDev, leanMode;
	float leanStyle;
	id<MTLRenderPipelineState> over;  // cloud_over for the HDR scene's format (made on first use)
	MTLPixelFormat overFormat;
	id<MTLTexture> noise, weather, shadowMap;
	id<MTLTexture> vanilla; // (1.1) the game's cloud texture as a 0/1 mask (mc_clouds_vanilla): the blocky style's cells
	id<MTLTexture> marchColor, marchDist, hist[2], data[2], dataSt[2], domeTex[2];
	int hw, hh, mw, mh, dw, dh, cur, domeCur;
	int histSt; // (1.2.3) hist[cur] came from cloud_resolve_st (flag 16): dataSt[cur] holds its distances (cloud_over reads them)
	// GPU timer (flag 8): fragment start/end per pass, a ring of 4 frames
	id<MTLCounterSampleBuffer> times;
	int timesTried, timeFrame;
	MTLTimestamp cpu0, gpu0;
	double timeSum[CLOUD_PASSES];
	int timeN[CLOUD_PASSES], timeCount;
	uint64_t timeLast[CLOUD_TIME_RING];
	int timeRan[CLOUD_TIME_RING];  // bit p: pass p was encoded with this ring slot's samples
} CloudState;

// lean: specialize CLOUD_FC_DEV / MODE / STYLE (function constants 0-2) to dev / mode / style; else none (read from CloudParams)
static id<MTLRenderPipelineState> cloudPsoFc(id<MTLDevice> dev, id<MTLLibrary> lib, NSString *fs, MTLPixelFormat f0, MTLPixelFormat f1, int lean,
	int devBits, int modeBits, float style, char *err, int errCap) {
	MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor new] autorelease];
	pd.label = fs;
	pd.vertexFunction = [[lib newFunctionWithName:@"cloud_vs"] autorelease];
	MTLFunctionConstantValues *fc = [[MTLFunctionConstantValues new] autorelease];
	if (lean) {
		[fc setConstantValue:&devBits type:MTLDataTypeInt atIndex:0];
		[fc setConstantValue:&modeBits type:MTLDataTypeInt atIndex:1];
		[fc setConstantValue:&style type:MTLDataTypeFloat atIndex:2];
	}
	NSError *fe = nil;
	pd.fragmentFunction = [[lib newFunctionWithName:fs constantValues:fc error:&fe] autorelease];
	if (!pd.vertexFunction || !pd.fragmentFunction) {
		snprintf(err, errCap, "clouds: no function %s", fs.UTF8String);
		return nil;
	}
	pd.colorAttachments[0].pixelFormat = f0;
	if (f1 != MTLPixelFormatInvalid) pd.colorAttachments[1].pixelFormat = f1;
	NSError *e = nil;
	id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
	if (!p) snprintf(err, errCap, "clouds %s: %s", fs.UTF8String, e.localizedDescription.UTF8String);
	return p;
}

static id<MTLRenderPipelineState> cloudPso(id<MTLDevice> dev, id<MTLLibrary> lib, NSString *fs, MTLPixelFormat f0, MTLPixelFormat f1, char *err, int errCap) {
	return cloudPsoFc(dev, lib, fs, f0, f1, 0, 0, 0, 0.0f, err, errCap);
}

// The three lean pipelines for one key (march, resolve, resolve_st), as mc_clouds_lean and mc_clouds_warm_lean build them.
static int cloudLeanPsos(id<MTLDevice> dev, id<MTLLibrary> lib, int devBits, int modeBits, float style, id<MTLRenderPipelineState> out[3]) {
	char err[512];
	out[0] = cloudPsoFc(dev, lib, @"cloud_march", MTLPixelFormatRGBA16Float, MTLPixelFormatR32Float, 1, devBits, modeBits, style, err, sizeof err);
	out[1] = cloudPsoFc(dev, lib, @"cloud_resolve", MTLPixelFormatRGBA16Float, MTLPixelFormatR8Unorm, 1, devBits, modeBits, style, err, sizeof err);
	out[2] = cloudPsoFc(dev, lib, @"cloud_resolve_st", MTLPixelFormatRGBA16Float, MTLPixelFormatR16Uint, 1, devBits, modeBits, style, err, sizeof err);
	if (out[0] && out[1] && out[2]) return 1;
	NSLog(@"mcopt clouds: lean pipelines: %s", err);
	for (int i = 0; i < 3; i++) {
		[out[i] release];
		out[i] = nil;
	}
	return 0;
}

static id<MTLComputePipelineState> cloudKernel(id<MTLDevice> dev, id<MTLLibrary> lib, NSString *name, char *err, int errCap) {
	// (v12-opt: through constantValues, none set: the library has optional function constants, clouds.metal CLOUD_FC_*)
	id<MTLFunction> fn = [[lib newFunctionWithName:name constantValues:[[MTLFunctionConstantValues new] autorelease] error:nil] autorelease];
	if (!fn) {
		snprintf(err, errCap, "clouds: no kernel %s", name.UTF8String);
		return nil;
	}
	NSError *e = nil;
	id<MTLComputePipelineState> p = [dev newComputePipelineStateWithFunction:fn error:&e];
	if (!p) snprintf(err, errCap, "clouds %s: %s", name.UTF8String, e.localizedDescription.UTF8String);
	return p;
}

static id<MTLTexture> cloudTarget(id<MTLDevice> dev, MTLPixelFormat format, int w, int h, NSString *label) {
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:(NSUInteger) w height:(NSUInteger) h mipmapped:NO];
	td.storageMode = MTLStorageModePrivate;
	td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
	id<MTLTexture> t = [dev newTextureWithDescriptor:td];
	t.label = label;
	return t;
}

void mc_clouds_free(CloudState *s);

static void timesInit(CloudState *s, id<MTLDevice> device) {
	s->timesTried = 1;
	if (![device supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) return;
	@autoreleasepool {
		for (id<MTLCounterSet> set in device.counterSets) {
			if (![set.name isEqualToString:MTLCommonCounterSetTimestamp]) continue;
			MTLCounterSampleBufferDescriptor *d = [[MTLCounterSampleBufferDescriptor new] autorelease];
			d.counterSet = set;
			d.storageMode = MTLStorageModeShared;
			d.sampleCount = CLOUD_TIME_RING * CLOUD_PASSES * 2;
			s->times = [device newCounterSampleBufferWithDescriptor:d error:nil];
			[device sampleTimestamps:&s->cpu0 gpuTimestamp:&s->gpu0];
			break;
		}
	}
}

static void timesCollect(CloudState *s, id<MTLDevice> device, int r) {
	MTLTimestamp cpu1, gpu1;
	[device sampleTimestamps:&cpu1 gpuTimestamp:&gpu1];
	if (gpu1 <= s->gpu0 || cpu1 <= s->cpu0) return;
	double nsPerTick = (double) (cpu1 - s->cpu0) / (double) (gpu1 - s->gpu0);
	@autoreleasepool {
		const int n = CLOUD_PASSES * 2;
		NSData *data = [s->times resolveCounterRange:NSMakeRange((NSUInteger) (n * r), n)];
		if (data.length < n * sizeof(MTLCounterResultTimestamp)) return;
		const MTLCounterResultTimestamp *ts = data.bytes;
		uint64_t first = 0;
		for (int i = 0; i < n; i++) if (ts[i].timestamp != MTLCounterErrorValue && ts[i].timestamp != 0) { first = ts[i].timestamp; break; }
		if (first == 0 || first == s->timeLast[r]) return;
		s->timeLast[r] = first;
		for (int p = 0; p < CLOUD_PASSES; p++) {
			uint64_t a = ts[2 * p].timestamp, b = ts[2 * p + 1].timestamp;
			if (!(s->timeRan[r] & (1 << p))) continue; // pass skipped that frame (its samples are stale)
			if (a == MTLCounterErrorValue || b == MTLCounterErrorValue || a == 0) continue;
			if (b > a) {
				s->timeSum[p] += (double) (b - a) * nsPerTick / 1e6;
				s->timeN[p]++;
			}
		}
		s->timeCount++;
	}
}

// Average GPU ms of shadow, march, resolve and dome per run of each since the last call (out[0..3]; the shadow map and the
// dome run every 4th frame) and the frame count (out[4]). Fragment stage start to end: other work the GPU overlaps with
// a pass counts too, so these are upper bounds (compare whole-frame GPU time with the clouds on and off).
void mc_clouds_times(CloudState *s, float *out) {
	int n = s->timeCount;
	for (int p = 0; p < CLOUD_PASSES; p++) {
		out[p] = s->timeN[p] > 0 ? (float) (s->timeSum[p] / s->timeN[p]) : 0.0f;
		s->timeSum[p] = 0;
		s->timeN[p] = 0;
	}
	out[CLOUD_PASSES] = (float) n;
	s->timeCount = 0;
}

// Compiles the passes (source: ShadeMsl.prelude() + clouds.metal) and bakes the noise textures (waits for the GPU once).
// NULL with the message in err on failure.
CloudState *mc_clouds_new(Ctx *ctx, const char *source, char *err, int errCap) {
	@autoreleasepool {
		CloudState *s = calloc(1, sizeof(CloudState));
		id<MTLDevice> dev = ctx->device;
		MTLCompileOptions *o = [[MTLCompileOptions new] autorelease];
		o.languageVersion = MTLLanguageVersion3_0;
		o.mathMode = mc_math();
		NSError *e = nil;
		s->lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:source] options:o error:&e];
		if (!s->lib) {
			snprintf(err, errCap, "clouds: %s", e.localizedDescription.UTF8String);
			mc_clouds_free(s);
			return NULL;
		}
		s->bakeNoise = cloudKernel(dev, s->lib, @"cloud_bake_noise", err, errCap);
		s->bakeWeather = cloudKernel(dev, s->lib, @"cloud_bake_weather", err, errCap);
		s->march = cloudPso(dev, s->lib, @"cloud_march", MTLPixelFormatRGBA16Float, MTLPixelFormatR32Float, err, errCap);
		s->resolve = cloudPso(dev, s->lib, @"cloud_resolve", MTLPixelFormatRGBA16Float, MTLPixelFormatR8Unorm, err, errCap);
		s->resolveSt = cloudPso(dev, s->lib, @"cloud_resolve_st", MTLPixelFormatRGBA16Float, MTLPixelFormatR16Uint, err, errCap);
		s->dome = cloudPso(dev, s->lib, @"cloud_dome", MTLPixelFormatRGBA16Float, MTLPixelFormatInvalid, err, errCap);
		s->shadow = cloudPso(dev, s->lib, @"cloud_shadow", MTLPixelFormatR16Float, MTLPixelFormatInvalid, err, errCap);
		if (!s->bakeNoise || !s->bakeWeather || !s->march || !s->resolve || !s->resolveSt || !s->dome || !s->shadow) {
			mc_clouds_free(s);
			return NULL;
		}
		MTLTextureDescriptor *td = [[MTLTextureDescriptor new] autorelease];
		td.textureType = MTLTextureType3D;
		td.pixelFormat = MTLPixelFormatRGBA8Unorm;
		td.width = td.height = td.depth = 64;
		td.mipmapLevelCount = 7;  // far samples read blurred noise (clouds.metal: cloudDensity's lod)
		td.storageMode = MTLStorageModePrivate;
		td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
		s->noise = [dev newTextureWithDescriptor:td];
		s->noise.label = @"mcopt shade: cloud noise 3D";
		// (2026-11 round 4) with mips: the far light samples read the cloud shape blurred (clouds.metal cloudLightDepthB, CloudParams.hz.z)
		MTLTextureDescriptor *wd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:512 height:512 mipmapped:YES];
		wd.storageMode = MTLStorageModePrivate;
		wd.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
		s->weather = [dev newTextureWithDescriptor:wd];
		s->weather.label = @"mcopt shade: cloud weather map";
		s->shadowMap = cloudTarget(dev, MTLPixelFormatR16Float, 256, 256, @"mcopt shade: cloud shadow");
		id<MTLCommandBuffer> cb = [ctx->queue commandBuffer];
		id<MTLComputeCommandEncoder> c = [cb computeCommandEncoder];
		c.label = @"mcopt shade: cloud noise bakes";
		[c setComputePipelineState:s->bakeNoise];
		[c setTexture:s->noise atIndex:0];
		[c dispatchThreads:MTLSizeMake(64, 64, 64) threadsPerThreadgroup:MTLSizeMake(4, 4, 4)];
		[c setComputePipelineState:s->bakeWeather];
		[c setTexture:s->weather atIndex:0];
		[c dispatchThreads:MTLSizeMake(512, 512, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
		[c endEncoding];
		id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
		[bl generateMipmapsForTexture:s->noise];
		[bl generateMipmapsForTexture:s->weather];
		[bl endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		if (cb.status != MTLCommandBufferStatusCompleted) {
			snprintf(err, errCap, "clouds: noise bake failed (%s)", cb.error ? cb.error.localizedDescription.UTF8String : "?");
			mc_clouds_free(s);
			return NULL;
		}
		return s;
	}
}

void mc_clouds_free(CloudState *s) {
	if (!s) return;
	[s->lib release];
	[s->bakeNoise release];
	[s->bakeWeather release];
	[s->march release];
	[s->resolve release];
	[s->resolveSt release];
	[s->marchLean release];
	[s->resolveLean release];
	[s->resolveStLean release];
	[s->dome release];
	[s->shadow release];
	[s->over release];
	[s->noise release];
	[s->weather release];
	[s->vanilla release];
	[s->shadowMap release];
	[s->marchColor release];
	[s->marchDist release];
	for (int i = 0; i < 2; i++) {
		[s->hist[i] release];
		[s->data[i] release];
		[s->dataSt[i] release];
		[s->domeTex[i] release];
	}
	[s->times release];
	free(s);
}

// (Re)allocates the screen targets: history hw x hh, march mw x mh (1/N of it with the N x N checkerboard), dome dw x dh.
// Returns 1 when anything was (re)made (the caller drops the history for a frame).
int mc_clouds_size(CloudState *s, Ctx *ctx, int hw, int hh, int mw, int mh, int dw, int dh) {
	int changed = 0;
	@autoreleasepool {
		id<MTLDevice> dev = ctx->device;
		if (hw != s->hw || hh != s->hh || mw != s->mw || mh != s->mh) {
			// the frames in flight may still read the old ones: they keep them alive (command buffers retain what they use,
			// and ShadeResources' ring retains its entries)
			[s->marchColor release];
			[s->marchDist release];
			for (int i = 0; i < 2; i++) {
				[s->hist[i] release];
				[s->data[i] release];
				[s->dataSt[i] release];
			}
			s->marchColor = cloudTarget(dev, MTLPixelFormatRGBA16Float, mw, mh, @"mcopt shade: cloud march");
			s->marchDist = cloudTarget(dev, MTLPixelFormatR32Float, mw, mh, @"mcopt shade: cloud march distance");
			for (int i = 0; i < 2; i++) {
				s->hist[i] = cloudTarget(dev, MTLPixelFormatRGBA16Float, hw, hh, i ? @"mcopt shade: cloud history B" : @"mcopt shade: cloud history A");
				s->data[i] = cloudTarget(dev, MTLPixelFormatR8Unorm, hw, hh, i ? @"mcopt shade: cloud age B" : @"mcopt shade: cloud age A");
				s->dataSt[i] = cloudTarget(dev, MTLPixelFormatR16Uint, hw, hh, i ? @"mcopt shade: cloud age+distance B" : @"mcopt shade: cloud age+distance A");
			}
			s->hw = hw;
			s->hh = hh;
			s->mw = mw;
			s->mh = mh;
			changed = 1;
		}
		if (dw != s->dw || dh != s->dh) {
			for (int i = 0; i < 2; i++) {
				[s->domeTex[i] release];
				s->domeTex[i] = cloudTarget(dev, MTLPixelFormatRGBA16Float, dw, dh, i ? @"mcopt shade: cloud dome B" : @"mcopt shade: cloud dome A");
			}
			s->dw = dw;
			s->dh = dh;
			changed = 1;
		}
	}
	return changed;
}

static void cloudPass(id<MTLCommandBuffer> cb, id<MTLRenderPipelineState> p, id<MTLTexture> out0, id<MTLTexture> out1, NSString *label,
	const void *params, int bytes, id<MTLTexture> const *inputs, int count, id<MTLCounterSampleBuffer> times, int sample) {
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	if (times) {
		rp.sampleBufferAttachments[0].sampleBuffer = times;
		rp.sampleBufferAttachments[0].startOfVertexSampleIndex = MTLCounterDontSample;
		rp.sampleBufferAttachments[0].endOfVertexSampleIndex = MTLCounterDontSample;
		rp.sampleBufferAttachments[0].startOfFragmentSampleIndex = (NSUInteger) sample;
		rp.sampleBufferAttachments[0].endOfFragmentSampleIndex = (NSUInteger) sample + 1;
	}
	rp.colorAttachments[0].texture = out0;
	rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	if (out1) {
		rp.colorAttachments[1].texture = out1;
		rp.colorAttachments[1].loadAction = MTLLoadActionDontCare;
		rp.colorAttachments[1].storeAction = MTLStoreActionStore;
	}
	id<MTLRenderCommandEncoder> r = [cb renderCommandEncoderWithDescriptor:rp];
	r.label = label;
	[r setRenderPipelineState:p];
	mc_shade_bind_render(r);
	[r setFragmentBytes:params length:(NSUInteger) bytes atIndex:0];
	for (int i = 0; i < count; i++) if (inputs[i]) [r setFragmentTexture:inputs[i] atIndex:(NSUInteger) i];
	[r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	[r endEncoding];
}

// (1.1) The game's cloud texture (textures/environment/clouds.png, resource packs included) as an R8 mask, w x h bytes (255 = a
// cloud cell): with render flag 32 the passes read it in place of the weather map (the blocky style: vanilla's own cloud shapes,
// ray-traced and lit). Replaces any earlier mask. Returns 1 when made.
int mc_clouds_vanilla(CloudState *s, Ctx *ctx, const uint8_t *mask, int w, int h) {
	if (!s || !mask || w <= 0 || h <= 0) return 0;
	@autoreleasepool {
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:(NSUInteger) w height:(NSUInteger) h mipmapped:NO];
		td.storageMode = MTLStorageModeShared;
		td.usage = MTLTextureUsageShaderRead;
		id<MTLTexture> t = [ctx->device newTextureWithDescriptor:td];
		if (!t) return 0;
		t.label = @"mcopt shade: vanilla cloud cells";
		[t replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger) w, (NSUInteger) h) mipmapLevel:0 withBytes:mask bytesPerRow:(NSUInteger) w];
		[s->vanilla release]; // frames in flight keep the old one alive (command buffers retain what they use)
		s->vanilla = t;
		return 1;
	}
}

// One frame of clouds on the frame's command buffer (ending any open render encoder; the backend reopens its own).
// params: CloudParams (clouds.metal), bytes long. flags: 1 shadow map, 2 screen (march + resolve), 4 dome, 8 GPU timer,
// 16 the M3.3 resolve (cloud_resolve_st with its R16Uint data; the Java side drops the history when this changes), 32 (1.1) the
// vanilla cloud mask (mc_clouds_vanilla) bound in place of the weather map (texture 0).
void mc_clouds_render(Enc *enc, CloudState *s, const void *params, int bytes, int flags) {
	if (!s || !s->hist[0]) return;
	@autoreleasepool {
		id<MTLTexture> weather = (flags & 32) && s->vanilla ? s->vanilla : s->weather;
		id<MTLCommandBuffer> cb = mc_frame_cmd(enc);
		id<MTLDevice> dev = cb.device;
		id<MTLCounterSampleBuffer> times = nil;
		int base = 0;
		if (flags & 8) {
			if (!s->timesTried) timesInit(s, dev);
			if (s->times) {
				int r = s->timeFrame % CLOUD_TIME_RING;
				if (s->timeFrame >= CLOUD_TIME_RING) timesCollect(s, dev, r);
				times = s->times;
				base = r * CLOUD_PASSES * 2;
				s->timeRan[r] = (flags & 1 ? 1 : 0) | (flags & 2 ? 6 : 0) | (flags & 4 ? 8 : 0);
				s->timeFrame++;
			}
		}
		if (flags & 1) {
			id<MTLTexture> in[2] = {weather, s->noise};
			cloudPass(cb, s->shadow, s->shadowMap, nil, @"mcopt shade: cloud shadow", params, bytes, in, 2, times, base);
		}
		if (flags & 2) {
			// (v12-opt, flag 64: mcopt.shade.cloudLean) the specialized march and resolve when this frame's dev bits (lightDir.w, float
			// 63), mode bits (shadowDir.w, float 103) and style (art.w, float 107) are the ones they were built for
			const float *pf = (const float *) params;
			int lean = (flags & 64) && s->marchLean && bytes >= 448 && (int) pf[63] == s->leanDev && (int) pf[103] == s->leanMode && pf[107] == s->leanStyle;
			id<MTLTexture> in[2] = {weather, s->noise};
			cloudPass(cb, lean ? s->marchLean : s->march, s->marchColor, s->marchDist, lean ? @"mcopt shade: cloud march (lean)" : @"mcopt shade: cloud march", params,
				bytes, in, 2, times, base + 2);
			int next = s->cur ^ 1;
			BOOL st = (flags & 16) != 0;
			id<MTLTexture> const *data = st ? s->dataSt : s->data;
			id<MTLTexture> in2[4] = {s->marchColor, s->marchDist, s->hist[s->cur], data[s->cur]};
			id<MTLRenderPipelineState> rs = st ? (lean ? s->resolveStLean : s->resolveSt) : (lean ? s->resolveLean : s->resolve);
			cloudPass(cb, rs, s->hist[next], data[next], @"mcopt shade: cloud resolve", params, bytes, in2, 4, times, base + 4);
			s->cur = next;
			s->histSt = st;
		}
		if (flags & 4) {
			int next = s->domeCur ^ 1;
			id<MTLTexture> in[3] = {weather, s->noise, s->domeTex[s->domeCur]};
			cloudPass(cb, s->dome, s->domeTex[next], nil, @"mcopt shade: cloud dome", params, bytes, in, 3, times, base + 6);
			s->domeCur = next;
		}
	}
}

// Clouds in front of the world (cloud_over): into scene (the HDR target, its live sub-rect liveW x liveH) where the depth
// lies behind the clouds' apparent distance (the stable resolve's history distances, else this frame's march distances),
// scene x T + light x exposure. mode: bit 1 Distant Horizons drew this frame (bit 2, the history's distances, is set here).
void mc_clouds_over(Enc *enc, CloudState *s, id<MTLTexture> scene, id<MTLTexture> depth, int liveW, int liveH, int mode) {
	if (!s || !s->hist[0] || !scene || !depth) return;
	@autoreleasepool {
		id<MTLCommandBuffer> cb = mc_frame_cmd(enc);
		if (!s->over || s->overFormat != scene.pixelFormat) {
			[s->over release];
			MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor new] autorelease];
			pd.label = @"cloud_over";
			pd.vertexFunction = [[s->lib newFunctionWithName:@"cloud_vs"] autorelease];
			pd.fragmentFunction = [[s->lib newFunctionWithName:@"cloud_over" constantValues:[[MTLFunctionConstantValues new] autorelease] error:nil] autorelease];
			MTLRenderPipelineColorAttachmentDescriptor *c = pd.colorAttachments[0];
			c.pixelFormat = scene.pixelFormat;
			c.blendingEnabled = YES;
			c.sourceRGBBlendFactor = c.sourceAlphaBlendFactor = MTLBlendFactorOne;
			c.destinationRGBBlendFactor = c.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
			NSError *e = nil;
			s->over = [cb.device newRenderPipelineStateWithDescriptor:pd error:&e];
			s->overFormat = scene.pixelFormat;
			if (!s->over) {
				NSLog(@"mcopt clouds: cloud_over pipeline: %@", e);
				return;
			}
		}
		MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
		rp.colorAttachments[0].texture = scene;
		rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
		rp.colorAttachments[0].storeAction = MTLStoreActionStore;
		id<MTLRenderCommandEncoder> r = [cb renderCommandEncoderWithDescriptor:rp];
		r.label = @"mcopt shade: clouds over the world";
		[r setRenderPipelineState:s->over];
		if (liveW > 0 && liveH > 0) [r setViewport:(MTLViewport) {0, 0, liveW, liveH, 0, 1}];
		mc_shade_bind_render(r);
		[r setFragmentTexture:depth atIndex:0];
		[r setFragmentTexture:s->marchDist atIndex:1];
		[r setFragmentTexture:s->hist[s->cur] atIndex:2];
		// (1.2.3, issue #4) bound either way (R16Uint, as cloud_over declares it); read only with bit 2
		[r setFragmentTexture:s->dataSt[s->cur] atIndex:3];
		uint32_t m = (uint32_t) mode | (s->histSt ? 2u : 0u);
		[r setFragmentBytes:&m length:4 atIndex:0];
		[r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[r endEncoding];
	}
}

// out[0] the cloud shadow map, out[1] the dome, out[2] the screen history written last (MTLTexture pointers).
void mc_clouds_outputs(CloudState *s, id<MTLTexture> *out) {
	out[0] = s ? s->shadowMap : nil;
	out[1] = s ? s->domeTex[s->domeCur] : nil;
	out[2] = s ? s->hist[s->cur] : nil;
}

// (parallel compile, mcopt.metal.shade.ShadeCompile) mc_clouds_new's pipelines, built from lib (the clouds source compiled
// with the same options) through the same helpers, so with the same descriptors, and released again: run off the render
// thread before the clouds start, it leaves them in Metal's shader cache for mc_clouds_new. Returns how many failed.
int mc_clouds_warm(Ctx *ctx, id<MTLLibrary> lib) {
	@autoreleasepool {
		id<MTLDevice> dev = ctx->device;
		char err[512];
		id built[7] = {
			cloudKernel(dev, lib, @"cloud_bake_noise", err, sizeof err),
			cloudKernel(dev, lib, @"cloud_bake_weather", err, sizeof err),
			cloudPso(dev, lib, @"cloud_march", MTLPixelFormatRGBA16Float, MTLPixelFormatR32Float, err, sizeof err),
			cloudPso(dev, lib, @"cloud_resolve", MTLPixelFormatRGBA16Float, MTLPixelFormatR8Unorm, err, sizeof err),
			cloudPso(dev, lib, @"cloud_resolve_st", MTLPixelFormatRGBA16Float, MTLPixelFormatR16Uint, err, sizeof err),
			cloudPso(dev, lib, @"cloud_dome", MTLPixelFormatRGBA16Float, MTLPixelFormatInvalid, err, sizeof err),
			cloudPso(dev, lib, @"cloud_shadow", MTLPixelFormatR16Float, MTLPixelFormatInvalid, err, sizeof err),
		};
		int failed = 0;
		for (int i = 0; i < 7; i++) {
			if (!built[i]) failed++;
			[built[i] release];
		}
		return failed;
	}
}

// (v12-opt) The march and resolves specialized for these dev bits, mode bits and style (clouds.metal CLOUD_FC_*), bound by
// mc_clouds_render (flag 64) on the frames whose CloudParams carry exactly them. Replaces any earlier set; 1 when built.
int mc_clouds_lean(CloudState *s, Ctx *ctx, int devBits, int modeBits, float style) {
	if (!s || !s->lib) return 0;
	@autoreleasepool {
		id<MTLRenderPipelineState> p[3];
		if (!cloudLeanPsos(ctx->device, s->lib, devBits, modeBits, style, p)) return 0;
		[s->marchLean release];
		[s->resolveLean release];
		[s->resolveStLean release];
		s->marchLean = p[0];
		s->resolveLean = p[1];
		s->resolveStLean = p[2];
		s->leanDev = devBits;
		s->leanMode = modeBits;
		s->leanStyle = style;
		return 1;
	}
}

// (parallel compile) mc_clouds_lean's pipelines from lib, built and released (Metal's shader cache keeps them): how many failed.
int mc_clouds_warm_lean(Ctx *ctx, id<MTLLibrary> lib, int devBits, int modeBits, float style) {
	@autoreleasepool {
		id<MTLRenderPipelineState> p[3];
		if (!cloudLeanPsos(ctx->device, lib, devBits, modeBits, style, p)) return 3;
		for (int i = 0; i < 3; i++) [p[i] release];
		return 0;
	}
}
