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

import java.util.function.Predicate;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.chunk.LevelChunk;
import net.minecraft.world.level.chunk.LevelChunkSection;
import net.minecraft.world.level.chunk.status.ChunkStatus;
import net.minecraft.world.level.material.Fluids;

/**
 * (FT2.11) Whether moving water (falling or running water, not a source) is within {@link #RANGE} sections of the camera: the
 * translucent terrain then draws with the variant that has the moving water's look compiled in (falling water's ripples and white
 * water, rougher currents: water.metal SHADE_WATER_FALL_*, ShadeMsl.LEAN_NOFALLS off). The water shader is bound by registers and
 * that code cost every water pixel ~0.2 ms in the lake spin even where it never ran (FT2.11 prices), so a lake or sea with no
 * stream or waterfall around keeps FT2.10's shader. The shader fades the look out by SHADE_WATER_FALL_RANGE blocks, inside the
 * scanned box (+-RANGE sections cover at least 96 blocks each way), so the switch never shows.
 * <p>
 * Cheap: a section is tested on its palette (PalettedContainer.maybeHas: a handful of states, no block walk; the global palette
 * answers yes), a slice of the box per frame ({@link #COLUMNS_PER_FRAME} section columns, the whole box in ~7 frames). Once moving
 * water is seen the answer stays yes for {@link #HOLD_NANOS} after the last pass that saw it (no flicker between variants).
 * Render thread only.
 */
public final class WaterFlowScan {
	/** Sections each way (horizontal and vertical) around the camera's: 6 = at least 96 blocks. */
	static final int RANGE = 6;
	private static final int SIDE = 2 * RANGE + 1;
	private static final int COLUMNS_PER_FRAME = 24;
	private static final long HOLD_NANOS = 2_000_000_000L;
	private static final Predicate<BlockState> MOVING = s -> s.getFluidState().getType() == Fluids.FLOWING_WATER;

	private static int cursor;
	private static boolean seenThisPass;
	private static long lastSeen = Long.MIN_VALUE / 2;
	private static ClientLevel lastLevel;

	private WaterFlowScan() {
	}

	/** Once per frame (WaterFrame.update): the next slice of the box around the camera at (x, y, z). */
	static void update(ClientLevel level, double x, double y, double z) {
		if (level == null || level.dimension() != net.minecraft.world.level.Level.OVERWORLD
			|| mcopt.metal.shade.Live.f("mcopt.shade.water.falls", 1f, 0f, 2f) <= 0f) {
			lastLevel = null;
			return;
		}
		if (level != lastLevel) { // a new world or dimension: start over, nothing seen yet
			lastLevel = level;
			cursor = 0;
			seenThisPass = false;
			lastSeen = Long.MIN_VALUE / 2;
		}
		long nowNs = System.nanoTime();
		// (2.0.1 opt) once moving water is detected, skip scanning for 1 s (half of HOLD_NANOS)
		if (nowNs - lastSeen < HOLD_NANOS / 2) return;
		int csx = (int) Math.floor(x) >> 4, csy = (int) Math.floor(y) >> 4, csz = (int) Math.floor(z) >> 4;
		int minSy = level.getMinSectionY(), count = level.getSectionsCount();
		for (int n = 0; n < COLUMNS_PER_FRAME; n++) {
			int sx = csx - RANGE + cursor % SIDE, sz = csz - RANGE + cursor / SIDE;
			LevelChunk chunk = level.getChunkSource().getChunk(sx, sz, ChunkStatus.FULL, false);
			if (chunk != null) {
				for (int sy = csy - RANGE; sy <= csy + RANGE; sy++) {
					int index = sy - minSy;
					if (index < 0 || index >= count) continue;
					LevelChunkSection section = chunk.getSection(index);
					if (!section.hasOnlyAir() && section.getStates().maybeHas(MOVING)) {
						seenThisPass = true;
						break;
					}
				}
			}
			if (seenThisPass) {
				lastSeen = nowNs;
				cursor = 0;
				seenThisPass = false;
				break;
			}
			if (++cursor == SIDE * SIDE) { // a pass is done
				cursor = 0;
			}
		}
		boolean now = near();
		if (now != logged) { // a line per change (the bench's logs show which variant a shot used)
			logged = now;
			System.out.println("[mcopt] shade: moving water near the camera: " + now);
		}
	}

	private static boolean logged;

	/** Moving water near the camera (seen in the last pass, or less than HOLD_NANOS ago). */
	public static boolean near() {
		return lastLevel != null && System.nanoTime() - lastSeen < HOLD_NANOS;
	}
}
