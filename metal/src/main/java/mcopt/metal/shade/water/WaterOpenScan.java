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

import java.nio.ByteBuffer;
import mcopt.metal.shade.Live;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.core.Holder;
import net.minecraft.world.level.biome.Biome;
import net.minecraft.world.level.biome.Biomes;
import net.minecraft.world.level.chunk.LevelChunk;
import net.minecraft.world.level.chunk.status.ChunkStatus;
import net.minecraft.world.level.levelgen.Heightmap;
import net.minecraft.world.level.material.Fluids;

/**
 * (2026-11-02, water round 1: work/notes/2026-11-02/water/DESIGN.md S2) Where the swell (water.metal shadeWaterSwell) belongs: the
 * open sea swells, lakes stay near mirrors, rivers and ponds calm, and every shore calms the water next to it. Wind waves grow with
 * fetch (open water upwind); Minecraft's blocky shores read better calming toward them than shoaling. A map of "open water" 0..1
 * around the camera, {@link #N}^2 cells of 2x2 blocks (256 blocks across, toroidal by absolute cell so it scrolls without copying):
 * smoothstep(4, fetch, distance to the nearest land column in blocks; mcopt.shade.water.swellFetch, 48: raise it to calm bays and
 * lakes that are wide but enclosed) x the biome's gain (oceans 0.8-1, beaches 0.75, rivers 0.25,
 * swamps 0.15, anything else, i.e. inland lakes, mcopt.shade.water.swellLake, 0.25; 0.4 in candidate 4), blurred over 3x3 cells. The shader scales the
 * swell's strength by it near the camera and by its outer ring's mean (96-128 blocks) beyond (ShadeWaterParams.swell2.x).
 * <p>
 * Cheap and spread over frames: one column per cell (the client's MOTION_BLOCKING_NO_LEAVES heightmap, which counts fluids, and the
 * fluid there), the biome every 4 blocks at that surface (the chunk's noise biome), {@link #FAST} cells per frame (the whole map in 16
 * frames) while the map is new or the camera moved more than 8 blocks since the last one, {@link #SLOW} otherwise; then a 2-pass
 * chamfer distance transform, the blur and a 64 KB upload (ShadeWater.openMap). Only while the swell's code is compiled in, the swell
 * is on (mcopt.shade.water.swell > 0), the map is wanted (mcopt.shade.water.swellOpen, 1; 0 = the swell everywhere) and the world is
 * HDR (ShadeResources). Unloaded chunks count as water of unknown biome (the lake gain) until they load. Render thread only.
 */
public final class WaterOpenScan {
	/** Cells per side (2 blocks each): 256 blocks across, centred on the camera. Must match water.metal shadeWaterOpen (1 / 256). */
	static final int N = 128;
	private static final int Q = N / 2; // biome samples per side (4 blocks)
	private static final int FAST = 1024, SLOW = 256;
	private static final byte LAND = 0, WATER = 1, UNKNOWN = 2;
	// the toroidal stores: cell (cx, cz) at (cx & N-1) + N (cz & N-1), the cell each entry holds (stale entries are unknown)
	private static final int[] CELL_X = new int[N * N], CELL_Z = new int[N * N];
	private static final byte[] STATE = new byte[N * N];
	private static final int[] QUART_X = new int[Q * Q], QUART_Z = new int[Q * Q];
	private static final float[] GAIN = new float[Q * Q];
	// the build's window (window cell (i, j) = world cell (centre - N/2 + i, ...))
	private static final int[] DIST = new int[N * N];
	private static final byte[] WIN = new byte[N * N];
	private static final float[] OPEN = new float[N * N], TMP = new float[N * N];
	private static ByteBuffer bytes;
	private static int cursor;
	private static int lastCx = Integer.MIN_VALUE, lastCz;
	private static boolean complete, active;
	private static ClientLevel lastLevel;

	private WaterOpenScan() {
	}

	/** Once per frame (WaterFrame.update): the next slice of the map around the camera at (x, z), and a new map when a pass ends. */
	static void update(ClientLevel level, double x, double z) {
		boolean want = level != null && mcopt.metal.shade.ShadeConfig.HDR && ShadeWater.swellCompiled()
			&& Live.f("mcopt.shade.water.swell", 1.3f) > 0f && Live.f("mcopt.shade.water.swellOpen", 1f) > 0f;
		if (!want) {
			if (active) ShadeWater.openNone();
			active = false;
			return;
		}
		if (level != lastLevel || !active) { // a new world or dimension, or back on: start over
			lastLevel = level;
			cursor = 0;
			complete = false;
			lastCx = Integer.MIN_VALUE;
			java.util.Arrays.fill(CELL_X, Integer.MIN_VALUE);
			java.util.Arrays.fill(QUART_X, Integer.MIN_VALUE);
			ShadeWater.openNone();
		}
		active = true;
		int ccx = Math.floorDiv((int) Math.floor(x), 2), ccz = Math.floorDiv((int) Math.floor(z), 2);
		boolean moved = lastCx == Integer.MIN_VALUE || Math.abs(ccx - lastCx) > 4 || Math.abs(ccz - lastCz) > 4;
		int budget = !complete || moved ? FAST : SLOW;
		LevelChunk chunk = null;
		int chunkX = Integer.MIN_VALUE, chunkZ = Integer.MIN_VALUE;
		for (int n = 0; n < budget; n++) {
			int cx = ccx - N / 2 + cursor % N, cz = ccz - N / 2 + cursor / N;
			int bx = cx * 2, bz = cz * 2; // the cell's sampled column
			if (bx >> 4 != chunkX || bz >> 4 != chunkZ) {
				chunkX = bx >> 4;
				chunkZ = bz >> 4;
				chunk = level.getChunkSource().getChunk(chunkX, chunkZ, ChunkStatus.FULL, false);
			}
			int idx = (cx & (N - 1)) + N * (cz & (N - 1));
			CELL_X[idx] = cx;
			CELL_Z[idx] = cz;
			if (chunk == null) {
				STATE[idx] = UNKNOWN;
			} else {
				int h = chunk.getHeight(Heightmap.Types.MOTION_BLOCKING_NO_LEAVES, bx, bz); // the top block that blocks motion or holds a fluid
				STATE[idx] = chunk.getFluidState(bx, h, bz).getType().isSame(Fluids.WATER) ? WATER : LAND;
				if (((cx | cz) & 1) == 0) { // a biome sample every 4 blocks, at that surface
					int qx = cx >> 1, qz = cz >> 1, qi = (qx & (Q - 1)) + Q * (qz & (Q - 1));
					QUART_X[qi] = qx;
					QUART_Z[qi] = qz;
					GAIN[qi] = gain(chunk.getNoiseBiome(bx >> 2, h >> 2, bz >> 2));
				}
			}
			if (++cursor == N * N) { // a pass is done: the map around where the camera is now
				cursor = 0;
				build(ccx, ccz);
				complete = true;
				lastCx = ccx;
				lastCz = ccz;
			}
		}
	}

	/** The swell's share by biome (deep oceans 1, the open ocean 0.9, ...; rivers, swamps and inland water calmer). */
	private static float gain(Holder<Biome> b) {
		if (b.is(Biomes.DEEP_OCEAN) || b.is(Biomes.DEEP_COLD_OCEAN) || b.is(Biomes.DEEP_LUKEWARM_OCEAN)) return 1f;
		if (b.is(Biomes.OCEAN) || b.is(Biomes.COLD_OCEAN)) return 0.9f;
		if (b.is(Biomes.WARM_OCEAN) || b.is(Biomes.LUKEWARM_OCEAN)) return 0.8f;
		if (b.is(Biomes.FROZEN_OCEAN) || b.is(Biomes.DEEP_FROZEN_OCEAN)) return 0.65f;
		if (b.is(Biomes.BEACH) || b.is(Biomes.SNOWY_BEACH) || b.is(Biomes.STONY_SHORE)) return 0.75f;
		if (b.is(Biomes.RIVER) || b.is(Biomes.FROZEN_RIVER)) return 0.25f;
		if (b.is(Biomes.SWAMP) || b.is(Biomes.MANGROVE_SWAMP)) return 0.15f;
		return -1f; // inland: mcopt.shade.water.swellLake when the map is built (live)
	}

	private static void build(int ccx, int ccz) {
		final int inf = 1 << 20;
		float lake = Live.f("mcopt.shade.water.swellLake", 0.25f, 0f, 1f); // (candidate 5: calmer lakes, mirrors as Gael likes them)
		float fetch = Live.f("mcopt.shade.water.swellFetch", 48f, 8f, 120f);
		int ox = ccx - N / 2, oz = ccz - N / 2;
		for (int j = 0; j < N; j++) {
			for (int i = 0; i < N; i++) {
				int cx = ox + i, cz = oz + j, idx = (cx & (N - 1)) + N * (cz & (N - 1)), k = i + N * j;
				byte s = CELL_X[idx] == cx && CELL_Z[idx] == cz ? STATE[idx] : UNKNOWN;
				WIN[k] = s;
				DIST[k] = s == LAND ? 0 : inf;
			}
		}
		// chamfer distance to land (3 per cell step = 2 blocks, 4 diagonally), forward then backward
		for (int j = 0; j < N; j++) {
			for (int i = 0; i < N; i++) {
				int k = i + N * j, d = DIST[k];
				if (d == 0) continue;
				if (i > 0) d = Math.min(d, DIST[k - 1] + 3);
				if (j > 0) {
					d = Math.min(d, DIST[k - N] + 3);
					if (i > 0) d = Math.min(d, DIST[k - N - 1] + 4);
					if (i < N - 1) d = Math.min(d, DIST[k - N + 1] + 4);
				}
				DIST[k] = d;
			}
		}
		for (int j = N - 1; j >= 0; j--) {
			for (int i = N - 1; i >= 0; i--) {
				int k = i + N * j, d = DIST[k];
				if (d == 0) continue;
				if (i < N - 1) d = Math.min(d, DIST[k + 1] + 3);
				if (j < N - 1) {
					d = Math.min(d, DIST[k + N] + 3);
					if (i < N - 1) d = Math.min(d, DIST[k + N + 1] + 4);
					if (i > 0) d = Math.min(d, DIST[k + N - 1] + 4);
				}
				DIST[k] = d;
			}
		}
		for (int j = 0; j < N; j++) {
			for (int i = 0; i < N; i++) {
				int k = i + N * j;
				if (WIN[k] == LAND) {
					TMP[k] = 0f;
					continue;
				}
				int qx = (ox + i) >> 1, qz = (oz + j) >> 1, qi = (qx & (Q - 1)) + Q * (qz & (Q - 1));
				float g = QUART_X[qi] == qx && QUART_Z[qi] == qz ? GAIN[qi] : -1f;
				if (g < 0f) g = lake;
				float blocks = DIST[k] * (2f / 3f);
				float t = Math.clamp((blocks - 4f) / (fetch - 4f), 0f, 1f);
				TMP[k] = t * t * (3f - 2f * t) * g; // smoothstep(4, fetch, distance to land) x the biome's gain
			}
		}
		// 3x3 box blur (edges clamped); the mean over the outer ring's water (96-128 blocks: 48-64 cells) for the water beyond it
		double ring = 0, all = 0;
		int nRing = 0, nAll = 0;
		for (int j = 0; j < N; j++) {
			for (int i = 0; i < N; i++) {
				float sum = 0f;
				for (int dj = -1; dj <= 1; dj++) {
					int jj = Math.clamp(j + dj, 0, N - 1);
					for (int di = -1; di <= 1; di++) sum += TMP[Math.clamp(i + di, 0, N - 1) + N * jj];
				}
				int k = i + N * j;
				float o = sum * (1f / 9f);
				OPEN[k] = o;
				if (WIN[k] == WATER) {
					all += o;
					nAll++;
					int di = i - N / 2, dj = j - N / 2, r2 = di * di + dj * dj;
					if (r2 >= 48 * 48 && r2 <= 64 * 64) {
						ring += o;
						nRing++;
					}
				}
			}
		}
		float far = nRing > 0 ? (float) (ring / nRing) : nAll > 0 ? (float) (all / nAll) : 0.7f;
		if (bytes == null) bytes = ByteBuffer.allocateDirect(N * N * 4);
		for (int j = 0; j < N; j++) {
			for (int i = 0; i < N; i++) {
				int k = i + N * j, t = (((ox + i) & (N - 1)) + N * ((oz + j) & (N - 1))) * 4;
				byte s = WIN[k];
				bytes.put(t, (byte) Math.round(Math.clamp(OPEN[k], 0f, 1f) * 255f));
				bytes.put(t + 1, (byte) (s == WATER ? 255 : s == UNKNOWN ? 128 : 0)); // (for a look at the map: the water found)
				bytes.put(t + 2, (byte) Math.round(Math.clamp(DIST[k] * (2f / 3f) / 64f, 0f, 1f) * 255f)); // the distance to land (64 blocks = 1)
				bytes.put(t + 3, (byte) 255);
			}
		}
		ShadeWater.openMap(bytes, N, far);
	}
}
