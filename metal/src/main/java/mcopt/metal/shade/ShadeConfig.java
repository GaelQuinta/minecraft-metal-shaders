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

import java.util.Locale;

/**
 * M2 flags, read once at startup from system properties (config/mcopt.properties becomes system properties first, see
 * Profile). Everything is off unless mcopt.shade=true; each M2 feature then has its own switch:
 * <ul>
 * <li>{@code mcopt.shade.hdr} (true): the world renders into an HDR target (mcopt.shade.hdrFormat: auto = rg11b10f for
 * performance and rgba16f from balanced up (1.2.7: balanced too, for the swaying leaves' motion), or either explicitly) and is tone-mapped ("Shade Filmic") into the game's main target before the hand and the GUI. false:
 * M1's in-shader tone curve into RGBA8 (bloom and auto-exposure need HDR). Off by itself with mcopt.lod (far terrain draws
 * with its own RGBA8 pipelines).</li>
 * <li>{@code mcopt.shade.bloom} (true): natural bloom + fog glow.</li>
 * <li>{@code mcopt.shade.exposure} (auto): auto = bounded auto-exposure around the time-of-day reference; fixed = the
 * reference only.</li>
 * <li>{@code mcopt.shade.pcss} (true): contact-hardening soft shadows on the near cascade.</li>
 * <li>{@code mcopt.shade.stars} (true): procedural sun disc, moon with phases, stars and Milky Way (vanilla's moon and stars
 * dropped).</li>
 * <li>{@code mcopt.shade.haze} (true): height haze, ground mist, border fog.</li>
 * <li>{@code mcopt.shade.light2} (true): lighting model v2.</li>
 * <li>{@code mcopt.shade.look} (epic): epic, storybook or natural art preset.</li>
 * <li>{@code mcopt.shade.preset} (Shade.PRESET_DEFAULT, balanced): performance, balanced, quality or ultra (Shade.TIER: bloom
 * levels, HDR format and every module's defaults).</li>
 * <li>{@code mcopt.shade.dhBridge} (true): Distant Horizons' passes see a display-referred copy of the HDR sky and their
 * result comes back into the HDR target (ShadePost).</li>
 * <li>{@code mcopt.shade.ev} (0): exposure compensation in EV.</li>
 * </ul>
 */
public final class ShadeConfig {
	public static final boolean LOD = Boolean.parseBoolean(System.getProperty("mcopt.lod", "false"));
	public static final boolean HDR = Shade.ENABLED && flag("mcopt.shade.hdr", true) && !LOD;
	/**
	 * MTLPixelFormat of the HDR world target: RG11B10Float (92, half the bandwidth: -0.2..0.45 ms at native Retina, no visible
	 * banding in A/B screenshots) or RGBA16Float (115). mcopt.shade.hdrFormat: auto (default: rg11b10f for the performance preset,
	 * rgba16f from balanced up), rg11b10f or rgba16f. (1.2.7 candidate 7, Gael's choice 2026-11-09: balanced moved to rgba16f: its alpha
	 * carries the swaying leaves' flag to the TAA (ShadeTaa leafMotion), backlit canopies flicker 40-47 % less, -4.5 % fps.)
	 */
	public static final int HDR_FORMAT = hdrFormat();
	public static final boolean BLOOM = HDR && flag("mcopt.shade.bloom", true);
	public static final boolean AUTO_EXPOSURE = HDR && !"fixed".equalsIgnoreCase(System.getProperty("mcopt.shade.exposure", "auto").trim());
	public static final boolean PCSS = flag("mcopt.shade.pcss", true);
	public static final boolean STARS = flag("mcopt.shade.stars", true);
	public static final boolean HAZE = flag("mcopt.shade.haze", true);
	public static final boolean LIGHT2 = flag("mcopt.shade.light2", true);
	public static final boolean DH_BRIDGE = HDR && flag("mcopt.shade.dhBridge", true);
	public static final float EV = floatFlag("mcopt.shade.ev", 0f, -4f, 4f);
	public static final int LOOK = switch (System.getProperty("mcopt.shade.look", "epic").trim().toLowerCase(Locale.ROOT)) {
		case "storybook" -> 1;
		case "natural" -> 2;
		default -> 0;
	};
	public static final int TIER = Shade.TIER;
	/** Bloom levels (half size down to 1/2^levels). */
	public static final int BLOOM_LEVELS = TIER >= 2 ? 7 : 6;

	private ShadeConfig() {
	}

	private static int hdrFormat() {
		String v = System.getProperty("mcopt.shade.hdrFormat", "auto").trim().toLowerCase(Locale.ROOT);
		if (v.equals("rg11b10f")) return 92;
		if (v.equals("rgba16f")) return 115;
		return Shade.TIER >= 1 ? 115 : 92;
	}

	static boolean flag(String key, boolean fallback) {
		String v = System.getProperty(key);
		return v == null ? fallback : Boolean.parseBoolean(v.trim());
	}

	static float floatFlag(String key, float fallback, float min, float max) {
		try {
			String v = System.getProperty(key);
			return v == null ? fallback : Math.max(min, Math.min(max, Float.parseFloat(v.trim())));
		} catch (NumberFormatException e) {
			return fallback;
		}
	}

	static String describe() {
		return "hdr " + (HDR ? (HDR_FORMAT == 92 ? "rg11b10f" : "rgba16f") : "off") + ", bloom " + BLOOM + ", exposure " + (AUTO_EXPOSURE ? "auto" : "fixed")
			+ ", pcss " + PCSS + ", sky " + STARS + ", haze " + HAZE + ", light v2 " + LIGHT2 + ", look " + new String[] {"epic", "storybook", "natural"}[LOOK]
			+ ", preset " + new String[] {"performance", "balanced", "quality", "ultra"}[TIER] + (LOD ? " (mcopt.lod on: no HDR)" : "");
	}
}
