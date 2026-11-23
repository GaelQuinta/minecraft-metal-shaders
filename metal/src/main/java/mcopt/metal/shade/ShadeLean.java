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

/**
 * M3.1: which module code this frame's terrain can do without. The M3 modules put their terrain code behind runtime
 * branches (the Nether / End lighting, the wet surfaces, the dynamic lights), and that code weighs on every terrain pixel
 * even where it never runs (registers, occupancy: ~1 ms at balanced, measured 2026-10-08). The world pass therefore draws
 * with a tagged HDR format (ShadeMsl.LEAN_*), and the Sodium terrain pipelines get one variant per tag with that code
 * compiled out (sodium_terrain.fs.metal SHADE_LEAN_OW / _DRY / _NODL); every other pipeline ignores the tag
 * (ShadeMsl canonical). The eight variants are built on the compile worker as the terrain pipelines compile (prewarm),
 * so switching (rain starts, a torch comes into the hand) does not stall a frame.
 */
public final class ShadeLean {
	/** mcopt.shade.lean (true): false draws every frame with the full terrain (M3.0). */
	public static final boolean ON = ShadeConfig.flag("mcopt.shade.lean", true);
	/**
	 * mcopt.shade.leanAbove (true, 2026-10-08; read every frame, for in-session prices): the water's variant without its view
	 * from below while the camera is above water.
	 */
	static boolean above() {
		return ON && !"false".equals(System.getProperty("mcopt.shade.leanAbove"));
	}
	/** mcopt.shade.leanSky (true): the sky's variant without the aurora code while no aurora shows (LEAN_NOAURORA). */
	public static final boolean SKY = ShadeConfig.flag("mcopt.shade.leanSky", true);
	/**
	 * 2026-10-08 (optimisation pricing, off unless set): -Dmcopt.shade.leanDev=NAME[,NAME...] defines those in the translucent
	 * terrain's LEAN_DEV variants, which the world pass uses while the system property mcopt.shade.leanDev.on is true (read every
	 * frame): compile-time variants of the water A/B'd inside one session (mcbench.ab phases).
	 */
	public static final String DEV_DEFINES = devDefines(System.getProperty("mcopt.shade.leanDev", ""));
	private static volatile int tag;
	/** (1.2.9) This frame's water-off bits (ShadeMsl.WOFF_*, unshifted), 0 when none or off; see waterOff(). */
	private static volatile int waterOff;

	/**
	 * (1.2.9, issue #68) The water settings the player turned off, as ShadeMsl.WOFF_* bits (unshifted): the translucent terrain's
	 * variant then has that code compiled out. Only with the camera above water in the overworld (LEAN_ABOVE: the variants that
	 * draw the surface from above); -Dmcopt.shade.leanWater=false (read every frame) turns it off, for in-session A/B.
	 */
	public static int waterOff() {
		return ON ? waterOff : 0;
	}

	private static int waterOffNow() {
		if ("false".equals(System.getProperty("mcopt.shade.leanWater"))) return 0;
		if (!mcopt.metal.shade.water.ShadeWater.ON) return 0;
		return mcopt.metal.shade.water.ShadeWater.offBits();
	}

	private static String devDefines(String v) {
		StringBuilder b = new StringBuilder();
		for (String d : v.split(",")) {
			String t = d.trim();
			if (t.matches("[A-Z][A-Z0-9_]*")) b.append("#define ").append(t).append(" 1\n");
		}
		return b.toString();
	}

	private ShadeLean() {
	}

	/** This frame's lean tag (ShadeMsl.LEAN_OW | LEAN_DRY | LEAN_NODL | LEAN_NETHER), 0 when off. */
	public static int tag() {
		return (ON ? tag & (ShadeMsl.LEAN_TERRAIN | ShadeMsl.LEAN_WATER) : 0) | (SKY ? tag & ShadeMsl.LEAN_NOAURORA : 0);
	}

	/** Once per frame, after the weather and the dynamic lights updated, before the world pass (ShadeFrameUpdater). */
	static void update(int dimension, boolean underwater) {
		int t = 0;
		if (dimension == ShadeFrame.DIM_OVERWORLD) t |= ShadeMsl.LEAN_OW;
		// 2026-10-08: the camera above water (the overworld; the variants are prewarmed with OW only): the translucent terrain
		// without the surface seen from below (it only runs with the camera under water)
		if (dimension == ShadeFrame.DIM_OVERWORLD && !underwater && above()) {
			t |= ShadeMsl.LEAN_ABOVE;
			if (!DEV_DEFINES.isEmpty() && Boolean.getBoolean("mcopt.shade.leanDev.on")) t |= ShadeMsl.LEAN_DEV;
		}
		waterOff = (t & ShadeMsl.LEAN_ABOVE) != 0 ? waterOffNow() : 0;
		// (FT2.11) the overworld's water without the moving water's look while there is no moving water near (WaterFlowScan), or the look
		// is off (mcopt.shade.water.falls=0)
		if (dimension == ShadeFrame.DIM_OVERWORLD && (!mcopt.metal.shade.water.WaterFlowScan.near()
			|| mcopt.metal.shade.vl.VlConfig.live("mcopt.shade.water.falls", 1f) <= 0f)) t |= ShadeMsl.LEAN_NOFALLS;
		if (dimension == ShadeFrame.DIM_NETHER && mcopt.metal.shade.dims.ShadeDims.netherLean()) t |= ShadeMsl.LEAN_NETHER; // M3.3 (dims)
		if (!mcopt.metal.shade.weather.ShadeWeather.ON || mcopt.metal.shade.weather.ShadeWeather.dry()) t |= ShadeMsl.LEAN_DRY;
		if (!mcopt.metal.shade.light.DynLights.ON || mcopt.metal.shade.light.DynLights.activeCount() == 0) t |= ShadeMsl.LEAN_NODL;
		// (M3.3 dims: also while the reduced-resolution aurora pass runs: the sky then only reads its texture)
		if (mcopt.metal.shade.dims.DimsConfig.aurora() == 0 || mcopt.metal.shade.dims.ShadeDims.aurora() <= 0.002f
			|| mcopt.metal.shade.dims.ShadeAurora.active()) t |= ShadeMsl.LEAN_NOAURORA;
		tag = t;
	}
}
