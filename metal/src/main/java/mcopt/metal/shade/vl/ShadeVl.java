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
package mcopt.metal.shade.vl;

import com.mojang.blaze3d.pipeline.RenderTarget;
import com.mojang.blaze3d.systems.RenderSystem;
import com.mojang.renderpearl.frontend.FrontendCommandEncoder;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import mcopt.metal.MetalBridge;
import mcopt.metal.shade.Shade;
import mcopt.metal.shade.ShadeFrame;
import mcopt.metal.shade.ShadeLook;
import mcopt.metal.shade.ShadePost;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.biome.Biome;
import net.minecraft.world.level.material.FluidState;
import net.minecraft.world.level.material.Fluids;
import org.joml.Vector4f;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.system.MemoryUtil;

/**
 * Volumetric light (shader bible E07): god rays through the sun's shadow map, crepuscular streaks toward the sun, caustic
 * shafts under water, subtle moon shafts. Runs once per frame right before the hand pass (GameRenderer.render3dHud, hook
 * H7: the main depth still holds the level), on the game's main target: march at {@link VlConfig#SCALE} of it, temporal
 * accumulation, depth-aware upsample and a composite that adds the light before M1's output curve. The CPU side here
 * picks the medium (haze + ground mist by time of day, rain and biome humidity), the light colour (saturated at sunset),
 * the strength, the water surface above the camera, and packs VlParams (vl.metal). Render thread only.
 *
 * <p>On the HDR pipeline (M2, {@link ShadePost#active()}) the same passes run as a before-tonemap hook of the post chain
 * (order {@value #HOOK_ORDER}): the composite (vl_composite_hdr, flag 4 of mc_vl_render) blends scene x T + light (One,
 * SourceAlpha) into the pre-exposed HDR world target, so bloom, auto-exposure and the tone map see the shafts; the open-air
 * medium follows the base's E06 haze and mist (ShadeLook), the strength its time-of-day keyframes and look preset. The
 * render3dHud mixin path (M1 LDR composite) remains for mcopt.shade.hdr=false. See VL.md and M2_INTEGRATION.md.
 */
public final class ShadeVl {
	private static final int PARAM_BYTES = 496; // VlParams (vl.metal), 31 x float4 since FT2.7
	private static final int ERR = 2048;
	private static final float SEA = 63f;
	/** M2: the open-air medium = the base's haze / mist sigma x these (see pack). */
	private static final float HDR_HAZE = 4.6f, HDR_MIST = 4.2f;
	/**
	 * M2 look (tuned in game against VL off and Complementary, bench vi*): HDR shows the in-scattering without M1's curve
	 * compressing it, so the shafts are scaled down (air, under water), the canopy mist's grey veil and its extinction are
	 * lighter, and more of the open air's unshadowed glow is left to the base haze (shafts = structure, not a milky veil).
	 */
	private static final float HDR_AIR = 0.6f, HDR_WATER = VlConfig.WATER_M3 ? 0.6f : 0.45f, HDR_VEIL = 0.1f, HDR_EXT = 0.35f, HDR_OPEN_CUT = 0.7f, HDR_CARVE = 0.6f,
		HDR_CARVE_WATER = VlConfig.WATER_M3 ? 0.62f : 0.55f; // M3 under water (mcopt.shade.vl.waterM3; false = M2.1: 0.45, 0.55)

	private static long state;
	private static boolean failed, logged;
	private static final ByteBuffer PARAMS = MemoryUtil.memAlloc(PARAM_BYTES).order(ByteOrder.nativeOrder());
	private static final long CANOPY_OUT = MemoryUtil.nmemCalloc(2, 4);
	private static final long TIMES_OUT = MemoryUtil.nmemCalloc(4, 4);
	/** Measurement only: run the passes but don't fold them into the final pass (prices the final pass's share). */
	private static final boolean FOLD_SKIP = Boolean.getBoolean("mcopt.shade.vl.foldSkip");
	private static final long OUTPUTS_OUT = MemoryUtil.nmemCalloc(2, 8);
	private static double prevX, prevY, prevZ;
	private static boolean hasPrevious;
	private static long lastNanos, lastLog;
	private static int frame;
	private static boolean lastUnderwater;
	/** The VL targets' size, and the live part of them last frame covered (where the history holds light). */
	private static int allocW, allocH, prevLiveW, prevLiveH;
	private static Object lastLevel;
	private static float humidity = -1f;
	private static boolean resetCanopy = true;
	/** ShadePost before-tonemap order (AO 50, clouds 80, VL 100). */
	public static final int HOOK_ORDER = 100;
	private static boolean hooked, stateHdr;
	/** This frame's VlParams.air.x (godrays v3: the final pass then lets the light it adds be negative on surfaces too). */
	private static boolean airActive;
	/** Its march's end (blocks), for the final pass's upsample (the air ratio of texels at another depth). */
	private static float airEndUsed;
	/** The shade grid's cell size last frame (a change refreshes all of it). */
	private static float lastCell = -1f;

	private ShadeVl() {
	}

	/**
	 * Before GameRenderer.render3dHud (VlGameRendererMixin): the level is drawn, the hand isn't. With M2's HDR post chain
	 * live this only registers the before-tonemap hook (which then does the work inside ShadePost.beforeHand); otherwise
	 * the M1 path: composite onto the game's RGBA8 main target.
	 */
	public static void beforeHand() {
		if (!VlConfig.ENABLED || failed) return;
		if (ShadePost.active()) {
			if (!hooked) {
				hooked = true;
				ShadePost.addBeforeTonemap(HOOK_ORDER, ShadeVl::beforeTonemap);
			}
			return;
		}
		try {
			Minecraft mc = Minecraft.getInstance();
			Object encoder = MetalBridge.encoder(((FrontendCommandEncoder) RenderSystem.getDevice().createCommandEncoder()).backend());
			if (encoder == null || MetalBridge.inRenderPass(encoder)) return;
			RenderTarget main = mc.gameRenderer.mainRenderTarget();
			var color = main.getColorTexture();
			var depth = main.getDepthTexture();
			if (color == null || depth == null || !ready(encoder, false)) return;
			MetalBridge.flushClear(encoder, color);
			MetalBridge.flushClear(encoder, depth);
			// under TAAU (before its resolve) main is the world target, allocated at the preset's maximum scale: the world drew
			// only into its live sub-rect
			int liveW = main.width, liveH = main.height;
			mcopt.metal.shade.taa.ShadeTaa taa = mcopt.metal.shade.taa.ShadeTaa.ON ? mcopt.metal.shade.taa.ShadeTaa.get() : null;
			if (taa != null && taa.swapped()) {
				liveW = Math.min(taa.width(main.width), main.width);
				liveH = Math.min(taa.height(main.height), main.height);
			}
			render(encoder, MetalBridge.enc(encoder), MetalBridge.textureHandle(color), MetalBridge.textureHandle(depth), liveW, liveH, main.width, main.height, null);
		} catch (Throwable t) {
			fail(t);
		}
	}

	/** M2: ShadePost's before-tonemap hook (world drawn into the HDR target, main depth intact, before bloom and exposure). */
	private static void beforeTonemap(ShadePost.Context c) {
		if (failed || c.depth() == 0 || c.scene() == 0) return;
		try {
			if (!ready(c.encoder(), true)) return;
			render(c.encoder(), c.enc(), c.scene(), c.depth(), c.width(), c.height(), c.texWidth(), c.texHeight(), c.look());
		} catch (Throwable t) {
			fail(t);
		}
	}

	private static void fail(Throwable t) {
		failed = true;
		System.out.println("[mcopt] shade: volumetric light failed, off from now on: " + t);
		t.printStackTrace();
	}

	/** The native state, made on first use for the HDR or the LDR composite (the pipeline doesn't switch mid-session). */
	private static boolean ready(Object encoder, boolean hdr) {
		if (state != 0) return stateHdr == hdr;
		stateHdr = hdr;
		return init(MetalBridge.ctx(encoder), hdr);
	}

	/**
	 * One frame of VL onto color (the main RGBA8 target, or M2's HDR world target when look != null) with depth (the main
	 * depth), both texWidth x texHeight with the live render in their sub-rect (0, 0, width, height) (TAAU dynamic resolution;
	 * equal sizes otherwise), on the frame's command buffer of enc. The VL targets follow the texture size (they never
	 * reallocate when the render scale moves) and cover the live sub-rect: VlParams.size.zw is the live size.
	 */
	private static void render(Object encoder, long enc, long color, long depth, int width, int height, int texWidth, int texHeight, ShadeLook look) {
		ShadeFrame f = Shade.frame();
		Minecraft mc = Minecraft.getInstance();
		ClientLevel level = mc.level;
		if (level == null || f.dimension != ShadeFrame.DIM_OVERWORLD) {
			hasPrevious = false;
			return;
		}
		// the game's fog wins (lava, powder snow, blindness, darkness): nothing to light
		// (FT2.8, audit idx 18: skipped frames drop the history, so the next frame resets instead of reprojecting an old one)
		// (1.1: mcopt.shade.vl.underwater live)
		if (f.fogColor[3] > 0.5f && !f.underwater || f.underwater && !VlConfig.underwater()) {
			hasPrevious = false;
			return;
		}

		long now = System.nanoTime();
		float dt = lastNanos == 0 ? 0f : Math.min((now - lastNanos) / 1e9f, 1f);
		lastNanos = now;
		// (and when the camera enters or leaves water: the two histories hold different light)
		boolean reset = !hasPrevious || lastLevel != level || !VlConfig.TEMPORAL || f.underwater != lastUnderwater;
		lastUnderwater = f.underwater;
		double dx = f.cameraX - prevX, dy = f.cameraY - prevY, dz = f.cameraZ - prevZ;
		if (Math.abs(dx) + Math.abs(dy) + Math.abs(dz) > 8) reset = true;
		if (reset) {
			dx = dy = dz = 0;
		}
		prevX = f.cameraX;
		prevY = f.cameraY;
		prevZ = f.cameraZ;
		hasPrevious = true;
		if (lastLevel != level) resetCanopy = true;
		lastLevel = level;

		// targets sized from the allocation (they never reallocate when the render scale moves); the march and temporal passes
		// cover only the live part, VlConfig.SCALE of the live render (so VL gets cheaper with the dynamic resolution)
		// (2026-10-09 look development: mcopt.shade.vl.scaleLive overrides the preset's scale every frame; the native side
		// reallocates its targets when the size changes)
		// (FT2.3: at least ~540 VL rows at a small window, up to half the resolution: on Gael's 1080p monitor a third of the render
		// made each VL texel ~3 screen pixels and the shafts looked pixelated; at Retina the preset's own scale still decides. From
		// the allocated height, so the dynamic resolution never reallocates the VL targets)
		float vlScale = VlConfig.scaleLive(VlConfig.ft21() ? VlConfig.SCALE
			: Math.max(VlConfig.SCALE, Math.min(0.5f, 540f / Math.max(texHeight, 1))));
		int vw = Math.max(1, Math.round(texWidth * vlScale)), vh = Math.max(1, Math.round(texHeight * vlScale));
		int lw = Math.clamp(Math.round(width * vlScale), 1, vw), lh = Math.clamp(Math.round(height * vlScale), 1, vh);
		if (vw != allocW || vh != allocH) {
			allocW = vw;
			allocH = vh;
			prevLiveW = lw;
			prevLiveH = lh;
		}
		if (reset) {
			prevLiveW = lw;
			prevLiveH = lh;
		}
		if (!pack(f, look, level, width, height, lw, lh, (float) prevLiveW / vw, (float) prevLiveH / vh, dx, dy, dz, dt, reset)) {
			hasPrevious = false; // nothing to draw (deep in a cave, no light): no passes at all
			return;
		}

		boolean fold = look != null && VlConfig.FOLD;
		int flags = (VlConfig.CANOPY < 0 ? 1 : 0) | (reset ? 2 : 0) | (look != null ? 4 : 0) | (VlConfig.GPU_TIMER ? 8 : 0) | (fold ? 16 : 0);
		if (MetalBridge.tracing(encoder)) System.out.println("mcopt-metal trace: shade pass 'VL canopy/march/temporal/composite' (" + vw + "x" + vh + ")");
		try (MemoryStack stack = MemoryStack.stackPush()) {
			long err = stack.ncalloc(1, ERR, 1);
			int r = VlNative.render(enc, state, color, depth, MemoryUtil.memAddress0(PARAMS), PARAM_BYTES, vw, vh, lw, lh, flags, err, ERR);
			if (r != 0) throw new IllegalStateException("volumetric light: " + MemoryUtil.memUTF8(err));
		}
		if (fold && !FOLD_SKIP) {
			VlNative.outputs(state, OUTPUTS_OUT);
			// (air mode: the floor of what the shadows may take out of a surface's light, share of it: mcopt.shade.vl.airFloor, live)
			// (1.1: the march's end this frame, the air mode's or mcopt.shade.vl.dist, live: pack's airEnd either way)
			ShadePost.setVolumetric(MemoryUtil.memGetAddress(OUTPUTS_OUT), MemoryUtil.memGetAddress(OUTPUTS_OUT + 8), airEndUsed, (float) lw / vw,
				(float) lh / vh, airActive ? Math.max(VlConfig.live("mcopt.shade.vl.airFloor", 0.3f), 1e-3f) : 0f);
		}
		prevLiveW = lw;
		prevLiveH = lh;
		resetCanopy = false;
		frame++;
		if (!logged) {
			logged = true;
			System.out.println("[mcopt] shade: volumetric light " + lw + "x" + lh + " of " + vw + "x" + vh + " (" + VlConfig.describe() + (look != null ? ", HDR" : ", LDR") + ")");
		}
		if (VlConfig.LOG && now - lastLog > 2_000_000_000L) {
			lastLog = now;
			VlNative.canopy(state, CANOPY_OUT);
			System.out.println(String.format(java.util.Locale.ROOT, "[mcopt] shade: vl canopy %.2f (shadowed %.2f) haze %.5f mist %.5f canopy mist %.5f strength %.2f g %.2f humidity %.2f underwater %b sunY %.3f",
				MemoryUtil.memGetFloat(CANOPY_OUT), MemoryUtil.memGetFloat(CANOPY_OUT + 4), PARAMS.getFloat(32), PARAMS.getFloat(36), PARAMS.getFloat(76),
				PARAMS.getFloat(16), PARAMS.getFloat(28), humidity, f.underwater, f.sunDir.y));
			if (VlConfig.GPU_TIMER) {
				VlNative.times(state, TIMES_OUT);
				float m = MemoryUtil.memGetFloat(TIMES_OUT), t = MemoryUtil.memGetFloat(TIMES_OUT + 4), c = MemoryUtil.memGetFloat(TIMES_OUT + 8);
				System.out.println(String.format(java.util.Locale.ROOT, "[mcopt] shade: vl gpu march %.3f temporal %.3f composite %.3f = %.3f ms (%dx%d of %dx%d, %.0f frames)",
					m, t, c, m + t + c, lw, lh, width, height, MemoryUtil.memGetFloat(TIMES_OUT + 12)));
			}
		}
	}

	private static boolean init(long ctx, boolean hdr) {
		try (MemoryStack stack = MemoryStack.stackPush()) {
			ByteBuffer source = MemoryUtil.memUTF8(VlConfig.source());
			try {
				long err = stack.ncalloc(1, ERR, 1);
				mcopt.metal.shade.ShadeRobust.maybeFail("vl"); // M3.3: dev-only injected failure; inert unset
				long t0 = mcopt.metal.shade.ShadeCompile.now();
				long s = VlNative.create(ctx, MemoryUtil.memAddress(source), (VlConfig.LOSSY ? 1 : 0) | (hdr ? 2 : 0), err, ERR);
				mcopt.metal.shade.ShadeCompile.setup("volumetric light", t0);
				if (s == 0) throw new IllegalStateException("volumetric light setup: " + MemoryUtil.memUTF8(err));
				state = s;
				return true;
			} finally {
				MemoryUtil.memFree(source);
			}
		} catch (Throwable t) {
			failed = true;
			System.out.println("[mcopt] shade: volumetric light off: " + t);
			return false;
		}
	}

	// ---- parameters ----------------------------------------------------------------------------------------------------

	private static float smoothstep(float a, float b, float x) {
		float t = Math.max(0f, Math.min(1f, (x - a) / (b - a)));
		return t * t * (3f - 2f * t);
	}

	private static float mix(float a, float b, float t) {
		return a + (b - a) * t;
	}

	/** 0 (arid) .. 1 (jungle, swamp) at the camera, smoothed over a few seconds (biome borders don't pop). */
	private static float humidity(ClientLevel level, BlockPos pos, float dt) {
		Biome b = level.getBiome(pos).value();
		float t = b.getBaseTemperature();
		float target = !b.hasPrecipitation() ? 0.1f : t >= 0.9f ? 0.95f : t >= 0.75f ? 0.75f : t < 0.2f ? 0.45f : 0.6f;
		humidity = humidity < 0f ? target : mix(humidity, target, 1f - (float) Math.exp(-dt / 6f));
		return humidity;
	}

	/** The water surface above the camera (absolute y), scanning up through water blocks; NaN if none within 32 blocks. */
	private static float waterSurface(ClientLevel level, ShadeFrame f) {
		BlockPos.MutableBlockPos p = new BlockPos.MutableBlockPos(Math.floor(f.cameraX), Math.floor(f.cameraY), Math.floor(f.cameraZ));
		for (int i = 0; i < 32; i++) {
			FluidState fs = level.getFluidState(p);
			boolean water = fs.getType() == Fluids.WATER || fs.getType() == Fluids.FLOWING_WATER;
			if (!water) return i == 0 ? Float.NaN : p.getY();
			FluidState above = level.getFluidState(p.above());
			boolean waterAbove = above.getType() == Fluids.WATER || above.getType() == Fluids.FLOWING_WATER;
			if (!waterAbove) return p.getY() + fs.getHeight(level, p);
			p.move(0, 1, 0);
		}
		return Float.NaN;
	}

	/** Packs VlParams; false when the frame would add nothing (no light and no canopy mist): then no pass runs. */
	private static boolean pack(ShadeFrame f, ShadeLook look, ClientLevel level, int width, int height, int vw, int vh, float histU, float histV, double dx,
		double dy, double dz, float dt, boolean reset) {
		ByteBuffer b = PARAMS;
		float sunY = f.sunDir.y;
		boolean sunLight = f.sky.sunLight;
		boolean morning = f.dayTime > 0.5f; // dayTime: 0 noon, 0.25 sunset, 0.5 midnight, 0.75 sunrise
		float rain = f.rain;
		float hum = humidity(level, BlockPos.containing(f.cameraX, f.cameraY, f.cameraZ), dt);
		// golden hour: the sun below ~30 degrees (sunY 0.5), full below ~6 (with the default 30-degree sun path tilt the sun
		// never climbs above sunY 0.87)
		float golden = sunLight ? 1f - smoothstep(0.05f, 0.55f, sunY) : 0f;
		float day = smoothstep(-0.05f, 0.25f, sunY);

		// medium (1/block): a thin haze everywhere plus ground mist, thick at dawn, lighter at dusk, faint at noon
		float mistLow = morning ? 0.0105f : 0.0065f;
		float mist = sunLight ? mix(0.0016f, mistLow, golden) : 0.0045f;
		float haze = 0.00085f * (1f + 0.6f * golden) * (sunLight ? 1f : 1.3f);
		float mistBase = SEA + 2f, mistH = 12f, hazeBase = SEA + 16f, hazeH = 48f;
		if (look != null) {
			// M2: the open-air layers follow the base's E06 haze and mist (ShadeLook: time-of-day keyframes, morning/evening
			// asymmetry, rain, heights), so the shafts carve the same air the final pass fogs; x MEDIUM_* (the shafts need a
			// denser medium than the haze's own glow to read, VL's art gates assume that density)
			haze = look.hazeSigmaLuma(f) * HDR_HAZE * (1f + 0.6f * golden) * (sunLight ? 1f : 1.3f);
			mist = look.mistSigmaBlock() * HDR_MIST;
			hazeBase = ShadeLook.SEA + ShadeLook.HAZE_BASE;
			hazeH = ShadeLook.HAZE_H;
			mistBase = ShadeLook.SEA + ShadeLook.MIST_BASE;
			mistH = look.mistHeight(f);
			mist *= 0.6f + 0.8f * hum;
		} else {
			mist *= 0.6f + 0.8f * hum;
			mist *= 1f + 3f * rain;
			haze *= 1f + 2f * rain;
		}
		// canopy mist (vl.metal: around the camera's height, scaled by the canopy factor): what makes the shafts under
		// trees and overhangs; densest in the golden hours, humid biomes and rain
		// (none deep in caves: the canopy factor is 1 there, but the mist would only dim the cave toward black)
		// (1.1: mcopt.shade.vl.mist live)
		float canopyMist = (sunLight ? mix(0.008f, 0.03f, golden) : 0.01f) * (0.7f + 0.6f * hum) * (1f + rain) * VlConfig.mist() * eyeLight(f)
			* VlConfig.live("mcopt.shade.vl.mistGain", 1f);
		// its sky-lit colour in the shade (the canopy hides most of the sky): what it dims the scene behind it toward
		float[] amb = f.sky.ambientSky;
		boolean hdr = look != null;
		float ambK = (hdr ? HDR_VEIL : 0.2f) * (f.underwater ? 0f : eyeLight(f));
		float camY = (float) f.cameraY;

		// strength: rain flattens the light; caves have no sun; the sun -> moon handover fades through ~0
		float eye = eyeLight(f);
		float lightUp = smoothstep(0.0f, 0.08f, sunLight ? sunY : f.moonDir.y);
		// (1.1: mcopt.shade.vl.strength and .moon live)
		float strength = VlConfig.strength() * (1f - 0.6f * rain) * (f.underwater ? 1f : eye) * lightUp * (sunLight ? 1f : 2.0f * VlConfig.moon());
		// M2: the art layer's VL keyframe (bible §3.2: strongest at golden hour) and look preset, softened (shafts under a canopy
		// stay visible at noon)
		if (hdr) strength *= look.vlFactor() * (f.underwater ? HDR_WATER : HDR_AIR);
		// (1.1) the player's under-water shafts (mcopt.shade.user.underwaterRays, live; 1 = as released), on top of the god-ray
		// setting below: under water the march's light is the caustic curtains alone (its scatter x this strength)
		float userWater = f.underwater ? VlConfig.userUnderwater() : 1f;
		strength *= userWater;
		// 2026-10-09 (Gael: "se ven poquito"; look development in game, notes/godrays-2026-10-09; then "como un lente empanado":
		// notes/godrays-veil-2026-10-09): the shafts' strength comes from the canopy mist's gain and its local contrast (hp), not
		// from an overall gain (a802352's 1.25 lifted the uniform glow too)
		strength *= VlConfig.look("mcopt.shade.vl.gain", 1f, 1f);

		// light colour (irradiance / pi, pre-exposure): saturated toward the low sun (golden hour), plain moonlight
		float[] c = f.sky.light;
		float lum = 0.2126f * c[0] + 0.7152f * c[1] + 0.0722f * c[2];
		float sat = 1f + 0.55f * golden * day;

		// Air mode (godrays v3, vl.metal; Photon's approach): the final pass's haze shadowed + the forest's humid air, both marched
		// to the scene through the sun's shadow (the fold carries the negative part: not with mcopt.shade.vl.fold=false or under
		// water). mcopt.shade.vl.air (1; look=ft21: 0), live
		boolean air = hdr && VlConfig.FOLD && !f.underwater && VlConfig.look("mcopt.shade.vl.air", 1f, 0f) > 0.5f;
		airActive = air;
		// its march's end: the render distance's fog end (the haze reaches as far), else the preset's distance
		// (1.1: mcopt.shade.vl.dist live)
		float airEnd = air && f.fogRenderEnd > 16f && f.fogRenderEnd < 1e5f ? Math.min(f.fogRenderEnd, 512f) : VlConfig.dist();
		airEndUsed = airEnd;
		if (air) {
			// the forest air's light follows the light itself, not the art keyframes' VL strength (strongest at the golden hour):
			// its density has the time of day (below)
			strength = VlConfig.strength() * (1f - 0.6f * rain) * eye * lightUp * (sunLight ? 1f : VlConfig.moon())
				* VlConfig.live("mcopt.shade.vl.airGain", 1f);
			// its scattering (1/block) at canopy 1: Photon's morning mist is 0.007 (its noon one 0.0001: shafts only in the morning
			// and evening); here the forest keeps some all day (Gael's forest at mid-morning), more at the golden hour, in humid
			// biomes and in rain
			// (where the shade grid says the air around lies in the shade; open sunlit land gets none of it: vl_shade_grid)
			// (gs-w13/w14 in Gael's forest: 0.014 = beams through the gaps at mid-morning, the veil below FT2.2's in 7 of 9 shots;
			// 0.02-0.036 brighter beams but a glow over the sunlit edge of the forest)
			canopyMist = VlConfig.live("mcopt.shade.vl.airForest", 0.017f) * (1f + VlConfig.live("mcopt.shade.vl.airGolden", 1f) * golden)
				* (0.7f + 0.6f * hum) * (1f + rain) * eye;
		}
		float lr = Math.max(lum + (c[0] - lum) * sat, 0f), lg = Math.max(lum + (c[1] - lum) * sat, 0f), lb = Math.max(lum + (c[2] - lum) * sat, 0f);

		// forward scattering: sharper toward the low sun
		// (FT2.3, Gael 2026-10-09: like the packs his reference photos come from, the shafts mostly toward the light: a sharper lobe
		// and a small isotropic share below; ft21 = M2's 0.5..0.72 by the golden hour)
		float g = VlConfig.live("mcopt.shade.vl.g", VlConfig.ft21() ? (sunLight ? mix(0.5f, 0.72f, golden) : 0.6f) : (sunLight ? 0.78f : 0.7f));

		// the light on screen (crepuscular streaks)
		float[] l = f.sky.lightDir;
		Vector4f clip = f.viewProj.transform(new Vector4f(l[0], l[1], l[2], 0f));
		float onScreen = 0f, sx = 0f, sy = 0f;
		if (clip.w > 1e-4f && VlConfig.SS_TAPS > 0 && !f.underwater) {
			float nx = clip.x / clip.w, ny = clip.y / clip.w;
			onScreen = 1f - smoothstep(1.05f, 1.9f, Math.max(Math.abs(nx), Math.abs(ny)));
			sx = (nx * 0.5f + 0.5f) * width;
			sy = (ny * 0.5f + 0.5f) * height;
		}
		onScreen *= smoothstep(-0.02f, 0.08f, l[1]) * eye;

		// water
		float surface = f.underwater ? waterSurface(level, f) : Float.NaN;
		float surfaceRel = Float.isNaN(surface) ? 4f : (float) (surface - f.cameraY);

		float canopyUp = 1f - (float) Math.exp(-dt / 1.5f), canopyDown = 1f - (float) Math.exp(-dt / 4f);

		// (1.1) the player's god-ray strength (ShadeSettings "Rayos de sol", 1 = as released): the shafts, the air's shadows and
		// the forest air; at 0 the module is off (the final pass's haze unshadowed, as with mcopt.shade.vl=false)
		float userRays = mcopt.metal.shade.ShadeSettings.godrays();
		strength *= userRays;
		canopyMist *= userRays;

		b.clear();
		put(b, vw, vh, width, height);                                                   // size
		put(b, strength, airEnd, VlConfig.live("mcopt.shade.vl.stepsLive", VlConfig.STEPS), g); // shape (air mode: its end)
		put(b, haze, mist, mistBase - camY, mistH);                                      // medium
		put(b, hazeBase - camY, hazeH, VlConfig.look("mcopt.shade.vl.iso", 0.12f, 0.35f), 0.05f); // haze (iso: what is seen from the side)
		put(b, lr, lg, lb, canopyMist);                                                  // light
		// crep: in front of geometry, light through the gaps; on the sky (HDR), the shadows of clouds and hills as dark rays
		// (2026-10-09 look development, live: mcopt.shade.vl.crepGain x the strength, crepTaps, crepFall = the exponent of the falloff
		// around the light: lower reaches further, the radial rays of Gael's reference photo)
		// (FT2.3: x2.5, twice the taps and a wider falloff: rays fanning out of the gaps around a visible sun, Gael's reference)
		put(b, VlConfig.SS_TAPS > 0 ? (hdr ? 0.08f + 0.12f * golden : 0.12f + 0.2f * golden) * VlConfig.live("mcopt.shade.vl.crepGain", 1f) * userRays : 0f,
			VlConfig.SS_TAPS > 0 ? VlConfig.live("mcopt.shade.vl.crepTaps", VlConfig.SS_TAPS) : 0f, onScreen, VlConfig.live("mcopt.shade.vl.crepFall", 6f));
		// sunPx; z the still view's clamp allowance, w bits: 1 the 3x3 clamp box, 2 the history at this point's distance,
		// 4 per-texel crepuscular taps over a bilinear sky mask, 8 per-texel offsets of the canopy mist's own steps, 16 of the
		// march under water
		put(b, sx, sy, VlConfig.TEMPORAL ? VlConfig.STILL : 0f, (VlConfig.BOX3 ? 1 : 0) + (VlConfig.HIST_DEPTH ? 2 : 0)
			+ (VlConfig.CREP_SMOOTH ? 4 : 0) + (VlConfig.NEAR_DITHER ? 8 : 0) + (VlConfig.WATER_DITHER ? 16 : 0)
			+ (VlConfig.look("mcopt.shade.vl.marchDither", 1f, 0f) > 0.5f ? 32 : 0) // 32 (FT2.3): the main march's offset per texel
			+ (VlConfig.look("mcopt.shade.vl.farShadow", 1f, 0f) > 0.5f ? 64 : 0)); // 64 (FT2.3): shafts from the far cascade only
		put(b, 0.4f, 0.11f, 0.06f, 0.022f);                                              // water: extinction rgb, scattering
		put(b, surfaceRel, f.underwater ? 1f : 0f, 48f, 1f);                             // water2
		// M3: the caustic curtains run on the water's clock (real time since M2.1: ShadeFrame.waterTime). On the game time the
		// integrated server's once-a-second time corrections jumped their phase, and the 0.9 history smeared the curtains into a
		// uniform glow (weaker shafts than M2); under water the history also follows them faster (they sway with the waves).
		// mcopt.shade.vl.waterM3=false: M2.1's 0.9 and game time.
		put(b, VlConfig.TEMPORAL ? (VlConfig.WATER_M3 && f.underwater ? 0.8f : 0.9f) : 0f, reset ? 1f : 0f, frame & 1023, VlConfig.WATER_M3 ? f.waterTime : f.gameTimeSeconds); // temporal
		put(b, (float) dx, (float) dy, (float) dz, canopyUp);                            // camDelta
		// (2026-10-09: the canopy mist x2.5, its uniform glow cut back by the local contrast below: veil4 i4)
		put(b, 0.7f * VlConfig.look("mcopt.shade.vl.openGain", 1f, 1f), (hdr ? 2.4f : 1.6f) * VlConfig.look("mcopt.shade.vl.canopyGain", 2.5f, 1f),
			VlConfig.CANOPY, VlConfig.DEBUG);                                            // gate: open air, canopy mist, override, debug
		// (y: the canopy mist's scale height above its top, mcopt.shade.vl.mistTopH, live; w: its own steps, nearStepsLive)
		// (FT2.3: the canopy mist from the ground up to 16 blocks above the eye, fading over 16 more, and twice the steps of its
		// own march, each texel offset on its own: shafts from the canopy down to the ground, not smoke rising from it, and thin
		// ones no longer skipped)
		// (air mode: no steps of its own, one march. FT2.8, audit idx 20/23: its documented airTop / airTopH / airRange knobs were
		// never read by the air march; they are gone. The forest air is bounded by the shade grid's box, about 62-64 blocks in
		// x/z and -24..+40 blocks in y around the camera, with an 8-block fade at its faces: vl.metal inGrid)
		put(b, resetCanopy ? 1f : 0f, VlConfig.look("mcopt.shade.vl.mistTopH", 16f, 8f), canopyDown,
			air ? 0f : VlConfig.look("mcopt.shade.vl.nearStepsLive", 2f * VlConfig.NEAR_STEPS, VlConfig.NEAR_STEPS));
		// mist: range, top above the eye (mcopt.shade.vl.mistRange / mistTop, live), extinction on, its scale
		// (air mode: its extinction 1 x its scattering, mcopt.shade.vl.airExt, live. It only dims the march's own light along the
		// ray: the forest air is additive, nothing behind it dims, as in BSL / Complementary: the extinction flag z is 0 there)
		float airExt = Math.max(VlConfig.live("mcopt.shade.vl.airExt", 1f), 0.05f);
		// (1.1: mcopt.shade.vl.extinction live)
		put(b, VlConfig.look("mcopt.shade.vl.mistRange", 24f, 16f), VlConfig.look("mcopt.shade.vl.mistTop", 16f, 4f), VlConfig.extinction() && !air ? 1f : 0f,
			air ? airExt : hdr ? HDR_EXT : 0.5f);
		float sunK = 0.25f * ambK; // plus a little sunlight scattered in from the lit air around (warm at dawn and dusk)
		// the cuts by the angle to the light (vl.metal mixes them; a802352 lowered them away from the light, which veiled side
		// views: since the local contrast (hp) both are FT2.1's again, live: mcopt.shade.vl.openCut / openCutSide / carve / carveSide)
		float openCut = hdr ? VlConfig.live("mcopt.shade.vl.openCut", HDR_OPEN_CUT) : 0.5f, carve = hdr ? VlConfig.look("mcopt.shade.vl.carve", HDR_CARVE, HDR_CARVE) : 0f;
		if (air) {
			// (FT2.8, audit idx 23: no analytic sky-lit part here, the fold never adds it in air mode (extinction flag 0); the
			// forest air's sky light is the march's air3.w, mcopt.shade.vl.airSky, below. openCut is read by the non-air march only)
			put(b, 0f, 0f, 0f, openCut);
		} else {
			put(b, amb[0] * ambK + lr * sunK, amb[1] * ambK + lg * sunK, amb[2] * ambK + lb * sunK, openCut); // mistAmb, open glow left out (toward the light)
		}
		put(b, carve, hdr ? HDR_CARVE_WATER : 0f, histU, histV);                         // carve (toward the light); zw: the history's live part
		// M3.3 art: x the gain of the sky's dark rays (mcopt.shade.vl.skyRays, dev; 1), y their extra gain over the open sky:
		// mcopt.shade.vl.sunsetRays - 1 in the golden hour while the sunset art is on (its brighter, warmer aureole had weakened
		// them); z that extra from the taps past the pixel's own neighbourhood (sunsetFar), w its falloff (sunsetFall); y = 0 is
		// M3.2
		float sunsetArt = mcopt.metal.shade.ShadeSky.sunsetArt ? golden : 0f;
		put(b, VlConfig.skyRays(), (VlConfig.sunsetRays() - 1f) * sunsetArt, VlConfig.sunsetFar() ? 1f : 0f, VlConfig.sunsetFall()); // art
		// tune: x the canopy factor's floor, yz the open cut and the carve away from the light
		put(b, VlConfig.live("mcopt.shade.vl.canopyMin", 0f), hdr ? VlConfig.live("mcopt.shade.vl.openCutSide", openCut) : openCut,
			hdr ? VlConfig.live("mcopt.shade.vl.carveSide", carve) : carve,
			// w: the far march's end at the golden hour (sunset rays from cloud gaps; mcopt.shade.vl.farDist, live)
			hdr && sunLight && !air ? VlConfig.live("mcopt.shade.vl.farDist", 0f) * smoothstep(0.0f, 0.35f, golden) : 0f);
		// tune2: x the far march's density gain, y its cut (mcopt.shade.vl.farGain / farCut, live)
		// (z: the shafts' soft edge radius in blocks, mcopt.shade.vl.soft, live; 0 = sharp)
		// (FT2.3: soft shaft edges, 0.8 blocks: the lit air under a big gap no longer reads as a hard-edged glass sheet)
		put(b, VlConfig.live("mcopt.shade.vl.farGain", 1f), VlConfig.live("mcopt.shade.vl.farCut", hdr ? HDR_OPEN_CUT : 0.5f), VlConfig.look("mcopt.shade.vl.soft", 0.8f, 0f),
			VlConfig.live("mcopt.shade.vl.radialStep", 2f)); // w: the radial blur's tap spacing (VL pixels; v3i: 12 x 2 ~ the reference look)
		// hp (2026-10-09, Gael: the stronger shafts veiled the view "como un lente empanado"): the shafts' local contrast under trees
		// (vl.metal vlVeilR; fold only): x the share of the local mean glow kept, y the gain of what stands out of it, z the veil
		// blur's tap spacing, w on (mcopt.shade.vl.hp / hpKeep / hpGain / hpRadius, live)
		// (veil4 i4: the uniform glow x0.2, a beam at twice its surroundings x1.4, at 3x x1.53; notes/godrays-veil-2026-10-09)
		put(b, VlConfig.look("mcopt.shade.vl.hpKeep", 0.2f, 1f), VlConfig.look("mcopt.shade.vl.hpGain", 1.8f, 1f),
			VlConfig.live("mcopt.shade.vl.hpRadius", 2f), hdr && VlConfig.FOLD && !air && underTrees() ? VlConfig.look("mcopt.shade.vl.hp", 1f, 0f) : 0f);
		// radial (FT2.3): the light direction's vanishing point (homogeneous NDC, scaled to unit size) and the radial blur's taps
		// on each side (mcopt.shade.vl.radialTaps, live; 0 = off; vl.metal vl_radial)
		float vm = Math.max(Math.max(Math.abs(clip.x), Math.abs(clip.y)), Math.max(Math.abs(clip.w), 1e-6f));
		put(b, clip.x / vm, clip.y / vm, clip.w / vm, hdr && VlConfig.FOLD && !f.underwater ? VlConfig.live("mcopt.shade.vl.radialTaps", 0f) : 0f);
		// look2 (FT2.3): x the screen-space streaks in front of geometry (mcopt.shade.vl.crepGeo, live; FT2.1: 1, now 0)
		// yzw (FT2.6): the shade grid's canopy test (vl_shade_grid): the top of its box above a cell (mcopt.shade.vl.airGridUp, 16; 0 =
		// off, FT2.5) and the sunlit share of that box over which the cell turns into sunlit land (airGateLo / airGateHi), live.
		// FT2.6's forest air (Gael's FT2.5 screenshots: a white halo around the sun on the leaves, smoke and puffs over ridges; rounds
		// r2-r7 in notes/bugs-ft25-2026-10-09): canopy test 16, lobe g 0.7 at 0.55 gain (the same light from the side, ~1/4 near the
		// sun), 0.4 of it with the camera in the open (airOpen), density 0.017 (was 0.014: the shafts of real forests keep more of
		// their light where the test lets them be). FT2.5's look: airGridUp=0, airG=0.85, airForestGain=1, airOpen=1, airForest=0.014
		put(b, VlConfig.look("mcopt.shade.vl.crepGeo", 0f, 1f), VlConfig.live("mcopt.shade.vl.airGridUp", 16f),
			VlConfig.live("mcopt.shade.vl.airGateLo", 0.6f), VlConfig.live("mcopt.shade.vl.airGateHi", 0.95f));
		// air (godrays v3): on, Photon's step count (8 + 0.1 per block marched; at most the preset's main + near steps: balanced
		// 20. gs-w18: 16 / 20 / 24 look alike in stills, but Gael asked not to trade the look for speed: 20 as before the
		// optimisation, ~0.1 ms; mcopt.shade.vl.airMin / airGrowth / airSteps, live)
		put(b, air ? 1f : 0f, VlConfig.live("mcopt.shade.vl.airMin", 8f), VlConfig.live("mcopt.shade.vl.airGrowth", 0.1f),
			VlConfig.live("mcopt.shade.vl.airSteps", VlConfig.STEPS + VlConfig.NEAR_STEPS));
		// air2: the march's end (the render distance's fog end, else the preset's distance), the share of the haze's glow the
		// shadows take out over the sky (mcopt.shade.vl.airSkyCut), gains (airShadow: the shadowed part, airForestGain)
		// (airSkyCut 0: the final pass draws no haze over the sky, so the shadows have none to take out there; the sky's dark rays
		// stay the screen-space ones)
		put(b, airEnd, VlConfig.live("mcopt.shade.vl.airSkyCut", 0f), VlConfig.live("mcopt.shade.vl.airShadow", 1f), VlConfig.live("mcopt.shade.vl.airForestGain", 0.55f));
		// grid (godrays v3): the shade grid's corner (camera-relative; cells snapped to the world: 64 x 32 x 64 cells of
		// mcopt.shade.vl.airCell blocks, from 3/8 of its height below the camera), and how far around a cell its taps reach
		// (mcopt.shade.vl.airGridR, live)
		// (grid2.xyz: the corner cell's place in the wrapped texture, its world cell index mod the grid's size; a cell size change
		// or a reset refreshes the whole grid)
		float cell = Math.max(VlConfig.live("mcopt.shade.vl.airCell", 2f), 0.5f);
		long cx = (long) Math.floor(f.cameraX / cell) - 32, cy = (long) Math.floor(f.cameraY / cell) - 12, cz = (long) Math.floor(f.cameraZ / cell) - 32;
		put(b, (float) (cx * (double) cell - f.cameraX), (float) (cy * (double) cell - f.cameraY), (float) (cz * (double) cell - f.cameraZ), cell);
		put(b, Math.floorMod(cx, 64), Math.floorMod(cy, 32), Math.floorMod(cz, 64), Math.max(VlConfig.live("mcopt.shade.vl.airGridR", 4f), 0.5f));
		// air3: the forest air at full density where at most 30 % of the air around is sunlit, none from 85 % (open land), its
		// fade-in from the camera (blocks) and its sky-lit share (mcopt.shade.vl.airLitLo / airLitHi / airNear / airSky, live)
		// (gs-w11, Gael's forest: the near field crisp, the sky-lit share 0.05: under the trees most of the sky is hidden, and that
		// share was a uniform bluish veil. trunk-w19, Gael: "un artefacto de luz sobre la parte de arriba del tronco, como si el haz
		// lo atravesara": the lit forest air 5-8 blocks in front of a trunk lit it up; faded in over 24 blocks instead of 10 the
		// trunk is clean and the beam past it stays)
		put(b, VlConfig.live("mcopt.shade.vl.airLitLo", 0.3f), VlConfig.live("mcopt.shade.vl.airLitHi", 0.85f), VlConfig.live("mcopt.shade.vl.airNear", 24f),
			VlConfig.live("mcopt.shade.vl.airSky", 0.05f));
		// air4: the forest air's share over open sunlit land (mcopt.shade.vl.airBase), its phase (airG: a forward lobe's g, 0 =
		// Photon's two lobes over four octaves; airIso: the isotropic share with it), live
		// (gs-w11: a forward lobe, g 0.85 with 5 % isotropic: the forest air lights up toward the sun, where the shafts are seen along
		// their length; Photon's broader phase glowed from every side = veil)
		// (w: which quarter of the shade grid this frame refreshes; -1 = all of it: after a reset, a cell size change, or
		// mcopt.shade.vl.airGridAll, live)
		// (FT2.7, audit idx 22: by the WORLD cell z mod 4, not the grid's own z: steady flight along z at a speed in step with
		// frame & 3 left some world slices never refreshed, stripes of stale forest air every 8 blocks)
		boolean gridAll = reset || cell != lastCell || VlConfig.live("mcopt.shade.vl.airGridAll", 0f) > 0.5f;
		lastCell = cell;
		put(b, VlConfig.live("mcopt.shade.vl.airBase", 0f), VlConfig.live("mcopt.shade.vl.airG", 0.7f), VlConfig.live("mcopt.shade.vl.airIso", 0.05f),
			gridAll ? -1f : (float) Math.floorMod((long) frame - cz, 4L));
		// air5 (FT2.6): the forest air's fade-out with the distance from the camera (blocks: mcopt.shade.vl.airFar0 / airFar1, live;
		// 0 = none, FT2.5)
		// (z: its share with the camera in the open, the canopy factor 0: mcopt.shade.vl.airOpen, live; 1 = FT2.5)
		// (w: how far sideways the shade grid's canopy test reaches: mcopt.shade.vl.airGridUpR, live; 0 = airGridR)
		put(b, VlConfig.live("mcopt.shade.vl.airFar0", 0f), VlConfig.live("mcopt.shade.vl.airFar1", 0f), VlConfig.live("mcopt.shade.vl.airOpen", 0.4f),
			VlConfig.live("mcopt.shade.vl.airGridUpR", 0f));
		// air6 (FT2.7, audit idx 16): the canopy test as columns (mcopt.shade.vl.airCols: how many, 0 = FT2.6's solid box, 1 = the
		// cell's own axis, the default; airColTaps: taps up each one, 5; airColR: their distance from the cell's axis, blocks, 0 = 3/4
		// of the test's reach), live
		// (w: sky pixels end their air-mode march past the shade grid, where it adds nothing: mcopt.shade.vl.airSkyCull, live; the same image)
		put(b, VlConfig.live("mcopt.shade.vl.airCols", 1f), VlConfig.live("mcopt.shade.vl.airColTaps", 5f), VlConfig.live("mcopt.shade.vl.airColR", 0f),
			VlConfig.live("mcopt.shade.vl.airSkyCull", 1f));
		// air7 (FT2.7): x how high above a cell the canopy test's columns start (mcopt.shade.vl.airColLo, blocks, live, 1.5; 0 =
		// airGridR), y only a blocker that near toward the light shades a column (mcopt.shade.vl.airColNear, blocks, live, 12; 0 = any)
		// (z: the columns and the box both, the lesser open share: mcopt.shade.vl.airColBox, live)
		// (w: the crepuscular taps reprojected into last frame's sky mask: mcopt.shade.vl.crepReproj, live)
		put(b, VlConfig.live("mcopt.shade.vl.airColLo", 1.5f), VlConfig.live("mcopt.shade.vl.airColNear", 12f), VlConfig.live("mcopt.shade.vl.airColBox", 0f),
			VlConfig.live("mcopt.shade.vl.crepReproj", 1f));
		// (air mode: the haze's shadows count wherever the sun is up, even with no forest around)
		if (userRays <= 0f) return false;
		if (userWater <= 0f) return false; // (1.1: under water with its shafts at 0 nothing is added: no passes, as above)
		return strength > 1e-3f || canopyMist > 1e-6f || f.underwater || air && lightUp > 1e-3f;
	}

	/**
	 * Whether the canopy factor the GPU measured (as of the last completed frame) is above ~0: the shafts' local contrast (hp)
	 * only acts under trees, so its three small passes (~0.1 ms, pricevl2) are skipped in the open; it rises over ~1.5 s when
	 * the camera steps under trees, so starting a frame late is invisible (the fold skips it once while the veil is stale).
	 */
	private static boolean underTrees() {
		if (state == 0) return false;
		VlNative.canopy(state, CANOPY_OUT);
		return Math.max(MemoryUtil.memGetFloat(CANOPY_OUT), VlConfig.live("mcopt.shade.vl.canopyMin", 0f)) > 0.005f || VlConfig.CANOPY > 0.005f;
	}

	/** How much sky the camera sees, 0 (cave) .. 1 (outdoors), from the sky light at the eye. */
	private static float eyeLight(ShadeFrame f) {
		return smoothstep(2.5f / 15f, 9.5f / 15f, f.eyeSkyLight / 15f);
	}

	private static void put(ByteBuffer b, float x, float y, float z, float w) {
		b.putFloat(x).putFloat(y).putFloat(z).putFloat(w);
	}
}
