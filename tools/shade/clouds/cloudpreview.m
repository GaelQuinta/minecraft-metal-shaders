// Copyright 2026 mcopt-shade contributors. Licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0). Dev tool for mcopt native shading's clouds, not part of the mod.
//
// Runs the real cloud passes (clouds.metal, as mcclouds.m does: bakes, shadow, march, resolve, dome) for N frames of a
// scenario packed by CloudPreviewFrames, then the preview composite into a PNG; or times the passes.
//   cloudpreview <clouds.metal> <lut.metal> <dir> <name> <W> <H> <out.png> [mode: 0 screen, 1 dome, 2 shadow, 3 alpha]
//   cloudpreview <clouds.metal> <lut.metal> <dir> <name> <W> <H> time      (GPU ms per pass, averaged over the frames)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static id<MTLDevice> dev;
static id<MTLLibrary> load(NSString *path) {
	NSString *src = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
	MTLCompileOptions *o = [MTLCompileOptions new];
	o.languageVersion = MTLLanguageVersion3_0;
	o.mathMode = MTLMathModeFast;
	NSError *e = nil;
	id<MTLLibrary> lib = [dev newLibraryWithSource:src options:o error:&e];
	if (!lib) { printf("%s: %s\n", path.UTF8String, e.localizedDescription.UTF8String); exit(1); }
	return lib;
}
// (v12-opt) fc: the clouds.metal CLOUD_FC_* specialization (nil: none, as mcclouds.m's generic pipelines)
static id<MTLRenderPipelineState> psoFc(id<MTLLibrary> lib, NSString *vs, NSString *fs, MTLPixelFormat f0, MTLPixelFormat f1, MTLFunctionConstantValues *fc) {
	MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
	pd.vertexFunction = [lib newFunctionWithName:vs];
	pd.fragmentFunction = [lib newFunctionWithName:fs constantValues:fc ? fc : [MTLFunctionConstantValues new] error:nil];
	pd.colorAttachments[0].pixelFormat = f0;
	if (f1 != MTLPixelFormatInvalid) pd.colorAttachments[1].pixelFormat = f1;
	NSError *e = nil;
	id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
	if (!p) { printf("%s: %s\n", fs.UTF8String, e.localizedDescription.UTF8String); exit(1); }
	return p;
}
static id<MTLRenderPipelineState> pso(id<MTLLibrary> lib, NSString *vs, NSString *fs, MTLPixelFormat f0, MTLPixelFormat f1) {
	return psoFc(lib, vs, fs, f0, f1, nil);
}
static id<MTLTexture> tex(MTLPixelFormat f, int w, int h, BOOL shared) {
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
	td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	td.storageMode = shared ? MTLStorageModeShared : MTLStorageModePrivate;
	return [dev newTextureWithDescriptor:td];
}
static id<MTLBuffer> frameBuf, lookBuf;
static id<MTLTexture> lut;
static id<MTLSamplerState> lin;
static double pass(id<MTLCommandQueue> q, id<MTLRenderPipelineState> p, id<MTLTexture> o0, id<MTLTexture> o1, const void *params, int bytes,
	NSArray<id<MTLTexture>> *in, BOOL wait) {
	id<MTLCommandBuffer> cb = [q commandBuffer];
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = o0; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	if (o1) { rp.colorAttachments[1].texture = o1; rp.colorAttachments[1].loadAction = MTLLoadActionDontCare; rp.colorAttachments[1].storeAction = MTLStoreActionStore; }
	id<MTLRenderCommandEncoder> r = [cb renderCommandEncoderWithDescriptor:rp];
	[r setRenderPipelineState:p];
	[r setFragmentBuffer:frameBuf offset:0 atIndex:16];
	[r setFragmentBuffer:lookBuf offset:0 atIndex:17];
	[r setFragmentTexture:lut atIndex:17];
	[r setFragmentSamplerState:lin atIndex:13];
	if (params) [r setFragmentBytes:params length:bytes atIndex:0];
	for (NSUInteger i = 0; i < in.count; i++) [r setFragmentTexture:in[i] atIndex:i];
	[r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	[r endEncoding];
	[cb commit];
	if (!wait) return 0;
	[cb waitUntilCompleted];
	return (cb.GPUEndTime - cb.GPUStartTime) * 1000.0;
}
int main(int argc, const char **argv) {
	@autoreleasepool {
		if (argc < 8) { printf("usage: see the header\n"); return 2; }
		dev = MTLCreateSystemDefaultDevice();
		id<MTLLibrary> cl = load(@(argv[1])), ll = load(@(argv[2]));
		NSString *dir = @(argv[3]), *name = @(argv[4]);
		int W = atoi(argv[5]), H = atoi(argv[6]);
		BOOL timing = strcmp(argv[7], "time") == 0;
		int mode = argc > 8 ? atoi(argv[8]) : 0;
		NSData *frame = [NSData dataWithContentsOfFile:[dir stringByAppendingFormat:@"/%@.frame", name]];
		NSData *look = [NSData dataWithContentsOfFile:[dir stringByAppendingFormat:@"/%@.look", name]];
		NSData *params = [NSData dataWithContentsOfFile:[dir stringByAppendingFormat:@"/%@.params", name]];
		const int PB = 448;
		int frames = (int) (params.length / PB);
		frameBuf = [dev newBufferWithLength:2048 options:MTLResourceStorageModeShared];
		memcpy(frameBuf.contents, frame.bytes, frame.length);
		lookBuf = [dev newBufferWithBytes:look.bytes length:look.length options:MTLResourceStorageModeShared];
		id<MTLCommandQueue> q = [dev newCommandQueue];
		MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
		sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
		sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
		lin = [dev newSamplerStateWithDescriptor:sd];
		// sky LUT
		lut = tex(MTLPixelFormatRGBA16Float, 128, 80, NO);
		pass(q, pso(ll, @"shade_lut_vs", @"shade_lut_fs", MTLPixelFormatRGBA16Float, MTLPixelFormatInvalid), lut, nil, NULL, 0, @[], YES);
		// bakes
		MTLTextureDescriptor *td = [MTLTextureDescriptor new];
		td.textureType = MTLTextureType3D; td.pixelFormat = MTLPixelFormatRGBA8Unorm; td.width = td.height = td.depth = 64; td.mipmapLevelCount = 7;
		td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite; td.storageMode = MTLStorageModePrivate;
		id<MTLTexture> noise = [dev newTextureWithDescriptor:td];
		MTLTextureDescriptor *wd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:512 height:512 mipmapped:NO];
		wd.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite; wd.storageMode = MTLStorageModePrivate;
		id<MTLTexture> weather = [dev newTextureWithDescriptor:wd];
		{
			NSError *e = nil;
			id<MTLComputePipelineState> bn = [dev newComputePipelineStateWithFunction:[cl newFunctionWithName:@"cloud_bake_noise"] error:&e];
			id<MTLComputePipelineState> bw = [dev newComputePipelineStateWithFunction:[cl newFunctionWithName:@"cloud_bake_weather"] error:&e];
			id<MTLCommandBuffer> cb = [q commandBuffer];
			id<MTLComputeCommandEncoder> c = [cb computeCommandEncoder];
			[c setComputePipelineState:bn]; [c setTexture:noise atIndex:0];
			[c dispatchThreads:MTLSizeMake(64, 64, 64) threadsPerThreadgroup:MTLSizeMake(4, 4, 4)];
			[c setComputePipelineState:bw]; [c setTexture:weather atIndex:0];
			[c dispatchThreads:MTLSizeMake(512, 512, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
			[c endEncoding];
			id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder]; [bl generateMipmapsForTexture:noise]; [bl endEncoding];
			[cb commit]; [cb waitUntilCompleted];
			printf("bakes %.2f ms\n", (cb.GPUEndTime - cb.GPUStartTime) * 1000.0);
		}
		if (strcmp(argv[7], "stats") == 0) {
			// percentiles of each channel of the weather map and the 3D noise
			id<MTLBuffer> wb = [dev newBufferWithLength:512 * 512 * 4 options:MTLResourceStorageModeShared];
			id<MTLBuffer> nb = [dev newBufferWithLength:64 * 64 * 64 * 4 options:MTLResourceStorageModeShared];
			id<MTLCommandBuffer> cb = [q commandBuffer];
			id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
			[bl copyFromTexture:weather sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(512, 512, 1)
				toBuffer:wb destinationOffset:0 destinationBytesPerRow:512 * 4 destinationBytesPerImage:512 * 512 * 4];
			[bl copyFromTexture:noise sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(64, 64, 64)
				toBuffer:nb destinationOffset:0 destinationBytesPerRow:64 * 4 destinationBytesPerImage:64 * 64 * 4];
			[bl endEncoding]; [cb commit]; [cb waitUntilCompleted];
			const char *names[2] = {"weather", "noise3d"};
			id<MTLBuffer> bufs[2] = {wb, nb};
			int counts[2] = {512 * 512, 64 * 64 * 64};
			for (int k = 0; k < 2; k++) {
				const unsigned char *b = bufs[k].contents;
				for (int ch = 0; ch < 4; ch++) {
					int hist[256] = {0};
					for (int i = 0; i < counts[k]; i++) hist[b[i * 4 + ch]]++;
					printf("%s.%c:", names[k], "rgba"[ch]);
					int acc = 0, pi = 0;
					const int ps[9] = {1, 5, 10, 25, 50, 75, 90, 95, 99};
					for (int v = 0; v < 256 && pi < 9; v++) {
						acc += hist[v];
						while (pi < 9 && acc * 100 >= ps[pi] * counts[k]) { printf(" p%d=%.2f", ps[pi], v / 255.0); pi++; }
					}
					printf("\n");
				}
			}
			return 0;
		}
		const float *p0 = params.bytes;
		int hw = (int) p0[32], hh = (int) p0[33], mw = (int) p0[34], mh = (int) p0[35];
		int dw = 128, dh = 64; // CloudConfig.DOME_W / DOME_H (FT2.8: CloudParams.dome.x is the dome's update count, not its width)
		// (v12-opt) CLOUDS_LEAN=1: the march and resolve specialized (CLOUD_FC_DEV / MODE / STYLE) for the first frame's dev bits
		// (lightDir.w), mode bits (shadowDir.w) and style (art.w), as mcclouds.m's lean pipelines
		MTLFunctionConstantValues *lfc = nil;
		if (getenv("CLOUDS_LEAN")) {
			int ldev = (int) p0[63], lmode = (int) p0[103];
			float lstyle = p0[107];
			lfc = [MTLFunctionConstantValues new];
			[lfc setConstantValue:&ldev type:MTLDataTypeInt atIndex:0];
			[lfc setConstantValue:&lmode type:MTLDataTypeInt atIndex:1];
			[lfc setConstantValue:&lstyle type:MTLDataTypeFloat atIndex:2];
			fprintf(stderr, "lean: dev %d mode %d style %g\n", ldev, lmode, lstyle);
		}
		id<MTLRenderPipelineState> march = psoFc(cl, @"cloud_vs", @"cloud_march", MTLPixelFormatRGBA16Float, MTLPixelFormatR32Float, lfc);
		// the resolve and its data target: M3.3 mode bit 1 (CloudParams.shadowDir.w) = cloud_resolve_st with R16Uint (age +
		// distance), else cloud_resolve with R8 (age); CLOUDS_RESOLVE / CLOUDS_DATAFMT (rg16f, r16u, r16f, r16un, r8) override (experiments)
		BOOL st = (((int) p0[103]) & 1) != 0;
		const char *dfe = getenv("CLOUDS_DATAFMT");
		MTLPixelFormat dfmt = dfe ? (strcmp(dfe, "rg16f") == 0 ? MTLPixelFormatRG16Float : strcmp(dfe, "r16u") == 0 ? MTLPixelFormatR16Uint
			: strcmp(dfe, "r16f") == 0 ? MTLPixelFormatR16Float : strcmp(dfe, "r16un") == 0 ? MTLPixelFormatR16Unorm : MTLPixelFormatR8Unorm)
			: st ? MTLPixelFormatR16Uint : MTLPixelFormatR8Unorm;
		const char *rfe = getenv("CLOUDS_RESOLVE");
		id<MTLRenderPipelineState> resolve = psoFc(cl, @"cloud_vs", rfe ? @(rfe) : st ? @"cloud_resolve_st" : @"cloud_resolve", MTLPixelFormatRGBA16Float, dfmt, lfc);
		id<MTLRenderPipelineState> domeP = pso(cl, @"cloud_vs", @"cloud_dome", MTLPixelFormatRGBA16Float, MTLPixelFormatInvalid);
		id<MTLRenderPipelineState> shadowP = pso(cl, @"cloud_vs", @"cloud_shadow", MTLPixelFormatR16Float, MTLPixelFormatInvalid);
		id<MTLRenderPipelineState> comp = pso(cl, @"cloudpreview_vs", @"cloudpreview_fs", MTLPixelFormatRGBA8Unorm, MTLPixelFormatInvalid);
		id<MTLTexture> mc = tex(MTLPixelFormatRGBA16Float, mw, mh, NO), md = tex(MTLPixelFormatR32Float, mw, mh, NO);
		id<MTLTexture> hist[2] = {tex(MTLPixelFormatRGBA16Float, hw, hh, NO), tex(MTLPixelFormatRGBA16Float, hw, hh, NO)};
		id<MTLTexture> data[2] = {tex(dfmt, hw, hh, NO), tex(dfmt, hw, hh, NO)};
		id<MTLTexture> domeT[2] = {tex(MTLPixelFormatRGBA16Float, dw, dh, NO), tex(MTLPixelFormatRGBA16Float, dw, dh, NO)};
		id<MTLTexture> shadow = tex(MTLPixelFormatR16Float, 256, 256, NO);
		int cur = 0, dc = 0;
		double ts = 0, tm = 0, tr = 0, td2 = 0;
		int counted = 0;
		for (int i = 0; i < frames; i++) {
			const void *pp = (const char *) params.bytes + PB * i;
			double a = pass(q, shadowP, shadow, nil, pp, PB, @[weather, noise], timing);
			double b = pass(q, march, mc, md, pp, PB, @[weather, noise], timing);
			double c = pass(q, resolve, hist[cur ^ 1], data[cur ^ 1], pp, PB, @[mc, md, hist[cur], data[cur]], timing);
			cur ^= 1;
			double d = pass(q, domeP, domeT[dc ^ 1], nil, pp, PB, @[weather, noise, domeT[dc]], timing);
			dc ^= 1;
			if (timing && i >= 4) { ts += a; tm += b; tr += c; td2 += d; counted++; }
		}
		if (timing) {
			// warm the GPU up, then time K back-to-back passes of each kind in one command buffer (GPU clocks stay up)
			const int K = 60;
			const void *pp = (const char *) params.bytes + PB * (frames - 1);
			double ms[4];
			for (int rep = 0; rep < 2; rep++) {
				for (int kind = 0; kind < 4; kind++) {
					id<MTLCommandBuffer> cb = [q commandBuffer];
					for (int k = 0; k < K; k++) {
						MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
						id<MTLTexture> o0 = kind == 0 ? shadow : kind == 1 ? mc : kind == 2 ? hist[(cur + k + 1) & 1] : domeT[(dc + k + 1) & 1];
						id<MTLTexture> o1 = kind == 1 ? md : kind == 2 ? data[(cur + k + 1) & 1] : nil;
						rp.colorAttachments[0].texture = o0; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
						if (o1) { rp.colorAttachments[1].texture = o1; rp.colorAttachments[1].loadAction = MTLLoadActionDontCare; rp.colorAttachments[1].storeAction = MTLStoreActionStore; }
						id<MTLRenderCommandEncoder> r = [cb renderCommandEncoderWithDescriptor:rp];
						[r setRenderPipelineState:kind == 0 ? shadowP : kind == 1 ? march : kind == 2 ? resolve : domeP];
						[r setFragmentBuffer:frameBuf offset:0 atIndex:16]; [r setFragmentBuffer:lookBuf offset:0 atIndex:17];
						[r setFragmentTexture:lut atIndex:17]; [r setFragmentSamplerState:lin atIndex:13];
						[r setFragmentBytes:pp length:PB atIndex:0];
						if (kind == 2) { [r setFragmentTexture:mc atIndex:0]; [r setFragmentTexture:md atIndex:1]; [r setFragmentTexture:hist[(cur + k) & 1] atIndex:2]; [r setFragmentTexture:data[(cur + k) & 1] atIndex:3]; }
						else { [r setFragmentTexture:weather atIndex:0]; [r setFragmentTexture:noise atIndex:1]; if (kind == 3) [r setFragmentTexture:domeT[(dc + k) & 1] atIndex:2]; }
						[r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
						[r endEncoding];
					}
					[cb commit]; [cb waitUntilCompleted];
					ms[kind] = (cb.GPUEndTime - cb.GPUStartTime) * 1000.0 / K;
				}
			}
			printf("%s history %dx%d march %dx%d: shadow %.3f march %.3f resolve %.3f dome %.3f ms, total %.3f\n", name.UTF8String, hw, hh, mw, mh,
				ms[0], ms[1], ms[2], ms[3], ms[0] + ms[1] + ms[2] + ms[3]);
			(void) ts; (void) tm; (void) tr; (void) td2; (void) counted;
			return 0;
		}
		// CLOUDS_DUMP=<file>: the last march target (RGBA16F, march size) raw to a file (instrumented experiments)
		const char *dump = getenv("CLOUDS_DUMP");
		if (dump) {
			id<MTLTexture> sh = tex(MTLPixelFormatRGBA16Float, mw, mh, YES);
			id<MTLCommandBuffer> cb = [q commandBuffer];
			id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
			[bl copyFromTexture:mc toTexture:sh];
			[bl endEncoding]; [cb commit]; [cb waitUntilCompleted];
			NSMutableData *raw = [NSMutableData dataWithLength:mw * mh * 8];
			[sh getBytes:raw.mutableBytes bytesPerRow:mw * 8 fromRegion:MTLRegionMake2D(0, 0, mw, mh) mipmapLevel:0];
			[raw writeToFile:@(dump) atomically:NO];
		}
		// Optional raw shadow-map readback for clear-weather regression checks (R16Float transmission).
		const char *shadowDump = getenv("CLOUDS_SHADOW_DUMP");
		if (shadowDump) {
			id<MTLTexture> readback = tex(MTLPixelFormatR16Float, 256, 256, YES);
			id<MTLCommandBuffer> cb = [q commandBuffer];
			id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
			[bl copyFromTexture:shadow toTexture:readback];
			[bl endEncoding]; [cb commit]; [cb waitUntilCompleted];
			NSMutableData *raw = [NSMutableData dataWithLength:256 * 256 * 2];
			[readback getBytes:raw.mutableBytes bytesPerRow:256 * 2 fromRegion:MTLRegionMake2D(0, 0, 256, 256) mipmapLevel:0];
			[raw writeToFile:@(shadowDump) atomically:NO];
		}
		// composite
		float *fp = (float *) frameBuf.contents;
		fp[848 / 4] = W; fp[848 / 4 + 1] = H; fp[848 / 4 + 2] = 1.0f / W; fp[848 / 4 + 3] = 1.0f / H;
		id<MTLTexture> out = tex(MTLPixelFormatRGBA8Unorm, W, H, YES);
		int m4[4] = {mode, 0, 0, 0};
		pass(q, comp, out, nil, m4, 16, @[hist[cur], domeT[dc], shadow], YES);
		NSMutableData *px = [NSMutableData dataWithLength:W * H * 4];
		[out getBytes:px.mutableBytes bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
		CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
		CGContextRef ctx = CGBitmapContextCreate(px.mutableBytes, W, H, 8, W * 4, cs, kCGImageAlphaNoneSkipLast);
		CGImageRef img = CGBitmapContextCreateImage(ctx);
		CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef) [NSURL fileURLWithPath:@(argv[7])], (__bridge CFStringRef) UTTypePNG.identifier, 1, NULL);
		CGImageDestinationAddImage(dst, img, NULL);
		CGImageDestinationFinalize(dst);
	}
	return 0;
}
