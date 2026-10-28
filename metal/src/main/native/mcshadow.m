// Copyright 2026 mcopt-shade contributors. Licensed under the Apache License, Version 2.0 (LICENSE).
//
// Sun shadow map for the native shading pipeline (-Dmcopt.shade=true, mcopt.metal.shade.shadow.ShadowPass): owns the
// cascade depth array, the compare sampler receivers bind at sampler(12), and the depth-only passes that replay Sodium's
// solid and cutout terrain from the light (shaders: resources/mcopt/shade/shadow.metal). Each cascade is its own render
// encoder on the frame's command buffer (mc_frame_cmd), encoded before the frame's first world pass, so the game's passes
// that follow never lose an encoder merge. ARC is off: everything here is retained/released by hand.
#import "mcmetal.h"
#include <string.h>

#define CHUNK_QUADS 32     // ShadowCasters.CHUNK_QUADS (32: a third of the vertex launches were padding with 64)
#define QUAD_INDICES (CHUNK_QUADS * 6)  // {0, 1, 2, 2, 3, 0} per quad
#define DRAW_BYTES 24     // per draw from Java: arena MTLBuffer (8), first chunk (4), chunk count (4), kind (4: 0 solid, 1 cutout; + 256: top-down), pad (4)

// M3 entity casters (mc_shadow_entity_*): the frame's entity draws, recorded in the main pass, copied at the end of the
// world (the game's vertex buffers are pooled per frame) and drawn into the next frame's near cascade.
#define ENT_MAX 4096
#define ENT_BYTES (12u << 20)
typedef struct {
	id<MTLBuffer> src;      // pending: the game's vertex buffer (retained until the copy is encoded); nil once copied
	id<MTLTexture> tex;     // retained while listed
	uint64_t srcOffset;     // pending: byte offset of the draw's first vertex
	uint32_t dst;           // ready: byte offset in casters
	uint32_t quads, stride, uvOffset;
	float cutoff;
} EntDraw;

typedef struct {
	id<MTLDevice> device;
	id<MTLLibrary> library;
	id<MTLRenderPipelineState> solid, cutout;
	id<MTLRenderPipelineState> entity;   // M3: entity casters (shadow_entity_vs / shadow_entity_fs)
	id<MTLBuffer> casters;               // ENT_BYTES, private: last frame's entity vertices
	EntDraw pending[ENT_MAX], ready[ENT_MAX];
	int pendingCount, readyCount;
	uint32_t pendingBytes;
	float shift[3];                      // camera-relative offset of the ready casters for this frame (set by Java)
	id<MTLRenderPipelineState> debug;  // made for the format of the target the debug view goes into
	MTLPixelFormat debugFormat;
	id<MTLTexture> debugTiles;         // the debug view's tiles, drawn here and blitted into the target
	id<MTLDepthStencilState> depthWrite;
	id<MTLSamplerState> compare;       // receivers: sampler(12)
	id<MTLSamplerState> atlasSampler;  // cutout test: nearest, level 0
	id<MTLTexture> map;                // Depth16Unorm or Depth32Float 2D array, one slice per cascade
	MTLPixelFormat format;
	id<MTLBuffer> quadIndices, quadIndicesRev; // quadIndicesRev (FT2.8): the chunk's quads last to first
	int resolution, layers;
	// M3 coloured shadows (mc_shadow_tint_*): the near cascade's translucent casters into a tint map
	id<MTLRenderPipelineState> tint;
	id<MTLTexture> tintMap;
	bool tintDirty;  // the map holds casters (it is cleared once when they're gone)
	id<MTLTexture> tintLite;  // M3.3 pricing (mcopt.shade.tintDev 8): a smaller tint map, same format; nil until asked for
	bool tintLiteDirty;
	// M3.3 (mcopt.shade.shadowFarSpread): a second map of the same shape. The far cascade is drawn a quarter per frame into
	// back's far slice; once complete, mc_shadow_swap makes it the map receivers bind (map <-> back). nil until first used.
	id<MTLTexture> back;
	// M3.3 (mcopt.shade.shadowTimes): GPU timers per shadow pass kind (SHADOW_TIME_KINDS), a ring of SHADOW_TIME_RING frames
	id<MTLCounterSampleBuffer> times;
	int timesTried, timeFrame, timeSlot;
	MTLTimestamp cpu0, gpu0;
	double timeSum[4];
	int timeN[4], timeCount;
	uint64_t timeLast[4];
	int timeRan[4];  // per ring slot: bit k = pass kind k was encoded with that slot's samples
	// mcopt 0.3 port (v12): mcopt's own terrain as casters (own/terrain.metal own_shadow_vs / own_shadow_cutout_fs, built from
	// own's library by mc_shadow_own_init), drawn from OwnTerrain.shadowCull's lists with their indirect arguments
	id<MTLRenderPipelineState> ownSolid, ownCutout;
	id<MTLBuffer> ownIndices;  // {0, 1, 2, 2, 3, 0} + 4q for 64 quads (own's draw units)
	// (v12) own terrain's coloured-shadow casters (mc_shadow_own_tint_init): own_shadow_tint_vs linked with shadow_tint_fs, the
	// translucent units' cull (own_shadow_tcull_reset / own_shadow_tcull / own_shadow_tcull_finish), its list and indirect arguments,
	// and OWN_TINT_RING slots of {x0 negated, y0 negated, x1, y1 (ordered-int bits), quads, units} the pass writes for ShadowPass
	id<MTLRenderPipelineState> ownTint;
	id<MTLComputePipelineState> ownTcullReset, ownTcull, ownTcullFinish;
	id<MTLBuffer> ownTintList, ownTintArgs, ownTintRect;
	uint32_t ownTintCap;
} Shadow;

#define OWN_TINT_RING 8

// own/terrain.metal OwnShadowFrame
typedef struct { int32_t camBlock[4]; float camOffset[4]; uint32_t listBase, flags, part, parts; } OwnShadowFrame;

// A cascade's own-terrain draw (Java ShadowPass writes it): the buffers of OwnTerrain.shadowBuffers(slot), what to draw, and
// own_shadow_vs' OwnShadowFrame (listBase and the plant bit set per list here).
typedef struct {
	id<MTLBuffer> arena, sections, recs, lists, args;
	uint32_t listCap;
	uint32_t solid;   // 1: draw the solid list
	uint32_t cutout;  // 0 not drawn, 1 with the alpha test, 2 as opaque without the any-facing units (far cascade)
	uint32_t classes; // (P8) 0, or the size classes per layer (OwnTerrain.shadowClasses: lists layer * classes + class, draws at uint 32)
	OwnShadowFrame frame;
} OwnShadowDraw;

// (v12) the tint pass's own-terrain casters (Java ShadowPass writes it): the buffers of OwnTerrain.shadowBuffers(0), the rect
// slot this pass writes (0 .. OWN_TINT_RING - 1), own/terrain.metal's OwnTcullFrame (the cascade's sides and depth range,
// camera, view distance, section count; cap filled here) and own_shadow_tint_vs' OwnShadowFrame (camera block and offset).
#define OWN_TCULL_BYTES 160
typedef struct {
	id<MTLBuffer> arena, sections, recs;
	uint32_t slot;
	uint32_t draw;  // 0: the cull only (its slot), no tint pass for own's units (none were listed lately and the map is clean)
	uint8_t cull[OWN_TCULL_BYTES];
	OwnShadowFrame frame;
} OwnShadowTint;

#define SHADOW_TIME_RING 4
#define SHADOW_TIME_KINDS 4  // 0 near cascade, 1 far cascade (whole), 2 far cascade (one spread part), 3 tint pass

static void copyErr(NSError *e, const char *fallback, char *err, int errCap) {
	strlcpy(err, e ? e.description.UTF8String : fallback, errCap);
}

static id<MTLRenderPipelineState> depthOnly(Shadow *s, NSString *vs, NSString *fs, NSError **e) {
	MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor new] autorelease];
	pd.label = vs;
	pd.vertexFunction = [[s->library newFunctionWithName:vs] autorelease];
	if (fs) pd.fragmentFunction = [[s->library newFunctionWithName:fs] autorelease];
	pd.depthAttachmentPixelFormat = s->format;
	pd.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
	return [s->device newRenderPipelineStateWithDescriptor:pd error:e];
}

void mc_shadow_free(Shadow *s);

// source: shadow.metal. resolution: per cascade (square). depthBits: 16 (Depth16Unorm) or 32 (Depth32Float). Returns NULL
// with err filled on failure.
Shadow *mc_shadow_new(Ctx *ctx, const char *source, int resolution, int layers, int depthBits, char *err, int errCap) {
	@autoreleasepool {
		Shadow *s = calloc(1, sizeof(Shadow));
		s->device = ctx->device;
		s->resolution = resolution;
		s->layers = layers;
		s->format = depthBits == 16 ? MTLPixelFormatDepth16Unorm : MTLPixelFormatDepth32Float;
		MTLCompileOptions *o = [[MTLCompileOptions new] autorelease];
		o.languageVersion = MTLLanguageVersion3_0;
		o.mathMode = mc_math();
		NSError *e = nil;
		s->library = [ctx->device newLibraryWithSource:[NSString stringWithUTF8String:source] options:o error:&e];
		if (s->library) s->solid = depthOnly(s, @"shadow_vs", nil, &e);
		if (s->solid) s->cutout = depthOnly(s, @"shadow_cutout_vs", @"shadow_cutout_fs", &e);
		if (!s->cutout) {
			copyErr(e, "shadow pipelines failed", err, errCap);
			mc_shadow_free(s);
			return NULL;
		}

		MTLDepthStencilDescriptor *dd = [[MTLDepthStencilDescriptor new] autorelease];
		dd.depthCompareFunction = MTLCompareFunctionGreater;  // reversed Z: nearer the light = larger
		dd.depthWriteEnabled = YES;
		s->depthWrite = [ctx->device newDepthStencilStateWithDescriptor:dd];

		MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor new] autorelease];
		sd.minFilter = MTLSamplerMinMagFilterLinear;  // hardware 2x2 PCF per tap
		sd.magFilter = MTLSamplerMinMagFilterLinear;
		sd.mipFilter = MTLSamplerMipFilterNotMipmapped;
		sd.sAddressMode = MTLSamplerAddressModeClampToBorderColor;
		sd.tAddressMode = MTLSamplerAddressModeClampToBorderColor;
		sd.borderColor = MTLSamplerBorderColorOpaqueBlack;  // depth 0 outside the map: nothing there casts
		sd.compareFunction = MTLCompareFunctionGreaterEqual;  // lit when receiver depth >= caster depth (reversed Z)
		sd.label = @"mcopt shadow compare";
		s->compare = [ctx->device newSamplerStateWithDescriptor:sd];

		MTLSamplerDescriptor *ad = [[MTLSamplerDescriptor new] autorelease];
		ad.minFilter = MTLSamplerMinMagFilterNearest;
		ad.magFilter = MTLSamplerMinMagFilterNearest;
		ad.mipFilter = MTLSamplerMipFilterNotMipmapped;
		ad.sAddressMode = MTLSamplerAddressModeClampToEdge;
		ad.tAddressMode = MTLSamplerAddressModeClampToEdge;
		s->atlasSampler = [ctx->device newSamplerStateWithDescriptor:ad];

		MTLTextureDescriptor *td = [[MTLTextureDescriptor new] autorelease];
		td.textureType = MTLTextureType2DArray;
		td.pixelFormat = s->format;
		td.width = resolution;
		td.height = resolution;
		td.arrayLength = layers;
		td.storageMode = MTLStorageModePrivate;
		td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
		s->map = [ctx->device newTextureWithDescriptor:td];
		s->map.label = @"mcopt shadow map";

		uint16_t indices[QUAD_INDICES];
		static const uint16_t corners[6] = {0, 1, 2, 2, 3, 0};
		for (int q = 0, i = 0; q < CHUNK_QUADS; q++) {
			for (int c = 0; c < 6; c++) indices[i++] = (uint16_t) (q * 4 + corners[c]);
		}
		s->quadIndices = [ctx->device newBufferWithBytes:indices length:sizeof indices options:MTLResourceStorageModeShared];
		// (FT2.8, audit idx 84) the same quads last to first (each quad's corners, so its winding, kept): a chunk drawn top-down
		for (int q = 0, i = 0; q < CHUNK_QUADS; q++) {
			for (int c = 0; c < 6; c++) indices[i++] = (uint16_t) ((CHUNK_QUADS - 1 - q) * 4 + corners[c]);
		}
		s->quadIndicesRev = [ctx->device newBufferWithBytes:indices length:sizeof indices options:MTLResourceStorageModeShared];
		if (!s->map || !s->quadIndices || !s->compare || !s->depthWrite) {
			strlcpy(err, "shadow resources failed", errCap);
			mc_shadow_free(s);
			return NULL;
		}
		return s;
	}
}

static void entClear(EntDraw *list, int *count) {
	for (int i = 0; i < *count; i++) {
		[list[i].src release];
		[list[i].tex release];
		list[i].src = nil;
		list[i].tex = nil;
	}
	*count = 0;
}

// own's library (mco_library): its shadow pipelines, compact / FAT as own was built. 0 = ready, 1 = failed (err filled).
int mc_shadow_own_init(Shadow *s, id<MTLLibrary> lib, int compact, int fat, char *err, int errCap) {
	if (!s || !lib) return 1;
	if (s->ownSolid) return 0;
	@autoreleasepool {
		MTLFunctionConstantValues *cv = [[MTLFunctionConstantValues new] autorelease];
		bool c = compact != 0, f = fat != 0;
		[cv setConstantValue:&c type:MTLDataTypeBool atIndex:1];
		[cv setConstantValue:&f type:MTLDataTypeBool atIndex:2];
		NSError *e = nil;
		id<MTLFunction> vs = [[lib newFunctionWithName:@"own_shadow_vs" constantValues:cv error:&e] autorelease];
		id<MTLFunction> fs = vs ? [[lib newFunctionWithName:@"own_shadow_cutout_fs"] autorelease] : nil;
		if (!vs || !fs) {
			copyErr(e, "own shadow functions missing", err, errCap);
			return 1;
		}
		MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor new] autorelease];
		pd.label = @"mcopt shadow own solid";
		pd.vertexFunction = vs;
		pd.depthAttachmentPixelFormat = s->format;
		pd.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
		id<MTLRenderPipelineState> solid = [s->device newRenderPipelineStateWithDescriptor:pd error:&e];
		pd.label = @"mcopt shadow own cutout";
		pd.fragmentFunction = fs;
		id<MTLRenderPipelineState> cutout = solid ? [s->device newRenderPipelineStateWithDescriptor:pd error:&e] : nil;
		if (!cutout) {
			[solid release];
			copyErr(e, "own shadow pipelines failed", err, errCap);
			return 1;
		}
		uint16_t idx[64 * 6];
		for (int q = 0; q < 64; q++) {
			uint16_t b = (uint16_t) (q * 4);
			uint16_t k[6] = {b, (uint16_t) (b + 1), (uint16_t) (b + 2), (uint16_t) (b + 2), (uint16_t) (b + 3), b};
			memcpy(idx + q * 6, k, sizeof k);
		}
		s->ownIndices = [s->device newBufferWithBytes:idx length:sizeof idx options:MTLResourceStorageModeShared];
		s->ownSolid = solid;
		s->ownCutout = cutout;
	}
	return 0;
}

int mco_sway_bind(id<MTLRenderCommandEncoder> r, int b, int t, int moves);  // (mcown.m, mcopt-shade 1.2.7)

// The own-terrain lists of d into the open cascade encoder r (the cutout's atlas bound at fragment texture 0 by the caller).
static void ownDraw(Shadow *s, id<MTLRenderCommandEncoder> r, const OwnShadowDraw *d, id<MTLTexture> atlas) {
	if (!d || !s->ownSolid || !d->arena || !d->args) return;
	int sway = mco_sway_bind(r, 6, 1, 1);  // (1.2.7: own_shadow_vs' foliage arguments, always bound)
	[r setVertexBuffer:d->arena offset:0 atIndex:0];
	[r setVertexBuffer:d->sections offset:0 atIndex:1];
	[r setVertexBuffer:d->recs offset:0 atIndex:2];
	[r setVertexBuffer:d->lists offset:0 atIndex:5];
	for (int layer = 0; layer < 2; layer++) {
		uint32_t how = layer == 0 ? d->solid : d->cutout;
		if (!how || (how == 1 && layer == 1 && !atlas)) continue;
		OwnShadowFrame f = d->frame;
		f.listBase = (uint32_t) layer * d->listCap;
		if (layer == 1 && how == 2) f.flags |= 1u;
		if (layer == 1 && how == 1 && sway) f.flags |= 4u;  // (1.2.7: the alpha-tested cutout's foliage waves as own_vs waves it)
		[r setRenderPipelineState:layer == 1 && how == 1 ? s->ownCutout : s->ownSolid];
		if (d->classes > 0) {  // (P8) a draw per size class, each its own quads an instance
			for (uint32_t c = 0; c < d->classes; c++) {
				uint32_t id = (uint32_t) layer * d->classes + c;
				f.listBase = id * d->listCap;
				[r setVertexBytes:&f length:sizeof f atIndex:4];
				[r drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexType:MTLIndexTypeUInt16 indexBuffer:s->ownIndices indexBufferOffset:0
					indirectBuffer:d->args indirectBufferOffset:(NSUInteger) (32 + id * 5) * 4];
			}
			continue;
		}
		[r setVertexBytes:&f length:sizeof f atIndex:4];
		[r drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexType:MTLIndexTypeUInt16 indexBuffer:s->ownIndices indexBufferOffset:0
			indirectBuffer:d->args indirectBufferOffset:(NSUInteger) layer * 20];
	}
}

// (v12) own terrain as coloured-shadow casters: the pipelines from own's library (compact as own was built) and shadow.metal's
// shadow_tint_fs (after mc_shadow_tint_init), a list of cap units. 0 = ready, 1 = failed (err filled).
int mc_shadow_own_tint_init(Shadow *s, id<MTLLibrary> lib, int compact, int cap, char *err, int errCap) {
	if (!s || !lib || !s->tint) return 1;
	if (s->ownTint) return 0;
	@autoreleasepool {
		MTLFunctionConstantValues *cv = [[MTLFunctionConstantValues new] autorelease];
		bool c = compact != 0, f = false;
		[cv setConstantValue:&c type:MTLDataTypeBool atIndex:1];
		[cv setConstantValue:&f type:MTLDataTypeBool atIndex:2];
		NSError *e = nil;
		id<MTLFunction> vs = [[lib newFunctionWithName:@"own_shadow_tint_vs" constantValues:cv error:&e] autorelease];
		id<MTLFunction> fs = [[s->library newFunctionWithName:@"shadow_tint_fs"] autorelease];
		id<MTLFunction> k0 = [[lib newFunctionWithName:@"own_shadow_tcull_reset"] autorelease];
		id<MTLFunction> k1 = [[lib newFunctionWithName:@"own_shadow_tcull" constantValues:cv error:&e] autorelease];
		id<MTLFunction> k2 = [[lib newFunctionWithName:@"own_shadow_tcull_finish"] autorelease];
		if (!vs || !fs || !k0 || !k1 || !k2) {
			copyErr(e, "own tint functions missing", err, errCap);
			return 1;
		}
		MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor new] autorelease];
		pd.label = @"mcopt shadow tint own";
		pd.vertexFunction = vs;
		pd.fragmentFunction = fs;
		pd.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
		MTLRenderPipelineColorAttachmentDescriptor *ca = pd.colorAttachments[0];  // (as mc_shadow_tint_init's)
		ca.pixelFormat = MTLPixelFormatRGBA16Float;
		ca.blendingEnabled = YES;
		ca.rgbBlendOperation = MTLBlendOperationMin;
		ca.alphaBlendOperation = MTLBlendOperationMax;
		ca.sourceRGBBlendFactor = MTLBlendFactorOne;
		ca.destinationRGBBlendFactor = MTLBlendFactorOne;
		ca.sourceAlphaBlendFactor = MTLBlendFactorOne;
		ca.destinationAlphaBlendFactor = MTLBlendFactorOne;
		id<MTLRenderPipelineState> pso = [s->device newRenderPipelineStateWithDescriptor:pd error:&e];
		id<MTLComputePipelineState> c0 = pso ? [s->device newComputePipelineStateWithFunction:k0 error:&e] : nil;
		id<MTLComputePipelineState> c1 = c0 ? [s->device newComputePipelineStateWithFunction:k1 error:&e] : nil;
		id<MTLComputePipelineState> c2 = c1 ? [s->device newComputePipelineStateWithFunction:k2 error:&e] : nil;
		uint32_t n = cap > 0 ? (uint32_t) cap : 1;
		id<MTLBuffer> list = c2 ? [s->device newBufferWithLength:(NSUInteger) n * 4 options:MTLResourceStorageModePrivate] : nil;
		id<MTLBuffer> args = list ? [s->device newBufferWithLength:32 options:MTLResourceStorageModePrivate] : nil;
		id<MTLBuffer> rect = args ? [s->device newBufferWithLength:OWN_TINT_RING * 32 options:MTLResourceStorageModeShared] : nil;
		if (!rect) {
			[pso release];
			[c0 release];
			[c1 release];
			[c2 release];
			[list release];
			[args release];
			copyErr(e, "own tint pipelines or buffers failed", err, errCap);
			return 1;
		}
		memset(rect.contents, 0, OWN_TINT_RING * 32);
		list.label = @"mcopt shadow tint own list";
		s->ownTint = pso;
		s->ownTcullReset = c0;
		s->ownTcull = c1;
		s->ownTcullFinish = c2;
		s->ownTintList = list;
		s->ownTintArgs = args;
		s->ownTintRect = rect;
		s->ownTintCap = n;
	}
	return 0;
}

// (v12) rect slot `slot` as the tint pass left it (out: 6 ints: the rectangle, the quads drawn, the units listed; see
// Shadow.ownTintRect); zeros before mc_shadow_own_tint_init.
void mc_shadow_own_tint_rect(Shadow *s, int slot, int32_t *out) {
	if (!s || !s->ownTintRect || slot < 0 || slot >= OWN_TINT_RING) {
		memset(out, 0, 6 * sizeof(int32_t));
		return;
	}
	memcpy(out, (const uint8_t *) s->ownTintRect.contents + slot * 32, 6 * sizeof(int32_t));
}

void mc_shadow_free(Shadow *s) {
	if (!s) return;
	entClear(s->pending, &s->pendingCount);
	entClear(s->ready, &s->readyCount);
	[s->entity release];
	[s->casters release];
	[s->library release];
	[s->solid release];
	[s->cutout release];
	[s->debug release];
	[s->debugTiles release];
	[s->depthWrite release];
	[s->compare release];
	[s->atlasSampler release];
	[s->map release];
	[s->quadIndices release];
	[s->quadIndicesRev release];
	[s->tint release];
	[s->tintMap release];
	[s->back release];
	[s->times release];
	[s->tintLite release];
	[s->ownSolid release];
	[s->ownCutout release];
	[s->ownIndices release];
	[s->ownTint release];
	[s->ownTcullReset release];
	[s->ownTcull release];
	[s->ownTcullFinish release];
	[s->ownTintList release];
	[s->ownTintArgs release];
	[s->ownTintRect release];
	free(s);
}

id<MTLTexture> mc_shadow_texture(Shadow *s) { return s->map; }
id<MTLSamplerState> mc_shadow_compare_sampler(Shadow *s) { return s->compare; }

/*
 * One cascade: clears slice `layer` to 0 and draws the lists. cascade: the MSL ShadowCascade (cascadeBytes), draws: drawCount
 * records of DRAW_BYTES (see above). chunks / regions: the frame's ShadowChunk and ShadowRegion arrays. Every arena must
 * stay alive until the command buffer completes (Java marks them used by this submit). Returns the profiling encoder index
 * this pass took (-1 when not profiling), so a -Dmcopt.metal.trace run can attribute its GPU time.
 */
static void timerAttach(Shadow *s, MTLRenderPassDescriptor *rp, int kind);

int mc_shadow_render_ex(Enc *enc, Shadow *s, int layer, const void *cascade, int cascadeBytes, id<MTLBuffer> chunks, uint64_t chunksOffset,
	id<MTLBuffer> regions, uint64_t regionsOffset, const uint8_t *draws, int drawCount, id<MTLTexture> atlas, float slopeScale, float clamp,
	int target, int load, int timerKind, const OwnShadowDraw *own);

int mc_shadow_render(Enc *enc, Shadow *s, int layer, const void *cascade, int cascadeBytes, id<MTLBuffer> chunks, uint64_t chunksOffset,
	id<MTLBuffer> regions, uint64_t regionsOffset, const uint8_t *draws, int drawCount, id<MTLTexture> atlas, float slopeScale, float clamp) {
	return mc_shadow_render_ex(enc, s, layer, cascade, cascadeBytes, chunks, chunksOffset, regions, regionsOffset, draws, drawCount, atlas, slopeScale, clamp,
		0, 0, -1, NULL);
}

/*
 * mc_shadow_render with M3.3's choices: target 0 = the map receivers bind, 1 = the back map (mc_shadow_spread_init; the far
 * cascade drawn in parts); load 1 keeps what the slice holds (the parts drawn before) instead of clearing it; timerKind
 * >= 0 times the pass (mc_shadow_times_frame), -1 not. own (v12, NULL: none): mcopt's own terrain's lists for this cascade.
 */
int mc_shadow_render_ex(Enc *enc, Shadow *s, int layer, const void *cascade, int cascadeBytes, id<MTLBuffer> chunks, uint64_t chunksOffset,
	id<MTLBuffer> regions, uint64_t regionsOffset, const uint8_t *draws, int drawCount, id<MTLTexture> atlas, float slopeScale, float clamp,
	int target, int load, int timerKind, const OwnShadowDraw *own) {
	id<MTLCommandBuffer> cmd = mc_frame_cmd(enc);
	int profiled = -1;
	id<MTLTexture> map = target == 1 && s->back ? s->back : s->map;
	@autoreleasepool {
		MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
		rp.depthAttachment.texture = map;
		rp.depthAttachment.slice = layer;
		rp.depthAttachment.loadAction = load ? MTLLoadActionLoad : MTLLoadActionClear;
		rp.depthAttachment.clearDepth = 0.0;  // reversed Z: nothing casts
		rp.depthAttachment.storeAction = MTLStoreActionStore;
		rp.renderTargetWidth = s->resolution;
		rp.renderTargetHeight = s->resolution;
		if (enc->samples && enc->sampleCount + 4 <= (int) enc->samples.sampleCount) {
			MTLRenderPassSampleBufferAttachmentDescriptor *sb = rp.sampleBufferAttachments[0];
			sb.sampleBuffer = enc->samples;
			sb.startOfVertexSampleIndex = enc->sampleCount;
			sb.endOfVertexSampleIndex = enc->sampleCount + 1;
			sb.startOfFragmentSampleIndex = enc->sampleCount + 2;
			sb.endOfFragmentSampleIndex = enc->sampleCount + 3;
			profiled = enc->sampleCount / 4;
			enc->sampleCount += 4;
		} else if (timerKind >= 0) {
			timerAttach(s, rp, timerKind);
		}
		id<MTLRenderCommandEncoder> r = [cmd renderCommandEncoderWithDescriptor:rp];
		r.label = layer == 0 ? @"mcopt shadow cascade 0" : target == 1 ? @"mcopt shadow cascade 1 (back, part)" : @"mcopt shadow cascade 1";
		[r setViewport:(MTLViewport) {0, 0, s->resolution, s->resolution, 0, 1}];
		[r setDepthStencilState:s->depthWrite];
		[r setCullMode:MTLCullModeNone];  // only light-facing ranges are listed; unassigned quads (plants) are two-sided
		[r setDepthClipMode:MTLDepthClipModeClamp];  // pancaking: casters in front of the near plane land at depth 1
		[r setDepthBias:0 slopeScale:slopeScale clamp:clamp];
		[r setVertexBytes:cascade length:cascadeBytes atIndex:3];
		[r setVertexBuffer:chunks offset:chunksOffset atIndex:1];
		[r setVertexBuffer:regions offset:regionsOffset atIndex:2];
		if (atlas) {
			[r setFragmentTexture:atlas atIndex:0];
			[r setFragmentSamplerState:s->atlasSampler atIndex:0];
		}
		int kind = -1;
		id<MTLBuffer> arena = nil;
		for (int i = 0; i < drawCount; i++) {
			const uint8_t *d = draws + i * DRAW_BYTES;
			id<MTLBuffer> vb;
			uint32_t first, count, k;
			memcpy(&vb, d, 8);
			memcpy(&first, d + 8, 4);
			memcpy(&count, d + 12, 4);
			memcpy(&k, d + 16, 4);
			// kind bit 8 (FT2.8): the list's chunks are listed last to first and its quads go through the reversed indices
			id<MTLBuffer> ib = (k & 256u) && s->quadIndicesRev ? s->quadIndicesRev : s->quadIndices;
			k &= 255u;
			if (count == 0 || (k == 1 && !atlas)) continue;
			if ((int) k != kind) {
				[r setRenderPipelineState:k == 1 ? s->cutout : s->solid];
				kind = (int) k;
			}
			if (vb != arena) {
				[r setVertexBuffer:vb offset:0 atIndex:0];
				arena = vb;
			}
			[r drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:QUAD_INDICES indexType:MTLIndexTypeUInt16 indexBuffer:ib
				indexBufferOffset:0 instanceCount:count baseVertex:0 baseInstance:first];
		}
		ownDraw(s, r, own, atlas);  // (v12: mcopt's own terrain)
		// M3: last frame's entities into the near cascade (shifted onto this frame's camera)
		if (layer == 0 && s->readyCount > 0 && s->entity) {
			[r setRenderPipelineState:s->entity];
			[r setVertexBuffer:s->casters offset:0 atIndex:0];
			[r setFragmentSamplerState:s->atlasSampler atIndex:0];
			id<MTLTexture> bound = nil;
			for (int i = 0; i < s->readyCount; i++) {
				EntDraw *d = &s->ready[i];
				struct { float shift[3]; uint32_t stride; uint32_t uvOffset; float cutoff; float pad[2]; } p = {
					{s->shift[0], s->shift[1], s->shift[2]}, d->stride, d->uvOffset, d->cutoff, {0, 0}};
				[r setVertexBufferOffset:d->dst atIndex:0];
				[r setVertexBytes:&p length:sizeof p atIndex:4];
				[r setFragmentBytes:&p length:sizeof p atIndex:4];
				if (d->tex != bound) {
					[r setFragmentTexture:d->tex atIndex:0];
					bound = d->tex;
				}
				[r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:d->quads * 6];
			}
		}
		[r endEncoding];
	}
	return profiled;
}

// ---- M3.3 far cascade spread (mcopt.shade.shadowFarSpread) ----------------------------------------------------------------
// The back map (same shape as the map), made on first use: 0 = ready, 1 = failed (the far cascade then keeps M3.2's way).
int mc_shadow_spread_init(Shadow *s) {
	if (!s) return 1;
	if (s->back) return 0;
	@autoreleasepool {
		MTLTextureDescriptor *td = [[MTLTextureDescriptor new] autorelease];
		td.textureType = MTLTextureType2DArray;
		td.pixelFormat = s->format;
		td.width = s->resolution;
		td.height = s->resolution;
		td.arrayLength = s->layers;
		td.storageMode = MTLStorageModePrivate;
		td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
		s->back = [s->device newTextureWithDescriptor:td];
		s->back.label = @"mcopt shadow map (2)";
	}
	return s->back ? 0 : 1;
}

// The back map becomes the map receivers bind and the other way round (call before this frame's cascades are encoded;
// mc_shadow_texture returns the new one). Tracked textures on one queue: the old map's readers in frames still in flight
// finish before anything writes it again.
void mc_shadow_swap(Shadow *s) {
	if (!s || !s->back) return;
	id<MTLTexture> t = s->map;
	s->map = s->back;
	s->back = t;
}

// ---- M3.3 GPU timers (mcopt.shade.shadowTimes): vertex start to fragment end of every shadow pass ---------------------
static void timesInit(Shadow *s) {
	s->timesTried = 1;
	if (![s->device supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) return;
	@autoreleasepool {
		for (id<MTLCounterSet> set in s->device.counterSets) {
			if (![set.name isEqualToString:MTLCommonCounterSetTimestamp]) continue;
			MTLCounterSampleBufferDescriptor *d = [[MTLCounterSampleBufferDescriptor new] autorelease];
			d.counterSet = set;
			d.storageMode = MTLStorageModeShared;
			d.sampleCount = SHADOW_TIME_RING * SHADOW_TIME_KINDS * 4;
			s->times = [s->device newCounterSampleBufferWithDescriptor:d error:nil];
			[s->device sampleTimestamps:&s->cpu0 gpuTimestamp:&s->gpu0];
			break;
		}
	}
}

static void timesCollect(Shadow *s, int r) {
	MTLTimestamp cpu1, gpu1;
	[s->device sampleTimestamps:&cpu1 gpuTimestamp:&gpu1];
	if (gpu1 <= s->gpu0 || cpu1 <= s->cpu0) return;
	double nsPerTick = (double) (cpu1 - s->cpu0) / (double) (gpu1 - s->gpu0);
	@autoreleasepool {
		const int n = SHADOW_TIME_KINDS * 4;
		NSData *data = [s->times resolveCounterRange:NSMakeRange((NSUInteger) (n * r), n)];
		if (data.length < n * sizeof(MTLCounterResultTimestamp)) return;
		const MTLCounterResultTimestamp *ts = data.bytes;
		uint64_t first = 0;
		for (int i = 0; i < n; i++) if (ts[i].timestamp != MTLCounterErrorValue && ts[i].timestamp != 0) { first = ts[i].timestamp; break; }
		if (first == 0 || first == s->timeLast[r]) return;
		s->timeLast[r] = first;
		for (int k = 0; k < SHADOW_TIME_KINDS; k++) {
			if (!(s->timeRan[r] & (1 << k))) continue;
			// vertex start, vertex end, fragment start, fragment end: the pass spans the earliest start to the latest end
			uint64_t a = UINT64_MAX, b = 0;
			for (int j = 0; j < 4; j++) {
				uint64_t t = ts[4 * k + j].timestamp;
				if (t == MTLCounterErrorValue || t == 0) continue;
				if (j == 0 || j == 2) a = t < a ? t : a;
				else b = t > b ? t : b;
			}
			if (a != UINT64_MAX && b > a) {
				s->timeSum[k] += (double) (b - a) * nsPerTick / 1e6;
				s->timeN[k]++;
			}
		}
		s->timeCount++;
	}
}

// Start of a timed frame (frame: a counter that advances once per frame): picks the ring slot this frame's passes sample
// into, after reading what that slot held SHADOW_TIME_RING frames ago. Returns 0, or 1 when the GPU can't time passes.
int mc_shadow_times_frame(Shadow *s, long long frame) {
	if (!s) return 1;
	if (!s->timesTried) timesInit(s);
	if (!s->times) return 1;
	int r = (int) (frame % SHADOW_TIME_RING);
	if (s->timeFrame >= SHADOW_TIME_RING && s->timeRan[r]) timesCollect(s, r);
	s->timeRan[r] = 0;
	s->timeSlot = r;
	s->timeFrame++;
	return 0;
}

static void timerAttach(Shadow *s, MTLRenderPassDescriptor *rp, int kind) {
	if (!s->times || kind < 0 || kind >= SHADOW_TIME_KINDS) return;
	int base = (s->timeSlot * SHADOW_TIME_KINDS + kind) * 4;
	MTLRenderPassSampleBufferAttachmentDescriptor *sb = rp.sampleBufferAttachments[0];
	sb.sampleBuffer = s->times;
	sb.startOfVertexSampleIndex = (NSUInteger) base;
	sb.endOfVertexSampleIndex = (NSUInteger) base + 1;
	sb.startOfFragmentSampleIndex = (NSUInteger) base + 2;
	sb.endOfFragmentSampleIndex = (NSUInteger) base + 3;
	s->timeRan[s->timeSlot] |= 1 << kind;
}

// Average GPU ms per run of each pass kind since the last call (out[0..3]: near, far whole, far part, tint), how many runs
// (out[4..7]) and how many frames were read back (out[8]). Vertex start to fragment end: work the GPU overlaps with a pass
// counts too, so these are upper bounds.
void mc_shadow_times(Shadow *s, float *out) {
	for (int k = 0; k < SHADOW_TIME_KINDS; k++) {
		out[k] = s && s->timeN[k] > 0 ? (float) (s->timeSum[k] / s->timeN[k]) : 0.0f;
		out[SHADOW_TIME_KINDS + k] = s ? (float) s->timeN[k] : 0.0f;
		if (s) {
			s->timeSum[k] = 0;
			s->timeN[k] = 0;
		}
	}
	out[2 * SHADOW_TIME_KINDS] = s ? (float) s->timeCount : 0.0f;
	if (s) s->timeCount = 0;
}

// ---- M3 entity casters ----------------------------------------------------------------------------------------------------
// The entity casters' pipeline and 12 MB buffer, made only when entity shadows are on (EntityCasters.attach). 0 = ready,
// 1 = failed (err filled; the terrain shadows are untouched and nothing is recorded).
int mc_shadow_entity_init(Shadow *s, char *err, int errCap) {
	if (!s) return 1;
	if (s->entity && s->casters) return 0;
	@autoreleasepool {
		NSError *e = nil;
		id<MTLRenderPipelineState> pso = depthOnly(s, @"shadow_entity_vs", @"shadow_entity_fs", &e);
		if (!pso) {
			copyErr(e, "shadow entity pipeline failed", err, errCap);
			return 1;
		}
		id<MTLBuffer> buf = [s->device newBufferWithLength:ENT_BYTES options:MTLResourceStorageModePrivate];
		if (!buf) {
			[pso release];
			strlcpy(err, "shadow entity casters buffer failed", errCap);
			return 1;
		}
		buf.label = @"mcopt shadow: entity casters";
		s->entity = pso;
		s->casters = buf;
	}
	return 0;
}

// One entity draw of the main pass: quads x 4 vertices of `stride` bytes at src + srcOffset (position float3 at 0, uv float2 at
// uvOffset), texture tex (alpha < cutoff: no shadow). Kept (retained) until mc_shadow_entity_commit copies them. 0 = recorded,
// 1 = dropped (list or buffer full).
int mc_shadow_entity_record(Shadow *s, id<MTLBuffer> src, uint64_t srcOffset, int quads, int stride, int uvOffset, id<MTLTexture> tex, float cutoff) {
	if (!s || !s->casters || !src || quads <= 0 || stride <= 0 || s->pendingCount >= ENT_MAX) return 1;
	uint32_t bytes = (uint32_t) quads * 4u * (uint32_t) stride;
	uint32_t dst = (s->pendingBytes + 15u) & ~15u;
	if (dst + bytes > ENT_BYTES || srcOffset + bytes > src.length) return 1;
	EntDraw *d = &s->pending[s->pendingCount++];
	d->src = [src retain];
	d->tex = [tex retain];
	d->srcOffset = srcOffset;
	d->dst = dst;
	d->quads = (uint32_t) quads;
	d->stride = (uint32_t) stride;
	d->uvOffset = (uint32_t) uvOffset;
	d->cutoff = cutoff;
	s->pendingBytes = dst + bytes;
	return 0;
}

// End of the world (before the hand): the recorded draws' vertices -> casters (one blit encoder on the frame's command buffer),
// and they become the list the next frame's near cascade draws. With nothing recorded, the list empties.
void mc_shadow_entity_commit(Enc *enc, Shadow *s) {
	if (!s) return;
	entClear(s->ready, &s->readyCount);
	if (s->pendingCount > 0) {
		id<MTLCommandBuffer> cmd = mc_frame_cmd(enc);
		@autoreleasepool {
			id<MTLBlitCommandEncoder> b = [cmd blitCommandEncoder];
			b.label = @"mcopt shadow: entity casters";
			for (int i = 0; i < s->pendingCount; i++) {
				EntDraw *d = &s->pending[i];
				[b copyFromBuffer:d->src sourceOffset:d->srcOffset toBuffer:s->casters destinationOffset:d->dst size:(NSUInteger) d->quads * 4u * d->stride];
			}
			[b endEncoding];
		}
		for (int i = 0; i < s->pendingCount; i++) {
			s->ready[i] = s->pending[i];
			[s->ready[i].src release]; // the blit holds it now
			s->ready[i].src = nil;
		}
		s->readyCount = s->pendingCount;
		s->pendingCount = 0;
	}
	s->pendingBytes = 0;
}

// Drops what was recorded (a frame that never reached its commit), keeping the ready list.
void mc_shadow_entity_reset(Shadow *s) {
	if (!s) return;
	entClear(s->pending, &s->pendingCount);
	s->pendingBytes = 0;
}

// The ready casters' shift for this frame's near cascade (camera of the frame they were recorded in - this frame's camera);
// clear: forget them (the camera jumped, another dimension).
void mc_shadow_entity_shift(Shadow *s, float x, float y, float z, int clear) {
	if (!s) return;
	if (clear) entClear(s->ready, &s->readyCount);
	s->shift[0] = x;
	s->shift[1] = y;
	s->shift[2] = z;
}

int mc_shadow_entity_count(Shadow *s) { return s ? s->readyCount : 0; }

// Binds the map at texture(textureSlot) and the compare sampler at sampler(samplerSlot), vertex and fragment, on the open
// render encoder (no-op when none is open). For the shade infrastructure's global binds.
void mc_shadow_bind(Enc *enc, Shadow *s, int textureSlot, int samplerSlot) {
	id<MTLRenderCommandEncoder> r = enc->render;
	if (!r) return;
	[r setVertexTexture:s->map atIndex:textureSlot];
	[r setFragmentTexture:s->map atIndex:textureSlot];
	[r setVertexSamplerState:s->compare atIndex:samplerSlot];
	[r setFragmentSamplerState:s->compare atIndex:samplerSlot];
}

// Debug view: every cascade as a size x size tile, drawn into a small texture of its own and blitted into target at
// (x + c * (size + gap), y) (texture pixels, GL row order). A blit leaves the rest of the target alone: a render pass on it
// would load and store all of it. params: one MSL ShadowDebugParams (paramBytes) per cascade. Returns 0, or 1 when the
// debug pipeline can't be made.
int mc_shadow_debug(Enc *enc, Shadow *s, id<MTLTexture> target, int x, int y, int size, int gap, const void *params, int paramBytes) {
	if (!s->debug || s->debugFormat != target.pixelFormat) {
		@autoreleasepool {
			[s->debug release];
			s->debug = nil;
			MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor new] autorelease];
			pd.vertexFunction = [[s->library newFunctionWithName:@"shadow_debug_vs"] autorelease];
			pd.fragmentFunction = [[s->library newFunctionWithName:@"shadow_debug_fs"] autorelease];
			pd.colorAttachments[0].pixelFormat = target.pixelFormat;
			NSError *e = nil;
			s->debug = [s->device newRenderPipelineStateWithDescriptor:pd error:&e];
			s->debugFormat = target.pixelFormat;
			if (!s->debug) {
				NSLog(@"mcopt-shade: shadow debug pipeline: %@", e);
				return 1;
			}
		}
	}
	int width = s->layers * size;
	if (x < 0 || y < 0 || x + width + (s->layers - 1) * gap > (int) target.width || y + size > (int) target.height) return 0;
	if (!s->debugTiles || (int) s->debugTiles.width != width || (int) s->debugTiles.height != size || s->debugTiles.pixelFormat != target.pixelFormat) {
		[s->debugTiles release];
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:target.pixelFormat width:width height:size mipmapped:NO];
		td.usage = MTLTextureUsageRenderTarget;
		td.storageMode = MTLStorageModePrivate;
		s->debugTiles = [s->device newTextureWithDescriptor:td];
	}
	id<MTLCommandBuffer> cmd = mc_frame_cmd(enc);
	@autoreleasepool {
		MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
		rp.colorAttachments[0].texture = s->debugTiles;
		rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;  // the tiles cover all of it
		rp.colorAttachments[0].storeAction = MTLStoreActionStore;
		id<MTLRenderCommandEncoder> r = [cmd renderCommandEncoderWithDescriptor:rp];
		r.label = @"mcopt shadow debug";
		[r setRenderPipelineState:s->debug];
		[r setFragmentTexture:s->map atIndex:0];
		for (int c = 0; c < s->layers; c++) {
			[r setViewport:(MTLViewport) {c * size, 0, size, size, 0, 1}];
			[r setFragmentBytes:(const uint8_t *) params + c * paramBytes length:paramBytes atIndex:0];
			[r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		}
		[r endEncoding];
		id<MTLBlitCommandEncoder> b = [cmd blitCommandEncoder];
		for (int c = 0; c < s->layers; c++) {
			[b copyFromTexture:s->debugTiles sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(c * size, 0, 0) sourceSize:MTLSizeMake(size, size, 1)
				toTexture:target destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(x + c * (size + gap), y, 0)];
		}
		[b endEncoding];
	}
	return 0;
}

// ---- coloured shadows (M3 weather) ----

// The tint map (RGBA16Float, resolution^2) and its pipeline (shadow.metal shadow_tint_vs / shadow_tint_fs; rgb blended by MIN,
// alpha by MAX). Returns 0, or 1 on failure (err filled).
int mc_shadow_tint_init(Shadow *s, int resolution, char *err, int errCap) {
	if (s->tint && s->tintMap && (int) s->tintMap.width == resolution) return 0;
	@autoreleasepool {
		MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor new] autorelease];
		pd.label = @"mcopt shadow tint";
		pd.vertexFunction = [[s->library newFunctionWithName:@"shadow_tint_vs"] autorelease];
		pd.fragmentFunction = [[s->library newFunctionWithName:@"shadow_tint_fs"] autorelease];
		pd.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
		MTLRenderPipelineColorAttachmentDescriptor *ca = pd.colorAttachments[0];
		ca.pixelFormat = MTLPixelFormatRGBA16Float;
		ca.blendingEnabled = YES;
		ca.rgbBlendOperation = MTLBlendOperationMin;
		ca.alphaBlendOperation = MTLBlendOperationMax;
		ca.sourceRGBBlendFactor = MTLBlendFactorOne;
		ca.destinationRGBBlendFactor = MTLBlendFactorOne;
		ca.sourceAlphaBlendFactor = MTLBlendFactorOne;
		ca.destinationAlphaBlendFactor = MTLBlendFactorOne;
		NSError *e = nil;
		id<MTLRenderPipelineState> pso = [s->device newRenderPipelineStateWithDescriptor:pd error:&e];
		if (!pso) {
			copyErr(e, "shadow tint pipeline failed", err, errCap);
			return 1;
		}
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:resolution height:resolution mipmapped:NO];
		td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
		td.storageMode = MTLStorageModePrivate;
		id<MTLTexture> map = [s->device newTextureWithDescriptor:td];
		if (!map) {
			[pso release];
			strlcpy(err, "shadow tint map failed", errCap);
			return 1;
		}
		map.label = @"mcopt shadow tint";
		[s->tint release];
		[s->tintMap release];
		s->tint = pso;
		s->tintMap = map;
		s->tintDirty = true;  // undefined until the first pass clears it
	}
	return 0;
}

id<MTLTexture> mc_shadow_tint_texture(Shadow *s) { return s->tintMap; }

// M3.3: a second, smaller tint map (resolution^2; the pipeline of mc_shadow_tint_init), for mc_shadow_tint_render_ex's lite.
// Returns it, or nil (no tint pipeline yet, or no memory).
id<MTLTexture> mc_shadow_tint_lite_init(Shadow *s, int resolution) {
	if (!s || !s->tint) return nil;
	if (s->tintLite && (int) s->tintLite.width == resolution) return s->tintLite;
	@autoreleasepool {
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:resolution height:resolution mipmapped:NO];
		td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
		td.storageMode = MTLStorageModePrivate;
		[s->tintLite release];
		s->tintLite = [s->device newTextureWithDescriptor:td];
		s->tintLite.label = @"mcopt shadow tint (lite)";
		s->tintLiteDirty = true;
	}
	return s->tintLite;
}

int mc_shadow_tint_render_ex(Enc *enc, Shadow *s, const void *cascade, int cascadeBytes, id<MTLBuffer> chunks, uint64_t chunksOffset,
	id<MTLBuffer> regions, uint64_t regionsOffset, const uint8_t *draws, int drawCount, id<MTLTexture> atlas, const void *params, int paramBytes,
	int lite, int timerKind, int areaW, int areaH, const OwnShadowTint *own);

/*
 * The tint pass for the near cascade: clears the map to (1, 1, 1, 0) (no tint, no caster) and draws the translucent lists
 * (records as mc_shadow_render's; every record is drawn with the tint pipeline). params: the MSL ShadowTintParams (48 bytes:
 * the water sprites, mode). With no draws the map is cleared only if it held casters. Returns 1 when it ran a pass.
 */
int mc_shadow_tint_render(Enc *enc, Shadow *s, const void *cascade, int cascadeBytes, id<MTLBuffer> chunks, uint64_t chunksOffset,
	id<MTLBuffer> regions, uint64_t regionsOffset, const uint8_t *draws, int drawCount, id<MTLTexture> atlas, const void *params, int paramBytes) {
	return mc_shadow_tint_render_ex(enc, s, cascade, cascadeBytes, chunks, chunksOffset, regions, regionsOffset, draws, drawCount, atlas, params, paramBytes, 0, -1,
		0, 0, NULL);
}

// mc_shadow_tint_render into the lite map (lite 1, after mc_shadow_tint_lite_init) or the normal one, timed as timerKind (-1: no).
// areaW x areaH > 0 (M3.3 mcopt.shade.tintSub): only that top-left part of the map is cleared, drawn and stored (the casters'
// rectangle; cascade's matrix maps it onto the area), the rest keeps whatever it held (receivers never read it).
// own (v12, NULL: none; after mc_shadow_own_tint_init): own terrain's translucent units too, culled here on the GPU first (so the
// pass runs every time: what they cover is known only after it, in the rect slot it writes).
int mc_shadow_tint_render_ex(Enc *enc, Shadow *s, const void *cascade, int cascadeBytes, id<MTLBuffer> chunks, uint64_t chunksOffset,
	id<MTLBuffer> regions, uint64_t regionsOffset, const uint8_t *draws, int drawCount, id<MTLTexture> atlas, const void *params, int paramBytes,
	int lite, int timerKind, int areaW, int areaH, const OwnShadowTint *own) {
	if (!s->tint || !s->tintMap) return 0;
	id<MTLTexture> map = lite && s->tintLite ? s->tintLite : s->tintMap;
	bool *dirty = map == s->tintLite ? &s->tintLiteDirty : &s->tintDirty;
	bool ownOn = own && s->ownTint && own->arena && own->sections && own->recs && atlas && own->slot < OWN_TINT_RING;
	bool ownDraw = ownOn && own->draw;
	if (drawCount == 0 && !*dirty && !ownOn) return 0;
	id<MTLCommandBuffer> cmd = mc_frame_cmd(enc);
	@autoreleasepool {
		if (ownOn) {
			uint8_t cull[OWN_TCULL_BYTES];
			memcpy(cull, own->cull, sizeof cull);
			memcpy(cull + 120, &s->ownTintCap, 4);
			uint32_t sections;
			memcpy(&sections, cull + 116, 4);
			id<MTLComputeCommandEncoder> c = [cmd computeCommandEncoder];
			c.label = @"mcopt shadow tint cull (own)";
			[c setBytes:cull length:sizeof cull atIndex:0];
			[c setBuffer:own->sections offset:0 atIndex:1];
			[c setBuffer:own->recs offset:0 atIndex:2];
			[c setBuffer:s->ownTintArgs offset:0 atIndex:3];
			[c setBuffer:s->ownTintList offset:0 atIndex:4];
			[c setBuffer:s->ownTintRect offset:own->slot * 32 atIndex:5];
			[c setBuffer:own->arena offset:0 atIndex:6];
			[c setBytes:params length:paramBytes atIndex:7];
			[c setComputePipelineState:s->ownTcullReset];
			[c dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
			if (sections > 0) {
				// a simdgroup (32 threads) per section: own_shadow_tcull's lanes test a unit's quads together
				[c setComputePipelineState:s->ownTcull];
				[c dispatchThreads:MTLSizeMake((NSUInteger) sections * 32, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
			}
			[c setComputePipelineState:s->ownTcullFinish];
			[c dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
			[c endEncoding];
		}
		if (drawCount == 0 && !*dirty && !ownDraw) return ownOn ? 2 : 0;  // (2: own's cull ran, no pass)
		MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
		rp.colorAttachments[0].texture = map;
		rp.colorAttachments[0].loadAction = MTLLoadActionClear;
		rp.colorAttachments[0].clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 0.0);
		rp.colorAttachments[0].storeAction = MTLStoreActionStore;
		if (timerKind >= 0) timerAttach(s, rp, timerKind);
		int res = (int) map.width;
		int w = res, h = res;
		if (areaW > 0 && areaH > 0) {
			w = areaW < res ? areaW : res;
			h = areaH < res ? areaH : res;
			rp.renderTargetWidth = (NSUInteger) w;
			rp.renderTargetHeight = (NSUInteger) h;
		}
		id<MTLRenderCommandEncoder> r = [cmd renderCommandEncoderWithDescriptor:rp];
		r.label = w < res || h < res ? @"mcopt shadow tint (rectangle)" : @"mcopt shadow tint";
		[r setViewport:(MTLViewport) {0, 0, w, h, 0, 1}];
		if (drawCount > 0 && atlas) {
			[r setRenderPipelineState:s->tint];
			[r setCullMode:MTLCullModeNone];
			[r setDepthClipMode:MTLDepthClipModeClamp];
			[r setVertexBytes:cascade length:cascadeBytes atIndex:3];
			[r setVertexBuffer:chunks offset:chunksOffset atIndex:1];
			[r setVertexBuffer:regions offset:regionsOffset atIndex:2];
			[r setFragmentTexture:atlas atIndex:0];
			[r setFragmentSamplerState:s->atlasSampler atIndex:0];
			[r setFragmentBytes:params length:paramBytes atIndex:0];
			id<MTLBuffer> arena = nil;
			for (int i = 0; i < drawCount; i++) {
				const uint8_t *d = draws + i * DRAW_BYTES;
				id<MTLBuffer> vb;
				uint32_t first, count;
				memcpy(&vb, d, 8);
				memcpy(&first, d + 8, 4);
				memcpy(&count, d + 12, 4);
				if (count == 0) continue;
				if (vb != arena) {
					[r setVertexBuffer:vb offset:0 atIndex:0];
					arena = vb;
				}
				[r drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:QUAD_INDICES indexType:MTLIndexTypeUInt16 indexBuffer:s->quadIndices
					indexBufferOffset:0 instanceCount:count baseVertex:0 baseInstance:first];
			}
		}
		if (ownDraw) {
			OwnShadowFrame f = own->frame;
			f.listBase = 0;
			[r setRenderPipelineState:s->ownTint];
			[r setCullMode:MTLCullModeNone];
			[r setDepthClipMode:MTLDepthClipModeClamp];
			[r setVertexBuffer:own->arena offset:0 atIndex:0];
			[r setVertexBuffer:own->sections offset:0 atIndex:1];
			[r setVertexBuffer:own->recs offset:0 atIndex:2];
			[r setVertexBytes:cascade length:cascadeBytes atIndex:3];
			[r setVertexBytes:&f length:sizeof f atIndex:4];
			[r setVertexBuffer:s->ownTintList offset:0 atIndex:5];
			[r setVertexBytes:params length:paramBytes atIndex:6];
			[r setVertexBuffer:s->ownTintRect offset:own->slot * 32 atIndex:7];
			[r setFragmentTexture:atlas atIndex:0];
			[r setFragmentSamplerState:s->atlasSampler atIndex:0];
			[r setFragmentBytes:params length:paramBytes atIndex:0];
			[r drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexType:MTLIndexTypeUInt16 indexBuffer:s->ownIndices indexBufferOffset:0
				indirectBuffer:s->ownTintArgs indirectBufferOffset:0];
		}
		[r endEncoding];
	}
	*dirty = drawCount > 0 || ownDraw;
	return 1;
}
