// Copyright 2026 mcopt-shade contributors. Apache-2.0.
package mcopt.metal.shade;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Add only the beam's extra radiance; the game's original fog colour and alpha stay intact. */
public final class ShadeBeacon {
	private ShadeBeacon() {}

	private static final Pattern FOG = Pattern.compile("constant Fog& (\\w+) \\[\\[buffer\\(\\d+\\)\\]\\]");
	private static final Pattern POSITION = Pattern.compile("float4 (\\w+) \\[\\[position\\]\\]");
	private static final Pattern RESULT = Pattern.compile("out\\.(\\w+) = calculateFinalColor\\((\\w+), (\\w+), (\\w+)\\);");

	/** Unrecognised resource-pack stages and every other pipeline keep the standard HDR conversion. */
	public static String fragment(String pipelineName, String msl) {
		String hdr = ShadeMsl.hdrFragment(msl);
		if (!(pipelineName.equals("minecraft:pipeline/beacon_beam_opaque")
			|| pipelineName.equals("minecraft:pipeline/beacon_beam_translucent"))) return hdr;
		int entry = msl.indexOf("fragment main0_out main0(");
		if (entry < 0 || hdr.equals(msl)) return hdr;
		String body = msl.substring(entry);
		Matcher fog = FOG.matcher(body), position = POSITION.matcher(body), result = RESULT.matcher(body);
		if (!fog.find() || !position.find() || !result.find()) return hdr;
		String f = fog.group(1), pos = position.group(1), member = result.group(1), raw = result.group(2);
		if (!(result.group(3).equals(f) && result.group(4).equals(pos)
			|| result.group(4).equals(f) && result.group(3).equals(pos))) return hdr;
		// The raw colour is a local at the return site. Restrict to the game's single-return entry shape.
		if (body.indexOf("return out;") != body.lastIndexOf("return out;") || result.find()) return hdr;
		String converted = "out." + member + " = shadeLdrToHdr(out." + member + ", mcoptShadeLook); return out;";
		String boost = "out." + member + ".rgb = min(out." + member + ".rgb + shadeBeaconEmission(" + raw + ".rgb, 1.0 / " + pos
			+ ".w, float4(" + f + ".FogEnvironmentalStart, " + f + ".FogEnvironmentalEnd, " + f + ".FogRenderDistanceStart, " + f
			+ ".FogRenderDistanceEnd), " + f + ".FogColor.a, mcoptShadeLook), float3(60000.0));";
		if (!hdr.contains(converted)) return hdr;
		return ShadeMsl.look() + ShadeMsl.resource("shade_beacon.metal") + "\n"
			+ hdr.substring(ShadeMsl.look().length()).replace(converted, converted.replace("return out;", boost + " return out;"));
	}
}
