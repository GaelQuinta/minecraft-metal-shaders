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
 * The <b>Fantasy</b> style (mcopt.shade.look=fantasy, the fourth of ShadeSettings.LOOKS) and its own switches. A stylized,
 * storybook-lit look that bends the lighting maths away from photometric PBR instead of adding more of it:
 * <ul>
 * <li><b>Soft terminator, lifted shadows</b> (shade_m2.metal shadeSunShape and shadeFantasyFill): instead of a hard
 * {@code max(N.L, 0)} the diffuse term is a smoothstep, so the day/night line of a hill is a soft gradient, and the sky's fill
 * turns violet-indigo (a "twilight" colour) rather than the shade fading to grey or black. {@code mcopt.shade.fantasy.softness},
 * {@code .shadowTint}.</li>
 * <li><b>Golden sunlight</b> (ShadeLook.update): the direct light gets a warmer chroma and a little more energy by day, so lit
 * surfaces read golden against the cooler shade.</li>
 * <li><b>Broader block light</b> (shade_m2.metal, the F(b) curve): the torch falloff keeps more of its energy far from the
 * light, so a lantern's pool is bigger and softer and the coloured lights (soul torches, amethyst, portals) read on more
 * blocks. {@code mcopt.shade.fantasy.blockLight}.</li>
 * <li><b>Low valley mist</b> (ShadeLook.pack): the mist layer sits lower and is denser, so rivers, valleys and forest floors
 * gather a morning haze while the hills above stay clear. {@code mcopt.shade.fantasy.mist}.</li>
 * <li><b>Painterly brush</b> (fantasy.metal, ShadePainterly): an optional structure-tensor + 8-sector oriented Kuwahara pass
 * that turns the frame into broad painted strokes, with a paper grain. Off by default (0 = the passes are not even encoded, so
 * it costs nothing) and independent of the style, so it can be tried with any look. {@code mcopt.shade.fantasy.painterly},
 * {@code .brush}.</li>
 * </ul>
 * Everything is live. Like Look2, the style is the master switch for the lighting items: {@link #k} is 0 for every item while
 * another style is selected, so epic / storybook / natural keep their exact numbers and this file costs them nothing.
 */
public final class Fantasy {
	public static final String KEY = "mcopt.shade.fantasy";
	/** ShadeSettings.LOOKS index of "fantasy". */
	public static final int LOOK = 3;
	/** The painterly brush (0..1), independent of the style; 0 by default. */
	public static final String PAINTERLY = KEY + ".painterly";

	private Fantasy() {
	}

	/** Whether the Fantasy style is the one selected (live). */
	public static boolean style() {
		return ShadeSettings.look() == LOOK;
	}

	/** An item's strength: 0 unless the Fantasy style is selected, else mcopt.shade.fantasy.item (live, 1 = the look's value). */
	public static float k(String item) {
		return style() ? Live.f(KEY + "." + item, 1f, 0f, 2f) : 0f;
	}

	/** A tuning value of the look (live): mcopt.shade.fantasy.name, def when unset. */
	public static float v(String name, float def, float min, float max) {
		return Live.f(KEY + "." + name, def, min, max);
	}

	/** Painterly brush strength 0..1, any style (0 = the painterly passes are skipped entirely on the command encoder). */
	public static float painterly() {
		return Live.f(PAINTERLY, 0f, 0f, 1f);
	}

	/** The brush's radius in output pixels (2.0..5.0; it shrinks with distance in the shader, kept small for M-series occupancy). */
	public static float brushRadius() {
		return Live.f(KEY + ".brush", 3.0f, 2.0f, 5.0f);
	}

	/** The paper grain mixed into the painted image (0 = none). */
	public static float grain() {
		return Live.f(KEY + ".grain", 0.35f, 0f, 1f);
	}

	/**
	 * A 0..1 post-effect strength of the style (live, mcopt.shade.fantasy.<name>): the split-tone grade, the shadow toe's lift
	 * and the bloom-vignette coupling (ShadeLook packs them at FANTASY_POST; see shadeSplitTone in shade_look.metal and
	 * shadeFinalEncode / shadeFinalScene in shade_post.metal). 0 disables each effect on the GPU with one compare.
	 */
	public static float pct(String name, float def, float min, float max) {
		return Live.f(KEY + "." + name, def, min, max);
	}

}
