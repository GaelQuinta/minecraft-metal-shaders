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
package mcopt.metal.shade.dims;

import java.util.ArrayList;
import java.util.List;
import mcopt.metal.MetalBridge;
import mcopt.metal.shade.ShadeConfig;
import mcopt.metal.shade.ShadeMsl;
import mcopt.metal.shade.ShadeRender;
import net.minecraft.client.Minecraft;

/**
 * M3.3 (mcopt.shade.aurora.half, default true, read every frame; false = M3.2): the aurora in its own pass at half the
 * world's render size (SCALE: 1210x786 on the 3024x1964 panel at the balanced preset), sampled by the sky pass with one
 * tap. The sky pass is a full-screen triangle drawn before the terrain, so in M3.2 every pixel of the frame paid the aurora
 * (8 noise taps) on aurora nights, ~0.4 ms in a sky view
 * (SKYDIMS.md M3.3). While the pass runs the sky draws with its lean variant (no per-pixel aurora code: ShadeLean
 * LEAN_NOAURORA) plus the one-tap read (ShadeLook bit SHADE_DIMS_AURORA_TEX, set only in frames whose pass ran).
 * Render thread only.
 */
public final class ShadeAurora {
	/** ShadeResources entry (shade_look.metal: aurora). */
	static final int RESOURCE = 11;
	/**
	 * The texture's size as a fraction of the output (window framebuffer) size: mcopt.shade.aurora.scale (0.5) x the preset's
	 * render scale (TAAU; 1 without it), i.e. half the world's render size in each direction (balanced 0.8: 0.4, 1210x786).
	 */
	// (2.0.1 opt) 0.35 (was 0.5): smooth atmospheric aurora ribbons look identical when bilinearly upscaled at ~2x fewer night pixels
	static final float SCALE = Math.max(0.1f, Math.min(1f, Float.parseFloat(System.getProperty("mcopt.shade.aurora.scale", "0.35"))
		* (mcopt.metal.shade.taa.TaaConfig.ENABLED ? mcopt.metal.shade.taa.TaaConfig.SCALE : 1f)));

	/**
	 * (1.1) live: SCALE with mcopt.shade.aurora.scale read now (its startup value as the default); a new size re-makes the
	 * texture in {@link #render}, as a new output resolution does.
	 */
	static float scale() {
		float user = mcopt.metal.shade.Live.f("mcopt.shade.aurora.scale", Float.NaN);
		return Float.isNaN(user) ? SCALE
			: Math.max(0.1f, Math.min(1f, user * (mcopt.metal.shade.taa.TaaConfig.ENABLED ? mcopt.metal.shade.taa.TaaConfig.SCALE : 1f)));
	}

	private static long library, pipeline, texture;
	private static int width, height;
	private static boolean failed, want;
	private static long frame;
	private static final List<long[]> retired = new ArrayList<>();

	private ShadeAurora() {
	}

	/** The pass's source: prelude + post (shade_fs_vs) + aurora.metal. */
	public static String source() {
		return ShadeRender.prelude() + "\n" + ShadeRender.postSource() + "\n" + ShadeMsl.resource("aurora.metal");
	}

	/** mcopt.shade.aurora.half (default true, live): false evaluates the aurora per pixel in the sky pass (M3.2). */
	static boolean enabled() {
		return !"false".equals(System.getProperty("mcopt.shade.aurora.half"));
	}

	/** ShadeDims.overworld, once per frame before ShadeDims.pack and ShadeLean.update: whether this frame's pass will run. */
	static void decide(float aurora) {
		want = aurora > 0.002f && !failed && enabled() && ShadeConfig.HDR && !mcopt.metal.shade.ShadeBindings.fallback();
	}

	/** Not in the overworld / no aurora: the pass does not run this frame. */
	static void off() {
		want = false;
	}

	/** This frame the sky pass reads the aurora from the texture (its per-pixel aurora code is not needed). */
	public static boolean active() {
		return want;
	}

	/**
	 * ShadeFrameUpdater, after the sky LUT and before the world pass (enc: the frame's native encoder): renders this frame's
	 * aurora texture and names it in ShadeResources. A failure turns the pass off for the session (the sky pass then
	 * evaluates the aurora itself, as in M3.2).
	 */
	public static void render(long enc) {
		frame++;
		retire(false);
		if (!want) return;
		try {
			if (pipeline == 0) {
				long t0 = mcopt.metal.shade.ShadeCompile.now();
				library = ShadeRender.library(source());
				// (2.0.1 opt) RG11B10F (4 B/px vs RGBA16F 8 B/px): aurora is non-negative RGB emission
				pipeline = ShadeRender.pipeline(library, "shade_fs_vs", "shade_aurora_pass", ShadeRender.RG11B10F, ShadeRender.BLEND_NONE);
				mcopt.metal.shade.ShadeCompile.setup("aurora", t0);
			}
			var window = Minecraft.getInstance().getWindow();
			// (2026-10-09: a share of the chosen output resolution, ShadeOutput, not the window's)
			int[] outSize = mcopt.metal.shade.ShadeOutput.current(window.getWidth(), window.getHeight());
			float scale = scale(); // (1.1) live
			int w = Math.max(16, Math.round(outSize[0] * scale)), h = Math.max(16, Math.round(outSize[1] * scale));
			if (texture == 0 || w != width || h != height) {
				if (texture != 0) retired.add(new long[] {texture, frame + 8});
				texture = ShadeRender.texture(ShadeRender.RG11B10F, w, h, false, "mcopt shade: aurora");
				width = w;
				height = h;
			}
			ShadeRender.pass(enc, pipeline, texture, ShadeRender.DONT_CARE, null, null, "mcopt shade: aurora");
			ShadeRender.resource(RESOURCE, texture);
		} catch (Throwable t) {
			failed = true;
			want = false;
			System.out.println("[mcopt] shade: aurora pass off (the sky pass evaluates it per pixel): " + t);
		}
	}

	/** Releases textures no frame in flight can still use (all of them with force). */
	private static void retire(boolean force) {
		retired.removeIf(r -> {
			if (!force && r[1] > frame) return false;
			MetalBridge.release(r[0]);
			return true;
		});
	}
}
