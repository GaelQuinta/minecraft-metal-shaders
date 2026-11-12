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
package mcopt.metal.shade.light;

import mcopt.metal.shade.Live;
import mcopt.metal.shade.Shade;

/**
 * Dynamic light flags (system properties or config/mcopt.properties, read once at startup; everything needs mcopt.shade=true).
 * (1.1) max, range, strength, spec, entity, hand, others and flicker are read live (every frame, through Live; the startup
 * value below is the default and the clamp is the same); the module, the volumes, the occlusion and the entities' vertex
 * stages stay startup switches (they decide the shaders and the buffers).
 * <ul>
 * <li>{@code mcopt.shade.dynLights} (true): the module. false = M2.1's shaders byte for byte (no define, no bindings).</li>
 * <li>{@code mcopt.shade.dynLights.max} (64): lights per frame (the nearest / strongest win; the local player's hands first).
 * (1.1) live 1..64: a cap only, the buffers stay sized for 64.</li>
 * <li>{@code mcopt.shade.dynLights.range} (48): blocks around the camera lights are gathered from.</li>
 * <li>{@code mcopt.shade.dynLights.volumes} (preset: 8 / 16 / 24 / 32): lights that get a visibility volume (no light through
 * walls); the rest light without occlusion (they are the weakest or farthest).</li>
 * <li>{@code mcopt.shade.dynLights.occlusion} (true): visibility volumes and the block occupancy behind them.</li>
 * <li>{@code mcopt.shade.dynLights.occBudgetUs} (300): CPU time per frame for refreshing the block occupancy.</li>
 * <li>{@code mcopt.shade.dynLights.strength} (1): overall strength; {@code .spec} (1) the glint on water; {@code .entity} (1)
 * the strength on entities, items, block entities and particles.</li>
 * <li>{@code mcopt.shade.dynLights.entities} (true): the game's own vertex stages (entities, items, block entities, particles,
 * text) get the lights in the HDR world target (DynLightMsl).</li>
 * <li>{@code mcopt.shade.dynLights.hand} (true): the local player's first-person hand and body take the light of what it holds.</li>
 * <li>{@code mcopt.shade.dynLights.others} (true): light from other entities (mobs, items, projectiles...); false = only the
 * local player's hands.</li>
 * <li>{@code mcopt.shade.dynLights.flicker} (true): gentle flicker for fire-like lights.</li>
 * <li>{@code mcopt.shade.dynLights.log} (false): a line every 2 s (lights, volumes, occupancy, CPU time).</li>
 * </ul>
 */
public final class DynLightConfig {
	public static final boolean ENABLED = Shade.ENABLED && flag("mcopt.shade.dynLights", true);
	public static final int MAX = clamp(Integer.getInteger("mcopt.shade.dynLights.max", 64), 1, 64);
	public static final float RANGE = floatFlag("mcopt.shade.dynLights.range", 48f, 8f, 60f);
	public static final boolean OCCLUSION = flag("mcopt.shade.dynLights.occlusion", true);
	public static final int VOLUMES = OCCLUSION ? clamp(Integer.getInteger("mcopt.shade.dynLights.volumes", new int[] {8, 16, 24, 32}[Shade.TIER]), 1, 64) : 0;
	/** Lights farther than this from the camera get no visibility volume (their volume must fit the occupancy window). */
	public static final float VOLUME_RANGE = 40f;
	public static final int OCC_BUDGET_US = clamp(Integer.getInteger("mcopt.shade.dynLights.occBudgetUs", 300), 20, 20000);
	public static final float STRENGTH = floatFlag("mcopt.shade.dynLights.strength", 1f, 0f, 4f);
	public static final float SPEC = floatFlag("mcopt.shade.dynLights.spec", 1f, 0f, 4f);
	public static final float ENTITY = floatFlag("mcopt.shade.dynLights.entity", 1f, 0f, 4f);
	public static final boolean ENTITIES = flag("mcopt.shade.dynLights.entities", true);
	public static final boolean HAND = flag("mcopt.shade.dynLights.hand", true);
	public static final boolean OTHERS = flag("mcopt.shade.dynLights.others", true);
	public static final boolean FLICKER = flag("mcopt.shade.dynLights.flicker", true);
	public static final boolean LOG = flag("mcopt.shade.dynLights.log", false);

	private DynLightConfig() {
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

	private static int clamp(int v, int min, int max) {
		return Math.max(min, Math.min(max, v));
	}

	/** (1.1) live: mcopt.shade.dynLights.max (MAX at startup), 1..64: the cap on this frame's lights (DynLights.MAX sizes the buffer). */
	static int max() {
		return clamp(Live.i("mcopt.shade.dynLights.max", MAX), 1, 64);
	}

	/** (1.1) live: mcopt.shade.dynLights.range (RANGE at startup), 8..60 blocks. */
	static float range() {
		return Live.f("mcopt.shade.dynLights.range", RANGE, 8f, 60f);
	}

	/** (1.1) live: mcopt.shade.dynLights.strength (STRENGTH at startup), 0..4. */
	static float strength() {
		return Live.f("mcopt.shade.dynLights.strength", STRENGTH, 0f, 4f);
	}

	/** (1.1) live: mcopt.shade.dynLights.spec (SPEC at startup), 0..4. */
	static float spec() {
		return Live.f("mcopt.shade.dynLights.spec", SPEC, 0f, 4f);
	}

	/** (1.1) live: mcopt.shade.dynLights.entity (ENTITY at startup), 0..4. */
	static float entity() {
		return Live.f("mcopt.shade.dynLights.entity", ENTITY, 0f, 4f);
	}

	/** (1.1) live: mcopt.shade.dynLights.hand (HAND at startup): the local player's held light and its hand / body taking it. */
	static boolean hand() {
		return Live.b("mcopt.shade.dynLights.hand", HAND);
	}

	/** (1.1) live: mcopt.shade.dynLights.others (OTHERS at startup). */
	static boolean others() {
		return Live.b("mcopt.shade.dynLights.others", OTHERS);
	}

	/** (1.1) live: mcopt.shade.dynLights.flicker (FLICKER at startup). */
	static boolean flicker() {
		return Live.b("mcopt.shade.dynLights.flicker", FLICKER);
	}

	static String describe() {
		return "max " + MAX + ", range " + RANGE + ", volumes " + VOLUMES + ", entities " + ENTITIES + ", hand " + HAND + ", others " + OTHERS
			+ (STRENGTH != 1f ? ", strength " + STRENGTH : "");
	}

	/** dynlight.metal's kernels + dynlight_vis.metal, the module's own library (DynLights.init). */
	public static String source() {
		return "#define SHADE_DL_KERNELS\n" + mcopt.metal.shade.ShadeMsl.resource("torch_light.metal") + "\n" + mcopt.metal.shade.ShadeMsl.resource("dynlight.metal") + "\n" + mcopt.metal.shade.ShadeMsl.resource("dynlight_vis.metal");
	}
}
