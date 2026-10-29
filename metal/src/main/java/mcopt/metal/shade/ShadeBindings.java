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

import java.nio.ByteBuffer;
import mcopt.metal.MetalBridge;
import mcopt.metal.shade.water.ShadeWater;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.system.MemoryUtil;

/**
 * The global resources every render encoder gets (shade_common.metal's header lists the slots): the ShadeFrame ring,
 * the shadow map (a 1x1x2 dummy until the shadow pass sets one) with its comparison sampler, and the sky-view LUT, which
 * is rendered here once per frame. bind() is called by the backend wherever a new encoder starts: after
 * Native.renderBegin opened one (MetalEncoder.createRenderPass), after MetalTerrain's split reopened it
 * (MetalRenderPass.rebind) and after far terrain or mcopt's own terrain drew (MetalRenderPass.reapplyPipeline, also at the end
 * of restoreAfterSplit). Inside own terrain's split passes (its occlusion test reopens the pass between its draws) the native
 * side binds the same globals itself (mcshade.m mc_shade_reopen_hook, set up in init). Render thread only.
 */
public final class ShadeBindings {
	/** The backend's gate for the bind hooks: a static final, so with shading off the hooks are dead code. */
	public static final boolean ON = Shade.ENABLED;
	/** Ring slots: more than the frames that can be in flight (-Dmcopt.metal.inFlight, 2 by default) plus the one being written. */
	private static final int RING = Math.max(3, Integer.getInteger("mcopt.metal.inFlight", 2) + 1);
	/** ShadeFrame (1024 B) at 0, ShadeLook (1120 B, including lava sprite bounds) at LOOK_OFFSET. */
	private static final int SLOT_SIZE = 2304, LOOK_OFFSET = 1024;

	private static long ctx, state, compareSampler, dummyShadow, shadowMap, gpuBuffer;
	private static ByteBuffer gpuView;
	private static final long[] buffers = new long[RING];
	private static final ByteBuffer[] views = new ByteBuffer[RING];
	private static int slot;
	private static boolean failed, fallback;

	private ShadeBindings() {
	}

	/** Binds the globals into the encoder's open render encoder (enc: the native Enc*); sets everything up on first use. */
	public static void bind(long ctx, long enc) {
		if (state == 0 && !init(ctx)) return;
		ShadeNative.bind(enc);
		if (ShadeWater.ON) ShadeWater.bind(ctx, enc);
		if (mcopt.metal.shade.light.DynLights.ON) mcopt.metal.shade.light.DynLights.bind(enc);
	}

	static boolean ready() {
		return state != 0;
	}

	static synchronized boolean init(long context) {
		if (state != 0) return true;
		if (failed) return false;
		ShadeCompile.worldStart();
		try {
			ctx = context;
			state = ShadeNative.create(context);
			compareSampler = ShadeNative.compareSampler(state);
			dummyShadow = ShadeNative.dummyShadow(state);
			for (int i = 0; i < RING; i++) {
				buffers[i] = MetalBridge.newBuffer(context, SLOT_SIZE);
				views[i] = MemoryUtil.memByteBuffer(MetalBridge.bufferContents(buffers[i]), SLOT_SIZE);
				ShadeFrameUpdater.FRAME.pack(views[i]); // defaults until the first level frame: never an unwritten buffer
				ShadeFrameUpdater.LOOK.pack(views[i].slice(LOOK_OFFSET, ShadeLook.SIZE), ShadeFrameUpdater.FRAME);
			}
			// ShadeGpu (buffer 18): GPU-written; starts at exposure 1 (the first frame snaps to its target)
			gpuBuffer = ShadeNative.buffer(context, 512);
			gpuView = MemoryUtil.memByteBuffer(MetalBridge.bufferContents(gpuBuffer), 512).order(java.nio.ByteOrder.LITTLE_ENDIAN);
			gpuView.putFloat(176, 1f).putFloat(180, 1f).putFloat(184, 1f);
			if (mcopt.metal.shade.light.DynLights.ON) mcopt.metal.shade.light.DynLights.init(context); // M3: its bindings exist from the first draw
			ShadeNative.reopenHook(true); // mcopt 0.3 port: own terrain's mid-pass reopens get the globals back natively
		} catch (Throwable e) {
			// Nothing to bind: the shaded pipelines can't be helped, but at least vanilla's face shade comes back.
			failed = true;
			state = 0;
			System.out.println("[mcopt] shade: setup failed, shading stays off: " + e);
			e.printStackTrace();
			Shade.setFaceShadeOff(false);
			return false;
		}
		try {
			ShadeRobust.maybeFail("lut"); // M3.3: dev-only injected failure (-Dmcopt.shade.dev.failCompile); inert unset
			ByteBuffer source = MemoryUtil.memUTF8(ShadeMsl.lut()); // too big for the thread's MemoryStack
			try (MemoryStack stack = MemoryStack.stackPush()) {
				long err = stack.nmalloc(1, 4096), t0 = ShadeCompile.now();
				int r = ShadeNative.lutInit(state, context, MemoryUtil.memAddress(source), ShadeMsl.LUT_WIDTH, ShadeMsl.LUT_HEIGHT, err, 4096);
				ShadeCompile.setup("sky LUT", t0);
				if (r != 0) throw new IllegalStateException("sky LUT: " + MemoryUtil.memUTF8(err));
			} finally {
				MemoryUtil.memFree(source);
			}
		} catch (Throwable e) {
			// Valid resources are bound (ring, dummy map, an unused LUT texture) and every frame is packed as "vanilla"
			// (ShadeFrame.DIM_VANILLA): the shaded pipelines take their vanilla paths, with vanilla's face shade put back.
			fallback = true;
			System.out.println("[mcopt] shade: setup failed, vanilla look from now on: " + e);
			e.printStackTrace();
			for (int i = 0; i < RING; i++) {
				ShadeFrameUpdater.FRAME.dimension = ShadeFrame.DIM_VANILLA;
				ShadeFrameUpdater.FRAME.pack(views[i]);
			}
		}
		publish();
		return true;
	}

	/** Setup only half worked (the sky LUT pass): frames are packed as ShadeFrame.DIM_VANILLA, without shadows. */
	public static boolean fallback() {
		return fallback;
	}

	/**
	 * The next ring slot, for this frame's ShadeFrame (bound by publish()). ShadeResources (buffer 19) moves to its next slot
	 * too: its own ring is one longer, because encoders a frame opens before this point (lightmap, TAA begin) still bind the
	 * previous frame's slot.
	 */
	static ByteBuffer nextSlot() {
		slot = (slot + 1) % RING;
		ShadeNative.resourcesAdvance(RING + 1);
		return views[slot];
	}

	static ByteBuffer currentSlot() {
		return views[slot];
	}

	/** Points the native bind state at the current slot, shadow map and sampler. */
	static void publish() {
		ShadeNative.set(buffers[slot], 0, shadowMap != 0 ? shadowMap : dummyShadow, compareSampler);
		ShadeNative.setM2(ctx, buffers[slot], LOOK_OFFSET, gpuBuffer);
	}

	/**
	 * ShadeLook.ssr.x of this frame (after ShadeLook.pack): 1 when ShadeResources.prevScene holds a finished earlier frame,
	 * 0 when it is a freshly allocated, never written texture (first frame, the frame after an HDR or TAA reallocation). The
	 * water and glossy shaders then use the scene copy and the sky LUT instead of reading undefined memory.
	 */
	static void setPrevSceneValid(boolean valid) {
		if (state != 0) currentLook().order(java.nio.ByteOrder.LITTLE_ENDIAN).putFloat(ShadeLook.SSR, valid ? 1f : 0f);
	}

	/**
	 * ShadeLook.ssr.y of this frame (after ShadeLook.pack): 1 when ShadeResources.prevDepth holds the linear view depth of
	 * prevScene (the TAA history's), so passes can march last frame's image (M3 weather: puddle reflections).
	 */
	static void setPrevDepthValid(boolean valid) {
		if (state != 0) currentLook().order(java.nio.ByteOrder.LITTLE_ENDIAN).putFloat(ShadeLook.SSR + 4, valid ? 1f : 0f);
	}

	/**
	 * M3 weather coloured shadows, this frame (after ShadeLook.pack and the shadow pass, before the world passes):
	 * ShadeLook.ssr.w = 1 when the tint map holds casters, ShadeLook.tintRect = their rectangle in the near cascade's light
	 * clip space (x0, y0, x1, y1); receivers outside it skip the tint lookup.
	 */
	public static void setShadowTint(boolean casters, float x0, float y0, float x1, float y1) {
		setShadowTint(casters ? 1 : 0, x0, y0, x1, y1);
	}

	/**
	 * M3.3 (shadow work): mode 0 no casters, 1 the tint map spans the near cascade (M3.2), 2 it holds only the rectangle,
	 * top-left at texel (0, 0) (weather_surface.metal shadeShadowTint reads ssr.w).
	 */
	public static void setShadowTint(int mode, float x0, float y0, float x1, float y1) {
		if (state == 0) return;
		boolean casters = mode > 0;
		ByteBuffer b = currentLook().order(java.nio.ByteOrder.LITTLE_ENDIAN);
		b.putFloat(ShadeLook.SSR + 12, mode);
		b.putFloat(ShadeLook.TINT_RECT, casters ? x0 : 1f).putFloat(ShadeLook.TINT_RECT + 4, casters ? y0 : 1f);
		b.putFloat(ShadeLook.TINT_RECT + 8, casters ? x1 : -1f).putFloat(ShadeLook.TINT_RECT + 12, casters ? y1 : -1f);
	}

	/** This frame's ShadeLook bytes (in the current slot). */
	static ByteBuffer currentLook() {
		return views[slot].slice(LOOK_OFFSET, ShadeLook.SIZE);
	}

	/**
	 * The exposure the GPU applied in a recent frame (ShadeGpu.exposure.x, read from the shared buffer without waiting, so
	 * it may be a frame or two old): for logs and CPU-side colours that must match the HDR image. 0 before setup.
	 */
	public static float gpuExposure() {
		return gpuView != null ? gpuView.getFloat(176) : 0f;
	}

	/**
	 * M3.3 (dims, XDR skip): ShadeGpu.xdrHot (set by the bloom's first downsample when a pixel neared the XDR knee in a recent
	 * frame), cleared as it is read. False before setup.
	 */
	public static boolean takeXdrHot() {
		if (gpuView == null || gpuView.getInt(464) == 0) return false;
		gpuView.putInt(464, 0);
		return true;
	}

	/** The metered mean log2 scene luminance (ShadeGpu.scene.x), for logs. */
	public static float gpuMeteredLog2() {
		return gpuView != null ? gpuView.getFloat(192) : 0f;
	}

	/** Renders the sky-view LUT from the current slot into the frame's command buffer (ends any open render encoder). */
	static void renderSkyLut(long enc) {
		ShadeNative.lutRender(enc, state);
	}

	/** The rebinding entry for code holding only a native Enc* (the shadow pass after its own encoders). */
	public static void rebind(long enc) {
		if (state == 0) return;
		ShadeNative.bind(enc);
		if (ShadeWater.ON) ShadeWater.bind(ctx, enc);
		if (mcopt.metal.shade.light.DynLights.ON) mcopt.metal.shade.light.DynLights.bind(enc);
	}

	/**
	 * The shadow pass's map: an MTLTexture of type 2DArray, Depth32Float, one slice per cascade (see shade_common.metal's
	 * convention); 0 goes back to the dummy. The caller keeps it alive while it's set. Takes effect for encoders bound from
	 * now on (call rebind for an open one).
	 */
	public static void setShadowMap(long texture) {
		shadowMap = texture;
		if (state != 0) publish();
	}

	/**
	 * The sky-view LUT (MTLTexture, RGBA16Float, ShadeMsl.LUT_WIDTH x LUT_HEIGHT, bound at texture(17)): the atmosphere's
	 * radiance for this frame, e.g. for reflections; 0 before setup.
	 */
	public static long skyLutTexture() {
		return state != 0 ? ShadeNative.lutTexture(state) : 0;
	}

	/** The comparison sampler bound at sampler(12) (linear, clamp, GreaterEqual), for the shadow pass's own use. */
	public static long compareSampler() {
		return compareSampler;
	}

	/** Rewrites the shadow fields of this frame's slot after Shade.frame().setShadow(...) (the GPU reads it when the frame runs). */
	public static void updateShadow() {
		if (state != 0) ShadeFrameUpdater.FRAME.packShadow(views[slot]);
	}

	static long ctx() {
		return ctx;
	}
}
