/*
 * Copyright 2026 mcopt-shade contributors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package mcopt.metal.shade;

import com.mojang.blaze3d.pipeline.RenderTarget;
import com.mojang.renderpearl.api.commands.RenderPassDescriptor;
import com.mojang.renderpearl.api.textures.GpuTexture;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import mcopt.metal.MetalBridge;
import mcopt.metal.MetalHooks;
import org.joml.Vector4fc;
import org.jspecify.annotations.Nullable;
import org.lwjgl.system.MemoryUtil;

/**
 * M2's HDR frame (bible §1.3, H5/H7/H8):
 * <ol>
 * <li><b>World phase</b> (LevelRenderer.render HEAD to render3dHud): every render pass whose color attachment is the game's
 * main color texture draws into the HDR world target instead (a format redirect: MetalHooks.Redirect.formats, through the
 * pipelines' RGBA16Float variants), keeping the main depth. Shaded pipelines write pre-exposed radiance there; the game's
 * others are converted from display-referred colours (shade_look.metal, shadeLdrToHdr, patched in by ShadeMsl's format
 * adapter).</li>
 * <li><b>Distant Horizons bridge</b>: DH's passes ("distantHorizons:*") composite into the main RGBA8 texture from a copy of
 * it, so before the first one the HDR world is tone-mapped into main (shade_bridge_encode), and before the next world pass
 * the pixels DH changed come back into the HDR target (shade_bridge_decode).</li>
 * <li><b>Before the hand</b> (render3dHud HEAD): hooks registered with {@link #addBeforeTonemap} (volumetric light, ...), then
 * bloom (13-tap down / tent up, octave spectrum), the exposure histogram and its reduce (ShadeGpu.exposure for the next
 * frame), and the final pass: bloom + fog glow, Purkinje, vignette, Shade Filmic, dither into the main RGBA8 target. The hand,
 * screen effects and the GUI then draw over it as in vanilla.</li>
 * </ol>
 * Without TAA two HDR targets alternate per frame, so last frame's stays readable (ShadeResources.prevScene, for SSR); with
 * TAA there is one, and prevScene is the TAA history. Render thread only.
 */
public final class ShadePost {
	/** Something that runs right before the tone map, with the world's HDR image and depth (VL, atmosphere composite...). */
	public interface Hook {
		void run(Context c);
	}

	/**
	 * What a hook gets. enc: the native Enc* (encode with ShadeRender.pass / dispatch, or your own natives on its command
	 * buffer). scene: this frame's HDR world target (MTLTexture; format hdrFormat; pre-exposed radiance, ShadeGpu.exposure.x);
	 * prevScene: last frame's (exposure ShadeGpu.exposure.z); depth: the main depth (Depth32Float, reversed Z, world only:
	 * read before the hand pass clears it). width x height: the live render size, i.e. the sub-rect (0, 0, width, height) of
	 * scene and depth that this frame drew (TAAU dynamic resolution: the textures are texWidth x texHeight, allocated once
	 * at the preset's maximum scale; without TAAU both sizes are equal). A hook may draw into scene (load action LOAD).
	 */
	public record Context(long enc, Object encoder, long scene, long prevScene, long depth, int width, int height, int hdrFormat, ShadeFrame frame,
		ShadeLook look, int texWidth, int texHeight) {
	}

	/**
	 * Replaces the image the post chain works on (TAAU: resolves this frame's internal-resolution scene, plus its history,
	 * into an output-resolution HDR image). Returns that texture (pre-exposed linear, any size; bloom, the exposure meter and
	 * the tone map read it), or 0 to keep c.scene(). Runs after the before-tonemap hooks.
	 */
	public interface Resolver {
		long resolve(Context c);
	}

	private static volatile @Nullable Resolver resolver;

	/** Installs the resolver (one at a time; null removes it). */
	public static void setResolver(@Nullable Resolver r) {
		resolver = r;
	}

	private record Ordered(int order, Hook hook) {
	}

	private static final List<Ordered> BEFORE_TONEMAP = new ArrayList<>();

	/** Adds a hook run before bloom and the tone map each frame (lower order first). */
	public static synchronized void addBeforeTonemap(int order, Hook hook) {
		BEFORE_TONEMAP.add(new Ordered(order, hook));
		BEFORE_TONEMAP.sort((a, b) -> Integer.compare(a.order, b.order));
	}

	// ---- state -----------------------------------------------------------------------------------------------------------
	private static boolean initialized, failed;
	private static long library, psoDown0, psoDown, psoUp, psoFinal, psoEncode, psoDecode, psoHistogram, psoExposure, milkyWay;
	/** M3 XDR (mcopt.shade.xdr, dims.ShadeXdr): the final pass with a second target, the highlights' excess above SDR white. */
	private static long psoFinalXdr, xdrExcess;
	private static long psoFinalHdr, psoFinalHdrDims, psoFinalHdrLean;
	private static int xdrFormat;
	// M3: the final pass with the Nether/End fog, End sky, shimmer and camera media compiled in (the plain ones carry none of it)
	private static long psoFinalDims, psoFinalXdrDims;
	/**
	 * (v12-opt) The overworld final pass without the code of settings that are off by default (the volumetric light's edge fix,
	 * its upsample modes other than 1, the debug views; shade_post.metal LEAN): picked while those are at their defaults, the
	 * same image ~0.25 ms cheaper at 3024x1964 (fewer live registers). mcopt.shade.finalLean (live, true; false = the full pass).
	 */
	private static long psoFinalLean, psoFinalXdrLean;
	private static boolean loggedLean;
	private static int xdrWidth, xdrHeight;
	/**
	 * (2026-10-09) The output resolution (ShadeOutput, below the window's): the final pass writes this RGBA8 image at the output
	 * size, then shade_upscale fills the window's target from it.
	 */
	private static long psoUpscale, outScaled;
	private static int outScaledWidth, outScaledHeight;
	private static final ByteBuffer UPSCALE_PARAMS = ByteBuffer.allocateDirect(16).order(ByteOrder.LITTLE_ENDIAN);
	private static final long[] hdr = new long[2];
	private static long[] bloomLevels = new long[0], bloomAccum = new long[0];
	private static int width, height, frame, bloomWidth, bloomHeight;
	/** World passes are being redirected (between LevelRenderer.render HEAD and the tone map). */
	private static boolean world;
	private static boolean bridgeOpen, bridgeUsed;
	/** This HDR target pair has had a frame finished into it since its allocation (prevScene is readable next frame). */
	private static boolean prevWritten;
	private static @Nullable GpuTexture mainColor;
	private static @Nullable Object encoder;
	private static long enc;
	/** Textures waiting for the frames that may still use them to finish: {handle, frame to release at}. */
	private static final List<long[]> retired = new ArrayList<>();
	private static final ByteBuffer params = ByteBuffer.allocateDirect(96).order(ByteOrder.LITTLE_ENDIAN);
	private static boolean loggedDh;
	/** This frame's live render size (the TAAU sub-rect of the HDR targets; = width x height without TAAU) and world depth. */
	private static int liveWidth, liveHeight;
	private static @Nullable GpuTexture worldDepth;
	/** M2.2: under TAAU the final pass reads depth and the volumetric light where this frame's jittered raster shows the pixel's
	 * scene point (mcopt.shade.vl.unjitter, default true; false = at the output uv, M2/M2.1: they moved by the jitter). */
	private static final boolean VL_UNJITTER = Boolean.parseBoolean(System.getProperty("mcopt.shade.vl.unjitter", "true"));
	/** (FT2.8, audit idx 110) DH's composite draws on the world's depth, so the next world pass continues its encoder. */
	private static final boolean DH_MERGE_MAIN = !"false".equals(System.getProperty("mcopt.shade.dh.mergeMain"));
	/** (FT2.8, audit idx 112) DH's far fade and intermediate copy don't load the colour they overwrite whole. */
	private static final boolean DH_NO_LOAD = !"false".equals(System.getProperty("mcopt.shade.dh.noLoad"));
	/** Bloom's first level: xy the part of its source's uv range that holds the image (the TAAU sub-rect). */
	private static final ByteBuffer downParams = ByteBuffer.allocateDirect(16).order(ByteOrder.LITTLE_ENDIAN);
	/** This frame's volumetric light for the final pass (setVolumetric): light + T, its distances, max distance. */
	private static long vlLight, vlDist;
	/** (FT2.8) this frame's bloom level the exposure histogram reads, dispatched after the final pass (0: none). */
	private static long histogramSource;
	private static float vlMaxDist, vlScaleU = 1f, vlScaleV = 1f, vlAirFloor;

	private ShadePost() {
	}

	/** The HDR world target of this frame (MTLTexture), or 0 outside HDR mode or before the first frame. */
	public static long sceneTexture() {
		return ShadeConfig.HDR && initialized ? hdr[frame & 1] : 0;
	}

	/**
	 * Folds a volumetric result into this frame's final pass (call from a before-tonemap hook; reset every frame): light: rgb
	 * in-scattered radiance before exposure, a = transmittance of its medium (the final pass does scene * a + rgb * exposure
	 * after the haze, before bloom's mix); dist: same size, a = the distance each texel stands for (blocks, 1e4 = sky), for
	 * the depth-aware upsample; maxDist: the march's max distance. Any resolution (upsampled by uv). Saves a full-resolution
	 * read-modify-write of the HDR target over a composite pass; bloom and the exposure meter then don't see the light.
	 */
	public static void setVolumetric(long light, long dist, float maxDist) {
		setVolumetric(light, dist, maxDist, 1f, 1f);
	}

	/** The same, when only the part (0, 0, uScale, vScale) of the textures' uv range holds this frame's light. */
	public static void setVolumetric(long light, long dist, float maxDist, float uScale, float vScale) {
		setVolumetric(light, dist, maxDist, uScale, vScale, 0f);
	}

	/**
	 * The same; airFloor > 0 (godrays v3, the VL module's air mode): the light may be negative on surfaces too (the shadows taking
	 * the haze's sunlit glow out of it), down to airFloor x the surface's light, and no knee on it.
	 */
	public static void setVolumetric(long light, long dist, float maxDist, float uScale, float vScale, float airFloor) {
		vlAirFloor = airFloor;
		vlLight = light;
		vlDist = dist;
		vlMaxDist = maxDist;
		vlScaleU = uScale;
		vlScaleV = vScale;
	}

	/** TAAU when it drives this frame (on, set up and standing in for the main target), else null. */
	private static mcopt.metal.shade.taa.@Nullable ShadeTaa taa() {
		if (!mcopt.metal.shade.taa.ShadeTaa.ON) return null;
		mcopt.metal.shade.taa.ShadeTaa t = mcopt.metal.shade.taa.ShadeTaa.get();
		return t != null && t.swapped() && t.outputTarget() != null ? t : null;
	}

	/** This frame's live render size (the TAAU sub-rect of the HDR target, or its whole size). */
	public static int liveWidth() {
		return liveWidth;
	}

	public static int liveHeight() {
		return liveHeight;
	}

	/** Whether world passes are currently redirected into the HDR target. */
	public static boolean inWorld() {
		return world;
	}

	static synchronized boolean init() {
		if (initialized) return true;
		if (failed || !ShadeConfig.HDR) return false;
		try {
			long t0 = ShadeCompile.now();
			library = ShadeRender.library(ShadeMsl.post());
			psoDown0 = ShadeRender.pipeline(library, "shade_fs_vs", "shade_bloom_down0", ShadeRender.RGBA16F, 0);
			psoDown = ShadeRender.pipeline(library, "shade_fs_vs", "shade_bloom_down", ShadeRender.RGBA16F, 0);
			psoUp = ShadeRender.pipeline(library, "shade_fs_vs", "shade_bloom_up", ShadeRender.RGBA16F, 0);
			psoFinal = ShadeRender.pipeline(library, "shade_fs_vs", "shade_final", ShadeRender.RGBA8, 0);
			psoUpscale = ShadeRender.pipeline(library, "shade_fs_vs", "shade_upscale", ShadeRender.RGBA8, 0);
			psoFinalLean = ShadeRender.pipeline(library, "shade_fs_vs", "shade_final_lean", ShadeRender.RGBA8, 0);
			boolean dimsVariant = mcopt.metal.shade.dims.DimsConfig.DIMS || mcopt.metal.shade.dims.DimsConfig.MEDIA;
			if (dimsVariant) psoFinalDims = ShadeRender.pipeline(library, "shade_fs_vs", "shade_final_dims", ShadeRender.RGBA8, 0);
			if (mcopt.metal.shade.dims.ShadeXdr.active()) {
				psoFinalHdr = mcopt.metal.shade.dims.ShadeXdr.pipeline2(ShadeBindings.ctx(), library, "shade_fs_vs", "shade_final_hdr", ShadeRender.RGBA8, ShadeRender.RGBA16F);
				psoFinalHdrLean = mcopt.metal.shade.dims.ShadeXdr.pipeline2(ShadeBindings.ctx(), library, "shade_fs_vs", "shade_final_hdr_lean", ShadeRender.RGBA8, ShadeRender.RGBA16F);
				if (dimsVariant) psoFinalHdrDims = mcopt.metal.shade.dims.ShadeXdr.pipeline2(ShadeBindings.ctx(), library, "shade_fs_vs", "shade_final_hdr_dims", ShadeRender.RGBA8, ShadeRender.RGBA16F);
				psoFinalXdr = mcopt.metal.shade.dims.ShadeXdr.pipeline2(ShadeBindings.ctx(), library, "shade_fs_vs", "shade_final_xdr", ShadeRender.RGBA8,
					ShadeRender.RG11B10F);
				psoFinalXdrLean = mcopt.metal.shade.dims.ShadeXdr.pipeline2(ShadeBindings.ctx(), library, "shade_fs_vs", "shade_final_xdr_lean",
					ShadeRender.RGBA8, ShadeRender.RG11B10F);
				if (dimsVariant) psoFinalXdrDims = mcopt.metal.shade.dims.ShadeXdr.pipeline2(ShadeBindings.ctx(), library, "shade_fs_vs", "shade_final_xdr_dims",
					ShadeRender.RGBA8, ShadeRender.RG11B10F);
			}
			psoEncode = ShadeRender.pipeline(library, "shade_fs_vs", "shade_bridge_encode", ShadeRender.RGBA8, 0);
			psoDecode = ShadeRender.pipeline(library, "shade_fs_vs", "shade_bridge_decode", ShadeConfig.HDR_FORMAT, 0);
			psoHistogram = ShadeRender.computePipeline(library, "shade_histogram");
			psoExposure = ShadeRender.computePipeline(library, "shade_exposure");
			long bake = ShadeRender.pipeline(library, "shade_fs_vs", "shade_milkyway_bake", ShadeRender.RGBA16F, 0);
			ShadeCompile.setup("post chain", t0);
			milkyWay = ShadeRender.texture(ShadeRender.RGBA16F, 1024, 512, false, "mcopt shade: Milky Way");
			ShadeNative.bake(ShadeBindings.ctx(), bake, milkyWay);
			MetalBridge.release(bake);
			ShadeRender.resource(0, milkyWay);
			MetalHooks.addRedirector(0, ShadePost::redirect);
			initialized = true;
			System.out.println("[mcopt] shade: HDR post chain ready (" + ShadeConfig.describe() + "; " + mcopt.metal.shade.dims.DimsConfig.describe() + ")");
			return true;
		} catch (Throwable e) {
			failed = true;
			System.out.println("[mcopt] shade: HDR post chain failed, M1's tone curve instead: " + e);
			ShadeRobust.postFailed(); // M3.3: vanilla clouds then (M1's sky has no volumetric-cloud composite)
			e.printStackTrace();
			return false;
		}
	}

	/** Whether the HDR path is live (set up and not failed); shaded pipelines then must be the HDR variants. */
	public static boolean active() {
		return initialized && !failed;
	}

	/**
	 * LevelRenderer.render HEAD (after the frame's uniforms are packed): sizes the targets to the main render target and starts
	 * redirecting world passes. main: the game's main render target (MetalFX's smaller world target when that is on).
	 */
	static void beginWorld(Object metalEncoder, long nativeEnc, RenderTarget main) {
		if (!init()) return;
		encoder = metalEncoder;
		enc = nativeEnc;
		releaseRetired();
		GpuTexture color = main.getColorTexture();
		if (color == null) return;
		int w = color.getWidth(0), h = color.getHeight(0);
		boolean resized = w != width || h != height || hdr[0] == 0;
		if (resized) resize(w, h);
		frame++;
		mainColor = color;
		worldDepth = main.getDepthTexture();
		world = true;
		bridgeOpen = false;
		bridgeUsed = false;
		mcopt.metal.shade.dims.DimsDebug.beginFrame(); // M3.3 dev: mcopt.shade.passLog (off unless set)
		vlLight = vlDist = 0;
		liveWidth = w;
		liveHeight = h;
		long prevScene = hdr[(frame + 1) & 1];
		// last frame's HDR target holds a finished frame unless both were just (re)allocated
		boolean prevValid = !resized && prevWritten;
		mcopt.metal.shade.taa.ShadeTaa taa = taa();
		if (taa != null) {
			// TAAU: the world draws into the live sub-rect; last frame's finished image is the TAA history (output size, whole
			// texture = the whole view, pre-exposed with last frame's exposure like the HDR target it replaces): SSR's colour
			// source then never samples a stale border of a larger sub-rect
			liveWidth = taa.width(w);
			liveHeight = taa.height(h);
			long history = taa.history();
			if (history != 0) prevScene = history;
			prevValid = history != 0 && taa.historyValid();
		} else if (hdr[0] == hdr[1]) {
			// one HDR target (TAA on) but no TAA this frame: there is no last frame's image (never this frame's own target)
			prevScene = 0;
			prevValid = false;
		}
		ShadeBindings.setPrevSceneValid(prevValid);
		ShadeRender.resource(1, prevScene);
		ShadeRender.resource(2, hdr[frame & 1]);
		// ShadeResources.prevDepth (5): the TAA history's linear view depth, for passes that march last frame's image
		long prevDepth = taa != null && prevValid ? taa.historyDepth() : 0;
		ShadeRender.resource(5, prevDepth);
		ShadeBindings.setPrevDepthValid(prevDepth != 0);
	}

	private static void resize(int w, int h) {
		retire(hdr[0]);
		if (hdr[1] != hdr[0]) retire(hdr[1]);
		prevWritten = false;
		width = w;
		height = h;
		hdr[0] = ShadeRender.texture(ShadeConfig.HDR_FORMAT, w, h, false, "mcopt shade: HDR world A");
		// under TAAU last frame's image is the TAA history (prevScene), so one HDR world target does (19-47 MB less)
		hdr[1] = mcopt.metal.shade.taa.ShadeTaa.ON ? hdr[0] : ShadeRender.texture(ShadeConfig.HDR_FORMAT, w, h, false, "mcopt shade: HDR world B");
		sizeBloom(w, h);
		ShadeFrameUpdater.LOOK.snapExposure();
		System.out.println("[mcopt] shade: HDR targets " + w + "x" + h + ", bloom " + bloomLevels.length + " levels");
	}

	/** The bloom pyramid for a w x h source (the HDR world, or the resolver's image); kept while the size stays. */
	private static void sizeBloom(int w, int h) {
		if (w == bloomWidth && h == bloomHeight) return;
		for (long t : bloomLevels) retire(t);
		for (long t : bloomAccum) retire(t);
		bloomWidth = w;
		bloomHeight = h;
		int n = ShadeConfig.BLOOM ? ShadeConfig.BLOOM_LEVELS : 0;
		bloomLevels = new long[n];
		bloomAccum = new long[n];
		int lw = w, lh = h;
		for (int i = 0; i < n; i++) {
			lw = Math.max(1, (lw + 1) / 2);
			lh = Math.max(1, (lh + 1) / 2);
			bloomLevels[i] = ShadeRender.texture(ShadeRender.RGBA16F, lw, lh, true, "mcopt shade: bloom L" + i);
			bloomAccum[i] = i == 0 ? 0 : ShadeRender.texture(ShadeRender.RGBA16F, lw, lh, true, "mcopt shade: bloom U" + i);
		}
		ShadeRender.resource(3, n > 1 ? bloomAccum[1] : 0);
	}

	private static void retire(long t) {
		if (t != 0) retired.add(new long[] {t, frame + 4});
	}

	private static void releaseRetired() {
		retired.removeIf(r -> {
			if (r[1] > frame) return false;
			MetalBridge.release(r[0]);
			return true;
		});
	}

	// ---- the redirect ------------------------------------------------------------------------------------------------------
	private static MetalHooks.@Nullable Redirect redirect(RenderPassDescriptor d) {
		if (!world && ShadeEntity.HAND) return handRedirect(d);
		if (!world || mainColor == null) return null;
		if (mcopt.metal.shade.dims.DimsDebug.logging()) mcopt.metal.shade.dims.DimsDebug.pass(d, mainColor); // M3.3 dev
		// Distant Horizons: every one of its passes (also those drawing into its own targets: its far fade samples the main
		// colour) sees the display-referred image in main and composites there, as without shading
		String label = d.label().get();
		var colors = d.colorAttachments();
		boolean dhComposite = false;
		if (label != null && label.startsWith("distantHorizons:")) {
			// FT2 (ShadeDh.direct): DH's own passes draw into its own targets as they are; only its last copy into main (its
			// composite) is redirected into the HDR target like a world pass (the format adapter turns its display-referred
			// colours into radiance), so no bridge encodes the HDR image into main before and decodes it after
			boolean intoMain = colors.size() == 1 && colors.get(0) != null && colors.get(0).textureView().texture() == mainColor;
			boolean direct = mcopt.metal.shade.dh.ShadeDh.directFrame();
			// (the frame's pending clear of main, when no world pass took it before DH's first pass: the HDR target gets it, as
			// openBridge does; the backend would otherwise apply it to main itself at this pass, leaving last frame's image in the
			// HDR target where nothing else draws: the End's void showed the island of a scene before, ft2 shotsdh)
			if (direct && !bridgeOpen) applyPendingClear();
			if (!(intoMain && direct && !bridgeOpen)) {
				if (ShadeConfig.DH_BRIDGE && !bridgeOpen && !direct && !mcopt.metal.shade.dims.DimsDebug.noBridge()) openBridge();
				// (FT2.8, audit idx 112) DH's far fade and its copy into its own target draw one full-screen triangle that writes
				// every pixel (no blend; dh_far_fade.fs / dh_copy.fs without MCOPT_HDR): their colour isn't loaded first
				if (direct && DH_NO_LOAD && !intoMain && colors.size() == 1 && colors.get(0) != null && colors.get(0).clearValue().isEmpty()
					&& colors.get(0).textureView().baseMipLevel() == 0
					&& ("distantHorizons:DhFarFadeRenderer".equals(label) || "distantHorizons:CopyRenderer".equals(label))) {
					var t = colors.get(0).textureView().texture();
					// (a pending clear of it is moot too; left pending, the backend would flush it as a pass of its own)
					MetalBridge.takePendingColorClear(encoder, t);
					return new MetalHooks.Redirect(new long[] {MetalBridge.textureHandle(t)}, new float[][] {MetalBridge.DONT_CARE}, t.getWidth(0),
						t.getHeight(0), 0, MetalHooks.Redirect.NO_CLEAR, null, null);
				}
				return null;
			}
			bridgeUsed = true; // (the final pass's "DH drew this frame" bit)
			if (!loggedDh) {
				loggedDh = true;
				System.out.println("[mcopt] shade: Distant Horizons passes seen: its composite goes straight into the HDR frame (FT2; mcopt.shade.dh.direct=false: through the bridge)");
			}
			mcopt.metal.shade.dims.DimsDebug.note("DH composite straight into the HDR target");
			dhComposite = true;
		}
		if (colors.size() != 1 || colors.get(0) == null) return null;
		var attachment = colors.get(0);
		if (attachment.textureView().texture() != mainColor || attachment.textureView().baseMipLevel() != 0) return null;
		if (bridgeOpen) closeBridge();
		float[] clear = null;
		Optional<Vector4fc> explicit = attachment.clearValue();
		if (explicit.isPresent()) {
			Vector4fc c = explicit.get();
			clear = new float[] {c.x(), c.y(), c.z(), c.w()};
			MetalBridge.takePendingColorClear(encoder, mainColor);
		} else {
			clear = MetalBridge.takePendingColorClear(encoder, mainColor);
		}
		float[][] clears = null;
		if (clear != null) {
			float[] h = ShadeFrameUpdater.LOOK.ldrToHdr(clear[0], clear[1], clear[2]);
			clears = new float[][] {{h[0], h[1], h[2], clear[3]}};
		}
		// M3.1: this frame's lean tag (ShadeLean) selects the Sodium terrain's variant without the module code it can't use
		int[] formats = {ShadeConfig.HDR_FORMAT | ShadeLean.tag() << ShadeMsl.LEAN_SHIFT};
		// (FT2.8, audit idx 110) DH's composite (no depth test, no depth write: its own depth is a dummy) on the world's depth,
		// loaded: the game's 'Main' pass right after it then continues the same encoder instead of storing the HDR target and
		// loading it again (and the dummy depth's load + store). mcopt.shade.dh.mergeMain=false: on its own depth, as FT2.7
		if (dhComposite && worldDepth != null && DH_MERGE_MAIN)
			return new MetalHooks.Redirect(new long[] {hdr[frame & 1]}, clears, width, height, MetalBridge.textureHandle(worldDepth),
				MetalHooks.Redirect.NO_CLEAR, null, formats);
		return MetalHooks.Redirect.formats(new long[] {hdr[frame & 1]}, clears, width, height, formats);
	}

	/**
	 * M3: the first-person hand ("Item in hand", after the final pass, into the display-referred RGBA8 main target) draws
	 * through tagged variants of its pipelines (ShadeEntity.HAND_FORMAT): lit by the shade model and tone-mapped like the
	 * world, instead of vanilla's two cardinal lights.
	 */
	private static MetalHooks.@Nullable Redirect handRedirect(RenderPassDescriptor d) {
		String label = d.label().get();
		if (!"Item in hand".equals(label)) return null;
		var colors = d.colorAttachments();
		if (colors.size() != 1 || colors.get(0) == null || colors.get(0).clearValue().isPresent()) return null;
		var texture = colors.get(0).textureView().texture();
		if (colors.get(0).textureView().baseMipLevel() != 0 || MetalBridge.textureFormat(texture) != ShadeRender.RGBA8) return null;
		float[] clear = MetalBridge.takePendingColorClear(encoder, texture);
		return MetalHooks.Redirect.formats(new long[] {MetalBridge.textureHandle(texture)}, clear == null ? null : new float[][] {clear}, texture.getWidth(0),
			texture.getHeight(0), new int[] {ShadeEntity.HAND_FORMAT});
	}

	private static void openBridge() {
		bridgeOpen = true;
		bridgeUsed = true;
		if (!loggedDh) {
			loggedDh = true;
			System.out.println("[mcopt] shade: Distant Horizons passes seen: bridging them through the HDR frame");
		}
		long main = MetalBridge.textureHandle(mainColor);
		mcopt.metal.shade.dims.DimsDebug.note("bridge encode (HDR -> main)");
		applyPendingClear();
		pass(psoEncode, main, ShadeRender.DONT_CARE, new long[] {hdr[frame & 1]}, null, "mcopt shade: DH bridge encode");
	}

	/**
	 * Main's pending clear, if no world pass took it yet this frame, applied to the HDR target instead (Distant Horizons' first
	 * pass, bridge or FT2's direct composite).
	 */
	private static void applyPendingClear() {
		float[] clear = MetalBridge.takePendingColorClear(encoder, mainColor);
		// M3.3 (mcopt.shade.dhClear, live, default true; false = M3.2): when no world pass drew into main before Distant
		// Horizons' first one (no sky pass: the Nether, the End's dragon fight, under water / lava / powder snow, blindness),
		// the frame's clear of main is still pending and the HDR target still holds the last frame: apply the clear there
		// first, as the redirect does for the first world pass. Without it DH's TAA + sharpen re-processed last frame's image
		// every frame where nothing else draws (the End + DH grey checkerboard / coloured noise, SKYDIMS.md 6.6 and M3.3).
		if (clear != null && mcopt.metal.shade.dims.DimsDebug.dhClear()) {
			float[] h = ShadeFrameUpdater.LOOK.ldrToHdr(clear[0], clear[1], clear[2]);
			MetalBridge.renderBegin(enc, new long[] {hdr[frame & 1]}, new float[][] {{h[0], h[1], h[2], clear[3]}}, 0, false, 0f, width, height);
			mcopt.metal.shade.dims.DimsDebug.note("main's pending clear applied to the HDR target");
		}
	}

	private static void closeBridge() {
		bridgeOpen = false;
		long main = MetalBridge.textureHandle(mainColor);
		mcopt.metal.shade.dims.DimsDebug.note("bridge decode (main -> HDR)");
		pass(psoDecode, hdr[frame & 1], ShadeRender.LOAD, new long[] {main}, null, "mcopt shade: DH bridge decode");
	}

	// ---- before the hand: hooks, bloom, exposure, tone map ---------------------------------------------------------------
	/** GameRenderer.render3dHud HEAD (and FogRenderer.endFrame as a fallback): ends the world phase and tone-maps into main. */
	static void beforeHand(RenderTarget main) {
		if (!world) return;
		world = false;
		if (bridgeOpen) closeBridge();
		mcopt.metal.shade.dims.DimsDebug.endFrame(); // M3.3 dev
		// M3: this frame's entity draws -> the next frame's near shadow cascade
		if (mcopt.metal.shade.shadow.EntityCasters.ON) mcopt.metal.shade.shadow.EntityCasters.commit(enc);
		if (mainColor == null) return;
		prevWritten = true;
		long scene = hdr[frame & 1], prev = hdr[0] != hdr[1] ? hdr[(frame + 1) & 1] : 0;
		GpuTexture depthTexture = worldDepth != null ? worldDepth : main.getDepthTexture();
		long depth = 0;
		if (depthTexture != null) {
			MetalBridge.flushClear(encoder, depthTexture);
			depth = MetalBridge.textureHandle(depthTexture);
		}
		ShadeFrame f = ShadeFrameUpdater.FRAME;
		ShadeLook look = ShadeFrameUpdater.LOOK;
		if (!BEFORE_TONEMAP.isEmpty()) {
			Context c = new Context(enc, encoder, scene, prev, depth, liveWidth, liveHeight, ShadeConfig.HDR_FORMAT, f, look, width, height);
			for (Ordered o : List.copyOf(BEFORE_TONEMAP)) {
				try {
					o.hook.run(c);
				} catch (RuntimeException e) {
					System.out.println("[mcopt] shade: post hook failed: " + e);
				}
			}
		}
		// the image bloom starts from: this frame's internal-resolution HDR world (its live sub-rect), also under TAAU
		// (bible E19: bloom L0 before the upscale, a 0.45x read instead of the output-size history)
		long bloomSource = scene;
		float srcU = (float) liveWidth / width, srcV = (float) liveHeight / height;
		GpuTexture out = mainColor;
		mcopt.metal.shade.taa.ShadeTaa taa = taa();
		float sharpen = 0f;
		if (taa != null && depth != 0) {
			// TAAU (E18): the jittered internal-resolution world + last frame's history -> this frame's output-size history,
			// which the final pass tone-maps (sharpened) into the game's real main target, before the hand
			scene = taa.resolveHdr(scene, depth);
			out = taa.outputTarget().getColorTexture();
			sharpen = mcopt.metal.shade.taa.TaaConfig.sharpen(taa.scale());
		} else {
			Resolver r = resolver;
			if (r != null) {
				try {
					long resolved = r.resolve(new Context(enc, encoder, scene, prev, depth, liveWidth, liveHeight, ShadeConfig.HDR_FORMAT, f, look, width, height));
					if (resolved != 0) {
						scene = resolved;
						bloomSource = resolved;
						srcU = srcV = 1f;
					}
				} catch (RuntimeException e) {
					System.out.println("[mcopt] shade: resolver failed: " + e);
				}
			}
		}
		if (out == null) return;
		// the bloom pyramid follows the output image (constant under dynamic resolution)
		if (scene != hdr[frame & 1]) sizeBloom(ShadeRender.width(scene), ShadeRender.height(scene));
		else sizeBloom(width, height);
		float bloomNorm = 0f, w0 = 0f;
		int n = bloomLevels.length;
		// (FT2.7, audit idx 51) the glow as a share of the screen, not in pixels: the look was tuned at 1964 rows (Retina), and each
		// level's texel is 2^(i+1) output pixels, so at the 1080 output (Gael's monitor, "Salida") the glow was ~1.8x wider = more veil.
		// Below 1964 rows: the pyramid stops round(shift) levels sooner and the weights move up by the fractional shift (octaves);
		// at native the same image (mcopt.shade.bloomScale, live; 0 = the width in pixels, FT2.6)
		float bloomShift = n > 0 && mcopt.metal.shade.vl.VlConfig.live("mcopt.shade.bloomScale", 1f) > 0.5f
			? Math.max(0f, (float) (Math.log(1964.0 / Math.max(bloomHeight, 1)) / Math.log(2.0))) : 0f;
		if (n > 4) n = Math.clamp(n - Math.round(bloomShift), 4, n);
		if (n > 0) {
			downParams.clear();
			downParams.putFloat(srcU).putFloat(srcV).putFloat(mcopt.metal.shade.dims.ShadeXdr.hotThreshold()).putFloat(0f).flip(); // z: M3.3 XDR skip
			pass(psoDown0, bloomLevels[0], ShadeRender.DONT_CARE, new long[] {bloomSource}, downParams, "mcopt shade: bloom down 0");
			for (int i = 1; i < n; i++) {
				pass(psoDown, bloomLevels[i], ShadeRender.DONT_CARE, new long[] {bloomLevels[i - 1]}, null, "mcopt shade: bloom down");
			}
			// (FT2.8, audit idx 45) the exposure histogram of bloom level 2 is dispatched after the final pass, next to the exposure
			// kernel: here, mid-chain, its ShadeGpu writes made the bloom up passes and the final pass (which bind ShadeGpu) wait for it
			if (ShadeConfig.AUTO_EXPOSURE && n > 2) histogramSource = bloomLevels[2];
			float spectrum = ShadeSettings.look() == 1 ? 0.9f : ShadeSettings.look() == 2 ? 0.3f : 0.6f;
			float sum = 0f;
			// U_i = w_i L_i + tent(U_i+1) down to U_1; level 0 (half size) is added in the final pass (w0 L0 + bilinear U1):
			// one half-size pass less, the biggest one
			for (int i = n - 1; i >= 1; i--) {
				float w = (float) Math.pow(i + 1 + bloomShift, spectrum);
				sum += w;
				params.clear();
				params.putFloat(w).putFloat(i == n - 1 ? 0f : 1f).putFloat(0f).putFloat(0f).flip();
				long coarser = i == n - 1 ? bloomLevels[i] : bloomAccum[i + 1];
				pass(psoUp, bloomAccum[i], ShadeRender.DONT_CARE, new long[] {bloomLevels[i], coarser}, params, "mcopt shade: bloom up");
			}
			w0 = (float) Math.pow(1 + bloomShift, spectrum);
			sum += w0;
			bloomNorm = 1f / sum;
		}
		params.clear();
		boolean vl = vlLight != 0 && vlDist != 0;
		// q: x bloom level 0's weight, y the volumetric light's upsample mode, z its depth tolerance scale (2026-10-09, live:
		// mcopt.shade.vl.upMode / upTol, shade_post.metal shadeVlUpsample), w the knee of the light it adds (exposed luminance;
		// 0 = linear: mcopt.shade.vl.knee, live)
		float upMode = mcopt.metal.shade.vl.VlConfig.look("mcopt.shade.vl.upMode", 1f, 0f);
		params.putFloat(bloomNorm).putFloat(n > 1 ? 1f : 0f).putFloat(frame & 0xffff).putFloat(f.debug).putFloat(w0)
			// (2026-10-09 default: mode 1 with 1.6x the tolerance: no dots where the shafts cross leaves; FT2.1: 0, 1)
			.putFloat(upMode).putFloat(mcopt.metal.shade.vl.VlConfig.look("mcopt.shade.vl.upTol", 1.6f, 1f))
			// (knee 0.4: the brightest glow toward a low sun, the lit air in front of backlit leaves, no longer washes them out
			// to beige; the shafts stay below it: veil4 i4, notes/godrays-veil-2026-10-09)
			.putFloat(vl && vlAirFloor > 0f ? 0f : mcopt.metal.shade.vl.VlConfig.look("mcopt.shade.vl.knee", 0.4f, 0f));
		// (v.x 2, FT2.8 audit idx 2: the light is the VL history itself, a = its distance: the medium's transmittance is 1)
		params.putFloat(vl ? (vlLight == vlDist ? 2f : 1f) : 0f).putFloat(vlMaxDist).putFloat(vlScaleU).putFloat(vlScaleV);
		// r: xy the live render size of depth (the final pass maps its output uv into that sub-rect), z sharpen (TAAU)
		// w: a bit field (as an exact small float): 1 = Distant Horizons drew into this frame (its LODs are where the depth is
		// empty: the Nether's fog leaves them); 2 (TAAU) = depth and the volumetric light read at the jittered raster's
		// position of the pixel's scene point (M2.2, mcopt.shade.vl.unjitter)
		params.putFloat(liveWidth).putFloat(liveHeight).putFloat(sharpen)
			.putFloat((bridgeUsed ? 1f : 0f) + (taa != null && depth != 0 && VL_UNJITTER ? 2f : 0f));
		// x: highlights = (1, peak, knee, range); full scene = (2, peak, curve b, curve beta)
		boolean xdr = psoFinalXdr != 0 && mcopt.metal.shade.dims.ShadeXdr.highlights()
			&& (!mcopt.metal.shade.dims.ShadeXdr.fullScene() || f.debug == 0f);
		boolean fullHdr = xdr && mcopt.metal.shade.dims.ShadeXdr.fullSceneFrame();
		// M3: the dims variant in the Nether / End and with the camera in lava or powder snow (anywhere)
		boolean dimsPass = f.dimension != ShadeFrame.DIM_OVERWORLD || f.fogType == ShadeFrame.FOG_LAVA || f.fogType == ShadeFrame.FOG_POWDER_SNOW;
		if (xdr) mcopt.metal.shade.dims.ShadeXdr.params(params);
		else params.putFloat(0f).putFloat(1f).putFloat(1f).putFloat(1f);
		// a (godrays v3): x the VL air mode's floor (0 = off: the light added is negative only over the sky, floored at 0.55)
		// (a.y, FT2.7 audit idx 47: the air mode's VL read at the haze edge's own keys (1) and its fallbacks' shadowed part uncapped
		// (2); mcopt.shade.vl.edgeFix, live; 0 by default: in Gael's autumn forest at sunrise (ft28-rim) no rim showed to fix and the
		// edges moved both ways, a flicker risk in motion; kept for a pose where the rim shows)
		// (a.z, FT2.12: mcopt.shade.vl.airClamp, live, 1; 0 = FT2.11) on surfaces the shadows take out at most the sunlit haze glow the
		// final pass added to the pixel (all of it in full shadow) instead of at most 70 % of the pixel (airFloor): toward a sun behind
		// a mountain 30 % of that glow stayed, an orange halo through the mountain (Gael 2026-10-11)
		float edgeFix = vl && vlAirFloor > 0f ? mcopt.metal.shade.vl.VlConfig.live("mcopt.shade.vl.edgeFix", 0f) : 0f;
		params.putFloat(vl ? vlAirFloor : 0f).putFloat(edgeFix)
			.putFloat(vl && vlAirFloor > 0f && mcopt.metal.shade.vl.VlConfig.live("mcopt.shade.vl.airClamp", 1f) > 0f ? 1f : 0f)
			.putFloat(fullHdr ? mcopt.metal.shade.dims.ShadeXdr.sceneBrightness() : 0f);
		params.flip();
		// (v12-opt) the lean final pass while it computes the same: no debug view (p.w), the upsample's mode 1 (q.y) and no edge fix
		// (a.y, read as int(a.y) where a.x > 0): what shade_post.metal's LEAN variants hold constant
		boolean lean = !dimsPass && f.debug == 0f && upMode == 1f && (int) edgeFix == 0 && Live.b("mcopt.shade.finalLean", true);
		if (lean != loggedLean) {
			loggedLean = lean;
			System.out.println("[mcopt] shade: final pass " + (lean ? "lean (mcopt.shade.finalLean)" : "full"));
		}
		long mainHandle = MetalBridge.textureHandle(out);
		MetalBridge.takePendingColorClear(encoder, out);
		// (2026-10-09) the output resolution below the window's (ShadeOutput): the final pass writes an output-size image, the
		// upscale below fills the window's target from it
		boolean upscale = taa != null && depth != 0 && taa.outputScaled() && psoUpscale != 0;
		long finalTarget = mainHandle;
		int targetW = out.getWidth(0), targetH = out.getHeight(0);
		if (upscale) {
			targetW = taa.outWidth();
			targetH = taa.outHeight();
			if (outScaled == 0 || targetW != outScaledWidth || targetH != outScaledHeight) {
				retire(outScaled);
				outScaledWidth = targetW;
				outScaledHeight = targetH;
				outScaled = ShadeRender.texture(ShadeRender.RGBA8, targetW, targetH, false, "mcopt shade: output");
			}
			finalTarget = outScaled;
		}
		long[] finalInputs = {scene, n > 1 ? bloomAccum[1] : scene, depth, n > 1 ? bloomLevels[0] : scene, vl ? vlLight : scene, vl ? vlDist : scene};
		if (xdr) {
			int ow = targetW, oh = targetH;
			int format = fullHdr ? ShadeRender.RGBA16F : ShadeRender.RG11B10F;
			if (xdrExcess == 0 || ow != xdrWidth || oh != xdrHeight || format != xdrFormat) {
				retire(xdrExcess);
				xdrWidth = ow;
				xdrHeight = oh;
				xdrFormat = format;
				xdrExcess = ShadeRender.texture(format, ow, oh, false, fullHdr ? "mcopt shade: HDR world output" : "mcopt shade: XDR excess");
			}
			if (encoder != null && MetalBridge.tracing(encoder)) System.out.println("mcopt-metal trace: shade pass 'mcopt shade: final (XDR)'");
			long finalPso = fullHdr ? (dimsPass && psoFinalHdrDims != 0 ? psoFinalHdrDims : lean ? psoFinalHdrLean : psoFinalHdr)
				: (dimsPass && psoFinalXdrDims != 0 ? psoFinalXdrDims : lean ? psoFinalXdrLean : psoFinalXdr);
			mcopt.metal.shade.dims.ShadeXdr.finalPass(enc, finalPso, finalTarget, xdrExcess, finalInputs, params,
				fullHdr ? "mcopt shade: final (full HDR)" : "mcopt shade: final (XDR)");
		} else {
			pass(dimsPass && psoFinalDims != 0 ? psoFinalDims : lean && psoFinalLean != 0 ? psoFinalLean : psoFinal, finalTarget, ShadeRender.DONT_CARE, finalInputs,
				params, "mcopt shade: final");
		}
		if (upscale) {
			// (the XDR excess stays at the output size: the present's compose samples it by uv, mcxdr.m)
			UPSCALE_PARAMS.clear();
			UPSCALE_PARAMS.putFloat(Math.max(mcopt.metal.shade.vl.VlConfig.live("mcopt.shade.outputSharpen", 0.3f), 0f)).putFloat(0f).putFloat(0f).putFloat(0f).flip();
			pass(psoUpscale, mainHandle, ShadeRender.DONT_CARE, new long[] {outScaled}, UPSCALE_PARAMS, "mcopt shade: upscale");
		}
		if (fullHdr) mcopt.metal.shade.dims.ShadeXdr.fullFrame(enc, xdrExcess, mainHandle);
		// after the final pass: the kernel advances ShadeGpu.exposure.x to next frame's value, and everything this frame
		// (world, TAA history, haze and VL in the final pass, Purkinje) must use this frame's
		if (histogramSource != 0) {
			long l2 = histogramSource;
			histogramSource = 0;
			ShadeRender.dispatch(enc, psoHistogram, ShadeRender.width(l2), ShadeRender.height(l2), 16, 16, new long[] {l2}, null, "mcopt shade: histogram");
		}
		ShadeRender.dispatch(enc, psoExposure, 1, 1, 1, 1, null, null, "mcopt shade: exposure");
		vlLight = vlDist = 0;
	}

	/** ShadeRender.pass on this frame's encoder, named in the -Dmcopt.metal.trace output (its GPU time is the next encoder #). */
	private static void pass(long pso, long target, int load, long @Nullable [] textures, @Nullable ByteBuffer p, String label) {
		if (encoder != null && MetalBridge.tracing(encoder)) System.out.println("mcopt-metal trace: shade pass '" + label + "'");
		ShadeRender.pass(enc, pso, target, load, textures, p, label);
	}

	/** Whether Distant Horizons' passes went through the bridge this frame. */
	public static boolean bridgedThisFrame() {
		return bridgeUsed;
	}
}
