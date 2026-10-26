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
package mcopt.metal.shade.terrain;

import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.invoke.MethodHandle;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import mcopt.metal.MetalBridge;
import mcopt.metal.shade.Shade;
import mcopt.metal.shade.ShadeConfig;
import mcopt.metal.shade.ShadeLean;
import mcopt.metal.shade.ShadeMsl;
import mcopt.metal.shade.ShadeRender;
import mcopt.metal.shade.taa.ShadeTaa;

import static java.lang.foreign.ValueLayout.JAVA_INT;
import static java.lang.foreign.ValueLayout.JAVA_LONG;

/**
 * mcopt 0.3 port (v12): native shading on mcopt's own near-terrain renderer (mcopt.metal.own), which draws the world's
 * terrain itself since mcopt 0.3 (no Sodium). The hooks it calls, each one line in upstream's code behind {@link #ON}:
 * <ul>
 * <li>{@link #prefix} (OwnTerrain's constructor): what goes in front of own/terrain.metal (ShadeMsl.ownPrefix). With
 * MCOPT_SHADE its vertex stage passes the camera-relative position and the block / sky light and leaves the lightmap out, and
 * its fragment stages bind the game's uniforms above the shade globals' slots (P1, P2).</li>
 * <li>{@link #created} (right after the library is built): tells mcown.m so (mco_shade), and starts building the shaded
 * fragment stage's libraries (below) in the background.</li>
 * <li>{@link #frame} (ShadeFrameUpdater, every frame, after ShadeLean picked this frame's lean variant): hands mcown.m this
 * frame's libraries with terrain_own.metal's shade_own_fs (mco_shade_fs), one for the opaque layers and one for the
 * translucent one; own's solid, cutout and translucent draws take that stage (P2: the lighting; P3: water, glossy
 * translucents).</li>
 * <li>{@link #beforeTranslucent} (OwnTerrain.drawTranslucent): the water module's scene copy, which Sodium's terrain used to
 * trigger by switching to its translucent pipeline (MetalRenderPass.captureWater).</li>
 * <li>{@link #noUocc} (OwnFrag's per-frame configuration): with -Dmcopt.shade.ownUoccGate, its two-phase occlusion off while TAAU
 * draws the world into a smaller live sub-rect of its targets (P2's gate; since P5 the test follows the sub-rect).</li>
 * </ul>
 * The shaded stage is a library of its own per variant, built from source like the Sodium terrain's variants were (the lean
 * variants are #ifdefs throughout the modules, the water's tuned by register pressure): 12 opaque and up to 24 translucent
 * ones (ShadeLean's sets), built on a background thread from the start; a frame that needs one not built yet waits for it
 * (or builds it). A variant that fails falls back to the full one (lean bits 0), and that to own's own stages (vanilla's
 * look in the HDR frame, P1), logged once.
 */
public final class ShadeTerrain {
	/** The gate for every hook: a static final, so with shading off the hooks are dead code. */
	public static final boolean ON = Shade.ENABLED;
	/**
	 * The terrain fragment stage lights faces itself, so meshing leaves vanilla's directional face shade out (ShadeFaceShadeMixin,
	 * applied only then).
	 */
	public static final boolean LIT = true;
	private static final int TRANSLUCENT = 1 << 16;
	/** Library handle per variant (TRANSLUCENT | lean bits); 0 = it failed. */
	private static final Map<Integer, CompletableFuture<Long>> LIBRARIES = new ConcurrentHashMap<>();
	private static final ExecutorService COMPILER = Executors.newSingleThreadExecutor(r -> {
		Thread t = new Thread(r, "mcopt-shade terrain compile");
		t.setDaemon(true);
		t.setPriority(Thread.MIN_PRIORITY);
		return t;
	});
	private static long own;
	private static MethodHandle shadeFs, shadeBuilt, shadePrewarm;
	/**
	 * -Dmcopt.shade.terrain.prewarmPipelines (true): the pipelines of the layouts own has drawn with so far are built for every
	 * other stage variant on the compile thread (mcown.m mco_shade_prewarm; at the world's 300th and 3000th frame, after the
	 * libraries), so a variant met later finds them in Metal's cache instead of building them in the frame that needs it.
	 */
	private static final boolean PREWARM_PIPELINES = !"false".equals(System.getProperty("mcopt.shade.terrain.prewarmPipelines"));
	private static long frames;
	private static double builtSeen;
	private static boolean said, failedSaid, prewarmed;

	private ShadeTerrain() {
	}

	/** The native Own* of mcopt's own terrain once created (the shadow pass builds its pipelines from its library), else 0. */
	public static long ownHandle() {
		return own;
	}

	/** What goes in front of own/terrain.metal when shading is on. */
	public static String prefix() {
		return ShadeMsl.ownPrefix();
	}

	/** OwnTerrain's constructor, right after OwnNative.create built the library with {@link #prefix} (own: the native Own*). */
	public static void created(long own) {
		try {
			Linker linker = Linker.nativeLinker();
			MethodHandle shade = linker.downcallHandle(native_("mco_shade"), FunctionDescriptor.ofVoid(JAVA_LONG, JAVA_INT));
			shade.invokeExact(own, 1);
			shadeFs = linker.downcallHandle(native_("mco_shade_fs"), FunctionDescriptor.ofVoid(JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_INT, JAVA_INT));
			shadeBuilt = linker.downcallHandle(native_("mco_shade_built"), FunctionDescriptor.ofVoid(JAVA_LONG, JAVA_LONG));
			shadePrewarm = linker.downcallHandle(native_("mco_shade_prewarm"), FunctionDescriptor.of(JAVA_INT, JAVA_LONG, JAVA_LONG, JAVA_INT, JAVA_INT));
		} catch (Throwable t) {
			throw new IllegalStateException("mcopt-shade: own terrain's shade slots", t);
		}
		ShadeTerrain.own = own;
		prewarm();
	}

	private static java.lang.foreign.MemorySegment native_(String name) {
		return MetalBridge.library().find(name).orElseThrow(() -> new IllegalStateException("missing native symbol " + name));
	}

	/**
	 * Every frame, after ShadeLean.update: this frame's shaded fragment stage for own's draws (the lean variant's libraries, built
	 * now if the background thread hasn't got to them yet).
	 */
	public static void frame() {
		if (own == 0 || shadeFs == null) return;
		if (!prewarmed) prewarm();
		int tag = ShadeLean.tag();
		int pbr = mcopt.metal.shade.ShadePbr.active() ? ShadeMsl.PBR_MATERIALS : 0;
		int opaqueBits = (tag & ShadeMsl.LEAN_TERRAIN) | pbr, translucentBits = (tag & (ShadeMsl.LEAN_TERRAIN | ShadeMsl.LEAN_WATER)) | pbr;
		long opaque = library(false, opaqueBits), translucent = library(true, translucentBits);
		if (opaque == 0 && opaqueBits != 0) opaque = library(false, opaqueBits = 0); // (the variant failed: the full stage)
		if (translucent == 0 && translucentBits != 0) translucent = library(true, translucentBits = 0);
		int key = (opaqueBits & 255) | (translucentBits & 255) << 8 | (opaque != 0 ? 1 << 16 : 0)
			| (translucent != 0 ? 1 << 17 : 0) | (pbr != 0 ? 1 << 18 : 0);
		try {
			shadeFs.invokeExact(own, opaque, translucent, key, ShadeConfig.HDR ? 1 : 0);
		} catch (Throwable t) {
			throw new IllegalStateException(t);
		}
		logBuilt(key);
		frames++;
		if (PREWARM_PIPELINES && (frames == 30 || frames == 1200)) prewarmPipelines();
		if (!said && opaque != 0) {
			said = true;
			System.out.println("[mcopt] shade: mcopt's own terrain lit per pixel (" + LIBRARIES.size() + " stage variants building or built)");
		}
	}

	private static final long BUILT = org.lwjgl.system.MemoryUtil.nmemAlloc(16);
	private static long builtLogAt;

	/**
	 * The shaded pipelines own built on the render thread since the last line (a lean variant met for the first time: the
	 * frame that needs it waits for them), logged at most every 2 s.
	 */
	private static void logBuilt(int key) {
		try {
			shadeBuilt.invokeExact(own, BUILT);
		} catch (Throwable t) {
			return;
		}
		double n = org.lwjgl.system.MemoryUtil.memGetDouble(BUILT), ms = org.lwjgl.system.MemoryUtil.memGetDouble(BUILT + 8);
		long now = System.nanoTime();
		if (n > builtSeen && now - builtLogAt > 2_000_000_000L) {
			System.out.println(String.format("[mcopt] shade: own terrain pipelines built on the render thread: %.0f so far, %.0f ms in all (stage key %x)", n, ms, key));
			builtSeen = n;
			builtLogAt = now;
		}
	}

	/** Variant (translucent, bits)'s library handle, built now if nobody has started it; 0 if it failed. */
	private static long library(boolean translucent, int bits) {
		int key = (translucent ? TRANSLUCENT : 0) | bits;
		CompletableFuture<Long> f = LIBRARIES.get(key);
		if (f == null) {
			CompletableFuture<Long> mine = new CompletableFuture<>();
			f = LIBRARIES.putIfAbsent(key, mine);
			if (f == null) {
				mine.complete(compile(translucent, bits));
				f = mine;
			}
		}
		return f.join();
	}

	private static long compile(boolean translucent, int bits) {
		long t0 = System.nanoTime();
		try {
			long lib = ShadeRender.library(ShadeMsl.ownFragmentSource(translucent, bits));
			if (Boolean.getBoolean("mcopt.shade.terrain.log")) {
				System.out.println(String.format("[mcopt] shade: own terrain stage %s lean %d built in %.0f ms", translucent ? "translucent" : "opaque", bits,
					(System.nanoTime() - t0) / 1e6));
			}
			return lib;
		} catch (RuntimeException e) {
			if (!failedSaid) {
				failedSaid = true;
				System.out.println("[mcopt] shade: own terrain's shaded stage (" + (translucent ? "translucent" : "opaque") + ", lean " + bits
					+ ") failed to build, " + (bits != 0 ? "using the full stage" : "vanilla's look") + ": "
					+ String.valueOf(e.getMessage()).lines().limit(8).reduce((a, b) -> a + " | " + b).orElse(""));
			}
			return 0;
		}
	}

	/**
	 * The variants ShadeLean can ask for, built in the background (as the Sodium terrain's were prewarmed on the compile worker
	 * up to 1.1, ShadeMsl.prewarm): this frame's first, then the overworld's eight and the Nether's four (opaque, translucent),
	 * then the translucent layer's water variants (above water, no moving water near, the leanDev ones).
	 */
	private static void prewarm() {
		if (!ShadeRender.ready()) return; // (frame() tries again: no device to build with yet)
		prewarmed = true;
		int tag = ShadeLean.tag();
		List<int[]> sets = new ArrayList<>();
		sets.add(new int[] {0, tag & ShadeMsl.LEAN_TERRAIN});
		sets.add(new int[] {1, tag & (ShadeMsl.LEAN_TERRAIN | ShadeMsl.LEAN_WATER)});
		if (ShadeLean.ON) {
			for (int t = 7; t >= 0; t--) sets.add(new int[] {0, t});
			for (int t = 0; t < 4; t++) sets.add(new int[] {0, ShadeMsl.LEAN_NETHER | t << 1});
			for (int t = 7; t >= 0; t--) sets.add(new int[] {1, t});
			for (int t = 0; t < 4; t++) sets.add(new int[] {1, ShadeMsl.LEAN_NETHER | t << 1});
			boolean dev = !ShadeLean.DEV_DEFINES.isEmpty();
			for (int t = 0; t < 4; t++) {
				int b = ShadeMsl.LEAN_OW | t << 1;
				sets.add(new int[] {1, b | ShadeMsl.LEAN_ABOVE | ShadeMsl.LEAN_NOFALLS});
				sets.add(new int[] {1, b | ShadeMsl.LEAN_ABOVE});
				sets.add(new int[] {1, b | ShadeMsl.LEAN_NOFALLS});
				if (dev) {
					sets.add(new int[] {1, b | ShadeMsl.LEAN_ABOVE | ShadeMsl.LEAN_DEV});
					sets.add(new int[] {1, b | ShadeMsl.LEAN_ABOVE | ShadeMsl.LEAN_DEV | ShadeMsl.LEAN_NOFALLS});
				}
			}
		} else {
			sets.add(new int[] {0, 0});
			sets.add(new int[] {1, 0});
		}
		for (int[] v : sets) {
			boolean translucent = v[0] == 1;
			int key = (translucent ? TRANSLUCENT : 0) | v[1];
			CompletableFuture<Long> mine = new CompletableFuture<>();
			if (LIBRARIES.putIfAbsent(key, mine) != null) continue;
			Runnable task = () -> mine.complete(compile(translucent, v[1]));
			if (!mcopt.metal.shade.ShadeCompile.background(task)) COMPILER.execute(task); // (v12: on the shader pool when there is one)
		}
	}

	private static final java.util.concurrent.atomic.AtomicInteger PREWARM_LEFT = new java.util.concurrent.atomic.AtomicInteger(),
		PREWARM_BUILT = new java.util.concurrent.atomic.AtomicInteger();
	private static volatile long prewarmT0;

	/**
	 * Every stage variant's pipelines for the layouts met so far, built in the background as each variant's library is ready
	 * (on the shader pool, else the compile thread), then logged once.
	 */
	private static void prewarmPipelines() {
		if (PREWARM_LEFT.get() > 0) return; // (the last round is still going)
		prewarmT0 = System.nanoTime();
		PREWARM_BUILT.set(0);
		List<Map.Entry<Integer, CompletableFuture<Long>>> all = new ArrayList<>(LIBRARIES.entrySet());
		PREWARM_LEFT.set(all.size());
		long round = frames;
		for (Map.Entry<Integer, CompletableFuture<Long>> e : all) {
			boolean translucent = (e.getKey() & TRANSLUCENT) != 0;
			e.getValue().whenComplete((lib, ex) -> {
				Runnable task = () -> {
					try {
						if (lib != null && lib != 0) PREWARM_BUILT.addAndGet((int) shadePrewarm.invokeExact(own, (long) lib, translucent ? 1 : 0, ShadeConfig.HDR ? 1 : 0));
					} catch (Throwable t) {
						System.out.println("[mcopt] shade: own terrain pipeline prewarm failed: " + t);
					}
					if (PREWARM_LEFT.decrementAndGet() == 0) {
						System.out.println(String.format("[mcopt] shade: own terrain pipelines prewarmed in the background: %d for %d stage variants in %.1f s (from frame %d)",
							PREWARM_BUILT.get(), all.size(), (System.nanoTime() - prewarmT0) / 1e9, round));
					}
				};
				if (!mcopt.metal.shade.ShadeCompile.background(task)) COMPILER.execute(task);
			});
		}
	}

	/** OwnTerrain.drawTranslucent, before its first draw: the water module's scene copy (once per pass). */
	public static void beforeTranslucent(Object encoder) {
		MetalBridge.captureWater(encoder);
	}

	/** -Dmcopt.shade.ownUoccGate=true: the P2 gate (uocc off while TAAU's sub-rect is smaller than its textures), for A/B. */
	private static final boolean UOCC_GATE = Boolean.getBoolean("mcopt.shade.ownUoccGate");

	/**
	 * OwnFrag's configuration this frame: true to draw it without the two-phase unit occlusion (uocc), while TAAU's world target
	 * stands in for the main target with a live sub-rect smaller than its textures. Off by default since P5: the tests map units
	 * onto the live sub-rect (mcown.m ownShadeSubRect), so uocc runs under TAAU and dynamic resolution too.
	 */
	public static boolean noUocc() {
		if (!UOCC_GATE || !ShadeTaa.ON) return false;
		ShadeTaa t = ShadeTaa.current();
		return t != null && t.swapped() && (t.width(Integer.MAX_VALUE) < t.allocWidth() || t.height(Integer.MAX_VALUE) < t.allocHeight());
	}
}
