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

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import org.joml.Matrix4f;
import org.joml.Matrix4fc;
import org.joml.Vector3f;

/**
 * The per-frame uniform block every shaded pipeline reads at buffer(16): this class holds the values and packs them in the
 * exact byte layout of struct ShadeFrame in resources/mcopt/shade/shade_common.metal (offsets below; change both together).
 * Filled once per frame at LevelRenderer.render HEAD (ShadeFrameUpdater, which reads the game's render state; this class
 * itself has no game types, so tools can pack frames too), written into the next slot of a ring of shared MTLBuffers
 * (ShadeBindings) that the GPU reads when the frame executes. The shadow pass adds its matrices with setShadow, which
 * also patches the slot already written for the current frame.
 */
public final class ShadeFrame {
	// Byte offsets of struct ShadeFrame (shade_common.metal).
	public static final int VIEW = 0, PROJ = 64, VIEW_PROJ = 128, INV_VIEW_PROJ = 192, PREV_VIEW_PROJ = 256, SHADOW_VIEW_PROJ = 320,
		CAMERA_BLOCK = 448, CAMERA_FRACT = 464, SUN_DIR_WORLD = 480, SUN_DIR_VIEW = 496, MOON_DIR_WORLD = 512, LIGHT_DIR_WORLD = 528,
		SUN_COLOR = 544, AMBIENT_SKY = 560, AMBIENT_GROUND = 576, AMBIENT_BLOCK = 592, FOG_COLOR = 608, FOG_RANGE = 624, FOG_SKY = 640,
		SKY_COLOR = 656, ZENITH_COLOR = 672, HORIZON = 688, CASCADE_SPLITS = 816, SHADOW_PARAMS = 832, SCREEN = 848, TIME = 864,
		WEATHER = 880, JITTER = 896, ATMOSPHERE = 912, AMBIENT_TOWARD = 928, AMBIENT_AWAY = 944, FLAGS = 960, FLAGS2 = 976, SUN_PATH = 992,
		WX_LINE = 1008;
	public static final int SIZE = 1024;

	/** mcopt.shade.dev: feature-off bits for pricing them in game (SHADE_DEV_* in shade_common.metal); 0 normally. */
	static final int DEV_BITS = Integer.getInteger("mcopt.shade.dev", 0);

	/**
	 * The dev bits this frame: mcopt.shade.dev is read again every frame (a bench can price a feature inside one session by
	 * setting the system property between phases, as mcbench's weather perf phases do); the startup value otherwise.
	 */
	static int devBits() {
		return Integer.getInteger("mcopt.shade.dev", DEV_BITS);
	}

	/** DIM_VANILLA: the overworld drawn the vanilla way (shading setup failed half way; see ShadeBindings.fallback). */
	public static final int DIM_OVERWORLD = 0, DIM_NETHER = 1, DIM_END = 2, DIM_VANILLA = 3;
	public static final int FOG_AIR = 0, FOG_WATER = 1, FOG_LAVA = 2, FOG_POWDER_SNOW = 3;

	// ---- values (camera-relative world space unless noted) ----
	public final Matrix4f view = new Matrix4f(), proj = new Matrix4f(), viewProj = new Matrix4f(), invViewProj = new Matrix4f(),
		prevViewProj = new Matrix4f();
	public final Matrix4f[] shadowViewProj = {new Matrix4f(), new Matrix4f()};
	public double cameraX, cameraY, cameraZ;
	public final Vector3f sunDir = new Vector3f(0, 1, 0), moonDir = new Vector3f(0, -1, 0);
	public float moonPhase = 1f;
	public final ShadeSky.Result sky = new ShadeSky.Result();
	public float sunIntensity, moonIntensity, mie = 1f;
	public final float[] blockLight = {2.4f, 1.2f, 0.48f}; // torches: warm (~2700 K), strong near, falling off fast (shadeBlockCurve)
	private final float[] torch = new float[3];

	/**
	 * (1.1) The torch light the shaders get: blockLight times user.torch (strength), and with user.torchKelvin set (1800..6500;
	 * 0 = as released) its colour that of a blackbody at that temperature with blockLight's luminance. Held lights, entities and
	 * the rain's glints follow it (their tints are relative to it).
	 */
	float[] torchLight() {
		float k = Live.f(ShadeLook.U + "torch", 1f, 0f, 3f), kelvin = Live.f(ShadeLook.U + "torchKelvin", 0f, 0f, 6500f);
		float[] base = this.blockLight;
		if (kelvin >= 1000f) {
			float[] bb = ShadeLook.blackbody(kelvin);
			float lb = ShadeSky.luma(base[0], base[1], base[2]), lc = Math.max(ShadeSky.luma(bb[0], bb[1], bb[2]), 1e-4f);
			for (int i = 0; i < 3; i++) this.torch[i] = bb[i] * lb / lc * k;
		} else {
			for (int i = 0; i < 3; i++) this.torch[i] = base[i] * k;
		}
		return this.torch;
	}
	public float minAmbient = 0.004f;
	/** Natural lighting's daylight weight, 0..2 (0 = Current, 1 = original Natural, 2 = stronger). */
	public float naturalLighting;
	/** sRGB fog colour and weight, vanilla fog distances (FogData). */
	public final float[] fogColor = new float[4];
	public float fogEnvStart, fogEnvEnd = 1e6f, fogRenderStart, fogRenderEnd = 1e6f, fogSkyEnd = 1e6f, fogCloudEnd = 1e6f, hazeDensity = 0.0008f, hazeStrength = 0.45f;
	public final float[] skyColor = {0.5f, 0.7f, 1f};
	public float rain, thunder, nightVision, starBrightness;
	/** Issue #18: chroma on the side opposite the low sun, 1 keeps the released sky. Stored in zenithColor.w. */
	public float sunsetAway = 1f;
	public float cascadeSplit0 = 32, cascadeSplit1 = 128, cascadeTexel0 = 1f / 32f, cascadeTexel1 = 1f / 8f;
	public int shadowResolution = 2048;
	public float shadowDepthBias = 0.00015f, shadowNormalOffset = 1.5f;
	public boolean shadowsEnabled;
	public int cascades = 2;
	public int width = 1, height = 1;
	public float dayTime, gameTimeSeconds, exposure = 0f, partialTick;
	/** The water's animation clock in seconds (sunPath.w): real time with mcopt.shade.waterClock (smooth), else gameTimeSeconds. */
	public float waterTime;
	/** (FT2.8) The sky's slow clock in seconds (ShadeLook.clock2.x): the water's, wrapped every 65536 s instead of 4096. */
	public float skyTime;
	public float jitterX, jitterY, prevJitterX, prevJitterY;
	/** TAA render scale for texture gradients (cameraBlock.w; mip bias = log2 of it), 1 at native resolution. */
	public float mipScale = 1f;
	/** TAAU render scale this frame (live render size / output size), 1 without TAAU. CPU only (ShadeLook.renderScale). */
	public float renderScale = 1f;
	public int dimension = DIM_OVERWORLD, fogType = FOG_AIR, debug;
	public int frameIndex;
	public boolean underwater;
	public int eyeSkyLight = 15;

	/**
	 * Recomputes everything derived from the raw inputs above (sun and moon directions, phase, rain, thunder, eye sky light,
	 * night vision): the atmosphere's light, ambient and horizon colours, haze, and the eye-adapted exposure, which moves
	 * toward its target over ShadeSky.ADAPT_SECONDS (dtSeconds since the last frame; snap jumps straight to it).
	 */
	public void updateAtmosphere(float dtSeconds, boolean snap) {
		ShadeSky.sunsetAway = this.sunsetAway = Live.f(ShadeLook.U + "sunsetAway", 1f, 0f, 1f);
		ShadeSky.Sky s = new ShadeSky.Sky(this.sunDir.x, this.sunDir.y, this.sunDir.z, this.moonDir.x, this.moonDir.y, this.moonDir.z, this.moonPhase,
			this.rain, this.thunder);
		ShadeSky.compute(s, this.sky);
		this.sunIntensity = s.sunIntensity();
		this.moonIntensity = s.moonIntensity();
		this.mie = s.mie();
		// (1.1) user.distanceHaze: the far land's haze; user.rainFog: the rain's share of it (ShadeLook.update reads the same key)
		float rainFog = this.rain * Live.f(ShadeLook.U + "rainFog", 1f, 0f, 3f);
		this.hazeDensity = 0.0008f * Live.f(ShadeLook.U + "distanceHaze", 1f, 0f, 4f) * (1f + 8f * rainFog); // rain closes the distance in
		this.hazeStrength = Math.min(0.5f + 0.4f * rainFog, 1f);
		// Eye adaptation: the light around the camera. Outdoors (sky light 15 at the eye) that's the sky's; deeper in, torches.
		this.naturalLighting = ShadeLighting.strength(this);
		float eye = this.eyeSkyLight / 15f;
		float eyeCurve = eye / (4f - 3f * eye);
		float scene = this.sky.sceneLuma * eyeCurve + 0.05f * (1f - eyeCurve) + this.minAmbient;
		if (this.naturalLighting > 0f) {
			// At the original Natural strength, cap the reference's interior lift at 1.5 EV; at the
			// stronger endpoint, 1 EV (ADAPTATION = 0.5). Blend without extrapolating past the floor.
			float extra = Math.max(this.naturalLighting - 1f, 0f);
			float floor = this.sky.sceneLuma * (0.125f * (1f + extra)) + this.minAmbient;
			scene += Math.min(this.naturalLighting, 1f) * (Math.max(scene, floor) - scene);
		}
		float target = ShadeSky.KEY / (float) Math.pow(Math.max(scene, 1e-4f), ShadeSky.ADAPTATION);
		target *= 1f + 1.5f * this.nightVision;
		target *= 1f - 0.3f * this.rain; // rain and storms read darker than a clear day, not adapted back up to it
		target *= s.exposureBias();
		target = Math.min(Math.max(target, ShadeSky.EXPOSURE_MIN), ShadeSky.EXPOSURE_MAX * (1f + this.nightVision));
		if (snap || !(this.exposure > 0f)) {
			this.exposure = target;
		} else { // log space: Natural reveals dark rooms gradually, but settles sooner when stepping into daylight
			float tau = ShadeSky.ADAPT_SECONDS;
			if (this.naturalLighting > 0f) {
				float extra = Math.max(this.naturalLighting - 1f, 0f);
				float naturalTau = target > this.exposure ? 2.8f + 0.7f * extra : 0.45f - 0.1f * extra;
				tau += Math.min(this.naturalLighting, 1f) * (naturalTau - tau);
			}
			float k = 1f - (float) Math.exp(-Math.max(dtSeconds, 0f) / tau);
			this.exposure = (float) Math.exp(Math.log(this.exposure) + (Math.log(target) - Math.log(this.exposure)) * k);
		}
	}

	/** shade_common.metal's shadeOutput for one colour on the CPU (linear radiance, pre-exposure -> sRGB), without the rods shift. */
	public static void output(float[] radiance, float exposure, float[] out) {
		float r = Math.max(radiance[0], 0f) * exposure, g = Math.max(radiance[1], 0f) * exposure, b = Math.max(radiance[2], 0f) * exposure;
		float m = Math.max(Math.max(r, g), Math.max(b, 1e-6f));
		float tm = curve(m);
		float w = ShadeSky.smoothstep(0.6f, 1f, tm) * 0.6f;
		float[] c = {r, g, b};
		for (int k = 0; k < 3; k++) {
			float v = c[k] * tm / m;
			v = v + (curve(c[k]) - v) * w;
			v = Math.min(Math.max(v, 0f), 1f);
			out[k] = v <= 0.0031308f ? v * 12.92f : 1.055f * (float) Math.pow(v, 1 / 2.4) - 0.055f;
		}
	}

	private static float curve(float x) {
		float y = 1f - (float) Math.exp(-1.1f * Math.max(x, 0f));
		return y * y * 1.006f / (y + 0.006f);
	}

	/** Writes the struct at address (at least SIZE bytes, any alignment the buffer gives). */
	public void pack(ByteBuffer out) {
		ByteBuffer b = out.duplicate().order(ByteOrder.LITTLE_ENDIAN);
		this.view.get(VIEW, b);
		this.proj.get(PROJ, b);
		this.viewProj.get(VIEW_PROJ, b);
		this.invViewProj.get(INV_VIEW_PROJ, b);
		this.prevViewProj.get(PREV_VIEW_PROJ, b);
		this.shadowViewProj[0].get(SHADOW_VIEW_PROJ, b);
		this.shadowViewProj[1].get(SHADOW_VIEW_PROJ + 64, b);
		double bx = Math.floor(this.cameraX), by = Math.floor(this.cameraY), bz = Math.floor(this.cameraZ);
		put4(b, CAMERA_BLOCK, (float) bx, (float) by, (float) bz, this.mipScale);
		put4(b, CAMERA_FRACT, (float) (this.cameraX - bx), (float) (this.cameraY - by), (float) (this.cameraZ - bz), (float) (this.cameraY - 63));
		put4(b, SUN_DIR_WORLD, this.sunDir.x, this.sunDir.y, this.sunDir.z, this.sunDir.y);
		Vector3f sv = this.view.transformDirection(new Vector3f(this.sunDir));
		put4(b, SUN_DIR_VIEW, sv.x, sv.y, sv.z, 0);
		put4(b, MOON_DIR_WORLD, this.moonDir.x, this.moonDir.y, this.moonDir.z, this.moonPhase);
		float[] l = this.sky.lightDir;
		put4(b, LIGHT_DIR_WORLD, l[0], l[1], l[2], this.sky.sunLight ? 1 : 0);
		float[] c = this.sky.light;
		put4(b, SUN_COLOR, c[0], c[1], c[2], ShadeSky.luma(c[0], c[1], c[2]));
		put3(b, AMBIENT_SKY, this.sky.ambientSky, 0);
		put3(b, AMBIENT_GROUND, this.sky.ambientGround, 0);
		put3(b, AMBIENT_BLOCK, torchLight(), this.minAmbient);
		put4(b, FOG_COLOR, this.fogColor[0], this.fogColor[1], this.fogColor[2], this.fogColor[3]);
		put4(b, FOG_RANGE, this.fogEnvStart, this.fogEnvEnd, this.fogRenderStart, this.fogRenderEnd);
		put4(b, FOG_SKY, this.fogSkyEnd, this.fogCloudEnd, this.hazeDensity, this.hazeStrength);
		put4(b, SKY_COLOR, this.skyColor[0], this.skyColor[1], this.skyColor[2], 1 - this.rain);
		put3(b, ZENITH_COLOR, this.sky.zenith, this.sunsetAway);
		for (int i = 0; i < 8; i++) put3(b, HORIZON + 16 * i, this.sky.horizon[i], 0);
		put4(b, CASCADE_SPLITS, this.cascadeSplit0, this.cascadeSplit1, this.cascadeTexel0, this.cascadeTexel1);
		put4(b, SHADOW_PARAMS, 1f / this.shadowResolution, this.shadowResolution, this.shadowDepthBias, this.shadowNormalOffset);
		put4(b, SCREEN, this.width, this.height, 1f / this.width, 1f / this.height);
		put4(b, TIME, this.dayTime, this.gameTimeSeconds, this.exposure, this.partialTick);
		put4(b, WEATHER, this.rain, this.thunder, this.nightVision, this.starBrightness);
		put4(b, JITTER, this.jitterX, this.jitterY, this.prevJitterX, this.prevJitterY);
		put4(b, ATMOSPHERE, this.sunIntensity, this.moonIntensity, this.mie, ShadeSky.SKY_BRIGHTNESS);
		put3(b, AMBIENT_TOWARD, this.sky.ambientToward, 0);
		put3(b, AMBIENT_AWAY, this.sky.ambientAway, 0);
		b.putInt(FLAGS, this.dimension).putInt(FLAGS + 4, this.fogType).putInt(FLAGS + 8, this.shadowsEnabled ? 1 : 0).putInt(FLAGS + 12, this.debug);
		b.putInt(FLAGS2, this.frameIndex).putInt(FLAGS2 + 4, this.underwater ? 1 : 0).putInt(FLAGS2 + 8, this.cascades).putInt(FLAGS2 + 12, this.eyeSkyLight);
		put4(b, SUN_PATH, (float) Math.sin(Math.toRadians(ShadeSky.SUN_TILT)), (float) Math.cos(Math.toRadians(ShadeSky.SUN_TILT)), devBits(), this.waterTime);
		// (2026-10-11) where snow and rain reach on the terrain (the camera biome's snow line; ShadeWeather.packLine)
		mcopt.metal.shade.weather.ShadeWeather.packLine(b, WX_LINE);
	}

	/** Only the shadow fields, for patching a slot already packed this frame. */
	void packShadow(ByteBuffer out) {
		ByteBuffer b = out.duplicate().order(ByteOrder.LITTLE_ENDIAN);
		this.shadowViewProj[0].get(SHADOW_VIEW_PROJ, b);
		this.shadowViewProj[1].get(SHADOW_VIEW_PROJ + 64, b);
		put4(b, CASCADE_SPLITS, this.cascadeSplit0, this.cascadeSplit1, this.cascadeTexel0, this.cascadeTexel1);
		put4(b, SHADOW_PARAMS, 1f / this.shadowResolution, this.shadowResolution, this.shadowDepthBias, this.shadowNormalOffset);
		b.putInt(FLAGS + 8, this.shadowsEnabled ? 1 : 0);
		b.putInt(FLAGS2 + 8, this.cascades);
	}

	/**
	 * The shadow pass's matrices for this frame (camera-relative world to shadow clip, see shade_common.metal's convention),
	 * cascade far distances in blocks, map size, depth bias (clip z) and normal offset (texels). Persists for later frames
	 * until called again; enabled false turns shadow sampling off (visibility 1).
	 */
	public void setShadow(boolean enabled, int cascades, Matrix4fc cascade0, Matrix4fc cascade1, float split0, float split1, int resolution,
		float depthBias, float normalOffsetTexels) {
		this.shadowsEnabled = enabled;
		this.cascades = cascades;
		this.shadowViewProj[0].set(cascade0);
		this.shadowViewProj[1].set(cascade1);
		this.cascadeSplit0 = split0;
		this.cascadeSplit1 = split1;
		this.shadowResolution = resolution;
		this.shadowDepthBias = depthBias;
		this.shadowNormalOffset = normalOffsetTexels;
	}

	/** World blocks per shadow texel of each cascade (cascadeSplits.zw: the receiver's offsets scale with it). */
	public void setShadowTexels(float texel0, float texel1) {
		this.cascadeTexel0 = texel0;
		this.cascadeTexel1 = texel1;
	}

	private static void put4(ByteBuffer b, int at, float x, float y, float z, float w) {
		b.putFloat(at, x).putFloat(at + 4, y).putFloat(at + 8, z).putFloat(at + 12, w);
	}

	private static void put3(ByteBuffer b, int at, float[] v, float w) {
		put4(b, at, v[0], v[1], v[2], w);
	}
}
