// Copyright 2026 mcopt-shade contributors. Licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0). Dev tool for mcopt native shading, not part of the mod.
// owncheck FILE.metal [shade [FRAG.metal ...]]   (check.sh builds it and runs it on OwnDump's sources)
// Compiles mcopt's own terrain library like mcown.m mco_new (MSL 3.0, fast math), makes its compute kernels and base stages,
// then builds render pipeline states for the draw kinds the indie profile uses, specialized as ownStage does (with
// SHADE_OWN_HDR, function constant 40, when "shade" is given and the colour target is HDR), against RGBA16Float, RG11B10Float
// and BGRA8Unorm colour + Depth32Float. Each FRAG.metal (ShadeMsl.ownFragmentSource; a name with "_t_" = the translucent
// layer's) is compiled as its own library and its shade_own_fs linked with own_vs as mcown.m does (opaque: solid and cutout
// kinds; translucent: the translucent ones) against the HDR targets. Prints OK or the errors.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static id<MTLDevice> dev;
static id<MTLLibrary> lib, fragLib;
static int fails;

static id<MTLFunction> fncIn(id<MTLLibrary> from, NSString *name, MTLFunctionConstantValues *cv) {
	NSError *e = nil;
	id<MTLFunction> f = cv ? [from newFunctionWithName:name constantValues:cv error:&e] : [from newFunctionWithName:name];
	if (!f) { printf("FAIL function %s: %s\n", name.UTF8String, e ? e.localizedDescription.UTF8String : "missing"); fails++; }
	return f;
}

static id<MTLFunction> fnc(NSString *name, MTLFunctionConstantValues *cv) { return fncIn(lib, name, cv); }

// (1.2.7) the shaded library's pipelines: their cutout kinds' own_vs waves foliage (F_SWAY), as mcown.m ownSwayKind
static int gShade;

// ownStage's constants for kind (vertex 1: own_vs, 0: the fragment stage)
static MTLFunctionConstantValues *stageConstants(int kind, int vertex, int hdr) {
	int frag = kind & 15, vsMode = (kind >> 4) & 3, translucent = frag == 3;
	bool half = (kind >> 18) & 1, lean = (kind >> 19) & 1, nonidx = (kind >> 20) & 1, rev = (kind >> 22) & 1, quads = (kind >> 7) & 1,
		tight = (kind >> 25) & 1, posonly = (kind >> 26) & 1, occA = (kind >> 27) & 1, occB = (kind >> 28) & 1, oracle = (kind >> 30) & 1,
		fogvert = (kind >> 14) & 1, fogvertAll = (kind >> 15) & 1, fogvertT = (kind >> 13) & 1, qflat = (kind >> 12) & 1,
		group = vertex == 1 && ((kind >> 11) & 1);
	MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
	[cv setConstantValue:&half type:MTLDataTypeBool atIndex:9];
	[cv setConstantValue:&lean type:MTLDataTypeBool atIndex:10];
	[cv setConstantValue:&nonidx type:MTLDataTypeBool atIndex:11];
	[cv setConstantValue:&rev type:MTLDataTypeBool atIndex:12];
	[cv setConstantValue:&tight type:MTLDataTypeBool atIndex:13];
	[cv setConstantValue:&posonly type:MTLDataTypeBool atIndex:14];
	[cv setConstantValue:&occA type:MTLDataTypeBool atIndex:15];
	[cv setConstantValue:&occB type:MTLDataTypeBool atIndex:16];
	[cv setConstantValue:&oracle type:MTLDataTypeBool atIndex:17];
	[cv setConstantValue:&fogvert type:MTLDataTypeBool atIndex:18];
	[cv setConstantValue:&fogvertAll type:MTLDataTypeBool atIndex:19];
	[cv setConstantValue:&qflat type:MTLDataTypeBool atIndex:21];
	[cv setConstantValue:&fogvertT type:MTLDataTypeBool atIndex:20];
	if (group) [cv setConstantValue:&group type:MTLDataTypeBool atIndex:25];
	if (vertex == 1 && gShade && (frag == 1 || frag == 5 || frag == 6)) { bool t = true; [cv setConstantValue:&t type:MTLDataTypeBool atIndex:26]; }
	if (vertex) {
		bool cmp = true, fatv = false, clipv = false, tr = translucent != 0;
		[cv setConstantValue:&cmp type:MTLDataTypeBool atIndex:1];
		[cv setConstantValue:&fatv type:MTLDataTypeBool atIndex:2];
		[cv setConstantValue:&clipv type:MTLDataTypeBool atIndex:3];
		[cv setConstantValue:&tr type:MTLDataTypeBool atIndex:4];
		[cv setConstantValue:&vsMode type:MTLDataTypeInt atIndex:7];
		[cv setConstantValue:&quads type:MTLDataTypeBool atIndex:8];
	} else {
		bool cut = frag == 1 || frag == 3 || frag == 5, lvl = frag == 4 || frag == 5;
		float limit = frag == 3 ? 0.1f : 0.5f;
		[cv setConstantValue:&cut type:MTLDataTypeBool atIndex:0];
		[cv setConstantValue:&limit type:MTLDataTypeFloat atIndex:5];
		[cv setConstantValue:&lvl type:MTLDataTypeBool atIndex:6];
		if (hdr) { bool t = true; [cv setConstantValue:&t type:MTLDataTypeBool atIndex:40]; }
	}
	return cv;
}

static void pso(int kind, MTLPixelFormat color, int shade) {
	int frag = kind & 15;
	gShade = shade;
	int hdr = shade && (color == MTLPixelFormatRGBA16Float || color == MTLPixelFormatRG11B10Float);
	NSString *fname = frag == 6 ? @"own_fs_alpha" : frag == 2 ? @"own_fs_flat" : @"own_fs";
	MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
	pd.vertexFunction = fnc(@"own_vs", stageConstants(kind, 1, 0));
	pd.fragmentFunction = fragLib ? fncIn(fragLib, @"shade_own_fs", stageConstants(kind, 0, hdr)) : fnc(fname, stageConstants(kind, 0, hdr));
	if (!pd.vertexFunction || !pd.fragmentFunction) return;
	pd.colorAttachments[0].pixelFormat = color;
	pd.colorAttachments[0].writeMask = frag == 6 ? MTLColorWriteMaskNone : MTLColorWriteMaskAll;
	if (frag == 3) {
		pd.colorAttachments[0].blendingEnabled = YES;
		pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
		pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	}
	pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
	pd.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
	NSError *e = nil;
	MTLAutoreleasedRenderPipelineReflection refl = nil;
	id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:pd options:MTLPipelineOptionBindingInfo reflection:&refl error:&e];
	if (!p) { printf("FAIL pso kind 0x%x format %d hdr %d: %s\n", kind, (int) color, hdr, e.localizedDescription.UTF8String); fails++; return; }
	// fragment bindings: report the buffer / texture slots the stage reads (they must be the shade layout with "shade")
	NSMutableString *b = [NSMutableString string];
	for (id<MTLBinding> x in refl.fragmentBindings) if (x.used) [b appendFormat:@" %@:%d", x.type == MTLBindingTypeBuffer ? @"b" : x.type == MTLBindingTypeTexture ? @"t" : x.type == MTLBindingTypeSampler ? @"s" : @"?", (int) [(id) x index]];
	printf("OK   pso kind 0x%08x format %3d hdr %d %s fragment%s\n", kind, (int) color, hdr, fragLib ? "shade_own_fs" : "own", b.UTF8String);
}

int main(int argc, const char **argv) {
	@autoreleasepool {
		if (argc < 2) { fprintf(stderr, "usage: owncheck FILE.metal [shade [FRAG.metal ...]]\n"); return 2; }
		int shade = argc > 2 && strcmp(argv[2], "shade") == 0;
		dev = MTLCreateSystemDefaultDevice();
		NSString *src = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[1]] encoding:NSUTF8StringEncoding error:nil];
		MTLCompileOptions *o = [MTLCompileOptions new];
		o.languageVersion = MTLLanguageVersion3_0;
		o.mathMode = MTLMathModeFast;
		NSError *e = nil;
		NSDate *t0 = [NSDate date];
		lib = [dev newLibraryWithSource:src options:o error:&e];
		double ms = -[t0 timeIntervalSinceNow] * 1000;
		if (!lib) { printf("FAIL compile %s\n%s\n", argv[1], e.localizedDescription.UTF8String); return 1; }
		printf("OK   compile %s (%.0f ms)\n", argv[1], ms);
		const char *kernels[] = {"own_reset", "own_cull", "own_finish", "own_clear_vis", "own_hiz0", "own_hizn", "own_occ", "own_finish_b", "own_q_reset",
			"own_q_size", "own_q_a", "own_q_b", "own_q_finish", "own_clear_words", "frag_reset", "frag_cull", "frag_finish", "own_hiz_tile", "own_hiz_pad",
			"own_so_clear", "own_so_raster", "own_so_mip0", "own_so_fill", "own_qstat", "own_q_pre", "own_cull_r", "own_q_bu", "own_q_size2", "own_q_bq", "own_q_bf", "own_hiz_top", "own_hiz_tile_g", "own_qrec_verify"};
		t0 = [NSDate date];
		for (int i = 0; i < (int) (sizeof kernels / sizeof kernels[0]); i++) {
			id<MTLFunction> f = fnc([NSString stringWithUTF8String:kernels[i]], nil);
			if (f && ![dev newComputePipelineStateWithFunction:f error:&e]) { printf("FAIL kernel %s: %s\n", kernels[i], e.localizedDescription.UTF8String); fails++; }
		}
		printf("OK   %d kernels (%.0f ms)\n", (int) (sizeof kernels / sizeof kernels[0]), -[t0 timeIntervalSinceNow] * 1000);
		if (shade) {
			// (v12 P4) the shadow pass's own stages (mcshadow.m mc_shadow_own_init / mc_shadow_own_tint_init): depth-only casters
			// (Depth16Unorm), the coloured shadows' cull kernels and tint vertex stage linked with shade/shadow.metal's
			// shadow_tint_fs (OWNCHECK_SHADOW = its path, from check.sh), for compact / full vertices and FAT lists
			int failsBefore = fails;
			const char *shadowPath = getenv("OWNCHECK_SHADOW");
			NSString *shadowSrc = shadowPath ? [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:shadowPath] encoding:NSUTF8StringEncoding error:nil] : nil;
			id<MTLLibrary> shadowLib = shadowSrc ? [dev newLibraryWithSource:shadowSrc options:o error:&e] : nil;
			if (shadowPath && !shadowLib) { printf("FAIL compile %s\n", shadowPath); fails++; }
			for (int compact = 0; compact < 2; compact++) {
				for (int fat = 0; fat < 2; fat++) {
					MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
					bool cc = compact, ff = fat;
					[cv setConstantValue:&cc type:MTLDataTypeBool atIndex:1];
					[cv setConstantValue:&ff type:MTLDataTypeBool atIndex:2];
					MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
					pd.vertexFunction = fnc(@"own_shadow_vs", cv);
					pd.depthAttachmentPixelFormat = MTLPixelFormatDepth16Unorm;
					pd.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
					if (pd.vertexFunction && ![dev newRenderPipelineStateWithDescriptor:pd error:&e]) { printf("FAIL own_shadow_vs: %s\n", e.localizedDescription.UTF8String); fails++; }
					pd.fragmentFunction = fnc(@"own_shadow_cutout_fs", nil);
					if (pd.vertexFunction && pd.fragmentFunction && ![dev newRenderPipelineStateWithDescriptor:pd error:&e]) { printf("FAIL own_shadow_cutout_fs: %s\n", e.localizedDescription.UTF8String); fails++; }
					if (fat) continue;
					id<MTLFunction> tc = fnc(@"own_shadow_tcull", cv);
					if (tc && ![dev newComputePipelineStateWithFunction:tc error:&e]) { printf("FAIL own_shadow_tcull: %s\n", e.localizedDescription.UTF8String); fails++; }
					if (!shadowLib) continue;
					MTLRenderPipelineDescriptor *td = [MTLRenderPipelineDescriptor new];
					td.vertexFunction = fnc(@"own_shadow_tint_vs", cv);
					td.fragmentFunction = fncIn(shadowLib, @"shadow_tint_fs", nil);
					td.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
					td.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
					if (td.vertexFunction && td.fragmentFunction && ![dev newRenderPipelineStateWithDescriptor:td error:&e]) { printf("FAIL own_shadow_tint_vs + shadow_tint_fs: %s\n", e.localizedDescription.UTF8String); fails++; }
				}
			}
			for (NSString *k in @[@"own_shadow_tcull_reset", @"own_shadow_tcull_finish"]) {
				id<MTLFunction> f = fnc(k, nil);
				if (f && ![dev newComputePipelineStateWithFunction:f error:&e]) { printf("FAIL %s: %s\n", k.UTF8String, e.localizedDescription.UTF8String); fails++; }
			}
			printf("%s  shadow pass stages (casters, cutout, coloured-shadow cull and tint%s)\n", fails == failsBefore ? "OK  " : "FAIL", shadowLib ? "" : " without shadow_tint_fs: no OWNCHECK_SHADOW");
		}
		// base stages (mco_new): own_fs with constants 0, 5, 6 only
		for (int c = 0; c < 5; c++) {
			MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
			bool cut = c == 1 || c == 2 || c == 4, lvl = c >= 3;
			float limit = c == 2 ? 0.1f : 0.5f;
			[cv setConstantValue:&cut type:MTLDataTypeBool atIndex:0];
			[cv setConstantValue:&limit type:MTLDataTypeFloat atIndex:5];
			[cv setConstantValue:&lvl type:MTLDataTypeBool atIndex:6];
			fnc(@"own_fs", cv);
		}
		// draw kinds: 0 solid, 1 cutout, 3 translucent, 6 the cutout pre-pass; F_HALF (bit 18), F_LEAN (19), F_TIGHT (25), F_GROUP (11),
		// F_QFLAT (12), F_FOGVERT_T (13)
		int kinds[] = {0, 1, 3, 6, 1 << 18, 1 | 1 << 18, 3 | 1 << 18, (1 << 18) | (1 << 19), 1 | (1 << 18) | (1 << 19), (1 << 18) | (1 << 25),
			(1 << 18) | (1 << 11), (1 << 18) | (1 << 12), 3 | (1 << 13) | (1 << 18)};
		MTLPixelFormat formats[] = {MTLPixelFormatRGBA16Float, MTLPixelFormatRG11B10Float, MTLPixelFormatBGRA8Unorm};
		t0 = [NSDate date];
		for (int k = 0; k < (int) (sizeof kinds / sizeof kinds[0]); k++)
			for (int f = 0; f < 3; f++) pso(kinds[k], formats[f], shade);
		printf("%s  %d failures (pipelines %.0f ms)\n", fails ? "FAIL" : "OK  ", fails, -[t0 timeIntervalSinceNow] * 1000);
		// the shaded fragment stage's libraries, linked with own_vs
		int oKinds[] = {0, 1, 1 << 18, 1 | 1 << 18, (1 << 18) | (1 << 19), 1 | (1 << 18) | (1 << 19), (1 << 18) | (1 << 25), (1 << 18) | (1 << 11), (1 << 18) | (1 << 12)};
		int tKinds[] = {3, 3 | 1 << 18, 3 | (1 << 18) | (1 << 19), 3 | (1 << 13) | (1 << 18)};
		for (int a = 3; a < argc; a++) {
			int failsBefore = fails;
			NSString *fsrc = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[a]] encoding:NSUTF8StringEncoding error:nil];
			NSDate *t1 = [NSDate date];
			fragLib = [dev newLibraryWithSource:fsrc options:o error:&e];
			if (!fragLib) { printf("FAIL compile %s\n%s\n", argv[a], e.localizedDescription.UTF8String); fails++; continue; }
			double fms = -[t1 timeIntervalSinceNow] * 1000;
			bool translucent = strstr(argv[a], "_t_") != NULL;
			int *ks = translucent ? tKinds : oKinds;
			int nk = translucent ? (int) (sizeof tKinds / sizeof tKinds[0]) : (int) (sizeof oKinds / sizeof oKinds[0]);
			for (int k = 0; k < nk; k++)
				for (int f = 0; f < 2; f++) pso(ks[k], formats[f], 1);
			printf("%s  %s (%.0f ms compile)\n", fails == failsBefore ? "OK  " : "FAIL", argv[a], fms);
			fragLib = nil;
		}
		return fails ? 1 : 0;
	}
}
