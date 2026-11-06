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

import java.util.Locale;
import mcopt.metal.shade.Live;

/**
 * Temporal anti-aliasing / upscaling settings (shader bible E18, §5), read once at startup from system properties (or
 * config/mcopt.properties, which mcopt's Profile turns into the same properties first). Free of game types.
 *
 * <p>Flags:
 * <ul>
 * <li>{@code mcopt.shade.taa} (true): TAA/TAAU on while native shading is on. false = M1's native, unjittered render.</li>
 * <li>{@code mcopt.shade.preset} (Shade.PRESET_DEFAULT; Shade.TIER, which every module reads): performance | balanced | quality | ultra, see {@link Preset}.</li>
 * <li>{@code mcopt.shade.scale}: start scale (overrides the preset's); {@code mcopt.shade.scaleMin} / {@code scaleMax}: the
 * dynamic resolution range. The world targets are allocated at scaleMax, so a narrower range also saves memory.</li>
 * <li>{@code mcopt.shade.drs} (true): dynamic resolution; {@code mcopt.shade.drsFps}: its target frame rate (preset's). (1.1)
 * both live ({@link #drs()}, {@link #drsFps()}): on again, the controller starts over at the start scale; a new target
 * retargets it (ShadeTaa.jitter).</li>
 * <li>{@code mcopt.shade.taaMode} (preset's): responsive | stable (history weight and clip box). (1.1) live ({@link #stable()}).</li>
 * <li>{@code mcopt.shade.sharpen}: sharpening strength 0..1 (default by scale: 0.25 native .. 0.4 at 0.67x). (1.1) live.</li>
 * <li>{@code mcopt.shade.mipBias} (true): sharper texture mips at reduced scale (log2 scale), like native.</li>
 * <li>{@code mcopt.shade.taaDebug} (0): 1 history age, 2 rejection (red clip, green disocclusion, blue off-screen), 3 no history, 4 reprojection check (unclipped history 50/50 over the current frame).</li>
 * <li>{@code mcopt.shade.drsLog} (false): one log line per resolution change.</li>
 * <li>{@code mcopt.shade.taaLossy} (false): lossy-compressed colour history (Apple8+).</li>
 * </ul>
 * Never below 0.6x, and no preset starts below 0.67x (critique C2): fewer pixels than that is below what the user ran at
 * 1080p before.
 */
public final class TaaConfig {
	/**
	 * The presets: start scale, dynamic resolution range, target fps, history mode. performance and balanced aim at the 120 Hz
	 * panel; quality at 80 (native resolution, the 120 Hz panel's VRR range), ultra at 60. The ranges and targets are the bible's §5 table.
	 */
	public enum Preset {
		PERFORMANCE(0.67f, 0.60f, 0.75f, 120, false),
		BALANCED(0.80f, 0.60f, 0.90f, 120, true), // floor 0.60 under load (bible §5 fallback: water-heavy views pinned it at 0.67)
		QUALITY(1.00f, 0.85f, 1.00f, 80, true),
		ULTRA(1.00f, 0.90f, 1.00f, 60, true);

		public final float scale, min, max;
		public final int fps;
		public final boolean stable;

		Preset(float scale, float min, float max, int fps, boolean stable) {
			this.scale = scale;
			this.min = min;
			this.max = max;
			this.fps = fps;
			this.stable = stable;
		}
	}

	/** The absolute floor of any scale (a transient dip; presets never start this low). */
	public static final float FLOOR = 0.6f;

	public static final boolean ENABLED = Boolean.parseBoolean(System.getProperty("mcopt.shade.taa", "true"));
	public static final Preset PRESET = Preset.values()[mcopt.metal.shade.Shade.TIER];
	public static final float SCALE_MAX = clamp(floatProp("mcopt.shade.scaleMax", PRESET.max), FLOOR, 1f);
	public static final float SCALE_MIN = clamp(floatProp("mcopt.shade.scaleMin", PRESET.min), FLOOR, SCALE_MAX);
	public static final float SCALE = clamp(floatProp("mcopt.shade.scale", PRESET.scale), SCALE_MIN, SCALE_MAX);
	public static final boolean DRS = Boolean.parseBoolean(System.getProperty("mcopt.shade.drs", "true")) && SCALE_MIN < SCALE_MAX;
	public static final int DRS_FPS = Math.max(20, Integer.getInteger("mcopt.shade.drsFps", PRESET.fps));
	public static final boolean STABLE = switch (System.getProperty("mcopt.shade.taaMode", "").toLowerCase(Locale.ROOT)) {
		case "stable" -> true;
		case "responsive" -> false;
		default -> PRESET.stable;
	};
	/** Negative: by scale (sharpen(scale)). */
	private static final float SHARPEN = floatProp("mcopt.shade.sharpen", -1f);
	public static final boolean MIP_BIAS = Boolean.parseBoolean(System.getProperty("mcopt.shade.mipBias", "true"));
	/** Lossy framebuffer compression for the colour history (Apple8+): less bandwidth, tiny error. Off by default (TAAU.md). */
	public static final boolean LOSSY = Boolean.getBoolean("mcopt.shade.taaLossy");
	public static final int DEBUG = Integer.getInteger("mcopt.shade.taaDebug", 0);
	public static final boolean DRS_LOG = Boolean.getBoolean("mcopt.shade.drsLog");

	private TaaConfig() {
	}

	private static float floatProp(String key, float fallback) {
		String v = System.getProperty(key);
		if (v == null || v.isBlank()) return fallback;
		try {
			return Float.parseFloat(v.trim());
		} catch (NumberFormatException e) {
			System.out.println("[mcopt] shade: bad " + key + "=" + v + ", using " + fallback);
			return fallback;
		}
	}

	static float clamp(float v, float lo, float hi) {
		return Math.max(lo, Math.min(hi, v));
	}

	/**
	 * Sharpening strength at a scale: the bible's 0.25 at native rising to 0.4 at 0.67x, unless mcopt.shade.sharpen sets it.
	 * (1.1) mcopt.shade.sharpen read live (SHARPEN at startup; negative = by scale).
	 */
	public static float sharpen(float scale) {
		float sharpen = Live.f("mcopt.shade.sharpen", SHARPEN);
		if (sharpen >= 0f) return Math.min(sharpen, 1f);
		return 0.25f + 0.15f * clamp((1f - scale) / 0.33f, 0f, 1f);
	}

	/** (1.1) live: mcopt.shade.taaMode this frame, stable or responsive (STABLE at startup: the preset's when unset). */
	public static boolean stable() {
		return switch (Live.s("mcopt.shade.taaMode", "")) {
			case "stable" -> true;
			case "responsive" -> false;
			default -> PRESET.stable;
		};
	}

	/**
	 * (1.1) live: dynamic resolution this frame (mcopt.shade.drs; DRS at startup). Never with a fixed range (scaleMin =
	 * scaleMax), as at startup.
	 */
	public static boolean drs() {
		return SCALE_MIN < SCALE_MAX && Live.b("mcopt.shade.drs", true);
	}

	/** (1.1) live: the dynamic resolution's target frame rate (mcopt.shade.drsFps, at least 20; DRS_FPS at startup: the preset's). */
	public static int drsFps() {
		return Math.max(20, Live.i("mcopt.shade.drsFps", DRS_FPS));
	}

	/** Minimum weight of the current frame (Responsive 0.12, Stable 0.08). (1.1) taaMode live. */
	public static float alphaMin() {
		return stable() ? 0.08f : 0.12f;
	}

	/** Floor of the current frame's weight on moving pixels (full from 0.5 px/frame; Responsive 0.25, Stable 0.18): keeps texture detail in motion. */
	public static float motionAlpha() {
		return stable() ? 0.18f : 0.25f;
	}

	/**
	 * (1.2.7 candidate 7, Gael 2026-11-06: shimmering water reflections and sunlit leaves) taa.metal's anti-flicker knobs, live:
	 * antiFlicker = lean on the history where it sits at the box's edge (Karis 2014), 0..1; floorCentre = the motion floor only where
	 * the history is resampled off its pixels' centres (Photon), 0..1; boostFrom = where the clip boost starts, in box units (1 = as
	 * before); flickerHold = keep an unclipped history well inside a wide box (Photon), 0..1, and its sensitivity.
	 */
	public static float antiFlicker() {
		return Live.f("mcopt.shade.taa.antiFlicker", 0f, 0f, 1f);
	}

	// (candidate 7 defaults, 2026-11-06, repeatable pond runs cf4: fixed-step clock, frozen scene) floorCentre 1 + boostFrom 3: the
	// reflections' repeated flicker -4..-6 % walking and jumping, the same sharpness, no cost. antiFlicker and flickerHold stay off
	// (round tpa: worse running / 8 % blurrier).
	public static float floorCentre() {
		return Live.f("mcopt.shade.taa.floorCentre", 1f, 0f, 1f);
	}

	public static float boostFrom() {
		return Live.f("mcopt.shade.taa.boostFrom", 3f, 1f, 8f);
	}

	public static float flickerHold() {
		return Live.f("mcopt.shade.taa.flickerHold", 0f, 0f, 1f);
	}

	public static float flickerHoldSensitivity() {
		return Live.f("mcopt.shade.taa.flickerHoldSens", 5f, 0.5f, 50f);
	}

	/** Variance clip box size in standard deviations (Responsive 1.0, Stable 1.25), +0.5 while the camera is still. */
	public static float clipGamma(boolean still) {
		return (stable() ? 1.25f : 1.0f) + (still ? 0.5f : 0f);
	}

	public static String describe() {
		return String.format(Locale.ROOT, "preset %s, scale %.2f (%.2f-%.2f%s), %s, sharpen %.2f%s", PRESET.name().toLowerCase(Locale.ROOT), SCALE, SCALE_MIN, SCALE_MAX,
			DRS ? ", dynamic to hold " + DRS_FPS + " fps" : ", fixed", STABLE ? "stable" : "responsive", sharpen(SCALE), MIP_BIAS ? "" : ", no mip bias");
	}

	/** taa.metal as ShadeTaa compiles it ((FT2.8) -Dmcopt.shade.taaCompressTaps=true: the history's Catmull-Rom on compressed taps). */
	public static String source() {
		return (Boolean.getBoolean("mcopt.shade.taaCompressTaps") ? "" : "#define TAA_LINEAR_HISTORY\n") + mcopt.metal.shade.ShadeMsl.resource("taa.metal");
	}

	/**
	 * (parallel compile, mcopt.metal.shade.ShadeCompile) ShadeTaa's library and resolve pipelines, made off the render thread
	 * with the flags ShadeTaa starts with and freed again: its own setup then finds them in Metal's shader cache.
	 */
	public static void warmUp(long ctx) {
		java.nio.ByteBuffer source = org.lwjgl.system.MemoryUtil.memUTF8(source());
		try (org.lwjgl.system.MemoryStack stack = org.lwjgl.system.MemoryStack.stackPush()) {
			long err = stack.ncalloc(1, 4096, 1);
			long taa = TaaNative.create(ctx, org.lwjgl.system.MemoryUtil.memAddress(source), (mcopt.metal.shade.ShadeConfig.HDR ? 1 : 0) | (LOSSY ? 2 : 0) | (DEBUG != 0 ? 4 : 0),
				err, 4096);
			if (taa == 0) throw new IllegalStateException(org.lwjgl.system.MemoryUtil.memUTF8(err));
			TaaNative.free(taa);
		} finally {
			org.lwjgl.system.MemoryUtil.memFree(source);
		}
	}
}
