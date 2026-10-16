/*
 * Copyright 2026 mcopt-shade contributors
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
 * License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
 * law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
 * OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
 * limitations under the License.
 */
package mcopt.metal.shade;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * M3.1: the world's render resolution as the player picks it in the pause menu (ShadePauseScreenMixin), live: the native
 * shading's TAAU (ShadeTaa) renders the world at that height and rebuilds the full-resolution frame; the GUI and the hand stay
 * at the screen's resolution. "Auto" is the preset's own behaviour (dynamic resolution in its range). The choice is kept in
 * config/mcopt.properties as {@code mcopt.shade.resolution} (auto, native, or a height such as 1440), read at startup like
 * every mcopt key.
 */
public final class ShadeResolution {
	/** The choices in menu order: 0 = auto (the preset), -1 = native, else a render height in pixels. */
	private static final int[] CHOICES = {0, -1, 2160, 1800, 1600, 1440, 1200, 1080};
	/** The lowest scale a choice may ask for (TAAU still rebuilds a sharp frame from about half the pixels per axis). */
	public static final float MIN_SCALE = 0.5f;
	private static volatile int index = parse(System.getProperty("mcopt.shade.resolution", "auto"));

	private ShadeResolution() {
	}

	private static int parse(String v) {
		String s = v.trim().toLowerCase(Locale.ROOT).replace("p", "");
		if (s.equals("native") || s.equals("nativa")) return 1;
		try {
			int h = Integer.parseInt(s);
			for (int i = 2; i < CHOICES.length; i++) if (CHOICES[i] == h) return i;
		} catch (NumberFormatException e) {
			// auto
		}
		return 0;
	}

	/** The render scale this choice asks for at an output height, or 0 for auto (the preset decides). */
	public static float scale(int outHeight) {
		int c = CHOICES[index];
		if (c == 0 || outHeight <= 0) return 0f;
		if (c < 0) return 1f;
		return Math.clamp((float) c / outHeight, MIN_SCALE, 1f);
	}

	/** Whether the player fixed a resolution (not auto). */
	public static boolean fixed() {
		return CHOICES[index] != 0;
	}

	/**
	 * M3.3 (Gael: "ver la resolución real del mundo"): the world's render size right now, {width, height}, from TAAU's live
	 * scale (the dynamic resolution's in Auto); null before the first world frame or without TAAU (the world then renders at
	 * the window's size).
	 */
	public static int[] worldSize() {
		mcopt.metal.shade.taa.ShadeTaa taa = mcopt.metal.shade.taa.ShadeTaa.current();
		if (taa == null || taa.outWidth() <= 0) return null;
		float s = taa.scale();
		return new int[] {Math.round(taa.outWidth() * s), Math.round(taa.outHeight() * s)};
	}

	/**
	 * M3.3: the F3 line (ShadeDebugMixin; top of F3's right column): the world's render size, its share of the window, the pause
	 * menu's choice and the preset, e.g. "Shaders: mundo 2419x1571 (80 %) · Auto · balanced". F3's "Display" line is the
	 * window's size, which the render resolution never changes.
	 */
	public static String debugLine() {
		String preset = mcopt.metal.shade.taa.TaaConfig.PRESET.name().toLowerCase(Locale.ROOT);
		int[] size = worldSize();
		mcopt.metal.shade.taa.ShadeTaa taa = mcopt.metal.shade.taa.ShadeTaa.current();
		if (size == null || taa == null) {
			return "Shaders: mundo a la resolución de la ventana (sin TAAU) · " + preset;
		}
		int c = CHOICES[index];
		String choice = c == 0 ? "Auto" : c < 0 ? "Nativa" : c + "p";
		// (2026-10-09) with a lower output resolution (ShadeOutput): "→ salida 1920x1080"
		var o = taa.outputTarget();
		String out = o == null ? "" : ShadeOutput.debugPart(taa.outWidth(), taa.outHeight(), o.width, o.height);
		return String.format(Locale.ROOT, "Shaders: mundo %dx%d (%d %%)%s · %s · %s", size[0], size[1], Math.round(taa.scale() * 100f), out, choice, preset);
	}

	/** The menu label for the current choice (short: it must fit the pause menu's 204-pixel button). */
	public static String label(int outWidth, int outHeight) {
		int c = CHOICES[index];
		if (c == 0) {
			// M3.3: in Auto, the height the dynamic resolution renders the world at right now ("Auto (1571p)"); M3.4: only from
			// a frame Auto drew (right after cycling to Auto the last frame still had the fixed choice's height)
			int[] size = worldSize();
			mcopt.metal.shade.taa.ShadeTaa taa = mcopt.metal.shade.taa.ShadeTaa.current();
			String auto = ShadeLang.t("Resolución: Auto", "Resolution: Auto");
			return size == null || taa == null || !taa.lastAuto() ? auto + ShadeLang.t(" (dinámica)", " (dynamic)") : auto + " (" + size[1] + "p)";
		}
		if (c < 0) return ShadeLang.t("Resolución: Nativa", "Resolution: Native");
		return ShadeLang.t("Resolución: ", "Resolution: ") + c + "p";
	}

	/** Next choice (the pause-menu button), saved to config/mcopt.properties. */
	public static void cycle(Path gameDir) {
		index = (index + 1) % CHOICES.length;
		int c = CHOICES[index];
		String value = c == 0 ? "auto" : c < 0 ? "native" : Integer.toString(c);
		System.setProperty("mcopt.shade.resolution", value);
		save(gameDir.resolve("config").resolve("mcopt.properties"), value);
	}

	private static void save(Path file, String value) {
		try {
			List<String> lines = Files.exists(file) ? new ArrayList<>(Files.readAllLines(file, StandardCharsets.UTF_8)) : new ArrayList<>();
			boolean found = false;
			for (int i = 0; i < lines.size(); i++) {
				if (lines.get(i).trim().startsWith("mcopt.shade.resolution=")) {
					lines.set(i, "mcopt.shade.resolution=" + value);
					found = true;
				}
			}
			if (!found) {
				lines.add("# Resolución del mundo (también desde el menú de pausa): auto, native, 2160, 1800, 1600, 1440, 1200, 1080");
				lines.add("mcopt.shade.resolution=" + value);
			}
			Files.createDirectories(file.getParent());
			Files.write(file, lines, StandardCharsets.UTF_8);
		} catch (IOException e) {
			System.out.println("[mcopt] shade: could not save the resolution choice: " + e);
		}
	}
}
