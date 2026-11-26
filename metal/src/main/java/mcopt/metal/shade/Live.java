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

import java.util.Locale;
import java.util.concurrent.ConcurrentHashMap;

/**
 * (1.1) Settings read live: a system property parsed only when its text changes (the settings screen, a bench variant or
 * config/mcopt.properties at startup set it), so a module can read it every frame for the price of a map lookup. A missing or
 * unparsable value gives the caller's default, which is where preset-dependent defaults come from.
 */
public final class Live {
	private record Entry(String raw, float f, int i, int b, String low) {
	}

	private static final ConcurrentHashMap<String, Entry> CACHE = new ConcurrentHashMap<>();
	private static final Entry MISSING = new Entry(null, Float.NaN, Integer.MIN_VALUE, -1, null);

	private Live() {
	}

	private static Entry entry(String key) {
		String raw = System.getProperty(key);
		if (raw == null) return MISSING;
		Entry e = CACHE.get(key);
		if (e != null && e.raw == raw) return e; // the same String: unchanged since it was parsed
		String trimmed = raw.trim();
		String low = trimmed.toLowerCase(Locale.ROOT);
		int b = "true".equals(low) ? 1 : "false".equals(low) ? 0 : -1;
		float f;
		try {
			f = Float.parseFloat(trimmed);
		} catch (NumberFormatException ex) {
			f = Float.NaN;
		}
		e = new Entry(raw, f, Float.isNaN(f) ? Integer.MIN_VALUE : Math.round(f), b, low);
		CACHE.put(key, e);
		return e;
	}

	/** The property as a float, def when it is missing or not a number. */
	public static float f(String key, float def) {
		float v = entry(key).f;
		return Float.isNaN(v) ? def : v;
	}

	/** The property as a float clamped to min..max, def when missing. */
	public static float f(String key, float def, float min, float max) {
		return Math.max(min, Math.min(max, f(key, def)));
	}

	/** The property as an int (a float value rounds), def when missing. */
	public static int i(String key, int def) {
		int v = entry(key).i;
		return v == Integer.MIN_VALUE ? def : v;
	}

	/** The property as a boolean: "true" / "false" (any case), def otherwise. */
	public static boolean b(String key, boolean def) {
		int b = entry(key).b;
		return b < 0 ? def : b != 0;
	}

	/** The property as lower-case trimmed text, def when missing. */
	public static String s(String key, String def) {
		String s = entry(key).low;
		return s == null ? def : s;
	}
}
