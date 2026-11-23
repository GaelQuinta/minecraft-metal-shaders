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

/**
 * (1.2.9 look pass, 2026-11-23) The "new atmosphere": the daytime mood moved toward Photon's (study in
 * work/notes/2026-11-23/photon), our nights, auroras, coloured lights and god rays kept. Master switch {@code mcopt.shade.look2}
 * (live, default true; false = the 1.2.8 look, "Clásica (1.2.8)" on the settings screen). Every item has its own live strength
 * {@code mcopt.shade.look2.<item>} (1 = the new look's value, 0 = the 1.2.8 behaviour of that item), read through {@link #k}, which
 * is 0 for every item while the master switch is off: each consumer blends classic -> new by it, so off is exactly the old code
 * path's numbers.
 * <ul>
 * <li>sunTint: the pink-gold light of a low sun (ShadeLook.update, CloudParams)</li>
 * <li>shade: weaker sky and bounce fill by day (deeper shade; ShadeLook)</li>
 * <li>exposure: evenings darker than noon, a less lifted dark end (ShadeLook)</li>
 * <li>sheen: grass, plants and leaves glow against the sun (ShadeLook.LOOK2A.x, shade_m2.metal shadeLit2)</li>
 * <li>clouds: higher base, finer detail, darker undersides, gold at sunset (CloudConfig, CloudParams)</li>
 * <li>sky: a deeper blue by day, a blue-violet blue hour (ShadeLook.LOOK2B, sky_lut.metal)</li>
 * <li>water: clearer water, a little less reflection (ShadeSettings defaults)</li>
 * <li>rain: a blue-teal overcast instead of grey-lavender (ShadeLook grade)</li>
 * </ul>
 */
public final class Look2 {
	public static final String KEY = "mcopt.shade.look2";

	private Look2() {
	}

	/** The master switch (live). */
	public static boolean on() {
		return Live.b(KEY, true);
	}

	/** An item's strength: 0 with the switch off, else mcopt.shade.look2.item (live, 1 = the new look). */
	public static float k(String item) {
		return on() ? Live.f(KEY + "." + item, 1f, 0f, 3f) : 0f;
	}

	/** A tuning value of the new look (live): mcopt.shade.look2.name, def when unset. */
	public static float v(String name, float def, float min, float max) {
		return Live.f(KEY + "." + name, def, min, max);
	}

	/** Chroma power on a light colour (ShadeLook.gradeLight without the multiplier): luminance kept, the colour deepened by gamma > 1. */
	public static void chroma(float[] c, float gamma) {
		ShadeLook.gradeLight(c, gamma, 1f);
	}

	/**
	 * The low sun's pink-gold tint (multiplier, luminance-neutral) at sin(sun elevation) sunY, times strength s: a rose-gold with
	 * less green than red and blue, in from about -13 to 35 degrees of sun, strongest near 10. Constants adapted from Photon Shaders
	 * by Benjamin Stott ("sixthsurge"), MIT License, commit 26c2906e (full text: LICENSES/MIT-Photon.txt):
	 * include/lighting/colors/light_color.glsl get_sun_tint (morning_evening_tint and its sqr(pulse(sun_dir.y, 0.17, 0.40)) weight).
	 */
	public static void sunTint(float sunY, float s, float[] out) {
		float p = Math.max(0f, 1f - Math.abs(sunY - v("tintCentre", 0.17f, -0.2f, 0.6f)) / v("tintWidth", 0.40f, 0.05f, 1f));
		float w = Math.min(p * p * s, 1.5f);
		// (1.05, 0.84, 0.93) normalised to luma 1: the light's brightness stays ours (exposure is item 3's job)
		float r = 1.05f, g = 0.84f, b = 0.93f, l = 0.2126f * r + 0.7152f * g + 0.0722f * b;
		out[0] = 1f + (r / l - 1f) * w;
		out[1] = 1f + (g / l - 1f) * w;
		out[2] = 1f + (b / l - 1f) * w;
	}
}
