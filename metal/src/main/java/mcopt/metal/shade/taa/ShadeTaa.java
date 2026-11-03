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
package mcopt.metal.shade.taa;

import com.mojang.blaze3d.pipeline.MainTarget;
import com.mojang.blaze3d.pipeline.RenderTarget;
import com.mojang.blaze3d.systems.RenderSystem;
import com.mojang.renderpearl.frontend.FrontendCommandEncoder;
import java.nio.ByteBuffer;
import mcopt.metal.MetalBridge;
import mcopt.metal.shade.Shade;
import mcopt.metal.shade.ShadeMsl;
import net.minecraft.client.Minecraft;
import net.minecraft.world.phys.Vec3;
import org.joml.Matrix4f;
import org.joml.Matrix4fc;
import org.jspecify.annotations.Nullable;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.system.MemoryUtil;

/**
 * Temporal anti-aliasing and upscaling with dynamic resolution for native shading (shader bible E18; flags in TaaConfig;
 * integration notes in TAAU.md). Render thread only.
 *
 * <p>Per frame (the mixins in mcopt.metal.mixin.shade call in this order):
 * <ol>
 * <li>{@link #jitter} (Camera.extractRenderState TAIL): picks this frame's render scale (DynamicResolution) and shifts the
 * camera projection by a Halton(2,3) sub-pixel offset. The offset lives inside the projection matrix, so every world draw
 * (vanilla, Sodium, Distant Horizons, which copies the game's projection) is jittered alike.</li>
 * <li>{@link #beginWorld} (GameRenderer.render, at its first device call): the world target, allocated once at the
 * preset's maximum scale, takes the main target's place; the backend draws every pass on it into the live sub-rect
 * (MetalBridge.setSubRect), so resolution changes never reallocate anything (DH reallocates its targets on every resize).</li>
 * <li>{@link #camera} (GameRenderer.renderLevel, the world's final projection): unjittered matrices for reprojection.</li>
 * <li>{@link #resolve} (GameRenderer.render3dHud HEAD, before the hand: the world's depth is still there): the TAAU pass
 * (taa.metal) resolves the sub-rect into the output-size history and writes it, sharpened, into the real main target,
 * which takes its place back. The hand, screen effects and GUI then draw at native resolution, crisp and unjittered.</li>
 * </ol>
 */
public final class ShadeTaa {
	/** TAA on: native shading on and mcopt.shade.taa not false. A static final, so with shading off this is dead code. */
	public static final boolean ON = Shade.ENABLED && TaaConfig.ENABLED;
	/** A camera that moved further than this between frames was teleported: the history is useless. */
	private static final double TELEPORT = 8;
	/** Frames further apart than this (a menu, a loading screen) start a fresh history. */
	private static final long GAP_NANOS = 500_000_000L;
	private static final int PARAMS = 304;

	private static @Nullable ShadeTaa instance;
	private static boolean failed;
	/**
	 * M2 integration: the world image TAAU resolves is linear pre-exposed HDR (M2's HDR world target, ShadePost), so the
	 * resolve blends range-compressed and rescales the history by ShadeGpu's exposure ratio. Default: whenever the HDR frame
	 * is on (ShadeConfig.HDR); setHdrInput overrides it before the first get().
	 */
	private static boolean hdrInput = mcopt.metal.shade.ShadeConfig.HDR;
	/**
	 * Distant Horizons loaded: a fixed render scale (the preset's start scale, world targets allocated at exactly that size,
	 * no sub-rect). DH renders its LODs into its own targets with a full viewport and copies them 1:1 into the main target,
	 * so a live sub-rect smaller than the allocation would put its frame at the wrong scale (tested on DEV-DH, ti3-dh). DRS
	 * with DH needs its passes on the sub-rect too (FT2).
	 */
	private static final boolean FIXED_FOR_DH = mcopt.metal.DhCompat.loaded();
	private static final DynamicResolution DRS = new DynamicResolution(TaaConfig.SCALE, TaaConfig.SCALE_MIN, TaaConfig.SCALE_MAX, TaaConfig.DRS_FPS);
	/** (1.1) Whether the last frame ran the dynamic resolution (mcopt.shade.drs is live: on again, the controller starts over). */
	private static boolean drsLast = TaaConfig.DRS;

	private final Object encoder;
	private final long ctx, enc, taa;
	private final RenderTarget world = new MainTarget(1, 1);
	/** The game's real main target while the world target stands in for it (output size): where M2's final pass writes. */
	private @Nullable RenderTarget output;
	private int outWidth, outHeight, allocWidth, allocHeight, width, height;
	private float scale = TaaConfig.SCALE;
	/** The scale the world targets were allocated at (M3.1: 1 without Distant Horizons; the live scale with it). */
	private float allocScale = 1f;

	/** With Distant Horizons (fixed scale, targets at exactly that size): the scale the player's choice or the preset asks for. */
	private static float wantedDhScale(int outHeight) {
		float chosen = mcopt.metal.shade.ShadeResolution.scale(outHeight);
		return chosen > 0f ? chosen : TaaConfig.SCALE;
	}
	private int frame;
	private float jitterX, jitterY;
	private boolean jittered, swapped, reset = true;
	private final Matrix4f viewProj = new Matrix4f(), invViewProj = new Matrix4f(), prevViewProj = new Matrix4f(), reprojection = new Matrix4f();
	/** (FT2.8, audit idx 64) reprojection x invViewProj, multiplied in double: TaaParams.reproj. */
	private final org.joml.Matrix4d combinedD = new org.joml.Matrix4d(), invD = new org.joml.Matrix4d();
	private final Matrix4f combined = new Matrix4f();
	private @Nullable Vec3 position, prevPosition;
	private @Nullable Object level;
	private long lastResolve;
	private float lastLogged;
	/** History rescale this frame: exposure now / exposure when the history was made (M2's eye adaptation), 1 without. */
	private float historyRescale = 1f;

	private ShadeTaa(Object encoder, long taa) {
		this.encoder = encoder;
		this.ctx = MetalBridge.ctx(encoder);
		this.enc = MetalBridge.enc(encoder);
		this.taa = taa;
	}

	/** M3.3: whether TAAU's setup failed (it then never runs this session: the render resolution choice has no effect). */
	public static boolean failed() {
		return failed;
	}

	/** M3.3: the TAA state if it was already made (no side effects: for F3 and the pause menu), else null. */
	public static @Nullable ShadeTaa current() {
		return failed ? null : instance;
	}

	/** M3.4: the last world frame's scale came from Auto (the preset / dynamic resolution), not a fixed pause-menu choice. */
	public boolean lastAuto() {
		return this.lastAuto;
	}

	private boolean lastAuto;

	/** M3.3: the window size of the last world frame (0 before the first one). */
	public int outWidth() {
		return this.outWidth;
	}

	public int outHeight() {
		return this.outHeight;
	}

	/** The TAA state, made on first use on the Metal backend; null when off, on another backend or after a setup failure. */
	public static @Nullable ShadeTaa get() {
		if (!ON || instance != null || failed) return instance;
		Object encoder = MetalBridge.encoder(((FrontendCommandEncoder) RenderSystem.getDevice().createCommandEncoder()).backend());
		if (encoder == null) {
			failed = true;
			return null;
		}
		// (FT2.8, audit idx 69) -Dmcopt.shade.taaCompressTaps=true: the history's Catmull-Rom on compressed taps (no ringing past very
		// bright edges); off by default: no ring showed around the sun or the glints while turning (bench motion shots, the bloom and
		// aureole cover it) and it costs +0.08 ms at Retina. Off = FT2.7's filter on linear HDR
		ByteBuffer source = MemoryUtil.memUTF8(TaaConfig.source());
		try (MemoryStack stack = MemoryStack.stackPush()) {
			long err = stack.nmalloc(1, 4096);
			mcopt.metal.shade.ShadeRobust.maybeFail("taa"); // M3.3: dev-only injected failure; inert unset
			long t0 = mcopt.metal.shade.ShadeCompile.now();
			long taa = TaaNative.create(MetalBridge.ctx(encoder), MemoryUtil.memAddress(source), (hdrInput ? 1 : 0) | (TaaConfig.LOSSY ? 2 : 0) | (TaaConfig.DEBUG != 0 ? 4 : 0), err, 4096);
			mcopt.metal.shade.ShadeCompile.setup("TAAU", t0);
			if (taa == 0) throw new IllegalStateException(MemoryUtil.memUTF8(err));
			instance = new ShadeTaa(encoder, taa);
			System.out.println("[mcopt] shade: TAA on, " + TaaConfig.describe()
				+ (TaaConfig.DRS && DynamicResolution.hold() ? String.format(java.util.Locale.ROOT, "; hold controller (M3.3), floor %.2f on performance/balanced", DynamicResolution.HOLD_FLOOR) : "")
				+ (FIXED_FOR_DH ? "; Distant Horizons loaded: fixed scale " + TaaConfig.SCALE + " (no dynamic resolution)" : ""));
			// (FT2.8, audit idx 73) the debug views need a destination target, which the HDR resolve (M2) doesn't take: say so
			if (hdrInput && TaaConfig.DEBUG != 0) System.out.println("[mcopt] shade: mcopt.shade.taaDebug=" + TaaConfig.DEBUG + " ignored: its views exist only without HDR (mcopt.shade.hdr=false)");
		} catch (Throwable e) {
			failed = true;
			System.out.println("[mcopt] shade: TAA setup failed, rendering without it: " + e);
		} finally {
			MemoryUtil.memFree(source);
		}
		return instance;
	}

	/**
	 * M2 integration (TAAU.md): declares that the image handed to {@link #resolveTextures} is linear, pre-exposed HDR (the
	 * resolve then blends in a range-compressed space). Must be called before the first {@link #get()}.
	 */
	public static void setHdrInput(boolean hdr) {
		if (instance != null && hdr != hdrInput) throw new IllegalStateException("ShadeTaa.setHdrInput after setup");
		hdrInput = hdr;
	}

	/** A retired frame's GPU start/end (seconds, host clock), from the backend: the dynamic resolution's input. */
	public static void gpuFrame(double start, double end) {
		DRS.frame(start, end);
	}

	/** Camera.extractRenderState TAIL: this frame's scale, and the projection shifted by its sub-pixel jitter. */
	public void jitter(Matrix4f projection) {
		this.jittered = false;
		if (this.outWidth == 0) return; // no world target yet: the first resolve starts the history anyway
		// M3.1: a resolution the player fixed in the pause menu (ShadeResolution) wins over the preset's dynamic resolution
		float chosen = mcopt.metal.shade.ShadeResolution.scale(this.outHeight);
		this.lastAuto = chosen <= 0f;
		// (1.1) mcopt.shade.drs live: switched on again, the controller starts over at the start scale (its timing and scale are
		// from before it was off); mcopt.shade.drsFps live: the controller's target follows it
		boolean drs = TaaConfig.drs();
		if (drs && !drsLast) DRS.restart(TaaConfig.SCALE);
		drsLast = drs;
		DRS.retarget(TaaConfig.drsFps());
		if (chosen > 0f) this.scale = FIXED_FOR_DH ? Math.min(chosen, this.allocScale) : chosen;
		else if (drs && !FIXED_FOR_DH) {
			// M3.3 dev (mcbench A/B phases, read every frame): mcopt.shade.drs.pause=true holds the preset's start scale (as
			// mcopt.shade.drs=false), =<number> holds that scale (0.4-1); mcopt.shade.drs.restart (any value, cleared here) starts
			// the controller over at the start scale
			float paused = pausedScale();
			if (paused > 0f) {
				DRS.restart(TaaConfig.SCALE);
				this.scale = paused;
			} else {
				if (System.getProperty("mcopt.shade.drs.restart") != null) {
					System.clearProperty("mcopt.shade.drs.restart");
					DRS.restart(TaaConfig.SCALE);
				}
				this.scale = DRS.update();
			}
		} else this.scale = FIXED_FOR_DH ? Math.min(TaaConfig.SCALE, this.allocScale) : TaaConfig.SCALE;
		this.updateSize();
		int phases = Math.clamp(Math.round(8 / (this.scale * this.scale)), 8, 32); // ~8 samples per output pixel (MetalFX/FSR guidance)
		this.frame = this.frame % phases + 1;
		this.jitterX = halton(this.frame, 2) - 0.5f;
		this.jitterY = halton(this.frame, 3) - 0.5f;
		new Matrix4f().translation(2 * this.jitterX / this.width, 2 * this.jitterY / this.height, 0).mul(projection, projection);
		this.jittered = true;
	}

	/** M3.3 dev: the scale mcopt.shade.drs.pause holds (true: the preset's start scale; a number: that scale), 0 = not paused. */
	private static float pausedScale() {
		String v = System.getProperty("mcopt.shade.drs.pause");
		if (v == null || v.equalsIgnoreCase("false")) return 0f;
		if (v.equalsIgnoreCase("true")) return TaaConfig.SCALE;
		try {
			return Math.clamp(Float.parseFloat(v.trim()), 0.4f, 1f);
		} catch (NumberFormatException e) {
			return 0f;
		}
	}

	private void updateSize() {
		this.width = Math.clamp(Math.round(this.outWidth * this.scale), 1, this.allocWidth);
		this.height = Math.clamp(Math.round(this.outHeight * this.scale), 1, this.allocHeight);
		if (TaaConfig.DRS_LOG && this.scale != this.lastLogged) {
			this.lastLogged = this.scale;
			System.out.println(String.format("[mcopt] shade: render scale %.3f (%dx%d), GPU %.2f ms/frame", this.scale, this.width, this.height, DRS.averageMs()));
		}
	}

	/** GameRenderer.render, first device call: the target the world draws into this frame (mainTarget's stand-in). */
	public RenderTarget beginWorld(RenderTarget mainTarget) {
		// (2026-10-09) the output size: the window's, or the chosen output resolution below it (ShadeOutput): TAAU resolves into a
		// history of that size and the final pass tone-maps at it, then one upscale pass fills the window (ShadePost)
		int[] o = mcopt.metal.shade.ShadeOutput.size(mainTarget.width, mainTarget.height);
		// (with Distant Horizons the world targets match the live scale exactly: a new resolution choice reallocates them)
		float dhWant = FIXED_FOR_DH ? wantedDhScale(o[1]) : 0f;
		if (o[0] != this.outWidth || o[1] != this.outHeight || (FIXED_FOR_DH && dhWant != this.allocScale)) {
			if (FIXED_FOR_DH) this.scale = dhWant;
			this.resize(o[0], o[1]);
		}
		if (!this.jittered) this.updateSize();
		MetalBridge.setSubRect(this.encoder, this.world.getColorTexture(), this.world.getDepthTexture(),
			this.width < this.allocWidth || this.height < this.allocHeight ? this.width : 0, this.height);
		this.swapped = true;
		this.output = mainTarget;
		return this.world;
	}

	private void resize(int outWidth, int outHeight) {
		this.outWidth = outWidth;
		this.outHeight = outHeight;
		// M3.1: allocated for the native choice of the pause menu (ShadeResolution), so any choice is a sub-rect of them
		float allocScale = FIXED_FOR_DH ? this.scale : 1f;
		this.allocScale = allocScale;
		this.allocWidth = Math.max(1, Math.round(this.outWidth * allocScale));
		this.allocHeight = Math.max(1, Math.round(this.outHeight * allocScale));
		this.world.resize(this.allocWidth, this.allocHeight);
		// Everything the level renderer pairs with the main target (entity outlines, post chains) matches the world target.
		Minecraft.getInstance().levelRenderer.resize(this.allocWidth, this.allocHeight);
		TaaNative.resize(this.taa, this.ctx, this.outWidth, this.outHeight);
		this.updateSize();
		this.reset = true;
		System.out.println(String.format("[mcopt] shade: TAA %dx%d -> %dx%d (world targets %dx%d)", this.width, this.height, this.outWidth, this.outHeight,
			this.allocWidth, this.allocHeight));
	}

	/** The game's main target (the window's size) this frame stands in for; null before the first beginWorld. */
	public @Nullable RenderTarget outputTarget() {
		return this.output;
	}

	/**
	 * Whether the output resolution is below the window's (ShadeOutput): the history and the final pass are then outWidth() x
	 * outHeight(), and ShadePost upscales into {@link #outputTarget()}.
	 */
	public boolean outputScaled() {
		RenderTarget o = this.output;
		return o != null && (this.outWidth != o.width || this.outHeight != o.height);
	}

	/** The world targets' allocated size (the sub-rect (0, 0, width(), height()) of it is live while swapped). */
	public int allocWidth() {
		return this.allocWidth;
	}

	public int allocHeight() {
		return this.allocHeight;
	}

	/**
	 * M2 (ShadePost.beforeHand): resolves this frame's HDR world (color: the HDR world target, depth: the world depth, both
	 * at the allocation size with the live sub-rect) into the output-size history and returns it (RGBA16Float, pre-exposed
	 * with this frame's exposure: the resolve rescales the old history by ShadeGpu.exposure.x / .z on the GPU). The final
	 * pass sharpens it while tone mapping, so there is no output pass.
	 */
	public long resolveHdr(long color, long depth) {
		this.resolveTextures(color, depth, 0, 0, 0f);
		return this.history();
	}

	/** M2: exposure(now) / exposure(previous frame) (ShadeGpu.exposure.x / .z), so the history follows eye adaptation. */
	public void setHistoryRescale(float rescale) {
		this.historyRescale = rescale > 0 && Float.isFinite(rescale) ? rescale : 1f;
	}

	/** Whether the world target stands in for the main one right now (between beginWorld and resolve). */
	/** (1.2.7) The last resolve's camera stood still (no move, the same reprojection): ShadePost skips the motion blur, which then returns its input. */
	public boolean still() {
		return this.still;
	}

	private boolean still;

	public boolean swapped() {
		return this.swapped;
	}

	/** The live render size while swapped (ScreenSize, ShadeFrame.screen), else the given full size. */
	public int width(int full) {
		return this.swapped ? this.width : full;
	}

	public int height(int full) {
		return this.swapped ? this.height : full;
	}

	/** This frame's jitter in NDC (ShadeFrame.jitter.xy), 0 when not jittered. */
	public float jitterNdcX() {
		return this.jittered ? 2 * this.jitterX / this.width : 0;
	}

	public float jitterNdcY() {
		return this.jittered ? 2 * this.jitterY / this.height : 0;
	}

	/** The factor for texture gradients (mip bias log2 of it): the render scale, so textures stay as sharp as at native. */
	public float mipScale() {
		return TaaConfig.MIP_BIAS && this.swapped ? this.scale : 1f;
	}

	public float scale() {
		return this.scale;
	}

	/** GameRenderer.renderLevel: the projection every world draw uses this frame (jittered, view bobbing applied), its view rotation and camera position. */
	public void camera(Matrix4fc projection, Matrix4fc viewRotation, Vec3 position) {
		if (!this.swapped) return;
		Matrix4f p = new Matrix4f(projection);
		if (this.jittered) new Matrix4f().translation(-2 * this.jitterX / this.width, -2 * this.jitterY / this.height, 0).mul(p, p);
		p.mul(viewRotation, this.viewProj);
		this.position = position;
		if (ShadeMotion.ON) { // M3: moving entities for the resolve's per-object reprojection
			this.motion.update(position, this.viewProj);
			this.motion.upload(this.taa);
		}
	}

	private final ShadeMotion motion = new ShadeMotion();

	/** Movers (entities that moved since last frame) this frame, for logs. */
	public int movers() {
		return this.motion.count;
	}

	/**
	 * GameRenderer.render3dHud HEAD: resolves the world into mainTarget (the real main target, which takes its place back from
	 * here: the hand, screen effects and GUI draw at native resolution).
	 */
	public void resolve(RenderTarget mainTarget) {
		MetalBridge.flushClear(this.encoder, this.world.getColorTexture());
		MetalBridge.flushClear(this.encoder, this.world.getDepthTexture());
		MetalBridge.dropPendingClear(this.encoder, mainTarget.getColorTexture()); // overwritten whole
		this.resolveTextures(MetalBridge.textureHandle(this.world.getColorTexture()), MetalBridge.textureHandle(this.world.getDepthTexture()), 0,
			MetalBridge.textureHandle(mainTarget.getColorTexture()), TaaConfig.sharpen(this.scale));
	}

	/**
	 * The resolve itself, on native MTLTexture handles (M2's HDR post chain calls this instead of {@link #resolve}, TAAU.md):
	 * color/depth = this frame's jittered world render (any texture size; the live sub-rect is (0, 0, width(), height())),
	 * reactive = an R8 mask in input pixels (1 = don't trust the history) or 0, dst = an output-size target that receives the
	 * sharpened result, or 0 (only the history is written: read it with {@link #history()}, e.g. in a final pass that
	 * sharpens). Ends the world part of the frame: from here passes draw at full size again.
	 */
	public void resolveTextures(long color, long depth, long reactive, long dst, float sharpen) {
		this.swapped = false;
		MetalBridge.setSubRect(this.encoder, null, null, 0, 0);
		long now = System.nanoTime();
		Object level = Minecraft.getInstance().level;
		boolean cut = this.reset || this.position == null || this.prevPosition == null || level != this.level || now - this.lastResolve > GAP_NANOS
			|| this.position.distanceTo(this.prevPosition) > TELEPORT
			|| Boolean.getBoolean("mcopt.shade.taa.cut"); // M3.3 dev (live): no history at all, for diagnosing feedback
		boolean still = false;
		if (cut) {
			this.reprojection.set(this.viewProj);
		} else {
			Vec3 d = this.position.subtract(this.prevPosition);
			this.prevViewProj.translate((float) d.x, (float) d.y, (float) d.z, this.reprojection); // last frame's clip from this frame's camera-relative world
			still = d.lengthSqr() < 1e-8 && this.reprojection.equals(this.viewProj, 1e-6f);
		}
		this.still = still;
		this.viewProj.invert(this.invViewProj);
		try (MemoryStack stack = MemoryStack.stackPush()) {
			long p = stack.nmalloc(16, PARAMS);
			this.invViewProj.getToAddress(p);
			this.reprojection.getToAddress(p + 64);
			Matrix4f m = this.viewProj; // row 3: clip w (linear view depth)
			put4(p + 128, m.m03(), m.m13(), m.m23(), m.m33());
			put4(p + 144, this.width, this.height, 0, 0);
			put4(p + 160, this.outWidth, this.outHeight, 1f / this.outWidth, 1f / this.outHeight);
			put4(p + 176, this.jittered ? this.jitterX : 0, this.jittered ? this.jitterY : 0, (float) this.width / this.outWidth, (float) this.height / this.outHeight);
			put4(p + 192, TaaConfig.alphaMin(), TaaConfig.clipGamma(still), 32, cut ? 1 : 0);
			put4(p + 208, this.historyRescale, 0f, reactive != 0 ? 0.85f : 0f, TaaConfig.DEBUG); // no mask: the shader skips its read
			put4(p + 224, sharpen, TaaConfig.motionAlpha(), 0, 0);
			this.combinedD.set(this.reprojection).mul(this.invD.set(this.invViewProj));
			this.combined.set(this.combinedD).getToAddress(p + 240);
			TaaNative.resolve(this.enc, this.taa, color, depth, reactive, dst, p, PARAMS);
		}
		this.prevViewProj.set(this.viewProj);
		this.prevPosition = this.position;
		this.level = level;
		this.lastResolve = now;
		this.reset = false;
	}

	/** Safety net at FogRenderer.endFrame: a frame that never reached resolve (no hand pass) leaves nothing swapped. */
	public void endFrame() {
		if (!this.swapped) return;
		this.swapped = false;
		MetalBridge.setSubRect(this.encoder, null, null, 0, 0);
		this.reset = true;
	}

	/**
	 * Whether {@link #history()} holds a resolved frame: false from a (re)allocation until the next resolve (the textures are
	 * then undefined memory), and after a frame that never reached its resolve.
	 */
	public boolean historyValid() {
		return !this.reset;
	}

	/** The latest resolved history (MTLTexture: RGBA16Float, output size; rgb as the input encodes it, a = age in frames), for later passes. */
	public long history() {
		return TaaNative.history(this.taa);
	}

	/** Its linear view depth (MTLTexture: R16Float, output size, blocks). */
	public long historyDepth() {
		return TaaNative.historyDepth(this.taa);
	}

	private static void put4(long at, float x, float y, float z, float w) {
		MemoryUtil.memPutFloat(at, x);
		MemoryUtil.memPutFloat(at + 4, y);
		MemoryUtil.memPutFloat(at + 8, z);
		MemoryUtil.memPutFloat(at + 12, w);
	}

	private static float halton(int index, int base) {
		float result = 0, f = 1;
		for (int i = index; i > 0; i /= base) {
			f /= base;
			result += f * (i % base);
		}
		return result;
	}
}
