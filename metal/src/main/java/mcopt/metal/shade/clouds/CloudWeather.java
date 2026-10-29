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
package mcopt.metal.shade.clouds;

/**
 * The daily weather of the sky (bible E05, original): every Minecraft day gets its own humidity, warmth and wind from a
 * hash of successive half-day fronts (and mcopt.shade.clouds.seed), with clear intervals, scattered cumulus and more humid
 * fronts. Values blend smoothly during the day as well as at night; dry fronts clear both cloud layers.
 * Rain and thunder take over on top: coverage
 * closes in, bases darken, storms tower. Cosmetic and per client. Pure maths, no game types.
 */
public final class CloudWeather {
	/** Smoothed values for this frame. */
	public float coverage = 0.28f, type = 0.5f, cirrus = 0.2f, storm, windSpeed = 4f;
	/** Unit wind direction (xz). */
	public float windX = 1f, windZ = 0f;
	private boolean started;
	/** (1.1) The player's coverage offset and type last frame (a change takes the new coverage and type at once). */
	private float lastUserCoverage, lastUserType = -1f;

	/** Day values: humidity, warmth, wind, cirrus, wind angle (radians). */
	static float[] day(long day, long seed) {
		long h = mix(day * 0x9E3779B97F4A7C15L + seed * 0xD1B54A32D192ED03L + 0x2545F4914F6CDD1DL);
		float humidity = unit(h);
		float warmth = unit(h = mix(h));
		float wind = unit(h = mix(h));
		float cirrus = unit(h = mix(h));
		float angle = unit(mix(h)) * 6.2831853f;
		return new float[] {humidity, warmth, wind, cirrus, angle};
	}

	/**
	 * days: the world's clock in days (ticks / 24000; 0 = sunrise of day 0), rain/thunder 0..1, dt seconds since the last
	 * frame, snap: jump to the target (first frame, teleports, a dimension change).
	 */
	public void update(double days, float rain, float thunder, float dt, boolean snap, long seed) {
		double front = days * 2.0;
		long k = (long) Math.floor(front);
		float u = (float) (front - Math.floor(front));
		// A front lasts ten real minutes at the normal game clock. Ease both ends so no boundary snaps.
		float w = smoothstep(0.1f, 0.9f, u);
		float[] a = day(k, seed), b = day(k + 1, seed);
		float humidity = lerp(a[0], b[0], w), warmth = lerp(a[1], b[1], w), wind = lerp(a[2], b[2], w), cir = lerp(a[3], b[3], w);
		float ax = (float) Math.cos(a[4]), az = (float) Math.sin(a[4]), bx = (float) Math.cos(b[4]), bz = (float) Math.sin(b[4]);
		float dx = lerp(ax, bx, w), dz = lerp(az, bz, w), dl = (float) Math.sqrt(dx * dx + dz * dz);
		if (dl < 1e-3f) { dx = 1f; dz = 0f; dl = 1f; }
		// fair-weather days stay open; humid ones crowd; warm humid windy days tower
		float wet = smoothstep(0.32f, 0.95f, humidity);
		float cov = 0.36f * wet;
		float typ = clamp01(0.15f + 0.75f * humidity * warmth + 0.35f * wind - 0.1f);
		float cirrusAmount = 0.28f * smoothstep(0.55f, 0.95f, cir) * smoothstep(0.32f, 0.6f, humidity);
		float speed = 2.5f + 7.5f * wind * wind;
		// (1.1) the player's cloud settings (live): coverage offset on the front's (0..0.36 without it, so the clamp leaves the
		// default exact) and the day's type forced, both before the rain and thunder below, which still close in and tower
		float userCoverage = CloudConfig.userCoverage(), userType = CloudConfig.userType();
		cov = clamp01(cov + userCoverage);
		if (userType >= 0f) typ = clamp01(userType);
		boolean userChanged = userCoverage != this.lastUserCoverage || userType != this.lastUserType;
		this.lastUserCoverage = userCoverage;
		this.lastUserType = userType;
		// rain: overcast, darker; thunder: towering storm clouds
		cov = cov + (0.92f - cov) * rain;
		typ = lerp(typ, 0.9f, thunder);
		typ = lerp(typ, Math.max(typ, 0.55f), rain);
		float stormy = Math.max(rain * 0.75f, thunder);
		speed *= 1f + 0.8f * rain + 0.6f * thunder;
		if (CloudConfig.COVERAGE >= 0f) cov = clamp01(CloudConfig.COVERAGE);
		if (CloudConfig.TYPE >= 0f) typ = clamp01(CloudConfig.TYPE);
		speed *= CloudConfig.wind(); // (1.1: live)
		cirrusAmount *= 1f - 0.7f * rain;
		if (!this.started || snap) {
			this.started = true;
			this.coverage = cov;
			this.type = typ;
			this.cirrus = cirrusAmount;
			this.storm = stormy;
			this.windSpeed = speed;
			this.windX = dx / dl;
			this.windZ = dz / dl;
			return;
		}
		// rain thickens the clouds over a few seconds (the game's rain level itself ramps over ~5 s)
		float f = 1f - (float) Math.exp(-Math.max(dt, 0f) / 4f);
		this.coverage += (cov - this.coverage) * f;
		if (cov == 0f && this.coverage < 0.0001f) this.coverage = 0f;
		this.type += (typ - this.type) * f;
		// (1.1: a change in the settings screen shows at once, not over the weather's ~4 s; the history blends it in in ~1 s)
		if (userChanged) {
			this.coverage = cov;
			this.type = typ;
		}
		this.cirrus += (cirrusAmount - this.cirrus) * f;
		this.storm += (stormy - this.storm) * f;
		this.windSpeed += (speed - this.windSpeed) * f;
		float nx = this.windX + (dx / dl - this.windX) * f, nz = this.windZ + (dz / dl - this.windZ) * f;
		float nl = (float) Math.sqrt(nx * nx + nz * nz);
		if (nl > 1e-3f) {
			this.windX = nx / nl;
			this.windZ = nz / nl;
		}
	}

	private static long mix(long z) { // SplitMix64 finalizer (public domain)
		z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9L;
		z = (z ^ (z >>> 27)) * 0x94D049BB133111EBL;
		return z ^ (z >>> 31);
	}

	private static float unit(long h) {
		return (h >>> 40) / (float) (1L << 24);
	}

	static float lerp(float a, float b, float t) {
		return a + (b - a) * t;
	}

	static float clamp01(float v) {
		return Math.max(0f, Math.min(1f, v));
	}

	static float smoothstep(float e0, float e1, float x) {
		float t = clamp01((x - e0) / (e1 - e0));
		return t * t * (3f - 2f * t);
	}

	public String describe() {
		return String.format(java.util.Locale.ROOT, "coverage %.2f type %.2f cirrus %.2f storm %.2f wind %.1f b/s (%.2f, %.2f)", this.coverage, this.type,
			this.cirrus, this.storm, this.windSpeed, this.windX, this.windZ);
	}
}
