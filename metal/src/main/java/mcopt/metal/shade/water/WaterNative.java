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
package mcopt.metal.shade.water;

import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemoryLayout;
import java.lang.invoke.MethodHandle;
import mcopt.metal.MetalBridge;

import static java.lang.foreign.ValueLayout.JAVA_INT;
import static java.lang.foreign.ValueLayout.JAVA_LONG;

/** Downcalls into native/mcwater.m (linked into libmcmetal; pointers cross as longs, like Native). */
final class WaterNative {
	private static final Linker LINKER = Linker.nativeLinker();
	private static final MethodHandle NEW = fn("mc_water_new", false, JAVA_LONG, JAVA_LONG);
	private static final MethodHandle PARAMS = fn("mc_water_params", true, null, JAVA_LONG, JAVA_LONG);
	private static final MethodHandle BIND = fn("mc_water_bind", true, null, JAVA_LONG);
	private static final MethodHandle CAPTURE = fn("mc_water_capture", false, JAVA_INT, JAVA_LONG, JAVA_LONG);
	private static final MethodHandle WAVES = fn("mc_water_waves", false, JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_INT);
	private static final MethodHandle WAVES_DETAIL = fn("mc_water_waves_detail", false, JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_INT);
	private static final MethodHandle SET_HZ = fn("mc_water_set_hz", false, null, JAVA_LONG, JAVA_LONG);
	private static final MethodHandle SET_PYR = fn("mc_water_set_pyr", false, null, JAVA_LONG, JAVA_LONG, JAVA_LONG);
	private static final MethodHandle WAVES_DONE = fn("mc_water_waves_done", false, null, JAVA_LONG, JAVA_LONG);

	private WaterNative() {
	}

	private static MethodHandle fn(String name, boolean critical, MemoryLayout result, MemoryLayout... args) {
		FunctionDescriptor d = result == null ? FunctionDescriptor.ofVoid(args) : FunctionDescriptor.of(result, args);
		var symbol = MetalBridge.library().find(name).orElseThrow(() -> new IllegalStateException("missing native symbol " + name));
		return critical ? LINKER.downcallHandle(symbol, d, Linker.Option.critical(false)) : LINKER.downcallHandle(symbol, d);
	}

	private static RuntimeException rethrow(Throwable t) {
		if (t instanceof RuntimeException r) return r;
		if (t instanceof Error e) throw e;
		return new IllegalStateException(t);
	}

	static long create(long ctx) { try { return (long) NEW.invokeExact(ctx); } catch (Throwable t) { throw rethrow(t); } }
	/** params: the address of 36 floats (still, flow, state, tune, swell, swell2, swell3, rhist, mirror: water.metal ShadeWaterParams). */
	static void params(long state, long params) { try { PARAMS.invokeExact(state, params); } catch (Throwable t) { throw rethrow(t); } }
	static void bind(long enc) { try { BIND.invokeExact(enc); } catch (Throwable t) { throw rethrow(t); } }
	static int capture(long enc, long state) { try { return (int) CAPTURE.invokeExact(enc, state); } catch (Throwable t) { throw rethrow(t); } }
	static long waves(long ctx, long state, int size) { try { return (long) WAVES.invokeExact(ctx, state, size); } catch (Throwable t) { throw rethrow(t); } }
	static long wavesDetail(long ctx, long state, int size) { try { return (long) WAVES_DETAIL.invokeExact(ctx, state, size); } catch (Throwable t) { throw rethrow(t); } }
	static void setHz(long state, long pso) { try { SET_HZ.invokeExact(state, pso); } catch (Throwable t) { throw rethrow(t); } }
	static void setPyr(long state, long pso, long pso2) { try { SET_PYR.invokeExact(state, pso, pso2); } catch (Throwable t) { throw rethrow(t); } }
	static void wavesDone(long enc, long state) { try { WAVES_DONE.invokeExact(enc, state); } catch (Throwable t) { throw rethrow(t); } }
}
