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
package mcopt.metal.shade.water;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import mcopt.metal.shade.Shade;
import mcopt.metal.shade.ShadeMsl;
import org.lwjgl.system.MemoryUtil;

/**
 * Native shading's water and reflections module (shader bible E14, E15 basics, E26 surface): animated waves, Fresnel,
 * screen-space reflections with a sky fallback, refraction, Beer-Lambert absorption from the biome's water colour,
 * shoreline foam, caustics on the bottom, and the surface seen from below (Snell's window, total internal reflection).
 *
 * <p>How it plugs in:
 * <ul>
 * <li>The scene copy (bible hook H6): MetalRenderPass.setPipeline calls {@link #capture} when a main pass (one with depth)
 * switches to {@code sodium:pipeline/translucent_terrain}; mcwater.m copies colour attachment 0 and depth there.</li>
 * <li>The shader: ShadeMsl.terrain prepends {@link #prelude} (defines + water.metal) to the translucent terrain fragment
 * only; sodium_terrain.fs.metal's water branch calls shadeWaterSurface (water.metal) when SHADE_WATER is defined.</li>
 * <li>The bindings (texture 18/19, buffer 23, fragment stage): {@link #bind} on every encoder ShadeBindings binds.</li>
 * <li>Per frame: {@link #frame} from ShadeFrameUpdater (WaterFrame has the game-typed part: sprite rectangles, the water
 * surface above the eye).</li>
 * </ul>
 *
 * <p>Flags (system properties or config/mcopt.properties, read once at startup; all need mcopt.shade=true):
 * <ul>
 * <li>{@code mcopt.shade.water} (true): the module. False = M1's still-water stand-in, byte-identical shaders.</li>
 * <li>{@code mcopt.shade.ssr} (true): screen-space reflections (false: sky and sun reflections only).</li>
 * <li>{@code mcopt.shade.ssrSteps} (24): SSR march steps (4-64), plus 4 binary refinement steps. With quad SSR the four
 * pixels of a quad share them (6 each).</li>
 * <li>{@code mcopt.shade.ssrQuad} (true): the 2x2 pixels of a quad trace one reflection ray together (half-resolution SSR
 * at a quarter of the cost; false: one ray per pixel).</li>
 * <li>{@code mcopt.shade.ssrDist} (512): SSR maximum ray length in blocks (the march is in screen space, so a long ray costs
 * no more steps; it lets distant hills and shores mirror in open water at sunset).</li>
 * <li>{@code mcopt.shade.waterWaves} (1.0): wave strength (0 = flat mirror).</li>
 * <li>{@code mcopt.shade.caustics} (true): caustics on the bottom seen through the surface.</li>
 * <li>{@code mcopt.shade.waterFoam} (true): shoreline foam.</li>
 * <li>{@code mcopt.shade.waterReflect} (1.0): reflection strength (artistic scale on the Fresnel term).</li>
 * <li>{@code mcopt.shade.waterDetail} (true, M2.1): fine ripples (their own faster baked layer), pixel-scale ripple pattern, calmer long
 * waves, softer refraction.</li>
 * <li>{@code mcopt.shade.ssrEdge} (true, M2.1): reflections reach the left and right screen edges.</li>
 * <li>{@code mcopt.shade.waterClock} (true, M2.1): the waves run on real time (smooth) instead of the game time.</li>
 * <li>{@code mcopt.shade.glossy} (false, opt-in until checked in game: the bench world has no ice or stained glass): stained
 * glass, ice, slime and honey get mirror reflections (sky, SSR, sun) too.</li>
 * </ul>
 *
 * <p>Free of game types (ShadeMsl, which the shade mixin plugin loads early, reads {@link #prelude}).
 */
public final class ShadeWater {
	/** The module's flag on its own (what ShadeMsl assembles the MSL by; validation tools run without mcopt.shade). */
	public static final boolean MODULE = Boolean.parseBoolean(System.getProperty("mcopt.shade.water", "true"));
	/** The module is live: shading on and the flag on. The backend's hooks test this static final. */
	public static final boolean ON = Shade.ENABLED && MODULE;
	public static final boolean SSR = Boolean.parseBoolean(System.getProperty("mcopt.shade.ssr", "true"));
	/** Preset defaults (Shade.TIER): quad-shared (half-resolution) SSR except ultra; steps 16 / 24 / 24 / 32 (TAAU integrates the per-frame step jitter). */
	public static final boolean SSR_QUAD = Boolean.parseBoolean(System.getProperty("mcopt.shade.ssrQuad", Shade.TIER >= 3 ? "false" : "true"));
	public static final int SSR_STEPS = Math.clamp(Integer.getInteger("mcopt.shade.ssrSteps", new int[] {16, 24, 24, 32}[Shade.TIER]), 4, 64);
	public static final float SSR_DIST = Math.clamp(floatProperty("mcopt.shade.ssrDist", 512f), 8f, 1024f);
	public static final float WAVES = Math.clamp(floatProperty("mcopt.shade.waterWaves", 1f), 0f, 4f);
	public static final boolean CAUSTICS = Boolean.parseBoolean(System.getProperty("mcopt.shade.caustics", "true"));
	public static final boolean FOAM = Boolean.parseBoolean(System.getProperty("mcopt.shade.waterFoam", "true"));
	public static final float REFLECT = Math.clamp(floatProperty("mcopt.shade.waterReflect", 1f), 0f, 2f);
	public static final boolean GLOSSY = Boolean.parseBoolean(System.getProperty("mcopt.shade.glossy", "false"));
	/**
	 * M2 HDR: reflections read last frame's finished HDR world (ShadeResources.prevScene): SSR hit colours (clouds,
	 * translucents, far LODs included) and the rendered sky in the reflected direction where it is on screen.
	 */
	/** The waves baked once per frame into a mipmapped texture (false: 7 analytic waves per pixel, as on m2-water). */
	public static final boolean BAKE = Boolean.parseBoolean(System.getProperty("mcopt.shade.waterBake", "true"));
	/**
	 * The baked wave texture's size (mcopt.shade.waterBakeSize; preset default 512 for performance and balanced, 1024 for
	 * quality and ultra): 512 still gives the shortest wave (0.62 blocks) about 5 texels, at a quarter of the bake's cost.
	 */
	public static final int BAKE_SIZE = Integer.getInteger("mcopt.shade.waterBakeSize", Shade.TIER >= 2 ? 1024 : 512) >= 1024 ? 1024 : 512;
	public static final boolean SSR_PREV = Boolean.parseBoolean(System.getProperty("mcopt.shade.ssrPrev", "true"));
	/**
	 * M2.1: fine ripples (a second, smaller and rotated sample of the baked waves), a pixel-scale ripple pattern near the camera
	 * (1/16-block cells, smooth in time), calmer long waves and a smaller refraction shift (false: M2's surface).
	 */
	public static final boolean DETAIL = Boolean.parseBoolean(System.getProperty("mcopt.shade.waterDetail", "true"));
	/** The fine-ripple layer's bake size (256 or 512) and whether it bakes the 7 extra waves too (dev knobs for pricing). */
	public static final int DETAIL_SIZE = Integer.getInteger("mcopt.shade.waterDetailSize", 256) >= 512 ? 512 : 256;
	/** (FT1.3: on by default with the photon style, whose stronger ripples showed the 7 main waves' lattice) */
	private static final boolean DETAIL_EXTRAS = Boolean.parseBoolean(System.getProperty("mcopt.shade.waterDetailExtras",
		String.valueOf(!"m21".equals(System.getProperty("mcopt.shade.water.style", "photon")))));
	/** Distance (blocks) beyond which the fine ripples are not sampled (faded from 0.6x of it). */
	/** Footprint (blocks/pixel) where the pixel pattern ends (dev knob). */
	private static final String PATTERN_FAR = System.getProperty("mcopt.shade.waterPatternFar", "0.075");
	private static final int DETAIL_FAR = Math.clamp(Integer.getInteger("mcopt.shade.waterDetailFar",
		"m21".equals(System.getProperty("mcopt.shade.water.style", "photon")) ? 96 : 112), 32, 512); // FT1.3: ripples a little farther out (160 cost ~0.3 ms over the lake, run wpq)
	/**
	 * M2.1: SSR reaches the left and right screen edges: rays that leave through a side keep marching on the edge column,
	 * no side fade on hits, and the far-end fade goes by distance instead of screen length (false: M2's SSR edges).
	 */
	public static final boolean SSR_EDGE = Boolean.parseBoolean(System.getProperty("mcopt.shade.ssrEdge", "true"));
	/**
	 * FT1.2 {@code mcopt.shade.water.edgeRefl} (true; Gael: mirrored clouds deformed at the screen edges and appeared / vanished
	 * there while turning): with the volumetric clouds' reflection dome, the mirrored sky fades into the dome over the last 1/8
	 * of the screen at the sides and the top instead of the edge column standing in past a side, the dome read along the same
	 * calm direction as the rendered sky; and SSR hits that last frame did not see (turning) are hazed like the others. false = M3.4.
	 */
	public static final boolean EDGE_REFL = Boolean.parseBoolean(System.getProperty("mcopt.shade.water.edgeRefl", "true"));
	/**
	 * FT2.6 (Gael's FT2.5 lake: white blocks in the mirrored forest, where rays passed behind trunks and leaves and fell back to
	 * the clouds' dome): the SSR march's thickness in steps' depth extents (mcopt.shade.water.ssrThick, 3 as Photon MIT allows;
	 * FT2.5 1) and, with no hit, the first crossing behind something instead of the sky (mcopt.shade.water.ssrBehind, true).
	 * Lake p6 (bug-ssr3): pixels above 200/255 in the mirrored forest 0.88 % -> 0.05 %; open water (bug-ssrchk): ~1/255. With
	 * -Dmcopt.shade.wdev=true, mcopt.shade.dev variants 2-5 switch them live.
	 */
	public static final float SSR_THICK = Math.clamp(floatProperty("mcopt.shade.water.ssrThick", 3f), 0.5f, 8f);
	public static final boolean SSR_BEHIND = Boolean.parseBoolean(System.getProperty("mcopt.shade.water.ssrBehind", "true"));
	/**
	 * 1.2.7 (water.metal SHADE_SSR_TOP): how far past the top screen edge (NDC) the march goes on against the top row, fading to
	 * nothing there (mcopt.shade.water.ssrTop, 0.15; 0 = candidate 3: the top edge ends it; candidate 4 went 0.5 at half weight and
	 * streaked the top row down the water when looking down at a lake).
	 */
	public static final float SSR_TOP = Math.clamp(floatProperty("mcopt.shade.water.ssrTop", 0.15f), 0.001f, 1f);
	/** (candidate 7, water.metal SHADE_SSR_SIDE / _END) past a side edge: how far (NDC; mcopt.shade.water.ssrSide, 1 = M2.1) and the weight kept there (.ssrSideEnd, 0.5). */
	public static final float SSR_SIDE = Math.clamp(floatProperty("mcopt.shade.water.ssrSide", 1f), 0.001f, 1f);
	public static final float SSR_SIDE_END = Math.clamp(floatProperty("mcopt.shade.water.ssrSideEnd", 0.5f), 0f, 1f);
	/** (candidate 7) the mirrored image's temporal reprojection's code (water.metal SHADE_WATER_RTR; mcopt.shade.water.rtr, startup). */
	public static final boolean RTR = Boolean.parseBoolean(System.getProperty("mcopt.shade.water.rtr", "true"));
	/**
	 * FT1.3 {@code mcopt.shade.water.style}: "photon" (default; Gael: "reflejos pixeleados", "agua como el mar de Photon"):
	 * smooth ripples without M2.1's 1/16-block cells and crest pattern, calmer in clear weather (mcopt.shade.water.calm, 0.55
	 * of the M2.1 slopes; rain brings them back), patches of calmer and rougher water, flatter at grazing angles (a near-mirror
	 * far surface, sharp reflections). "m21" = M3.4's water.
	 */
	public static final boolean SMOOTH = !"m21".equals(System.getProperty("mcopt.shade.water.style", "photon"));
	/** The long waves' calm in clear weather at startup (mcopt.shade.water.calm, 0.05..2; 2026-11-02: read every frame, {@link #frame}). */
	static final float CALM = Math.clamp(floatProperty("mcopt.shade.water.calm", 0.55f), 0.05f, 2f);
	/** FT1.3 style photon: the fine ripples' slopes in clear weather (mcopt.shade.water.ripple, x the M2.1 detail layer; read every frame too). */
	static final float RIPPLE = Math.clamp(floatProperty("mcopt.shade.water.ripple", 2.0f), 0f, 3f);
	/**
	 * M3: the sun glint's distance widening (normals averaging out across a pixel) only at grazing views; from high up the
	 * widened glint of a low sun was a broad glow cut into bright rectangles by the terrain's shadows (false: M2.1's glint).
	 */
	public static final boolean GLINT_GRAZE = Boolean.parseBoolean(System.getProperty("mcopt.shade.waterGlintGraze", "true"));
	/**
	 * M3.4 (Gael, 2026-10-08: "sombras cuadradas en el agua" at sunset): the radius in blocks over which the shadow on an
	 * up-facing water surface is softened (shade_common.metal shadeShadowSoft: 8 taps on the water plane, turned per pixel and
	 * frame). The long shadows of blocky terrain under a low sun cut the sun's glint on the water along their block outline;
	 * waves and the sun's size blur that edge in reality. mcopt.shade.waterShadowSoft (read every frame): 0 = M3.3.
	 */
	public static float shadowSoft() {
		if (!ON) return 0f;
		String v = System.getProperty("mcopt.shade.waterShadowSoft");
		if (v == null) return SHADOW_SOFT_DEFAULT;
		try {
			return Math.clamp(Float.parseFloat(v.trim()), 0f, 8f);
		} catch (NumberFormatException e) {
			return SHADOW_SOFT_DEFAULT;
		}
	}

	/**
	 * FT2.8 (audit idx 97): the soft shadow's penumbra growth with the caster's height above the water, blocks of radius per block
	 * (shade_common.metal shadeShadowCascadeDisc: 0.125 = the full 2 blocks from casters 16 blocks up; banks a block or two above the
	 * water no longer darken a band along the shore). mcopt.shade.waterShadowContact, read every frame; 0 = M3.4's fixed disc.
	 */
	public static float shadowContact() {
		return Math.max(mcopt.metal.shade.vl.VlConfig.live("mcopt.shade.waterShadowContact", 0f), 0f);
	}

	/**
	 * (2026-11-02, water round 1: work/notes/2026-11-02/water/DESIGN.md, ROUND1.md) {@code mcopt.shade.water.swellCode} (false, startup):
	 * the round's per-pixel code compiled into the translucent terrain (water.metal SHADE_WATER_SWELL: the swell, its open-water map,
	 * the light through its crests; SHADE_WATER_GLITTER: the glint's glitter, unless {@code mcopt.shade.water.glitterCode} says
	 * otherwise). The water shader is bound by registers (code that never runs still costs ~0.1-0.3 ms), so it is out unless asked
	 * for; once in, everything it does is read every frame (mcopt.shade.water.swell, .swellMask, .swellFresnel, .swellRefl,
	 * .swellOpen, .swellGlow, .glitter) and its defaults are the look without it. Pricing the code's presence in one session:
	 * -Dmcopt.shade.leanDev=SHADE_WATER_SWELL (and/or SHADE_WATER_GLITTER) with mcopt.shade.leanDev.on (ShadeLean).
	 */
	public static final boolean SWELL_CODE = Boolean.parseBoolean(System.getProperty("mcopt.shade.water.swellCode", "true"));
	/** The glint's glitter's code (water.metal SHADE_WATER_GLITTER, live mcopt.shade.water.glitter): with the swell's unless set on its own. */
	public static final boolean GLITTER_CODE = Boolean.parseBoolean(System.getProperty("mcopt.shade.water.glitterCode", String.valueOf(SWELL_CODE)));
	static final boolean SWELL_DEV = mcopt.metal.shade.ShadeLean.DEV_DEFINES.contains("SHADE_WATER_SWELL ");

	/** Whether the swell's code is in some variant of the translucent terrain (its CPU side, the open-water map, is then worth running). */
	public static boolean swellCompiled() {
		return ON && (SWELL_CODE || SWELL_DEV);
	}

	/** (2026-11-02, S2) ShadeResources entry of the open-water map (shade_look.metal waterOpen). */
	static final int RES_OPEN = 9;
	/** The map's textures (WaterOpenScan's size, RGBA8, filled by the CPU): a ring, so a new map never overwrites one a frame in flight reads. */
	private static final long[] OPEN_TEX = new long[3];
	private static int openNext;
	private static boolean openFailed;
	/** The map's outer-ring mean for the water beyond it (ShadeWaterParams.swell2.x); < 0 = no map: the swell everywhere at its strength. */
	private static float openFar = -1f;

	/**
	 * (2026-11-02, S2) A new open-water map (WaterOpenScan): size x size RGBA8 in the direct buffer rgba (toroidal: texel (x mod size, z mod size)
	 * holds the 2x2-block cell (floor(X / 2), floor(Z / 2)); r = how open the water is there, 0..1), and far = its outer ring's mean, for
	 * the water beyond it. Uploaded into the next texture of a small ring and published as ShadeResources entry {@link #RES_OPEN}; HDR
	 * only (the terrain reads ShadeResources). Render thread.
	 */
	static void openMap(ByteBuffer rgba, int size, float far) {
		if (openFailed || !mcopt.metal.shade.ShadeConfig.HDR || !mcopt.metal.shade.ShadeRender.ready()) return; // (not set up yet: the next map)
		try {
			int i = openNext;
			if (OPEN_TEX[i] == 0) OPEN_TEX[i] = mcopt.metal.shade.ShadeRender.textureCpu(size, size, "mcopt shade water: open-water map " + i);
			mcopt.metal.shade.ShadeRender.upload(OPEN_TEX[i], 0, 0, size, size, MemoryUtil.memAddress(rgba), size * 4);
			openPending = OPEN_TEX[i];
			openPendingFar = far;
			openNext = (i + 1) % OPEN_TEX.length;
		} catch (Throwable e) {
			openFailed = true;
			openFar = -1f;
			System.out.println("[mcopt] shade: water open-water map failed, the swell is the same everywhere from now on: " + e);
		}
	}

	/** (2026-11-02, S2) No open-water map (off, a new world): the shader scales the swell by 1 everywhere. */
	static void openNone() {
		openFar = -1f;
		openPending = 0;
	}

	/** A map uploaded but not yet published (openMap runs before this frame's ShadeResources slot exists). */
	private static long openPending;
	private static float openPendingFar = -1f;

	/**
	 * (2026-11-03) Publishes the last uploaded open-water map as ShadeResources entry {@link #RES_OPEN}: right after the frame's
	 * ShadeBindings.nextSlot (ShadeFrameUpdater), as the other per-frame resources. openMap runs in WaterFrame.update, before it:
	 * publishing there wrote the entry into the slot the previous frame's encoders still read, which had made only the old map
	 * resident (Metal validation with Distant Horizons: GPU address faults, 2-3 a run).
	 */
	public static void publishOpen() {
		if (openPending == 0) return;
		mcopt.metal.shade.ShadeRender.resource(RES_OPEN, openPending);
		openFar = openPendingFar;
		openPending = 0;
	}

	/** M3.4: the default soft shadow radius on water (blocks). */
	static final float SHADOW_SOFT_DEFAULT = 2f;
	/** M2.1: the water animates on a real-time clock instead of the (server-corrected, tick-based) game time. */
	public static final boolean CLOCK = Boolean.parseBoolean(System.getProperty("mcopt.shade.waterClock", "true"));
	/**
	 * The pipelines whose first use in a main pass triggers the scene copy: vanilla's translucent terrain (mcopt 0.3 port:
	 * Sodium's until 1.1; with mcopt's own terrain renderer the copy is taken where it starts its translucent draws instead).
	 */
	public static final String TRANSLUCENT = "minecraft:pipeline/translucent_terrain", TRANSLUCENT_MULTIDRAW = "minecraft:pipeline/translucent_terrain_multidraw";

	/** Whether pipelineName is one of the {@link #TRANSLUCENT} pipelines. */
	public static boolean translucentTerrain(String pipelineName) {
		return TRANSLUCENT.equals(pipelineName) || TRANSLUCENT_MULTIDRAW.equals(pipelineName);
	}

	private static long state;
	private static boolean failed;
	private static final ByteBuffer PARAMS = ByteBuffer.allocateDirect(112).order(ByteOrder.nativeOrder()); // water.metal ShadeWaterParams
	private static int captures;

	private ShadeWater() {
	}

	private static float floatProperty(String key, float def) {
		try {
			return Float.parseFloat(System.getProperty(key, Float.toString(def)));
		} catch (NumberFormatException e) {
			return def;
		}
	}

	/** The MSL that goes after shade_common.metal in front of the translucent terrain fragment: flag defines + water.metal. */
	public static String prelude() {
		StringBuilder b = new StringBuilder("#define SHADE_WATER 1\n");
		if (SSR) b.append("#define SHADE_SSR 1\n");
		if (SSR_QUAD) b.append("#define SHADE_SSR_QUAD 1\n");
		b.append("#define SHADE_SSR_STEPS ").append(SSR_STEPS).append('\n');
		if (CAUSTICS) b.append("#define SHADE_CAUSTICS 1\n");
		if (FOAM) b.append("#define SHADE_FOAM 1\n");
		if (GLOSSY) b.append("#define SHADE_GLOSSY 1\n");
		if (SSR_PREV) b.append("#define SHADE_SSR_PREV 1\n");
		if (DETAIL) {
			b.append("#define SHADE_WATER_DETAIL 1\n#define SHADE_WATER_DETAIL_SIZE ").append(DETAIL_SIZE).append("\n#define SHADE_WATER_DETAIL_FAR ")
				.append(DETAIL_FAR).append(".0\n#define SHADE_WATER_PATTERN_FAR ").append(Float.parseFloat(PATTERN_FAR)).append('\n');
			if (DETAIL_EXTRAS) b.append("#define SHADE_WATER_DETAIL_EXTRAS 1\n");
		}
		if (SSR_EDGE) b.append("#define SHADE_SSR_EDGE 1\n");
		b.append("#define SHADE_SSR_THICK_K ").append(SSR_THICK).append("\n#define SHADE_SSR_BEHIND ").append(SSR_BEHIND ? 1 : 0)
			.append("\n#define SHADE_SSR_TOP ").append(SSR_TOP).append("\n#define SHADE_SSR_SIDE ").append(SSR_SIDE)
			.append("\n#define SHADE_SSR_SIDE_END ").append(SSR_SIDE_END).append('\n');
		// 2026-10-08: the SSR march decides in reversed-Z depth (same decisions, no division per step); false = FT1.3's march
		if (Boolean.parseBoolean(System.getProperty("mcopt.shade.water.rawz", "true"))) b.append("#define SHADE_SSR_RAWZ 1\n");
		// (FT2.8, audit idx 57/58) the RAWZ march's bisection in 2 rounds of 3 reads and its fallback kept as one float: same image,
		// -0.06..-0.09 ms in the lake spin (notes/ft28-2026-10-09 ssr28-*, 2 pairs); mcopt.shade.water.ssrLean=false: FT2.7's
		if (Boolean.parseBoolean(System.getProperty("mcopt.shade.water.ssrLean", "true"))) b.append("#define SHADE_SSR_LEAN2 1\n");
		// 2026-10-08: the live pricing switches (bits 21-23 of mcopt.shade.dev) only with -Dmcopt.shade.wdev=true (they cost ~0.09 ms
		// in the lake spin, price5c)
		if (Boolean.getBoolean("mcopt.shade.wdev")) b.append("#define SHADE_WDEV_ON 1\n");
		if (EDGE_REFL) b.append("#define SHADE_WATER_EDGE_REFL 1\n");
		if (SMOOTH && SSR_QUAD && Boolean.parseBoolean(System.getProperty("mcopt.shade.water.ssrLane", "true"))) b.append("#define SHADE_SSR_LANE 1\n");
		if (SMOOTH) b.append("#define SHADE_WATER_SMOOTH 1\n"); // (2026-11-02: calm and ripple are read every frame, ShadeWaterParams.swell2.zw)
		if (GLINT_GRAZE) b.append("#define SHADE_WATER_GLINT_GRAZE 1\n");
		if (SWELL_CODE) b.append("#define SHADE_WATER_SWELL 1\n"); // (2026-11-02, water round 1)
		if (GLITTER_CODE) b.append("#define SHADE_WATER_GLITTER 1\n");
		if (BAKE) b.append("#define SHADE_WAVE_BAKE 1\n#define SHADE_WAVE_BAKE_SIZE ").append(BAKE_SIZE).append('\n');
		// TAAU (mcopt.shade.taa): the world draws into a live sub-rect of fixed-size targets (so do the copies), and the SSR
		// jitter changes per frame for the temporal resolve to integrate. The sub-rect mapping is exact without TAAU too
		// (ShadeFrame.screen = the copy's size then).
		b.append("#define SHADE_WATER_SUBRECT 1\n");
		if (mcopt.metal.shade.taa.TaaConfig.ENABLED) b.append("#define SHADE_WATER_TAA 1\n");
		if (RTR && mcopt.metal.shade.taa.TaaConfig.ENABLED) b.append("#define SHADE_WATER_RTR 1\n");
		// (candidate 7, dev) mcopt.shade.water.ssrJitterFrame=false: the SSR step jitter fixed per pixel even with TAA (the flicker hunt)
		if (!Boolean.parseBoolean(System.getProperty("mcopt.shade.water.ssrJitterFrame", "true"))) b.append("#define SHADE_SSR_JITTER_STILL 1\n");
		return b.append(ShadeMsl.resource("water.metal")).append('\n').toString();
	}

	/** Lazily creates the native state (first bind or frame). False after a failure: the shaders then fall back by themselves. */
	private static boolean ready(long ctx) {
		if (state != 0) return true;
		if (failed || ctx == 0) return false;
		try {
			state = WaterNative.create(ctx);
			if (SSR) {
				try {
					long t0 = mcopt.metal.shade.ShadeCompile.now();
					WaterNative.setHz(state, mcopt.metal.shade.ShadeRender.pipeline(library(), "shade_fs_vs", "shade_water_hz_fs", mcopt.metal.shade.ShadeRender.R32F,
						mcopt.metal.shade.ShadeRender.BLEND_NONE));
					mcopt.metal.shade.ShadeCompile.setup("water", t0);
				} catch (Throwable e) {
					System.out.println("[mcopt] shade: water coarse depth failed, SSR finds nothing: " + e);
				}
			}
			System.out.println("[mcopt] shade: water on (ssr " + SSR + (SSR_QUAD ? " quad" : "") + ", " + SSR_STEPS + " steps, " + SSR_DIST + " blocks; waves " + WAVES
				+ ", detail " + DETAIL + ", ssr edges " + SSR_EDGE + ", real-time clock " + CLOCK + ", caustics " + CAUSTICS + ", foam " + FOAM + ", glossy " + GLOSSY + ", prev-frame reflections " + SSR_PREV + ", baked waves " + BAKE + ", glint graze " + GLINT_GRAZE + ", edge reflections " + EDGE_REFL + ", style " + (SMOOTH ? "photon (calm " + CALM + ", ripple " + RIPPLE + ")" : "m21") + ")");
		} catch (Throwable e) {
			failed = true;
			System.out.println("[mcopt] shade: water setup failed, M1 water from now on: " + e);
		}
		return state != 0;
	}

	private static long bakePso, bakeDetailPso, library;
	private static boolean bakeFailed, bakedOnce;
	private static int capturesAtBake = -1;

	/** The module's own passes (wave bake, coarse depth): prelude + post (shade_fs_vs) + this prelude. */
	private static long library() {
		if (library == 0) library = mcopt.metal.shade.ShadeRender.library(librarySource());
		return library;
	}

	/** The module's own passes' source: prelude + post (shade_fs_vs) + this prelude. */
	public static String librarySource() {
		return mcopt.metal.shade.ShadeRender.prelude() + mcopt.metal.shade.ShadeRender.postSource() + prelude();
	}

	/**
	 * Renders this frame's wave field (water.metal shade_water_bake_fs, BAKE_SIZE^2 RGBA16F over a 64-block tile) and its mips,
	 * before the world passes (ShadeFrameUpdater, after the sky LUT). Without it the shaders evaluate the waves per pixel.
	 */
	public static void bake(long ctx, long enc) {
		if (!BAKE || bakeFailed || enc == 0 || !ready(ctx)) return;
		// no translucent terrain drew last frame (no scene copy: no water on screen, the Nether, caves): skip the bake; the
		// shaders use the analytic waves on the frame water comes back (ShadeWaterParams.state.w = 0)
		boolean recent = captures != capturesAtBake;
		capturesAtBake = captures;
		if (!recent && bakedOnce) return;
		bakedOnce = true;
		try {
			if (bakePso == 0) {
				long t0 = mcopt.metal.shade.ShadeCompile.now();
				bakePso = mcopt.metal.shade.ShadeRender.pipeline(library(), "shade_fs_vs", "shade_water_bake_fs", mcopt.metal.shade.ShadeRender.RGBA16F,
					mcopt.metal.shade.ShadeRender.BLEND_NONE);
				mcopt.metal.shade.ShadeCompile.setup("water", t0);
			}
			long tex = WaterNative.waves(ctx, state, BAKE_SIZE);
			mcopt.metal.shade.ShadeRender.pass(enc, bakePso, tex, mcopt.metal.shade.ShadeRender.DONT_CARE, null, null, "mcopt shade water: wave bake");
			if (DETAIL) {
				// M2.1: the fine-ripple layer (water.metal shade_water_bake_detail_fs: the same waves, faster), texture(22)
				if (bakeDetailPso == 0) {
					long t0 = mcopt.metal.shade.ShadeCompile.now();
					bakeDetailPso = mcopt.metal.shade.ShadeRender.pipeline(library(), "shade_fs_vs", "shade_water_bake_detail_fs",
						mcopt.metal.shade.ShadeRender.RGBA16F, mcopt.metal.shade.ShadeRender.BLEND_NONE);
					mcopt.metal.shade.ShadeCompile.setup("water", t0);
				}
				long det = WaterNative.wavesDetail(ctx, state, DETAIL_SIZE);
				mcopt.metal.shade.ShadeRender.pass(enc, bakeDetailPso, det, mcopt.metal.shade.ShadeRender.DONT_CARE, null, null, "mcopt shade water: ripple bake");
			}
			WaterNative.wavesDone(enc, state);
		} catch (Throwable e) {
			bakeFailed = true;
			System.out.println("[mcopt] shade: water wave bake failed, per-pixel waves from now on: " + e);
		}
	}

	/** Binds the copies and this frame's parameters into enc's open render encoder (fragment stage). */
	public static void bind(long ctx, long enc) {
		if (ready(ctx)) WaterNative.bind(enc);
	}

	/**
	 * The scene copy at the switch to translucent terrain (enc's open encoder is ended, copied and reopened). True when it
	 * happened: the caller must restore its encoder state (pipeline, uniforms, scissor, vertex buffers, shade globals).
	 */
	public static boolean capture(long ctx, long enc) {
		if (!ready(ctx)) return false;
		boolean done = WaterNative.capture(enc, state) != 0;
		if (done && captures++ == 0) System.out.println("[mcopt] shade: water scene copy active");
		return done;
	}

	/**
	 * This frame's parameters, before anything draws (ShadeFrameUpdater). still / flow: the water sprites' atlas uv
	 * rectangles (u0, v0, u1, v1; zeros = unknown, the shader then guesses water from the vertex colour like M1);
	 * surfaceY: the water surface above the eye, camera-relative (under water; 0 otherwise); wetness 0..1.
	 */
	/**
	 * (1.2.7 candidate 6, DESIGN.md S6) the swell's strength for Distant Horizons' sea (ShadeLook user2.z; dh_terrain.fs.metal): the near
	 * water's past 120 blocks (swell x the open-water map's outer ring x the wet; the storm factor is applied in the shader), 0 without the
	 * swell's code or with mcopt.shade.dh.waterSwell=0 (live; candidate 5's flat far sea). Written by frame(), read when ShadeLook packs.
	 */
	public static volatile float dhSwell;

	public static void frame(long ctx, float[] still, float[] flow, float surfaceY, float wetness) {
		if (!ready(ctx)) return;
		dhSwell = swellCompiled() && mcopt.metal.shade.Live.f("mcopt.shade.dh.waterSwell", 1f, 0f, 1f) > 0.5f
			? mcopt.metal.shade.Live.f("mcopt.shade.water.swell", 1.3f, 0f, 3f) * (openFar < 0f ? 1f : openFar) * (1f + 0.8f * wetness) : 0f;
		ByteBuffer p = PARAMS;
		for (int i = 0; i < 4; i++) p.putFloat(i * 4, still[i]);
		for (int i = 0; i < 4; i++) p.putFloat(16 + i * 4, flow[i]);
		p.putFloat(32, 0f).putFloat(36, surfaceY).putFloat(40, wetness).putFloat(44, 0f);
		// (1.1) waves, reflections and screen reflections on/off from the settings screen (ShadeSettings, live), mcopt.shade.ssrDist live,
		// w the caustics' strength (user.caustics, 0..2; 0 = none; only with the module's code built in, mcopt.shade.caustics at startup)
		float ssrDist = Math.clamp(mcopt.metal.shade.Live.f("mcopt.shade.ssrDist", SSR_DIST), 8f, 1024f);
		p.putFloat(48, mcopt.metal.shade.ShadeSettings.waves()).putFloat(52, mcopt.metal.shade.ShadeSettings.ssr() ? ssrDist : 0f)
			.putFloat(56, mcopt.metal.shade.ShadeSettings.reflect())
			.putFloat(60, CAUSTICS ? mcopt.metal.shade.Live.f("mcopt.shade.user.caustics", 1f, 0f, 2f) : 0f);
		// (2026-11-02, water round 1) swell (64), swell2 (80), swell3 (96): water.metal ShadeWaterParams. The calm of the long waves and the
		// ripples' strength in clear weather (style photon), read every frame since round 1 (they were startup defines: now A/B-able in session)
		// the swell (mcopt.shade.water.swell 0..3, 0 = none: the look before it): its strength, its masking k (.swellMask), the light through
		// its crests at golden hour (.swellGlow 0..4, 0 = none), its share in the Fresnel (.swellFresnel, 1 physical, 0 = the cosine without it)
		p.putFloat(64, mcopt.metal.shade.Live.f("mcopt.shade.water.swell", 1.3f, 0f, 3f)).putFloat(68, mcopt.metal.shade.Live.f("mcopt.shade.water.swellMask", 0.45f, 0f, 1f))
			.putFloat(72, mcopt.metal.shade.Live.f("mcopt.shade.water.swellGlow", 0.5f, 0f, 4f))
			.putFloat(76, mcopt.metal.shade.Live.f("mcopt.shade.water.swellFresnel", 1f, 0f, 1f));
		// (candidate 7) the mirrored images' calm (.mirrorCalm 0.05..1: how far their normal is pulled toward the face's; 0.55 = before;
		// 0.75 with reflTemporal 0.8: at Gael's pond, frozen waves, pixels flickering again and again walking 21 -> 9 %, running 32 -> 17 %,
		// jumping 30 -> 16 %; 0.9 measured the same and smooths the reflections more)
		p.putFloat(80, openFar).putFloat(84, mcopt.metal.shade.Live.f("mcopt.shade.water.mirrorCalm", 0.75f, 0.05f, 1f)).putFloat(88, mcopt.metal.shade.Live.f("mcopt.shade.water.calm", CALM, 0.05f, 2f))
			.putFloat(92, mcopt.metal.shade.Live.f("mcopt.shade.water.ripple", RIPPLE, 0f, 3f));
		// the swell's share in the mirrored images' direction (.swellRefl: 0.45 = the ripples' share, 1 = all of it; STUDY item 2)
		// and the glint's glitter (.glitter 0..3, 0 = none; STUDY item 3). 1.2.7 candidate 5 (Gael, 2026-11-03: "los reflejos se
		// cortan de repente"): 1 -> 0.45. All of the swell tilted the mirrored rays by up to ~12 degrees: shores and trees mirrored
		// far from where they stand, cut into slivers and doubled lines; at the ripples' share the images stay whole and wavy
		p.putFloat(96, mcopt.metal.shade.Live.f("mcopt.shade.water.swellRefl", 0.45f, 0f, 1f))
			// (candidate 5, Gael's Photon references: the sun's road a narrow column of separate dashes) the glitter 1 -> 1.5 and the glint's
			// base roughness factor (.glintSharp 0.1..2; 1 = candidate 4's broad ribbon; 0.3: A/B at sunrise and sunset over the sea,
			// work/notes/2026-11-03 ps-k2, against 0.5 and 0.2)
			.putFloat(100, mcopt.metal.shade.Live.f("mcopt.shade.water.glitter", 1.5f, 0f, 3f))
			.putFloat(104, mcopt.metal.shade.Live.f("mcopt.shade.water.glintSharp", 0.3f, 0.1f, 2f))
			// (candidate 7) the mirrored image's temporal reprojection: its weight x the Fresnel (.reflTemporal 0..0.95; 0 = candidate 6;
			// water.metal SHADE_WATER_RTR, Gael's flicker on the water while moving)
			.putFloat(108, RTR ? mcopt.metal.shade.Live.f("mcopt.shade.water.reflTemporal", 0.8f, 0f, 0.95f) : 0f);
		WaterNative.params(state, MemoryUtil.memAddress(p));
	}
}
