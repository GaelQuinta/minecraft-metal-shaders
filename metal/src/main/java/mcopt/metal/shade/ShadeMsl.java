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
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Objects;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import mcopt.metal.MetalShaderRegistry;
import mcopt.metal.shade.water.ShadeWater;
import mcopt.metal.shade.weather.ShadeWeather;

/**
 * The shaded MSL, assembled from resources/mcopt/shade the same way for the game and for validation tools (mslcheck):
 * every shaded stage is "#define MCOPT_SHADE" + shade_common.metal + the stage's own source (MetalPipeline prepends the
 * MCOPT_SLOT_* uniform slot defines in front of that). Registered by pipeline name in MetalShaderRegistry:
 * <ul>
 * <li>(up to 1.1) sodium:pipeline/{solid,cutout,translucent}_terrain: Sodium's terrain with per-pixel lighting. Since the
 * mcopt 0.3 port the terrain is mcopt's own renderer's (own/terrain.metal), shaded through {@link #ownPrefix}.</li>
 * <li>minecraft:pipeline/sky: the atmosphere (sky.vs.metal, sky.fs.metal).</li>
 * <li>minecraft:pipeline/celestial: vanilla's sun quad dropped, moon kept (celestial.vs.metal).</li>
 * <li>minecraft:pipeline/sunrise_sunset: dropped in the overworld (sunrise_sunset.vs.metal).</li>
 * <li>minecraft:pipeline/clouds, flat_clouds: lit clouds (clouds.fs.metal).</li>
 * <li>minecraft:pipeline/weather: rain and snow re-lit (weather.metal, patched into the generated fragment).</li>
 * <li>minecraft:pipeline/stars: vanilla's star quads dropped when the sky draws M2's procedural stars (stars.vs.metal).</li>
 * </ul>
 * M2 (mcopt.shade.hdr): the prelude is shade_look.metal + shade_common.metal + shade_m2.metal, and every pipeline that draws
 * into the HDR world target gets an RGBA16Float variant through {@link #formatAdapter}: the stages above are compiled with
 * "#define MCOPT_HDR" (pre-exposed radiance out), the game's own fragments convert their display-referred result with
 * shadeLdrToHdr ({@link #hdrFragment}).
 */
public final class ShadeMsl {
	/** Must match SHADE_LUT_W / SHADE_LUT_H in shade_common.metal. */
	public static final int LUT_WIDTH = 128, LUT_HEIGHT = 80;
	public static final String SKY = "minecraft:pipeline/sky", CELESTIAL = "minecraft:pipeline/celestial", SUNRISE = "minecraft:pipeline/sunrise_sunset";
	/**
	 * The terrain pipelines registered with shading: none since the mcopt 0.3 port (v12). Up to 1.1 these were Sodium's
	 * (sodium:pipeline/{solid,cutout,translucent}_terrain, shaded through sodium_terrain.{vs,fs}.metal); mcopt 0.3 draws terrain
	 * with its own renderer (mcopt.metal.own), which gets the shading through {@link #ownPrefix} instead.
	 */
	public static final List<String> TERRAIN = List.of();

	public static final String WEATHER = "minecraft:pipeline/weather", STARS = "minecraft:pipeline/stars", LIGHTNING = "minecraft:pipeline/lightning";
	/** M3 (mcopt.shade.dims): the End sky box (end_sky.{vs,fs}.metal). */
	public static final String END_SKY = "minecraft:pipeline/end_sky";
	public static final List<String> CLOUDS = List.of("minecraft:pipeline/clouds", "minecraft:pipeline/flat_clouds");

	private static volatile String prelude, look, skyVertex, skyFragment, celestialVertex, sunriseVertex, starsVertex, cloudFragment, endSkyVertex, endSkyFragment;

	private ShadeMsl() {
	}

	public static String resource(String name) {
		try (InputStream in = ShadeMsl.class.getResourceAsStream("/mcopt/shade/" + name)) {
			return new String(Objects.requireNonNull(in, name).readAllBytes(), StandardCharsets.UTF_8);
		} catch (IOException e) {
			throw new UncheckedIOException(e);
		}
	}

	/**
	 * "#define MCOPT_SHADE", shade_look.metal (M2 art layer, display transform), shade_common.metal (M1), shade_clouds.metal
	 * (M3: what shaders read of the volumetric clouds), shade_m2.metal (M2 shading), shade_dims.metal (M3 sky / dimensions),
	 * the dynamic-lights module (M3, empty when off) and shade_dynlight.metal (M3: the dynamic-lights seam): what goes in front
	 * of every shaded stage.
	 */
	/**
	 * FT1.3 (Gael: far terrain at the sunset horizon dotted and oddly white): mcopt.shade.hazeEdge (true) = the final pass's
	 * haze from the 2x2 depth texels along silhouettes (not the nearest: a rim of dots against the resolved image);
	 * mcopt.shade.hazeMieG (0.5; 0.76 = M3.4) = the haze's forward lobe toward the sun (0.76 washed far terrain out to cream).
	 */
	static final String HAZE_DEFINES = (Boolean.parseBoolean(System.getProperty("mcopt.shade.hazeEdge", "true")) ? "#define SHADE_HAZE_EDGE 1\n" : "")
		+ "#define SHADE_HAZE_MIE_G " + Math.clamp(Float.parseFloat(System.getProperty("mcopt.shade.hazeMieG", "0.5")), 0f, 0.95f) + "\n"
		// (FT2.8, audit idx 96) the PCSS disc rotated per frame under TAA (-Dmcopt.shade.pcssNoise=true). Off by default: at still poses
		// it made leaves and canopy silhouettes shimmer frame to frame (pcss28-*: p4 pixels off by > 8 levels 0.08 % -> 1.23 %); FT2.7's
		// fixed pattern keeps them still
		+ (mcopt.metal.shade.taa.TaaConfig.ENABLED && Boolean.getBoolean("mcopt.shade.pcssNoise") ? "#define SHADE_PCSS_TAA 1\n" : "")
		// (FT2.8, audit idx 82) the terrain's RGSS taps only where they count (mcopt.shade.rgssGate; false = Sodium's 5 taps everywhere)
		+ (Boolean.parseBoolean(System.getProperty("mcopt.shade.rgssGate", "true")) ? "#define SHADE_RGSS_GATE 1\n" : "")
		// (v12) own terrain's RGSS as 1.1's: 4 taps at the nearest whole mip, not own's 8 across two (lake spin -0.3 ms, flight -0.5 ms;
		// shots within 0.7-1.6 of 255); -Dmcopt.shade.rgssOne=false = own's two-level blend
		+ (!"false".equals(System.getProperty("mcopt.shade.rgssOne")) ? "#define SHADE_RGSS_ONE 1\n" : "");

	public static String prelude() {
		if (prelude == null) {
			prelude = "#define MCOPT_SHADE\n" + HAZE_DEFINES + resource("shade_look.metal") + "\n" + resource("shade_common.metal") + "\n" + resource("shade_clouds.metal") + "\n"
				+ resource("shade_m2.metal") + "\n"
				+ resource("shade_dims.metal") + "\n" // M3 sky / dimensions (skydims)
				+ mcopt.metal.shade.light.DynLightMsl.prelude() // M3 dynamic lights (empty when off)
				+ resource("shade_dynlight.metal") + "\n";
		}
		return prelude;
	}

	/**
	 * mcopt 0.3 port: what goes in front of mcopt's own terrain library (own/terrain.metal, through ShadeTerrain.prefix):
	 * MCOPT_SHADE (its fragment stages' slots kept clear of the shade globals, the shading varyings, the lightmap per pixel) and
	 * shade_look.metal (own_fs's SHADE_OWN_HDR conversion, the vanilla-look fallback). The shading itself is in a library of its
	 * own per variant: {@link #ownFragmentSource}.
	 */
	public static String ownPrefix() {
		return "#define MCOPT_SHADE\n" + look();
	}

	/**
	 * mcopt 0.3 port: the library with the terrain's shaded fragment stage (terrain_own.metal shade_own_fs) for own's opaque
	 * layers or its translucent one, for lean variant leanBits (ShadeLean's tag bits, unshifted), assembled as terrain() and
	 * the format adapter built Sodium's terrain stages up to 1.1: MCOPT_HDR (the world target is HDR), the lean defines, the
	 * prelude, the weather module (its translucent form for the translucent layer), the water module (translucent layer only,
	 * mcopt.shade.water), the stage.
	 */
	public static String ownFragmentSource(boolean translucent, int leanBits) {
		return (ShadeConfig.HDR ? "#define MCOPT_HDR\n" : "") + (OWN_NONCE != null ? "#define SHADE_OWN_NONCE " + OWN_NONCE + "\n" : "")
			+ leanDefines(leanBits << LEAN_SHIFT) + LEAN_TEST
			+ (translucent ? "#define SHADE_OWN_TRANSLUCENT\n" : "") + prelude() + ShadeWeather.prelude(translucent)
			+ (translucent && ShadeWater.MODULE ? ShadeWater.prelude() : "") + resource("terrain_own.metal");
	}

	/**
	 * -Dmcopt.shade.terrain.nonce=N (dev only, an integer): own terrain's shaded stages get code of their own (a test no pixel
	 * passes), so Metal's cache has none of their pipelines: the first launch after an install or an OS update, on demand.
	 */
	private static final Integer OWN_NONCE = Integer.getInteger("mcopt.shade.terrain.nonce");

	/** shade_look.metal alone (self-contained): what the game's own fragments need for shadeLdrToHdr. */
	public static String look() {
		if (look == null) look = resource("shade_look.metal") + "\n";
		return look;
	}

	/** The post chain's library (ShadePost): the prelude + shade_post.metal. */
	public static String post() {
		return prelude() + resource("shade_post.metal");
	}

	/**
	 * A Sodium terrain stage (the source MetalPipeline would compile: built-in MSL, with its defines) with shading. The
	 * translucent fragment (the only stage with "#define ALPHA_CUTOUT 0.01" and a fragment entry) also gets the water
	 * module (ShadeWater.prelude: SHADE_WATER and water.metal) unless mcopt.shade.water=false.
	 */
	public static String terrain(String source) {
		return terrain(source, ShadeWater.MODULE);
	}

	/** terrain(source) with the water module forced on or off (validation tools build both). */
	public static String terrain(String source, boolean water) {
		// M3 weather (ShadeWeather.prelude: wet surfaces, puddles, ripples, shadow tint) goes in front of every terrain fragment,
		// before the water module (whose surface uses its ripples)
		String weather = source.contains("fragment main0_out main0(") ? ShadeWeather.prelude(source.startsWith(TRANSLUCENT_DEFINE)) : "";
		String lean = source.contains("fragment main0_out main0(") ? LEAN_TEST : "";
		if (water && source.startsWith(TRANSLUCENT_DEFINE) && source.contains("fragment main0_out main0(")) return lean + prelude() + weather + ShadeWater.prelude() + source;
		return lean + prelude() + weather + source;
	}

	private static final String TRANSLUCENT_DEFINE = "#define ALPHA_CUTOUT 0.01";
	/**
	 * M3.1 lean terrain tags (ShadeLean) on the HDR world format, bits 17-19 (the lit hand's tag is bit 16, on RGBA8): the Sodium
	 * terrain's variant for a tag compiles that code out (sodium_terrain.fs.metal SHADE_LEAN_*); other pipelines drop the bits.
	 */
	public static final int LEAN_SHIFT = mcopt.metal.MetalHooks.TAG_SHIFT + 1, LEAN_OW = 1, LEAN_DRY = 2, LEAN_NODL = 4, LEAN_NOAURORA = 8,
		LEAN_NETHER = 16, // M3.3 (dims): the Nether's terrain variant (SHADE_LEAN_NETHER), mcopt.shade.dims.netherLean
		// 2026-10-08 (translucent terrain only): ABOVE = the camera is not under water (SHADE_LEAN_ABOVE: the surface seen from
		// below is compiled out); DEV = ShadeLean.DEV_DEFINES (-Dmcopt.shade.leanDev, in-session A/B of compile-time variants)
		// (FT2.11, translucent terrain, overworld) NOFALLS = no moving water near the camera (WaterFlowScan): the moving water's look is
		// compiled out (SHADE_LEAN_NOFALLS: the water shader is bound by registers and that code cost ~0.2 ms where it never ran)
		LEAN_ABOVE = 32, LEAN_DEV = 64, LEAN_NOFALLS = 128, LEAN_WATER = LEAN_ABOVE | LEAN_DEV | LEAN_NOFALLS,
		LEAN_TERRAIN = LEAN_OW | LEAN_DRY | LEAN_NODL | LEAN_NETHER, LEAN_MASK = 255 << LEAN_SHIFT;

	static final String TRANSLUCENT_TERRAIN = "sodium:pipeline/translucent_terrain";

	static boolean leanTerrain(String pipelineName) {
		return pipelineName.startsWith("sodium:pipeline/") && pipelineName.endsWith("_terrain");
	}

	static String leanDefines(int format) {
		int t = (format & LEAN_MASK) >>> LEAN_SHIFT;
		return ((t & LEAN_OW) != 0 ? "#define SHADE_LEAN_OW\n" : "") + ((t & LEAN_DRY) != 0 ? "#define SHADE_LEAN_DRY\n" : "")
			+ ((t & LEAN_NODL) != 0 ? "#define SHADE_LEAN_NODL\n" : "") + ((t & LEAN_NOAURORA) != 0 ? "#define SHADE_LEAN_NOAURORA\n" : "")
			+ ((t & LEAN_NETHER) != 0 ? "#define SHADE_LEAN_NETHER\n" : "") + ((t & LEAN_ABOVE) != 0 ? "#define SHADE_LEAN_ABOVE\n" : "")
			+ ((t & LEAN_NOFALLS) != 0 ? "#define SHADE_LEAN_NOFALLS\n" : "")
			+ ((t & LEAN_DEV) != 0 ? ShadeLean.DEV_DEFINES : "");
	}
	/** M3.1 experiment (-Dmcopt.shade.leanTest=ow,dry,nodl): those lean defines in every terrain fragment, always. */
	private static final String LEAN_TEST = leanTest(System.getProperty("mcopt.shade.leanTest", ""));

	private static String leanTest(String v) {
		StringBuilder b = new StringBuilder();
		for (String t : v.split(",")) {
			switch (t.trim()) {
				case "ow" -> b.append("#define SHADE_LEAN_OW\n");
				case "dry" -> b.append("#define SHADE_LEAN_DRY\n");
				case "nodl" -> b.append("#define SHADE_LEAN_NODL\n");
				default -> { }
			}
		}
		return b.toString();
	}

	/** One of the sky pipelines' replacement stages (the vanilla uniform blocks come with them). */
	public static String skyStage(String file) {
		return prelude() + resource("vanilla_uniforms.metal") + "\n" + resource(file);
	}

	/** The sky-view LUT pass (compiled natively by mcshade.m). */
	public static String lut() {
		return resource("shade_look.metal") + "\n" + resource("shade_common.metal") + "\n" + resource("sky_lut.metal");
	}

	private static final String WEATHER_SIGNATURE = "fragment main0_out main0(main0_in in [[stage_in]]";
	private static final String WEATHER_RESULT = "out.fragColor = calculateFinalColor(";

	/**
	 * minecraft:pipeline/weather (fragment): vanilla's generated rain and snow shader, with its result re-lit at the end
	 * (shadeWeather in weather.metal: grey-white streaks in the light the terrain gets, through the same tone curve, instead
	 * of vanilla's saturated blue). A textual patch of the generated source, since its texture slots are numbered by the
	 * game; if the source doesn't have the expected shape, it's left as it is.
	 */
	public static String weather(String generated) {
		int at = generated.indexOf(WEATHER_RESULT);
		if (!generated.contains(WEATHER_SIGNATURE) || at < 0) return generated;
		int end = generated.indexOf(';', at) + 1;
		boolean m3 = ShadeWeather.MODULE && !generated.contains("[[position]]");
		String call = m3 ? "shadeWeather3(out.fragColor, mcoptFragCoord, mcoptShadeFrame, mcoptShadeLook, mcoptShadeGpu, mcoptSkyLut, mcoptSkyLutSmplr)"
			: "shadeWeather(out.fragColor, mcoptShadeFrame, mcoptShadeLook, mcoptShadeGpu)";
		String patched = generated.substring(0, end) + "\n    out.fragColor = " + call + ";" + generated.substring(end);
		patched = patched.replace(WEATHER_SIGNATURE, WEATHER_SIGNATURE
			+ ", constant ShadeFrame& mcoptShadeFrame [[buffer(16)]], constant ShadeLook& mcoptShadeLook [[buffer(17)]], constant ShadeGpu& mcoptShadeGpu [[buffer(18)]]"
			+ (m3 ? ", float4 mcoptFragCoord [[position]], texture2d<half> mcoptSkyLut [[texture(17)]], sampler mcoptSkyLutSmplr [[sampler(13)]]" : ""));
		return prelude() + (m3 ? "#define SHADE_WEATHER\n" + (ShadeWeather.LITE ? "#define SHADE_WX_LITE\n" : "") : "") + resource("weather.metal") + "\n" + patched;
	}

	private static final String VERTEX_SIGNATURE = "vertex main0_out main0(main0_in in [[stage_in]]";
	private static final String VERTEX_BODY = "main0_out out = {};";

	/**
	 * minecraft:pipeline/weather (vertex, M3 weather with mcopt.shade.rainSlant): vanilla's generated stage with the column
	 * vertices leaned along the wind before anything uses them (weather.metal shadeRainSlant). Unchanged if the source doesn't
	 * have the expected shape.
	 */
	public static String weatherVertex(String generated) {
		if (!ShadeWeather.MODULE || !ShadeWeather.SLANT || !generated.contains(VERTEX_SIGNATURE) || !generated.contains(VERTEX_BODY)
			|| !generated.contains("in.Position")) return generated;
		String patched = generated.replace(VERTEX_BODY, VERTEX_BODY + "\n    in.Position = shadeRainSlant(in.Position, mcoptShadeLook);")
			.replace(VERTEX_SIGNATURE, VERTEX_SIGNATURE + ", constant ShadeLook& mcoptShadeLook [[buffer(17)]]");
		return prelude() + resource("weather.metal") + "\n" + patched;
	}

	private static final String LIGHTNING_RESULT = "out.fragColor = calculateFinalColor(";

	/**
	 * minecraft:pipeline/lightning (fragment, M3 weather): the bolt is light, not paint. In the HDR world target its colour is
	 * written as bright pre-exposed radiance (about 10x the display white), so bloom makes it glow; in RGBA8 it stays as it was.
	 */
	public static String lightning(String generated) {
		int at = generated.indexOf(LIGHTNING_RESULT);
		if (!ShadeWeather.MODULE || !ShadeWeather.LIGHTNING || !generated.contains(FRAGMENT_ENTRY) || at < 0) return generated;
		int end = generated.indexOf(';', at) + 1;
		String patched = generated.substring(0, end)
			+ "\n#ifdef MCOPT_HDR\n    out.fragColor.rgb = min(out.fragColor.rgb * float3(30.0, 33.0, 40.0), float3(6.0e4));\n#endif" + generated.substring(end);
		return patched;
	}

	private static final String FRAGMENT_ENTRY = "fragment main0_out main0(";
	private static final Pattern COLOR0 = Pattern.compile("(?:float4|half4)\\s+(\\w+)\\s*\\[\\[color\\(0\\)\\]\\]");

	/**
	 * A game fragment stage (SPIRV-Cross output) for the HDR world target: its color(0) result, display-referred sRGB as it
	 * would have stored into RGBA8, goes through shadeLdrToHdr (ShadeLook at buffer(17)) before each return, so vanilla-lit
	 * entities, particles, block outlines... land in the HDR image at the value the tone map turns back into the same colour.
	 * Stages of another shape (no color output, a void entry) are returned unchanged.
	 */
	public static String hdrFragment(String msl) {
		int sig = msl.indexOf(FRAGMENT_ENTRY);
		if (sig < 0) return msl;
		Matcher m = COLOR0.matcher(msl);
		if (!m.find() || m.start() > sig) return msl;
		String member = m.group(1);
		int open = sig + FRAGMENT_ENTRY.length() - 1, depth = 0, close = -1;
		for (int i = open; i < msl.length(); i++) {
			char c = msl.charAt(i);
			if (c == '(') depth++;
			else if (c == ')' && --depth == 0) {
				close = i;
				break;
			}
		}
		if (close < 0) return msl;
		String head = msl.substring(0, close) + ", constant ShadeLook& mcoptShadeLook [[buffer(17)]]";
		String body = msl.substring(close).replace("return out;", "{ out." + member + " = shadeLdrToHdr(out." + member + ", mcoptShadeLook); return out; }");
		return look() + head + body;
	}

	/** Whether colorFormats are the lit hand's tagged RGBA8 (ShadeEntity.HAND_FORMAT). */
	static boolean handTarget(int[] colorFormats) {
		return colorFormats.length == 1 && colorFormats[0] == ShadeEntity.HAND_FORMAT;
	}

	/** Whether colorFormats are an HDR world target's (one color attachment of the HDR format). */
	static boolean hdrTarget(int[] colorFormats) {
		if (colorFormats.length != 1) return false;
		int f = colorFormats[0] & ~LEAN_MASK;
		return f == ShadeRender.RGBA16F || f == ShadeRender.RG11B10F;
	}

	/** MetalShaderRegistry's format adapter for the HDR world target (see the class comment). */
	static final MetalShaderRegistry.FormatAdapter FORMAT_ADAPTER = new MetalShaderRegistry.FormatAdapter() {
		@Override
		public String vertex(String pipelineName, String msl, boolean registry, int[] colorFormats) {
			ShadeEntity.beginVariant(); // M3: this variant's fragment follows its own vertex stage (MetalPipeline.variant)
			if (handTarget(colorFormats)) { // M3: the lit first-person hand (ShadeEntity.HAND)
				String lit = registry ? null : ShadeEntity.vertex(pipelineName, msl);
				return lit != null ? lit : msl;
			}
			if (!hdrTarget(colorFormats)) return msl;
			if (registry) return "#define MCOPT_HDR\n" + msl;
			// (M3: vanilla's blob shadow is left out per piece on the CPU where real entity shadows replace it:
			// EntityCasters.dropBlob, EntityBlobShadowMixin)
			// M3: the game's own world stages (entities, items, block entities, particles) take the dynamic lights in their lightmap
			// (DynLightMsl, per vertex: the game's colour keeps them where ShadeEntity does not shade, outside the overworld and
			// in the pipelines it leaves alone: glint, text, leash...), then ShadeEntity's per-pixel lighting (overworld)
			String dyn = mcopt.metal.shade.light.DynLightMsl.patchVertex(pipelineName, msl);
			String lit = ShadeEntity.vertex(pipelineName, dyn); // M3: entities, items, moving blocks, particles lit by shade
			return lit != null ? lit : dyn;
		}

		@Override
		public String fragment(String pipelineName, String msl, boolean registry, int[] colorFormats) {
			if (handTarget(colorFormats)) {
				String lit = registry ? null : ShadeEntity.fragment(pipelineName, msl, true);
				return lit != null ? lit : msl;
			}
			if (!hdrTarget(colorFormats)) return msl;
			if (registry) return "#define MCOPT_HDR\n" + leanDefines(colorFormats[0]) + msl; // (M3.1 lean terrain tags: canonical keeps them only for the terrain)
			String lit = ShadeEntity.fragment(pipelineName, msl, false);
			return lit != null ? lit : ShadeBeacon.fragment(pipelineName, msl);
		}

		@Override
		public int[] canonical(String pipelineName, int[] colorFormats) {
			// M3.1: the lean tags only mean something to the Sodium terrain; any other pipeline keeps one HDR variant
			if (colorFormats.length != 1 || (colorFormats[0] & LEAN_MASK) == 0) return colorFormats;
			// the terrain keeps its three bits, the sky its aurora bit (M3.1 aurora lean), any other pipeline none
			int keep = leanTerrain(pipelineName) ? LEAN_TERRAIN | (TRANSLUCENT_TERRAIN.equals(pipelineName) ? LEAN_WATER : 0)
				: SKY.equals(pipelineName) ? LEAN_NOAURORA : 0;
			int f = colorFormats[0] & ~LEAN_MASK | colorFormats[0] & keep << LEAN_SHIFT;
			return f == colorFormats[0] ? colorFormats : new int[] {f};
		}
	};

	/**
	 * Which pipelines get their HDR variant built as soon as they compile (on the frontend's compile worker), so the first
	 * world frame that uses one doesn't compile it on the render thread: everything but the GUI and full-screen game passes.
	 */
	static int @org.jspecify.annotations.Nullable [] @org.jspecify.annotations.Nullable [] prewarm(String name) {
		if (!ShadeConfig.HDR) return null;
		String n = name.toLowerCase(java.util.Locale.ROOT);
		if (n.contains("gui") || n.contains("panorama") || n.contains("lightmap") || n.contains("blit") || n.contains("blur") || n.contains("oit_")
			|| n.contains("animate_sprite") || n.contains("crosshair") || n.contains("distanthorizons") || n.contains("post/")) return null;
		// M3: the lit hand's tagged variants too (the "Item in hand" pass: arm, held items and their glint), so its first frame
		// doesn't compile ~80 KB fragments on the render thread
		if (ShadeEntity.HAND && (ShadeEntity.PIPELINES.containsKey(name) || n.contains("glint"))) return new int[][] {{ShadeConfig.HDR_FORMAT}, {ShadeEntity.HAND_FORMAT}};
		// M3.1: the Sodium terrain's eight lean variants (ShadeLean), so a change of tag never compiles on the render thread
		if (ShadeLean.SKY && SKY.equals(name)) return new int[][] {{ShadeConfig.HDR_FORMAT}, {ShadeConfig.HDR_FORMAT | LEAN_NOAURORA << LEAN_SHIFT}};
		if (ShadeLean.ON && leanTerrain(name)) {
			// M3.3 (dims): + the Nether's four (LEAN_NETHER with or without DRY / NODL; never with OW); 2026-10-08: the
			// translucent terrain also the overworld's four with LEAN_ABOVE (and, with -Dmcopt.shade.leanDev, those with LEAN_DEV);
			// (FT2.11) and each overworld one of those also with LEAN_NOFALLS (no moving water near: the common case)
			boolean water = TRANSLUCENT_TERRAIN.equals(name);
			int extra = water ? (ShadeLean.DEV_DEFINES.isEmpty() ? 4 : 8) : 0;
			int[][] sets = new int[12 + extra + (water ? 4 + extra : 0)][];
			for (int t = 0; t < 8; t++) sets[t] = new int[] {ShadeConfig.HDR_FORMAT | t << LEAN_SHIFT};
			for (int t = 0; t < 4; t++) sets[8 + t] = new int[] {ShadeConfig.HDR_FORMAT | (LEAN_NETHER | t << 1) << LEAN_SHIFT};
			for (int t = 0; t < extra; t++) {
				int bits = LEAN_OW | (t & 3) << 1 | LEAN_ABOVE | (t >= 4 ? LEAN_DEV : 0);
				sets[12 + t] = new int[] {ShadeConfig.HDR_FORMAT | bits << LEAN_SHIFT};
			}
			if (water) {
				for (int t = 0; t < 4; t++) sets[12 + extra + t] = new int[] {ShadeConfig.HDR_FORMAT | (LEAN_OW | t << 1 | LEAN_NOFALLS) << LEAN_SHIFT};
				for (int t = 0; t < extra; t++) {
					int bits = LEAN_OW | (t & 3) << 1 | LEAN_ABOVE | (t >= 4 ? LEAN_DEV : 0) | LEAN_NOFALLS;
					sets[16 + extra + t] = new int[] {ShadeConfig.HDR_FORMAT | bits << LEAN_SHIFT};
				}
			}
			return sets;
		}
		return new int[][] {{ShadeConfig.HDR_FORMAT}};
	}

	static void register() {
		skyVertex = skyStage("sky.vs.metal");
		skyFragment = skyStage("sky.fs.metal");
		celestialVertex = skyStage("celestial.vs.metal");
		sunriseVertex = skyStage("sunrise_sunset.vs.metal");
		starsVertex = skyStage("stars.vs.metal");
		cloudFragment = prelude() + resource("clouds.fs.metal");
		endSkyVertex = skyStage("end_sky.vs.metal");
		endSkyFragment = skyStage("end_sky.fs.metal");
		for (String name : TERRAIN) MetalShaderRegistry.register(name, new MetalShaderRegistry.Variant(ShadeMsl::terrain, ShadeMsl::terrain, List.of()));
		List<String> matrices = List.of("DynamicTransforms", "Projection");
		MetalShaderRegistry.register(SKY, new MetalShaderRegistry.Variant(generated -> skyVertex, generated -> skyFragment,
			List.of("DynamicTransforms", "Projection", "Fog")));
		MetalShaderRegistry.register(CELESTIAL, new MetalShaderRegistry.Variant(generated -> celestialVertex, null, matrices));
		MetalShaderRegistry.register(SUNRISE, new MetalShaderRegistry.Variant(generated -> sunriseVertex, null, matrices));
		for (String name : CLOUDS) MetalShaderRegistry.register(name, new MetalShaderRegistry.Variant(null, generated -> cloudFragment, List.of("CloudInfo")));
		MetalShaderRegistry.register(WEATHER, new MetalShaderRegistry.Variant(ShadeWeather.MODULE && ShadeWeather.SLANT ? ShadeMsl::weatherVertex : null,
			ShadeMsl::weather, List.of()));
		if (ShadeWeather.MODULE && ShadeWeather.LIGHTNING) MetalShaderRegistry.register(LIGHTNING, new MetalShaderRegistry.Variant(null, ShadeMsl::lightning, List.of()));
		MetalShaderRegistry.register(STARS, new MetalShaderRegistry.Variant(generated -> starsVertex, null, matrices));
		if (mcopt.metal.shade.dims.DimsConfig.DIMS) {
			MetalShaderRegistry.register(END_SKY, new MetalShaderRegistry.Variant(generated -> endSkyVertex, generated -> endSkyFragment,
				List.of("DynamicTransforms", "Projection", "Sampler0")));
		}
		if (ShadeConfig.HDR) {
			mcopt.metal.shade.dh.ShadeDh.register(); // FT1: Distant Horizons' LOD terrain lit by the shade model
			MetalShaderRegistry.setFormatAdapter(FORMAT_ADAPTER);
			MetalShaderRegistry.setPrewarm(ShadeMsl::prewarm);
		}
	}
}
