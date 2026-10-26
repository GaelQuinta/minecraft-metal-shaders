// Copyright 2026 mcopt-shade contributors. Licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0). Dev tool for mcopt native shading, not part of the mod.
// Writes own/terrain.metal as OwnTerrain builds it (indie defines), with and without the shade prefix (ShadeMsl.ownPrefix).
import java.nio.file.*;
import mcopt.metal.shade.ShadeMsl;

public class OwnDump {
	public static void main(String[] a) throws Exception {
		Path out = Path.of(a[0]);
		Files.createDirectories(out);
		String terrain = new String(OwnDump.class.getResourceAsStream("/mcopt/own/terrain.metal").readAllBytes());
		// indie: mesh.exactPos (OWN_EXACT_POS) and mesh.qrec (OWN_QREC) on; vcount, tflat, tprobe off; A1_SH default
		String defines = "#define OWN_EXACT_POS 1\n#define OWN_QREC 1\n";
		Files.writeString(out.resolve("own_plain.metal"), defines + terrain);
		Files.writeString(out.resolve("own_plain_nodef.metal"), terrain);
		String prefix = ShadeMsl.ownPrefix();
		Files.writeString(out.resolve("own_shade.metal"), defines + prefix + terrain);
		// the shaded fragment stage's libraries (ShadeTerrain): the full ones and a lean variant of each kind
		int ow = ShadeMsl.LEAN_OW, dry = ShadeMsl.LEAN_DRY, nodl = ShadeMsl.LEAN_NODL;
		int[] opaque = {0, ow, ow | dry | nodl, ShadeMsl.LEAN_NETHER, ShadeMsl.LEAN_NETHER | dry | nodl};
		int[] translucent = {0, ow, ow | dry | nodl | ShadeMsl.LEAN_ABOVE, ow | dry | nodl | ShadeMsl.LEAN_ABOVE | ShadeMsl.LEAN_NOFALLS, ow | ShadeMsl.LEAN_NOFALLS,
			ShadeMsl.LEAN_NETHER | dry};
		for (int b : opaque) Files.writeString(out.resolve("frag_o_" + b + ".metal"), ShadeMsl.ownFragmentSource(false, b));
		for (int b : translucent) Files.writeString(out.resolve("frag_t_" + b + ".metal"), ShadeMsl.ownFragmentSource(true, b));
		// labPBR: validate the same terrain variants with data-map sampling/shading enabled.
		for (int b : opaque) Files.writeString(out.resolve("frag_o_pbr_" + b + ".metal"), ShadeMsl.ownFragmentSource(false, b | ShadeMsl.PBR_MATERIALS));
		for (int b : translucent) Files.writeString(out.resolve("frag_t_pbr_" + b + ".metal"), ShadeMsl.ownFragmentSource(true, b | ShadeMsl.PBR_MATERIALS));
		System.out.println("prefix " + prefix.length() + " chars, terrain " + terrain.length());
	}
}
