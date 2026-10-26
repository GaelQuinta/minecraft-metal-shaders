// Copyright 2026 mcopt-shade contributors. Licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0). Dev tool for mcopt native shading, not part of the mod.
import java.nio.file.*;
import java.util.*;
import mcopt.metal.MetalShaderRegistry;
import mcopt.metal.shade.ShadeMsl;

/** Writes every shaded MSL variant exactly as MetalPipeline assembles it at runtime (plus the upstream ones), for mslcheck/pipecheck. */
public class ShadeMslDump {
	static String msl(String name) throws Exception {
		return new String(ShadeMslDump.class.getResourceAsStream("/mcopt/metal/msl/" + name).readAllBytes());
	}
	/** (v12, mcopt 0.3) Sodium's terrain is gone: its variants are dumped only when its sources are there (own terrain: tools/shade/own/check.sh). */
	static boolean sodium() {
		return ShadeMslDump.class.getResource("/mcopt/metal/msl/sodium_terrain.vs.metal") != null;
	}
	public static void main(String[] a) throws Exception {
		Path out = Path.of(a[0]);
		Files.createDirectories(out);
		String slotsT = MetalShaderRegistry.slotDefines(List.of("u_Globals", "u_SectionTimeInfo", "u_LightTex", "u_BlockTex"));
		String vs = sodium() ? msl("sodium_terrain.vs.metal") : "", fs = sodium() ? msl("sodium_terrain.fs.metal") : "";
		Map<String, String> defs = new LinkedHashMap<>();
		if (!sodium()) System.out.println("ShadeMslDump: no Sodium terrain sources (mcopt 0.3): terrain variants skipped");
		else {
		defs.put("solid", ""); defs.put("cutout", "#define ALPHA_CUTOUT 0.5\n"); defs.put("translucent", "#define ALPHA_CUTOUT 0.01\n");
		for (var e : defs.entrySet()) {
			// upstream (flag off)
			Files.writeString(out.resolve("up_" + e.getKey() + ".vs.metal"), vs);
			Files.writeString(out.resolve("up_" + e.getKey() + ".fs.metal"), e.getValue() + fs);
			// shaded
			Files.writeString(out.resolve("shade_" + e.getKey() + ".vs.metal"), slotsT + ShadeMsl.terrain(vs));
			Files.writeString(out.resolve("shade_" + e.getKey() + ".fs.metal"), slotsT + ShadeMsl.terrain(e.getValue() + fs));
			// M2 HDR variants (what MetalPipeline.variant builds through ShadeMsl's format adapter)
			Files.writeString(out.resolve("hdr_" + e.getKey() + ".vs.metal"), "#define MCOPT_HDR\n" + slotsT + ShadeMsl.terrain(vs));
			Files.writeString(out.resolve("hdr_" + e.getKey() + ".fs.metal"), "#define MCOPT_HDR\n" + slotsT + ShadeMsl.terrain(e.getValue() + fs));
			// M3.1 / M3.3 lean terrain variants (ShadeLean): the overworld's and the Nether's (compiled only)
			Files.writeString(out.resolve("hdr_" + e.getKey() + "_leanow.fs.metal"), "#define MCOPT_HDR\n#define SHADE_LEAN_OW\n#define SHADE_LEAN_DRY\n#define SHADE_LEAN_NODL\n" + slotsT + ShadeMsl.terrain(e.getValue() + fs));
			Files.writeString(out.resolve("hdr_" + e.getKey() + "_leannether.fs.metal"), "#define MCOPT_HDR\n#define SHADE_LEAN_NETHER\n" + slotsT + ShadeMsl.terrain(e.getValue() + fs));
			// FT2.11: the overworld's water seen from above with dynamic lights, with and without the moving water's look (LEAN_NOFALLS)
			Files.writeString(out.resolve("hdr_" + e.getKey() + "_leanabove.fs.metal"), "#define MCOPT_HDR\n#define SHADE_LEAN_OW\n#define SHADE_LEAN_ABOVE\n" + slotsT + ShadeMsl.terrain(e.getValue() + fs));
			Files.writeString(out.resolve("hdr_" + e.getKey() + "_leannofalls.fs.metal"), "#define MCOPT_HDR\n#define SHADE_LEAN_OW\n#define SHADE_LEAN_DRY\n#define SHADE_LEAN_NODL\n#define SHADE_LEAN_ABOVE\n#define SHADE_LEAN_NOFALLS\n" + slotsT + ShadeMsl.terrain(e.getValue() + fs));
			Files.writeString(out.resolve("hdr_" + e.getKey() + "_leannetherdry.fs.metal"), "#define MCOPT_HDR\n#define SHADE_LEAN_NETHER\n#define SHADE_LEAN_DRY\n#define SHADE_LEAN_NODL\n" + slotsT + ShadeMsl.terrain(e.getValue() + fs));
			if (e.getKey().equals("translucent")) {
				// the translucent fragment without the water module (mcopt.shade.water=false: M1's water)
				Files.writeString(out.resolve("shade_translucentnowater.vs.metal"), slotsT + ShadeMsl.terrain(vs));
				Files.writeString(out.resolve("shade_translucentnowater.fs.metal"), slotsT + ShadeMsl.terrain(e.getValue() + fs, false));
				Files.writeString(out.resolve("hdr_translucentnowater.vs.metal"), "#define MCOPT_HDR\n" + slotsT + ShadeMsl.terrain(vs));
				Files.writeString(out.resolve("hdr_translucentnowater.fs.metal"), "#define MCOPT_HDR\n" + slotsT + ShadeMsl.terrain(e.getValue() + fs, false));
			}
			if (!e.getKey().equals("translucent")) {
				Files.writeString(out.resolve("up_" + e.getKey() + ".pulled.vs.metal"), "#define PULLED\n" + vs);
				Files.writeString(out.resolve("shade_" + e.getKey() + ".pulled.vs.metal"), slotsT + ShadeMsl.terrain("#define PULLED\n" + vs));
				Files.writeString(out.resolve("hdr_" + e.getKey() + ".pulled.vs.metal"), "#define MCOPT_HDR\n" + slotsT + ShadeMsl.terrain("#define PULLED\n" + vs));
			}
		}
		}
		// sky pipelines, with two different uniform orders (renderpearl numbers them by use)
		List<List<String>> orders = List.of(List.of("Fog", "DynamicTransforms", "Projection"), List.of("Projection", "DynamicTransforms", "Fog"));
		for (int i = 0; i < orders.size(); i++) {
			String s = MetalShaderRegistry.slotDefines(orders.get(i));
			Files.writeString(out.resolve("sky" + i + ".vs.metal"), s + ShadeMsl.skyStage("sky.vs.metal"));
			Files.writeString(out.resolve("sky" + i + ".fs.metal"), s + ShadeMsl.skyStage("sky.fs.metal"));
			Files.writeString(out.resolve("hdrsky" + i + ".vs.metal"), "#define MCOPT_HDR\n" + s + ShadeMsl.skyStage("sky.vs.metal"));
			Files.writeString(out.resolve("hdrsky" + i + ".fs.metal"), "#define MCOPT_HDR\n" + s + ShadeMsl.skyStage("sky.fs.metal"));
			// M3.1 / M3.3: the sky's lean variant (no per-pixel aurora; still reads the reduced-resolution aurora texture)
			Files.writeString(out.resolve("hdrskylean" + i + ".fs.metal"), "#define MCOPT_HDR\n#define SHADE_LEAN_NOAURORA\n" + s + ShadeMsl.skyStage("sky.fs.metal"));
		}
		// M3.3 (dims): the reduced-resolution aurora pass (ShadeAurora)
		Files.writeString(out.resolve("aurora_pass.metal"), mcopt.metal.shade.ShadeRender.prelude() + "\n" + mcopt.metal.shade.ShadeRender.postSource() + "\n" + ShadeMsl.resource("aurora.metal"));
		String s2 = MetalShaderRegistry.slotDefines(List.of("Projection", "DynamicTransforms", "Sampler0"));
		Files.writeString(out.resolve("celestial.vs.metal"), s2 + ShadeMsl.skyStage("celestial.vs.metal"));
		String s3 = MetalShaderRegistry.slotDefines(List.of("DynamicTransforms", "Projection"));
		Files.writeString(out.resolve("sunrise.vs.metal"), s3 + ShadeMsl.skyStage("sunrise_sunset.vs.metal"));
		Files.writeString(out.resolve("stars.vs.metal"), s3 + ShadeMsl.skyStage("stars.vs.metal"));
		// FT1: Distant Horizons' LOD terrain stages (ShadeDh), with DH's uniform order (shared, unique, lightmap, frag, atlas)
		String sd = MetalShaderRegistry.slotDefines(List.of("vertSharedUniformBlock", "vertUniqueUniformBlock", "uLightMap", "fragUniformBlock", "uBlockAtlas"));
		Files.writeString(out.resolve("dh_terrain.vs.metal"), sd + ShadeMsl.prelude() + ShadeMsl.resource("dh_terrain.vs.metal"));
		Files.writeString(out.resolve("dh_terrain.fs.metal"), sd + ShadeMsl.prelude() + ShadeMsl.resource("dh_terrain.fs.metal"));
		Files.writeString(out.resolve("dh_terrain_water.fs.metal"), sd + ShadeMsl.prelude() + "#define SHADE_DH_TRANSLUCENT\n" + ShadeMsl.resource("dh_terrain.fs.metal"));
		Files.writeString(out.resolve("dh_terrain_jitter.vs.metal"), sd + ShadeMsl.prelude() + "#define SHADE_DH_JITTER\n#define SHADE_DH_SKY_HIGH\n" + ShadeMsl.resource("dh_terrain.vs.metal"));
		// FT2: DH's far fade and copy (ShadeDh.DIRECT), DH's uniform orders; the copy also as the HDR target's variant
		String sf = MetalShaderRegistry.slotDefines(List.of("fragUniformBlock", "uMcColorTexture", "uDhColorTexture", "uDhDepthTexture"));
		Files.writeString(out.resolve("dh_far_fade.fs.metal"), sf + ShadeMsl.prelude() + ShadeMsl.resource("dh_far_fade.fs.metal"));
		String sc = MetalShaderRegistry.slotDefines(List.of("uCopyTexture"));
		Files.writeString(out.resolve("dh_copy.fs.metal"), sc + ShadeMsl.prelude() + ShadeMsl.resource("dh_copy.fs.metal"));
		Files.writeString(out.resolve("dh_copy_hdr.fs.metal"), "#define MCOPT_HDR\n" + sc + ShadeMsl.prelude() + ShadeMsl.resource("dh_copy.fs.metal"));
		Files.writeString(out.resolve("sky_lut.metal"), ShadeMsl.lut());
		// M3 End sky box (mcopt.shade.dims): two uniform orders, LDR and HDR
		List<List<String>> endOrders = List.of(List.of("Projection", "DynamicTransforms", "Sampler0"), List.of("Sampler0", "DynamicTransforms", "Projection"));
		for (int i = 0; i < endOrders.size(); i++) {
			String s = MetalShaderRegistry.slotDefines(endOrders.get(i));
			Files.writeString(out.resolve("endsky" + i + ".vs.metal"), s + ShadeMsl.skyStage("end_sky.vs.metal"));
			Files.writeString(out.resolve("endsky" + i + ".fs.metal"), s + ShadeMsl.skyStage("end_sky.fs.metal"));
			Files.writeString(out.resolve("hdrendsky" + i + ".vs.metal"), "#define MCOPT_HDR\n" + s + ShadeMsl.skyStage("end_sky.vs.metal"));
			Files.writeString(out.resolve("hdrendsky" + i + ".fs.metal"), "#define MCOPT_HDR\n" + s + ShadeMsl.skyStage("end_sky.fs.metal"));
		}
		// M2 post chain (one library: bloom, final, bridge, exposure kernels, Milky Way bake)
		Files.writeString(out.resolve("post.metal"), ShadeMsl.post());
		Files.writeString(out.resolve("motion_blur.metal"), ShadeMsl.prelude() + ShadeMsl.resource("motion_blur.metal"));
		// the water module's own passes (wave bake, SSR coarse depth): ShadeWater.library
		Files.writeString(out.resolve("water_passes.metal"), ShadeMsl.post() + mcopt.metal.shade.water.ShadeWater.prelude());
		// M3 weather: the puddle/snow noise bake (ShadeWeather.bakeNoise)
		Files.writeString(out.resolve("weather_noise.metal"), ShadeMsl.post() + "#define SHADE_WX_NOISE_BAKE\n" + mcopt.metal.shade.weather.ShadeWeather.prelude());
		Files.writeString(out.resolve("vl.metal"), mcopt.metal.shade.vl.VlConfig.source()); // volumetric light (mcvl.m)
		Files.writeString(out.resolve("dynlight_vis.metal"), "#define SHADE_DL_KERNELS\n" + ShadeMsl.resource("dynlight.metal") + "\n" + ShadeMsl.resource("dynlight_vis.metal")); // M3 dynamic lights: visibility kernel (mcdynlight.m)
		Files.writeString(out.resolve("clouds_passes.metal"), mcopt.metal.shade.clouds.CloudConfig.source()); // M3 volumetric clouds (mcclouds.m)
		// clouds: own fragment (CloudInfo slot from the defines); vanilla's generated vertex stage comes from a dump if given
		String s4 = MetalShaderRegistry.slotDefines(List.of("CloudInfo", "Projection", "DynamicTransforms", "Fog"));
		Files.writeString(out.resolve("clouds.fs.metal"), s4 + ShadeMsl.prelude() + ShadeMsl.resource("clouds.fs.metal"));
		Files.writeString(out.resolve("hdrclouds.fs.metal"), "#define MCOPT_HDR\n" + s4 + ShadeMsl.prelude() + ShadeMsl.resource("clouds.fs.metal"));
		// weather: patched generated fragment, from a -Dmcopt.metal.dumpMsl directory (MCOPT_GEN_DIR) when available
		String gen = System.getenv("MCOPT_GEN_DIR");
		if (gen != null) {
			java.nio.file.Path w = java.nio.file.Path.of(gen, "minecraft_pipeline_weather.fs.metal");
			if (Files.exists(w)) {
				Files.writeString(out.resolve("weather.fs.metal"), ShadeMsl.weather(Files.readString(w)));
				Files.writeString(out.resolve("hdrweather.fs.metal"), "#define MCOPT_HDR\n" + ShadeMsl.weather(Files.readString(w)));
			}
			// M3 entity lighting: the HDR variants of the game's entity / item / block / particle stages, patched (ShadeEntity)
			Path ent = out.resolve("entity");
			Files.createDirectories(ent);
			// (same-named pipelines with other sources are dumped as NAME~1, NAME~2...: e.g. the plain item_cutout and its glints)
			for (String name : mcopt.metal.shade.ShadeEntityAccess.pipelines()) for (int k = 0; k < 8; k++) {
				String file = name.replaceAll("[^A-Za-z0-9._-]", "_") + (k == 0 ? "" : "~" + k);
				Path evs = Path.of(gen, file + ".vs.metal"), efs = Path.of(gen, file + ".fs.metal");
				if (!Files.exists(evs) || !Files.exists(efs)) break;
				String v = mcopt.metal.shade.ShadeEntityAccess.vertex(name, Files.readString(evs));
				String f = mcopt.metal.shade.ShadeEntityAccess.fragment(name, Files.readString(efs));
				if (v == null || f == null) {
					System.out.println("entity lighting: not patched: " + file);
					continue;
				}
				Files.writeString(ent.resolve(file + ".vs.metal"), v);
				Files.writeString(ent.resolve(file + ".fs.metal"), f);
				String h = mcopt.metal.shade.ShadeEntityAccess.fragmentHand(name, Files.readString(efs));
				if (h != null) {
					Files.writeString(ent.resolve("hand_" + file + ".vs.metal"), v);
					Files.writeString(ent.resolve("hand_" + file + ".fs.metal"), h);
				}
			}
			// M3 weather: the slanted weather vertex stage and the HDR lightning bolt
			java.nio.file.Path wv = java.nio.file.Path.of(gen, "minecraft_pipeline_weather.vs.metal");
			if (Files.exists(wv)) {
				Files.writeString(out.resolve("weather.vs.metal"), ShadeMsl.weatherVertex(Files.readString(wv)));
				Files.writeString(out.resolve("hdrweather.vs.metal"), "#define MCOPT_HDR\n" + ShadeMsl.weatherVertex(Files.readString(wv)));
			}
			java.nio.file.Path lf = java.nio.file.Path.of(gen, "minecraft_pipeline_lightning.fs.metal");
			if (Files.exists(lf)) {
				Files.writeString(out.resolve("lightning.fs.metal"), ShadeMsl.lightning(Files.readString(lf)));
				Files.writeString(out.resolve("hdrlightning.fs.metal"), "#define MCOPT_HDR\n" + ShadeMsl.lightning(Files.readString(lf)));
			}
			// every generated game fragment, converted for the HDR world target (ShadeMsl.hdrFragment)
			Path hdrGen = out.resolve("hdrgen");
			Files.createDirectories(hdrGen);
			try (var files = Files.list(Path.of(gen))) {
				for (Path f : files.filter(x -> x.getFileName().toString().endsWith(".fs.metal")).toList()) {
					Files.writeString(hdrGen.resolve(f.getFileName()), ShadeMsl.hdrFragment(Files.readString(f)));
				}
			}
			// M3: the game's vertex stages with the dynamic lights in their lightmap (DynLightMsl.patch), as their HDR variants get them
			try (var files = Files.list(Path.of(gen))) {
				int n = 0;
				for (Path f : files.filter(x -> x.getFileName().toString().endsWith(".vs.metal")).toList()) {
					String src = Files.readString(f), patched = mcopt.metal.shade.light.DynLightMsl.patch(src);
					if (patched != src) {
						Files.writeString(hdrGen.resolve(f.getFileName()), patched);
						n++;
					}
				}
				System.out.println("dynamic lights: " + n + " game vertex stages patched");
			}
		}
	}
}
