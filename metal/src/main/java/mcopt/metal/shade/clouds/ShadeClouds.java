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
import mcopt.metal.shade.ShadeFrame;
import mcopt.metal.shade.ShadePost;
import mcopt.metal.shade.ShadeRender;
import net.minecraft.client.CloudStatus;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.util.ARGB;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.system.MemoryUtil;

/**
 * M3 volumetric clouds (bible E05): cumulus with multiple scattering, silver linings and dark storm bases, a cirrus layer,
 * cloud shadows and a daily weather, in place of vanilla's clouds. Each frame, before the sky pass (ShadeFrameUpdater,
 * right after the sky LUT): the daily weather and wind (CloudWeather), CloudParams, then on the GPU (mcclouds.m) the cloud
 * shadow map, the checkerboard march at a fraction of the output resolution, its temporal resolve, and the reflection dome.
 * The outputs go to ShadeResources 12-14 and ShadeLook (cloudShadowVP, clouds0/1, SHADE_FEATURE_CLOUDS); the sky pass
 * composites the clouds behind the world (sky.fs.metal), terrain/water/god rays read the shadow map (shade_clouds.metal).
 * Vanilla's cloud draw is skipped while this draws (MetalRenderPass, {@link #replacesVanilla}). Render thread only.
 * See CLOUDS.md.
 */
public final class ShadeClouds {
	/** The module is on (flags); with it off nothing here runs and vanilla's clouds draw as in M2. */
	public static final boolean ON = CloudConfig.ENABLED;
	public static final int RESOURCE_SHADOW = 12, RESOURCE_DOME = 13, RESOURCE_SCREEN = 14;
	private static final int ERR = 4096;

	private static long state;
	private static boolean failed, active, wasActive;
	private static final CloudWeather WEATHER = new CloudWeather();
	private static final CloudParams PARAMS = new CloudParams();
	private static final ByteBuffer PACKED = MemoryUtil.memAlloc(CloudParams.SIZE).order(ByteOrder.nativeOrder());
	private static final long OUT = MemoryUtil.nmemCalloc(3, 8);
	private static final long TIMES = MemoryUtil.nmemCalloc(5, 4);
	private static long lastNanos, lastLog;
	private static int frame, domeFrames;
	private static double lastX, lastY, lastZ;
	private static int lastDimension = -1;
	private static int lastMode = -1;
	/** M3.3 (robustness, mcopt.shade.clouds.timeSnap): the day time of the last frame, to drop the history on a time jump. */
	private static long lastTicks = Long.MIN_VALUE;
	/** ShadePost before-tonemap order (AO 50, clouds 80, VL 100). */
	public static final int HOOK_ORDER = 80;
	private static boolean hooked, over;
	/** Distant Horizons loaded (mcopt.shade.clouds.withDh=false: then the Clouds option decides, as without DH). */
	private static final boolean DH = mcopt.metal.DhCompat.loaded() && CloudConfig.flag("mcopt.shade.clouds.withDh", true);

	private ShadeClouds() {
	}

	private static final String DH_API = "com.seibel.distanthorizons.api.";
	/** DH's own clouds are switched off by us (an API override), or the API is unusable. */
	private static boolean dhCloudsOff, dhApiFailed;

	/**
	 * Distant Horizons draws its own clouds (flat, LOD-sized) on top of everything, ours included: while ours draw, switch
	 * them off through DH's public config API (DhApi.Delayed.configs ... cloudRenderingEnabled; an API override that
	 * DistantHorizons.toml keeps nothing of), and clear the override when ours stop (pause, other dimension, failure).
	 * Reflection: no compile-time dependency on DH. Does nothing until DH's API is up, or without DH.
	 */
	private static void dhClouds(boolean ours) {
		if (!DH || dhApiFailed || ours == dhCloudsOff) return;
		try {
			ClassLoader cl = ShadeClouds.class.getClassLoader();
			Object cfg = Class.forName(DH_API + "DhApi$Delayed", true, cl).getField("configs").get(null);
			if (cfg == null) return; // DH not initialised yet: next frame
			Object g = Class.forName(DH_API + "interfaces.config.IDhApiConfig", true, cl).getMethod("graphics").invoke(cfg);
			Object gr = Class.forName(DH_API + "interfaces.config.client.IDhApiGraphicsConfig", true, cl).getMethod("genericRendering").invoke(g);
			Object v = Class.forName(DH_API + "interfaces.config.client.IDhApiGenericRenderingConfig", true, cl).getMethod("cloudRenderingEnabled").invoke(gr);
			Class<?> value = Class.forName(DH_API + "interfaces.config.IDhApiConfigValue", true, cl);
			Object r = ours ? value.getMethod("setValue", Object.class).invoke(v, Boolean.FALSE) : value.getMethod("clearValue").invoke(v);
			if (Boolean.FALSE.equals(r)) throw new IllegalStateException("DH refused the API value");
			dhCloudsOff = ours;
			System.out.println("[mcopt] shade clouds: Distant Horizons' own clouds " + (ours ? "off (ours draw)" : "back to its setting"));
		} catch (Throwable t) {
			dhApiFailed = true;
			System.out.println("[mcopt] shade clouds: could not switch Distant Horizons' clouds (" + t + "); set Clouds off in DH's settings");
		}
	}

	/** Whether vanilla's clouds are replaced this frame (MetalRenderPass skips their draw). */
	public static boolean replacesVanilla() {
		return ON && (active || userOff);
	}

	/** (1.1) The settings screen's "Clouds: Off" this frame (in the overworld): neither ours nor vanilla's draw. */
	private static boolean userOff;
	/** (1.1) The style last drawn (a switch drops the history once). */
	private static int lastStyle = -1;
	/**
	 * (1.1) The live settings last drawn whose change needs a reset: the checkerboard (the march target's size), the layer's base
	 * setting (NaN = vanilla's height) and thickness (the history holds the clouds at the old height: dropped like a teleport),
	 * the dome (turned on: a fresh one, not one blended from stale or never written texels) and the shadows (turned on: the map
	 * rendered that frame).
	 */
	private static int lastChecker = -1;
	private static float lastBase = Float.NaN, lastThickness = -1f;
	private static boolean lastDome, lastShadows;

	/**
	 * (1.1) The game's cloud texture uploaded as a mask (mc_clouds_vanilla): the blocky style then draws vanilla's own cloud
	 * shapes (12 x 4 x 12 cells drifting as vanilla's do), not the weather map's cells. Tried once per state; false = the
	 * weather map's cells (the Storybook look's blocky clouds before 1.1).
	 */
	private static boolean vanillaMask, vanillaTried;
	private static int vanillaW = 256, vanillaH = 256;
	private static double lastVanillaX = Double.NaN;

	/** Loads textures/environment/clouds.png (resource packs included) into the native mask; false when it can't. */
	private static boolean loadVanillaMask(long ctx) {
		vanillaTried = true;
		Minecraft mc = Minecraft.getInstance();
		try (java.io.InputStream in = mc.getResourceManager().open(net.minecraft.resources.Identifier.withDefaultNamespace("textures/environment/clouds.png"));
			com.mojang.blaze3d.platform.NativeImage img = com.mojang.blaze3d.platform.NativeImage.read(in)) {
			int w = img.getWidth(), h = img.getHeight();
			ByteBuffer mask = MemoryUtil.memAlloc(w * h);
			try {
				// a cell holds a cloud as vanilla's CloudRenderer.isCellEmpty says (alpha 10 and up)
				for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) mask.put(y * w + x, (byte) (ARGB.alpha(img.getPixel(x, y)) >= 10 ? 255 : 0));
				if (CloudNative.vanilla(state, ctx, MemoryUtil.memAddress(mask), w, h) == 0) return false;
			} finally {
				MemoryUtil.memFree(mask);
			}
			vanillaW = w;
			vanillaH = h;
			System.out.println("[mcopt] shade clouds: blocky style with the game's cloud texture (" + w + "x" + h + ")");
			return true;
		} catch (Throwable t) {
			System.out.println("[mcopt] shade clouds: no vanilla cloud texture for the blocky style (" + t + "); the weather map's cells instead");
			return false;
		}
	}

	/** (1.1) The blocky style this frame (ShadeSettings "Clouds: Blocky", live; was CloudConfig.BLOCKY at startup). */
	/** (v12-opt) The style the specialized passes are built for: CloudParams.art.w with the startup setting (blocky: the game's cells). */
	static float leanStyle() {
		return blocky() ? 2f : 0f;
	}

	public static boolean blocky() {
		return mcopt.metal.shade.ShadeSettings.clouds() == mcopt.metal.shade.ShadeSettings.CLOUDS_BLOCKY;
	}

	/**
	 * Called once per level frame before the sky pass, after ShadeLook was packed (look: this frame's ShadeLook bytes).
	 * ctx/enc: the backend context and the frame's native encoder.
	 */
	public static void update(long ctx, long enc, ShadeFrame f, ByteBuffer look) {
		active = false;
		over = false;
		userOff = false;
		if (failed) {
			dhClouds(false);
			PARAMS.packLook(look, false);
			return;
		}
		try {
			Minecraft mc = Minecraft.getInstance();
			ClientLevel level = mc.level;
			var game = mc.gameRenderer.gameRenderState();
			// the game's Clouds option OFF turns them off, except with Distant Horizons, which sets that option itself (its LODs
			// would show through vanilla's clouds; ours draw behind the LODs, in the sky pass)
			boolean option = game.optionsRenderState.cloudStatus != CloudStatus.OFF || DH;
			// mcopt.shade.clouds.pause (read every frame; the bench's in-session A/B sets it): as if the module were off
			// (1.1) the settings screen's choice (ShadeSettings, live): Minecraft = vanilla's clouds (lit by clouds.fs, as with the
			// module off), Off = none at all (vanilla's skipped too, replacesVanilla; Distant Horizons' own kept off)
			int userMode = mcopt.metal.shade.ShadeSettings.clouds();
			userOff = userMode == mcopt.metal.shade.ShadeSettings.CLOUDS_OFF && level != null && f.dimension == ShadeFrame.DIM_OVERWORLD;
			boolean want = level != null && f.dimension == ShadeFrame.DIM_OVERWORLD && option && ARGB.alpha(game.levelRenderState.cloudColor) > 0
				&& !Boolean.getBoolean("mcopt.shade.clouds.pause") && userMode <= mcopt.metal.shade.ShadeSettings.CLOUDS_BLOCKY;
			dhClouds(want || userOff);
			if (!want) {
				wasActive = false;
				PARAMS.packLook(look, false);
				return;
			}
			if (state == 0 && !init(ctx)) {
				PARAMS.packLook(look, false);
				return;
			}
			long now = System.nanoTime();
			float dt = lastNanos == 0 ? 0f : Math.min((now - lastNanos) / 1e9f, 0.25f);
			boolean longGap = lastNanos != 0 && now - lastNanos > 1_000_000_000L;
			lastNanos = now;
			double dx = f.cameraX - lastX, dy = f.cameraY - lastY, dz = f.cameraZ - lastZ;
			boolean teleport = dx * dx + dy * dy + dz * dz > 64.0 * 64.0;
			boolean snap = !wasActive || longGap || teleport || lastDimension != f.dimension;
			// M3.3 robustness: a jump of the day time (sleeping, /time set) changes the clouds' light and the day's weather at once;
			// the history kept the old sky and, marched 1/9 of the pixels per frame and blended 1/age, took ~3.5 s at 90 fps
			// (~11 s at 30 real fps, frame generation) to let go of it: smeared streaky clouds. More than 200 ticks (10 s of game
			// time) between two frames now drops it like a teleport. mcopt.shade.clouds.timeSnap=false (read every frame): M3.2.
			long dayTicks = level.getDefaultClockTime();
			if (lastTicks != Long.MIN_VALUE && Math.abs(dayTicks - lastTicks) > 200 && !"false".equals(System.getProperty("mcopt.shade.clouds.timeSnap"))) snap = true;
			lastTicks = dayTicks;
			lastX = f.cameraX;
			lastY = f.cameraY;
			lastZ = f.cameraZ;
			lastDimension = f.dimension;

			// M3.1 dev bits (mcopt.shade.clouds.dev, read every frame; 0 normally): the bench's price phases switch passes or
			// consumers off, or an optimisation back to M3's way, inside one session (CloudConfig.DEV_*, CLOUDS.md "M3.1 performance")
			int dev = CloudConfig.devBits();
			// M3.3 mode bits (read every frame): switching the resolve drops the history once (its data target differs)
			int mode = CloudConfig.modeBits();
			boolean modeChanged = lastMode < 0 || ((mode ^ lastMode) & CloudConfig.MODE_STABLE) != 0;
			lastMode = mode;
			int style = blocky() ? 1 : 0;
			if (style != lastStyle) modeChanged = true;
			lastStyle = style;
			// sizes: a fraction of the output, independent of TAAU's render scale (2026-10-09: the chosen output resolution, not
			// the window's, ShadeOutput: at "1080p" on a Retina screen the clouds cost what they do on a 1080p monitor)
			var window = mc.getWindow();
			int[] outSize = mcopt.metal.shade.ShadeOutput.current(window.getWidth(), window.getHeight());
			int ow = outSize[0], oh = outSize[1];
			// (1.1: mcopt.shade.clouds.scale and .checker live, the preset's by default: a change resizes the targets below, which
			// drops the history, as the dev bits' switch does)
			float scale = (dev & CloudConfig.DEV_SCALE_ALT) != 0 ? CloudConfig.SCALE_ALT : CloudConfig.scale();
			int hw = Math.max(16, Math.round(ow * scale)), hh = Math.max(16, Math.round(oh * scale));
			// (M3.3: dev bit DEV_CHECKER_ALT = the other checkerboard, mcopt.shade.clouds.checkerAlt, for in-session pricing; the
			// march target's size changes, so the switch drops the history once)
			int checker = (dev & CloudConfig.DEV_CHECKER_ALT) != 0 ? CloudConfig.CHECKER_ALT : CloudConfig.checker();
			// (1.1: the slot order and age cap follow N too: a change drops the history even where the sizes happen to stay)
			if (checker != lastChecker) modeChanged = true;
			lastChecker = checker;
			hw = (hw + checker - 1) / checker * checker;
			hh = (hh + checker - 1) / checker * checker;
			int mw = hw / checker, mh = hh / checker;
			boolean resized = CloudNative.size(state, ctx, hw, hh, mw, mh, CloudConfig.DOME_W, CloudConfig.DOME_H) != 0;

			// weather and wind
			long ticks = level.getDefaultClockTime();
			double days = (ticks + f.partialTick) / 24000.0;
			WEATHER.update(days, f.rain, f.thunder, dt, snap, CloudConfig.SEED);
			// (M3.3: mcopt.shade.clouds.freeze, read every frame, default false: the clouds stand still, no wind displacement at
			// all, for look comparisons of variants shot one after another inside one session; the bench sets it)
			float move = Boolean.getBoolean("mcopt.shade.clouds.freeze") ? 0f : dt;
			float sx = WEATHER.windX * WEATHER.windSpeed * move, sz = WEATHER.windZ * WEATHER.windSpeed * move;
			CloudParams p = PARAMS;
			p.windX += sx;
			p.windZ += sz;
			p.wind3X += sx * CloudConfig.NOISE_DRIFT;
			p.wind3Z += sz * CloudConfig.NOISE_DRIFT;
			p.cirrusX += sx * 1.7;
			p.cirrusZ += sz * 1.7;
			// keep the accumulators small (each wraps at a multiple of its noise period)
			p.windX %= CloudParams.WEATHER_PERIOD * 64;
			p.windZ %= CloudParams.WEATHER_PERIOD * 64;
			p.wind3X %= CloudParams.NOISE_PERIOD * 64;
			p.wind3Z %= CloudParams.NOISE_PERIOD * 64;
			p.cirrusX %= CloudParams.WEATHER_PERIOD * 64;
			p.cirrusZ %= CloudParams.WEATHER_PERIOD * 64;
			p.windStepX = sx;
			p.windStepZ = sz;
			float vanillaHeight = game.levelRenderState.cloudHeight;
			// (1.1) the blocky style with the game's cloud texture: vanilla's cells at vanilla's height, 4 blocks thick (its fancy
			// clouds; mcopt.shade.clouds.blockThickness overrides), drifting as its CloudRenderer moves them (0.03 blocks per tick
			// along x, the texture offset 3.96 blocks along z)
			if (blocky() && !vanillaTried) vanillaMask = loadVanillaMask(ctx);
			boolean cells = blocky() && vanillaMask;
			p.vanillaCells = cells;
			if (cells) {
				if (!wasActive || modeChanged || longGap) lastVanillaX = Double.NaN;
				// Use the same real-time wind clock as the volumetric clouds. Re-reading server-corrected game ticks every
				// frame moved blocky cloud shadows backward on time packets (issue #22). Initialise from the game once,
				// then integrate; pausing/freezing the cloud field must freeze both its image and its shadows.
				double period = vanillaW * 12.0;
				double step = Double.isNaN(lastVanillaX) ? 0.0 : move * 0.6 * CloudConfig.wind();
				double drift = Double.isNaN(lastVanillaX)
					? ((level.getGameTime() % (vanillaW * 400L)) + f.partialTick) * 0.03
					: (lastVanillaX + step) % period;
				lastVanillaX = drift;
				p.vanillaX = drift;
				p.vanillaStepX = (float) step; // continuous even across the texture-period wrap
				p.vanillaPeriodX = vanillaW * 12.0;
				p.vanillaPeriodZ = vanillaH * 12.0;
			} else {
				lastVanillaX = Double.NaN;
			}
			// (1.1: the base, the thickness and the blocky slab live; a change of the setting drops the history like a teleport, the
			// clouds it holds stand at the old height. Not a change of vanilla's own cloud height: that kept the history before too)
			float baseSet = CloudConfig.base();
			float thickness = blocky() ? CloudConfig.blockThickness(cells) : CloudConfig.thickness();
			if (Float.compare(baseSet, lastBase) != 0 || thickness != lastThickness) modeChanged = true;
			lastBase = baseSet;
			lastThickness = thickness;
			p.base = Float.isNaN(baseSet) ? (Float.isFinite(vanillaHeight) && vanillaHeight > 0f ? vanillaHeight + (cells ? 0f : 8f) : 200f) : baseSet;
			p.top = p.base + thickness;
			p.histW = hw;
			p.histH = hh;
			p.marchW = mw;
			p.marchH = mh;
			p.checker = checker;
			p.frame = frame++;
			// (1.1: the dome live; turned on, the history drops once so the dome pass writes a fresh one: its texels are stale, or
			// were never written when it was off from the start, and the pass blends 0.4 of a new march into them otherwise)
			boolean domeOn = CloudConfig.dome();
			if (domeOn && !lastDome) modeChanged = true;
			lastDome = domeOn;
			p.reset = snap || resized || modeChanged;
			if (p.reset) domeFrames = 0;
			p.domeValid = domeOn && domeFrames > 0;
			p.domeUpdates = domeFrames;
			// (1.1: the player's mcopt.shade.user.cloudOpacity, live; 1 = as released. CloudParams scales the shadows by it too)
			p.opacity = CloudConfig.userOpacity();
			p.dev = dev;
			p.mode = mode;
			// the shadow map and the dome change slowly (the wind moves the shadows ~1/25 of a map texel in 4 frames): each every
			// fourth frame, never in the same frame (both after a reset). CloudParams keeps the map's own frame in between.
			// (M3.1: the dome every 8th frame at performance/balanced, CloudConfig.DOME_EVERY: its 8k rays cost ~0.11 ms per update,
			// the long horizon rays' latency, not their number)
			int domeEvery = (dev & CloudConfig.DEV_OLD_DOME) != 0 ? 4 : CloudConfig.DOME_EVERY;
			boolean dome = (p.frame & (domeEvery - 1)) == 1;
			// (1.1: the shadows live; off = no map pass and strength 0 (CloudParams); turned on, the map is rendered this frame, it
			// holds the frame it was last rendered in, or nothing)
			boolean shadows = CloudConfig.shadows();
			p.shadowUpdate = shadows && ((p.frame & 3) == 3 || p.reset || !lastShadows);
			lastShadows = shadows;
			p.pack(PACKED, f, WEATHER);
			int flags = 2 | (p.shadowUpdate ? 1 : 0) | (domeOn && (dome || p.reset) ? 4 : 0)
				| (CloudConfig.GPU_TIMER ? 8 : 0) | ((mode & CloudConfig.MODE_STABLE) != 0 ? 16 : 0) | (cells ? 32 : 0)
				| (mcopt.metal.shade.Live.b("mcopt.shade.cloudLean", true) ? 64 : 0);
			if (!p.reset) {
				if ((dev & CloudConfig.DEV_NO_SCREEN) != 0) flags &= ~2;   // pricing: no march / resolve (the consumers read the old history)
				if ((dev & CloudConfig.DEV_NO_MAPS) != 0) flags &= ~(1 | 4); // pricing: no shadow map / dome pass
			}
			CloudNative.render(enc, state, MemoryUtil.memAddress(PACKED), CloudParams.SIZE, flags);
			if ((flags & 4) != 0) domeFrames++;
			CloudNative.outputs(state, OUT);
			ShadeRender.resource(RESOURCE_SHADOW, MemoryUtil.memGetAddress(OUT));
			ShadeRender.resource(RESOURCE_DOME, MemoryUtil.memGetAddress(OUT + 8));
			ShadeRender.resource(RESOURCE_SCREEN, MemoryUtil.memGetAddress(OUT + 16));
			active = true;
			wasActive = true;
			// up at (or above) the cloud layer, clouds stand in front of the world too: composited before the tone map
			over = f.cameraY > p.base - 48.0;
			if (!hooked && ShadePost.active()) {
				hooked = true;
				ShadePost.addBeforeTonemap(HOOK_ORDER, ShadeClouds::beforeTonemap);
			}
			PARAMS.packLook(look, true);
			if (CloudConfig.LOG && now - lastLog > 2_000_000_000L) {
				lastLog = now;
				String times = "";
				if (CloudConfig.GPU_TIMER) {
					CloudNative.times(state, TIMES);
					times = String.format(java.util.Locale.ROOT, ", gpu ms shadow %.3f march %.3f resolve %.3f dome %.3f (%d frames)", MemoryUtil.memGetFloat(TIMES),
						MemoryUtil.memGetFloat(TIMES + 4), MemoryUtil.memGetFloat(TIMES + 8), MemoryUtil.memGetFloat(TIMES + 12), (int) MemoryUtil.memGetFloat(TIMES + 16));
				}
				System.out.println(String.format(java.util.Locale.ROOT, "[mcopt] shade clouds: day %.2f, %s, layer %.0f-%.0f, %dx%d (march %dx%d), light %.2f %.2f %.2f %s%s",
					days, WEATHER.describe(), p.base, p.top, hw, hh, mw, mh, p.light[0], p.light[1], p.light[2], p.sunLit ? "sun" : "moon", times));
			}
		} catch (Throwable t) {
			failed = true;
			active = false;
			System.out.println("[mcopt] shade: clouds failed, vanilla clouds from now on: " + t);
			t.printStackTrace();
			PARAMS.packLook(look, false);
		}
	}

	private static void beforeTonemap(ShadePost.Context c) {
		if (!active || !over || failed || state == 0 || c.depth() == 0 || c.scene() == 0) return;
		try {
			// Distant Horizons' LODs are not in the world depth (empty there): with DH drawn this frame, pixels below the horizon
			// without world depth are taken as far terrain behind the clouds (mode 1)
			CloudNative.over(c.enc(), state, c.scene(), c.depth(), c.width(), c.height(), DH && ShadePost.bridgedThisFrame() ? 1 : 0);
		} catch (Throwable t) {
			System.out.println("[mcopt] shade: clouds over the world failed: " + t);
			over = false;
		}
	}

	private static boolean init(long ctx) {
		ByteBuffer src = MemoryUtil.memUTF8(CloudConfig.source());
		try (MemoryStack stack = MemoryStack.stackPush()) {
			long err = stack.nmalloc(1, ERR);
			MemoryUtil.memPutByte(err, (byte) 0);
			long t0 = mcopt.metal.shade.ShadeCompile.now();
			long s = mcopt.metal.shade.ShadeRobust.failCompile("clouds") ? 0 : CloudNative.create(ctx, MemoryUtil.memAddress(src), err, ERR); // M3.3: dev-only injected failure
			mcopt.metal.shade.ShadeCompile.setup("clouds", t0);
			if (s == 0) {
				failed = true;
				System.out.println("[mcopt] shade: clouds setup failed, vanilla clouds: " + MemoryUtil.memUTF8(err));
				return false;
			}
			state = s;
			vanillaTried = false; // (1.1) a new state has no cloud mask yet
			// (v12-opt) the specialized march and resolves for the startup settings (warmed off the render thread by CloudConfig.warmUp)
			if (CloudConfig.LEAN_PASSES) {
				long t1 = mcopt.metal.shade.ShadeCompile.now();
				int ok = CloudNative.lean(s, ctx, CloudConfig.devBits(), CloudConfig.modeBits(), leanStyle());
				mcopt.metal.shade.ShadeCompile.setup("clouds (lean)", t1);
				if (ok == 0) System.out.println("[mcopt] shade: clouds: the specialized passes could not be built (the generic ones run)");
			}
			System.out.println("[mcopt] shade: volumetric clouds on (" + CloudConfig.describe() + ")");
			return true;
		} finally {
			MemoryUtil.memFree(src);
		}
	}
}
