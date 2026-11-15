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
package mcopt.metal.shade.light;

import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemoryLayout;
import java.lang.invoke.MethodHandle;
import mcopt.metal.MetalBridge;

import static java.lang.foreign.ValueLayout.JAVA_INT;
import static java.lang.foreign.ValueLayout.JAVA_LONG;

/** Downcalls into native/mcdynlight.m (pointers cross as longs). */
final class DynLightNative {
	private static final Linker LINKER = Linker.nativeLinker();
	private static final MethodHandle NEW = fn("mc_dl_new", JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_LONG, JAVA_INT);
	private static final MethodHandle IRR = fn("mc_dl_irr", null, JAVA_LONG, JAVA_LONG, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT);
	private static final MethodHandle CONTENTS = fn("mc_dl_contents", JAVA_LONG, JAVA_LONG, JAVA_INT);
	private static final MethodHandle SLOT = fn("mc_dl_slot", null, JAVA_LONG, JAVA_INT);
	private static final MethodHandle BIND = fn("mc_dl_bind", null, JAVA_LONG);
	private static final MethodHandle VIS = fn("mc_dl_vis", null, JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_INT, JAVA_INT);
	private static final MethodHandle OCCUPANCY = fn("mc_dl_occupancy", null, JAVA_LONG, JAVA_LONG);
	private static final MethodHandle FALLBACK = fn("mc_dl_fallback", JAVA_INT, JAVA_LONG, JAVA_INT);
	private static final MethodHandle HAS_FLOOD = fn("mc_dl_has_flood", JAVA_INT, JAVA_LONG);
	// (1.2.8) the coloured light volume (mcdynlight.m mc_cl_*, ColorLights)
	private static final MethodHandle CL_NEW = fn("mc_cl_new", JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT,
		JAVA_LONG, JAVA_INT, JAVA_INT, JAVA_LONG, JAVA_INT);
	private static final MethodHandle CL_FALLBACK = fn("mc_cl_fallback", JAVA_INT, JAVA_LONG);
	private static final MethodHandle CL_IDS = fn("mc_cl_ids", JAVA_LONG, JAVA_LONG);
	private static final MethodHandle CL_LIST = fn("mc_cl_list", JAVA_LONG, JAVA_LONG, JAVA_INT);
	private static final MethodHandle CL_HEADER = fn("mc_cl_header", null, JAVA_LONG, JAVA_LONG);
	private static final MethodHandle CL_FRAME = fn("mc_cl_frame", null, JAVA_LONG, JAVA_LONG, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT);

	private DynLightNative() {
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

	static long create(long ctx, long source, int bytes, int ring, int slabs, int occBytes, int irrW, int irrH, int irrD, long err, int errCap) {
		try {
			return (long) NEW.invokeExact(ctx, source, bytes, ring, slabs, occBytes, irrW, irrH, irrD, err, errCap);
		} catch (Throwable t) {
			throw rethrow(t);
		}
	}

	/** The CPU's block occupancy (Occupancy.BYTES at address) into the next occupancy slot, read by the next mc_dl_vis. */
	static void occupancy(long state, long address) {
		try {
			OCCUPANCY.invokeExact(state, address);
		} catch (Throwable t) {
			throw rethrow(t);
		}
	}

	static long clCreate(long ctx, long source, int fw, int fh, int fd, int cw, int ch, int cd, long cells, int listCap, int ring, long err, int errCap) {
		try {
			return (long) CL_NEW.invokeExact(ctx, source, fw, fh, fd, cw, ch, cd, cells, listCap, ring, err, errCap);
		} catch (Throwable t) {
			throw rethrow(t);
		}
	}

	static boolean clFallback(long ctx) {
		try {
			return (int) CL_FALLBACK.invokeExact(ctx) != 0;
		} catch (Throwable t) {
			throw rethrow(t);
		}
	}

	static long clIds(long state) {
		try {
			return (long) CL_IDS.invokeExact(state);
		} catch (Throwable t) {
			throw rethrow(t);
		}
	}

	static long clList(long state, int slot) {
		try {
			return (long) CL_LIST.invokeExact(state, slot);
		} catch (Throwable t) {
			throw rethrow(t);
		}
	}

	static void clHeader(long state, long bytes) {
		try {
			CL_HEADER.invokeExact(state, bytes);
		} catch (Throwable t) {
			throw rethrow(t);
		}
	}

	static void clFrame(long enc, long state, int slot, int clears, int fine, int coarse, int fineSteps) {
		try {
			CL_FRAME.invokeExact(enc, state, slot, clears, fine, coarse, fineSteps);
		} catch (Throwable t) {
			throw rethrow(t);
		}
	}

	/** Zeroed fallback bindings for the module's slots (after a failed start); false when even those failed. */
	static boolean fallback(long ctx, int bytes) {
		try {
			return (int) FALLBACK.invokeExact(ctx, bytes) != 0;
		} catch (Throwable t) {
			throw rethrow(t);
		}
	}

	/** Ring slot i's CPU address. */
	static long contents(long state, int i) {
		try {
			return (long) CONTENTS.invokeExact(state, i);
		} catch (Throwable t) {
			throw rethrow(t);
		}
	}

	static void slot(long state, int slot) {
		try {
			SLOT.invokeExact(state, slot);
		} catch (Throwable t) {
			throw rethrow(t);
		}
	}

	static void bind(long enc) {
		try {
			BIND.invokeExact(enc);
		} catch (Throwable t) {
			throw rethrow(t);
		}
	}

	static void irr(long enc, long state, int x0, int y0, int z0, int w, int h, int d) {
		try {
			IRR.invokeExact(enc, state, x0, y0, z0, w, h, d);
		} catch (Throwable t) {
			throw rethrow(t);
		}
	}

	/** (FT2.11) Whether the flood fill's pipeline exists (else DlVisParams.info.y = 1 falls back to rays). */
	static boolean hasFlood(long state) {
		try {
			return (int) HAS_FLOOD.invokeExact(state) != 0;
		} catch (Throwable t) {
			throw rethrow(t);
		}
	}

	static void vis(long enc, long state, long params, int length, int volumes) {
		try {
			VIS.invokeExact(enc, state, params, length, volumes);
		} catch (Throwable t) {
			throw rethrow(t);
		}
	}
}
