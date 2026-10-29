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

import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemoryLayout;
import java.lang.invoke.MethodHandle;
import mcopt.metal.MetalBridge;

import static java.lang.foreign.ValueLayout.JAVA_INT;
import static java.lang.foreign.ValueLayout.JAVA_LONG;

/** Downcalls into native/mcshade.m (linked into libmcmetal with the backend; pointers cross as longs, like Native). */
final class ShadeNative {
	private static final Linker LINKER = Linker.nativeLinker();
	private static final MethodHandle NEW = fn("mc_shade_new", false, JAVA_LONG, JAVA_LONG);
	private static final MethodHandle DUMMY_SHADOW = fn("mc_shade_dummy_shadow", true, JAVA_LONG, JAVA_LONG);
	private static final MethodHandle COMPARE_SAMPLER = fn("mc_shade_compare_sampler", true, JAVA_LONG, JAVA_LONG);
	private static final MethodHandle SET = fn("mc_shade_set", true, null, JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_LONG);
	private static final MethodHandle BIND = fn("mc_shade_bind", true, null, JAVA_LONG);
	private static final MethodHandle REOPEN_HOOK = fn("mc_shade_reopen_hook", true, null, JAVA_INT); // mcopt 0.3 port
	private static final MethodHandle LUT_INIT = fn("mc_shade_lut_init", false, JAVA_INT, JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_INT, JAVA_INT, JAVA_LONG, JAVA_INT);
	private static final MethodHandle LUT_RENDER = fn("mc_shade_lut_render", false, null, JAVA_LONG, JAVA_LONG);
	private static final MethodHandle LUT_TEXTURE = fn("mc_shade_lut_texture", true, JAVA_LONG, JAVA_LONG);
	// M2
	private static final MethodHandle SET_M2 = fn("mc_shade_set_m2", true, null, JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_LONG);
	private static final MethodHandle RESOURCE = fn("mc_shade_resource", true, null, JAVA_INT, JAVA_LONG);
	private static final MethodHandle RESOURCES_ADVANCE = fn("mc_shade_resources_advance", true, null, JAVA_INT);
	private static final MethodHandle LIBRARY = fn("mc_shade_library", false, JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_INT);
	private static final MethodHandle PSO = fn("mc_shade_pso", false, JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_INT, JAVA_INT, JAVA_LONG, JAVA_INT);
	private static final MethodHandle CPSO = fn("mc_shade_cpso", false, JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_INT);
	private static final MethodHandle TEXTURE = fn("mc_shade_texture", false, JAVA_LONG, JAVA_LONG, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_LONG);
	private static final MethodHandle BUFFER = fn("mc_shade_buffer", false, JAVA_LONG, JAVA_LONG, JAVA_LONG);
	private static final MethodHandle PASS = fn("mc_shade_pass", false, null, JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_INT, JAVA_LONG, JAVA_INT, JAVA_LONG, JAVA_INT, JAVA_LONG, JAVA_INT);
	private static final MethodHandle DISPATCH = fn("mc_shade_dispatch", false, null, JAVA_LONG, JAVA_LONG, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_LONG, JAVA_INT, JAVA_LONG, JAVA_INT, JAVA_LONG);
	private static final MethodHandle BAKE = fn("mc_shade_bake", false, null, JAVA_LONG, JAVA_LONG, JAVA_LONG);
	private static final MethodHandle TEX_W = fn("mc_shade_texture_width", true, JAVA_INT, JAVA_LONG);
	private static final MethodHandle TEX_H = fn("mc_shade_texture_height", true, JAVA_INT, JAVA_LONG);
	private static final MethodHandle TEX_FORMAT = fn("mc_shade_texture_format", true, JAVA_INT, JAVA_LONG);
	// parallel compile (native/mccompile.m, ShadeCompile)
	private static final MethodHandle COMPILE_SETUP = fn("mc_compile_setup", false, JAVA_INT, JAVA_LONG, JAVA_INT);
	private static final MethodHandle COMPILE_THREAD_QOS = fn("mc_compile_thread_qos", false, JAVA_INT, JAVA_INT);
	// (1.2.6, PBR) CPU-filled RGBA8 textures with mips (ShadePbr)
	private static final MethodHandle TEX_CPU = fn("mc_shade_texture_cpu", false, JAVA_LONG, JAVA_LONG, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_LONG);
	private static final MethodHandle TEX_UPLOAD = fn("mc_shade_texture_upload", false, null, JAVA_LONG, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_LONG, JAVA_INT);
	private static final MethodHandle TEX_RELEASE = fn("mc_shade_texture_release", false, null, JAVA_LONG);

	private ShadeNative() {
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
	static long dummyShadow(long state) { try { return (long) DUMMY_SHADOW.invokeExact(state); } catch (Throwable t) { throw rethrow(t); } }
	static long compareSampler(long state) { try { return (long) COMPARE_SAMPLER.invokeExact(state); } catch (Throwable t) { throw rethrow(t); } }
	static void set(long frame, long offset, long shadow, long sampler) { try { SET.invokeExact(frame, offset, shadow, sampler); } catch (Throwable t) { throw rethrow(t); } }
	static void bind(long enc) { try { BIND.invokeExact(enc); } catch (Throwable t) { throw rethrow(t); } }
	static void reopenHook(boolean on) { try { REOPEN_HOOK.invokeExact(on ? 1 : 0); } catch (Throwable t) { throw rethrow(t); } }
	static int lutInit(long state, long ctx, long source, int width, int height, long err, int errCap) { try { return (int) LUT_INIT.invokeExact(state, ctx, source, width, height, err, errCap); } catch (Throwable t) { throw rethrow(t); } }
	static long lutTexture(long state) { try { return (long) LUT_TEXTURE.invokeExact(state); } catch (Throwable t) { throw rethrow(t); } }
	static void lutRender(long enc, long state) { try { LUT_RENDER.invokeExact(enc, state); } catch (Throwable t) { throw rethrow(t); } }
	static void setM2(long ctx, long look, long lookOffset, long gpu) { try { SET_M2.invokeExact(ctx, look, lookOffset, gpu); } catch (Throwable t) { throw rethrow(t); } }
	static void resource(int index, long texture) { try { RESOURCE.invokeExact(index, texture); } catch (Throwable t) { throw rethrow(t); } }
	static void resourcesAdvance(int ring) { try { RESOURCES_ADVANCE.invokeExact(ring); } catch (Throwable t) { throw rethrow(t); } }
	static long library(long ctx, long source, long err, int errCap) { try { return (long) LIBRARY.invokeExact(ctx, source, err, errCap); } catch (Throwable t) { throw rethrow(t); } }
	static long pso(long ctx, long lib, long vs, long fs, int format, int blend, long err, int errCap) { try { return (long) PSO.invokeExact(ctx, lib, vs, fs, format, blend, err, errCap); } catch (Throwable t) { throw rethrow(t); } }
	static long cpso(long ctx, long lib, long name, long err, int errCap) { try { return (long) CPSO.invokeExact(ctx, lib, name, err, errCap); } catch (Throwable t) { throw rethrow(t); } }
	static long texture(long ctx, int format, int w, int h, int lossy, long label) { try { return (long) TEXTURE.invokeExact(ctx, format, w, h, lossy, label); } catch (Throwable t) { throw rethrow(t); } }
	static long buffer(long ctx, long size) { try { return (long) BUFFER.invokeExact(ctx, size); } catch (Throwable t) { throw rethrow(t); } }
	static void pass(long enc, long pso, long target, int load, long textures, int count, long bytes, int length, long label, int globals) { try { PASS.invokeExact(enc, pso, target, load, textures, count, bytes, length, label, globals); } catch (Throwable t) { throw rethrow(t); } }
	static void dispatch(long enc, long pso, int w, int h, int tw, int th, long textures, int count, long bytes, int length, long label) { try { DISPATCH.invokeExact(enc, pso, w, h, tw, th, textures, count, bytes, length, label); } catch (Throwable t) { throw rethrow(t); } }
	static void bake(long ctx, long pso, long target) { try { BAKE.invokeExact(ctx, pso, target); } catch (Throwable t) { throw rethrow(t); } }
	static int textureWidth(long t) { try { return (int) TEX_W.invokeExact(t); } catch (Throwable t2) { throw rethrow(t2); } }
	static int textureHeight(long t) { try { return (int) TEX_H.invokeExact(t); } catch (Throwable t2) { throw rethrow(t2); } }
	static int textureFormat(long t) { try { return (int) TEX_FORMAT.invokeExact(t); } catch (Throwable t2) { throw rethrow(t2); } }
	static long textureCpu(long ctx, int w, int h, int mips, long label) { try { return (long) TEX_CPU.invokeExact(ctx, w, h, mips, label); } catch (Throwable t) { throw rethrow(t); } }
	static void textureUpload(long tex, int mip, int x, int y, int w, int h, long bytes, int rowBytes) { try { TEX_UPLOAD.invokeExact(tex, mip, x, y, w, h, bytes, rowBytes); } catch (Throwable t) { throw rethrow(t); } }
	static void textureRelease(long tex) { try { TEX_RELEASE.invokeExact(tex); } catch (Throwable t) { throw rethrow(t); } }
	static int compileSetup(long ctx, int maximize) { try { return (int) COMPILE_SETUP.invokeExact(ctx, maximize); } catch (Throwable t) { throw rethrow(t); } }
	static int compileThreadQos(int qos) { try { return (int) COMPILE_THREAD_QOS.invokeExact(qos); } catch (Throwable t) { throw rethrow(t); } }
}
