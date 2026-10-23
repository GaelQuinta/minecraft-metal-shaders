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

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * (1.1, 2026-10-13; players on Reddit asked for shader settings in game) The player's settings that several modules read as
 * typed values (the rest are read where they are used, through Live; every setting of the screen is in ShadeOptions). Each one is a system property, so
 * config/mcopt.properties and -D flags set it as before; the screen changes it live and writes the changed ones back to
 * config/mcopt.properties when it closes. Everything but the preset applies on the next frame (the preset sizes every module's
 * buffers and passes at startup). The defaults are the look as released: every multiplier at 100.
 *
 * <ul>
 * <li>{@code mcopt.shade.preset}: performance, balanced, quality, ultra (at the next start).</li>
 * <li>{@code mcopt.shade.look}: epic, storybook, natural.</li>
 * <li>{@code mcopt.shade.ev} (0): brightness in EV, -2..2.</li>
 * <li>{@code mcopt.shade.user.saturation} (100): percent, 0..150 (2x turned a sunset neon orange, v11-s1).</li>
 * <li>{@code mcopt.shade.user.bloom}, {@code .godrays}, {@code .haze} (100): percent, 0..200 (haze: the air's haze only; the
 * ground mist is user.mist, ShadeLook).</li>
 * <li>{@code mcopt.shade.clouds.mode}: volumetric, blocky (12-block cells like vanilla's, ray-traced and lit), vanilla (the
 * game's own, lit by the shaders), off. Default: volumetric, or blocky with mcopt.shade.clouds.style=blocky or the storybook
 * look.</li>
 * <li>{@code mcopt.shade.aurora}: off, rare, auto, always.</li>
 * <li>{@code mcopt.shade.water.color}: natural (the biome's), blue, turquoise, green, clear.</li>
 * <li>{@code mcopt.shade.water.clarity} (100): percent, 25..300 (how far the eye sees into water).</li>
 * <li>{@code mcopt.shade.waterWaves}, {@code mcopt.shade.waterReflect} (1): wave height and reflection strength, 0..2.</li>
 * <li>{@code mcopt.shade.user.ssr} (true): screen-space reflections on the water (false: sky and sun only, faster).</li>
 * </ul>
 */
public final class ShadeSettings {
	public static final String PRESET = "mcopt.shade.preset", LOOK = "mcopt.shade.look", EV = "mcopt.shade.ev",
		SATURATION = "mcopt.shade.user.saturation", BLOOM = "mcopt.shade.user.bloom", GODRAYS = "mcopt.shade.user.godrays",
		HAZE = "mcopt.shade.user.haze", CLOUDS = "mcopt.shade.clouds.mode", AURORA = "mcopt.shade.aurora",
		SSR = "mcopt.shade.user.ssr", WATER_COLOR = "mcopt.shade.water.color", WATER_CLARITY = "mcopt.shade.water.clarity", WAVES = "mcopt.shade.waterWaves",
		REFLECT = "mcopt.shade.waterReflect";

	public static final String[] PRESETS = {"performance", "balanced", "quality", "ultra"};
	public static final String[] LOOKS = {"epic", "storybook", "natural"};
	public static final int CLOUDS_VOLUMETRIC = 0, CLOUDS_BLOCKY = 1, CLOUDS_VANILLA = 2, CLOUDS_OFF = 3;
	public static final String[] CLOUD_MODES = {"volumetric", "blocky", "vanilla", "off"};
	/** In menu order; DimsConfig's codes are 0 off, 1 auto, 2 always, 3 rare. */
	public static final String[] AURORAS = {"off", "rare", "auto", "always"};
	public static final String[] WATER_COLORS = {"natural", "blue", "turquoise", "green", "clear"};
	/**
	 * The water colours as a biome water colour would be (sRGB, the vertex tint the absorption is made from: water.metal
	 * shadeWaterSigmaA): vanilla's default ocean blue, its warm ocean, a clear green between river and mangrove, and a pale cyan
	 * that absorbs little (clear tropical water). Natural = the biome's own.
	 */
	private static final int[] WATER_RGB = {0, 0x3F76E4, 0x43D5EE, 0x4C9E7A, 0x8CE6F5};

	private static volatile int look = indexOf(LOOKS, System.getProperty(LOOK, "epic"), 0);
	private static volatile float ev = clamp(floatProp(EV, 0f), -2f, 2f);
	private static volatile int saturation = percent(SATURATION, 100, 0, 150), bloom = percent(BLOOM, 100, 0, 200),
		godrays = percent(GODRAYS, 100, 0, 200), haze = percent(HAZE, 100, 0, 200), clarity = percent(WATER_CLARITY, 100, 25, 300);
	/** When no cloud mode is set, the default follows the current look (or the legacy cloud style override). */
	private static volatile int clouds = indexOf(CLOUD_MODES, System.getProperty(CLOUDS, ""), defaultCloudMode());
	private static volatile int aurora = indexOf(AURORAS, System.getProperty(AURORA, "auto"), 2);
	private static volatile int waterColor = indexOf(WATER_COLORS, System.getProperty(WATER_COLOR, "natural"), 0);
	private static volatile float waves = clamp(floatProp(WAVES, 1f), 0f, 2f), reflect = clamp(floatProp(REFLECT, 1f), 0f, 2f);
	private static volatile boolean ssr = !"false".equalsIgnoreCase(System.getProperty(SSR, "true").trim());

	/** Keys changed since the last save, with their new values (insertion order: the file's order). */
	private static final Map<String, String> CHANGED = new LinkedHashMap<>();

	private ShadeSettings() {
	}

	/**
	 * Re-reads every setting from its system property (ShadeLook.update, once per frame: ~13 lookups). The screen sets the
	 * properties too, so this changes nothing then; a bench phase or variant that sets one (mcbench.variantShots) shows on the
	 * next frame, as the other live flags do. The preset is not re-read (it applies at the next start).
	 */
	public static void sync() {
		look = indexOf(LOOKS, System.getProperty(LOOK, "epic"), 0);
		ev = clamp(floatProp(EV, 0f), -2f, 2f);
		saturation = percent(SATURATION, 100, 0, 150);
		bloom = percent(BLOOM, 100, 0, 200);
		godrays = percent(GODRAYS, 100, 0, 200);
		haze = percent(HAZE, 100, 0, 200);
		clarity = percent(WATER_CLARITY, 100, 25, 300);
		clouds = indexOf(CLOUD_MODES, System.getProperty(CLOUDS, ""), defaultCloudMode());
		aurora = indexOf(AURORAS, System.getProperty(AURORA, "auto"), 2);
		waterColor = indexOf(WATER_COLORS, System.getProperty(WATER_COLOR, "natural"), 0);
		waves = clamp(floatProp(WAVES, 1f), 0f, 2f);
		reflect = clamp(floatProp(REFLECT, 1f), 0f, 2f);
		ssr = !"false".equalsIgnoreCase(System.getProperty(SSR, "true").trim());
	}

	// ---- the values, read every frame -----------------------------------------------------------------------------------
	/** 0 epic, 1 storybook, 2 natural. */
	public static int look() {
		return look;
	}

	public static float ev() {
		return ev;
	}

	/** Multipliers, 1 = as released. */
	public static float saturation() {
		return saturation / 100f;
	}

	public static float bloom() {
		return bloom / 100f;
	}

	public static float godrays() {
		return godrays / 100f;
	}

	public static float haze() {
		return haze / 100f;
	}

	/** CLOUDS_VOLUMETRIC, CLOUDS_BLOCKY, CLOUDS_VANILLA or CLOUDS_OFF. */
	public static int clouds() {
		return clouds;
	}

	/** DimsConfig's aurora code: 0 off, 1 auto, 2 always, 3 rare. */
	public static int aurora() {
		return switch (aurora) {
			case 0 -> 0;
			case 1 -> 3;
			case 3 -> 2;
			default -> 1;
		};
	}

	/** The water colour override, linear rgb and its weight (0 = the biome's own colour). */
	public static void waterTint(float[] out) {
		int c = WATER_RGB[waterColor];
		out[0] = toLinear(c >> 16 & 0xFF);
		out[1] = toLinear(c >> 8 & 0xFF);
		out[2] = toLinear(c & 0xFF);
		out[3] = waterColor == 0 ? 0f : 1f;
	}

	/** How far the eye sees into water, 1 = as released (the absorption is divided by it). */
	public static float clarity() {
		return clarity / 100f;
	}

	public static float waves() {
		return waves;
	}

	public static float reflect() {
		return reflect;
	}

	/** Screen-space reflections on the water (false: the sky and the sun only; ~1.2 ms less looking over a lake on an M4). */
	public static boolean ssr() {
		return ssr;
	}

	/**
	 * (ShadeOption.set) Records a setting for config/mcopt.properties: its text, or null for its default (the key's line is
	 * removed, so the default follows the preset and later releases). The property itself is set by the caller.
	 */
	static synchronized void changed(String key, String value) {
		CHANGED.put(key, value);
	}

	/** Writes the changed settings to config/mcopt.properties (each key's line replaced, or added at the end). */
	public static synchronized void save(Path gameDir) {
		if (CHANGED.isEmpty()) return;
		Path file = gameDir.resolve("config").resolve("mcopt.properties");
		try {
			List<String> lines = Files.exists(file) ? new ArrayList<>(Files.readAllLines(file, StandardCharsets.UTF_8)) : new ArrayList<>();
			boolean header = false;
			for (Map.Entry<String, String> e : CHANGED.entrySet()) {
				boolean found = false;
				for (int i = lines.size() - 1; i >= 0; i--) {
					String t = lines.get(i).trim();
					if (t.startsWith(e.getKey() + "=") || t.startsWith(e.getKey() + " ")) {
						if (e.getValue() == null) lines.remove(i);
						else lines.set(i, e.getKey() + "=" + e.getValue());
						found = true;
					}
				}
				if (!found && e.getValue() != null) {
					if (!header && lines.stream().noneMatch(l -> l.startsWith("# Ajustes de shaders"))) {
						lines.add("# Ajustes de shaders (también desde el menú de pausa: Shaders...)");
						header = true;
					}
					lines.add(e.getKey() + "=" + e.getValue());
				}
			}
			Files.createDirectories(file.getParent());
			Files.write(file, lines, StandardCharsets.UTF_8);
			System.out.println("[mcopt] shade: settings saved: " + CHANGED);
			CHANGED.clear();
		} catch (IOException e) {
			System.out.println("[mcopt] shade: could not save the shader settings: " + e);
		}
	}

	// ---- parsing -------------------------------------------------------------------------------------------------------
	/** The same fallback used by the renderer and the settings menu, including after a live look change. */
	static int defaultCloudMode() {
		String style = System.getProperty("mcopt.shade.clouds.style");
		if (style != null) return style.trim().equalsIgnoreCase("blocky") ? CLOUDS_BLOCKY : CLOUDS_VOLUMETRIC;
		return "storybook".equalsIgnoreCase(System.getProperty(LOOK, "").trim()) ? CLOUDS_BLOCKY : CLOUDS_VOLUMETRIC;
	}

	private static int indexOf(String[] names, String v, int fallback) {
		String s = v.trim().toLowerCase(Locale.ROOT);
		for (int i = 0; i < names.length; i++) if (names[i].equals(s)) return i;
		// the aurora's older spellings (DimsConfig)
		if (names == AURORAS) {
			if (s.equals("false")) return 0;
			if (s.equals("on") || s.equals("true")) return 3;
		}
		return fallback;
	}

	private static float floatProp(String key, float fallback) {
		try {
			String v = System.getProperty(key);
			return v == null ? fallback : Float.parseFloat(v.trim());
		} catch (NumberFormatException e) {
			return fallback;
		}
	}

	private static int percent(String key, int fallback, int min, int max) {
		return Math.round(clamp(floatProp(key, fallback), min, max));
	}

	private static float clamp(float v, float min, float max) {
		return Math.max(min, Math.min(max, v));
	}

	private static float toLinear(int c8) {
		double c = c8 / 255.0;
		return (float) (c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4));
	}
}
