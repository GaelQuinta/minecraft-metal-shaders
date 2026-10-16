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
import java.util.List;
import java.util.Locale;

/**
 * The OUTPUT resolution of the native shading (2026-10-09, Gael: "la resolución como la del monitor, no la del reescalado"): the
 * size TAAU resolves the world into and the final pass tone-maps at, before one upscale pass to the window (ShadePost
 * shade_upscale). The render resolution (ShadeResolution: the world's own pixels, a share of this output) and the GUI, hand and
 * text (drawn after, on the window's target) are not affected. On a Retina screen "1080p" here costs the TAAU resolve and the
 * final pass about a quarter of their pixels; "Nativa" is the window's size (everything as before).
 *
 * <p>mcopt.shade.output = native | 2160 | 1440 | 1200 | 1080 | 900 (an output height; the width follows the window's aspect), also
 * cycled from the pause menu and saved to config/mcopt.properties.
 *
 * <p>Two ways (mcopt.shade.outputMode): <b>window</b> (default; Gael: "que todo se renderice a la resolución que se cambia"): the
 * window reports that size as its framebuffer (ShadeWindowMixin), so everything draws at it, the GUI and the text too, and the
 * compositor stretches the image over the screen, as a monitor of that resolution would show it (F3's "Display" line says
 * it; Distant Horizons too); <b>taau</b>: only the shaded frame (TAAU's output and the final pass) at that size, upscaled into the
 * window by shade_upscale, the hand, GUI and text at the screen's own resolution (HDR frame, no Distant Horizons).
 */
public final class ShadeOutput {
	/** The choices in menu order: -1 = native (the window), else an output height in pixels. */
	private static final int[] CHOICES = {-1, 2160, 1440, 1200, 1080, 900};

	private static volatile int index = parse(System.getProperty("mcopt.shade.output", "native"));

	private ShadeOutput() {
	}

	private static int parse(String v) {
		String s = v.trim().toLowerCase(Locale.ROOT).replace("p", "");
		try {
			int h = Integer.parseInt(s);
			for (int i = 1; i < CHOICES.length; i++) if (CHOICES[i] == h) return i;
		} catch (NumberFormatException e) {
			// native
		}
		return 0;
	}

	/** mcopt.shade.outputMode=taau: the shaded frame alone at the output size (see the class comment); else the whole window. */
	public static boolean taauMode() {
		return "taau".equalsIgnoreCase(System.getProperty("mcopt.shade.outputMode", "window").trim());
	}

	/**
	 * Whether the choice can apply in this session: the window mode always; the taau mode with the HDR frame (M2: its final pass
	 * writes the output-size image the upscale reads; M1's TAAU writes the window's target directly) and no Distant Horizons
	 * (it draws its LODs at the window's size).
	 */
	public static boolean available() {
		return !taauMode() || ShadeConfig.HDR && !mcopt.metal.DhCompat.loaded();
	}

	/** The chosen output height (the property read live: a bench phase may set it directly), or -1 for native. */
	private static int choice() {
		String live = System.getProperty("mcopt.shade.output");
		return CHOICES[live != null ? parse(live) : index];
	}

	/** {width, height} for a w x h image at output height c (the width by the aspect, even), or w x h at or above it. */
	private static int[] scaled(int w, int h, int c) {
		if (c < 0 || h <= 0 || c >= h) return new int[] {w, h};
		int sw = Math.max(2, (int) (Math.round((double) w * c / h / 2.0) * 2));
		return new int[] {Math.min(sw, w), c};
	}

	/**
	 * The window mode: the framebuffer size the window reports for a real framebuffer of width x height (ShadeWindowMixin): the
	 * output resolution's, else the real one. A scaled size maps to itself (its height is the choice).
	 */
	public static int[] framebuffer(int width, int height) {
		if (taauMode()) return new int[] {width, height};
		return scaled(width, height, choice());
	}

	/** The window mode, after a change: the window re-reads its framebuffer size and the game resizes to it (surface, GUI). */
	public static void apply() {
		if (taauMode()) return;
		net.minecraft.client.Minecraft mc = net.minecraft.client.Minecraft.getInstance();
		((mcopt.metal.mixin.shade.ShadeWindowAccessor) (Object) mc.getWindow()).mcopt$refreshFramebufferSize();
		mc.framebufferSizeChanged();
	}

	/**
	 * The output size for a window of mainWidth x mainHeight: {width, height}, the window's own size for native, a choice at or
	 * above the window's height, or while unavailable. The width keeps the window's aspect (even, so the 2x2 quads of the
	 * upscale line up).
	 */
	public static int[] size(int mainWidth, int mainHeight) {
		// (the window mode: the window's framebuffer has that size already, nothing to scale here)
		if (!taauMode() || !available()) return new int[] {mainWidth, mainHeight};
		return scaled(mainWidth, mainHeight, choice());
	}

	/**
	 * The output image's size this frame, {width, height}: TAAU's output (the chosen output resolution, else the window's) once
	 * it has drawn a frame, else the window framebuffer's. For passes sized as a share of the output (clouds, aurora), so they
	 * get cheaper with a lower output resolution as everything else does.
	 */
	public static int[] current(int windowWidth, int windowHeight) {
		mcopt.metal.shade.taa.ShadeTaa taa = mcopt.metal.shade.taa.ShadeTaa.current();
		if (taa != null && taa.outWidth() > 0 && taa.outHeight() > 0) return new int[] {taa.outWidth(), taa.outHeight()};
		return new int[] {Math.max(1, windowWidth), Math.max(1, windowHeight)};
	}

	/** The pause menu's label (short: the button is 204 pixels wide). */
	public static String label() {
		int c = CHOICES[index];
		if (!available()) return ShadeLang.t("Salida: Nativa (DH)", "Output: Native (DH)");
		return c < 0 ? ShadeLang.t("Salida: Nativa", "Output: Native") : ShadeLang.t("Salida: ", "Output: ") + c + "p";
	}

	/** The pause menu button's tooltip. */
	public static String tooltip() {
		return taauMode() ? ShadeLang.t("Resolución de la imagen del mundo; el menú y el texto siguen nítidos. Más baja = más FPS.",
				"Resolution of the world image; the menus and text stay sharp. Lower = more FPS.")
			: ShadeLang.t("Resolución de todo el juego, como la de un monitor (el menú y el texto también). Más baja = más FPS.",
				"Resolution of the whole game, like a monitor's (menus and text too). Lower = more FPS.");
	}

	/** The F3 line's part: "salida 1920x1080" while scaled, else "". */
	public static String debugPart(int outWidth, int outHeight, int mainWidth, int mainHeight) {
		if (outWidth <= 0 || (outWidth == mainWidth && outHeight == mainHeight)) return "";
		return String.format(Locale.ROOT, " → salida %dx%d", outWidth, outHeight);
	}

	/** Next choice (the pause-menu button), saved to config/mcopt.properties and applied. */
	public static void cycle(Path gameDir) {
		index = (index + 1) % CHOICES.length;
		int c = CHOICES[index];
		String value = c < 0 ? "native" : Integer.toString(c);
		System.setProperty("mcopt.shade.output", value);
		save(gameDir.resolve("config").resolve("mcopt.properties"), value);
		apply();
	}

	private static void save(Path file, String value) {
		try {
			List<String> lines = Files.exists(file) ? new ArrayList<>(Files.readAllLines(file, StandardCharsets.UTF_8)) : new ArrayList<>();
			boolean found = false;
			for (int i = 0; i < lines.size(); i++) {
				if (lines.get(i).trim().startsWith("mcopt.shade.output=")) {
					lines.set(i, "mcopt.shade.output=" + value);
					found = true;
				}
			}
			if (!found) {
				lines.add("# Resolución de salida (también desde el menú de pausa): native, 2160, 1440, 1200, 1080, 900");
				lines.add("mcopt.shade.output=" + value);
			}
			Files.createDirectories(file.getParent());
			Files.write(file, lines, StandardCharsets.UTF_8);
		} catch (IOException e) {
			System.out.println("[mcopt] shade: could not save the output resolution choice: " + e);
		}
	}
}
