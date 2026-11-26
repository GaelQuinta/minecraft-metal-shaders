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
import java.util.ArrayList;
import java.util.List;
import mcopt.metal.MetalBridge;
import org.jspecify.annotations.Nullable;

/**
 * The Fantasy style's painterly brush (fantasy.metal): a structure-tensor pass and an 8-sector oriented Kuwahara pass over the
 * HDR world, encoded between the TAA resolve and bloom.
 *
 * <p>Cost when off is zero, by construction: with {@code mcopt.shade.fantasy.painterly} at 0 (the default) the textures are
 * never allocated and neither pass is encoded, and the whole thing is one branch per frame on the CPU. Turned on, the tensor
 * pass runs at half size and the Kuwahara at the image's size (48 taps), both in scene radiance, so the tone map keeps the
 * strokes. The brush radius (2.0..5.0 px, {@code mcopt.shade.fantasy.brush}) shrinks with distance in the shader, which keeps
 * far hillsides readable and the dependent-read loop short on M-series GPUs.
 *
 * <p>Install it once ({@link #install()}, from the shade setup) and it stays out of the way until the setting is changed.
 */
public final class ShadePainterly {
	public static final int PARAMS_SIZE = 32;
	private static final ByteBuffer PARAMS = ByteBuffer.allocateDirect(PARAMS_SIZE).order(ByteOrder.LITTLE_ENDIAN);
	private static final ByteBuffer TENSOR_PARAMS = ByteBuffer.allocateDirect(16).order(ByteOrder.LITTLE_ENDIAN);

	private static boolean installed, failed;
	private static long library, psoTensor, psoPaint;
	private static long tensor, painted;
	private static int tensorW, tensorH, paintedW, paintedH;
	/** Textures waiting for the frames that may still use them: {handle, frame to release at}. */
	private static final List<long[]> retired = new ArrayList<>();

	private ShadePainterly() {
	}

	/** Registers the pass with the post chain (idempotent). */
	public static synchronized void install() {
		if (installed) return;
		installed = true;
		ShadePost.addPostResolve(ShadePainterly::filter);
	}

	/** How many frames the post chain has finished into its targets (the pass frees its old textures a few frames late). */
	private static int frame;

	/**
	 * The post chain's post-resolve filter: paints the frame when the brush is on. Returns 0 to keep {@code scene} (off, or a
	 * failure: the frame then draws as without it).
	 */
	private static long filter(ShadePost.Context c, long scene) {
		frame++;
		releaseRetired();
		if (Fantasy.painterly() <= 0f || c.depth() == 0) return 0; // no depth: the brush needs to know the sky
		try {
			if (!ready()) return 0;
			int w = ShadeRender.width(scene), h = ShadeRender.height(scene);
			if (w <= 0 || h <= 0) return 0;
			int tw = Math.max(1, w / 2), th = Math.max(1, h / 2);
			if (tensor == 0 || tw != tensorW || th != tensorH) {
				retire(tensor);
				tensorW = tw;
				tensorH = th;
				tensor = ShadeRender.texture(ShadeRender.RGBA16F, tw, th, true, "mcopt shade: painterly tensor");
			}
			if (painted == 0 || w != paintedW || h != paintedH) {
				retire(painted);
				paintedW = w;
				paintedH = h;
				// RGBA16F always: the source may be the TAAU history (RGBA16F) even when the world target is RG11B10F
				painted = ShadeRender.texture(ShadeRender.RGBA16F, w, h, false, "mcopt shade: painterly");
			}
			TENSOR_PARAMS.clear();
			TENSOR_PARAMS.putFloat(1f / w).putFloat(1f / h).putFloat(0f).putFloat(0f).flip();
			ShadeRender.pass(c.enc(), psoTensor, tensor, ShadeRender.DONT_CARE, new long[] {scene}, TENSOR_PARAMS, "mcopt shade: painterly tensor");
			// q: xy the live part of the depth texture this image maps into (TAAU: the scene is the output-size history, the
			// depth this frame's live sub-rect), w 1 = the depth is this frame's jittered raster (f.jitter applies)
			boolean live = (float) c.width() != w;
			PARAMS.clear();
			PARAMS.putFloat(Fantasy.brushRadius()).putFloat(Fantasy.painterly()).putFloat(Fantasy.grain())
				.putFloat(Fantasy.v("paintFade", 96f, 16f, 512f))
				.putFloat((float) c.width() / w).putFloat((float) c.height() / h).putFloat(live ? 1f : 0f).putFloat(0f).flip();
			ShadeRender.pass(c.enc(), psoPaint, painted, ShadeRender.DONT_CARE, new long[] {scene, tensor, c.depth()}, PARAMS,
				"mcopt shade: painterly");
			return painted;
		} catch (RuntimeException e) {
			disable();
			System.out.println("[mcopt] shade: painterly brush unavailable, the frame draws without it: " + e);
			return 0;
		}
	}

	private static void disable() {
		failed = true;
		retire(tensor);
		retire(painted);
		tensor = painted = 0;
	}

	private static boolean ready() {
		if (failed) return false;
		if (psoTensor != 0) return true;
		try {
			long t0 = ShadeCompile.now();
			library = ShadeRender.library(ShadeMsl.prelude() + ShadeMsl.resource("fantasy.metal"));
			psoTensor = ShadeRender.pipeline(library, "shade_painterly_vs", "shade_painterly_tensor", ShadeRender.RGBA16F, 0);
			psoPaint = ShadeRender.pipeline(library, "shade_painterly_vs", "shade_painterly", ShadeRender.RGBA16F, 0);
			ShadeCompile.setup("painterly brush", t0);
			System.out.println("[mcopt] shade: painterly brush ready (brush " + Fantasy.brushRadius() + " px, strength "
				+ Fantasy.painterly() + ")");
			return true;
		} catch (RuntimeException e) {
			failed = true;
			System.out.println("[mcopt] shade: painterly brush could not be built, off: " + e);
			return false;
		}
	}

	private static void retire(long t) {
		if (t != 0) retired.add(new long[] {t, frame + 6});
	}

	private static void releaseRetired() {
		retired.removeIf(r -> {
			if (r[1] > frame) return false;
			MetalBridge.release(r[0]);
			return true;
		});
	}

	/** A brush texture or null (tools / the debug log). */
	public static @Nullable Long currentTarget() {
		return painted != 0 ? painted : null;
	}
}
