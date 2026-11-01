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

import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemoryLayout;
import java.lang.invoke.MethodHandle;
import mcopt.metal.MetalBridge;

import static java.lang.foreign.ValueLayout.JAVA_FLOAT;
import static java.lang.foreign.ValueLayout.JAVA_INT;
import static java.lang.foreign.ValueLayout.JAVA_LONG;

/** Downcalls into native/mcclouds.m (pointers cross as longs). */
final class CloudNative {
	private static final Linker LINKER = Linker.nativeLinker();
	private static final MethodHandle NEW = fn("mc_clouds_new", JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_INT);
	private static final MethodHandle SIZE = fn("mc_clouds_size", JAVA_INT, JAVA_LONG, JAVA_LONG, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT);
	private static final MethodHandle RENDER = fn("mc_clouds_render", null, JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_INT, JAVA_INT);
	private static final MethodHandle OUTPUTS = fn("mc_clouds_outputs", JAVA_INT, JAVA_LONG, JAVA_LONG);
	private static final MethodHandle TIMES = fn("mc_clouds_times", null, JAVA_LONG, JAVA_LONG);
	private static final MethodHandle FREE = fn("mc_clouds_free", null, JAVA_LONG);
	private static final MethodHandle VANILLA = fn("mc_clouds_vanilla", JAVA_INT, JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_INT, JAVA_INT);
	private static final MethodHandle OVER = fn("mc_clouds_over", null, JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_INT, JAVA_INT, JAVA_INT);
	private static final MethodHandle WARM = fn("mc_clouds_warm", JAVA_INT, JAVA_LONG, JAVA_LONG);
	// (v12-opt) the specialized march and resolves (clouds.metal CLOUD_FC_*)
	private static final MethodHandle LEAN = fn("mc_clouds_lean", JAVA_INT, JAVA_LONG, JAVA_LONG, JAVA_INT, JAVA_INT, JAVA_FLOAT);
	private static final MethodHandle WARM_LEAN = fn("mc_clouds_warm_lean", JAVA_INT, JAVA_LONG, JAVA_LONG, JAVA_INT, JAVA_INT, JAVA_FLOAT);

	private CloudNative() {
	}

	private static MethodHandle fn(String name, MemoryLayout ret, MemoryLayout... args) {
		var symbol = MetalBridge.library().find(name).orElseThrow(() -> new IllegalStateException("libmcmetal has no " + name));
		return LINKER.downcallHandle(symbol, ret == null ? FunctionDescriptor.ofVoid(args) : FunctionDescriptor.of(ret, args));
	}

	private static RuntimeException rethrow(Throwable t) {
		if (t instanceof RuntimeException r) return r;
		if (t instanceof Error e) throw e;
		return new IllegalStateException(t);
	}

	/** (parallel compile) mc_clouds_new's pipelines from lib, built and released: how many failed. */
	static int warm(long ctx, long lib) {
		try {
			return (int) WARM.invokeExact(ctx, lib);
		} catch (Throwable t) {
			throw rethrow(t);
		}
	}

	/** (v12-opt) The march and resolves specialized for dev bits, mode bits and style (art.w): 1 when built. */
	static int lean(long state, long ctx, int dev, int mode, float style) {
		try {
			return (int) LEAN.invokeExact(state, ctx, dev, mode, style);
		} catch (Throwable t) {
			throw rethrow(t);
		}
	}

	/** (v12-opt, parallel compile) lean()'s pipelines from lib, built and released: how many failed. */
	static int warmLean(long ctx, long lib, int dev, int mode, float style) {
		try {
			return (int) WARM_LEAN.invokeExact(ctx, lib, dev, mode, style);
		} catch (Throwable t) {
			throw rethrow(t);
		}
	}

	static long create(long ctx, long source, long err, int errCap) {
		try {
			return (long) NEW.invokeExact(ctx, source, err, errCap);
		} catch (Throwable t) {
			throw rethrow(t);
		}
	}

	static int size(long state, long ctx, int hw, int hh, int mw, int mh, int dw, int dh) {
		try {
			return (int) SIZE.invokeExact(state, ctx, hw, hh, mw, mh, dw, dh);
		} catch (Throwable t) {
			throw rethrow(t);
		}
	}

	/** (1.1) The game's cloud texture as a w x h byte mask (255 = cloud) at address mask; 1 when made. */
	static int vanilla(long state, long ctx, long mask, int w, int h) {
		try {
			return (int) VANILLA.invokeExact(state, ctx, mask, w, h);
		} catch (Throwable t) {
			throw rethrow(t);
		}
	}

	/**
	 * flags: 1 shadow map, 2 screen (march + resolve), 4 dome, 8 GPU timer, 16 the M3.3 resolve (cloud_resolve_st, R16Uint data),
	 * 32 (1.1) the vanilla cloud mask in place of the weather map, 64 (v12-opt) the specialized march and resolves where they apply.
	 */
	static void render(long enc, long state, long params, int bytes, int flags) {
		try {
			RENDER.invokeExact(enc, state, params, bytes, flags);
		} catch (Throwable t) {
			throw rethrow(t);
		}
	}

	/** out: shadow, dome, screen, march distance and stable history data; returns 1 for stable history. */
	static int outputs(long state, long out) {
		try {
			return (int) OUTPUTS.invokeExact(state, out);
		} catch (Throwable t) {
			throw rethrow(t);
		}
	}

	/** out: 5 floats: GPU ms of shadow, march, resolve, dome; frames averaged. */
	static void times(long state, long out) {
		try {
			TIMES.invokeExact(state, out);
		} catch (Throwable t) {
			throw rethrow(t);
		}
	}

	/** Clouds in front of the world: into scene (live sub-rect liveW x liveH) where depth lies behind them. */
	static void over(long enc, long state, long scene, long depth, int liveW, int liveH, int mode) {
		try {
			OVER.invokeExact(enc, state, scene, depth, liveW, liveH, mode);
		} catch (Throwable t) {
			throw rethrow(t);
		}
	}

	static void free(long state) {
		try {
			FREE.invokeExact(state);
		} catch (Throwable t) {
			throw rethrow(t);
		}
	}
}
