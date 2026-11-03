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

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import mcopt.metal.shade.Live;
import mcopt.metal.shade.ShadeFrame;
import mcopt.metal.shade.ShadeLook;
import mcopt.metal.shade.ShadeSky;
import org.joml.Matrix4f;

/**
 * The per-frame state of the clouds and its two packed forms: CloudParams (clouds.metal, buffer 0 of the cloud passes) and
 * the ShadeLook fields every other shader reads (cloudShadowVP, clouds0/1, the SHADE_FEATURE_CLOUDS bit). Pure maths on
 * ShadeFrame and CloudWeather, no game types: the offline preview packs it too.
 */
public final class CloudParams {
	public static final int SIZE = 448;
	/** Art knobs: multiple-scattering octave weight and extinction factors, sky-light extinction (diffuse) factor. */
	static final float OCTAVE_WEIGHT = CloudConfig.floatProperty("mcopt.shade.clouds.octaveWeight", 0.68f),
		OCTAVE_EXTINCTION = CloudConfig.floatProperty("mcopt.shade.clouds.octaveExtinction", 0.48f),
		SKY_EXTINCTION = CloudConfig.floatProperty("mcopt.shade.clouds.skyExtinction", 0.12f),
		SUNSET_FILL = CloudConfig.floatProperty("mcopt.shade.clouds.sunsetFill", 0.65f),
		AP_SUNSET = CloudConfig.floatProperty("mcopt.shade.clouds.apSunset", 1.5f),
		LIGHT_STEP = CloudConfig.floatProperty("mcopt.shade.clouds.lightStep", 4f),
		OD_STEP = CloudConfig.floatProperty("mcopt.shade.clouds.odStep", 2.5f),
		OD_MIN = CloudConfig.floatProperty("mcopt.shade.clouds.odMin", 0.5f);
	/** World periods the noise textures tile with (blocks): the weather map's 4096 tile, the 3D noise's 120 and 30 tiles. */
	static final double WEATHER_PERIOD = 16384.0, NOISE_PERIOD = 120.0 * 64.0;
	static final float CURVATURE_RADIUS = 40000f;
	static final float SEA = 63f;
	/** The cirrus streaks' fixed axis (radians from +x). */
	static final float CIRRUS_AXIS = 0.52f;

	// ---- inputs (set by the caller each frame) ----
	public int histW = 1, histH = 1, marchW = 1, marchH = 1, frame;
	/** Checkerboard N (1-4): one history pixel of each N x N block is marched per frame. */
	public int checker = 3;
	public boolean reset = true, domeValid;
	/** Dome updates so far (the dome march's jitter steps by the golden ratio per update). */
	public int domeUpdates;
	/** The cloud shadow map is rendered this frame (else consumers keep reading the one rendered on an earlier frame). */
	public boolean shadowUpdate = true;
	public float base = 200f, top = 350f;
	/** Accumulated wind displacement (blocks) of the cumulus (2D field), of the 3D noise, and of the cirrus. */
	public double windX, windZ, wind3X, wind3Z, cirrusX, cirrusZ;
	/**
	 * (1.1) The blocky style with the game's cloud texture this frame (ShadeClouds): origin in its space (vanilla's drift along x
	 * and the 3.96-block z offset, wrapped to the texture's size in blocks), its drift as the history's motion, no cirrus.
	 */
	public boolean vanillaCells;
	public double vanillaX, vanillaPeriodX = 3072.0, vanillaPeriodZ = 3072.0;
	public float vanillaStepX;
	/** How far the cumulus moved since last frame (blocks). */
	public float windStepX, windStepZ;
	/** Overall opacity (fades the clouds and their shadows; 1.1: the player's mcopt.shade.user.cloudOpacity, ShadeClouds). */
	public float opacity = 1f;
	/** This frame's dev bits (CloudConfig.devBits): the passes read them in lightDir.w, the consumers in ShadeLook.clouds1.z. */
	public int dev;
	/** This frame's M3.3 mode bits (CloudConfig.modeBits; 0 = M3.2): the passes read them in shadowDir.w. */
	public int mode;

	// ---- derived, for the log / tools ----
	public final float[] light = new float[3];
	public final float[] lightDir = new float[3];
	public float shadowStrength;
	public boolean sunLit;

	private final Matrix4f m = new Matrix4f(), inv = new Matrix4f();
	private final float[] t = new float[3];

	/** Packs CloudParams (SIZE bytes) at out's position 0. */
	public void pack(ByteBuffer out, ShadeFrame f, CloudWeather w) {
		ByteBuffer b = out.duplicate().order(ByteOrder.LITTLE_ENDIAN);
		// matrices without the TAA jitter: the clouds' raster stays put, the sky pass samples them by direction
		m.translation(-f.jitterX, -f.jitterY, 0f).mul(f.viewProj).invert(inv);
		inv.get(0, b);
		m.translation(-f.prevJitterX, -f.prevJitterY, 0f).mul(f.prevViewProj).get(64, b);
		put4(b, 128, this.histW, this.histH, this.marchW, this.marchH);
		int n = Math.max(1, Math.min(4, this.checker));
		int slot = Math.floorMod(this.frame, n * n);
		// slot orders that spread consecutive frames apart: 2x2 (0,0) (1,1) (1,0) (0,1); 3x3 by a Bayer-like order; 4x4 Bayer
		int[] order = n == 4 ? ORDER4 : n == 3 ? ORDER3 : n == 2 ? ORDER2 : ORDER1;
		int cell = order[slot];
		put4(b, 144, cell % n, cell / n, this.reset ? 1f : 0f, CloudConfig.maxAge(n));
		float camY = (float) f.cameraY;
		put4(b, 160, this.base, this.top, camY, 1f / (2f * CURVATURE_RADIUS));
		float storm = w.storm;
		float sigma = 0.15f * CloudConfig.density() * (1f + 0.6f * storm); // (1.1: density live)
		put4(b, 176, w.coverage, w.type, sigma, 0.78f);
		if (this.vanillaCells) {
			put4(b, 192, (float) wrap(f.cameraX + this.vanillaX, this.vanillaPeriodX), (float) wrap(f.cameraZ + 3.96, this.vanillaPeriodZ),
				(float) wrap(f.cameraX + this.wind3X, NOISE_PERIOD), (float) wrap(f.cameraZ + this.wind3Z, NOISE_PERIOD));
			put4(b, 208, this.vanillaStepX, 0f, 0f, storm); // (no cirrus: the mask is bound in place of the weather map it reads)
		} else {
			put4(b, 192, (float) wrap(f.cameraX + this.windX, WEATHER_PERIOD), (float) wrap(f.cameraZ + this.windZ, WEATHER_PERIOD),
				(float) wrap(f.cameraX + this.wind3X, NOISE_PERIOD), (float) wrap(f.cameraZ + this.wind3Z, NOISE_PERIOD));
			// (1.1: the cirrus on/off live, its coverage x the player's mcopt.shade.user.cirrusAmount)
			put4(b, 208, this.windStepX, this.windStepZ, CloudConfig.cirrus() ? w.cirrus * CloudConfig.userCirrus() : 0f, storm);
		}

		// the light the layer gets: the sun until it is well below the horizon (the clouds' altitude sees it longer than the
		// ground), then the moon
		float sunY = f.sunDir.y;
		float mid = this.base + 0.4f * (this.top - this.base);
		this.sunLit = sunY > -0.1f;
		if (this.sunLit) {
			// below the horizon the colour stays that of the setting sun (the column through the planet's shadow turns pure
			// red): the light fades out instead
			ShadeSky.transmittanceAbove(Math.max(mid - SEA, 0f) * CloudConfig.altitudeScale() / 1000f, Math.max(sunY, 0.01f), f.mie, t); // (1.1: live)
			float k = ShadeSky.SUN_INTENSITY * smoothstep(-0.1f, 0.0f, sunY) * (1f - 0.55f * f.rain) * (1f - 0.5f * f.thunder);
			for (int i = 0; i < 3; i++) this.light[i] = t[i] * k;
			this.lightDir[0] = f.sunDir.x;
			this.lightDir[1] = f.sunDir.y;
			this.lightDir[2] = f.sunDir.z;
		} else {
			// the moon: what reaches the ground (ShadeFrame's light is the moon by now), as irradiance
			for (int i = 0; i < 3; i++) this.light[i] = f.sky.light[i] * (float) Math.PI * 2f;
			this.lightDir[0] = f.moonDir.x;
			this.lightDir[1] = f.moonDir.y;
			this.lightDir[2] = f.moonDir.z;
		}
		// (1.1) the player's cloud brightness (mcopt.shade.user.cloudBrightness, live; 1 = as released): the light the layer gets
		// here and its ambient from above and below (ambTop / ambBottom), so the whole layer, cirrus and dome included, scales
		float bright = CloudConfig.userBrightness();
		put4(b, 224, this.light[0] * bright, this.light[1] * bright, this.light[2] * bright, this.sunLit ? 1f : 0f);
		put4(b, 240, this.lightDir[0], this.lightDir[1], this.lightDir[2], this.dev);
		float[] as = f.sky.ambientSky, ag = f.sky.ambientGround;
		float albedo = 0.96f - 0.3f * storm;
		// Retain enough diffuse sky fill at low sun to keep the undersides readable beneath the golden rims.
		// (1.1: mcopt.shade.clouds.sunsetFill read every frame, SUNSET_FILL its default)
		float sunsetFill = Live.f("mcopt.shade.clouds.sunsetFill", SUNSET_FILL);
		float fill = this.sunLit ? sunsetFill + (1f - sunsetFill) * smoothstep(0.04f, 0.35f, sunY) : 1f;
		put4(b, 256, as[0] * fill * bright, as[1] * fill * bright, as[2] * fill * bright, albedo);
		put4(b, 272, ag[0] * bright, ag[1] * bright, ag[2] * bright, 0.9f);
		// aerial perspective toward the sky behind: lighter while the sun is low (the clouds keep their sunset colour)
		float lowSun = this.sunLit ? 1f - smoothstep(0.03f, 0.3f, sunY) : 0f;
		// (FT2.10: mcopt.shade.clouds.apSunset read every frame, for look development in one session)
		float ap = (6000f + 3000f * f.rain) * (1f - 0.65f * f.rain) * (1f + CloudConfig.floatProperty("mcopt.shade.clouds.apSunset", AP_SUNSET) * lowSun);
		put4(b, 288, CloudConfig.steps(), CloudConfig.lightSteps(), 12000f, ap); // (1.1: the steps live, uniforms of the march)
		// cirrus: wraps in its own rotated frame (streak axis fixed in the world), so the period stays exact
		double ca = Math.cos(CIRRUS_AXIS), sa = Math.sin(CIRRUS_AXIS);
		double cx = f.cameraX + this.cirrusX, cz = f.cameraZ + this.cirrusZ;
		// (1.1: cirrusAbove live, kept for packLook's cirrus altitude of the same frame)
		this.cirrusAbove = CloudConfig.cirrusAbove();
		put4(b, 304, this.base + this.cirrusAbove, 0.45f, (float) wrap(cx * ca + cz * sa, WEATHER_PERIOD), (float) wrap(-cx * sa + cz * ca, WEATHER_PERIOD));
		// cloud shadow map: on the plane yRef, centred on where the light through the camera crosses it, snapped to texels
		// The map is not rendered every frame: its frame (world origin, plane, light direction) is kept from the frame that
		// rendered it, and the consumers' projection is built from that against this frame's camera (a moving camera would
		// otherwise shift the shadows by a texel where the snapped origin steps, until the next update).
		float extent = CloudConfig.SHADOW_EXTENT;
		if (this.shadowUpdate || this.reset || !this.shadowValid) {
			float[] sl = f.sky.lightDir;
			float ly = Math.max(sl[1], 0.05f);
			float yRef = this.base + 0.35f * (this.top - this.base);
			double texel = extent / 256.0;
			double ccx = f.cameraX + sl[0] / ly * (yRef - camY), ccz = f.cameraZ + sl[2] / ly * (yRef - camY);
			this.shadowOriginX = Math.floor(ccx / texel) * texel;
			this.shadowOriginZ = Math.floor(ccz / texel) * texel;
			this.shadowRefY = yRef;
			this.shadowDir[0] = sl[0];
			this.shadowDir[1] = ly;
			this.shadowDir[2] = sl[2];
			this.shadowValid = true;
		}
		float[] sl = this.shadowDir;
		float ly = sl[1];
		float yRef = this.shadowRefY;
		float relX = (float) (this.shadowOriginX - f.cameraX), relZ = (float) (this.shadowOriginZ - f.cameraZ);
		put4(b, 320, extent, yRef, relX, relZ);
		put4(b, 336, 0.4f + 0.4f * storm, 0.12f, 0.8f, this.opacity);
		// y (FT2.10): the far clouds' bases spread (mcopt.shade.clouds.baseSpread, live: share of the layer's thickness by which a
		// base rises with the weather map's fine fBm, from ~400 blocks out, full from ~1500; 0 = every base on the layer's floor,
		// FT2.9; 0.25: no more stacked plates toward the sunset horizon, ft210-t13/t14)
		put4(b, 352, this.domeUpdates & 0xffff, Math.min(Math.max(CloudConfig.floatProperty("mcopt.shade.clouds.baseSpread", 0.25f), 0f), 0.6f),
			0.4f, CloudConfig.domeSteps()); // (1.1: dome steps live)
		put4(b, 368, this.frame & 0xffff, LIGHT_STEP, SEA - 6f, CloudConfig.detail()); // (1.1: detail live)
		// the angle one march sample covers: the vertical field of view over the history's rows, times the checkerboard (M3.3: at
		// most 3, so a 4x4 checkerboard reads the noise from the same mip levels as 3x3: the same far billows)
		float fovY = (float) (2.0 * Math.atan(1.0 / Math.max(Math.abs(f.proj.m11()), 1e-3f)));
		put4(b, 384, (float) Math.cos(CIRRUS_AXIS), (float) Math.sin(CIRRUS_AXIS), n, fovY / Math.max(this.histH, 1) * Math.min(n, 3));
		put4(b, 400, sl[0], ly, sl[2], this.mode);
		// art: a low sun gets fewer, dimmer scattering octaves (more contrast: gold sunlit sides, darker bodies)
		float low = this.sunLit ? 1f - smoothstep(0.03f, 0.3f, sunY) : 0f;
		put4(b, 416, OCTAVE_WEIGHT - 0.15f * low, OCTAVE_EXTINCTION, SKY_EXTINCTION, ShadeClouds.blocky() ? (this.vanillaCells ? 2f : 1f) : 0f);
		// wind shear: the tops lean downwind by ~40 blocks over the layer (more on windy days)
		float shear = ShadeClouds.blocky() ? 0f : 25f + 3f * w.windSpeed;
		put4(b, 432, w.windX * shear, w.windZ * shear, OD_STEP, OD_MIN);
		// (1.1: shadows on/off and their strength live; off = 0, the consumers read 1, ShadeClouds skips the map's pass)
		this.shadowStrength = CloudConfig.shadows() ? CloudConfig.shadowStrength() * smoothstep(0.04f, 0.18f, f.sky.lightDir[1]) * this.opacity : 0f;

		// ---- ShadeLook ----
		this.shadowExtent = extent;
		this.shadowRelX = relX;
		this.shadowRelZ = relZ;
		this.shadowLx = sl[0] / ly;
		this.shadowLz = sl[2] / ly;
		this.cameraY = camY;
	}

	private float shadowExtent = 1f, shadowRefY, shadowRelX, shadowRelZ, shadowLx, shadowLz, cameraY;
	/** (1.1) This frame's cirrus height over the base (CloudConfig.cirrusAbove, live), for packLook. */
	private float cirrusAbove = CloudConfig.CIRRUS_ABOVE;
	private double shadowOriginX, shadowOriginZ;
	private final float[] shadowDir = new float[3];
	private boolean shadowValid;

	/**
	 * The ShadeLook fields of the clouds (call after ShadeLook.pack, with pack above done for this frame): look = this frame's
	 * ShadeLook bytes. active: the clouds draw this frame.
	 */
	public void packLook(ByteBuffer look, boolean active) {
		ByteBuffer b = look.duplicate().order(ByteOrder.LITTLE_ENDIAN);
		int bits = b.getInt(ShadeLook.TIER + 4);
		b.putInt(ShadeLook.TIER + 4, active ? bits | FEATURE_CLOUDS : bits & ~FEATURE_CLOUDS);
		if (!active) {
			put4(b, ShadeLook.CLOUDS0, 0f, 0f, 0f, 0f);
			put4(b, ShadeLook.CLOUDS1, 0f, 0f, CloudConfig.aerialSun() ? CloudConfig.DEV_AP_SUN : 0f, 0f); // (FT2.12: the fog's bit also without clouds)
			return;
		}
		// camera-relative p -> uv: the point's projection along the light onto the plane yRef, in the map's frame
		float e = this.shadowExtent;
		float u0 = (this.shadowLx * (this.shadowRefY - this.cameraY) - this.shadowRelX) / e + 0.5f;
		float v0 = (this.shadowLz * (this.shadowRefY - this.cameraY) - this.shadowRelZ) / e + 0.5f;
		int o = ShadeLook.CLOUD_SHADOW_VP;
		float[] cols = {1f / e, 0f, 0f, 0f, -this.shadowLx / e, -this.shadowLz / e, 0f, 0f, 0f, 1f / e, 0f, 0f, u0, v0, 0f, 1f};
		for (int i = 0; i < 16; i++) b.putFloat(o + 4 * i, cols[i]);
		boolean shadowUse = (this.dev & CloudConfig.DEV_NO_SHADOW_USE) == 0;
		put4(b, ShadeLook.CLOUDS0, this.base - this.cameraY, this.top - this.cameraY, shadowUse ? this.shadowStrength : 0f, 1f);
		// w (M3.4): 1 = the screen consumers read the history with a cubic B-spline (CloudConfig.smooth)
		put4(b, ShadeLook.CLOUDS1, this.domeValid ? 1f : 0f, this.base + this.cirrusAbove - this.cameraY,
			this.dev | (CloudConfig.lateFog() ? 0 : CloudConfig.DEV_EARLY_FOG) | (CloudConfig.aerialSun() ? CloudConfig.DEV_AP_SUN : 0), CloudConfig.smooth() ? 1f : 0f);
	}

	private static final int[] ORDER1 = {0}, ORDER2 = {0, 3, 1, 2}, ORDER3 = {0, 7, 5, 2, 6, 4, 8, 3, 1};
	/** 4x4 (M3.3): the cells (y * 4 + x) by their value in the 4x4 Bayer matrix. */
	private static final int[] ORDER4 = {0, 10, 2, 8, 5, 15, 7, 13, 1, 11, 3, 9, 4, 14, 6, 12};

	/** SHADE_FEATURE_CLOUDS (shade_look.metal). */
	public static final int FEATURE_CLOUDS = 4096;

	static double wrap(double v, double period) {
		double r = v % period;
		return r < 0 ? r + period : r;
	}

	private static void put4(ByteBuffer b, int at, float x, float y, float z, float w) {
		b.putFloat(at, x).putFloat(at + 4, y).putFloat(at + 8, z).putFloat(at + 12, w);
	}

	static float smoothstep(float e0, float e1, float x) {
		float v = Math.max(0f, Math.min(1f, (x - e0) / (e1 - e0)));
		return v * v * (3f - 2f * v);
	}
}
