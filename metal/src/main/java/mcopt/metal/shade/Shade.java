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
 * mcopt native shading ("Shaders on Metal"): original MSL lighting, shadows and sky inside the Metal backend. Everything
 * is off unless -Dmcopt.shade=true (or mcopt.shade=true in config/mcopt.properties, which Profile turns into the same
 * system property before any of this loads); off, the backend is byte-for-byte upstream: no mixin of ours applies, the
 * registry stays empty, the bind hooks are dead code behind a static final false.
 *
 * <p>Flags (read once at startup):
 * <ul>
 * <li>{@code mcopt.shade} (false): the switch. Needs the Metal backend (not with -Dmcopt.metal=false).</li>
 * <li>{@code mcopt.shade.shadows} (true): sun/moon shadow maps (the shadow pass, mcopt.metal.shade.shadow).</li>
 * <li>{@code mcopt.shade.shadowRes} (2048): shadow map size per cascade.</li>
 * <li>{@code mcopt.shade.shadowDist} (128): shadow distance in blocks.</li>
 * <li>{@code mcopt.shade.debug} (0): 1 shadow visibility and cascades, 2 normals, 3 lighting only (grey albedo).</li>
 * <li>{@code mcopt.shade.sunTilt} (30): sun path tilt in degrees (ShadeSky.SUN_TILT); 0 = vanilla's overhead path.</li>
 * <li>{@code mcopt.shade.dev} (0): feature-off bits for pricing in game (SHADE_DEV_* in shade_common.metal).</li>
 * <li>Shadow pass details (cascades, casters, bias): mcopt.metal.shade.shadow.ShadowConfig.</li>
 * </ul>
 *
 * <p>This class stays free of game types: the mixin plugin loads it while mixins bootstrap.
 *
 * <p>Pieces: ShadeFrame (per-frame uniforms, buffer 16), ShadeFrameUpdater (fills it at LevelRenderer.render HEAD),
 * ShadeBindings (binds buffer 16, texture 16/17, samplers 12/13 on every render encoder; the sky LUT pass), ShadeMsl (the
 * in-jar MSL registered for Sodium terrain and the sky pipelines), the face-shade-off mixin, and the shadow pass.
 */
public final class Shade {
	/** Native shading on: mcopt.shade=true and the Metal backend not turned off. */
	public static final boolean ENABLED = Boolean.getBoolean("mcopt.shade") && Boolean.parseBoolean(System.getProperty("mcopt.metal", "true"));
	/** Sun shadows (mcopt.shade.shadows, default true); the shadow pass's own settings are in shadow.ShadowConfig. */
	public static final boolean SHADOWS = ENABLED && Boolean.parseBoolean(System.getProperty("mcopt.shade.shadows", "true"));
	public static final int DEBUG = Integer.getInteger("mcopt.shade.debug", 0);
	/**
	 * The quality preset every module reads its defaults from (mcopt.shade.preset: performance | balanced | quality | ultra,
	 * or p/b/q/u): render scale and dynamic resolution (TAAU), HDR format, bloom levels, volumetric light resolution and
	 * steps, SSR steps, shadow map size. Default {@link #PRESET_DEFAULT}; unknown names fall back to it.
	 */
	public static final String PRESET_DEFAULT = "balanced";
	public static final int TIER = tier(System.getProperty("mcopt.shade.preset", PRESET_DEFAULT));
	public static final String PRESET = new String[] {"performance", "balanced", "quality", "ultra"}[TIER];

	private static int tier(String name) {
		return switch (name.trim().toLowerCase(java.util.Locale.ROOT)) {
			case "performance", "p" -> 0;
			case "balanced", "b" -> 1;
			case "quality", "q" -> 2;
			case "ultra", "u" -> 3;
			default -> {
				System.out.println("[mcopt] shade: unknown mcopt.shade.preset '" + name + "', using " + PRESET_DEFAULT);
				yield tier(PRESET_DEFAULT);
			}
		};
	}
	/** Sun path tilt in degrees (mcopt.shade.sunTilt); see ShadeSky.SUN_TILT. */
	public static final float SUN_TILT = ShadeSky.SUN_TILT;

	/** Celestial direction for SkyRenderState angle a, tilted by SUN_TILT; see ShadeSky.celestial. */
	public static void celestial(double angle, double[] out) {
		ShadeSky.celestial(angle, out);
	}

	/** Vertex colours without vanilla's directional face shade (the shaders light faces themselves); see mixin.shade.ShadeFaceShadeMixin and ShadeFrameUpdater.faceShadeOff. */
	private static volatile boolean faceShadeOff = ENABLED;
	private static boolean initialized;

	private Shade() {
	}

	/** Early setup, from the shade mixin plugin (before the game's classes load): registers the shaded MSL. */
	public static synchronized void init() {
		if (initialized || !ENABLED) return;
		initialized = true;
		ShadeMsl.register();
		// Shaded frames take ~4 ms of GPU: presenting from the frame's own command buffer then holds drawables long enough
		// that nextDrawable blocks the render thread (the 1% lows). Present (and acquire) on mcopt's second queue instead,
		// unless the user chose otherwise.
		if (System.getProperty("mcopt.metal.presentQueue") == null) System.setProperty("mcopt.metal.presentQueue", "acquire");
		// (2.0.1e) With VSync (FIFO) on, present directly on the render thread instead of routing through presentQueue=acquire
		// (which bypasses VSync back-pressure and drops/skips frames while reporting 120 fps), and avoid fighting hardware VSync
		// with a drifting software frame cap when framerateLimit >= the display's refresh rate. VSync-off is unchanged.
		if (System.getProperty("mcopt.metal.vsyncDirect") == null) System.setProperty("mcopt.metal.vsyncDirect", "true");
		if (System.getProperty("mcopt.metal.vsyncLimiter") == null) System.setProperty("mcopt.metal.vsyncLimiter", "true");
		// (2.0.1f) Under direct FIFO VSync, cap in-flight submits to 1 (2 total with current, while CAMetalLayer keeps 3 drawables
		// so ProMotion stays at 120 Hz) and enforce a minimum frame spacing floor (~96% of refresh period = 8.0 ms at 120 Hz):
		// prevents the 3-drawable FIFO queue from collapsing into 2 ms + 14 ms (60 Hz) frame pairs when GPU time nears 8.33 ms.
		if (System.getProperty("mcopt.metal.vsyncInFlight") == null) System.setProperty("mcopt.metal.vsyncInFlight", "1");
		if (System.getProperty("mcopt.metal.vsyncMinPace") == null) System.setProperty("mcopt.metal.vsyncMinPace", "0.96");
		// (1.1.1, macOS 27) VSync off: the paced presents (one per refresh) still wait for a vblank, as with VSync. Without display
		// sync a present that goes direct to the display (fullscreen) can land mid-scanout (tearing), and on the 120 Hz panel
		// paced presents reached the screen in pairs (MetalSurface.PACE_SYNC). The game still renders every frame. And the
		// refresh grid follows the display the window is on (MetalSurface.PACE_FOLLOW).
		if (System.getProperty("mcopt.metal.paceSync") == null) System.setProperty("mcopt.metal.paceSync", "true");
		if (System.getProperty("mcopt.metal.paceFollow") == null) System.setProperty("mcopt.metal.paceFollow", "true");
		System.out.println("[mcopt] shade: native shading on (shadows " + SHADOWS + ", " + mcopt.metal.shade.shadow.ShadowConfig.RES + " px, "
			+ mcopt.metal.shade.shadow.ShadowConfig.DIST + " blocks"
			+ (DEBUG != 0 ? ", debug view " + DEBUG : "") + ")");
	}

	public static boolean faceShadeOff() {
		return faceShadeOff;
	}

	/**
	 * Turns vanilla's baked face shade off (true) or back on, rebuilding every chunk when it changes (the shade is baked
	 * into the vertex colours at meshing time). The terrain shaders assume it off in the overworld.
	 */
	public static void setFaceShadeOff(boolean off) {
		if (faceShadeOff == off) return;
		faceShadeOff = off;
		ShadeFrameUpdater.rebuildChunks();
	}

	/** This frame's uniform values (the shadow pass reads the light direction and writes its matrices with setShadow). */
	public static ShadeFrame frame() {
		return ShadeFrameUpdater.FRAME;
	}
}
