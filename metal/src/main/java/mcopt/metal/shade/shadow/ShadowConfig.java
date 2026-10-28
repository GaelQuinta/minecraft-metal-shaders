// Copyright 2026 mcopt-shade contributors. Licensed under the Apache License, Version 2.0 (LICENSE).
package mcopt.metal.shade.shadow;

import mcopt.metal.shade.Live;

/**
 * The sun shadow pass's switches. All are system properties, so they can also be set in config/mcopt.properties (Profile
 * applies those before any mixin plugin or class here reads them). Nothing here does anything unless mcopt.shade=true.
 * <ul>
 * <li>{@code mcopt.shade} (false): the native shading pipeline as a whole.</li>
 * <li>{@code mcopt.shade.shadows} (true): the sun shadow map.</li>
 * <li>{@code mcopt.shade.shadowRes} (2048): texels per side of each cascade (512-8192).</li>
 * <li>{@code mcopt.shade.shadowDepth} (32): 32 = Depth32Float, 16 = Depth16Unorm (same speed on the M4 in the synthetic
 * bench, half the memory; precision is ample for both cascades' depth ranges).</li>
 * <li>{@code mcopt.shade.shadowDist} (128): half-width in blocks of the far cascade, centered on the camera. (1.1) live
 * (16..1024, {@link #dist()}): a change re-fits the far cascade and redraws it whole that frame (ShadowPass.prepare).</li>
 * <li>{@code mcopt.shade.shadowNear} (shadowDist / 4): half-width in blocks of the near cascade, which is redrawn every frame
 * and pushed 40% of its half-width ahead of the camera. (1.1) live with shadowDist ({@link #near()}: 4..dist, the live
 * dist / 4 by default).</li>
 * <li>{@code mcopt.shade.shadowFarEvery} (4): the far cascade is redrawn every N frames, or sooner when the light direction
 * (quantized to {@code mcopt.shade.shadowSunStep} degrees, default 0.1) changes or the camera moved an eighth of the
 * cascade.</li>
 * <li>{@code mcopt.shade.shadowCull} (light): which sections cast. {@code light} (default since the M1 integration: verified
 * in game, about +0.15 ms GPU per frame on the bench route for ~250-390k far-cascade quads every 4 frames): every loaded
 * section inside the cascade's light-space box (a read-only scan of Sodium's regions, independent of the camera's
 * occlusion culling and of mcopt's list mixins), so shadows don't pop when turning. {@code camera}: Sodium's render list
 * for the camera this frame (cheaper; misses casters outside the view, e.g. behind the player).</li>
 * <li>{@code mcopt.shade.shadowFaces} (sun): {@code sun} draws only the face directions that face the light (plus
 * unassigned quads), using Sodium's per-facing vertex ranges; {@code all} draws every face.</li>
 * <li>{@code mcopt.shade.shadowBias} (1.0): slope-scaled raster bias (per unit of depth slope, pushes casters away).</li>
 * <li>{@code mcopt.shade.shadowBiasTexels} (1.0): constant raster bias, in shadow texels of world distance along the light.</li>
 * <li>{@code mcopt.shade.shadowFarCutout} (opaque): in the far cascade (1/8 block per texel, coarser than a leaf's holes)
 * axis-aligned cutout faces are drawn as opaque, without the alpha test, and unassigned cutout quads (grass, flowers) are
 * left out; {@code test} alpha-tests them as the near cascade always does.</li>
 * <li>{@code mcopt.shade.shadowStats} (false): every ~5 s, print what each cascade drew and the CPU time spent listing it.</li>
 * <li>{@code mcopt.shade.debug} (0): 1 overlays both cascades in the top-right corner of the screen.</li>
 * <li>M3.3, read every frame (so mcbench can switch them inside one session):
 * <ul>
 * <li>{@code mcopt.shade.shadowFarSpread} (true): the far cascade's redraw is spread over its {@code shadowFarEvery} frames:
 * one part of its casters per frame into a second map, all parts with one fitted cascade (no seams, no swimming), which
 * then becomes the map receivers read. false = M3.2: the whole far cascade every 4th frame (a 0.3-0.5 ms GPU spike on
 * that frame). +16 MB (2048, Depth32) for the second map, made on first use.</li>
 * <li>{@code mcopt.shade.shadowTimes} (false): GPU timers on the shadow passes, logged every ~2 s.</li>
 * <li>{@code mcopt.shade.tintTight} (true): the coloured shadows' rectangle (receivers outside it skip the tint lookup) from
 * the translucent blocks themselves instead of their whole 16^3 sections. false = M3.2.</li>
 * <li>{@code mcopt.shade.tintSub} (true): the tint pass clears, draws and stores only the casters' rectangle (at the map's
 * texel size, in its top-left corner; receivers map their position into it, ssr.w = 2), not the whole near cascade.
 * false = M3.2.</li>
 * <li>{@code mcopt.shade.tintDev} (0): coloured-shadow pricing bits: 1 no lookup (pass kept), 2 no pass (lookup of the last
 * map kept), 8 a 512^2 map.</li>
 * </ul>
 * </li>
 * </ul>
 */
public final class ShadowConfig {
	private ShadowConfig() {
	}

	public static final boolean SHADE = mcopt.metal.shade.Shade.ENABLED;
	public static final boolean SHADOWS = mcopt.metal.shade.Shade.SHADOWS; // one parser for every gate
	/** Per cascade; preset default (Shade.TIER): 2048 for performance, balanced and quality, 3072 for ultra. */
	public static final int RES = clamp(Integer.getInteger("mcopt.shade.shadowRes", mcopt.metal.shade.Shade.TIER >= 3 ? 3072 : 2048), 512, 8192);
	// (FT2.8, audit idx 83) 16 bits by default: -0.1..-0.15 ms in the spin and the flight (d16 A/B x2; the far spread loads and stores
	// the map, PCSS and the VL read it), the same image at noon, sunset and low sun (d16look-*, d16taiga-*; 0.003 / 0.005 block per
	// step in the near / far range, the bias is ~10x that). -Dmcopt.shade.shadowDepth=32: FT2.7's Depth32Float
	public static final int DEPTH_BITS = Integer.getInteger("mcopt.shade.shadowDepth", 16) == 32 ? 32 : 16;
	public static final float DIST = clamp(floatProp("mcopt.shade.shadowDist", 128f), 16f, 1024f);
	public static final float NEAR = clamp(floatProp("mcopt.shade.shadowNear", DIST / 4f), 4f, DIST);
	public static final int FAR_EVERY = clamp(Integer.getInteger("mcopt.shade.shadowFarEvery", 4), 1, 64);
	public static final double SUN_STEP_DEGREES = clamp(floatProp("mcopt.shade.shadowSunStep", 0.1f), 0f, 5f);
	/**
	 * (1.2.7, issue #19) mcopt.shade.shadowSunStepAdaptive (true): near the horizon the light's step shrinks (halved up to eight
	 * times) so a step moves the ground end of a shadow at most 1 % of the caster's height; at a 5 degree sun a 0.1 degree step
	 * moved a tree's shadow tip and its god-ray shafts by over a block, three times a second. false = one step at every height.
	 * Read every frame.
	 */
	static boolean sunStepAdaptive() {
		return mcopt.metal.shade.Live.b("mcopt.shade.shadowSunStepAdaptive", true);
	}
	public static final boolean CULL_LIGHT = !"camera".equals(System.getProperty("mcopt.shade.shadowCull", "light"));
	public static final boolean ALL_FACES = "all".equals(System.getProperty("mcopt.shade.shadowFaces", "sun"));
	public static final float BIAS_SLOPE = floatProp("mcopt.shade.shadowBias", 1.0f);
	public static final float BIAS_TEXELS = floatProp("mcopt.shade.shadowBiasTexels", 1.0f);
	public static final int DEBUG = Integer.getInteger("mcopt.shade.debug", 0);
	public static final boolean FAR_CUTOUT_OPAQUE = !"test".equals(System.getProperty("mcopt.shade.shadowFarCutout", "opaque"));
	public static final boolean STATS = Boolean.getBoolean("mcopt.shade.shadowStats");

	/**
	 * (1.1) live: mcopt.shade.shadowDist (DIST at startup), 16..1024 blocks: the far cascade's half-width this frame.
	 * ShadowPass.prepare re-fits the far cascade when it changes (and drops a spread redraw under way).
	 */
	static float dist() {
		return Live.f("mcopt.shade.shadowDist", DIST, 16f, 1024f);
	}

	/** (1.1) live: mcopt.shade.shadowNear, 4..dist() blocks; default dist() / 4 (NEAR at startup when neither is set). */
	static float near() {
		float dist = dist();
		return clamp(Live.f("mcopt.shade.shadowNear", dist / 4f), 4f, dist);
	}

	/** M3.3 defaults of the per-frame switches (see the class comment). */
	static final String FAR_SPREAD_DEFAULT = "true", TINT_TIGHT_DEFAULT = "true", TINT_SUB_DEFAULT = "true";

	static boolean farSpread() {
		return !"false".equals(System.getProperty("mcopt.shade.shadowFarSpread", FAR_SPREAD_DEFAULT));
	}

	static boolean times() {
		return Boolean.getBoolean("mcopt.shade.shadowTimes");
	}

	static boolean tintTight() {
		return !"false".equals(System.getProperty("mcopt.shade.tintTight", TINT_TIGHT_DEFAULT));
	}

	/** M3.3 mcopt.shade.tintSub (true): the tint pass clears, draws and stores only the casters' rectangle. false = M3.2. */
	static boolean tintSub() {
		return !"false".equals(System.getProperty("mcopt.shade.tintSub", TINT_SUB_DEFAULT));
	}

	static int tintDev() {
		return Integer.getInteger("mcopt.shade.tintDev", 0);
	}

	private static float floatProp(String key, float fallback) {
		String v = System.getProperty(key);
		if (v == null) return fallback;
		try {
			return Float.parseFloat(v.trim());
		} catch (NumberFormatException e) {
			System.out.println("[mcopt] shade: bad " + key + "=" + v + ", using " + fallback);
			return fallback;
		}
	}

	private static int clamp(int v, int lo, int hi) {
		return Math.max(lo, Math.min(hi, v));
	}

	private static float clamp(float v, float lo, float hi) {
		return Math.max(lo, Math.min(hi, v));
	}

	/** shadow.metal, the shadow pass's source (ShadowPass). */
	public static String source() {
		try (java.io.InputStream in = ShadowConfig.class.getResourceAsStream("/mcopt/shade/shadow.metal")) {
			if (in == null) throw new IllegalStateException("missing /mcopt/shade/shadow.metal");
			return new String(in.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
		} catch (java.io.IOException e) {
			throw new IllegalStateException(e);
		}
	}

	/**
	 * (parallel compile, mcopt.metal.shade.ShadeCompile) ShadowPass's library and pipelines (and the coloured shadows' tint
	 * pipeline), made off the render thread and freed again: its own setup then finds them in Metal's shader cache. With one
	 * 1 x 1 layer: the pipelines depend only on the depth format.
	 */
	public static void warmUp(long ctx) {
		java.nio.ByteBuffer source = org.lwjgl.system.MemoryUtil.memUTF8(source());
		try (org.lwjgl.system.MemoryStack stack = org.lwjgl.system.MemoryStack.stackPush()) {
			long err = stack.ncalloc(1, 2048, 1);
			long s = ShadowNative.create(ctx, org.lwjgl.system.MemoryUtil.memAddress(source), 1, 1, DEPTH_BITS, err, 2048);
			if (s == 0) throw new IllegalStateException(org.lwjgl.system.MemoryUtil.memUTF8(err));
			try {
				if (mcopt.metal.shade.weather.ShadeWeather.COLOR_SHADOWS && ShadowNative.tintInit(s, 1, err, 2048) != 0) {
					throw new IllegalStateException(org.lwjgl.system.MemoryUtil.memUTF8(err));
				}
			} finally {
				ShadowNative.free(s);
			}
		} finally {
			org.lwjgl.system.MemoryUtil.memFree(source);
		}
	}
}
