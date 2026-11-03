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

import java.util.Locale;
import mcopt.metal.shade.ShadeMsl;

/**
 * The dynamic lights' MSL (free of game types: ShadeMsl uses it while mixins bootstrap):
 * <ul>
 * <li>{@link #prelude()}: "#define SHADE_DYNLIGHT" + dynlight.metal, appended to every shaded stage's prelude (the Sodium
 * terrain fragment then adds the lights; other shaded stages ignore it). Empty with the module off, so the shaders are
 * M2.1's byte for byte.</li>
 * <li>{@link #patchVertex}: the game's own vertex stages that sample the lightmap (entities, items, armour, block entities,
 * banners, particles, text, leashes; SPIRV-Cross output: {@code sample_lightmap(Sampler2, Sampler2Smplr, uv)}) get each such
 * lightmap colour passed through shadeDynLightmap with the vertex position (camera-relative world, as vanilla's fog uses it)
 * and normal, for their HDR world variant only (the format adapter): the hand, the GUI and anything drawn outside the world
 * pass keep the game's stages. A stage of another shape is returned unchanged.</li>
 * </ul>
 */
public final class DynLightMsl {
	public static final boolean ON = DynLightConfig.ENABLED;
	private static final String CALL = "sample_lightmap(Sampler2, Sampler2Smplr, ";
	private static final String VERTEX_ENTRY = "vertex main0_out main0(";
	private static volatile String prelude, module;

	private DynLightMsl() {
	}

	/** "#define SHADE_DYNLIGHT" + dynlight.metal, or "" with the module off. */
	public static String prelude() {
		if (!ON) return "";
		if (prelude == null) prelude = "#define SHADE_DYNLIGHT\n" + module() + "\n";
		return prelude;
	}

	static String module() {
		if (module == null) module = ShadeMsl.resource("torch_light.metal") + "\n" + ShadeMsl.resource("dynlight.metal");
		return module;
	}

	/** Whether a game pipeline's vertex stage gets the lights (by name: not terrain, OIT, weather, debug or GUI pipelines). */
	static boolean wants(String pipelineName) {
		String n = pipelineName.toLowerCase(Locale.ROOT);
		return !(n.contains("terrain") || n.contains("oit_") || n.contains("weather") || n.contains("wireframe") || n.contains("gui") || n.contains("lightning"));
	}

	/** The vertex stage with dynamic lights in its lightmap colours (see the class comment), or msl unchanged. */
	public static String patchVertex(String pipelineName, String msl) {
		if (!ON || !DynLightConfig.ENTITIES || !wants(pipelineName)) return msl;
		return patch(msl);
	}

	/** The patch itself (validation tools call it on dumped stages). */
	public static String patch(String msl) {
		int sig = msl.indexOf(VERTEX_ENTRY);
		if (sig < 0 || msl.indexOf(CALL, sig) < 0 || !msl.contains("in.Position") || msl.contains("mcoptDynLights")) return msl;
		int close = closeParen(msl, sig + VERTEX_ENTRY.length() - 1);
		if (close < 0) return msl;
		String normal = msl.substring(0, sig).matches("(?s).*\\bfloat3 Normal \\[\\[attribute\\(\\d+\\)\\]\\];.*") ? "in.Normal" : "float3(0.0)";
		StringBuilder body = new StringBuilder();
		int from = close, at;
		while ((at = msl.indexOf(CALL, from)) >= 0) {
			int end = closeParen(msl, at + "sample_lightmap".length());
			if (end < 0) return msl;
			String uv = msl.substring(at + CALL.length(), end).trim();
			if (!uv.matches("[A-Za-z_][A-Za-z0-9_.]*")) return msl; // a plain variable (SPIRV-Cross's param_N), evaluated twice
			body.append(msl, from, at);
			body.append("shadeDynLightmap(").append(msl, at, end + 1).append(", ").append(uv).append(", in.Position, ").append(normal)
				.append(", Sampler2, Sampler2Smplr, mcoptDynLights, mcoptDynVis)");
			from = end + 1;
		}
		body.append(msl, from, msl.length());
		return module() + "\n" + msl.substring(0, close) + ", constant ShadeDynLights& mcoptDynLights [[buffer(24)]], texture3d<half> mcoptDynVis [[texture(23)]]"
			+ body;
	}

	private static int closeParen(String s, int open) {
		int depth = 0;
		for (int i = open; i < s.length(); i++) {
			char c = s.charAt(i);
			if (c == '(') depth++;
			else if (c == ')' && --depth == 0) return i;
		}
		return -1;
	}
}
