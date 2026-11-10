/*
 * Copyright 2026 mcopt-shade contributors
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
 * License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
 * law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
 * OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
 * limitations under the License.
 */
package mcopt.metal.shade.water;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

import mcopt.metal.shade.ShadeFrame;
import mcopt.metal.shade.ShadeRender;

/**
 * 1.2.7 candidate 8: the reflections' panorama (water.metal SHADE_WATER_PANO; ShadeResources.reflPano, entry 10). Screen-space
 * reflections end where the screen does: mirrored trees and shores near its sides were cut off along a line that swept over the
 * water while the view turned. Once a frame, before the world is drawn, last frame's finished image (the TAA's history and its
 * depth) is laid into a 2048x512 texture by direction from the eye; what the view no longer shows stays, re-aimed as the eye
 * moves. The water marches the mirrored rays that leave the screen through it. Two textures alternate (the pass reads the one it
 * replaces). Starts over on a jump of the eye (a teleport, a respawn) or a change of dimension. Render thread only.
 */
public final class ShadeWaterPano {
	private static final int W = 2048, H = 512; // water.metal SHADE_PANO_W / _H
	private static final long[] TEX = new long[2];
	private static final ByteBuffer PARAMS = ByteBuffer.allocateDirect(32).order(ByteOrder.nativeOrder());
	private static long pso;
	private static int cur, frames, calls, sinceWater = 1 << 20, lastCaptures, dimension = Integer.MIN_VALUE;
	private static boolean failed;
	// the eye of last frame (whose finished image an update lays in) and the eye the panorama stands at (the last image laid in)
	private static double lastX, lastY, lastZ, panoX, panoY, panoZ;

	private ShadeWaterPano() {
	}

	/** The panorama holds something the water may read (ShadeWaterParams.mirror.z is 0 until then). */
	static boolean ready() {
		return frames > 2 && !failed && on();
	}

	/**
	 * (Gael, 2026-11-10: "un toggle en las opciones para apagar el relleno de los lados") The settings screen's switch, live
	 * ({@code mcopt.shade.water.reflSides}, true): off = no panorama pass and a share of 0 for the water (its march is skipped), so
	 * reflections end at the screen's sides as in candidate 7; back on, the panorama starts over from nothing.
	 */
	static boolean on() {
		return mcopt.metal.shade.Live.b("mcopt.shade.water.reflSides", true);
	}

	/**
	 * Lays last frame's image in; f: this frame's (its camera and dimension). Before the world passes, after ShadePost.beginWorld.
	 * Not every frame: the pass is 1 M texels (0.18 ms, prof-px28 2026-11-10) and the panorama is a memory of what left the screen,
	 * so every third frame while water is being drawn (mcopt.shade.water.reflPanoEvery) and every twelfth otherwise (a rough memory
	 * for the next lake at ~0.015 ms a frame); the eye's move since the last update is passed whole.
	 */
	public static void update(long enc, ShadeFrame f) {
		if (!ShadeWater.ON || !ShadeWater.PANO || !mcopt.metal.shade.taa.TaaConfig.ENABLED || failed || enc == 0) return;
		try {
			if (!on()) {
				frames = 0;
				return;
			}
			int captures = ShadeWater.captures();
			sinceWater = captures != lastCaptures ? 0 : Math.min(sinceWater + 1, 1 << 20);
			lastCaptures = captures;
			int every = sinceWater < 600 ? Math.clamp((int) mcopt.metal.shade.Live.f("mcopt.shade.water.reflPanoEvery", 3f, 1f, 60f), 1, 60) : 12;
			double mx = lastX - panoX, my = lastY - panoY, mz = lastZ - panoZ;
			boolean reset = frames == 0 || f.dimension != dimension || Math.abs(mx) + Math.abs(my) + Math.abs(mz) > 16;
			if (reset || calls++ % every == 0) {
				if (pso == 0) {
					long t0 = mcopt.metal.shade.ShadeCompile.now();
					pso = ShadeRender.pipeline(ShadeWater.passLibrary(), "shade_fs_vs", "shade_water_pano_fs", ShadeRender.RGBA16F, ShadeRender.BLEND_NONE);
					TEX[0] = ShadeRender.texture(ShadeRender.RGBA16F, W, H, false, "mcopt shade water: reflection panorama A");
					TEX[1] = ShadeRender.texture(ShadeRender.RGBA16F, W, H, false, "mcopt shade water: reflection panorama B");
					mcopt.metal.shade.ShadeCompile.setup("water", t0);
				}
				dimension = f.dimension;
				PARAMS.clear();
				PARAMS.putFloat((float) mx).putFloat((float) my).putFloat((float) mz).putFloat(reset ? 1f : 0f)
					.putFloat(mcopt.metal.shade.Live.f("mcopt.shade.water.reflPanoBlend", 0.5f, 0.02f, 1f)).putFloat(0f).putFloat(0f).putFloat(0f).flip();
				int next = cur ^ 1;
				ShadeRender.pass(enc, pso, TEX[next], ShadeRender.DONT_CARE, new long[] {TEX[cur]}, PARAMS, "mcopt shade water: reflection panorama");
				ShadeRender.resource(10, TEX[next]);
				cur = next;
				frames = reset ? 1 : frames + 1;
				panoX = lastX;
				panoY = lastY;
				panoZ = lastZ;
			}
			lastX = f.cameraX;
			lastY = f.cameraY;
			lastZ = f.cameraZ;
		} catch (Throwable e) {
			failed = true;
			System.out.println("[mcopt] shade: water reflection panorama failed, reflections end at the screen's sides: " + e);
		}
	}
}
