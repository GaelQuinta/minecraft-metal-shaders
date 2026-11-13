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
 * The CPU twin of shade_common.metal's atmosphere (shadeColumn, shadeScatter, shadeSkyRadiance), line for line, plus what
 * only the CPU computes once per frame from it: the light reaching the ground from the sun or moon, sky and ground ambient,
 * the horizon colour table the terrain fogs into, and the exposure the eye adapts to. Keeping one model for the sky pixels,
 * the terrain's light and its fog is what makes the horizon seamless. Pure math, no game types.
 */
public final class ShadeSky {
	static final float R_GROUND = 6360f, R_TOP = 6420f, ALTITUDE = 0.5f, H_R = 8f, H_M = 1.2f, MIE_G = 0.78f;
	static final int SAMPLES = 8;
	static final float[] BETA_R = {5.802e-3f, 13.558e-3f, 33.1e-3f};
	static final float BETA_M = 3.996e-3f, BETA_M_EXT = 4.440e-3f;
	static final float[] BETA_O = {0.650e-3f * 2.2f, 1.881e-3f * 2.2f, 0.085e-3f * 2.2f};
	/** Moonlight tint, as the shader's shadeSkyRadiance applies it. */
	static final float[] MOON_TINT = {0.85f, 0.95f, 1.25f};
	static final float[] AIRGLOW = {0.0003f, 0.00045f, 0.0009f};

	// ---- art direction: the knobs, in one place ----
	/** Sun irradiance in the scattering integral (arbitrary units; exposure maps them to the screen). */
	public static final float SUN_INTENSITY = 20f;
	/** Full-moon intensity relative to the sun: far brighter than reality so nights are playable. */
	public static final float MOON_INTENSITY = SUN_INTENSITY * 0.010f;
	/** Sky and fog brightness relative to the physical single-scattering result (games show a brighter sky than physics). */
	public static final float SKY_BRIGHTNESS = 3.4f;
	/** Saturation of the sky's colour (1 = the physical single-scattering result, which reads greyish-lavender on the horizon). */
	public static final float SKY_SATURATION = 1.3f;
	/**
	 * Sky light on terrain relative to the physical sky irradiance: softer shadows, the stylized look. At 4 the sun is about
	 * 4-5x the fill at noon, so lit and shaded faces read clearly apart (8 flattened the frame back toward vanilla).
	 */
	public static final float AMBIENT_BOOST = 4.0f;
	/** How far the sky's fill light is pulled toward grey: physically it's deep blue, which reads cold on pixel art. */
	public static final float AMBIENT_DESATURATE = 0.3f;
	/** Neutral daylight fill; the sky pixels keep their atmospheric colour. */
	public static final float DAY_AMBIENT_DESATURATE = 0.8f;
	/** Gentler dusk fill lets the warm direct sun set the colour without blue shadows needing a global warm grade. */
	public static final float SUNSET_AMBIENT_DESATURATE = 0.65f;
	/** Exposure: the average scene luminance maps to this; clamped to the range below, adapted over ADAPT_SECONDS. */
	public static final float KEY = 0.61f, EXPOSURE_MIN = 0.1f, EXPOSURE_MAX = 1.6f, ADAPT_SECONDS = 1.2f;
	/** How much of a brightness change the eye compensates: 1 = all of it (every scene as bright), 0 = none. */
	public static final float ADAPTATION = 0.5f;
	/** Geometry of the fixed 23-direction ambient quadrature, independent of sun, weather and camera. */
	private static final float[][] AMBIENT_SAMPLES = ambientSamples();
	private static float[][] ambientSamples() {
		float[][] bands = {{0f, 0.35f, 8}, {0.35f, 0.8f, 8}, {0.8f, 1.2f, 6}, {1.2f, 1.5707963f, 1}};
		float[][] samples = new float[23][4];
		int at = 0;
		for (float[] band : bands) {
			float lo = band[0], hi = band[1], mid = 0.5f * (lo + hi);
			int n = (int) band[2];
			float solid = (float) (2 * Math.PI * (Math.sin(hi) - Math.sin(lo))) / n;
			float cy = (float) Math.sin(mid), ch = (float) Math.cos(mid);
			for (int i = 0; i < n; i++) {
				double a = (i + 0.5) * 2 * Math.PI / n;
				samples[at++] = new float[] {ch * (float) Math.cos(a), cy, ch * (float) Math.sin(a), solid};
			}
		}
		return samples;
	}

	private ShadeSky() {
	}

	/**
	 * Sun path tilt in degrees (mcopt.shade.sunTilt, default 30): the sun and moon orbit rotated about world x so the noon sun
	 * stands south of the zenith (toward +z) and casts visible shadows; sunrise and sunset stay due east and west. 0 is
	 * vanilla's path. The shading (sun direction, sky), the shadow map and the moon all follow it.
	 */
	public static final float SUN_TILT = Math.max(-60f, Math.min(60f, floatProperty("mcopt.shade.sunTilt", 30f)));

	private static float floatProperty(String key, float fallback) {
		try {
			String v = System.getProperty(key);
			return v == null ? fallback : Float.parseFloat(v.trim());
		} catch (NumberFormatException e) {
			return fallback;
		}
	}

	/** Celestial direction (-sin a, cos a, 0) for SkyRenderState angle a, tilted by SUN_TILT; into out (x, y, z). */
	public static void celestial(double angle, double[] out) {
		double t = Math.toRadians(SUN_TILT), y = Math.cos(angle);
		out[0] = -Math.sin(angle);
		out[1] = y * Math.cos(t);
		out[2] = y * Math.sin(t);
	}

	static float column(float r, float mu, float h) {
		float c = (float) Math.sqrt(r / h * 1.5707963f);
		if (mu >= 0f) return h * (float) Math.exp((R_GROUND - r) / h) * c / ((c - 1f) * mu + 1f);
		float rt = r * (float) Math.sqrt(Math.max(1f - mu * mu, 0f));
		float deep = Math.max(R_GROUND - rt, 0f);
		rt = Math.max(rt, R_GROUND);
		float ct = (float) Math.sqrt(rt / h * 1.5707963f);
		return h * (2f * ct * (float) Math.exp((R_GROUND - rt) / h) - (float) Math.exp((R_GROUND - r) / h) * c / ((c - 1f) * -mu + 1f)) + deep * 1.5f;
	}

	static float phaseR(float mu) {
		return 0.0596831f * (1f + mu * mu);
	}

	static float phaseM(float mu, float g) {
		float g2 = g * g;
		return 0.1193662f * (1f - g2) * (1f + mu * mu) / ((2f + g2) * (float) Math.pow(Math.max(1f + g2 - 2f * g * mu, 1e-4f), 1.5));
	}

	/** shadeScatter: radiance along unit dir (x, y, z) from a light of intensity at unit lightDir; adds into out[0..2]. */
	static void scatter(float dx, float dy, float dz, float lx, float ly, float lz, float intensity, float mie, float[] tint, float[] out) {
		float r0 = R_GROUND + ALTITUDE;
		float b = r0 * dy;
		float tEnd = -b + (float) Math.sqrt(Math.max(b * b - r0 * r0 + R_TOP * R_TOP, 0f));
		float dg = b * b - r0 * r0 + R_GROUND * R_GROUND;
		if (dy < 0f && dg > 0f) tEnd = -b - (float) Math.sqrt(dg);
		float mu = dx * lx + dy * ly + dz * lz;
		float pr = phaseR(mu), pm = phaseM(mu, MIE_G);
		float betaM = BETA_M * mie, betaMExt = BETA_M_EXT * mie;
		float odR = 0, odM = 0, tPrev = 0;
		float sr0 = 0, sr1 = 0, sr2 = 0, sm0 = 0, sm1 = 0, sm2 = 0;
		for (int i = 0; i < SAMPLES; i++) {
			float u = (float) (i + 1) / SAMPLES;
			float t = tEnd * u * u, dt = t - tPrev, tm = 0.5f * (t + tPrev);
			tPrev = t;
			float px = dx * tm, py = r0 + dy * tm, pz = dz * tm;
			float r = (float) Math.sqrt(px * px + py * py + pz * pz);
			float dR = (float) Math.exp((R_GROUND - r) / H_R) * dt, dM = (float) Math.exp((R_GROUND - r) / H_M) * dt;
			float muL = (px * lx + py * ly + pz * lz) / r;
			float cR = odR + 0.5f * dR + column(r, muL, H_R), cM = odM + 0.5f * dM + column(r, muL, H_M);
			float t0 = (float) Math.exp(-(BETA_R[0] + BETA_O[0]) * cR - betaMExt * cM);
			float t1 = (float) Math.exp(-(BETA_R[1] + BETA_O[1]) * cR - betaMExt * cM);
			float t2 = (float) Math.exp(-(BETA_R[2] + BETA_O[2]) * cR - betaMExt * cM);
			sr0 += t0 * dR; sr1 += t1 * dR; sr2 += t2 * dR;
			sm0 += t0 * dM; sm1 += t1 * dM; sm2 += t2 * dM;
			odR += dR;
			odM += dM;
		}
		out[0] += tint[0] * intensity * (BETA_R[0] * pr * sr0 + betaM * pm * sm0);
		out[1] += tint[1] * intensity * (BETA_R[1] * pr * sr1 + betaM * pm * sm1);
		out[2] += tint[2] * intensity * (BETA_R[2] * pr * sr2 + betaM * pm * sm2);
	}

	private static final float[] WHITE = {1f, 1f, 1f};

	/** Everything the per-frame atmosphere depends on. */
	public record Sky(float sunX, float sunY, float sunZ, float moonX, float moonY, float moonZ, float moonPhase, float rain, float thunder) {
		float sunIntensity() {
			return SUN_INTENSITY;
		}

		/** The moon fades in as the sun's last scattering fades out (the shader computes both only while both count). */
		float moonIntensity() {
			return MOON_INTENSITY * (0.35f + 0.65f * this.moonPhase) * smoothstep(-0.10f, -0.22f, this.sunY);
		}

		float mie() {
			return 0.75f + 3.25f * this.rain;
		}

		/**
		 * Exposure bias by sun height: sunsets and twilight darken (the eye doesn't fully adapt back to day brightness, which
		 * made a sunset read like an afternoon); 1 by day and at night.
		 */
		float exposureBias() {
			return 1f - 0.25f * (1f - smoothstep(0.02f, 0.25f, this.sunY)) * smoothstep(-0.25f, -0.05f, this.sunY);
		}
	}

	/** shadeSkyRadiance: sky radiance (linear, pre-exposure, with SKY_BRIGHTNESS) along unit dir into out. */
	public static void radiance(Sky s, float dx, float dy, float dz, float[] out) {
		out[0] = out[1] = out[2] = 0f;
		if (s.sunY > -0.22f) scatter(dx, dy, dz, s.sunX, s.sunY, s.sunZ, s.sunIntensity(), s.mie(), WHITE, out);
		float moon = s.moonIntensity();
		if (moon > 0f) scatter(dx, dy, dz, s.moonX, s.moonY, s.moonZ, moon, s.mie(), MOON_TINT, out);
		for (int k = 0; k < 3; k++) out[k] += AIRGLOW[k] * (1f - 0.5f * s.rain);
		float l = luma(out[0], out[1], out[2]);
		for (int k = 0; k < 3; k++) out[k] = Math.max(l + (out[k] - l) * SKY_SATURATION, out[k] * 0.5f);
		float gh = goldenHourWeight(s.sunY, s.rain), h = 1f - Math.min(Math.abs(dy), 1f);
		if (sunsetArt) { // shade_common.metal shadeSunsetGrade
			float dl = dx * dx + dz * dz, sl = s.sunX * s.sunX + s.sunZ * s.sunZ;
			float toward = dl > 1e-8f && sl > 1e-8f ? (float) ((dx * s.sunX + dz * s.sunZ) / Math.sqrt(dl * sl)) * 0.5f + 0.5f : 0.5f;
			float band = (float) Math.pow(Math.max(h, 1e-4f), 9f + (2f - 9f) * toward * toward);
			float t = toward > 0.5f ? (float) Math.pow(toward * 2f - 1f, 2.5) : toward * 2f;
			float[] a = toward > 0.5f ? ART_SIDE : ART_AWAY, b = toward > 0.5f ? ART_TOWARD : ART_SIDE;
			float sl3 = (float) Math.sqrt(s.sunX * s.sunX + s.sunY * s.sunY + s.sunZ * s.sunZ);
			float cs = Math.max((dx * s.sunX + dy * s.sunY + dz * s.sunZ) / Math.max(sl3, 1e-6f), 0f);
			float glow = (float) Math.pow(cs, 10.0);
			float k = gh * Math.min(0.2f + 0.8f * band + 0.4f * glow, 1f);
			for (int c = 0; c < 3; c++) {
				float col = a[c] + (b[c] - a[c]) * t;
				col += (ART_HALO[c] - col) * glow * 0.4f;
				out[c] *= 1f + (col - 1f) * k;
			}
			// shade_common.metal shadeSunsetChroma
			float mx = Math.max(out[0], Math.max(out[1], out[2])), mn = Math.min(out[0], Math.min(out[1], out[2]));
			if (gh > 0f && mx > 1e-6f) {
				float kc = smoothstep(0.55f, 1f, 1f - mn / mx) * gh, lc = luma(out[0], out[1], out[2]);
				float cr = (out[0] - lc) * (1f - 0.36f * kc), cg = (out[1] - lc) * (1f - 0.36f * kc), cb = (out[2] - lc) * (1f - 0.36f * kc);
				cg -= 0.06f * kc * Math.max(cr, 0f);
				out[0] = Math.max(lc + cr, 0f); out[1] = Math.max(lc + cg, 0f); out[2] = Math.max(lc + cb, 0f);
			}

		} else {
			gh *= 0.55f + 0.45f * h * h * h;
			out[0] *= 1f + 0.45f * gh; out[1] *= 1f + 0.02f * gh; out[2] *= 1f - 0.28f * gh;
		}
		float grey = 1f - 0.45f * s.thunder, w = s.rain * 0.75f;
		out[0] = mix(out[0], l * 0.92f * grey, w) * SKY_BRIGHTNESS;
		out[1] = mix(out[1], l * 0.96f * grey, w) * SKY_BRIGHTNESS;
		out[2] = mix(out[2], l * grey, w) * SKY_BRIGHTNESS;
		if (sunsetArt) {
			// The RGB scattering approximation can peak in green between the blue sky and warm horizon.
			// Correct only that atmospheric hue, retaining luminance; never grade material colours here.
			// Keep this in sync with shade_common.metal's shadeSunsetHue.
			float transition = (1f - smoothstep(0.32f, 0.50f, s.sunY)) * smoothstep(-0.16f, -0.02f, s.sunY);
			if (transition > 0f) {
				float before = luma(out[0], out[1], out[2]);
				out[1] -= Math.max(out[1] - 0.96f * Math.max(out[0], out[2]), 0f) * transition;
				float energy = before / Math.max(luma(out[0], out[1], out[2]), 1e-8f);
				for (int c = 0; c < 3; c++) out[c] *= energy;
			}
		}
		// Same brightness-preserving directional chroma control as shadeAwaySunset (issue #18).
		if (sunsetAway < 1f) {
			float dl = dx * dx + dz * dz, sl = s.sunX * s.sunX + s.sunZ * s.sunZ;
			float az = dl > 1e-8f && sl > 1e-8f ? (float) ((dx * s.sunX + dz * s.sunZ) / Math.sqrt(dl * sl)) : 0f;
			float k = (1f - sunsetAway) * (1f - smoothstep(-0.2f, 0.4f, az)) * goldenHourWeight(s.sunY, s.rain);
			float lum = luma(out[0], out[1], out[2]);
			for (int c = 0; c < 3; c++) out[c] = mix(out[c], lum, k);
		}
	}

	/** M3 sunset art (mcopt.shade.sunsetArt, set every frame by ShadeLook): the azimuth-aware grade of shadeSunsetGrade. */
	public static volatile boolean sunsetArt = true;
	/** Render-thread snapshot, set before computing a frame; same value packed at zenithColor.w. */
	public static volatile float sunsetAway = 1f;
	private static final float[] ART_HALO = {1.55f, 1.0f, 0.70f}, ART_TOWARD = {1.50f, 0.96f, 0.72f}, ART_SIDE = {1.40f, 0.97f, 0.82f}, ART_AWAY = {1.18f, 0.90f, 1.06f};

	/** shade_common.metal's shadeGoldenHour weight: the warm grade on the sky while the sun is low. */
	static float goldenHourWeight(float sunY, float rain) {
		return smoothstep(0.32f, 0.02f, sunY) * smoothstep(-0.16f, -0.02f, sunY) * (1f - rain);
	}

	/** Light from the sun (or moon) through the atmosphere to the camera, per channel, for a light at unit (x, y, z). */
	static void transmittance(float y, float mie, float[] out) {
		float r0 = R_GROUND + ALTITUDE;
		float cR = column(r0, y, H_R), cM = column(r0, y, H_M);
		for (int k = 0; k < 3; k++) out[k] = (float) Math.exp(-(BETA_R[k] + BETA_O[k]) * cR - BETA_M_EXT * mie * cM);
	}

	/**
	 * Transmittance of the atmosphere toward a light at cosine mu to the vertical, seen from altitudeKm above the camera's
	 * reference altitude (M3 clouds: the light their layer gets, which stays warm and bright after the ground's has faded).
	 */
	public static void transmittanceAbove(float altitudeKm, float mu, float mie, float[] out) {
		float r = R_GROUND + ALTITUDE + Math.max(altitudeKm, 0f);
		float cR = column(r, mu, H_R), cM = column(r, mu, H_M);
		for (int k = 0; k < 3; k++) out[k] = (float) Math.exp(-(BETA_R[k] + BETA_O[k]) * cR - BETA_M_EXT * mie * cM);
	}

	/** What the frame's light and fog get from the atmosphere; see ShadeFrame for where each lands. */
	public static final class Result {
		public final float[] lightDir = new float[3];
		public boolean sunLight;
		/** Direct light reaching the ground, divided by pi. */
		public final float[] light = new float[3];
		public final float[] ambientSky = new float[3], ambientGround = new float[3], zenith = new float[3];
		/** Sky (and half the ground) light on vertical faces turned toward / away from the sun's azimuth. */
		public final float[] ambientToward = new float[3], ambientAway = new float[3];
		public final float[][] horizon = new float[8][3];
		/** Average scene luminance the exposure adapts to (before eye sky light). */
		public float sceneLuma;
		// Each result owns its scratch: no frame-by-frame array garbage and no mutable global scratch between callers.
		private final float[] transmittance = new float[3], sample = new float[3], up = new float[3], toward = new float[3], away = new float[3];
	}

	public static void compute(Sky s, Result r) {
		float mie = s.mie();
		float[] t = r.transmittance, tmp = r.sample;
		// The light: the sun while it's up, the moon once the sun is well down (both are near zero at the switch).
		r.sunLight = s.sunY > -0.06f;
		if (r.sunLight) {
			transmittance(s.sunY, mie, t);
			float f = SUN_INTENSITY * smoothstep(-0.06f, 0.02f, s.sunY) * (1f - 0.85f * s.rain) * (1f - 0.5f * s.thunder) / (float) Math.PI;
			for (int k = 0; k < 3; k++) r.light[k] = t[k] * f;
			r.lightDir[0] = s.sunX; r.lightDir[1] = s.sunY; r.lightDir[2] = s.sunZ;
		} else {
			transmittance(Math.max(s.moonY, -1f), mie, t);
			// sun/moon handover (bible §3.2): the moon's light ramps up from zero only after the sun's has faded out, so the
			// switch of the shadow-casting light never pops (lighting, shadows, specular and volumetric light follow it)
			float handover = smoothstep(0.06f, 0.13f, -s.sunY);
			float f = s.moonIntensity() * smoothstep(-0.04f, 0.06f, s.moonY) * handover * (1f - 0.85f * s.rain) / (float) Math.PI;
			for (int k = 0; k < 3; k++) r.light[k] = t[k] * f * MOON_TINT[k];
			r.lightDir[0] = s.moonX; r.lightDir[1] = s.moonY; r.lightDir[2] = s.moonZ;
		}
		// Sky light on an upward face and on vertical faces turned toward / away from the sun's azimuth: directions in rings,
		// weighted by solid angle and the face's cosine; vertical faces also see half a hemisphere of ground.
		float ax = s.sunX, az = s.sunZ, al = (float) Math.sqrt(ax * ax + az * az);
		if (al > 1e-3f) { ax /= al; az /= al; } else { ax = 1f; az = 0f; }
		float[] up = r.up, toward = r.toward, away = r.away;
		for (int k = 0; k < 3; k++) up[k] = toward[k] = away[k] = 0f;
		for (float[] sample : AMBIENT_SAMPLES) {
			float dx = sample[0], cy = sample[1], dz = sample[2], solid = sample[3];
			radiance(s, dx, cy, dz, tmp);
			float side = dx * ax + dz * az;
			for (int k = 0; k < 3; k++) {
				up[k] += tmp[k] * cy * solid;
				toward[k] += tmp[k] * Math.max(side, 0f) * solid;
				away[k] += tmp[k] * Math.max(-side, 0f) * solid;
			}
		}
		float sunOnGround = Math.max(r.lightDir[1], 0f);
		float k1 = AMBIENT_BOOST / SKY_BRIGHTNESS / (float) Math.PI;
		for (int k = 0; k < 3; k++) {
			r.ambientSky[k] = up[k] * k1;
			// an earthy, near-neutral ground lit by the light and the sky (was green-grey 0.085/0.10/0.06: it tinted every
			// side and bottom face, and the clouds' undersides at sunset, green)
			float albedo = k == 1 ? 0.084f : k == 0 ? 0.090f : 0.072f;
			float ground = albedo * (r.light[k] * sunOnGround + up[k] / SKY_BRIGHTNESS / (float) Math.PI) * 1.2f;
			r.ambientGround[k] = ground + r.ambientSky[k] * 0.3f;
			r.ambientToward[k] = toward[k] * k1 + 0.5f * ground;
			r.ambientAway[k] = away[k] * k1 + 0.5f * ground;
		}
		// Keep dusk and moonlight coloured; remove the blue daylight illuminant from surface fill.
		float day = r.sunLight ? Math.clamp((r.lightDir[1] - 0.2f) / 0.5f, 0f, 1f) : 0f;
		day *= day * (3f - 2f * day);
		float fillNeutrality = AMBIENT_DESATURATE + (DAY_AMBIENT_DESATURATE - AMBIENT_DESATURATE) * day;
		float sunset = smoothstep(-0.07f, 0f, s.sunY) * (1f - smoothstep(0.32f, 0.50f, s.sunY)) * (1f - s.rain);
		fillNeutrality += (SUNSET_AMBIENT_DESATURATE - AMBIENT_DESATURATE) * sunset * (1f - day);
		desaturate(r.ambientSky, fillNeutrality);
		desaturate(r.ambientToward, fillNeutrality);
		desaturate(r.ambientAway, fillNeutrality);
		desaturate(r.ambientGround, fillNeutrality);
		radiance(s, 0f, 1f, 0f, r.zenith);
		for (int i = 0; i < 8; i++) {
			float x = i / 3.5f - 1f;
			radiance(s, x, 0.0f, (float) Math.sqrt(Math.max(0f, 1f - x * x)), r.horizon[i]);
		}
		r.sceneLuma = luma(r.light[0], r.light[1], r.light[2]) * 0.55f * Math.max(r.lightDir[1], 0.35f) + luma(r.ambientSky[0], r.ambientSky[1], r.ambientSky[2]);
	}

	private static void desaturate(float[] c, float amount) {
		float l = luma(c[0], c[1], c[2]);
		for (int k = 0; k < 3; k++) c[k] = mix(c[k], l, amount);
	}

	static float luma(float r, float g, float b) {
		return 0.2126f * r + 0.7152f * g + 0.0722f * b;
	}

	static float mix(float a, float b, float t) {
		return a + (b - a) * t;
	}

	static float smoothstep(float e0, float e1, float x) {
		float t = Math.min(Math.max((x - e0) / (e1 - e0), 0f), 1f);
		return t * t * (3f - 2f * t);
	}
}
