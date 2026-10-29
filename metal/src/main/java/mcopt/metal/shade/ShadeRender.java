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
import org.jspecify.annotations.Nullable;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.system.MemoryUtil;

/**
 * The building blocks of native shading's own GPU passes, for the post chain (ShadePost) and for modules (volumetric light,
 * water): compile MSL, make full-screen and compute pipelines, private compressible textures, and encode a full-screen
 * fragment pass or a compute dispatch on the frame's command buffer with the shade globals bound (buffers 16-19, shadow map
 * at texture(16) + sampler(12), sky LUT at texture(17) + sampler(13)). Handles are native pointers (id&lt;MTL...&gt;) as longs,
 * like the rest of the backend; release them with mcopt.metal.MetalBridge.release once no frame in flight uses them.
 * Render thread only (except library/pipeline creation, which is thread-safe).
 *
 * <p>MSL for modules: start the source with {@link #prelude()} (shade_look + shade_common + shade_m2: every struct and
 * shading function), then your functions. A full-screen pass uses the vertex function {@code shade_fs_vs} from
 * {@link #postSource()} (include it, or write your own: a 3-vertex triangle, no vertex buffers).
 */
public final class ShadeRender {
	/** Native mc_shade_pass binding modes. Unclassified passes keep all globals. */
	static final int GLOBALS_ALL = -1, GLOBALS_NONE = 0, GLOBALS_GPU = 1;
	/** MTLPixelFormat values used by shade. */
	public static final int RGBA8 = 70, RGBA16F = 115, RG11B10F = 92, R16F = 25, RG16F = 65, R8 = 10, R32F = 55;
	/** Load actions for {@link #pass}. */
	public static final int DONT_CARE = 0, LOAD = 1, CLEAR = 2;
	/** Blend modes for {@link #pipeline}. */
	public static final int BLEND_NONE = 0, BLEND_ADD = 1, BLEND_ALPHA = 2, BLEND_PREMULTIPLIED = 3;

	private ShadeRender() {
	}

	/** "#define MCOPT_SHADE" + shade_look.metal + shade_common.metal + shade_m2.metal (no MCOPT_HDR: define it yourself if needed). */
	public static String prelude() {
		return ShadeMsl.prelude();
	}

	/** shade_post.metal (shade_fs_vs and the post functions); goes after prelude(). */
	public static String postSource() {
		return ShadeMsl.resource("shade_post.metal");
	}

	/** Whether the shade globals are set up (ShadeBindings: the device is known, {@link #library} can compile). */
	public static boolean ready() {
		return ShadeBindings.ready();
	}

	/** Compiles a library (MSL 3.0, fast math); throws with the compiler's message. */
	public static long library(String source) {
		// M3.3: dev-only injected failure (ShadeRobust, -Dmcopt.shade.dev.failCompile=library:<caller class>); inert unset
		if (System.getProperty("mcopt.shade.dev.failCompile") != null) {
			String caller = StackWalker.getInstance(StackWalker.Option.RETAIN_CLASS_REFERENCE).walk(s -> s.skip(1).findFirst())
				.map(f -> f.getDeclaringClass().getSimpleName()).orElse("?");
			ShadeRobust.maybeFail("library:" + caller);
		}
		long ctx = ShadeBindings.ctx();
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

	/** A full-screen render pipeline (one color target of format, no depth). */
	public static long pipeline(long library, String vertex, String fragment, int format, int blend) {
		try (MemoryStack stack = MemoryStack.stackPush()) {
			long err = stack.nmalloc(1, 4096);
			MemoryUtil.memPutByte(err, (byte) 0);
			long pso = ShadeNative.pso(ShadeBindings.ctx(), library, MemoryUtil.memAddress(stack.UTF8(vertex)), MemoryUtil.memAddress(stack.UTF8(fragment)),
				format, blend, err, 4096);
			if (pso == 0) throw new IllegalStateException("shade pipeline " + fragment + ": " + MemoryUtil.memUTF8(err));
			return pso;
		}
	}

	public static long computePipeline(long library, String kernel) {
		try (MemoryStack stack = MemoryStack.stackPush()) {
			long err = stack.nmalloc(1, 4096);
			MemoryUtil.memPutByte(err, (byte) 0);
			long pso = ShadeNative.cpso(ShadeBindings.ctx(), library, MemoryUtil.memAddress(stack.UTF8(kernel)), err, 4096);
			if (pso == 0) throw new IllegalStateException("shade kernel " + kernel + ": " + MemoryUtil.memUTF8(err));
			return pso;
		}
	}

	/**
	 * A private render-target + sampled texture (compressible); lossy for blurry intermediates (RGBA16F/RGBA8/R16F/RG16F/R8;
	 * RG11B10F can't be lossy and silently stays lossless).
	 */
	public static long texture(int format, int width, int height, boolean lossy, String label) {
		try (MemoryStack stack = MemoryStack.stackPush()) {
			long t = ShadeNative.texture(ShadeBindings.ctx(), format, Math.max(1, width), Math.max(1, height), lossy ? 1 : 0, MemoryUtil.memAddress(stack.UTF8(label)));
			if (t == 0) throw new IllegalStateException("shade texture " + label + " " + width + "x" + height);
			return t;
		}
	}

	public static int width(long texture) {
		return ShadeNative.textureWidth(texture);
	}

	public static int height(long texture) {
		return ShadeNative.textureHeight(texture);
	}

	/**
	 * One full-screen triangle of pipeline into target (load: DONT_CARE, LOAD or CLEAR), with inputs at texture(0..) and
	 * params (may be null, at most 4 KB) at buffer(0). Ends any open render encoder (the backend reopens its own).
	 */
	public static void pass(long enc, long pipeline, long target, int load, long @Nullable [] textures, @Nullable ByteBuffer params, String label) {
		pass(enc, pipeline, target, load, textures, params, label, GLOBALS_ALL);
	}

	/** Post passes with an explicit global binding contract (bloom); other callers use the full-state overload. */
	static void pass(long enc, long pipeline, long target, int load, long @Nullable [] textures, @Nullable ByteBuffer params, String label, int globals) {
		try (MemoryStack stack = MemoryStack.stackPush()) {
			int n = textures == null ? 0 : textures.length;
			long t = stack.nmalloc(8, Math.max(1, n) * 8);
			for (int i = 0; i < n; i++) MemoryUtil.memPutAddress(t + i * 8L, textures[i]);
			ShadeNative.pass(enc, pipeline, target, load, t, n, params == null ? 0 : MemoryUtil.memAddress(params), params == null ? 0 : params.remaining(),
				MemoryUtil.memAddress(stack.UTF8(label)), globals);
		}
	}

	/** A compute dispatch of width x height threads in groups of tw x th, inputs at texture(0..), params at buffer(0). */
	public static void dispatch(long enc, long pipeline, int width, int height, int tw, int th, long @Nullable [] textures, @Nullable ByteBuffer params,
		String label) {
		try (MemoryStack stack = MemoryStack.stackPush()) {
			int n = textures == null ? 0 : textures.length;
			long t = stack.nmalloc(8, Math.max(1, n) * 8);
			for (int i = 0; i < n; i++) MemoryUtil.memPutAddress(t + i * 8L, textures[i]);
			ShadeNative.dispatch(enc, pipeline, width, height, tw, th, t, n, params == null ? 0 : MemoryUtil.memAddress(params),
				params == null ? 0 : params.remaining(), MemoryUtil.memAddress(stack.UTF8(label)));
		}
	}

	/**
	 * ShadeResources (buffer 19) entry index = texture (0: the dummy), for this frame and the following ones (a ring like
	 * ShadeFrame: frames already encoded keep their entries; the ring retains the texture while any slot names it).
	 */
	public static void resource(int index, long texture) {
		ShadeNative.resource(index, texture);
	}
}
