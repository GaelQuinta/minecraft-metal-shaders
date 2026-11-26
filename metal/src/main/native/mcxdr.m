// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// M3 XDR / EDR output for the Liquid Retina XDR panel (native shading, mcopt.shade.xdr; bible E23). Off unless the Java side
// calls mc_xdr_enable(1) before the layer is configured; then:
//   - mc_layer_configure (mcmetal.m) makes the CAMetalLayer RGBA16Float, extendedLinearDisplayP3, wantsExtendedDynamicRange;
//   - shade's final pass (shade_post.metal shade_final_xdr) writes the SDR image into the game's main RGBA8 target as before,
//     with alpha 0 ("the world, untouched"), and the highlights' extra brightness above SDR white (linear Rec.709, >= 0) into
//     an RG11B10Float "excess" image, which it hands over with mc_xdr_frame;
//   - the hand, screen effects and the GUI then draw over main as usual (their blending writes alpha > 0: coverage);
//   - at present (pqFill / mc_present in mcmetal.m) a compose pass writes linear extended P3 = M709toP3 (sRGB->linear(main.rgb)
//     + excess x (1 - main.a)): SDR content at SDR white, the world's highlights above it, the GUI on top untouched.
// Full-scene mode uses a complete RGBA16F world image instead of excess and a
// pre-HUD SDR reference to recover overlay coverage without changing vanilla passes.
// Screenshots read main, i.e. the SDR image. Headroom: NSScreen.maximumExtendedDynamicRangeColorComponentValue of the
// layer's screen (mc_xdr_headroom), queried by the Java side a few times a second.
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <AppKit/AppKit.h>
#include "mcmetal.h"

static int xdrOn;
static id<MTLTexture> xdrExcess;  // retained; this frame's (valid while xdrValid)
static int xdrValid, xdrFull;
static id<MTLTexture> xdrBase; // SDR compatibility image before hand/HUD; exact window-sized snapshot
static float xdrUiWhite = 1.0f, xdrPeak = 1.0f;
static void *xdrCmd;  // the command buffer the final pass encoded into: the excess counts only for that frame's present
static id<MTLLibrary> xdrLib;
static id<MTLRenderPipelineState> xdrCompose, xdrCompose16, xdrPresent, xdrComposeFull, xdrComposeFull16;

static const char *xdrSource =
	"#include <metal_stdlib>\n"
	"using namespace metal;\n"
	"struct V { float4 pos [[position]]; float2 uv; };\n"
	"vertex V xdr_vs(uint id [[vertex_id]]) {\n"
	"  float2 p = float2((id << 1) & 2, id & 2);\n"
	"  V v; v.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); v.uv = p; return v;\n"
	"}\n"
	"struct XdrParams { int flip; int valid; int e5; int full; float uiWhite; float peak; float2 pad; };\n"
	// (v12-opt) e5: the value as the RGB9E5 staging slot of the present queue stores it (shared exponent, mantissas truncated: the
	// GPU's render-target encode, matched bit for bit on 3.1 M random channels), so a compose straight into the RGBA16Float drawable
	// (presentQueue off) presents the same pixels as the queued path's slot + copy
	"static float3 e5(float3 c) {\n"
	"  c = clamp(c, 0.0, 65408.0); float m = max(c.x, max(c.y, c.z));\n"
	"  int e = max(-16, int((as_type<uint>(m) >> 23) & 255u) - 127) + 1 + 15;\n"
	"  float sc = as_type<float>(uint(e - 24 + 127) << 23);\n"
	"  return min(floor(c / sc), 511.0) * sc;\n"
	"}\n"
	"static float3 srgbToLinear(float3 c) { return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045); }\n"
	// (2.0.1 opt) exact 256-entry sRGB->linear LUT for 8-bit unorm inputs: eliminates 3x pow(x, 2.4) per 5.94 MP full-res pixel
	"constant half SRGB_TO_LIN[256] = {\n"
	"0.0h, 0.000303527h, 0.000607054h, 0.000910581h, 0.001214108h, 0.001517635h, 0.001821162h, 0.002124689h,\n"
	"0.002428216h, 0.002731743h, 0.00303527h, 0.003346536h, 0.003676507h, 0.004024717h, 0.004391442h, 0.004776953h,\n"
	"0.005181517h, 0.005605392h, 0.006048833h, 0.006512091h, 0.00699541h, 0.007499032h, 0.008023193h, 0.008568126h,\n"
	"0.009134059h, 0.009721217h, 0.01032982h, 0.01096009h, 0.01161225h, 0.01228649h, 0.01298303h, 0.01370208h,\n"
	"0.01444384h, 0.01520851h, 0.01599629h, 0.01680738h, 0.01764195h, 0.01850022h, 0.01938236h, 0.02028856h,\n"
	"0.02121901h, 0.02217388h, 0.02315337h, 0.02415763h, 0.02518686h, 0.02624122h, 0.02732089h, 0.02842604h,\n"
	"0.02955683h, 0.03071344h, 0.03189603h, 0.03310477h, 0.03433981h, 0.03560131h, 0.03688945h, 0.03820437h,\n"
	"0.03954624h, 0.0409152h, 0.04231141h, 0.04373503h, 0.0451862h, 0.04666509h, 0.04817182h, 0.04970657h,\n"
	"0.05126946h, 0.05286065h, 0.05448028h, 0.05612849h, 0.05780543h, 0.05951124h, 0.06124605h, 0.06301002h,\n"
	"0.06480327h, 0.06662594h, 0.06847817h, 0.0703601h, 0.07227185h, 0.07421357h, 0.07618538h, 0.07818742h,\n"
	"0.08021982h, 0.08228271h, 0.08437621h, 0.08650046h, 0.08865559h, 0.09084171h, 0.09305896h, 0.09530747h,\n"
	"0.09758735h, 0.09989873h, 0.1022417h, 0.1046165h, 0.1070231h, 0.1094617h, 0.1119324h, 0.1144354h,\n"
	"0.1169707h, 0.1195384h, 0.1221388h, 0.1247718h, 0.1274377h, 0.1301365h, 0.1328683h, 0.1356333h,\n"
	"0.1384316h, 0.1412633h, 0.1441285h, 0.1470273h, 0.1499598h, 0.1529262h, 0.1559265h, 0.1589608h,\n"
	"0.1620294h, 0.1651322h, 0.1682694h, 0.1714411h, 0.1746474h, 0.1778884h, 0.1811642h, 0.184475h,\n"
	"0.1878208h, 0.1912017h, 0.1946178h, 0.1980693h, 0.2015563h, 0.2050787h, 0.2086369h, 0.2122308h,\n"
	"0.2158605h, 0.2195262h, 0.223228h, 0.2269659h, 0.23074h, 0.2345506h, 0.2383976h, 0.2422811h,\n"
	"0.2462013h, 0.2501583h, 0.2541521h, 0.2581829h, 0.2622507h, 0.2663556h, 0.2704978h, 0.2746773h,\n"
	"0.2788943h, 0.2831487h, 0.2874408h, 0.2917706h, 0.2961383h, 0.3005438h, 0.3049873h, 0.3094689h,\n"
	"0.3139887h, 0.3185468h, 0.3231432h, 0.3277781h, 0.3324515h, 0.3371636h, 0.3419144h, 0.3467041h,\n"
	"0.3515326h, 0.3564001h, 0.3613068h, 0.3662526h, 0.3712377h, 0.3762621h, 0.381326h, 0.3864294h,\n"
	"0.3915725h, 0.3967552h, 0.4019778h, 0.4072402h, 0.4125426h, 0.4178851h, 0.4232677h, 0.4286905h,\n"
	"0.4341536h, 0.4396572h, 0.4452012h, 0.4507858h, 0.456411h, 0.462077h, 0.4677838h, 0.4735315h,\n"
	"0.4793202h, 0.4851499h, 0.4910208h, 0.496933h, 0.5028865h, 0.5088813h, 0.5149177h, 0.5209956h,\n"
	"0.5271151h, 0.5332764h, 0.5394795h, 0.5457245h, 0.5520114h, 0.5583404h, 0.5647115h, 0.5711248h,\n"
	"0.5775804h, 0.5840784h, 0.5906188h, 0.5972018h, 0.6038273h, 0.6104956h, 0.6172066h, 0.6239604h,\n"
	"0.6307571h, 0.6375969h, 0.6444797h, 0.6514056h, 0.6583748h, 0.6653873h, 0.6724432h, 0.6795425h,\n"
	"0.6866853h, 0.6938718h, 0.7011019h, 0.7083758h, 0.7156935h, 0.7230551h, 0.7304607h, 0.7379104h,\n"
	"0.7454042h, 0.7529422h, 0.7605245h, 0.7681511h, 0.7758222h, 0.7835378h, 0.7912979h, 0.7991027h,\n"
	"0.8069523h, 0.8148466h, 0.8227858h, 0.8307699h, 0.838799h, 0.8468732h, 0.8549926h, 0.8631572h,\n"
	"0.8713671h, 0.8796224h, 0.8879231h, 0.8962694h, 0.9046612h, 0.9130987h, 0.9215819h, 0.9301109h,\n"
	"0.9386857h, 0.9473065h, 0.9559734h, 0.9646862h, 0.9734453h, 0.9822506h, 0.9911021h, 1.0h\n"
	"};\n"
	"static inline half3 srgbToLinear8(half3 c) {\n"
	"  ushort3 i = ushort3(clamp(c * 255.0h + 0.5h, 0.0h, 255.0h));\n"
	"  return half3(SRGB_TO_LIN[i.x], SRGB_TO_LIN[i.y], SRGB_TO_LIN[i.z]);\n"
	"}\n"
	// linear Rec.709 -> linear Display P3 (both D65): every coefficient >= 0, so non-negative stays non-negative
	"constant float3x3 M709toP3 = float3x3(float3(0.822462, 0.033194, 0.017083), float3(0.177538, 0.966806, 0.072397), float3(0.0, 0.0, 0.910520));\n"
	"constant half3x3 M709toP3h = half3x3(half3(0.822462h, 0.033194h, 0.017083h), half3(0.177538h, 0.966806h, 0.072397h), half3(0.0h, 0.0h, 0.910520h));\n"
	// (1.2.5) two entry points: the full-scene compose (PR #6) is its own pipeline, so the default highlights compose runs 1.2.4's code
	"fragment half4 xdr_compose_fs(V v [[stage_in]], texture2d<half> src [[texture(0)]], texture2d<half> excess [[texture(1)]],\n"
	"                              texture2d<half> base [[texture(2)]], constant XdrParams &p [[buffer(0)]]) {\n"
	"  uint2 px = uint2(v.pos.xy);\n"
	"  if (p.flip != 0) px.y = src.get_height() - 1 - px.y;\n"
	"  half4 m = src.read(px);\n"
	"  half3 lin = srgbToLinear8(saturate(m.rgb));\n"
	"  if (p.valid != 0) {\n"
	"    half3 ex;\n"
	"    if (excess.get_width() == src.get_width() && excess.get_height() == src.get_height()) {\n"
	"      ex = excess.read(px).rgb;\n"
	"    } else {\n"
	"      constexpr sampler ls(filter::linear, address::clamp_to_edge);\n"
	"      float2 euv = (float2(px) + 0.5) / float2(src.get_width(), src.get_height());\n"
	"      ex = excess.sample(ls, euv).rgb;\n"
	"    }\n"
	"    bool bad = any((as_type<ushort3>(ex) & ushort3(0x7c00)) == ushort3(0x7c00));\n"
	"    if (!bad) lin += ex * saturate(1.0h - m.a);\n"
	"  }\n"
	"  half3 oh = M709toP3h * lin;\n"
	"  return p.e5 != 0 ? half4(half3(e5(float3(oh))), 1.0h) : half4(oh, 1.0h);\n"
	"}\n"
	"fragment float4 xdr_compose_full_fs(V v [[stage_in]], texture2d<float> src [[texture(0)]], texture2d<half> excess [[texture(1)]],\n"
	"                                    texture2d<float> base [[texture(2)]], constant XdrParams &p [[buffer(0)]]) {\n"
	"  uint2 px = uint2(v.pos.xy);\n"
	"  if (p.flip != 0) px.y = src.get_height() - 1 - px.y;\n"
	"  float4 m = src.read(px);\n"
	"  float3 lin = float3(srgbToLinear8(half3(saturate(m.rgb))));\n"
	"  if (p.valid != 0) {\n"
	"    half3 ex;\n"
	"    if (excess.get_width() == src.get_width() && excess.get_height() == src.get_height()) {\n"
	"      ex = excess.read(px).rgb;\n"
	"    } else {\n"
	"      constexpr sampler ls(filter::linear, address::clamp_to_edge);\n"
	"      float2 euv = (float2(px) + 0.5) / float2(src.get_width(), src.get_height());\n"
	"      ex = excess.sample(ls, euv).rgb;\n"
	"    }\n"
	"    bool bad = any((as_type<ushort3>(ex) & ushort3(0x7c00)) == ushort3(0x7c00));\n"
	"    float3 hdr = bad ? float3(0.0) : float3(ex);\n"
	"    if (!bad) {\n"
	"      float a = saturate(m.a); float3 b = base.read(px).rgb;\n"
	"      if (a > 0.0) {\n"
	"        float3 ui = saturate((m.rgb - b * (1.0 - a)) / a);\n"
	"        lin = hdr * (1.0 - a) + srgbToLinear(ui) * (a * p.uiWhite);\n"
	"      } else {\n"
	"        float3 delta = lin - float3(srgbToLinear8(half3(saturate(b))));\n"
	"        lin = hdr + min(delta, 0.0) + max(delta, 0.0) * p.uiWhite;\n"
	"      }\n"
	"      lin = max(lin, 0.0);\n"
	"      lin /= max(1.0, max(max(lin.r, lin.g), lin.b) / p.peak);\n"
	"    } else lin += hdr * saturate(1.0 - m.a);\n"
	"  }\n"
	"  float3 o = M709toP3 * lin;\n"
	"  return float4(p.e5 != 0 ? e5(o) : o, 1.0);\n"
	"}\n"
	// the present side's copy into an RGBA16Float drawable (the staging slot already holds the composed image)
	"fragment half4 xdr_present_fs(V v [[stage_in]], texture2d<half> t [[texture(0)]]) {\n"
	"  constexpr sampler s(filter::nearest, address::clamp_to_edge);\n"
	"  return t.sample(s, v.uv);\n"
	"}\n";

void mc_xdr_enable(int on) { xdrOn = on; }
// (v12-opt) the direct compose (presentQueue off) rounds like the queued path's RGB9E5 slot (default on; ShadeXdr.configure)
static int xdrE5 = 1;
void mc_xdr_e5(int on) { xdrE5 = on; }
int mc_xdr_on(void) { return xdrOn; }

// Whether any screen can show EDR at all (maximumPotentialExtendedDynamicRangeColorComponentValue > 1): "auto".
int mc_xdr_supported(void) {
	@autoreleasepool {
		for (NSScreen *s in [NSScreen screens]) {
			if (s.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.01) return 1;
		}
	}
	return 0;
}

static NSScreen *layerScreen(CAMetalLayer *layer) {
	id d = layer ? layer.delegate : nil;
	if (d && [d isKindOfClass:[NSView class]]) {
		NSWindow *w = ((NSView *) d).window;
		if (w && w.screen) return w.screen;
	}
	CALayer *l = layer;
	while (l) { // a hosted layer: the view is the delegate of an ancestor
		id dd = l.delegate;
		if (dd && [dd isKindOfClass:[NSView class]] && ((NSView *) dd).window.screen) return ((NSView *) dd).window.screen;
		l = l.superlayer;
	}
	return [NSScreen mainScreen];
}

// (1.1.1) The display the layer's window is on (its CGDirectDisplayID), for the present pacer's refresh grid (mc_pace); 0
// when unknown or off the main thread (AppKit), so the pacer keeps the display it has.
uint32_t mc_layer_display(CAMetalLayer *layer) {
	if (!layer || ![NSThread isMainThread]) return 0;
	@autoreleasepool {
		NSScreen *s = layerScreen(layer);
		NSNumber *n = s ? s.deviceDescription[@"NSScreenNumber"] : nil;
		return n ? n.unsignedIntValue : 0;
	}
}

// (2.0.1e) Top refresh rate (Hz) of the display the layer's window is on (e.g. 120 on ProMotion, 144 on an external monitor,
// 60 on an SDR panel); 0 when unknown or off the main thread. Used with direct VSync so a software framerateLimit >= refresh
// doesn't fight hardware VSync.
int mc_layer_refresh_hz(CAMetalLayer *layer) {
	if (!layer || ![NSThread isMainThread]) return 0;
	@autoreleasepool {
		NSScreen *s = layerScreen(layer);
		if (!s) return 0;
		NSInteger hz = s.maximumFramesPerSecond;
		return hz > 0 ? (int) hz : 0;
	}
}

// (1.1.1) One line for bug reports (latest.log): the OS version and build, Low Power Mode, and every screen (pixels, top
// refresh rate, potential EDR headroom), the window's marked with *.
void mc_system_info(CAMetalLayer *layer, char *out, int cap) {
	@autoreleasepool {
		NSScreen *mine = [NSThread isMainThread] ? layerScreen(layer) : nil;
		NSProcessInfo *p = [NSProcessInfo processInfo];
		NSMutableString *s = [NSMutableString stringWithFormat:@"macOS %@%@", p.operatingSystemVersionString, p.lowPowerModeEnabled ? @", Low Power Mode" : @""];
		for (NSScreen *sc in [NSScreen screens]) {
			NSSize px = [sc convertRectToBacking:sc.frame].size;
			[s appendFormat:@"; %@%@ (display %@) %.0fx%.0f %ld Hz EDR %.1f", sc == mine ? @"*" : @"", sc.localizedName,
				sc.deviceDescription[@"NSScreenNumber"], px.width, px.height, (long) sc.maximumFramesPerSecond,
				sc.maximumPotentialExtendedDynamicRangeColorComponentValue];
		}
		snprintf(out, cap, "%s", s.UTF8String);
	}
}

// (1.2.5, ShadeDiag) The OS's thermal state: 0 nominal, 1 fair, 2 serious, 3 critical (NSProcessInfoThermalState).
int mc_thermal_state(void) {
	@autoreleasepool {
		return (int) [NSProcessInfo processInfo].thermalState;
	}
}

// The current EDR headroom of the layer's screen (1 = SDR only; rises once an EDR layer is on screen; depends on the
// brightness slider), or its potential with potential = 1.
float mc_xdr_headroom(CAMetalLayer *layer, int potential) {
	@autoreleasepool {
		NSScreen *s = layerScreen(layer);
		if (!s) return 1.0f;
		return (float) (potential ? s.maximumPotentialExtendedDynamicRangeColorComponentValue : s.maximumExtendedDynamicRangeColorComponentValue);
	}
}

// From the final pass: this frame's excess image (nil: none this frame). Used by this frame's compose only (same command
// buffer): a frame whose present was skipped or paced away leaves nothing for a later menu frame.
void mc_xdr_frame(Enc *enc, id<MTLTexture> excess) {
	xdrFull = 0;
	xdrCmd = (void *) enc->cmd;
	if (excess != xdrExcess) {
		[excess retain];
		[xdrExcess release];
		xdrExcess = excess;
	}
	xdrValid = excess != nil;
}

// Snapshot after output upscaling, before the hand and HUD. The command buffer
// retains resources in flight; replacing the snapshot on resize is safe.
void mc_xdr_full_frame(Enc *enc, id<MTLTexture> hdr, id<MTLTexture> main, float uiWhite, float peak) {
	mc_xdr_frame(enc, nil); // allocation failure must fall back to the SDR compatibility image
	if (!hdr || !main) return;
	if (!xdrBase || xdrBase.width != main.width || xdrBase.height != main.height || xdrBase.pixelFormat != main.pixelFormat) {
		[xdrBase release];
		MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:main.pixelFormat width:main.width height:main.height mipmapped:NO];
		d.storageMode = MTLStorageModePrivate;
		d.usage = MTLTextureUsageShaderRead;
		xdrBase = [main.device newTextureWithDescriptor:d];
		xdrBase.label = @"mcopt shade: SDR world reference";
	}
	if (!xdrBase) return;
	id<MTLCommandBuffer> cb = mc_frame_cmd(enc);
	id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
	[b copyFromTexture:main toTexture:xdrBase];
	[b endEncoding];
	mc_xdr_frame(enc, hdr);
	xdrFull = 1;
	xdrUiWhite = fmaxf(0.25f, fminf(uiWhite, 2.0f));
	xdrPeak = fmaxf(1.0f, fminf(peak, 16.0f));
}

static int ensurePipelines(id<MTLDevice> device) {
	if (xdrCompose && xdrCompose16 && xdrPresent) return 1;
	@autoreleasepool {
		NSError *e = nil;
		if (!xdrLib) {
			// (1.1.1) pinned to MSL 3.0 like the other shade libraries: with no options a library compiles as the newest MSL
			// the OS has (4.1 on macOS 27), so the same source would build differently there (math stays the default, relaxed)
			MTLCompileOptions *o = [[MTLCompileOptions new] autorelease];
			o.languageVersion = MTLLanguageVersion3_0;
			xdrLib = [device newLibraryWithSource:[NSString stringWithUTF8String:xdrSource] options:o error:&e];
		}
		if (!xdrLib) {
			NSLog(@"mcopt shade xdr: %@", e);
			return 0;
		}
		MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor new] autorelease];
		pd.vertexFunction = [[xdrLib newFunctionWithName:@"xdr_vs"] autorelease];
		pd.fragmentFunction = [[xdrLib newFunctionWithName:@"xdr_compose_fs"] autorelease];
		// the staging slot: shared-exponent RGB9E5 (4 B/px: 9-bit mantissas, plenty for an image up to ~16x SDR white) instead
		// of RGBA16Float, half the bytes of the compose write and the present read; the drawable itself is RGBA16Float
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGB9E5Float;
		xdrCompose = [device newRenderPipelineStateWithDescriptor:pd error:&e];
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
		xdrCompose16 = [device newRenderPipelineStateWithDescriptor:pd error:&e];
		// (1.2.5) PR #6's full-scene compose (nil if it fails: that frame then composes as highlights)
		pd.fragmentFunction = [[xdrLib newFunctionWithName:@"xdr_compose_full_fs"] autorelease];
		xdrComposeFull16 = [device newRenderPipelineStateWithDescriptor:pd error:&e];
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGB9E5Float;
		xdrComposeFull = [device newRenderPipelineStateWithDescriptor:pd error:&e];
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
		pd.fragmentFunction = [[xdrLib newFunctionWithName:@"xdr_present_fs"] autorelease];
		xdrPresent = [device newRenderPipelineStateWithDescriptor:pd error:&e];
		if (!xdrCompose || !xdrCompose16 || !xdrPresent) NSLog(@"mcopt shade xdr: %@", e);
	}
	return xdrCompose && xdrCompose16 && xdrPresent;
}

// mc_layer_configure: whether the EDR layer can be used (the compose / present pipelines built). If not, the output is
// turned off for good (an RGBA8 layer, the plain copy; the Java side sees mc_xdr_on() = 0 and stops writing the excess).
int mc_xdr_ready(id<MTLDevice> device) {
	if (!xdrOn) return 0;
	if (!ensurePipelines(device)) xdrOn = 0;
	return xdrOn;
}

// The present pipeline for an RGBA16Float drawable (nil: use the backend's own).
id<MTLRenderPipelineState> mc_xdr_present_pso(id<MTLDevice> device) {
	return ensurePipelines(device) ? xdrPresent : nil;
}

// Verification aid (env MCOPT_XDR_DUMP=<path prefix>): every 8 s one composed frame is written as raw RGBA16Float
// (<prefix>-<n>-<w>x<h>.rgb9e5 / .rgba16f, linear extended Display P3; at most MCOPT_XDR_DUMP_MAX, default 24) for offline
// inspection (screenshots only see the SDR image).
static void dumpMaybe(id<MTLCommandBuffer> cb, id<MTLTexture> dst, int valid) {
	static const char *prefix;
	static int checked, n, max;
	static double last;
	if (!checked) {
		checked = 1;
		prefix = getenv("MCOPT_XDR_DUMP");
		const char *m = getenv("MCOPT_XDR_DUMP_MAX"); // at most this many files (default 24; ~24 MB each at 3024x1964)
		max = m ? atoi(m) : 24;
	}
	if (!prefix || !valid || n >= max) return;
	double now = CACurrentMediaTime();
	if (now - last < 8.0) return;
	last = now;
	NSUInteger bpp = dst.pixelFormat == MTLPixelFormatRGB9E5Float ? 4 : 8;
	NSUInteger w = dst.width, h = dst.height, bytes = w * h * bpp;
	id<MTLBuffer> buf = [cb.device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
	id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
	[b copyFromTexture:dst sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:buf
		destinationOffset:0 destinationBytesPerRow:w * bpp destinationBytesPerImage:bytes];
	[b endEncoding];
	int k = n++;
	char path[1024];
	snprintf(path, sizeof path, "%s-%d-%lux%lu.%s", prefix, k, (unsigned long) w, (unsigned long) h, bpp == 4 ? "rgb9e5" : "rgba16f");
	char *pathCopy = strdup(path);
	[cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
		FILE *fp = fopen(pathCopy, "wb");
		if (fp) {
			fwrite(buf.contents, 1, bytes, fp);
			fclose(fp);
		}
		free(pathCopy);
		[buf release];
	}];
}

// Composes src (the game's finished RGBA8 frame) and this frame's excess into dst (RGBA16Float: a staging slot, or the drawable
// with flip = 1) on cb. Returns 0 if it couldn't (the caller falls back to its own copy).
int mc_xdr_compose(id<MTLCommandBuffer> cb, id<MTLTexture> src, id<MTLTexture> dst, int flip) {
	if (!ensurePipelines(cb.device)) return 0;
	@autoreleasepool {
		MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
		rp.colorAttachments[0].texture = dst;
		rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
		rp.colorAttachments[0].storeAction = MTLStoreActionStore;
		id<MTLRenderCommandEncoder> r = [cb renderCommandEncoderWithDescriptor:rp];
		r.label = @"mcopt shade: XDR compose";
		// (FT2.7, audit idx 42/52) no size test: the compose samples the excess by uv, and with outputMode=taau below native the
		// excess is the output's size, not the window's (the equality dropped every XDR highlight there); this frame's final pass
		// wrote it (the same command buffer)
		int valid = xdrValid && (void *) cb == xdrCmd && xdrExcess && xdrExcess.width <= src.width && xdrExcess.height <= src.height;
		// (v12-opt) straight into an RGBA16Float drawable (flip, presentQueue off): the staging slot's RGB9E5 rounding too, so both
		// present paths show the same pixels (mc_xdr_e5(0), -Dmcopt.shade.xdrDirectE5=false: without it, as 1.2)
		int e5 = flip && dst.pixelFormat == MTLPixelFormatRGBA16Float && xdrE5;
		int full = valid && xdrFull && xdrBase && xdrBase.width == src.width && xdrBase.height == src.height;
		if (full && !(dst.pixelFormat == MTLPixelFormatRGB9E5Float ? xdrComposeFull : xdrComposeFull16)) full = 0;
		if (xdrFull && !full) valid = 0; // never interpret a complete HDR image as highlight excess
		BOOL e9 = dst.pixelFormat == MTLPixelFormatRGB9E5Float;
		[r setRenderPipelineState:full ? (e9 ? xdrComposeFull : xdrComposeFull16) : (e9 ? xdrCompose : xdrCompose16)];
		struct { int flip, valid, e5, full; float uiWhite, peak, pad[2]; } p = {flip, valid, e5, full, xdrUiWhite, xdrPeak, {0, 0}};
		[r setFragmentTexture:src atIndex:0];
		[r setFragmentTexture:valid ? xdrExcess : src atIndex:1];
		[r setFragmentTexture:full ? xdrBase : src atIndex:2];
		[r setFragmentBytes:&p length:sizeof p atIndex:0];
		[r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[r endEncoding];
		if (!flip) dumpMaybe(cb, dst, valid);
	}
	xdrValid = 0;
	return 1;
}

// ---- the final pass's two targets (shade's MRT variant of mc_shade_pass) ---------------------------------------------------
int mc_shade_bind_render(id<MTLRenderCommandEncoder> r);

id<MTLRenderPipelineState> mc_xdr_pso2(Ctx *ctx, id<MTLLibrary> lib, const char *vs, const char *fs, int format0, int format1, char *err, int errCap) {
	@autoreleasepool {
		MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor new] autorelease];
		pd.vertexFunction = [[lib newFunctionWithName:[NSString stringWithUTF8String:vs]] autorelease];
		pd.fragmentFunction = [[lib newFunctionWithName:[NSString stringWithUTF8String:fs]] autorelease];
		pd.colorAttachments[0].pixelFormat = (MTLPixelFormat) format0;
		pd.colorAttachments[1].pixelFormat = (MTLPixelFormat) format1;
		NSError *e = nil;
		id<MTLRenderPipelineState> pso = pd.vertexFunction && pd.fragmentFunction ? [ctx->device newRenderPipelineStateWithDescriptor:pd error:&e] : nil;
		if (!pso && err) strlcpy(err, e ? e.localizedDescription.UTF8String : "missing function", errCap);
		return pso;
	}
}

// mc_shade_pass with two color targets (both DONT_CARE / store), inputs at texture(0..count-1), bytes at buffer(0).
void mc_xdr_pass2(Enc *enc, id<MTLRenderPipelineState> pso, id<MTLTexture> t0, id<MTLTexture> t1, id<MTLTexture> const *textures, int count,
                  const void *bytes, int length, const char *label) {
	if (!pso || !t0 || !t1) return;
	@autoreleasepool {
		id<MTLCommandBuffer> cb = mc_frame_cmd(enc);
		MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
		rp.colorAttachments[0].texture = t0;
		rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
		rp.colorAttachments[0].storeAction = MTLStoreActionStore;
		rp.colorAttachments[1].texture = t1;
		rp.colorAttachments[1].loadAction = MTLLoadActionDontCare;
		rp.colorAttachments[1].storeAction = MTLStoreActionStore;
		id<MTLRenderCommandEncoder> r = [cb renderCommandEncoderWithDescriptor:rp];
		if (label) r.label = [NSString stringWithUTF8String:label];
		[r setRenderPipelineState:pso];
		mc_shade_bind_render(r);
		for (int i = 0; i < count; i++) if (textures[i]) [r setFragmentTexture:textures[i] atIndex:i];
		if (bytes && length > 0) [r setFragmentBytes:bytes length:length atIndex:0];
		[r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[r endEncoding];
	}
}
