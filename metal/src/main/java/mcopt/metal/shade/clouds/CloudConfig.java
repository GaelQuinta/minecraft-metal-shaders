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
package mcopt.metal.shade.clouds;

import mcopt.metal.shade.Live;
import mcopt.metal.shade.Shade;

/**
 * Volumetric cloud settings (M3, bible E05), read once at startup (system properties or config/mcopt.properties). Free of
 * game types. Everything needs mcopt.shade=true and the HDR pipeline (mcopt.shade.hdr, default on).
 * (1.1) The look and quality keys below are read live (the accessors after the statics: the settings screen changes them
 * every frame); their static is the default, so with no property set the clouds are exactly as before. The module switch
 * (mcopt.shade.clouds) stays a startup one.
 *
 * <ul>
 * <li>{@code mcopt.shade.clouds} (true): volumetric cumulus + cirrus replace vanilla's clouds (false: vanilla's, lit by
 * M2's clouds.fs.metal, exactly as before).</li>
 * <li>{@code mcopt.shade.clouds.scale}: history resolution relative to the output (P 0.4, B 0.45, Q 0.5, U 0.67).</li>
 * <li>{@code mcopt.shade.clouds.checker} (P 3, B 3, Q 2, U 2): march one pixel of each N x N block per frame, the rest
 * from the reprojected history (1 = every pixel every frame).</li>
 * <li>{@code mcopt.shade.clouds.steps} / {@code .lightSteps}: primary and light samples (P 20/3, B 20/3, Q 40/4, U 56/5).</li>
 * <li>{@code mcopt.shade.clouds.shadows} (true) / {@code .shadowStrength} (0.8): cloud shadows on terrain, water and
 * god rays.</li>
 * <li>{@code mcopt.shade.clouds.dome} (true): the reflection dome (clouds in water reflections of directions off
 * screen), {@code .domeSteps} (P 8, B 10, Q 12, U 16).</li>
 * <li>{@code mcopt.shade.clouds.cirrus} (true): the high cirrus layer.</li>
 * <li>{@code mcopt.shade.clouds.base} / {@code .thickness}: the cumulus layer (default: vanilla's cloud height + 8, 150
 * blocks thick).</li>
 * <li>{@code mcopt.shade.clouds.coverage} / {@code .type} (-1 = the daily weather): force coverage 0..1 or the cloud
 * type (0 flat .. 1 towering).</li>
 * <li>{@code mcopt.shade.clouds.wind} (1): wind speed multiplier; {@code .seed} (0): changes the daily weather.</li>
 * <li>{@code mcopt.shade.clouds.density} (1), {@code .detail} (1): extinction and fine-detail multipliers.</li>
 * <li>(1.1, live) {@code mcopt.shade.user.cloudCoverage} (0: -0.5..0.5 on the day's coverage), {@code .cloudType} (-1 = the
 * day's), {@code .cloudBrightness} (1), {@code .cloudOpacity} (1), {@code .cirrusAmount} (1): the player's cloud settings.</li>
 * <li>{@code mcopt.shade.clouds.gpuTimer} (false) / {@code .log} (false): a log line every 2 s with the passes' GPU ms and
 * the weather.</li>
 * </ul>
 */
public final class CloudConfig {
	private static final int TIER = Shade.TIER;
	/**
	 * M3.3 master switch (mcopt.shade.clouds.m33, default true): false = every M3.3 change of the clouds off at once, exactly
	 * M3.2 (mode bits 0, the M3.2 checkerboard defaults); each change also has its own flag (CLOUDS.md M3.3).
	 */
	public static final boolean M33 = flag("mcopt.shade.clouds.m33", true);
	public static final boolean ENABLED = Shade.ENABLED && flag("mcopt.shade.clouds", true) && flag("mcopt.shade.hdr", true)
		&& !Boolean.parseBoolean(System.getProperty("mcopt.lod", "false"));
	public static final float SCALE = clamp(floatProperty("mcopt.shade.clouds.scale", new float[] {0.4f, 0.45f, 0.5f, 0.67f}[TIER]), 0.2f, 1f);
	/**
	 * Checkerboard N: one pixel of each N x N block is marched per frame (P 3, B 3, Q 2, U 2; 1 = every pixel; M3.3: up to 4,
	 * a 16-frame cycle with 44 % fewer march rays than 3).
	 */
	public static final int CHECKER = clampInt(Integer.getInteger("mcopt.shade.clouds.checker", new int[] {3, 3, 2, 2}[TIER]), 1, 4);
	/** M3.3: the checkerboard dev bit {@link #DEV_CHECKER_ALT} switches to (mcopt.shade.clouds.checkerAlt, 4): in-session pricing. */
	public static final int CHECKER_ALT = clampInt(Integer.getInteger("mcopt.shade.clouds.checkerAlt", 4), 1, 4);
	public static final int STEPS = clampInt(Integer.getInteger("mcopt.shade.clouds.steps", new int[] {20, 20, 40, 56}[TIER]), 6, 128);
	public static final int LIGHT_STEPS = clampInt(Integer.getInteger("mcopt.shade.clouds.lightSteps", new int[] {3, 3, 4, 5}[TIER]), 1, 8);
	public static final boolean SHADOWS = flag("mcopt.shade.clouds.shadows", true);
	public static final float SHADOW_STRENGTH = clamp(floatProperty("mcopt.shade.clouds.shadowStrength", 0.8f), 0f, 1f);
	public static final float SHADOW_EXTENT = clamp(floatProperty("mcopt.shade.clouds.shadowExtent", 1024f), 256f, 4096f);
	public static final boolean DOME = flag("mcopt.shade.clouds.dome", true);
	public static final int DOME_STEPS = clampInt(Integer.getInteger("mcopt.shade.clouds.domeSteps", new int[] {8, 10, 12, 16}[TIER]), 4, 64);
	public static final int DOME_W = 128, DOME_H = 64;
	/** Frames between dome updates (4 or 8; mcopt.shade.clouds.domeEvery): M3.1 8 at performance/balanced, else 4; 4 (M3) without lean. */
	public static final int DOME_EVERY = Integer.getInteger("mcopt.shade.clouds.domeEvery", TIER <= 1 ? 8 : 4) >= 8 ? 8 : 4;
	public static final boolean CIRRUS = flag("mcopt.shade.clouds.cirrus", true);
	/**
	 * Cloud style: volumetric (default) or blocky (vanilla-style 12-block cells, ray-traced and lit: the Storybook look's
	 * default, mcopt.shade.look=storybook).
	 */
	public static final boolean BLOCKY = System.getProperty("mcopt.shade.clouds.style", "storybook".equalsIgnoreCase(System.getProperty("mcopt.shade.look", "").trim())
		? "blocky" : "volumetric").trim().equalsIgnoreCase("blocky");
	/** Blocky style: slab thickness (blocks; vanilla's fancy clouds are 4). */
	public static final float BLOCK_THICKNESS = clamp(floatProperty("mcopt.shade.clouds.blockThickness", 8f), 2f, 64f);
	/** (1.1) Blocky style with the game's cloud texture: slab thickness (vanilla's fancy clouds: 4; mcopt.shade.clouds.blockThickness). */
	public static final float VANILLA_THICKNESS = clamp(floatProperty("mcopt.shade.clouds.blockThickness", 4f), 2f, 64f);
	/** Absolute y of the cumulus base; NaN = vanilla's cloud height + 8. */
	public static final float BASE = floatProperty("mcopt.shade.clouds.base", Float.NaN);
	public static final float THICKNESS = clamp(floatProperty("mcopt.shade.clouds.thickness", 150f), 20f, 600f);
	public static final float CIRRUS_ABOVE = clamp(floatProperty("mcopt.shade.clouds.cirrusAbove", 900f), 100f, 4000f);
	public static final float COVERAGE = floatProperty("mcopt.shade.clouds.coverage", -1f);
	public static final float TYPE = floatProperty("mcopt.shade.clouds.type", -1f);
	public static final float WIND = Math.max(0f, floatProperty("mcopt.shade.clouds.wind", 1f));
	/**
	 * Speed of the 3D (billow) noise relative to the cumulus field (0.82: the billows slide a little through the shapes, "boil";
	 * 1 = the clouds drift as rigid shapes, which the history reprojection follows exactly). Tried 1 as the default on
	 * 2026-10-07 against the still-camera comb on soft edges (gone with wind 0): the comb stayed the same (runs cf7/cf2), so
	 * the boil is kept; the comb comes from the resolve's reprojection of the wind (see CLOUDS.md, open items).
	 */
	public static final float NOISE_DRIFT = clamp(floatProperty("mcopt.shade.clouds.noiseDrift", 0.82f), 0f, 2f);
	public static final long SEED = Long.getLong("mcopt.shade.clouds.seed", 0L);
	public static final float DENSITY = clamp(floatProperty("mcopt.shade.clouds.density", 1f), 0.1f, 10f);
	public static final float DETAIL = clamp(floatProperty("mcopt.shade.clouds.detail", 0.6f), 0f, 3f);
	/** Blocks of world per 1 km of the sky model's air for the light the layer gets (sunset light lingers on the clouds). */
	public static final float ALTITUDE_SCALE = clamp(floatProperty("mcopt.shade.clouds.altitudeScale", 4f), 0f, 50f);
	/** Most visits a history pixel averages (its march samples are jittered): fewer with a larger checkerboard (slower visits). */
	public static final int MAX_AGE = maxAge(CHECKER);

	/** The visit cap for checkerboard n (mcopt.shade.clouds.maxAge overrides): 12 (n <= 2), 10 (3), 8 (4: ~ the same seconds as 3's 10). */
	public static int maxAge(int n) {
		return clampInt(Integer.getInteger("mcopt.shade.clouds.maxAge", n >= 4 ? 8 : n >= 3 ? 10 : 12), 1, 63);
	}

	// ---- (1.1) live settings: read every frame through Live (parsed only when their text changes). Each default is the static
	// above (the startup value, the preset's where it has one) with the same clamp; the ones whose change needs a reset get it in
	// ShadeClouds.update (it remembers the last value) ----

	/** (1.1) live: mcopt.shade.clouds.density, the extinction multiplier ({@link #DENSITY}, 0.1..10). */
	public static float density() {
		return Live.f("mcopt.shade.clouds.density", DENSITY, 0.1f, 10f);
	}

	/** (1.1) live: mcopt.shade.clouds.detail, the fine-detail strength ({@link #DETAIL}, 0..3). */
	public static float detail() {
		return Live.f("mcopt.shade.clouds.detail", DETAIL, 0f, 3f);
	}

	/** (1.1) live: mcopt.shade.clouds.base, the cumulus base (absolute y; {@link #BASE}, NaN = vanilla's cloud height + 8). A change drops the history. */
	public static float base() {
		return Live.f("mcopt.shade.clouds.base", BASE);
	}

	/** (1.1) live: mcopt.shade.clouds.thickness, the cumulus layer ({@link #THICKNESS}, 20..600 blocks). A change drops the history. */
	public static float thickness() {
		return Live.f("mcopt.shade.clouds.thickness", THICKNESS, 20f, 600f);
	}

	/**
	 * (1.1) live: mcopt.shade.clouds.blockThickness, the blocky style's slab (2..64 blocks): {@link #VANILLA_THICKNESS} (4,
	 * vanilla's fancy clouds) with the game's cloud texture, else {@link #BLOCK_THICKNESS} (8). A change drops the history.
	 */
	public static float blockThickness(boolean vanillaCells) {
		return Live.f("mcopt.shade.clouds.blockThickness", vanillaCells ? VANILLA_THICKNESS : BLOCK_THICKNESS, 2f, 64f);
	}

	/** (1.1) live: mcopt.shade.clouds.wind, the wind speed multiplier ({@link #WIND}, 0..4). */
	public static float wind() {
		return Live.f("mcopt.shade.clouds.wind", WIND, 0f, 4f);
	}

	/** (1.1) live: mcopt.shade.clouds.cirrus, the high cirrus layer ({@link #CIRRUS}). */
	public static boolean cirrus() {
		return Live.b("mcopt.shade.clouds.cirrus", CIRRUS);
	}

	/** (1.1) live: mcopt.shade.clouds.cirrusAbove, the cirrus' height over the cumulus base ({@link #CIRRUS_ABOVE}, 100..4000 blocks). */
	public static float cirrusAbove() {
		return Live.f("mcopt.shade.clouds.cirrusAbove", CIRRUS_ABOVE, 100f, 4000f);
	}

	/**
	 * (1.1) live: mcopt.shade.clouds.shadows ({@link #SHADOWS}): off = no shadow map pass and strength 0 for the consumers
	 * (terrain, water, god rays read 1); back on, the map is rendered that frame (ShadeClouds).
	 */
	public static boolean shadows() {
		return Live.b("mcopt.shade.clouds.shadows", SHADOWS);
	}

	/** (1.1) live: mcopt.shade.clouds.shadowStrength ({@link #SHADOW_STRENGTH}, 0..1). */
	public static float shadowStrength() {
		return Live.f("mcopt.shade.clouds.shadowStrength", SHADOW_STRENGTH, 0f, 1f);
	}

	/** (1.1) live: mcopt.shade.clouds.dome, the reflection dome ({@link #DOME}); turned on, the history drops once (a fresh dome). */
	public static boolean dome() {
		return Live.b("mcopt.shade.clouds.dome", DOME);
	}

	/** (1.1) live: mcopt.shade.clouds.steps, the march's primary samples ({@link #STEPS}: the preset's, 6..128). */
	public static int steps() {
		return clampInt(Live.i("mcopt.shade.clouds.steps", STEPS), 6, 128);
	}

	/** (1.1) live: mcopt.shade.clouds.lightSteps, the light march's samples ({@link #LIGHT_STEPS}: the preset's, 1..8). */
	public static int lightSteps() {
		return clampInt(Live.i("mcopt.shade.clouds.lightSteps", LIGHT_STEPS), 1, 8);
	}

	/** (1.1) live: mcopt.shade.clouds.domeSteps, the dome march's samples ({@link #DOME_STEPS}: the preset's, 4..64). */
	public static int domeSteps() {
		return clampInt(Live.i("mcopt.shade.clouds.domeSteps", DOME_STEPS), 4, 64);
	}

	/**
	 * (1.1) live: mcopt.shade.clouds.scale, the history's resolution relative to the output ({@link #SCALE}: the preset's,
	 * 0.2..1). A change resizes the targets (CloudNative.size), which drops the history, as dev bit 4096 already did.
	 */
	public static float scale() {
		return Live.f("mcopt.shade.clouds.scale", SCALE, 0.2f, 1f);
	}

	/** (1.1) live: mcopt.shade.clouds.checker, the checkerboard N ({@link #CHECKER}: the preset's, 1..4). A change resizes the march and drops the history. */
	public static int checker() {
		return clampInt(Live.i("mcopt.shade.clouds.checker", CHECKER), 1, 4);
	}

	/** (1.1) live: mcopt.shade.clouds.altitudeScale, world blocks per km of the sky model's air for the layer's light ({@link #ALTITUDE_SCALE}, 0..50). */
	public static float altitudeScale() {
		return Live.f("mcopt.shade.clouds.altitudeScale", ALTITUDE_SCALE, 0f, 50f);
	}

	/**
	 * (1.1) live, new: mcopt.shade.user.cloudCoverage (0 = the day's weather, -0.5..0.5), added to the day's coverage before
	 * rain closes the sky in (CloudWeather), so a storm still overcasts a clear setting.
	 */
	public static float userCoverage() {
		return Live.f("mcopt.shade.user.cloudCoverage", 0f, -0.5f, 0.5f);
	}

	/**
	 * (1.1) live, new: mcopt.shade.user.cloudType (-1 = the day's weather, else 0 flat .. 1 towering): the day's type forced;
	 * rain and thunder still raise it (CloudWeather), unlike mcopt.shade.clouds.type (startup, over the weather too).
	 */
	public static float userType() {
		return Live.f("mcopt.shade.user.cloudType", -1f, -1f, 1f);
	}

	/** (1.1) live, new: mcopt.shade.user.cloudBrightness (1, 0.25..2): the light the layer gets (sun or moon, the sky above, the ground below). */
	public static float userBrightness() {
		return Live.f("mcopt.shade.user.cloudBrightness", 1f, 0.25f, 2f);
	}

	/** (1.1) live, new: mcopt.shade.user.cloudOpacity (1, 0..1): the clouds' overall opacity (CloudParams.opacity), which also scales their shadows. */
	public static float userOpacity() {
		return Live.f("mcopt.shade.user.cloudOpacity", 1f, 0f, 1f);
	}

	/** (1.1) live, new: mcopt.shade.user.cirrusAmount (1, 0..2): a multiplier on the cirrus layer's coverage. */
	public static float userCirrus() {
		return Live.f("mcopt.shade.user.cirrusAmount", 1f, 0f, 2f);
	}
	public static final int DEBUG = Integer.getInteger("mcopt.shade.clouds.debug", 0);
	/**
	 * M3.1 performance pass (CLOUDS.md "M3.1 performance"): the cheaper ways of the passes and consumers (fog lookup only where
	 * it shows, VL cloud shadow every other step, the resolve's distance taps by gather, the march's sky lookup only where a
	 * cloud is). false = M3 exactly (the dev bits OLD_* all set).
	 */
	public static final boolean LEAN = flag("mcopt.shade.clouds.lean", true);
	/** Dev bits (mcopt.shade.clouds.dev, read every frame; 0 normally): price parts of the clouds inside one session. */
	public static final int DEV_NO_SCREEN = 1, DEV_NO_MAPS = 2, DEV_NO_SKY = 4, DEV_NO_FOG = 8, DEV_NO_SHADOW_USE = 16, DEV_NO_VL = 32,
		DEV_OLD_FOG = 256, DEV_OLD_VL = 512, DEV_OLD_RESOLVE = 1024, DEV_OLD_MARCH = 2048, DEV_SCALE_ALT = 4096, DEV_OLD_MIP = 8192,
		DEV_OLD_DOME = 16384, DEV_OLD_STABLE = 32768, DEV_OLD_LIGHT = 65536, DEV_OLD_BATCH = 131072, DEV_OLD_PAIR = 262144,
		DEV_CHECKER_ALT = 524288, DEV_OLD_SHADOW = 1048576,
		// (FT2.10) shadeFogAir2's clouds behind distant terrain from the border fog's start (FT2.9), not only in its last 30 %: set in
		// ShadeLook.clouds1.z while mcopt.shade.clouds.lateFog is false (CloudParams.packLook)
		DEV_EARLY_FOG = 2097152,
		// (FT2.12) diagnosis: shadeFogAir2 without its aerial blend toward the sky behind
		DEV_NO_AP = 4194304,
		// (FT2.12) FT2.11's aerial blend toward the sky behind with its glow around the sun: set while mcopt.shade.aerialSun is true
		DEV_AP_SUN = 8388608;
	/**
	 * (FT2.12) mcopt.shade.aerialSun (false; read every frame): true = FT2.11, the land within the render distance blends toward the
	 * sky behind it with that sky's glow around the sun, unshadowed (a sun set behind a mountain glowed orange through it).
	 */
	public static boolean aerialSun() {
		return "true".equalsIgnoreCase(System.getProperty("mcopt.shade.aerialSun", "false").trim());
	}
	/** (FT2.10) mcopt.shade.clouds.lateFog (true; read every frame): the clouds show through the border fog only once the terrain is mostly gone. */
	public static boolean lateFog() {
		return flag("mcopt.shade.clouds.lateFog", true);
	}
	/** All M3.3 dev bits (the M3.2 way of every M3.3 change). */
	public static final int DEV_OLD_M33 = DEV_OLD_STABLE | DEV_OLD_LIGHT | DEV_OLD_BATCH | DEV_OLD_PAIR;
	public static final int DEV_OLD_ALL = DEV_OLD_FOG | DEV_OLD_VL | DEV_OLD_RESOLVE | DEV_OLD_MARCH | DEV_OLD_MIP | DEV_OLD_DOME;
	/** The history scale dev bit 4096 switches to (pricing another scale inside one session). */
	public static final float SCALE_ALT = clamp(floatProperty("mcopt.shade.clouds.scaleAlt", 0.4f), 0.2f, 1f);

	/** This frame's dev bits: mcopt.shade.clouds.dev (read every frame: the bench's price phases set it), plus OLD_* without LEAN. */
	public static int devBits() {
		return Integer.getInteger("mcopt.shade.clouds.dev", 0) | (LEAN ? 0 : DEV_OLD_ALL);
	}
	/**
	 * M3.3 mode bits (CloudParams.shadowDir.w, clouds.metal CLOUD_MODE_*; each off = M3.2's way). {@link #MODE_STABLE}
	 * (mcopt.shade.clouds.stable, default true): the march's start offsets from a per-pixel hash and the resolve that carries
	 * the clouds' distance in the history (no comb / hatching on soft edges in the wind or while turning; CLOUDS.md M3.3).
	 */
	public static final int MODE_STABLE = 1;
	/**
	 * {@link #MODE_LIGHT2} (mcopt.shade.clouds.halfLight, default false): the march's light march (and its sky-light sample)
	 * on every other in-cloud sample, the samples between lit by the mean of their neighbours'. Off by default: no gain
	 * measured in game (run m33c-2: march timer 0.394 vs 0.395 ms) for a small change of look.
	 */
	public static final int MODE_LIGHT2 = 2;
	/**
	 * {@link #MODE_BATCH} (mcopt.shade.clouds.batch, default true): a march sample's texture fetches issued together instead of
	 * one after the other (the march is latency-bound; same values: M3.3 price).
	 */
	public static final int MODE_BATCH = 4;
	/** {@link #MODE_PAIR} (mcopt.shade.clouds.pair, default true): the march's empty-air tests two at a time (same tests). */
	public static final int MODE_PAIR = 8;
	/**
	 * FT1.2 {@link #MODE_EDGE} (mcopt.shade.clouds.edgeGate, default true; Gael: pixelated cloud edges at sunset): the stable
	 * resolve keeps its history inside this frame's march colours only where the reprojection depends on the distance (the
	 * nearest and farthest march distance around land more than half a history pixel apart: camera motion, wind parallax),
	 * not on every soft edge against the sky. That clamp's box comes from the 1/3-resolution march, one per 3x3 block: it cut
	 * the edges into 3x3-block steps and left bright / dark specks (offline: edge error vs a 1x1 reference -15 %, same price).
	 */
	public static final int MODE_EDGE = 16;
	/**
	 * FT2.6 {@link #MODE_DRIFT} (mcopt.shade.clouds.driftClamp, default true; Gael's FT2.5 screenshots in a cloud: a comet tail
	 * from the sun): where the reprojection moves a history pixel against a pure turn (the camera's travel and the wind at a
	 * near cloud's distance: inside a cloud, flying next to one) the stable resolve keeps it inside this frame's march colours
	 * and caps its age low; far clouds don't drift, so they keep their history as before.
	 */
	public static final int MODE_DRIFT = 32;
	/**
	 * FT2.8 {@link #MODE_ZOOM} (mcopt.shade.clouds.zoomAge, default true; audit idx 12): zooming in (spyglass, FOV effects) keeps a
	 * magnified history at full age, so the clouds stayed blurry and blocky for 1-2 s; the resolve lowers its age by the magnification.
	 */
	public static final int MODE_ZOOM = 64;

	/**
	 * This frame's mode bits (the flags are read every frame: the bench can switch them inside one session; dev bits 32768 /
	 * 65536 / 131072 = M3.2's march jitter and resolve / light march on every sample / fetch chains, for pricing with
	 * mcbench's cloudsDev phases; 262144 = the empty-air tests one at a time).
	 */
	public static int modeBits() {
		if (!M33) return 0;
		int dev = Integer.getInteger("mcopt.shade.clouds.dev", 0);
		return (flag("mcopt.shade.clouds.stable", true) && (dev & DEV_OLD_STABLE) == 0 ? MODE_STABLE : 0)
			| (flag("mcopt.shade.clouds.halfLight", false) && (dev & DEV_OLD_LIGHT) == 0 ? MODE_LIGHT2 : 0)
			| (flag("mcopt.shade.clouds.batch", true) && (dev & DEV_OLD_BATCH) == 0 ? MODE_BATCH : 0)
			| (flag("mcopt.shade.clouds.pair", true) && (dev & DEV_OLD_PAIR) == 0 ? MODE_PAIR : 0)
			| (flag("mcopt.shade.clouds.edgeGate", true) ? MODE_EDGE : 0)
			| (flag("mcopt.shade.clouds.driftClamp", true) ? MODE_DRIFT : 0)
			| (flag("mcopt.shade.clouds.zoomAge", true) ? MODE_ZOOM : 0);
	}
	/**
	 * M3.4 (Gael: cloud edges look pixelated and flicker at sunset): the sky, fog and VL read the clouds' history (0.45 of the
	 * screen at balanced, magnified ~2.2x) with a cubic B-spline (4 bilinear taps) instead of one bilinear tap: no texel
	 * blocks on soft edges, and the march's per-pixel grain smoothed. mcopt.shade.clouds.smooth (read every frame, default false = M3.3).
	 */
	public static boolean smooth() {
		return flag("mcopt.shade.clouds.smooth", SMOOTH_DEFAULT);
	}

	static final boolean SMOOTH_DEFAULT = false; // (run cl1: +0.21 ms with every cloud read smoothed, and the edge specks stay: off)
	public static final boolean GPU_TIMER = Boolean.getBoolean("mcopt.shade.clouds.gpuTimer");
	/**
	 * (v12-opt) The march and resolves specialized for the dev bits, mode bits and style the settings have at startup (clouds.metal
	 * CLOUD_FC_*: the code of the modes that are off left out; the same arithmetic), bound on the frames that carry exactly those
	 * values. mcopt.shade.cloudLean: false at startup = never built; false live = the generic passes.
	 */
	public static final boolean LEAN_PASSES = !"false".equals(System.getProperty("mcopt.shade.cloudLean"));
	public static final boolean LOG = GPU_TIMER || Boolean.getBoolean("mcopt.shade.clouds.log");

	private CloudConfig() {
	}

	/** The MSL of the passes: ShadeMsl.prelude() + clouds.metal (mcclouds.m; validate.sh). */
	public static String source() {
		return mcopt.metal.shade.ShadeMsl.prelude() + "\n" + mcopt.metal.shade.ShadeMsl.resource("clouds.metal");
	}

	static String describe() {
		return (BLOCKY ? "blocky at start, " : "") + "preset " + Shade.PRESET + ", scale " + SCALE + " (" + CHECKER + "x" + CHECKER + " checkerboard)" + ", " + STEPS + "/" + LIGHT_STEPS + " steps"
			+ (SHADOWS ? ", shadows " + SHADOW_STRENGTH : ", no shadows") + (DOME ? ", dome " + DOME_STEPS + " steps" : "") + (CIRRUS ? ", cirrus" : "")
			+ (LEAN ? "" : ", not lean (M3 passes)");
	}

	static boolean flag(String key, boolean def) {
		String v = System.getProperty(key);
		return v == null ? def : Boolean.parseBoolean(v.trim());
	}

	static float floatProperty(String key, float def) {
		String v = System.getProperty(key);
		if (v == null) return def;
		try {
			return Float.parseFloat(v.trim());
		} catch (NumberFormatException e) {
			return def;
		}
	}

	private static float clamp(float v, float lo, float hi) {
		return Math.max(lo, Math.min(hi, v));
	}

	private static int clampInt(int v, int lo, int hi) {
		return Math.max(lo, Math.min(hi, v));
	}

	/**
	 * (parallel compile, mcopt.metal.shade.ShadeCompile) ShadeClouds' library and pipelines, made off the render thread and
	 * released again (mc_clouds_warm: mc_clouds_new's pipelines without its textures and noise bakes): its own setup then
	 * finds them in Metal's shader cache.
	 */
	public static void warmUp(long ctx) {
		long lib = mcopt.metal.shade.ShadeCompile.library(ctx, source());
		try {
			int failed = CloudNative.warm(ctx, lib);
			if (failed != 0) throw new IllegalStateException(failed + " cloud pipelines failed");
			// (v12-opt) and the specialized march and resolves for the startup settings (ShadeClouds.init builds the same)
			if (LEAN_PASSES) CloudNative.warmLean(ctx, lib, devBits(), modeBits(), ShadeClouds.leanStyle());
		} finally {
			mcopt.metal.MetalBridge.release(lib);
		}
	}
}
