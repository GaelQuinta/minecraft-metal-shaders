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
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.FutureTask;
import java.util.concurrent.PriorityBlockingQueue;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import mcopt.metal.MetalBridge;
import mcopt.metal.MetalShaderRegistry;
import org.jspecify.annotations.Nullable;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.system.MemoryUtil;

/**
 * Native shading's shader compilation off the render thread and several at once (mcopt.shade.compile.parallel, default true;
 * false = everything compiles one after another where it did before, the A/B baseline). Metal compiles in its own process,
 * up to maximumConcurrentCompilationTaskCount requests at once (10 on an M4), and caches every result on disk per app. With
 * that cache cold (the first launch, a mod update that changes the MSL, the first launch after a macOS update) two things
 * were slow:
 * <ul>
 * <li>the startup reload: each pipeline's prewarmed format variants (MetalPipeline.prewarm) were built one after another on
 * the worker compiling it, and the Sodium translucent terrain alone has 24 lean variants of the water fragment, ~0.8 s each
 * cold: a ~19 s chain on one thread while the other workers had long finished (tools/shade/compilebench). They now go to
 * this pool ({@link #runAll}), with the worker building the ones nobody has started yet;</li>
 * <li>the first world frame: every shade module compiles its library and pipelines on the render thread when it starts
 * (~1.6 s of libraries and ~1 s of pipelines cold). A warm-up ({@link #warmUps}) builds the same libraries and pipelines on
 * this pool right after the Metal device exists and drops them: the module's own setup then finds them in Metal's cache
 * (~1 ms each; a request for one still being built joins it).</li>
 * </ul>
 * Nothing compiled changes: the same sources, options and descriptors, through the same native functions (or, for the
 * modules built natively, their own create and free). Results are only ever used through the module's own call, so its
 * error handling and fallbacks are unchanged. The pool's threads run at QoS user-initiated (below the render thread's
 * user-interactive; Metal's compiler service runs a request at its sender's QoS). Startup timings are logged
 * ("[mcopt] shade shaders: ...") with the pool on or off, for A/B runs with the cache cold or warm.
 */
public final class ShadeCompile {
	public static final boolean PARALLEL = Shade.ENABLED && Boolean.parseBoolean(System.getProperty("mcopt.shade.compile.parallel", "true"));
	/** The warm-up of shade's own libraries and pipelines (mcopt.shade.compile.warm, default true; needs PARALLEL). */
	static final boolean WARM = PARALLEL && Boolean.parseBoolean(System.getProperty("mcopt.shade.compile.warm", "true"));
	/** Threads (mcopt.shade.compile.threads; default 0 = Metal's maximumConcurrentCompilationTaskCount for the device). */
	private static final int THREADS = Integer.getInteger("mcopt.shade.compile.threads", 0);
	/** QoS class of the threads (mcopt.shade.compile.qos): initiated (default), utility or default. */
	private static final String QOS = System.getProperty("mcopt.shade.compile.qos", "initiated").trim().toLowerCase(Locale.ROOT);
	/** World frames after the first one at which the startup summary is logged (mcopt.shade.compile.summaryFrames). */
	private static final int SUMMARY_FRAMES = Integer.getInteger("mcopt.shade.compile.summaryFrames", 300);
	/** Queue order: prewarm variants (the reload waits for them) before the warm-up (needed only when a world starts). */
	private static final int PRIORITY_PREWARM = 0, PRIORITY_WARM = 1, PRIORITY_BACKGROUND = 2;

	private static @Nullable ThreadPoolExecutor pool;
	private static int threads, maxTasks;
	private static final AtomicLong SEQ = new AtomicLong();
	// warm-up progress
	private static long startNs, warmDoneNs;
	private static int warmTotal;
	private static final AtomicInteger WARM_LEFT = new AtomicInteger(), WARM_FAILED = new AtomicInteger();
	private static final AtomicLong WARM_WORK_NS = new AtomicLong();
	private static final List<String> warmFailures = new ArrayList<>();
	// startup summary
	private static long worldNs, frames;
	private static @Nullable Map<String, Object> beforeWorld;
	private static final Map<String, long[]> setups = new LinkedHashMap<>();

	private ShadeCompile() {
	}

	/** One pool task, ordered by priority, then by submission. */
	private static final class Job extends FutureTask<Void> implements Comparable<Job> {
		private final int priority;
		private final long seq = SEQ.getAndIncrement();

		Job(Runnable r, int priority) {
			super(r, null);
			this.priority = priority;
		}

		@Override
		public int compareTo(Job o) {
			return this.priority != o.priority ? Integer.compare(this.priority, o.priority) : Long.compare(this.seq, o.seq);
		}
	}

	/** MetalDevice, once the Metal device exists (shading on): the pool, the prewarm runner and the warm-up. */
	public static synchronized void start(long ctx) {
		if (startNs != 0 || !Shade.ENABLED) return;
		startNs = System.nanoTime();
		if (!PARALLEL) {
			System.out.println("[mcopt] shade shaders: parallel compile off (mcopt.shade.compile.parallel=false): one after another, as before");
			return;
		}
		try {
			maxTasks = ShadeNative.compileSetup(ctx, Boolean.parseBoolean(System.getProperty("mcopt.shade.compile.maximize", "true")) ? 1 : 0);
			threads = Math.max(1, Math.min(16, THREADS > 0 ? THREADS : maxTasks > 0 ? maxTasks : Runtime.getRuntime().availableProcessors()));
			int qos = switch (QOS) {
				case "utility" -> 0x11;
				case "default" -> 0x15;
				default -> 0x19; // user-initiated
			};
			AtomicInteger n = new AtomicInteger();
			ThreadPoolExecutor p = new ThreadPoolExecutor(threads, threads, 30, TimeUnit.SECONDS, new PriorityBlockingQueue<>(), r -> {
				Thread t = new Thread(() -> {
					ShadeNative.compileThreadQos(qos);
					r.run();
				}, "mcopt-compile-" + n.incrementAndGet());
				t.setDaemon(true);
				return t;
			});
			p.allowCoreThreadTimeOut(true); // idle after startup: the threads go, and come back for a resource reload
			pool = p;
			MetalShaderRegistry.setPrewarmRunner(ShadeCompile::runAll);
			List<Map.Entry<String, Runnable>> warm = WARM ? warmUps(ctx) : List.of();
			System.out.println("[mcopt] shade shaders: parallel compile on, " + threads + " threads (Metal runs " + maxTasks + " at once), QoS " + QOS
				+ (WARM ? "; warming " + warm.size() + " shade modules" : "; no warm-up (mcopt.shade.compile.warm=false)"));
			warmTotal = warm.size();
			WARM_LEFT.set(warm.size());
			for (Map.Entry<String, Runnable> w : warm) execute(new Job(() -> warmOne(w.getKey(), w.getValue()), PRIORITY_WARM));
		} catch (Throwable t) {
			// no pool: everything compiles where it did before
			MetalShaderRegistry.setPrewarmRunner(null);
			pool = null;
			System.out.println("[mcopt] shade shaders: parallel compile unavailable, one after another as before: " + t);
		}
	}

	/**
	 * (v12) A background build on the pool, after the startup ones (own terrain's stage variants and their pipelines,
	 * ShadeTerrain). False when there is no pool: the caller runs it its own way.
	 */
	public static boolean background(Runnable r) {
		if (pool == null) return false;
		execute(new Job(r, PRIORITY_BACKGROUND));
		return true;
	}

	private static void execute(Job job) {
		ThreadPoolExecutor p = pool;
		if (p == null) return;
		try {
			p.execute(job);
		} catch (RejectedExecutionException e) {
			// shutting down: whoever waits for the job runs it
		}
	}

	/**
	 * MetalShaderRegistry.PrewarmRunner: the builds on the pool, the calling worker building whichever no pool thread has
	 * started yet (so it never just waits, and a busy pool costs no more than building them all here), then waiting for the
	 * rest. Returns the indices of the builds that threw.
	 */
	private static List<Integer> runAll(List<Runnable> builds) {
		int n = builds.size();
		boolean[] failed = new boolean[n];
		Job[] jobs = new Job[n];
		for (int i = 0; i < n; i++) {
			int k = i;
			jobs[i] = new Job(() -> {
				try {
					builds.get(k).run();
				} catch (Throwable t) {
					failed[k] = true;
				}
			}, PRIORITY_PREWARM);
			execute(jobs[i]);
		}
		for (Job j : jobs) j.run(); // a no-op for one a pool thread has started or finished
		List<Integer> out = new ArrayList<>();
		for (int i = 0; i < n; i++) {
			try {
				jobs[i].get();
			} catch (InterruptedException e) {
				Thread.currentThread().interrupt();
				failed[i] = !jobs[i].isDone() || failed[i];
			} catch (Exception e) {
				failed[i] = true;
			}
			if (failed[i]) out.add(i);
		}
		return out;
	}

	// ---- warm-up ------------------------------------------------------------------------------------------------------

	/**
	 * A pipeline the warm-up builds the way ShadeRender.pipeline does (vertex + fragment into one color target of format,
	 * blend as ShadeRender's BLEND_*), or with vertex null the compute kernel named function (ShadeRender.computePipeline).
	 */
	public record Pso(@Nullable String vertex, String function, int format, int blend) {
		public static Pso fullScreen(String fragment, int format) {
			return new Pso("shade_fs_vs", fragment, format, ShadeRender.BLEND_NONE);
		}

		public static Pso kernel(String name) {
			return new Pso(null, name, 0, 0);
		}
	}

	/**
	 * Every shade module's library and pipelines as the module will build them when it starts, as named tasks, for the
	 * modules that are on. Each list mirrors its module's setup: one out of date only means that module compiles cold again
	 * on the render thread, as before (the summary's render-thread setup times show it).
	 */
	private static List<Map.Entry<String, Runnable>> warmUps(long ctx) {
		List<Map.Entry<String, Runnable>> w = new ArrayList<>();
		// ShadeBindings.init (mc_shade_lut_init: same descriptor as ShadeRender.pipeline with no blending)
		w.add(Map.entry("sky LUT", () -> warm(ctx, ShadeMsl.lut(), new Pso("shade_lut_vs", "shade_lut_fs", ShadeRender.RGBA16F, ShadeRender.BLEND_NONE))));
		if (ShadeConfig.HDR) {
			// ShadePost.init (without the XDR final passes: whether the screen takes them is known only later)
			List<Pso> post = new ArrayList<>(List.of(Pso.fullScreen("shade_bloom_down0", ShadeRender.RGBA16F), Pso.fullScreen("shade_bloom_down", ShadeRender.RGBA16F),
				Pso.fullScreen("shade_bloom_up", ShadeRender.RGBA16F), Pso.fullScreen("shade_final", ShadeRender.RGBA8), Pso.fullScreen("shade_final_lean", ShadeRender.RGBA8),
				Pso.fullScreen("shade_upscale", ShadeRender.RGBA8)));
			if (mcopt.metal.shade.dims.DimsConfig.DIMS || mcopt.metal.shade.dims.DimsConfig.MEDIA) post.add(Pso.fullScreen("shade_final_dims", ShadeRender.RGBA8));
			post.addAll(List.of(Pso.fullScreen("shade_bridge_encode", ShadeRender.RGBA8), Pso.fullScreen("shade_bridge_decode", ShadeConfig.HDR_FORMAT),
				Pso.kernel("shade_histogram"), Pso.kernel("shade_exposure"), Pso.fullScreen("shade_milkyway_bake", ShadeRender.RGBA16F)));
			w.add(Map.entry("post chain", () -> warm(ctx, ShadeMsl.post(), post.toArray(Pso[]::new))));
		}
		if (mcopt.metal.shade.taa.TaaConfig.ENABLED) w.add(Map.entry("TAAU", () -> mcopt.metal.shade.taa.TaaConfig.warmUp(ctx)));
		if (Shade.SHADOWS) w.add(Map.entry("shadows", () -> mcopt.metal.shade.shadow.ShadowConfig.warmUp(ctx)));
		if (mcopt.metal.shade.light.DynLightConfig.ENABLED) {
			// DynLights.init (mc_dl_new: its kernels as ShadeRender.computePipeline makes them)
			w.add(Map.entry("dynamic lights", () -> warm(ctx, mcopt.metal.shade.light.DynLightConfig.source(), Pso.kernel("shade_dl_vis"), Pso.kernel("shade_dl_irr"),
				Pso.kernel("shade_dl_flood"), Pso.kernel("shade_dl_flood_out"))));
		}
		if (mcopt.metal.shade.vl.VlConfig.ENABLED) w.add(Map.entry("volumetric light", () -> mcopt.metal.shade.vl.VlConfig.warmUp(ctx, ShadeConfig.HDR)));
		if (mcopt.metal.shade.clouds.CloudConfig.ENABLED) w.add(Map.entry("clouds", () -> mcopt.metal.shade.clouds.CloudConfig.warmUp(ctx)));
		if (mcopt.metal.shade.water.ShadeWater.ON && (mcopt.metal.shade.water.ShadeWater.SSR || mcopt.metal.shade.water.ShadeWater.BAKE)) {
			// ShadeWater.ready (coarse depth) and bake (waves, ripples)
			List<Pso> water = new ArrayList<>();
			if (mcopt.metal.shade.water.ShadeWater.SSR && mcopt.metal.shade.water.ShadeWater.SSR_EXACT) {
				water.add(Pso.fullScreen("shade_water_pyr_fs", ShadeRender.RGBA32F));
				water.add(Pso.fullScreen("shade_water_pyr2_fs", ShadeRender.RGBA32F));
			} else if (mcopt.metal.shade.water.ShadeWater.SSR) water.add(Pso.fullScreen("shade_water_hz_fs", ShadeRender.R32F));
			if (mcopt.metal.shade.water.ShadeWater.BAKE) {
				water.add(Pso.fullScreen("shade_water_bake_fs", ShadeRender.RGBA16F));
				if (mcopt.metal.shade.water.ShadeWater.DETAIL) water.add(Pso.fullScreen("shade_water_bake_detail_fs", ShadeRender.RGBA16F));
			}
			w.add(Map.entry("water", () -> warm(ctx, mcopt.metal.shade.water.ShadeWater.librarySource(), water.toArray(Pso[]::new))));
		}
		if (ShadeConfig.HDR && mcopt.metal.shade.weather.ShadeWeather.ON && (mcopt.metal.shade.weather.ShadeWeather.PUDDLES || mcopt.metal.shade.weather.ShadeWeather.SNOW)) {
			// ShadeWeather.bakeNoise
			w.add(Map.entry("weather noise", () -> warm(ctx, mcopt.metal.shade.weather.ShadeWeather.noiseSource(), Pso.fullScreen("shade_wx_noise_fs", ShadeRender.RG16F))));
		}
		if (ShadeConfig.HDR && mcopt.metal.shade.dims.DimsConfig.AURORA != 0 && !"false".equals(System.getProperty("mcopt.shade.aurora.half"))) {
			// ShadeAurora.render (the first night with an aurora)
			w.add(Map.entry("aurora", () -> warm(ctx, mcopt.metal.shade.dims.ShadeAurora.source(), Pso.fullScreen("shade_aurora_pass", ShadeRender.RGBA16F))));
		}
		return w;
	}

	/** (dev tools: tools/shade/compilecheck) The warm-up's tasks for ctx by module, to run and time one at a time. */
	public static List<Map.Entry<String, Runnable>> warmUpTasks(long ctx) {
		return warmUps(ctx);
	}

	/** (dev tools) Whether the warm-up start() began has finished (true when it had nothing to do). */
	public static boolean warmUpDone() {
		return startNs != 0 && (warmDoneNs != 0 || WARM_LEFT.get() == 0);
	}

	private static void warmOne(String name, Runnable task) {
		long t0 = System.nanoTime();
		try {
			task.run();
		} catch (Throwable t) {
			WARM_FAILED.incrementAndGet();
			synchronized (warmFailures) {
				warmFailures.add(name + " (" + String.valueOf(t.getMessage()).lines().findFirst().orElse("") + ")");
			}
		}
		WARM_WORK_NS.addAndGet(System.nanoTime() - t0);
		if (WARM_LEFT.decrementAndGet() == 0) {
			warmDoneNs = System.nanoTime();
			String failed;
			synchronized (warmFailures) {
				failed = warmFailures.isEmpty() ? "" : "; failed (the module compiles at its start as before): " + String.join(", ", warmFailures);
			}
			System.out.println(String.format(Locale.ROOT, "[mcopt] shade shaders: warm-up of %d shade modules done %.2f s after start (work %.2f s)%s",
				warmTotal, (warmDoneNs - startNs) / 1e9, WARM_WORK_NS.get() / 1e9, failed));
		}
	}

	/**
	 * Compiles source as ShadeRender.library does (mc_shade_library: MSL 3.0, fast math) and builds pipelines from it as
	 * ShadeRender.pipeline / computePipeline do, then releases everything: Metal keeps the compiled code in its shader cache,
	 * where the module's own setup finds it. Throws on the first failure.
	 */
	public static void warm(long ctx, String source, Pso... pipelines) {
		long lib = library(ctx, source);
		try (MemoryStack stack = MemoryStack.stackPush()) {
			long err = stack.nmalloc(1, 4096);
			for (Pso p : pipelines) {
				MemoryUtil.memPutByte(err, (byte) 0);
				long fn = MemoryUtil.memAddress(stack.UTF8(p.function()));
				long pso = p.vertex() == null ? ShadeNative.cpso(ctx, lib, fn, err, 4096)
					: ShadeNative.pso(ctx, lib, MemoryUtil.memAddress(stack.UTF8(p.vertex())), fn, p.format(), p.blend(), err, 4096);
				if (pso == 0) throw new IllegalStateException(p.function() + ": " + MemoryUtil.memUTF8(err));
				MetalBridge.release(pso);
			}
		} finally {
			MetalBridge.release(lib);
		}
	}

	/** A library from source on ctx as ShadeRender.library compiles it (for warm-ups: release it with MetalBridge.release). */
	public static long library(long ctx, String source) {
		ByteBuffer src = MemoryUtil.memUTF8(source);
		try (MemoryStack stack = MemoryStack.stackPush()) {
			long err = stack.nmalloc(1, 4096);
			MemoryUtil.memPutByte(err, (byte) 0);
			long lib = ShadeNative.library(ctx, MemoryUtil.memAddress(src), err, 4096);
			if (lib == 0) throw new IllegalStateException("shade MSL: " + MemoryUtil.memUTF8(err));
			return lib;
		} finally {
			MemoryUtil.memFree(src);
		}
	}

	// ---- startup timings ----------------------------------------------------------------------------------------------

	/** Start of a module's shader setup, for {@link #setup}. */
	public static long now() {
		return System.nanoTime();
	}

	/** A module's shader setup (library and pipelines) took since t0: counted for the startup summary on the render thread. */
	public static void setup(String module, long t0) {
		long ns = System.nanoTime() - t0;
		if (!"Render thread".equals(Thread.currentThread().getName())) return;
		synchronized (setups) {
			long[] s = setups.computeIfAbsent(module, k -> new long[2]);
			s[0] += ns;
			s[1]++;
		}
	}

	/** ShadeBindings.init: the first world frame starts (what compiled until now is the startup's). */
	static synchronized void worldStart() {
		if (worldNs != 0) return;
		worldNs = System.nanoTime();
		beforeWorld = MetalBridge.compileStats();
	}

	/** Once per world frame (ShadeFrameUpdater.update): the summary after SUMMARY_FRAMES of them. */
	static void frame() {
		if (++frames != SUMMARY_FRAMES || beforeWorld == null) return;
		try {
			summary();
		} catch (Throwable t) {
			System.out.println("[mcopt] shade shaders: no summary: " + t);
		}
	}

	private static void summary() {
		Map<String, Object> b = beforeWorld, now = MetalBridge.compileStats();
		long first = (long) b.get("firstStartNs"), last = (long) b.get("lastEndNs");
		System.out.println(String.format(Locale.ROOT,
			"[mcopt] shade shaders: before the world: %d pipelines + %d variants compiled in %.2f s (first compile to last; %s; per pipeline, summed: SPIR-V to MSL %.2f s, libraries %.2f s, states and prewarm %.2f s)",
			(long) b.get("count"), (long) b.get("variants"), first == 0 ? 0 : (last - first) / 1e9,
			pool != null ? "parallel, " + threads + " threads" : "one after another", (double) b.get("translateMs") / 1e3, (double) b.get("libraryMs") / 1e3,
			(double) b.get("stateMs") / 1e3));
		StringBuilder s = new StringBuilder();
		long total = 0;
		synchronized (setups) {
			for (Map.Entry<String, long[]> e : setups.entrySet()) {
				total += e.getValue()[0];
				s.append(s.isEmpty() ? "" : ", ").append(e.getKey()).append(String.format(Locale.ROOT, " %.0f", e.getValue()[0] / 1e6));
			}
		}
		long rv = (long) now.get("renderThreadVariants") - (long) b.get("renderThreadVariants");
		double rvMs = (double) now.get("renderThreadVariantMs") - (double) b.get("renderThreadVariantMs");
		String slow = (String) now.get("slowRenderThreadVariants");
		String warm = warmTotal == 0 ? "no warm-up" : warmDoneNs == 0 ? "warm-up still running (" + (warmTotal - WARM_LEFT.get()) + " of " + warmTotal + " done)"
			: warmDoneNs <= worldNs ? String.format(Locale.ROOT, "warm-up done %.2f s before the world", (worldNs - warmDoneNs) / 1e9)
			: String.format(Locale.ROOT, "warm-up done %.2f s into the world", (warmDoneNs - worldNs) / 1e9);
		System.out.println(String.format(Locale.ROOT,
			"[mcopt] shade shaders: first %d world frames, render thread: shade setup %.2f s (ms: %s), variants built on first use %d in %.2f s%s; %s",
			SUMMARY_FRAMES, total / 1e9, s.isEmpty() ? "none" : s, rv, rvMs / 1e3, rv > 0 && !slow.isEmpty() ? " (slowest since launch: " + slow + ")" : "", warm));
	}
}
