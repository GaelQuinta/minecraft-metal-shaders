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
package mcopt.metal.shade.weather;

import java.nio.ByteBuffer;
import java.util.Locale;
import mcopt.metal.shade.Live;
import mcopt.metal.shade.Shade;
import mcopt.metal.shade.ShadeLook;
import mcopt.metal.shade.ShadeMsl;

/**
 * M3 weather (shader bible E13, and E08's coloured shadows): wet surfaces, puddles with reflections, raindrop ripples on
 * puddles and water, slanted lit rain, snow cover, lightning light, and light tinted by stained glass and water. See
 * WEATHER.md (branch m3-weather) for the integration.
 * <ul>
 * <li>CPU state (this class, no game types): wetness rises while it rains where rain falls (the camera's biome), puddles
 * follow it with a lag and dry slowly, snow cover builds where it snows; a wind direction and slant; lightning flashes.
 * {@link WeatherFrame#update} (game-typed) feeds it once per frame; {@link #pack} writes ShadeLook.wet / wind / flash.</li>
 * <li>Shaders: {@link #prelude} (the SHADE_* defines + weather_surface.metal) goes in front of the Sodium terrain stages
 * (ShadeMsl.terrain); sodium_terrain.fs.metal applies the wet layer, the flash and the shadow tint, water.metal the ripples;
 * weather.metal re-lights rain and slants it (ShadeMsl.weather / weatherVertex); lightning bolts glow in HDR
 * (ShadeMsl.lightning).</li>
 * <li>Coloured shadows: the shadow pass draws the translucent terrain (water, stained glass, ice) of the near cascade into a
 * tint map (mcshadow.m mc_shadow_tint_*), published as ShadeResources entry {@link #RES_SHADOW_TINT}.</li>
 * <li>Puddle reflections march last frame's TAA history with its depth (ShadeResources entry {@link #RES_PREV_DEPTH},
 * ShadeLook.ssr.y = 1 when valid; ShadePost.beginWorld publishes it).</li>
 * </ul>
 *
 * <p>Flags (system properties or config/mcopt.properties; read once at startup; all need mcopt.shade=true):
 * <ul>
 * <li>{@code mcopt.shade.weather} (true): the module (false: M2.1's rain, dry surfaces; the shaders are byte-identical to
 * M2.1's except for the unused tint bindings).</li>
 * <li>{@code mcopt.shade.puddles} (true), {@code mcopt.shade.puddleSsr} (preset: false for performance, true otherwise),
 * {@code mcopt.shade.puddleQuad} (true except ultra: a 2x2 quad shares one ray), {@code mcopt.shade.puddleSteps} (quad: 12 / 12 / 20 / 24;
 * per pixel: 8 / 10 / 14 / 20), {@code mcopt.shade.puddleDist} (64 blocks).</li>
 * <li>{@code mcopt.shade.ripples} (true): raindrop rings on puddles and on water under open sky; {@code mcopt.shade.rippleLayers}
 * (1 on performance/balanced, 2 on quality/ultra): drop grids.</li>
 * <li>{@code mcopt.shade.weatherLite} (true on performance/balanced): budget gates that keep the look (no sun highlight on
 * wet surfaces in heavy rain, raindrop rings only where the puddle mirror shows them, rain streaks lit by the sky's mean
 * light, coloured shadows and the films' sky lookup off in heavy rain, puddle reflections marched from F x P 0.05).</li>
 * <li>{@code mcopt.shade.rainBudget} (M3.3; empty = M3.2): comma list of gate, ripples, steps: the rain budget options
 * ({@link #RAIN_BUDGET}).</li>
 * <li>{@code mcopt.shade.snowCover} (true): snow builds up on top faces while it snows at the camera.</li>
 * <li>{@code mcopt.shade.snowLine} (2026-10-11, true): snow cover only above the camera biome's snow line, rain's wetness and
 * puddles only below it ({@link #SNOW_LINE}); false = M3's look (the whole terrain takes what falls at the camera). (1.1) live
 * (the shaders gate it by a bit of ShadeFrame.wxLine).</li>
 * <li>{@code mcopt.shade.rainSlant} (true): rain leans with the wind (more in thunderstorms). (1.1) live off: the slanted
 * vertex stage is compiled at startup only while it is on there; off then leaves the rain upright (slant 0).</li>
 * <li>{@code mcopt.shade.lightning} (true): bolts light the scene and the sky, and glow (the game's "Hide Lightning Flashes"
 * option turns the flash light off). (1.1) live off: no flash light (the code stays compiled; the bolts still glow).</li>
 * <li>{@code mcopt.shade.colorShadows} (true) and {@code mcopt.shade.colorShadowRes} (1024; 2048 on ultra): coloured light
 * through stained glass, ice and water (near cascade).</li>
 * <li>{@code mcopt.shade.weatherTime} (1): time scale of wetting and drying (the bench uses 10). (1.1) live, 0.1..100.</li>
 * <li>{@code mcopt.shade.wetness} (-1 = from the weather): force wetness and puddles to this value (look development; M3.3:
 * read again every frame).</li>
 * <li>{@code mcopt.shade.wetAll} (M3.3, true): in rain the whole open ground soaks (a water film with a Fresnel sheen and
 * reflections on all solid ground, puddles the deeper water in its low spots); false at startup = M3.2's shaders, and it is
 * read again every frame (false = M3.2's look) for in-session A/B. {@code mcopt.shade.wetRough} (0.2), {@code wetVeg} (0.1),
 * {@code wetSsr} (film reflections' gate, 0 = off), {@code wetDark}, {@code wetVegFilm}, {@code wetTex}, {@code wetRim} likewise
 * ({@link #WET_ALL}).</li>
 * <li>{@code mcopt.shade.snowAmount} (-1 = from the weather): force the snow cover to this value (look development). (1.1)
 * live.</li>
 * <li>(1.1, live) the player's amounts, multipliers on what the weather packs (1 = as released, 0..2; the result is clamped to
 * 0..1): {@code mcopt.shade.user.wetness} (the wet film, wet.x), {@code mcopt.shade.user.puddles} (wet.y),
 * {@code mcopt.shade.user.snow} (the snow cover, wet.z). The weather's own state (soaking, drying) is not changed by them.</li>
 * </ul>
 */
public final class ShadeWeather {
	/** The module's flag on its own (what ShadeMsl assembles the MSL by; validation tools run without mcopt.shade). */
	public static final boolean MODULE = flag("mcopt.shade.weather", true);
	public static final boolean ON = Shade.ENABLED && MODULE;
	public static final boolean PUDDLES = flag("mcopt.shade.puddles", true);
	public static final boolean PUDDLE_SSR = PUDDLES && flag("mcopt.shade.puddleSsr", Shade.TIER >= 1);
	/** The 2x2 quad shares one reflection ray (each lane marches a quarter of it): default except ultra. */
	public static final boolean PUDDLE_QUAD = flag("mcopt.shade.puddleQuad", Shade.TIER < 3);
	/** March steps per ray (quad-shared: split over 4 lanes) + 3 bisection steps. */
	public static final int PUDDLE_STEPS = Math.clamp(Integer.getInteger("mcopt.shade.puddleSteps", PUDDLE_QUAD ? new int[] {12, 12, 20, 24}[Shade.TIER]
		: new int[] {8, 10, 14, 20}[Shade.TIER]), 4, 64);
	public static final float PUDDLE_DIST = Math.clamp(floatFlag("mcopt.shade.puddleDist", 64f), 8f, 256f);
	public static final boolean RIPPLES = flag("mcopt.shade.ripples", true);
	/** Raindrop grids: 2 (quality, ultra) or 1 with faster drops (performance, balanced: about half the cost). */
	public static final int RIPPLE_LAYERS = Integer.getInteger("mcopt.shade.rippleLayers", Shade.TIER >= 2 ? 2 : 1) >= 2 ? 2 : 1;
	/**
	 * Budget gates (performance, balanced): no sun highlight on wet surfaces in heavy rain (the sun is behind the clouds),
	 * raindrop rings only where the puddle mirror shows them, rain streaks lit by the sky's mean light (no sky-view LUT per
	 * streak fragment), coloured shadows fade out in heavy rain (tint pass skipped), wet films off the puddles see the overcast
	 * sky's mean light in heavy rain, puddle reflections marched from F x P 0.05 (not 0.035: puddles within ~4.5 blocks of the
	 * feet reflect 2-5 % and keep the sky alone). The mirror (grazing views) is untouched. Quality/ultra keep the full shading
	 * (dev bits 32/64/128/256/512/131072 price each gate there).
	 */
	public static final boolean LITE = flag("mcopt.shade.weatherLite", Shade.TIER <= 1);
	/**
	 * M3.3 rain budget options (mcopt.shade.rainBudget: a comma list of gate, ripples, steps; empty or none = M3.2), each with
	 * a small look cost: gate = puddle reflections marched from F x P 0.06 (puddles within ~3 blocks of the feet lose a ~5 %
	 * reflection), ripples = raindrop rings fade out nearer (none beyond ~10 blocks), steps = 8 reflection steps (thin things
	 * like torches can be missed in the reflection). With mcopt.shade.rainBudget.dev=true each is switched in one session by
	 * its dev bit (262144, 524288, 1048576: pricing).
	 */
	public static final String RAIN_BUDGET = System.getProperty("mcopt.shade.rainBudget", "").trim().toLowerCase(Locale.ROOT);
	public static final boolean B_GATE = budget("gate"), B_RIPPLE = budget("ripples"), B_STEPS = budget("steps");
	/** M3.3 pricing: the options switchable by their dev bits (mcopt.shade.dev) in one session; off = the shaders of M3.2. */
	public static final boolean B_DEV = flag("mcopt.shade.rainBudget.dev", false);
	public static final boolean SNOW = flag("mcopt.shade.snowCover", true);
	/**
	 * (2026-10-11, Gael: rain on a stony mountain turned the ground below flat white with dark holes) Where the snow and the rain
	 * reach on the terrain. The game decides rain or snow by the temperature at the camera's height, and above sea level + 17 the
	 * temperature falls with height (Biome.getHeightAdjustedTemperature): windswept hills (0.2) snow above y ~120 and rain below.
	 * Standing above that line made the whole terrain snow-covered, the rained-on ground below included. Now the camera biome's
	 * line (WeatherFrame.snowLine) limits each: snow cover above it (and only in snowy biomes unless SNOW_LINE_COVER), wetness
	 * and puddles below it, fading out over the 16 blocks above it (the game's own +-8 blocks of temperature noise: rain still
	 * falls on some columns there). Each limit is kept from the last time it snowed / rained, so snow left from a snowy biome
	 * still fades over minutes after walking into a warm one, as before. false = M3's look.
	 */
	public static final boolean SNOW_LINE = flag("mcopt.shade.snowLine", true);
	/** (2026-10-11, mcopt.shade.snowGrain, true) the snow cover keeps a trace of the block's texture (false: flat white, M3). */
	public static final boolean SNOW_GRAIN = flag("mcopt.shade.snowGrain", true);
	/** (SNOW_LINE) mcopt.shade.snowLine.cover (false): the snow cover also above the snow line of biomes that aren't snowy. */
	public static final boolean SNOW_LINE_COVER = flag("mcopt.shade.snowLine.cover", false);
	/** Blend half-width of the snow line (blocks): the game's temperature noise moves it +-8 (Biome.TEMPERATURE_NOISE x 8). */
	static final float LINE_BAND = 8f;
	public static final boolean SLANT = flag("mcopt.shade.rainSlant", true);
	public static final boolean LIGHTNING = flag("mcopt.shade.lightning", true);
	/** HDR only: the terrain reads the tint map through ShadeResources (no reader in LDR, so no tint pass either). */
	public static final boolean COLOR_SHADOWS = ON && Shade.SHADOWS && mcopt.metal.shade.ShadeConfig.HDR && flag("mcopt.shade.colorShadows", true);
	public static final int COLOR_SHADOW_RES = Integer.getInteger("mcopt.shade.colorShadowRes", Shade.TIER >= 3 ? 2048 : 1024) >= 2048 ? 2048 : 1024;
	public static final float TIME_SCALE = Math.clamp(floatFlag("mcopt.shade.weatherTime", 1f), 0.1f, 100f);
	public static final float FORCE_WET = floatFlag("mcopt.shade.wetness", -1f);
	public static final float FORCE_SNOW = floatFlag("mcopt.shade.snowAmount", -1f);
	/**
	 * M3.3 wet ground (Gael: the whole ground should get wet in rain, not only the puddles): solid ground under open sky soaks
	 * into a water film (darker, a Fresnel sheen of the sky, the sun's highlight, reflections where the sheen shows them),
	 * puddles are the deeper water in its low spots with a wetter rim. false at startup: weather_surface.metal compiles
	 * without it (M3.2's shaders); on, the property is read again every frame (ShadeLook.water.x: false = M3.2's look).
	 */
	public static final boolean WET_ALL = flag("mcopt.shade.wetAll", true);
	/** Film reflections' gate (F x k x gloss; 0 = off): on wherever the puddles reflect (puddleSsr: not on performance). */
	static final float WET_SSR = PUDDLE_SSR ? 0.06f : 0f;

	/** ShadeResources entries (shade_look.metal): last frame's linear view depth (TAA history), the coloured-shadow map. */
	public static final int RES_PREV_DEPTH = 5, RES_SHADOW_TINT = 6, RES_NOISE = 4;

	/** The baked puddle/snow noise tile (ShadeResources entry 4), 0 until baked; bake failures fall back to the analytic noise. */
	private static long noiseTexture;
	private static boolean noiseFailed;


	// ---- state (render thread) -----------------------------------------------------------------------------------------
	/** Smoothed: wetness, puddles, snow cover, rain intensity. */
	static float wetness, puddles, snow, rain;
	/** Wind direction (radians from +x toward +z), slant, gust; snowfall at the camera 0..1 (smoothed: snow flakes' look). */
	static float windAngle, slant, gust, snowfall;

	/** (1.2.7) The wind's direction (radians from +x toward +z), for the waving foliage. */
	public static float windAngle() {
		return windAngle;
	}
	/** (SNOW_LINE) The lowest y the snow cover reaches and the highest the rain's wetness reaches, absolute; at first everywhere. */
	static float snowFloor = -1e4f, rainTop = 1e4f;
	/** This frame's flash: direction (camera-relative, unit) and its light. */
	static final float[] flashDir = {0f, 1f, 0f};
	static float flash;

	private ShadeWeather() {
	}

	/**
	 * Nothing of the weather shows on the terrain this frame (no rain, wetness, puddles, snow cover, snowfall or flash, below
	 * what can be seen): the terrain can take its lean variant without the wet-surface code (ShadeLean).
	 */
	public static boolean dry() {
		// (1.1) the packed amounts (the player's multipliers applied: at 0 the wet code isn't needed while it rains either)
		return wetNow() < 0.003f && puddlesNow() < 0.003f && snowNow() < 0.003f && rain < 0.003f && snowfall < 0.003f && flash <= 0f;
	}

	static boolean flag(String key, boolean fallback) {
		String v = System.getProperty(key);
		return v == null ? fallback : Boolean.parseBoolean(v.trim());
	}

	static float floatFlag(String key, float fallback) {
		try {
			String v = System.getProperty(key);
			return v == null ? fallback : Float.parseFloat(v.trim());
		} catch (NumberFormatException e) {
			return fallback;
		}
	}

	/**
	 * One frame of the weather's slow state. dt: seconds since the last frame; rainTarget / snowTarget: the rain level where it
	 * rains / snows on the terrain around the camera (0 elsewhere: deserts, other dimensions); snowing: it snows at the camera
	 * itself (the flakes' look); line: the camera biome's snow line (absolute y; NaN: unknown), camY: the camera's y; thunder
	 * 0..1; snap: jump to the targets (world load, dimension change, teleport).
	 */
	static void step(float dt, float rainTarget, float snowTarget, boolean snowing, float line, float camY, float thunder, float dayIndex,
	                 float seconds, boolean snap) {
		float s = dt * timeScale(); // (1.1) live
		// wetness: soaks in over ~20 s of rain, dries over a couple of minutes; puddles fill once the ground is wet and dry
		// slower still; snow builds over ~40 s and lingers for minutes
		float wetTarget = rainTarget;
		float puddleTarget = rainTarget > 0.05f ? Math.min(Math.max((wetness - 0.35f) / 0.65f, 0f), rainTarget) : 0f;
		if (snap) {
			wetness = wetTarget;
			puddles = wetTarget;
			snow = snowTarget;
			rain = rainTarget;
			snowfall = snowing && snowTarget > 0.05f ? 1f : 0f;
		} else {
			// (FT2.8, audit idx 90) drying toward slightly below 0, clamped: the values reach exactly 0 in finite time (puddles ~3.4
			// minutes sooner than the exponential's tail under 0.003, snow ~7), so the terrain's lean dry variant comes back that much earlier
			wetness = dryTo(wetness, wetTarget, s, 14f, 75f);
			puddles = dryTo(puddles, puddleTarget, s, 10f, 110f);
			snow = dryTo(snow, snowTarget, s, 30f, 240f);
			rain = approach(rain, rainTarget, dt, 1.5f, 3f);
			snowfall = approach(snowfall, snowing && snowTarget > 0.05f ? 1f : 0f, dt, 1.5f, 1.5f);
		}
		if (snowLine() && !Float.isNaN(line)) {
			// within 400 blocks of the camera (+-1e4 = everywhere / nowhere), eased over ~1.5 s: no jump at a biome's border
			float lo = camY - 400f, hi = camY + 400f, lt = Math.clamp(line, lo, hi);
			float k = snap ? 1f : 1f - (float) Math.exp(-dt / 1.5f);
			if (snowTarget > 0f) {
				float v = Math.clamp(snowFloor, lo, hi);
				snowFloor = v + (lt - v) * k;
			}
			if (rainTarget > 0f) {
				float v = Math.clamp(rainTop, lo, hi);
				rainTop = v + (lt - v) * k;
			}
		}
		float forceWet = floatFlag("mcopt.shade.wetness", FORCE_WET); // (M3.3: read every frame, for A/B shots after the rain)
		if (forceWet >= 0f) {
			wetness = Math.min(forceWet, 1f);
			puddles = Math.min(forceWet, 1f);
		}
		float forceSnow = Live.f("mcopt.shade.snowAmount", FORCE_SNOW); // (1.1) live
		if (forceSnow >= 0f) snow = Math.min(forceSnow, 1f);
		// wind: a direction per day that wanders slowly; storms lean the rain more and gust
		double h = Math.sin(dayIndex * 12.9898 + 78.233) * 43758.5453;
		windAngle = (float) ((h - Math.floor(h)) * Math.PI * 2 + 0.35 * Math.sin(seconds / 97.0));
		gust = (float) (0.5 + 0.5 * Math.sin(seconds * 0.71) * Math.sin(seconds * 0.23 + 1.3));
		slant = rainSlant() ? (0.12f + 0.22f * thunder) * (0.75f + 0.5f * gust) : 0f;
	}

	/** (1.1) live: mcopt.shade.weatherTime, the time scale of wetting and drying (TIME_SCALE at startup; 0.1..100). */
	static float timeScale() {
		return Live.f("mcopt.shade.weatherTime", TIME_SCALE, 0.1f, 100f);
	}

	/** (1.1) live: mcopt.shade.snowLine, whether the camera biome's snow line limits the snow cover and the rain's wetness. */
	static boolean snowLine() {
		return Live.b("mcopt.shade.snowLine", SNOW_LINE);
	}

	/** (1.1) live off: mcopt.shade.rainSlant (the slanted rain stage exists only when it was on at startup, SLANT). */
	static boolean rainSlant() {
		return SLANT && Live.b("mcopt.shade.rainSlant", true);
	}

	/** (1.1) live off: mcopt.shade.lightning, the flash light (its code compiled only when it was on at startup, LIGHTNING). */
	static boolean lightning() {
		return LIGHTNING && Live.b("mcopt.shade.lightning", true);
	}

	/**
	 * (1.1) live off: mcopt.shade.colorShadows. The tint map, its pass and the receivers' lookup exist only when it was on at
	 * startup (COLOR_SHADOWS); off then skips the tint pass (ShadowPass) and the receivers see no casters (ssr.w = 0).
	 */
	public static boolean colorShadows() {
		return COLOR_SHADOWS && Live.b("mcopt.shade.colorShadows", true);
	}

	/**
	 * (1.1) live: the player's amount of v (mcopt.shade.user.wetness / .puddles / .snow, 1 = as released, 0..2), clamped to
	 * 0..1 (what the shaders expect). At 1 the value is passed through untouched, so the image is the released one.
	 */
	private static float amount(float v, String key) {
		float k = Live.f(key, 1f, 0f, 2f);
		return k == 1f ? v : Math.min(Math.max(v * k, 0f), 1f);
	}

	/** This frame's packed wetness, puddles and snow cover (wet.x / y / z): the state times the player's amounts. */
	private static float wetNow() {
		return amount(wetness, "mcopt.shade.user.wetness");
	}

	private static float puddlesNow() {
		return amount(puddles, "mcopt.shade.user.puddles");
	}

	private static float snowNow() {
		return amount(snow, "mcopt.shade.user.snow");
	}

	/** Exponential approach with separate rise / fall time constants (s). */
	private static float dryTo(float v, float target, float dt, float rise, float fall) {
		return target > 0f ? approach(v, target, dt, rise, fall) : Math.max(approach(v, -0.02f, dt, rise, fall), 0f);
	}

	private static float approach(float v, float target, float dt, float rise, float fall) {
		float tau = target > v ? rise : fall;
		return target + (v - target) * (float) Math.exp(-dt / tau);
	}

	/** Writes ShadeLook.wet, wind and flash (call from ShadeLook.pack, b = the struct's bytes, little-endian). */
	public static void pack(ByteBuffer b) {
		if (!ON) {
			put4(b, ShadeLook.WET, 0f, 0f, 0f, 0f);
			put4(b, ShadeLook.WIND, 1f, 0f, 0f, 0f);
			put4(b, ShadeLook.FLASH, 0f, 1f, 0f, 0f);
			put4(b, ShadeLook.WATER, 0f, 0f, 0f, 0f);
			put4(b, ShadeLook.WATER_ABS, 0f, 0.55f, 0f, 0.12f);
			return;
		}
		// M3.3 wet ground: ShadeLook.water (576, reserved for the water module, unused by it) = (on, soaked film roughness,
		// vegetation's extra roughness, film reflections' gate), waterAbs (592) = (extra darkening, vegetation's film share, texel height
		// proxy strength, rim band width in puddle-field units); read
		// every frame, so a bench can switch them live (mcbench WetShots / MiscShots ab phases)
		boolean wetAll = WET_ALL && flag("mcopt.shade.wetAll", true);
		put4(b, ShadeLook.WATER, wetAll ? 1f : 0f, floatFlag("mcopt.shade.wetRough", 0.2f), floatFlag("mcopt.shade.wetVeg", 0.18f),
			wetAll ? Math.max(floatFlag("mcopt.shade.wetSsr", WET_SSR), 0f) : 0f);
		put4(b, ShadeLook.WATER_ABS, floatFlag("mcopt.shade.wetDark", 0.2f), floatFlag("mcopt.shade.wetVegFilm", 0.55f), floatFlag("mcopt.shade.wetTex", 0f),
			Math.max(floatFlag("mcopt.shade.wetRim", 0.12f), 0.005f));
		// (1.1) the player's amounts (mcopt.shade.user.wetness / .puddles / .snow, live; 1 = the state as it is)
		put4(b, ShadeLook.WET, wetNow(), PUDDLES ? puddlesNow() : 0f, SNOW ? snowNow() : 0f, rain);
		put4(b, ShadeLook.WIND, (float) Math.cos(windAngle), (float) Math.sin(windAngle), slant, snowfall); // w: snowfall (gust only shapes the slant)
		put4(b, ShadeLook.FLASH, flashDir[0], flashDir[1], flashDir[2], lightning() ? flash : 0f); // (1.1) live off
		b.putFloat(ShadeLook.SSR + 8, noiseTexture != 0 ? 1f : 0f); // ssr.z: ShadeResources.weatherNoise is baked
		// ssr.w / tintRect: no coloured-shadow casters until the shadow pass of this frame says otherwise (ShadowPass ->
		// ShadeBindings.setShadowTint, before the world passes); without a shadow pass the receivers skip the lookup
		b.putFloat(ShadeLook.SSR + 12, 0f);
		put4(b, ShadeLook.TINT_RECT, 1f, 1f, -1f, -1f);
	}

	/**
	 * Bakes the puddle field and snow drifts into one 256-block tile (weather_surface.metal shade_wx_noise_fs, RG16F 1024^2)
	 * once, into enc before the world passes, and publishes it as ShadeResources entry 4. HDR only (the terrain reads it
	 * through ShadeResources); idempotent.
	 */
	public static void bakeNoise(long enc) {
		if (!ON || noiseTexture != 0 || noiseFailed || enc == 0 || !(PUDDLES || SNOW)) return;
		try {
			long t0 = mcopt.metal.shade.ShadeCompile.now();
			long lib = mcopt.metal.shade.ShadeRender.library(noiseSource());
			long pso = mcopt.metal.shade.ShadeRender.pipeline(lib, "shade_fs_vs", "shade_wx_noise_fs", mcopt.metal.shade.ShadeRender.RG16F,
				mcopt.metal.shade.ShadeRender.BLEND_NONE);
			mcopt.metal.shade.ShadeCompile.setup("weather noise", t0);
			long tex = mcopt.metal.shade.ShadeRender.texture(mcopt.metal.shade.ShadeRender.RG16F, 1024, 1024, false, "mcopt shade weather noise");
			mcopt.metal.shade.ShadeRender.pass(enc, pso, tex, mcopt.metal.shade.ShadeRender.DONT_CARE, null, null, "mcopt shade weather: noise bake");
			mcopt.metal.shade.ShadeRender.resource(RES_NOISE, tex);
			noiseTexture = tex;
		} catch (Throwable e) {
			noiseFailed = true;
			System.out.println("[mcopt] shade: weather noise bake failed, per-pixel noise from now on: " + e);
		}
	}

	/**
	 * Writes ShadeFrame.wxLine at {@code at} (call from ShadeFrame.pack): snow floor, rain top, blend half-width, and in w the bits
	 * 1 = the snow line is on, 2 = (2026-10-12) mcopt.shade.wetWalls (true; read every frame, for in-session A/B): walls take no
	 * glossy film (they only darken, with a faint rough sheen) and mirror rays below the horizon see the ground's light, not the sky;
	 * 4 = (2026-10-12) mcopt.shade.wetVegLight (true, read every frame): grass and leaves darken a third as much when wet (water
	 * beads on blades; porous stone, dirt and wood keep the full darkening); 8 = (2026-10-12) mcopt.shade.wetVegPuddles (true, read
	 * every frame): grass tops hold about a third of the puddles, shallower (blades stand out of the water: x0.7).
	 */
	public static void packLine(ByteBuffer b, int at) {
		boolean on = ON && snowLine(); // (1.1) live
		int bits = (on ? 1 : 0) | (flag("mcopt.shade.wetWalls", true) ? 2 : 0) | (flag("mcopt.shade.wetVegLight", true) ? 4 : 0)
			| (flag("mcopt.shade.wetVegPuddles", true) ? 8 : 0);
		put4(b, at, on ? snowFloor : -1e4f, on ? rainTop : 1e4f, LINE_BAND, bits);
	}

	private static void put4(ByteBuffer b, int at, float x, float y, float z, float w) {
		b.putFloat(at, x).putFloat(at + 4, y).putFloat(at + 8, z).putFloat(at + 12, w);
	}

	/**
	 * True when the coloured shadows have faded out (weather_surface.metal shadeShadowTint, SHADE_DEV_WX_RAIN_TINT: over rain
	 * 0.5-0.8, with LITE or dev bit 256): heavy rain, where the sun they colour gives a third of its light or less. ShadowPass
	 * then skips the tint pass (ssr.w stays 0, so the receivers skip the lookup as well).
	 */
	public static boolean tintHidden() {
		return ON && rain >= 0.8f && (LITE || (Integer.getInteger("mcopt.shade.dev", 0) & 256) != 0);
	}

	/** The wetness the water module's ripples and roughness use (rain intensity while it rains). */
	public static float rainIntensity() {
		return rain;
	}

	/** For logs: wetness, puddles, snow, rain, flash. */
	public static String describeState() {
		return String.format(Locale.ROOT, "wet %.2f puddles %.2f snow %.2f rain %.2f flash %.2f", wetness, puddles, snow, rain, flash)
			+ (snowLine() ? String.format(Locale.ROOT, ", snow from y %.0f, rain up to y %.0f", snowFloor, rainTop) : "");
	}

	/** The MSL in front of the Sodium terrain stages (after ShadeMsl.prelude, before the water module): defines + weather_surface.metal. */
	public static String prelude() {
		return prelude(false);
	}

	/** The puddle/snow noise bake's source (bakeNoise): prelude + post (shade_fs_vs) + this prelude with SHADE_WX_NOISE_BAKE. */
	public static String noiseSource() {
		return mcopt.metal.shade.ShadeRender.prelude() + mcopt.metal.shade.ShadeRender.postSource() + "#define SHADE_WX_NOISE_BAKE\n" + prelude();
	}

	/**
	 * translucent: for the translucent terrain fragment (stained glass, ice: wet, no puddles or puddle reflections; the HDR
	 * translucent pipeline with the water module is at the edge of what the Metal compiler service builds: more code there
	 * made it crash with XPC_ERROR_CONNECTION_INTERRUPTED, see WATER_M21.md).
	 */
	public static String prelude(boolean translucent) {
		if (!MODULE) return "";
		StringBuilder s = new StringBuilder("#define SHADE_WEATHER\n");
		if (LITE) s.append("#define SHADE_WX_LITE\n");
		if (B_GATE) s.append("#define SHADE_WX_B_GATE\n");
		if (B_RIPPLE) s.append("#define SHADE_WX_B_RIPPLE\n");
		if (B_STEPS) s.append("#define SHADE_WX_B_STEPS\n");
		if (B_DEV) s.append("#define SHADE_WX_B_DEV\n");
		// (M3.3 wet ground; not in the translucent fragment: that pipeline is at the edge of what the Metal compiler builds)
		if (WET_ALL && !translucent) s.append("#define SHADE_WET_ALL\n");
		if (PUDDLES && !translucent) s.append("#define SHADE_PUDDLES\n");
		if (PUDDLE_SSR && !translucent) s.append("#define SHADE_PUDDLE_SSR\n#define SHADE_PUDDLE_STEPS ").append(PUDDLE_STEPS).append('\n')
			.append("#define SHADE_PUDDLE_DIST ").append(String.format(Locale.ROOT, "%.1f", PUDDLE_DIST)).append('\n')
			.append(PUDDLE_QUAD ? "#define SHADE_PUDDLE_QUAD\n" : "");
		if (RIPPLES) s.append("#define SHADE_RIPPLES\n#define SHADE_RIPPLE_LAYERS ").append(RIPPLE_LAYERS).append('\n');
		if (SNOW) s.append("#define SHADE_SNOW_COVER\n");
		if (SNOW && SNOW_GRAIN) s.append("#define SHADE_SNOW_GRAIN\n"); // (2026-10-11)
		if (LIGHTNING) s.append("#define SHADE_LIGHTNING\n");
		if (COLOR_SHADOWS || (!Shade.ENABLED && flag("mcopt.shade.colorShadows", true))) s.append("#define SHADE_COLOR_SHADOW\n");
		return s.append(ShadeMsl.resource("weather_surface.metal")).append('\n').toString();
	}

	private static boolean budget(String option) {
		for (String o : RAIN_BUDGET.split(",")) if (o.trim().equals(option)) return true;
		return false;
	}

	static String describe() {
		return (LITE ? "lite, " : "") + (WET_ALL ? "wet all, " : "") + (RAIN_BUDGET.isEmpty() ? "" : "rain budget " + RAIN_BUDGET + ", ") + "puddles " + PUDDLES + (PUDDLE_SSR ? " (ssr " + PUDDLE_STEPS + " steps" + (PUDDLE_QUAD ? ", quad" : "") + ")" : "") + ", ripples " + RIPPLES + ", snow " + SNOW + ", slant " + SLANT
			+ ", lightning " + LIGHTNING + ", coloured shadows " + (COLOR_SHADOWS ? COLOR_SHADOW_RES + "^2" : "off");
	}
}
