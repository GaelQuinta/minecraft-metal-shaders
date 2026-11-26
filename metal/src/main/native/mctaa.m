// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// Native shading: temporal anti-aliasing / upscaling (TAAU) passes (mcopt.metal.shade.taa.ShadeTaa, resources
// mcopt/shade/taa.metal). Two full-screen fragment passes at output resolution, both into compressible render targets
// (private storage, RenderTarget | ShaderRead, never ShaderWrite: apple-gpu.md measured 2x cheaper than compute):
//   1. taau_fs: jittered world render (input, a sub-rect of its textures) + last frame's history -> this frame's history
//      (RGBA16Float colour + age) and linear depth (R16Float), ping-ponged here;
//   2. taa_output_fs: the new history -> the destination (the game's main colour target), sharpened.
// The history stays readable after the frame (mc_taa_history) for later passes (M2's final grade, SSR's colour source).
// Manual retain/release (the dylib builds with -fno-objc-arc), like the other files.
#import "mcmetal.h"

typedef struct {
	id<MTLRenderPipelineState> resolve, resolveNoMovers; // (FT2.8, audit idx 63) resolveNoMovers: TAA_MOVERS_ON false, for frames with no mover
	NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *output;  // taa_output_fs per destination pixel format
	id<MTLFunction> vs, outputFs, debugFs;  // debugFs: taau_debug_fs (flags bit 2), else nil
	NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *debug;  // taau_debug_fs per destination pixel format
	id<MTLTexture> hist[2], depth[2];
	id<MTLTexture> noReactive;  // 1x1 R8 zero: bound when no reactive mask is given
	int width, height, cur;     // history size; hist[cur] is the latest
	bool lossy;                 // history targets use lossy framebuffer compression (Apple8+, guaranteed 2:1)
	bool hdr;                   // HDR input (M2): the history rescale comes from ShadeGpu.exposure on the GPU
	uint8_t movers[16 + 32 * 48]; // M3 per-object motion (taa.metal TaaMovers): count + boxes, set by mc_taa_movers; zeroed = none
} Taa;

id<MTLBuffer> mc_shade_gpu_buffer(void);  // mcshade.m: ShadeGpu (M2), nil without the HDR frame

static id<MTLTexture> taaTarget(id<MTLDevice> device, MTLPixelFormat format, int w, int h, bool lossy, NSString *label) {
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
	d.storageMode = MTLStorageModePrivate;
	d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;  // compressible: no ShaderWrite, no format views
	if (lossy) d.compressionType = MTLTextureCompressionTypeLossy;
	id<MTLTexture> t = [device newTextureWithDescriptor:d];
	t.label = label;
	return t;
}

// Compiles taa.metal. flags: bit 0 = the input is linear HDR (function constant TAA_HDR), else display-encoded LDR (M1's
// RGBA8); bit 1 = lossy-compressed history (only where the GPU supports it, Apple8+); bit 2 = debug view (taau_debug_fs
// writes the view into the destination, no output pass). NULL with the compiler's message in err.
Taa *mc_taa_new(Ctx *ctx, const char *source, int flags, char *err, int errCap) {
	int hdr = flags & 1;
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
		MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor new] autorelease];
		pd.vertexFunction = [[lib newFunctionWithName:@"taa_vs"] autorelease];
		MTLFunctionConstantValues *fc = [[MTLFunctionConstantValues new] autorelease];
		bool h = hdr != 0;
		[fc setConstantValue:&h type:MTLDataTypeBool atIndex:0];
		MTLFunctionConstantValues *fcNo = [[MTLFunctionConstantValues new] autorelease];
		bool no = false;
		[fcNo setConstantValue:&h type:MTLDataTypeBool atIndex:0];
		[fcNo setConstantValue:&no type:MTLDataTypeBool atIndex:1];
		pd.fragmentFunction = [[lib newFunctionWithName:@"taau_fs" constantValues:fc error:&e] autorelease];
		if (!pd.fragmentFunction) {
			snprintf(err, errCap, "%s", e.localizedDescription.UTF8String);
			[lib release];
			return NULL;
		}
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
		pd.colorAttachments[1].pixelFormat = MTLPixelFormatRGBA16Float;
		pd.label = @"mcopt shade: TAAU resolve";
		id<MTLRenderPipelineState> resolve = [ctx->device newRenderPipelineStateWithDescriptor:pd error:&e];
		if (!resolve) {
			snprintf(err, errCap, "%s", e.localizedDescription.UTF8String);
			[lib release];
			return NULL;
		}
		pd.fragmentFunction = [[lib newFunctionWithName:@"taau_fs" constantValues:fcNo error:&e] autorelease];
		id<MTLRenderPipelineState> resolveNo = pd.fragmentFunction ? [ctx->device newRenderPipelineStateWithDescriptor:pd error:&e] : nil;
		Taa *t = calloc(1, sizeof(Taa));
		t->resolve = resolve;
		t->resolveNoMovers = resolveNo; // nil: the movers variant every frame
		t->lossy = (flags & 2) && [ctx->device supportsFamily:MTLGPUFamilyApple8];
		t->hdr = hdr != 0;
		t->output = [NSMutableDictionary new];
		t->vs = [lib newFunctionWithName:@"taa_vs"];
		t->outputFs = [lib newFunctionWithName:@"taa_output_fs"];
		t->debug = [NSMutableDictionary new];
		if (flags & 4) t->debugFs = [lib newFunctionWithName:@"taau_debug_fs" constantValues:fc error:&e];
		[lib release];
		MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:1 height:1 mipmapped:NO];
		d.storageMode = MTLStorageModeShared;
		d.usage = MTLTextureUsageShaderRead;
		t->noReactive = [ctx->device newTextureWithDescriptor:d];
		uint8_t zero = 0;
		[t->noReactive replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&zero bytesPerRow:1];
		return t;
	}
}

// The output pipeline for a destination format (made on first use; the main target is RGBA8Unorm, M2's HDR one RGBA16Float).
static id<MTLRenderPipelineState> outputPipeline(Ctx *ctx, Taa *t, MTLPixelFormat format) {
	NSNumber *key = @(format);
	id<MTLRenderPipelineState> pso = t->output[key];
	if (pso) return pso;
	@autoreleasepool {
		MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor new] autorelease];
		pd.vertexFunction = t->vs;
		pd.fragmentFunction = t->outputFs;
		pd.colorAttachments[0].pixelFormat = format;
		pd.label = @"mcopt shade: TAAU output";
		NSError *e = nil;
		pso = [ctx->device newRenderPipelineStateWithDescriptor:pd error:&e];
		if (!pso) {
			NSLog(@"mcopt shade: TAAU output pipeline for format %lu: %@", (unsigned long) format, e);
			return nil;
		}
		t->output[key] = pso;
		[pso release];
		return pso;
	}
}

// The debug resolve for a destination format (made on first use).
static id<MTLRenderPipelineState> debugPipeline(Ctx *ctx, Taa *t, MTLPixelFormat format) {
	NSNumber *key = @(format);
	id<MTLRenderPipelineState> pso = t->debug[key];
	if (pso) return pso;
	@autoreleasepool {
		MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor new] autorelease];
		pd.vertexFunction = t->vs;
		pd.fragmentFunction = t->debugFs;
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
		pd.colorAttachments[1].pixelFormat = MTLPixelFormatRGBA16Float;
		pd.colorAttachments[2].pixelFormat = format;
		pd.label = @"mcopt shade: TAAU debug";
		NSError *e = nil;
		pso = [ctx->device newRenderPipelineStateWithDescriptor:pd error:&e];
		if (!pso) {
			NSLog(@"mcopt shade: TAAU debug pipeline for format %lu: %@", (unsigned long) format, e);
			return nil;
		}
		t->debug[key] = pso;
		[pso release];
		return pso;
	}
}

// (Re)allocates the history at the output size. Returns 1 when it changed (the caller resets the history), 0 otherwise.
int mc_taa_resize(Taa *t, Ctx *ctx, int width, int height) {
	if (t->width == width && t->height == height && t->hist[0]) return 0;
	@autoreleasepool {
		for (int i = 0; i < 2; i++) {
			[t->hist[i] release];
			[t->depth[i] release];
			t->hist[i] = taaTarget(ctx->device, MTLPixelFormatRGBA16Float, width, height, t->lossy, i ? @"mcopt shade: TAA history 1" : @"mcopt shade: TAA history 0");
			t->depth[i] = taaTarget(ctx->device, MTLPixelFormatRGBA16Float, width, height, false, i ? @"mcopt shade: TAA depth 1" : @"mcopt shade: TAA depth 0");
		}
	}
	t->width = width;
	t->height = height;
	t->cur = 0;
	return 1;
}

// Resolves this frame: color/depth = the jittered world render (textures of any size; params say which sub-rect is live),
// reactive = an R8 mask in input pixels or NULL, dst = where the sharpened result goes (NULL: only the history is written).
// params: struct TaaParams of taa.metal (304 bytes since FT2.8). Ends whatever encoder is open; encodes into the frame's command buffer.
void mc_taa_resolve(Enc *enc, Taa *t, id<MTLTexture> color, id<MTLTexture> depth, id<MTLTexture> reactive, id<MTLTexture> dst,
	const void *params, int paramsLength) {
	if (!t->hist[0]) return;
	id<MTLRenderPipelineState> dbg = dst && t->debugFs ? debugPipeline(enc->ctx, t, dst.pixelFormat) : nil;
	id<MTLRenderPipelineState> out = dst && !dbg ? outputPipeline(enc->ctx, t, dst.pixelFormat) : nil;
	@autoreleasepool {
		id<MTLCommandBuffer> cb = mc_frame_cmd(enc);
		int next = 1 - t->cur;
		MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
		rp.colorAttachments[0].texture = t->hist[next];
		rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;  // every pixel is written
		rp.colorAttachments[0].storeAction = MTLStoreActionStore;
		rp.colorAttachments[1].texture = t->depth[next];
		rp.colorAttachments[1].loadAction = MTLLoadActionDontCare;
		rp.colorAttachments[1].storeAction = MTLStoreActionStore;
		if (dbg) {
			rp.colorAttachments[2].texture = dst;
			rp.colorAttachments[2].loadAction = MTLLoadActionDontCare;
			rp.colorAttachments[2].storeAction = MTLStoreActionStore;
		}
		id<MTLRenderCommandEncoder> r = [cb renderCommandEncoderWithDescriptor:rp];
		r.label = @"mcopt shade: TAAU";
		uint32_t moverCount;
		memcpy(&moverCount, t->movers, sizeof moverCount);
		[r setRenderPipelineState:dbg ? dbg : moverCount == 0 && t->resolveNoMovers ? t->resolveNoMovers : t->resolve];
		[r setFragmentBytes:params length:paramsLength atIndex:0];
		[r setFragmentTexture:color atIndex:0];
		[r setFragmentTexture:depth atIndex:1];
		[r setFragmentTexture:t->hist[t->cur] atIndex:2];
		[r setFragmentTexture:t->depth[t->cur] atIndex:3];
		[r setFragmentTexture:reactive ? reactive : t->noReactive atIndex:4];
		// history rescale: M2's exposure (x this frame, z the frame the history was made with) straight from ShadeGpu, which
		// the CPU never sees; otherwise (M1, headless tests) x = the CPU's TaaParams.misc.x over z = 1
		id<MTLBuffer> gpu = t->hdr ? mc_shade_gpu_buffer() : nil;
		if (gpu) {
			[r setFragmentBuffer:gpu offset:176 atIndex:1];
		} else {
			float e[4] = {((const float *) params)[52], 0.0f, 1.0f, 0.0f};
			[r setFragmentBytes:e length:sizeof(e) atIndex:1];
		}
		// M3 movers (the whole struct: API validation checks the bound length against the argument's size)
		[r setFragmentBytes:t->movers length:sizeof t->movers atIndex:2];
		[r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[r endEncoding];
		t->cur = next;
		if (out) {
			rp = [MTLRenderPassDescriptor renderPassDescriptor];
			rp.colorAttachments[0].texture = dst;
			rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
			rp.colorAttachments[0].storeAction = MTLStoreActionStore;
			r = [cb renderCommandEncoderWithDescriptor:rp];
			r.label = @"mcopt shade: TAAU output";
			[r setRenderPipelineState:out];
			[r setFragmentBytes:params length:paramsLength atIndex:0];
			[r setFragmentTexture:t->hist[t->cur] atIndex:0];
			[r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
			[r endEncoding];
		}
	}
}

// M3: the moving entities for the next resolves (taa.metal TaaMovers: uint4 count, then min / max / delta float4 triples);
// length bytes are copied (at most the struct), the count is clamped by the shader. length 0 clears them.
void mc_taa_movers(Taa *t, const void *data, int length) {
	if (!t) return;
	memset(t->movers, 0, sizeof t->movers);
	if (data && length > 0) memcpy(t->movers, data, length < (int) sizeof t->movers ? length : (int) sizeof t->movers);
}

// The latest resolved history (RGBA16Float, output size, rgb + age): valid after mc_taa_resolve until the next one.
id<MTLTexture> mc_taa_history(Taa *t) { return t->hist[t->cur]; }

// Its linear view depth (R16Float, blocks).
id<MTLTexture> mc_taa_history_depth(Taa *t) { return t->depth[t->cur]; }

void mc_taa_free(Taa *t) {
	if (!t) return;
	[t->resolve release];
	[t->resolveNoMovers release];
	[t->output release];
	[t->vs release];
	[t->outputFs release];
	[t->debugFs release];
	[t->debug release];
	for (int i = 0; i < 2; i++) {
		[t->hist[i] release];
		[t->depth[i] release];
	}
	[t->noReactive release];
	free(t);
}
