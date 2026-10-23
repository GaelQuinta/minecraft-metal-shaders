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

import com.google.gson.JsonParser;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import net.minecraft.client.Minecraft;

/**
 * (2026-10-11) The pause menu buttons' language: Spanish when the game's language is any Spanish (es_mx, es_es, ...), else
 * English. Chosen in code from Options.languageCode instead of lang files: a mod's assets need Fabric API's resource loader,
 * and the instance without Distant Horizons has no Fabric API.
 * (2026-10-19) Chinese: the English text through a table in the jar (mcopt/shade/lang/zh_cn.json; zh_tw.json, with Taiwan
 * terms, for zh_tw and zh_hk), read from the classpath like the shaders. A text the table lacks stays English;
 * tools/lang/check.py lists them.
 */
public final class ShadeLang {
	private static String tableFor; // the language code table was loaded for
	private static Map<String, String> table = Map.of();

	private ShadeLang() {
	}

	private static String code() {
		Minecraft mc = Minecraft.getInstance();
		return mc != null && mc.options != null && mc.options.languageCode != null ? mc.options.languageCode : "";
	}

	/** The text in the game's language. */
	public static String t(String spanish, String english) {
		String code = code();
		return code.startsWith("es") ? spanish : table(code).getOrDefault(english, english);
	}

	/** English text -> the text in code's language: empty but for Chinese. Loaded again when the game's language changes. */
	private static synchronized Map<String, String> table(String code) {
		if (code.equals(tableFor)) return table;
		String name = code.equals("zh_cn") ? "zh_cn" : code.startsWith("zh_") ? "zh_tw" : null;
		Map<String, String> t = new HashMap<>();
		if (name != null) {
			try (InputStream in = ShadeLang.class.getResourceAsStream("/mcopt/shade/lang/" + name + ".json")) {
				JsonParser.parseReader(new InputStreamReader(in, StandardCharsets.UTF_8)).getAsJsonObject().entrySet()
					.forEach(e -> t.put(e.getKey(), e.getValue().getAsString()));
			} catch (IOException e) {
				throw new UncheckedIOException(e);
			}
		}
		tableFor = code;
		table = t;
		return t;
	}
}
