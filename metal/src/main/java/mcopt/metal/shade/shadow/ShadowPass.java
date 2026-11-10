// Copyright 2026 mcopt-shade contributors. Licensed under the Apache License, Version 2.0 (LICENSE).
package mcopt.metal.shade.shadow;

import com.mojang.blaze3d.pipeline.RenderTarget;
import com.mojang.blaze3d.systems.RenderSystem;
import com.mojang.renderpearl.api.buffers.GpuBuffer;
import com.mojang.renderpearl.api.buffers.GpuBufferSlice;
import com.mojang.renderpearl.frontend.FrontendCommandEncoder;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;
import mcopt.metal.MetalBridge;
import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.state.level.CameraRenderState;
import net.minecraft.client.renderer.state.level.SkyRenderState;
import net.minecraft.world.level.dimension.DimensionType;
import org.joml.Matrix4f;
import org.joml.Vector3f;
import org.jspecify.annotations.Nullable;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.system.MemoryUtil;

/**
 * The sun (or moon) shadow map: two orthographic cascades in one Depth32Float (or Depth16Unorm) 2D array texture, rendered natively before
 * the frame's first world pass (-Dmcopt.shade=true, mcopt.shade.shadows on by default; see ShadowConfig).
 * <p>
 * Frame lifecycle (ShadowLevelRendererMixin): {@link #beginFrame} at LevelRenderer.render HEAD fits the cascades and fixes
 * this frame's matrices (idempotent within a frame, so the infrastructure's ShadeFrame packer may call it first);
 * {@link #renderFrame} right before the level's frame graph executes lists the casters and encodes the depth passes in
 * their own render encoders; {@link #endFrame} at RETURN draws the debug view (mcopt.shade.debug=1) and closes the frame.
 * <p>
 * Near cascade (slice 0): half-width {@link ShadowConfig#NEAR}, redrawn every frame. Far cascade (slice 1): half-width
 * {@link ShadowConfig#DIST} centered on the camera, redrawn every {@link ShadowConfig#FAR_EVERY} frames, or when the
 * light direction (quantized) changed or the camera left an eighth of it; in between its map and its world-anchored
 * matrix are kept, re-expressed against the moving camera every frame.
 * <p>
 * Conventions (shade_shadow.metal has the receiver code): matrices take CAMERA-RELATIVE world positions (Sodium's origin
 * this frame) to light clip x, y in [-1, 1], z in [0, 1] REVERSED (1 nearest the light, cleared to 0); texture uv =
 * (0.5 + 0.5 x, 0.5 - 0.5 y); the compare sampler is GreaterEqual (lit when receiver depth >= stored).
 */
public final class ShadowPass {
	/** Binding slots of the shared shade contract: texture(16) = map, sampler(12) = compare sampler. */
	public static final int TEXTURE_SLOT = 16, SAMPLER_SLOT = 12;
	public static final int CASCADES = 2;
	private static final int CASCADE_BYTES = 80, DRAW_BYTES = 24, DEBUG_BYTES = 16;
	/** Light below this elevation (sin) is raised to it for the shadow projection, so maps never degenerate at the horizon. */
	private static final double MIN_ELEVATION = Math.sin(Math.toRadians(2.0));
	/**
	 * Light-space depth kept beyond each cascade's half-width: behind its center (away from the light; receivers deeper than
	 * this fall back to the far cascade, or are lit past it) and in front of it, plus how far past that casters are still
	 * listed (they're pancaked onto depth 1 by the clamped depth clip).
	 */
	private static final double NEAR_BACK = 96, FAR_BACK = 64, DEPTH_FRONT = 32, CASTER_REACH = 192;

	private static @Nullable ShadowPass instance;
	private static boolean failed;

	private long shadow;
	private long texture, compareSampler;
	/** M3 coloured shadows: the tint map (0 = off), the water sprites for its pass. */
	private long tintMap;
	private final float[] waterRects = new float[8];
	private static final int TINT_PARAM_BYTES = 48;
	private final ShadowCascade[] cascades = {new ShadowCascade(), new ShadowCascade()};
	private final ShadowCasters casters = new ShadowCasters();
	/** This frame's camera-relative matrices (2 x 16, column-major) and their camera. */
	private final float[] matrices = new float[32];
	private double camX, camY, camZ;
	/** The quantized direction to the light that casts (sun, or moon at night), world space. */
	private final double[] light = new double[3];
	private boolean lightIsMoon;
	private long lightKey = Long.MIN_VALUE, farLightKey = Long.MIN_VALUE;
	/** (1.1) The far cascade's half-width it was last fitted for (mcopt.shade.shadowDist is live: a new one re-fits it). */
	private double fitDist = Double.NaN;
	/**
	 * (1.1) This frame's half-widths (ShadowConfig.near() / dist(), fixed in prepare) for the receivers' splits and texel sizes,
	 * so they always match the cascades drawn this frame.
	 */
	private static volatile double nearNow = ShadowConfig.NEAR, distNow = ShadowConfig.DIST;
	private final boolean[] draw = new boolean[2];
	private int framesSinceFar = Integer.MAX_VALUE / 2;
	/** beginFrame ran for this frame token and found shadows possible. renderOk: the last renderFrame drew the maps. */
	private boolean prepared, renderOk = true;
	private long frameToken, preparedToken = -1;
	private long frames;
	private @Nullable String lastProblem;

	// ---- M3.3 far cascade spread (ShadowConfig.farSpread, read every frame) ----
	/** The fit the back map is being drawn with, part by part; it becomes cascades[1] when the last part is drawn. */
	private final ShadowCascade farBack = new ShadowCascade();
	private final ShadowCascade[] castCascades = new ShadowCascade[2];
	private final float[] backMatrix = new float[16];
	/** The part of the back map drawn next (0..FAR_EVERY-1), -1: no back map under way. */
	private int backPart = -1;
	private long backLightKey;
	/** This frame's far cascade: 0 not drawn, 1 whole into the bound map (M3.2), 2 one part into the back map, 3 the last part (the maps swap first). */
	private int farMode;
	private int farPartNow;
	private boolean spreadReady, spreadFailed;
	/** Light more than this far (cos) from the bound far map's: redraw it whole at once (a /time jump; the day's 0.1 degree steps never get there). */
	private static final double SPREAD_LIGHT_COS = Math.cos(Math.toRadians(1.0));
	private long statSwaps, statWhole;
	// ---- M3.3 GPU timers (ShadowConfig.times) ----
	private boolean timing;
	private long timesPrinted;
	private final long timesOut = MemoryUtil.nmemAlloc(9 * 4);
	/** M3.3 coloured-shadow pricing / lite map (ShadowConfig.tintDev 8). */
	private long tintLite;

	private ShadowPass() {
	}

	// ---- public API (render thread only) ----

	/**
	 * Whether this frame has a shadow map (ShadeFrame.shadowsEnabled; receivers treat everything as lit otherwise). Valid
	 * from beginFrame on: true when the cascades are fitted for this frame and the last render succeeded.
	 */
	public static boolean enabled() {
		ShadowPass p = instance;
		return p != null && p.prepared && p.renderOk && !failed;
	}

	/** The map: an id<MTLTexture> (depth2d_array, Depth32Float or Depth16Unorm, CASCADES slices), 0 before the first frame or when off. */
	public static long texture() {
		ShadowPass p = instance;
		return p == null ? 0 : p.texture;
	}

	/** The compare sampler for sampler(12): an id<MTLSamplerState>, 0 before the first frame or when off. */
	public static long sampler() {
		ShadowPass p = instance;
		return p == null ? 0 : p.compareSampler;
	}

	/**
	 * This frame's camera-relative world -> light clip matrices, column-major, cascade 0 at out[offset..+16), cascade 1 at
	 * out[offset + 16..+32). Identity-free zeros when shadows are off this frame.
	 */
	public static void matrices(float[] out, int offset) {
		ShadowPass p = instance;
		if (p == null || !p.prepared) {
			java.util.Arrays.fill(out, offset, offset + 32, 0f);
			return;
		}
		System.arraycopy(p.matrices, 0, out, offset, 32);
	}

	public static void matrices(float[] out) {
		matrices(out, 0);
	}

	public static void matrices(Matrix4f cascade0, Matrix4f cascade1) {
		float[] m = new float[32];
		matrices(m, 0);
		cascade0.set(m, 0);
		cascade1.set(m, 16);
	}

	/**
	 * ShadeFrame.cascadeSplits: {d0, d1, texel0, texel1}. d0 / d1: distance in blocks from the camera within which cascade 0
	 * / 1 covers every direction inside its 85% blend margin (the near box is pushed ahead of the camera by 40% of its
	 * half-width; the far box may lag the camera by an eighth of its half-width), for receivers that pick a cascade by
	 * distance. shade_shadow.metal picks by the box itself, which covers more. texel0 / texel1: blocks per texel.
	 */
	public static void splits(float[] out) {
		out[0] = (float) ((0.85 - 0.4) * nearNow); // (1.1) this frame's (shadowDist live)
		out[1] = (float) ((0.85 - 0.125) * distNow);
		out[2] = texelSize(0);
		out[3] = texelSize(1);
	}

	/** Receiver depth bias in clip z to use with this map: casters are already biased at raster time, so none is needed. */
	public static float receiverDepthBias() {
		return 0f;
	}

	/** World blocks per shadow texel of cascade i (for the receiver's normal offset). */
	public static float texelSize(int cascade) {
		return (float) (2.0 * (cascade == 0 ? nearNow : distNow) / ShadowConfig.RES); // (1.1) this frame's (shadowDist live)
	}

	/** 1 / resolution: one texel in texture coordinates (ShadeFrame.shadowTexelSize). */
	public static float texelUv() {
		return 1f / ShadowConfig.RES;
	}

	public static int resolution() {
		return ShadowConfig.RES;
	}

	/** Unit world direction toward the light the map was rendered from (sun, or the moon at night). */
	public static void lightDir(float[] out) {
		ShadowPass p = instance;
		if (p == null) {
			out[0] = 0;
			out[1] = 1;
			out[2] = 0;
			return;
		}
		out[0] = (float) p.light[0];
		out[1] = (float) p.light[1];
		out[2] = (float) p.light[2];
	}

	/** Whether the casting light is the moon (the sun is below the horizon). */
	public static boolean lightIsMoon() {
		ShadowPass p = instance;
		return p != null && p.lightIsMoon;
	}

	/**
	 * Binds the map at texture(16) and the compare sampler at sampler(12), vertex and fragment, on the open render encoder
	 * of native encoder enc (MetalBridge.enc). For the infrastructure's global rebinds; a no-op before the first frame.
	 */
	public static void bind(long enc) {
		ShadowPass p = instance;
		if (p == null || p.shadow == 0) return;
		ShadowNative.bind(enc, p.shadow, TEXTURE_SLOT, SAMPLER_SLOT);
	}

	// ---- frame hooks (ShadowLevelRendererMixin) ----

	/**
	 * Fits this frame's cascades and fixes their matrices for camera cam. Idempotent within a frame. Callable by the shade
	 * infrastructure before it packs ShadeFrame (any order relative to the shadow pass's own HEAD hook).
	 */
	public static void beginFrame(CameraRenderState cam) {
		if (!ShadowConfig.SHADOWS || failed || mcopt.metal.shade.ShadeBindings.fallback()) return;
		ShadowPass p = instance;
		if (p == null) p = instance = new ShadowPass();
		if (p.preparedToken == p.frameToken) return;
		p.preparedToken = p.frameToken;
		try {
			p.prepare(cam);
		} catch (RuntimeException | LinkageError e) {
			fail(e);
		}
	}

	/** Encodes the depth passes; called right before the level's frame graph runs (no render pass open). */
	public static void renderFrame() {
		ShadowPass p = instance;
		if (p != null && EntityCasters.ON) EntityCasters.beginFrame(p);
		if (p == null || !p.prepared || failed) return;
		try {
			p.render();
		} catch (RuntimeException | LinkageError e) {
			fail(e);
		}
	}

	/** End of the level's frame: the debug view, then the next frame token. */
	public static void endFrame() {
		ShadowPass p = instance;
		if (p == null) return;
		try {
			if (ShadowConfig.DEBUG == 1 && p.prepared && p.shadow != 0 && !failed) p.debugView();
		} catch (RuntimeException | LinkageError e) {
			fail(e);
		}
		p.frameToken++;
		p.frames++;
	}

	private static void fail(Throwable e) {
		failed = true;
		ShadowPass p = instance;
		if (p != null) p.prepared = false;
		System.out.println("[mcopt] shade: shadow pass disabled after an error: " + e);
		e.printStackTrace(System.out);
	}

	// ---- implementation ----

	private void prepare(CameraRenderState cam) {
		this.prepared = false;
		this.draw[0] = this.draw[1] = false;
		Minecraft mc = Minecraft.getInstance();
		if (mc.level == null || !cam.initialized) return;
		SkyRenderState sky = mc.gameRenderer.gameRenderState().levelRenderState.skyRenderState;
		if (sky.skybox == DimensionType.Skybox.NONE) return; // no sun: Nether
		if (sky.skybox == DimensionType.Skybox.END) {
			// M3 (mcopt.shade.endShadows; (1.1) live): the End's fixed key light (ShadeDims), so the far cascade stays cached
			if (!mcopt.metal.shade.dims.DimsConfig.endShadows() || mcopt.metal.shade.dims.ShadeDims.paused()) return;
			float[] e = mcopt.metal.shade.dims.ShadeDims.endLight();
			this.light[0] = e[0];
			this.light[1] = e[1];
			this.light[2] = e[2];
			this.lightIsMoon = false;
			this.lightKey = 0x456e64L; // constant: never forces a far redraw
		} else {
			this.chooseLight(mcopt.metal.shade.SunClock.angle(sky.sunAngle, 0), mcopt.metal.shade.SunClock.angle(sky.moonAngle, 1));
		}
		double x = cam.pos.x, y = cam.pos.y, z = cam.pos.z;
		this.camX = x;
		this.camY = y;
		this.camZ = z;
		int res = ShadowConfig.RES;
		// near: every frame, pushed ahead of the view so more of it covers what's on screen ((1.1) its half-width read live)
		Vector3f f = cam.orientation.transform(new Vector3f(0, 0, -1));
		double near = ShadowConfig.near(), shift = 0.4 * near;
		this.cascades[0].fit(this.light, x + f.x * shift, y + f.y * shift, z + f.z * shift, near, res, NEAR_BACK, DEPTH_FRONT, CASTER_REACH);
		this.draw[0] = true;
		// far: kept between redraws, anchored in the world
		ShadowCascade far = this.cascades[1];
		double dist = ShadowConfig.dist();
		// (1.1) mcopt.shade.shadowDist live: a new distance re-fits the far cascade and redraws it whole this frame (below), and a
		// spread redraw under way (fitted for the old one) is dropped
		if (dist != this.fitDist) {
			this.fitDist = dist;
			far.valid = false;
			this.backPart = -1;
		}
		nearNow = near;
		distNow = dist;
		double dx = x - far.cx, dy = y - far.cy, dz = z - far.cz;
		boolean moved = dx * dx + dy * dy + dz * dz > (dist / 8) * (dist / 8);
		// M3.3: spread the far redraw over FAR_EVERY frames (one part of the casters per frame into the back map, all parts with
		// one fit, then the maps swap); off = M3.2. A camera jump or a big light jump still redraws it whole in this frame.
		boolean spread = ShadowConfig.FAR_EVERY > 1 && !this.spreadFailed && ShadowConfig.farSpread();
		if (!spread) this.backPart = -1;
		this.farMode = 0;
		boolean lightJump = spread ? far.z[0] * this.light[0] + far.z[1] * this.light[1] + far.z[2] * this.light[2] < SPREAD_LIGHT_COS
			: this.farLightKey != this.lightKey;
		if (!far.valid || moved || lightJump || !spread && this.framesSinceFar >= ShadowConfig.FAR_EVERY - 1) {
			far.fit(this.light, x, y, z, dist, res, FAR_BACK, DEPTH_FRONT, CASTER_REACH);
			this.farMode = 1;
			this.backPart = -1;
		} else if (spread) {
			if (this.backPart < 0) { // a new back map: fitted once, here, for all its parts
				this.farBack.fit(this.light, x, y, z, dist, res, FAR_BACK, DEPTH_FRONT, CASTER_REACH);
				this.backPart = 0;
				this.backLightKey = this.lightKey;
			}
			this.farPartNow = this.backPart;
			if (this.backPart >= ShadowConfig.FAR_EVERY - 1) {
				far.copyFrom(this.farBack); // receivers read the back map (complete after this frame's part) from this frame on
				this.farMode = 3;
			} else {
				this.farMode = 2;
				this.farBack.matrix(x, y, z, this.backMatrix, 0);
			}
		}
		this.draw[1] = this.farMode != 0;
		this.cascades[0].matrix(x, y, z, this.matrices, 0);
		far.matrix(x, y, z, this.matrices, 16);
		this.prepared = true;
	}

	/** The light that casts this frame: the sun, or the moon while the sun is below the horizon, quantized to the sun step. */
	private void chooseLight(double sunAngle, double moonAngle) {
		// vanilla's celestial transform: RotY(-90) * RotX(angle) * (0, 1, 0) = (-sin a, cos a, 0)
		// the same switch as the shade sky (ShadeSky.compute: the moon once the sun is 0.06 below the horizon), so the light
		// the terrain is lit by and the one the map is drawn from are always the same
		boolean useMoon = Math.cos(sunAngle) * Math.cos(Math.toRadians(mcopt.metal.shade.Shade.SUN_TILT)) < -0.06;
		double raw = useMoon ? moonAngle : sunAngle;
		double a = quantize(raw, this.sunStep(raw));
		double[] d = this.dirScratch;
		mcopt.metal.shade.Shade.celestial(a, d); // vanilla's direction, tilted by the shared sun path tilt
		double lx = d[0], ly = d[1], lz = d[2];
		if (ly < MIN_ELEVATION) { // keep the projection sane at the horizon (direct light is ~0 there anyway)
			double h = Math.sqrt(1 - MIN_ELEVATION * MIN_ELEVATION), n = Math.sqrt(lx * lx + lz * lz);
			if (n < 1e-9) {
				lx = h;
				lz = 0;
			} else {
				lx = lx / n * h;
				lz = lz / n * h;
			}
			ly = MIN_ELEVATION;
		}
		this.light[0] = lx;
		this.light[1] = ly;
		this.light[2] = lz;
		this.lightIsMoon = useMoon;
		this.lightKey = Double.doubleToLongBits(a) ^ (useMoon ? 1L : 0L);
	}

	/** This frame's maps weren't drawn: say so to receivers, and refit (redraw) the far cascade next frame. */
	private void unrendered() {
		this.prepared = false;
		this.renderOk = false;
		this.cascades[1].valid = false;
		this.backPart = -1;
		this.draw[0] = this.draw[1] = false;
	}

	private final double[] dirScratch = new double[3];

	/**
	 * (1.2.7, issue #19) The quantization step for a light at this angle: ShadowConfig.SUN_STEP_DEGREES, halved (up to eight times:
	 * 0.0004 degree, under a frame's motion at 60 fps) while a step would move the ground end of a shadow by more than 1 % of its
	 * caster's height. A shadow's length is h / tan(e), so a step de moves its tip by h de / sin^2(e): at 5 degrees a 0.1 degree
	 * step was 0.23 h (a tree's shadow and the god-ray shafts through it jumped over a block three times a second at sunset and
	 * sunrise). Halving keeps the finer grids' points on the coarser ones, and the sun crosses each band once, so the light never
	 * steps back. The far cascade still swaps every FAR_EVERY frames (redrawing it whole each frame instead measured worse:
	 * its texel grid then shimmers), so its hops are smaller, not gone: pixels jumping 12+ levels -48 to -60 % in sunset holds.
	 */
	private double sunStep(double angle) {
		double base = Math.toRadians(ShadowConfig.SUN_STEP_DEGREES);
		if (base <= 0 || !ShadowConfig.sunStepAdaptive()) return base;
		mcopt.metal.shade.Shade.celestial(angle, this.dirScratch);
		double s = Math.max(Math.abs(this.dirScratch[1]), MIN_ELEVATION), allowed = 0.01 * s * s;
		int n = 0;
		while (n < 8 && base / (1 << n) > allowed) n++;
		return base / (1 << n);
	}

	private static double quantize(double angle, double step) {
		return step <= 0 ? angle : Math.round(angle / step) * step;
	}

	/** The tint map's resolution this frame (the receivers' rectangle pad is 8 of its texels). */
	private int tintRes = mcopt.metal.shade.weather.ShadeWeather.COLOR_SHADOW_RES;

	/**
	 * M3 coloured shadows: the listed translucent casters' rectangle in cascade 0's light clip space (its matrix takes
	 * camera-relative positions; orthographic, so a box of half extents h spans its centre +- h.|row|), widened by
	 * 4 texels for the receivers' normal offset and bilinear taps; into this frame's ShadeLook (ssr.w, tintRect).
	 */
	private void publishTint(boolean any) {
		this.publishTint(any, false);
	}

	/** publishTint, with own terrain's casters as the tint pass found them a few passes ago (v12) when own is set. */
	private void publishTint(boolean any, boolean own) {
		boolean on = any && this.tintRect();
		if (own) on = this.ownTintRect(on);
		float[] r = this.tintRectNow;
		mcopt.metal.shade.ShadeBindings.setShadowTint(on ? this.tintSubNow ? 2 : 1 : 0, r[0], r[1], r[2], r[3]);
	}

	/** This frame's tint rectangle (x0, y0, x1, y1 in cascade 0's light clip space, padded; clipped to [-1, 1] with tintSub). */
	private final float[] tintRectNow = new float[4];
	/** M3.3 mcopt.shade.tintSub: this frame's tint pass draws only the rectangle (tintSubMatrix), ssr.w = 2. */
	private boolean tintSubNow;

	/** Fills tintRectNow from the listed casters' boxes; false when none of them reaches the near cascade. */
	private boolean tintRect() {
		float x0 = Float.MAX_VALUE, y0 = Float.MAX_VALUE, x1 = -Float.MAX_VALUE, y1 = -Float.MAX_VALUE;
		float[] m = this.matrices;
		int[] b = this.casters.tintBoxes;
		for (int i = 0; i < this.casters.tintCount; i++) {
			int o = i * 6; // world block box, max exclusive (a section's 16^3, or M3.3's tight box of its translucent blocks)
			float hx = (b[o + 3] - b[o]) * 0.5f, hy = (b[o + 4] - b[o + 1]) * 0.5f, hz = (b[o + 5] - b[o + 2]) * 0.5f;
			float px = (float) (b[o] + hx - this.camX), py = (float) (b[o + 1] + hy - this.camY), pz = (float) (b[o + 2] + hz - this.camZ);
			float cx = m[0] * px + m[4] * py + m[8] * pz + m[12], cy = m[1] * px + m[5] * py + m[9] * pz + m[13];
			float bx = hx * Math.abs(m[0]) + hy * Math.abs(m[4]) + hz * Math.abs(m[8]), by = hx * Math.abs(m[1]) + hy * Math.abs(m[5]) + hz * Math.abs(m[9]);
			x0 = Math.min(x0, cx - bx);
			x1 = Math.max(x1, cx + bx);
			y0 = Math.min(y0, cy - by);
			y1 = Math.max(y1, cy + by);
		}
		float pad = 8f / Math.max(this.tintRes, 1);
		float[] r = this.tintRectNow;
		r[0] = x0 - pad;
		r[1] = y0 - pad;
		r[2] = x1 + pad;
		r[3] = y1 + pad;
		if (this.tintSubNow) { // receivers only look up inside the cascade's square: the drawn rectangle needs no more
			r[0] = Math.max(r[0], -1f);
			r[1] = Math.max(r[1], -1f);
			r[2] = Math.min(r[2], 1f);
			r[3] = Math.min(r[3], 1f);
		}
		return this.casters.tintCount > 0 && r[0] < 1f && r[2] > -1f && r[1] < 1f && r[3] > -1f && r[0] < r[2] && r[1] < r[3];
	}

	/**
	 * M3.3 mcopt.shade.tintSub: cascade 0's matrix (at cascadeData) made to draw only the tint rectangle into the top-left
	 * areaW x areaH texels of the map, at the same texel size as the whole map (texel column (c.x - x0) res / 2, row
	 * (y1 - c.y) res / 2; weather_surface.metal reads it back that way when ssr.w = 2). Returns {areaW, areaH}.
	 */
	private int[] tintSubMatrix(long cascadeData, int res) {
		float[] r = this.tintRectNow;
		int w = Math.min(res, (int) Math.ceil(0.5 * (r[2] - r[0]) * res) + 2), h = Math.min(res, (int) Math.ceil(0.5 * (r[3] - r[1]) * res) + 2);
		float sx = (float) res / w, sy = (float) res / h;
		// clip x'' = sx (c.x - x0) - 1, y'' = 1 - sy (y1 - c.y): row x and row y of the column-major matrix scaled and shifted
		for (int col = 0; col < 4; col++) {
			long ax = cascadeData + (col * 4L) * 4L, ay = ax + 4;
			MemoryUtil.memPutFloat(ax, sx * MemoryUtil.memGetFloat(ax));
			MemoryUtil.memPutFloat(ay, sy * MemoryUtil.memGetFloat(ay));
		}
		long tx = cascadeData + 12 * 4L, ty = cascadeData + 13 * 4L;
		MemoryUtil.memPutFloat(tx, MemoryUtil.memGetFloat(tx) - sx * r[0] - 1f);
		MemoryUtil.memPutFloat(ty, MemoryUtil.memGetFloat(ty) + 1f - sy * r[3]);
		return new int[] {w, h};
	}

	/** The block atlas the terrain is drawn with (cutout and translucent casters sample it), as a Metal texture view. */
	private static long blockAtlas() {
		return MetalBridge.viewHandle(net.minecraft.client.Minecraft.getInstance().getTextureManager()
			.getTexture(net.minecraft.client.renderer.texture.TextureAtlas.LOCATION_BLOCKS).getTextureView());
	}

	/** v12: OwnShadowDraw (mcshadow.m) bytes. */
	private static final int OWN_DRAW_BYTES = 112;
	/** v12: 1 own's shadow pipelines are built, -1 they failed (logged), 0 not tried. */
	private int ownReady;

	/**
	 * v12 (mcopt 0.3 port, P4): cascade c's casters from mcopt's own terrain: OwnTerrain.shadowCull culls its units into the
	 * lists of slot c (in the pre command buffer, which runs before the frame's), and mc_shadow_render_ex draws them
	 * (own/terrain.metal own_shadow_vs). Light mode by construction: every compiled section within the view distance whose box
	 * reaches into the cascade, the faces turned toward the light (the cull's facing test from 4096 blocks along it). 0 when
	 * there is nothing to draw (no own terrain, nothing published yet, its pipelines failed).
	 */
	private long ownDraw(MemoryStack stack, int c, float[] matrix) {
		mcopt.metal.own.OwnTerrain own = mcopt.metal.own.OwnTerrain.get();
		long handle = mcopt.metal.shade.terrain.ShadeTerrain.ownHandle();
		if (own == null || handle == 0 || this.ownReady < 0) return 0;
		if (this.ownReady == 0) {
			long err = stack.ncalloc(1, 1024, 1);
			if (ShadowNative.ownInit(this.shadow, handle, mcopt.metal.own.OwnTerrain.compact(), mcopt.metal.own.OwnTerrain.fat(), err, 1024) != 0) {
				this.ownReady = -1;
				System.out.println("[mcopt] shade: no terrain shadows: own terrain's shadow pipelines failed: " + MemoryUtil.memUTF8(err));
				return 0;
			}
			this.ownReady = 1;
		}
		float[] planes = new float[8];
		try (MemoryStack s = MemoryStack.stackPush()) {
			long at = s.nmalloc(16, 32);
			this.depthPlanes(this.castCascades[c], at);
			for (int i = 0; i < 8; i++) planes[i] = MemoryUtil.memGetFloat(at + i * 4L);
		}
		int part = c == 1 && this.casters.farPart >= 0 ? this.casters.farPart : -1;
		if (!own.shadowCull(c, new org.joml.Matrix4f().set(matrix), (float) this.light[0], (float) this.light[1], (float) this.light[2], planes, part,
			this.casters.farParts)) return 0;
		long[] b = own.shadowBuffers(c);
		long d = stack.ncalloc(16, OWN_DRAW_BYTES, 1);
		for (int i = 0; i < 5; i++) MemoryUtil.memPutLong(d + i * 8L, b[i]);
		MemoryUtil.memPutInt(d + 40, (int) b[5]);
		MemoryUtil.memPutInt(d + 44, 1);
		// the far cascade's cutout drawn as opaque without the plants (ShadowConfig.FAR_CUTOUT_OPAQUE), as with Sodium's lists
		MemoryUtil.memPutInt(d + 48, c == 1 && ShadowConfig.FAR_CUTOUT_OPAQUE ? 2 : 1);
		MemoryUtil.memPutInt(d + 52, mcopt.metal.own.OwnTerrain.shadowClasses());  // (P8) the lists' size classes per layer
		int bx = (int) Math.floor(this.camX), by = (int) Math.floor(this.camY), bz = (int) Math.floor(this.camZ);
		MemoryUtil.memPutInt(d + 56, bx);
		MemoryUtil.memPutInt(d + 60, by);
		MemoryUtil.memPutInt(d + 64, bz);
		MemoryUtil.memPutFloat(d + 72, (float) (bx - this.camX));
		MemoryUtil.memPutFloat(d + 76, (float) (by - this.camY));
		MemoryUtil.memPutFloat(d + 80, (float) (bz - this.camZ));
		// M3.3 far spread: only this frame's part of the far cascade's sections (the cull lists them all)
		if (c == 1 && this.casters.farPart >= 0) {
			MemoryUtil.memPutInt(d + 92, 2);
			MemoryUtil.memPutInt(d + 96, this.casters.farPart);
			MemoryUtil.memPutInt(d + 100, this.casters.farParts);
		}
		return d;
	}

	/** v12: OwnShadowTint (mcshadow.m) bytes; rect ring slots (OWN_TINT_RING there); the tint list's units. */
	private static final int OWN_TINT_BYTES = 240, OWN_TINT_RING = 8, OWN_TINT_CAP = 32768;
	/** v12: rect slots are read this many tint passes after they were written (the GPU is done with them by then). */
	private static final int OWN_TINT_BACK = Math.max(3, Math.min(OWN_TINT_RING - 1, Integer.getInteger("mcopt.metal.inFlight", 2) + 2));
	/** v12: 1 own's tint pipelines are built, -1 they failed (logged), 0 not tried. */
	private int ownTintReady;
	/** v12: own tint passes so far (the rect slot is ownTintPasses % OWN_TINT_RING), and per slot the camera and cascade 0's translation. */
	private long ownTintPasses;
	private final double[] ownTintCam = new double[OWN_TINT_RING * 3];
	private final float[] ownTintMove = new float[OWN_TINT_RING * 2];
	private final int[] ownTintRead = new int[6];

	/**
	 * v12 (P4b): the coloured shadows' casters from mcopt's own terrain, for this frame's tint pass (cascade 0, after ownDraw
	 * drew its depth): the translucent units of every section within the view distance inside the cascade's sides, culled on the
	 * GPU in the tint pass itself (own/terrain.metal own_shadow_tcull). 0 when there is nothing to draw.
	 */
	private long ownTint(MemoryStack stack) {
		mcopt.metal.own.OwnTerrain own = mcopt.metal.own.OwnTerrain.get();
		long handle = mcopt.metal.shade.terrain.ShadeTerrain.ownHandle();
		if (own == null || handle == 0 || this.ownReady != 1 || this.ownTintReady < 0) return 0;
		net.minecraft.client.renderer.ViewArea va = Minecraft.getInstance().levelRenderer.viewArea();
		if (va == null) return 0;
		if (this.ownTintReady == 0) {
			long err = stack.ncalloc(1, 1024, 1);
			if (ShadowNative.ownTintInit(this.shadow, handle, mcopt.metal.own.OwnTerrain.compact(), OWN_TINT_CAP, err, 1024) != 0) {
				this.ownTintReady = -1;
				System.out.println("[mcopt] shade: no coloured shadows from mcopt's own terrain: " + MemoryUtil.memUTF8(err));
				return 0;
			}
			this.ownTintReady = 1;
		}
		long[] b = own.shadowBuffers(0);
		if (b[0] == 0 || b[1] == 0 || b[2] == 0 || b[6] <= 0) return 0;
		long d = stack.ncalloc(16, OWN_TINT_BYTES, 1);
		MemoryUtil.memPutLong(d, b[0]);
		MemoryUtil.memPutLong(d + 8, b[1]);
		MemoryUtil.memPutLong(d + 16, b[2]);
		MemoryUtil.memPutInt(d + 24, (int) (this.ownTintPasses % OWN_TINT_RING));
		// draw: only while the cull listed units lately (the slot OWN_TINT_BACK passes back: the latest the GPU is done with), and
		// in the first passes; otherwise the cull alone runs (the tint map's 8 MB clear and store were ~0.5 ms a frame)
		MemoryUtil.memPutInt(d + 28, this.ownTintPasses + 1 < OWN_TINT_BACK || this.ownTintSlot(this.ownTintPasses + 1 - OWN_TINT_BACK)[5] > 0 ? 1 : 0);
		// OwnTcullFrame: cascade 0's side planes (camera-relative), camera block, offset and section, view distance, sections
		long f = d + 32;
		Matrix4f clip = new Matrix4f().set(java.util.Arrays.copyOfRange(this.matrices, 0, 16));
		org.joml.Vector4f pl = new org.joml.Vector4f();
		int[] planes = {org.joml.Matrix4fc.PLANE_NX, org.joml.Matrix4fc.PLANE_PX, org.joml.Matrix4fc.PLANE_NY, org.joml.Matrix4fc.PLANE_PY};
		for (int i = 0; i < 4; i++) {
			clip.frustumPlane(planes[i], pl);
			MemoryUtil.memPutFloat(f + i * 16L, pl.x);
			MemoryUtil.memPutFloat(f + i * 16L + 4, pl.y);
			MemoryUtil.memPutFloat(f + i * 16L + 8, pl.z);
			MemoryUtil.memPutFloat(f + i * 16L + 12, pl.w);
		}
		int bx = (int) Math.floor(this.camX), by = (int) Math.floor(this.camY), bz = (int) Math.floor(this.camZ);
		float ox = (float) (bx - this.camX), oy = (float) (by - this.camY), oz = (float) (bz - this.camZ);
		MemoryUtil.memPutInt(f + 64, bx);
		MemoryUtil.memPutInt(f + 68, by);
		MemoryUtil.memPutInt(f + 72, bz);
		MemoryUtil.memPutFloat(f + 80, ox);
		MemoryUtil.memPutFloat(f + 84, oy);
		MemoryUtil.memPutFloat(f + 88, oz);
		MemoryUtil.memPutInt(f + 96, bx >> 4);
		MemoryUtil.memPutInt(f + 100, by >> 4);
		MemoryUtil.memPutInt(f + 104, bz >> 4);
		MemoryUtil.memPutInt(f + 112, va.getViewDistance());
		MemoryUtil.memPutInt(f + 116, (int) b[6]);
		this.depthPlanes(this.castCascades[0], f + 128);
		// own_shadow_tint_vs' OwnShadowFrame
		long g = d + 192;
		MemoryUtil.memPutInt(g, bx);
		MemoryUtil.memPutInt(g + 4, by);
		MemoryUtil.memPutInt(g + 8, bz);
		MemoryUtil.memPutFloat(g + 16, ox);
		MemoryUtil.memPutFloat(g + 20, oy);
		MemoryUtil.memPutFloat(g + 24, oz);
		return d;
	}

	/**
	 * v12: cascade's light-space depth range as two planes at `at` (2 x float4, camera-relative world, xyz . p + w >= 0 inside),
	 * as ShadowCascade.casts bounds it (1.1's casters): boxes reaching from zFar up to casterReach past zNear.
	 */
	private void depthPlanes(ShadowCascade cascade, long at) {
		double[] z = cascade.z;
		double zc = z[0] * this.camX + z[1] * this.camY + z[2] * this.camZ;  // the camera's light-space depth
		// z . q + (zc - zFar) >= 0: not wholly beyond the far side (away from the light)
		MemoryUtil.memPutFloat(at, (float) z[0]);
		MemoryUtil.memPutFloat(at + 4, (float) z[1]);
		MemoryUtil.memPutFloat(at + 8, (float) z[2]);
		MemoryUtil.memPutFloat(at + 12, (float) (zc - cascade.zFar));
		// -z . q + (zNear + casterReach - zc) >= 0: not wholly past the caster reach toward the light
		MemoryUtil.memPutFloat(at + 16, (float) -z[0]);
		MemoryUtil.memPutFloat(at + 20, (float) -z[1]);
		MemoryUtil.memPutFloat(at + 24, (float) -z[2]);
		MemoryUtil.memPutFloat(at + 28, (float) (cascade.zNear + cascade.casterReach - zc));
	}

	/** v12: notes this frame's own tint pass (its slot's camera and cascade 0's translation) once it is encoded. */
	private void ownTintEncoded() {
		int k = (int) (this.ownTintPasses % OWN_TINT_RING);
		this.ownTintCam[k * 3] = this.camX;
		this.ownTintCam[k * 3 + 1] = this.camY;
		this.ownTintCam[k * 3 + 2] = this.camZ;
		this.ownTintMove[k * 2] = this.matrices[12];
		this.ownTintMove[k * 2 + 1] = this.matrices[13];
		this.ownTintPasses++;
	}

	/**
	 * v12: widens tintRectNow by own terrain's casters as the pass OWN_TINT_BACK passes ago found them (their rectangle in that
	 * frame's light clip space, moved onto this frame's: the camera's move through this cascade's rows, and the change of its
	 * translation; the light's own turn in between is covered by a small pad). any: tintRectNow already holds casters. Returns
	 * whether it holds any now.
	 */
	private boolean ownTintRect(boolean any) {
		if (this.ownTintPasses < OWN_TINT_BACK) return any;
		int k = (int) ((this.ownTintPasses - OWN_TINT_BACK) % OWN_TINT_RING);
		this.ownTintSlot(this.ownTintPasses - OWN_TINT_BACK);
		if (this.ownTintRead[4] <= 0) return any;
		float x0 = -ordered(this.ownTintRead[0]), y0 = -ordered(this.ownTintRead[1]), x1 = ordered(this.ownTintRead[2]), y1 = ordered(this.ownTintRead[3]);
		if (!(x0 <= x1 && y0 <= y1)) return any;
		float[] m = this.matrices;
		double dx = this.ownTintCam[k * 3] - this.camX, dy = this.ownTintCam[k * 3 + 1] - this.camY, dz = this.ownTintCam[k * 3 + 2] - this.camZ;
		float mx = (float) (m[0] * dx + m[4] * dy + m[8] * dz) + m[12] - this.ownTintMove[k * 2];
		float my = (float) (m[1] * dx + m[5] * dy + m[9] * dz) + m[13] - this.ownTintMove[k * 2 + 1];
		float pad = 8f / Math.max(this.tintRes, 1) + 0.02f;
		float[] r = this.tintRectNow;
		float a0 = x0 + mx - pad, b0 = y0 + my - pad, a1 = x1 + mx + pad, b1 = y1 + my + pad;
		if (any) {
			r[0] = Math.min(r[0], a0);
			r[1] = Math.min(r[1], b0);
			r[2] = Math.max(r[2], a1);
			r[3] = Math.max(r[3], b1);
		} else {
			r[0] = a0;
			r[1] = b0;
			r[2] = a1;
			r[3] = b1;
		}
		return r[0] < 1f && r[2] > -1f && r[1] < 1f && r[3] > -1f;
	}

	/** The rect slot of tint pass number pass into ownTintRead (6 ints: rectangle, quads drawn, units listed). */
	private int[] ownTintSlot(long pass) {
		try (MemoryStack stack = MemoryStack.stackPush()) {
			long out = stack.ncalloc(4, 6, 4);
			ShadowNative.ownTintRect(this.shadow, (int) (pass % OWN_TINT_RING), out);
			for (int i = 0; i < 6; i++) this.ownTintRead[i] = MemoryUtil.memGetInt(out + i * 4L);
		}
		return this.ownTintRead;
	}

	/** own_shadow_tint_vs' ordered-int bits back to the float. */
	private static float ordered(int i) {
		return Float.intBitsToFloat(i >= 0 ? i : i ^ 0x7fffffff);
	}

	private void render() {
		Object encoder = MetalBridge.encoder(((FrontendCommandEncoder) RenderSystem.getDevice().createCommandEncoder()).backend());
		if (encoder == null || MetalBridge.inRenderPass(encoder)) {
			this.problem("not on the Metal backend, or a render pass is open");
			this.unrendered();
			return;
		}
		if (this.shadow == 0) this.create(MetalBridge.ctx(encoder));
		if (this.farMode >= 2 && !this.spreadReady) { // M3.3: the back map, made on first use
			if (ShadowNative.spreadInit(this.shadow) == 0) {
				this.spreadReady = true;
				System.out.println(String.format("[mcopt] shade: far cascade spread over %d frames (second map %.0f MB)", ShadowConfig.FAR_EVERY,
					CASCADES * (ShadowConfig.DEPTH_BITS / 8.0) * ShadowConfig.RES * ShadowConfig.RES / (1 << 20)));
			} else {
				this.spreadFailed = true; // keep M3.2's way: the bound far map stays as it is this frame
				System.out.println("[mcopt] shade: far cascade spread off: no memory for the second map");
				this.farMode = 0;
				this.draw[1] = false;
				this.backPart = -1;
			}
		}
		this.timing = ShadowConfig.times() && ShadowNative.timesFrame(this.shadow, this.frames) == 0;
		if (this.draw[0]) EntityCasters.prepareCast(this.frames, this.camX, this.camY, this.camZ); // M3: last frame's entities, onto this camera
		int faceMask = ShadowCasters.faceMask(this.light, ShadowConfig.ALL_FACES);
		long t0 = ShadowConfig.STATS ? System.nanoTime() : 0;
		// SHADE_DEV_WX_NO_TINT (16384, mcopt.shade.dev, read per frame): skip the tint pass too, to price coloured shadows in one session
		// in heavy rain on performance/balanced (ShadeWeather.tintHidden) the receivers' tint has faded out: no pass either
		// (1.1) mcopt.shade.colorShadows live off (ShadeWeather.colorShadows; the map exists only when it was on at startup): no tint
		// pass, and the receivers are told there are no casters (ssr.w = 0, an empty rectangle), so they skip the lookup
		boolean colour = mcopt.metal.shade.weather.ShadeWeather.colorShadows();
		if (this.tintMap != 0 && !colour) mcopt.metal.shade.ShadeBindings.setShadowTint(0, 1f, 1f, -1f, -1f);
		boolean tint = this.tintMap != 0 && colour && (Integer.getInteger("mcopt.shade.dev", 0) & 16384) == 0 && !mcopt.metal.shade.weather.ShadeWeather.tintHidden();
		int tintDev = ShadowConfig.tintDev();
		this.casters.tintTight = ShadowConfig.tintTight();
		// M3.3 far spread: this frame's far casters are one part of them, cast into the back map's fit (mode 2) or the bound one's
		this.casters.farPart = this.farMode >= 2 ? this.farPartNow : -1;
		this.casters.farParts = ShadowConfig.FAR_EVERY;
		this.castCascades[0] = this.cascades[0];
		this.castCascades[1] = this.farMode == 2 ? this.farBack : this.cascades[1];
		boolean built = this.casters.build(this.castCascades, this.draw, faceMask, this.camX, this.camY, this.camZ, ShadowConfig.CULL_LIGHT, tint,
			mcopt.metal.shade.water.ShadeWater.ON);
		if (ShadowConfig.STATS) this.statBuildNanos += System.nanoTime() - t0;
		if (!built) {
			this.problem(this.casters.problem);
			this.unrendered();
			return;
		}
		if (this.farMode == 3) { // the back map gets its last part this frame and is what receivers read from now on
			ShadowNative.swap(this.shadow);
			this.texture = ShadowNative.texture(this.shadow);
		}
		long enc = MetalBridge.enc(encoder);
		var memory = ((FrontendCommandEncoder) RenderSystem.getDevice().createCommandEncoder()).transientMemory();
		// regions, then every cascade's chunks back to back; one upload each
		int regionBytes = Math.max(16, this.casters.regionCount * ShadowCasters.regionBytes());
		GpuBufferSlice.MappedView regions = memory.allocateGpuMapped(regionBytes, 16L, GpuBuffer.USAGE_UNIFORM);
		MemoryUtil.memCopy(this.casters.regions, MemoryUtil.memAddress(regions.data()), (long) this.casters.regionCount * ShadowCasters.regionBytes());
		int totalChunks = 0;
		for (int c = 0; c < CASCADES; c++) for (ShadowCasters.DrawList l : this.casters.lists[c]) totalChunks += l.count;
		GpuBufferSlice.MappedView chunks = memory.allocateGpuMapped(Math.max(16, (long) totalChunks * ShadowCasters.chunkBytes()), 16L, GpuBuffer.USAGE_UNIFORM);
		long chunkAt = MemoryUtil.memAddress(chunks.data());
		long regionsHandle = MetalBridge.useBuffer(encoder, regions.slice().buffer()), chunksHandle = MetalBridge.useBuffer(encoder, chunks.slice().buffer());
		long atlas = blockAtlas();
		int first = 0;
		boolean tracing = MetalBridge.tracing(encoder);
		try (MemoryStack stack = MemoryStack.stackPush()) {
			for (int c = 0; c < CASCADES; c++) {
				if (!this.draw[c]) continue;
				List<ShadowCasters.DrawList> lists = this.casters.lists[c];
				long draws = stack.ncalloc(8, Math.max(1, lists.size()) * DRAW_BYTES, 1);
				long tintDraws = stack.ncalloc(8, Math.max(1, lists.size()) * DRAW_BYTES, 1);
				int n = 0, nTint = 0;
				// (FT2.8, audit idx 84) the near cascade's cutout lists top-down when the light is high: Sodium meshes a section from
				// its lowest y up and the lists walk the sections bottom-up, so every lower leaf layer was alpha-tested, written and then
				// overwritten by the one above (depth Greater); drawn from the top, the lower layers fail the depth test before shading.
				// The map is the per-texel maximum either way (mcopt.shade.shadowTopDown, read every frame; false = bottom-up)
				boolean topDown = c == 0 && this.light[1] > 0.5 && !"false".equals(System.getProperty("mcopt.shade.shadowTopDown"));
				for (ShadowCasters.DrawList l : lists) {
					if (l.count == 0 || l.arena.isClosed()) continue;
					boolean rev = topDown && l.kind == ShadowCasters.KIND_CUTOUT;
					if (rev) {
						java.nio.IntBuffer ib = MemoryUtil.memIntBuffer(chunkAt + (long) first * ShadowCasters.chunkBytes(), l.count * 2);
						for (int k = l.count - 1; k >= 0; k--) ib.put(l.chunks[k * 2]).put(l.chunks[k * 2 + 1]);
					} else {
						MemoryUtil.memIntBuffer(chunkAt + (long) first * ShadowCasters.chunkBytes(), l.count * 2).put(l.chunks, 0, l.count * 2);
					}
					boolean translucent = l.kind == ShadowCasters.KIND_TRANSLUCENT; // M3 coloured shadows: the tint pass, not the depth pass
					long d = (translucent ? tintDraws : draws) + (long) (translucent ? nTint : n) * DRAW_BYTES;
					MemoryUtil.memPutLong(d, MetalBridge.useBuffer(encoder, l.arena));
					MemoryUtil.memPutInt(d + 8, first);
					MemoryUtil.memPutInt(d + 12, l.count);
					MemoryUtil.memPutInt(d + 16, l.kind | (rev ? 256 : 0));
					first += l.count;
					if (translucent) nTint++; else n++;
				}
				ShadowCascade cascade = this.castCascades[c];
				long cascadeData = stack.ncalloc(16, CASCADE_BYTES, 1);
				// M3.3: a part of the back map is drawn with the back map's fit (receivers still read the bound one this frame)
				boolean back = c == 1 && this.farMode == 2;
				for (int i = 0; i < 16; i++) MemoryUtil.memPutFloat(cascadeData + i * 4L, back ? this.backMatrix[i] : this.matrices[c * 16 + i]);
				float depthPerTexel = (float) (cascade.texelWorld() / cascade.depthRange());
				MemoryUtil.memPutFloat(cascadeData + 64, ShadowConfig.BIAS_TEXELS * depthPerTexel);
				// slope-scaled raster bias, negative: reversed Z pushes casters away from the light by lowering depth
				// M3.3: far parts go into the back map (mode 2) or, the last one, into the just-swapped bound map (mode 3); every part after the
				// first keeps what the slice holds
				int load = c == 1 && this.farMode >= 2 && this.farPartNow > 0 ? 1 : 0;
				int timer = !this.timing ? -1 : c == 0 ? 0 : this.farMode == 1 ? 1 : 2;
				long own = this.ownDraw(stack, c, back ? this.backMatrix : java.util.Arrays.copyOfRange(this.matrices, c * 16, c * 16 + 16));
				int gpuEncoder = ShadowNative.renderEx(enc, this.shadow, c, cascadeData, CASCADE_BYTES, chunksHandle, chunks.slice().offset(), regionsHandle,
					regions.slice().offset(), draws, n, atlas, -ShadowConfig.BIAS_SLOPE, -8f * depthPerTexel, back ? 1 : 0, load, timer, own);
				if (c == 0 && tint) {
					// M3 coloured shadows: the near cascade's translucent casters into the tint map (unbiased matrix: receivers compare their own depth)
					MemoryUtil.memPutFloat(cascadeData + 64, 0f);
					long params = stack.ncalloc(16, TINT_PARAM_BYTES, 1);
					mcopt.metal.shade.water.WaterFrame.rects(this.waterRects);
					for (int i = 0; i < 8; i++) MemoryUtil.memPutFloat(params + i * 4L, this.waterRects[i]);
					// mode.x = 1: leave water out (the water module absorbs the light on its way down to the floor itself)
					MemoryUtil.memPutFloat(params + 32, mcopt.metal.shade.water.ShadeWater.ON ? 1f : 0f);
					long translucentAtlas = atlas;
					// M3.3 pricing (mcopt.shade.tintDev, per frame): 8 = a 512^2 map, 2 = no pass (the last map is looked up), 1 = no lookup
					boolean lite = (tintDev & 8) != 0;
					if (lite && this.tintLite == 0) this.tintLite = ShadowNative.tintLiteInit(this.shadow, 512);
					lite &= this.tintLite != 0;
					this.tintRes = lite ? 512 : mcopt.metal.shade.weather.ShadeWeather.COLOR_SHADOW_RES;
					// M3.3 mcopt.shade.tintSub: draw (clear, store) only the casters' rectangle, at the map's texel size, in its top-left corner
					// (v12: own terrain's casters are found on the GPU during the pass, so the map is drawn whole for them: no rectangle)
					long ownTint = own != 0 ? this.ownTint(stack) : 0;
					this.tintSubNow = ShadowConfig.tintSub() && nTint > 0 && (tintDev & 2) == 0 && ownTint == 0;
					int[] area = this.tintSubNow && this.tintRect() ? this.tintSubMatrix(cascadeData, this.tintRes) : new int[2];
					if ((tintDev & 2) == 0) {
						ShadowNative.tintRenderEx(enc, this.shadow, cascadeData, CASCADE_BYTES, chunksHandle, chunks.slice().offset(), regionsHandle,
							regions.slice().offset(), tintDraws, nTint, translucentAtlas, params, TINT_PARAM_BYTES, lite ? 1 : 0, this.timing ? 3 : -1, area[0], area[1],
							ownTint);
						if (ownTint != 0) this.ownTintEncoded();
					}
					this.publishTint(nTint > 0 && (tintDev & 1) == 0, ownTint != 0 && (tintDev & 1) == 0);
					mcopt.metal.shade.ShadeRender.resource(mcopt.metal.shade.weather.ShadeWeather.RES_SHADOW_TINT, lite ? this.tintLite : this.tintMap);
				}
				if (tracing) {
					System.out.println(String.format("[mcopt] shade trace: shadow cascade %d: %d sections, %d quads, %d chunks in %d draws%s", c, this.casters.sections[c],
						this.casters.quads[c], lists.stream().mapToInt(l -> l.count).sum(), n,
						gpuEncoder >= 0 ? " (gpu encoder #" + gpuEncoder + " in the profile below; later game encoders shift by one)" : ""));
				}
				if (ShadowConfig.STATS) {
					this.statQuads[c] += this.casters.quads[c];
					this.statSections[c] += this.casters.sections[c];
					this.statDraws[c]++;
				}
			}
		}
		switch (this.farMode) {
			case 1 -> { // whole (M3.2's redraw, or a jump in spread mode)
				this.framesSinceFar = 0;
				this.farLightKey = this.lightKey;
				this.statWhole++;
			}
			case 2 -> { // one part of the back map
				this.backPart++;
				this.framesSinceFar++;
			}
			case 3 -> { // the back map is complete and bound: the next frame starts the next one
				this.backPart = -1;
				this.framesSinceFar = 0;
				this.farLightKey = this.backLightKey;
				this.statSwaps++;
			}
			default -> this.framesSinceFar++;
		}
		this.renderOk = true;
		this.draw[0] = this.draw[1] = false;
		if (ShadowConfig.STATS) this.stats();
		if (this.timing || this.timesPrinted != 0) this.times();
		if (this.lastProblem != null) {
			System.out.println("[mcopt] shade: shadow pass running again");
			this.lastProblem = null;
		}
	}

	private final long[] statQuads = new long[2], statSections = new long[2];
	private final int[] statDraws = new int[2];
	private long statBuildNanos, statStart, statFrames;

	/** -Dmcopt.shade.shadowStats: averages every ~5 s (stdout; println, which the game's log captures). */
	private void stats() {
		long now = System.nanoTime();
		if (this.statStart == 0) this.statStart = now;
		this.statFrames++;
		if (now - this.statStart < 5_000_000_000L) return;
		System.out.println(String.format("[mcopt] shade stats: %d frames; near drawn %d x, avg %d sections / %d quads; far drawn %d x, avg %d sections / %d quads; "
			+ "caster listing %.3f ms/frame CPU; casters: %s; far spread %s (%d swaps, %d whole); tint boxes %d (tight %s, %d scans)", this.statFrames,
			this.statDraws[0], this.statSections[0] / Math.max(1, this.statDraws[0]),
			this.statQuads[0] / Math.max(1, this.statDraws[0]), this.statDraws[1], this.statSections[1] / Math.max(1, this.statDraws[1]),
			this.statQuads[1] / Math.max(1, this.statDraws[1]), this.statBuildNanos / 1e6 / this.statFrames, ShadowConfig.CULL_LIGHT ? "light" : "camera",
			ShadowConfig.farSpread(), this.statSwaps, this.statWhole, this.casters.tintCount, this.casters.tintTight, this.casters.tightScans));
		this.statSwaps = this.statWhole = 0;
		java.util.Arrays.fill(this.statQuads, 0);
		java.util.Arrays.fill(this.statSections, 0);
		java.util.Arrays.fill(this.statDraws, 0);
		this.statBuildNanos = 0;
		this.statFrames = 0;
		this.statStart = now;
	}

	/** M3.3 mcopt.shade.shadowTimes: the shadow passes' GPU timers every ~2 s (ms per run, runs). */
	private void times() {
		long now = System.nanoTime();
		if (this.timesPrinted == 0) {
			this.timesPrinted = now;
			return;
		}
		if (now - this.timesPrinted < 2_000_000_000L) return;
		this.timesPrinted = this.timing ? now : 0;
		ShadowNative.times(this.shadow, this.timesOut);
		float[] t = new float[9];
		for (int i = 0; i < 9; i++) t[i] = MemoryUtil.memGetFloat(this.timesOut + i * 4L);
		System.out.println(String.format(java.util.Locale.ROOT,
			"[mcopt] shade: shadow gpu ms near %.3f (%d) far %.3f (%d) farPart %.3f (%d) tint %.3f (%d), %d frames; spread %s, tintTight %s, tintSub %s, tintDev %d",
			t[0], (int) t[4], t[1], (int) t[5], t[2], (int) t[6], t[3], (int) t[7], (int) t[8], ShadowConfig.farSpread(), ShadowConfig.tintTight(),
			ShadowConfig.tintSub(), ShadowConfig.tintDev()));
	}

	private void problem(@Nullable String why) {
		if (why == null || why.equals(this.lastProblem)) return;
		this.lastProblem = why;
		System.out.println("[mcopt] shade: no shadow map this frame: " + why);
	}

	static @Nullable ShadowPass instance() {
		return instance;
	}

	double camX() {
		return this.camX;
	}

	double camY() {
		return this.camY;
	}

	double camZ() {
		return this.camZ;
	}

	/** Whether this frame draws the near cascade (fitted in beginFrame; false in the Nether / End, after a failure). */
	boolean nearThisFrame() {
		return this.prepared && this.draw[0] && !failed;
	}

	/** Frame counter (endFrame advances it). */
	long frame() {
		return this.frames;
	}

	private void create(long ctx) {
		String source = ShadowConfig.source();
		try (MemoryStack stack = MemoryStack.stackPush()) {
			long err = stack.ncalloc(1, 2048, 1);
			mcopt.metal.shade.ShadeRobust.maybeFail("shadow"); // M3.3: dev-only injected failure; inert unset
			long t0 = mcopt.metal.shade.ShadeCompile.now();
			long s = ShadowNative.create(ctx, MemoryUtil.memAddress(stack.UTF8(source)), ShadowConfig.RES, CASCADES, ShadowConfig.DEPTH_BITS, err, 2048);
			mcopt.metal.shade.ShadeCompile.setup("shadows", t0);
			if (s == 0) throw new IllegalStateException("shadow pass setup: " + MemoryUtil.memUTF8(err));
			this.shadow = s;
		}
		EntityCasters.attach(this.shadow); // M3: entity draws cast into the near cascade
		this.texture = ShadowNative.texture(this.shadow);
		this.compareSampler = ShadowNative.compareSampler(this.shadow);
		if (mcopt.metal.shade.weather.ShadeWeather.COLOR_SHADOWS) { // M3 coloured shadows: the near cascade's tint map
			try (MemoryStack stack = MemoryStack.stackPush()) {
				long err = stack.ncalloc(1, 1024, 1);
				if (ShadowNative.tintInit(this.shadow, mcopt.metal.shade.weather.ShadeWeather.COLOR_SHADOW_RES, err, 1024) == 0) {
					this.tintMap = ShadowNative.tintTexture(this.shadow);
					System.out.println("[mcopt] shade: coloured shadows " + mcopt.metal.shade.weather.ShadeWeather.COLOR_SHADOW_RES + "^2 (near cascade)");
				} else {
					System.out.println("[mcopt] shade: no coloured shadows: " + MemoryUtil.memUTF8(err));
				}
			}
		}
		System.out.println(String.format("[mcopt] shade: shadow map %dx%d x %d cascades (%s, %.0f MB), near %.0f / far %.0f blocks, casters: %s, faces: %s, far cutout: %s",
			ShadowConfig.RES, ShadowConfig.RES, CASCADES, ShadowConfig.DEPTH_BITS == 16 ? "Depth16Unorm" : "Depth32Float",
			CASCADES * (ShadowConfig.DEPTH_BITS / 8.0) * ShadowConfig.RES * ShadowConfig.RES / (1 << 20), ShadowConfig.near(), ShadowConfig.dist(),
			ShadowConfig.CULL_LIGHT ? "light" : "camera", ShadowConfig.ALL_FACES ? "all" : "sun-facing", ShadowConfig.FAR_CUTOUT_OPAQUE ? "opaque" : "alpha test"));
	}

	/** mcopt.shade.debug=1: both cascades as tiles in the top-right corner of the main target (near left, far right). */
	private void debugView() {
		Object encoder = MetalBridge.encoder(((FrontendCommandEncoder) RenderSystem.getDevice().createCommandEncoder()).backend());
		if (encoder == null || MetalBridge.inRenderPass(encoder)) return;
		RenderTarget main = Minecraft.getInstance().gameRenderer.mainRenderTarget();
		var color = main.getColorTexture();
		if (color == null) return;
		MetalBridge.flushClear(encoder, color);
		long enc = MetalBridge.enc(encoder);
		int size = Math.max(64, main.height / 4), margin = Math.max(4, main.height / 100);
		try (MemoryStack stack = MemoryStack.stackPush()) {
			long params = stack.ncalloc(16, CASCADES * DEBUG_BYTES, 1);
			for (int c = 0; c < CASCADES; c++) {
				ShadowCascade cascade = this.cascades[c];
				long at = params + (long) c * DEBUG_BYTES;
				MemoryUtil.memPutInt(at, c);
				MemoryUtil.memPutFloat(at + 4, (float) cascade.depthOf(this.camX, this.camY, this.camZ));
				MemoryUtil.memPutFloat(at + 8, (float) cascade.depthRange());
			}
			int x = main.width - CASCADES * (size + margin);
			int y = main.height - size - margin; // GL row order: high rows are the top of the screen
			ShadowNative.debug(enc, this.shadow, MetalBridge.textureHandle(color), x, y, size, margin, params, DEBUG_BYTES);
		}
	}
}
