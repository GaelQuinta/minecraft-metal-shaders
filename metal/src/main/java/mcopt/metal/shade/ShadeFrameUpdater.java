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

import com.mojang.blaze3d.systems.RenderSystem;
import com.mojang.renderpearl.frontend.FrontendCommandEncoder;
import mcopt.metal.MetalBridge;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.client.renderer.fog.FogData;
import net.minecraft.client.renderer.state.GameRenderState;
import net.minecraft.client.renderer.state.level.CameraRenderState;
import net.minecraft.client.renderer.state.level.LevelRenderState;
import net.minecraft.client.renderer.state.level.SkyRenderState;
import net.minecraft.world.level.LightLayer;
import net.minecraft.world.level.dimension.DimensionType;
import net.minecraft.world.level.material.FogType;
import org.joml.Matrix4f;
import org.joml.Matrix4fc;
import org.joml.Vector3fc;
import org.joml.Vector4f;

/**
 * Fills the ShadeFrame once per frame, at LevelRenderer.render HEAD (ShadeLevelRendererMixin), from what the game
 * extracted for this frame: the camera (matrices as the world is drawn, previous frame's for reprojection), the sky
 * (sun and moon angles, phase, stars), weather, fog, the light around the camera; then writes it into the next ring slot,
 * points the bindings at it, and renders the sky-view LUT before the sky pass draws.
 */
public final class ShadeFrameUpdater {
	static final ShadeFrame FRAME = new ShadeFrame();
	static final ShadeLook LOOK = new ShadeLook();
	private static int moonPhaseIndex;
	private static long lastLog;
	/** The projection the world is drawn with this frame (view bobbing, hurt tilt, nausea), from ShadeGameRendererMixin. */
	private static final Matrix4f PROJECTION = new Matrix4f();
	private static boolean projectionSet;
	private static final Matrix4f PREVIOUS_VIEW_PROJ = new Matrix4f();
	private static double prevX, prevY, prevZ;
	private static boolean hasPrevious;
	private static long lastNanos;
	private static int lastDimension = -1;
	private static boolean warnedOit;
	private static final double[] DIR = new double[3];
	private static final float[] MOON_BRIGHTNESS = {1f, 0.75f, 0.5f, 0.25f, 0f, 0.25f, 0.5f, 0.75f};

	private ShadeFrameUpdater() {
	}

	/** The art layer of the frame being packed (tools and modules: its CPU display transform and inverse). */
	public static ShadeLook look() {
		return LOOK;
	}

	/** Every chunk meshed again (F3+A), e.g. after the face shade setting changed. */
	static void rebuildChunks() {
		Minecraft mc = Minecraft.getInstance();
		if (mc != null && mc.level != null) mc.execute(() -> mc.levelExtractor.allChanged());
	}

	/** 1 the game runs on mcopt's Metal backend, -1 another backend (OpenGL fallback), 0 not known yet. */
	private static volatile int metal;

	/**
	 * Whether chunks mesh without vanilla's face shade (ShadeFaceShadeMixin): Shade.faceShadeOff() and the Metal backend
	 * actually running (the device's backend name, read once it exists), so falling back to OpenGL keeps vanilla's look.
	 */
	public static boolean faceShadeOff() {
		if (!Shade.faceShadeOff()) return false;
		int m = metal;
		if (m == 0) {
			var device = RenderSystem.tryGetDevice();
			if (device == null) return false;
			metal = m = "Metal".equals(device.getDeviceInfo().backendName()) ? 1 : -1;
		}
		return m > 0;
	}

	/**
	 * The fog (and clear) colour under water while shading is on in the overworld (ShadeFogMixin): the light scattered in
	 * the water toward the eye, from last frame's sun or moon and sky light, darker with depth (sky light at the eye), through
	 * the frame's exposure and tone curve (ShadeFrame.output). Deep teal by day, near black at night. dest: sRGB, alpha kept.
	 */
	public static void waterFog(ClientLevel level, Vector4f dest) {
		ShadeFrame f = FRAME;
		if (!ShadeBindings.ready() || ShadeBindings.fallback() || f.dimension != ShadeFrame.DIM_OVERWORLD || !(f.exposure > 0f)) return;
		float[] l = f.sky.light, a = f.sky.ambientSky;
		float sun = Math.max(f.sky.lightDir[1], 0f) * 0.5f + 0.5f;
		float eye = f.eyeSkyLight / 15f;
		float depth = eye / (4f - 3f * eye) * 0.85f + 0.15f;
		float[] c = {
			(l[0] * sun * 0.02f + a[0] * 0.02f) * depth,
			(l[1] * sun * 0.085f + a[1] * 0.07f) * depth,
			(l[2] * sun * 0.11f + a[2] * 0.09f) * depth};
		ShadeFrame.output(c, f.exposure, c);
		dest.set(c[0], c[1], c[2], dest.w);
	}

	/** Called with the matrix RenderSystem.setProjectionMatrix receives in GameRenderer.renderLevel. */
	public static void projection(Matrix4fc projection) {
		PROJECTION.set(projection);
		projectionSet = true;
	}

	public static void update(CameraRenderState camera) {
		Object encoder = MetalBridge.encoder(((FrontendCommandEncoder) RenderSystem.getDevice().createCommandEncoder()).backend());
		if (encoder == null) return; // not on the Metal backend
		long enc = MetalBridge.enc(encoder);
		if (!ShadeBindings.ready() && !ShadeBindings.init(MetalBridge.ctx(encoder))) return;
		ShadeCompile.frame(); // the startup compile summary, once
		Minecraft mc = Minecraft.getInstance();
		ClientLevel level = mc.level;
		GameRenderState game = mc.gameRenderer.gameRenderState();
		LevelRenderState state = game.levelRenderState;
		SkyRenderState sky = state.skyRenderState;
		ShadeFrame f = FRAME;
		float partial = state.worldPartialTicks;

		// camera
		f.view.set(camera.viewRotationMatrix);
		f.proj.set(projectionSet ? PROJECTION : camera.projectionMatrix);
		projectionSet = false;
		f.proj.mul(f.view, f.viewProj);
		f.viewProj.invert(f.invViewProj);
		double x = camera.pos.x, y = camera.pos.y, z = camera.pos.z;
		if (hasPrevious && Math.abs(x - prevX) + Math.abs(y - prevY) + Math.abs(z - prevZ) < 64) {
			// last frame's clip space from this frame's camera-relative positions: shift by the camera's motion first
			PREVIOUS_VIEW_PROJ.translate((float) (x - prevX), (float) (y - prevY), (float) (z - prevZ), f.prevViewProj);
		} else {
			f.prevViewProj.set(f.viewProj);
		}
		PREVIOUS_VIEW_PROJ.set(f.viewProj);
		prevX = x;
		prevY = y;
		prevZ = z;
		hasPrevious = true;
		f.cameraX = x;
		f.cameraY = y;
		f.cameraZ = z;
		f.prevJitterX = f.jitterX;
		f.prevJitterY = f.jitterY;
		var target = mc.gameRenderer.mainRenderTarget();
		f.width = Math.max(1, target.width);
		f.height = Math.max(1, target.height);
		f.jitterX = f.jitterY = 0f;
		f.mipScale = 1f;
		f.renderScale = 1f;
		if (mcopt.metal.shade.taa.ShadeTaa.ON) { // TAA: the world draws into a live sub-rect of the world target, jittered
			var taa = mcopt.metal.shade.taa.ShadeTaa.get();
			if (taa != null && taa.swapped()) {
				f.width = taa.width(f.width);
				f.height = taa.height(f.height);
				f.jitterX = taa.jitterNdcX();
				f.jitterY = taa.jitterNdcY();
				f.mipScale = taa.mipScale();
				f.renderScale = taa.scale();
			}
		}

		// sky, dimension
		f.dimension = sky.skybox == DimensionType.Skybox.OVERWORLD ? ShadeFrame.DIM_OVERWORLD
			: sky.skybox == DimensionType.Skybox.END ? ShadeFrame.DIM_END : ShadeFrame.DIM_NETHER;
		if (f.dimension == ShadeFrame.DIM_OVERWORLD) {
			// SkyRenderer: RotY(-90) * RotX(angle) * (0, 1, 0)
			Shade.celestial(sky.sunAngle, DIR);
			f.sunDir.set((float) DIR[0], (float) DIR[1], (float) DIR[2]);
			Shade.celestial(sky.moonAngle, DIR);
			f.moonDir.set((float) DIR[0], (float) DIR[1], (float) DIR[2]);
			// (1.1) user.moonPhases false: always a full moon (its light and its disc)
			int phase = Live.b(ShadeLook.U + "moonPhases", true) ? sky.moonPhase.index() : 0;
			f.moonPhase = MOON_BRIGHTNESS[Math.floorMod(phase, 8)];
			moonPhaseIndex = phase;
			f.starBrightness = sky.starBrightness;
			f.dayTime = (float) (sky.sunAngle / (2 * Math.PI) - Math.floor(sky.sunAngle / (2 * Math.PI)));
			Vector3fc skyColor = sky.skyColor;
			if (skyColor != null) {
				f.skyColor[0] = skyColor.x();
				f.skyColor[1] = skyColor.y();
				f.skyColor[2] = skyColor.z();
			}
		} else {
			f.sunDir.set(0f, 1f, 0f);
			f.moonDir.set(0f, -1f, 0f);
			f.starBrightness = 0f;
		}
		if (ShadeBindings.fallback()) f.dimension = ShadeFrame.DIM_VANILLA;
		f.rain = level != null ? level.getRainLevel(partial) : 0f;
		f.thunder = level != null ? level.getThunderLevel(partial) : 0f;
		f.gameTimeSeconds = ((state.gameTime % 72000L) + partial) / 20f;
		f.partialTick = partial;

		// fog
		FogData fog = camera.fogData;
		FogType fogType = camera.fogType;
		f.fogType = fogType == FogType.WATER ? ShadeFrame.FOG_WATER : fogType == FogType.LAVA ? ShadeFrame.FOG_LAVA
			: fogType == FogType.POWDER_SNOW ? ShadeFrame.FOG_POWDER_SNOW : ShadeFrame.FOG_AIR;
		f.underwater = fogType == FogType.WATER;
		Vector4f fogColor = fog.color;
		f.fogColor[0] = fogColor.x;
		f.fogColor[1] = fogColor.y;
		f.fogColor[2] = fogColor.z;
		// The game's fog colour wins under water, in lava and powder snow, outside the overworld, and with fog that closes in
		// (blindness, darkness, the boss fog): there the atmosphere has nothing to say.
		float vanilla = f.fogType != ShadeFrame.FOG_AIR || f.dimension != ShadeFrame.DIM_OVERWORLD ? 1f
			: Math.min(Math.max((64f - fog.environmentalEnd) / 32f, 0f), 1f);
		f.fogColor[3] = vanilla;
		f.fogEnvStart = fog.environmentalStart;
		f.fogEnvEnd = fog.environmentalEnd;
		if (f.fogType == ShadeFrame.FOG_WATER) {
			// (1.1) user.underwaterView: how far the eye sees under water (vanilla's water fog range, stretched)
			float uw = Live.f(ShadeLook.U + "underwaterView", 1f, 0.25f, 4f);
			f.fogEnvStart *= uw;
			f.fogEnvEnd *= uw;
		}
		f.fogRenderStart = fog.renderDistanceStart;
		f.fogRenderEnd = fog.renderDistanceEnd;
		f.fogSkyEnd = fog.skyEnd;
		f.fogCloudEnd = fog.cloudEnd;

		// light around the camera, brightness, night vision
		f.eyeSkyLight = level != null ? level.getBrightness(LightLayer.SKY, camera.blockPos) : 15;
		var lightmap = game.lightmapRenderState;
		f.nightVision = lightmap.nightVisionEffectIntensity;
		// (1.1) user.caveLight: the least light a place gets (caves; the game's Brightness option raises it too)
		f.minAmbient = (0.0025f + 0.02f * lightmap.brightness) * Live.f(ShadeLook.U + "caveLight", 1f, 0f, 6f) + 0.25f * f.nightVision;

		if (!warnedOit && mc.gameRenderer.useImprovedTransparency()) {
			warnedOit = true; // Sodium's OIT pipelines aren't shaded (M2): water and glass then keep vanilla's light
			System.out.println("[mcopt] shade: Improved Transparency is on; translucent blocks are not shaded with it (turn it off for shaders)");
		}
		f.debug = Shade.DEBUG;
		f.frameIndex++;
		long now = System.nanoTime();
		float dt = lastNanos == 0 ? 0f : (now - lastNanos) / 1e9f;
		lastNanos = now;
		boolean snap = lastDimension != f.dimension || dt > 1f;
		// the water's clock: real time (frame deltas, a stall counts at most 0.25 s), wrapped every 4096 s (water.metal rounds every
		// wave speed to whole turns per 4096 s: the wrap is seamless). The game time is
		// tick-based and the integrated server resets it every second (ClientboundSetTimePacket), so waves driven by it
		// jump back or forward whenever the server lags (chunk generation): the "choppy" water of M2.
		// (FT2.8, audit idx 78) the sky (aurora, End sky, Nether fog drift) on the same real time wrapped every 65536 s (~18 h of play): its
		// speeds aren't whole noise tiles per 4096 s, so at the water's wrap the aurora's curtains and the End's beams jumped
		// (a float of up to 65536 still steps by 1/128 s, far below what those slow drifts can show)
		if (WATER_TIME >= 0f) {
			f.waterTime = WATER_TIME; // (dev: frozen waves, for image diffs across jars)
			f.skyTime = WATER_TIME;
		} else if (mcopt.metal.shade.water.ShadeWater.CLOCK) {
			// (1.1) user.waveSpeed: the water's clock (its waves, ripples, rain rings, falls; also the Nether's shimmer)
			waterClock = (waterClock + Math.min(dt, 0.25) * Live.f(ShadeLook.U + "waveSpeed", 1f, 0f, 3f)) % 4096.0;
			skyClock = (skyClock + Math.min(dt, 0.25)) % 65536.0;
			f.waterTime = (float) waterClock;
			f.skyTime = (float) skyClock;
		} else {
			f.waterTime = f.gameTimeSeconds;
			f.skyTime = f.gameTimeSeconds;
		}
		lastDimension = f.dimension;
		f.updateAtmosphere(Math.min(dt, 0.25f), snap);
		if (snap) LOOK.snapExposure();
		// M3 sky and dimensions (mcopt.shade.dims / aurora): Nether and End light, palettes and exposure; the aurora's state
		if (mcopt.metal.shade.dims.DimsConfig.DIMS || mcopt.metal.shade.dims.DimsConfig.aurora() != 0) {
			mcopt.metal.shade.dims.ShadeDims.update(f, level, sky, camera.blockPos, Math.min(dt, 0.25f), snap);
		}
		ShadeShadows.beforePack(camera, f);
		LOOK.update(f, moonPhaseIndex, dt); // grades f.sky.light: before f.pack
		if (mcopt.metal.shade.weather.ShadeWeather.ON) { // M3 weather: wetness, snow, wind, lightning (ShadeLook.wet/wind/flash)
			mcopt.metal.shade.weather.WeatherFrame.update(level, x, y, z, f.rain, f.thunder, f.dimension == ShadeFrame.DIM_OVERWORLD, Math.min(dt, 0.25f),
				(float) (state.gameTime / 24000L), (float) ((now / 1_000_000L) % 3_600_000L) / 1000f, snap);
		}

		if (mcopt.metal.shade.water.ShadeWater.ON) {
			// M3 weather: the rain that actually falls here (none in deserts, snow is not rain), smoothed
			float waterRain = mcopt.metal.shade.weather.ShadeWeather.ON ? mcopt.metal.shade.weather.ShadeWeather.rainIntensity() : f.rain;
			mcopt.metal.shade.water.WaterFrame.update(ShadeBindings.ctx(), level, x, y, z, f.underwater, waterRain);
		}
		f.pack(ShadeBindings.nextSlot());
		ShadePbr.frame();
		LOOK.pack(ShadeBindings.currentLook(), f);
		mcopt.metal.shade.dims.ShadeDims.pack(ShadeBindings.currentLook(), ShadeBindings.currentSlot(), f);
		if (mcopt.metal.shade.dims.ShadeXdr.active()) mcopt.metal.shade.dims.ShadeXdr.frame(Math.min(dt, 0.25f));
		ShadeDiag.frame(); // (1.2.5) a latest.log line a minute: hitches, GC, thermal state
		ShadeBindings.publish();
		ShadeBindings.renderSkyLut(enc);
		mcopt.metal.shade.dims.ShadeAurora.render(enc); // M3.3 (dims): the reduced-resolution aurora the sky pass reads
		// M3 clouds: shadow map, march, resolve and reflection dome before the sky pass composites them (needs the LUT)
		if (mcopt.metal.shade.clouds.ShadeClouds.ON && ShadeConfig.HDR && !ShadeBindings.fallback()) {
			mcopt.metal.shade.clouds.ShadeClouds.update(ShadeBindings.ctx(), enc, f, ShadeBindings.currentLook());
		}
		// FT1: Distant Horizons' own SSAO / TAA / vanilla fade off while the shade frame runs (back to its settings otherwise)
		if (mcopt.metal.shade.dh.ShadeDh.LOADED) mcopt.metal.shade.dh.ShadeDh.frame(ShadeConfig.HDR && !ShadeBindings.fallback());
		// M3 dynamic lights: this frame's lights into their ring slot, occupancy refresh, visibility volumes (before the world)
		if (mcopt.metal.shade.light.DynLights.ON) mcopt.metal.shade.light.DynLights.frame(ShadeBindings.ctx(), enc, camera, level, partial);
		ShadeLean.update(f.dimension, f.underwater); // M3.1: which lean terrain variant this frame's world pass draws with
		if (mcopt.metal.shade.terrain.ShadeTerrain.ON) mcopt.metal.shade.terrain.ShadeTerrain.frame(); // (v12) own terrain's shaded stage for it
		if (mcopt.metal.shade.water.ShadeWater.ON) mcopt.metal.shade.water.ShadeWater.bake(ShadeBindings.ctx(), enc);
		if (ShadeConfig.HDR && !ShadeBindings.fallback()) mcopt.metal.shade.weather.ShadeWeather.bakeNoise(enc);
		if (ShadeConfig.HDR && !ShadeBindings.fallback()) ShadePost.beginWorld(encoder, enc, mc.gameRenderer.mainRenderTarget());
		if (LOG_EVERY > 0 && now - lastLog > LOG_EVERY * 1_000_000_000L) {
			lastLog = now;
			System.out.println(String.format(java.util.Locale.ROOT, "[mcopt] shade: e %.1f deg, exposure ref %.3f gpu %.3f, metered log2 %.2f, sat %.2f, contrast %.2f, bloom %.3f, mist %.2f, wb %.0f%s",
				LOOK.elevation, LOOK.exposureRef, ShadeBindings.gpuExposure(), ShadeBindings.gpuMeteredLog2(), LOOK.saturation, LOOK.contrast,
				LOOK.bloomMix, LOOK.mistSigma, LOOK.whiteBalance,
				mcopt.metal.shade.weather.ShadeWeather.ON ? ", " + mcopt.metal.shade.weather.ShadeWeather.describeState() : ""));
		}
	}

	/** The water's real-time clock (seconds, wrapped every 4096 s: water.metal SHADE_WATER_CLOCK_WRAP, seamless). */
	private static double waterClock, skyClock;
	/** -Dmcopt.shade.waterTime=SECONDS (dev, 2026-10-08): the waves stand still at that clock (image diffs of two jars). */
	private static final float WATER_TIME = Float.parseFloat(System.getProperty("mcopt.shade.waterTime", "-1"));

	/** mcopt.shade.log=N: a line with the art layer's state every N seconds (0 = never). */
	private static final int LOG_EVERY = Integer.getInteger("mcopt.shade.log", 0);
}
