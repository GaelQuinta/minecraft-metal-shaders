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

import java.util.ArrayList;
import java.util.HashMap;
import java.util.IdentityHashMap;
import java.util.Map;
import java.util.function.Predicate;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.chunk.LevelChunk;
import net.minecraft.world.level.chunk.LevelChunkSection;
import net.minecraft.world.level.chunk.status.ChunkStatus;

/**
 * (1.2.8, issue #61) Placed lights whose colour is far from a torch's: soul fire (blue), redstone torches (red), copper torches
 * and lanterns (green), nether portals, crying obsidian and amethyst clusters (purple), the green and the pink froglight, sea
 * lanterns and conduits (cyan). Vanilla's block light is one number without a colour, so the terrain lit all of it in the
 * torch's warm colour. This finds those blocks in the sections around the camera (DynLights then lists them as lights that
 * only tint: dynlight.metal shadeBlockTintVol). Whites, yellows and oranges (glowstone, lamps, lava, end rods, beacons...) stay
 * as they are: only what is clearly another colour.
 *
 * <p>A section is read when it is first needed and again when one of its blocks changes (DynLights.blockChanged /
 * sectionChanged) or after {@link #STALE_FRAMES} frames, a few sections a frame: the palette is asked first (no such block:
 * nothing to read), so a world without these blocks costs a palette test per section. Neighbouring blocks of one colour (a
 * portal's six blocks, a patch of soul fire) count as one light. Render thread only (the client level's own thread).
 */
final class PlacedLights {
	/** A light: block-centre position, vanilla's emission (its reach in blocks) and the tint (DynLightTable's, relative to the torch's colour). */
	record Light(double x, double y, double z, float level, float[] tint) {
	}

	/** Sections around the camera's that are read (horizontally / vertically): the dynamic lights' range and their volume's height. */
	private static final int RX = 3, RY = 2;
	private static final int PER_FRAME = 24, STALE_FRAMES = 600, MAX_PER_SECTION = 24;
	private static final Light[] NONE = new Light[0];

	private record Entry(Light[] lights, int frame) {
	}

	private static final Map<Long, Entry> SECTIONS = new HashMap<>();
	private static Map<Block, float[]> tints;
	private static final Predicate<BlockState> COLOURED = s -> s.getLightEmission() > 0 && tints.containsKey(s.getBlock());
	private static ClientLevel lastLevel;
	private static int cursor, frame;

	private PlacedLights() {
	}

	private static Map<Block, float[]> tints() {
		Map<Block, float[]> m = new IdentityHashMap<>();
		for (Block b : BuiltInRegistries.BLOCK) {
			String p = BuiltInRegistries.BLOCK.getKey(b).getPath();
			float[] t = p.startsWith("soul_") && !p.equals("soul_sand") && !p.equals("soul_soil") ? DynLightTable.SOUL
				: p.equals("redstone_torch") || p.equals("redstone_wall_torch") ? DynLightTable.REDSTONE
				: p.equals("copper_torch") || p.equals("copper_wall_torch") || p.endsWith("copper_lantern") ? DynLightTable.COPPER
				: p.equals("nether_portal") || p.equals("crying_obsidian") || p.equals("amethyst_cluster") ? DynLightTable.VIOLET
				: p.equals("verdant_froglight") ? DynLightTable.VERDANT
				: p.equals("pearlescent_froglight") ? DynLightTable.PEARL
				: p.equals("sea_lantern") || p.equals("conduit") ? DynLightTable.COOL
				: null;
			if (t != null) m.put(b, t);
		}
		return m;
	}

	private static long key(int sx, int sy, int sz) {
		return ((long) sx & 0x3FFFFFL) << 42 | ((long) sz & 0x3FFFFFL) << 20 | ((long) sy & 0xFFFFFL);
	}

	static void sectionChanged(int sx, int sy, int sz) {
		SECTIONS.remove(key(sx, sy, sz));
	}

	static void blockChanged(int x, int y, int z) {
		SECTIONS.remove(key(x >> 4, y >> 4, z >> 4));
	}

	/** Every frame: reads a few of the sections around the camera that are unknown or old, then gives the lights within range. */
	static void collect(ClientLevel level, double camX, double camY, double camZ, double range, ArrayList<Light> out) {
		out.clear();
		if (level == null) return;
		if (tints == null) tints = tints();
		if (level != lastLevel) {
			SECTIONS.clear();
			lastLevel = level;
		}
		frame++;
		int cx = (int) Math.floor(camX) >> 4, cy = (int) Math.floor(camY) >> 4, cz = (int) Math.floor(camZ) >> 4;
		int w = 2 * RX + 1, h = 2 * RY + 1, n = w * w * h, read = 0;
		// unknown sections first (a new place: the nearest ring of them matters at once), then the oldest by turns
		for (int pass = 0; pass < 2 && read < PER_FRAME; pass++) {
			for (int i = 0; i < n && read < PER_FRAME; i++) {
				int k = pass == 0 ? i : (cursor + i) % n;
				int sx = cx - RX + k % w, sz = cz - RX + k / w % w, sy = cy - RY + k / (w * w);
				Entry e = SECTIONS.get(key(sx, sy, sz));
				if (pass == 0 ? e != null : e == null || frame - e.frame < STALE_FRAMES) continue;
				Light[] lights = read(level, sx, sy, sz);
				if (lights != null) SECTIONS.put(key(sx, sy, sz), new Entry(lights, frame));
				read++;
				if (pass == 1) cursor = (k + 1) % n;
			}
		}
		if (SECTIONS.size() > 4 * n) { // (moved far: what is out of reach goes)
			SECTIONS.keySet().removeIf(q -> {
				int sx = (int) (q << 0 >> 42), sz = (int) (q << 22 >> 42), sy = (int) (q << 44 >> 44);
				return Math.abs(sx - cx) > RX + 1 || Math.abs(sz - cz) > RX + 1 || Math.abs(sy - cy) > RY + 1;
			});
		}
		double r2 = range * range;
		for (int sy = cy - RY; sy <= cy + RY; sy++) for (int sz = cz - RX; sz <= cz + RX; sz++) for (int sx = cx - RX; sx <= cx + RX; sx++) {
			Entry e = SECTIONS.get(key(sx, sy, sz));
			if (e == null) continue;
			for (Light l : e.lights) {
				double dx = l.x - camX, dy = l.y - camY, dz = l.z - camZ;
				if (dx * dx + dz * dz <= r2 && Math.abs(dy) <= 32) out.add(l);
			}
		}
	}

	/** The coloured lights of a section (NONE for none); null while its chunk isn't loaded (asked again later). */
	private static Light[] read(ClientLevel level, int sx, int sy, int sz) {
		int index = sy - level.getMinSectionY();
		if (index < 0 || index >= level.getSectionsCount()) return NONE;
		LevelChunk chunk = level.getChunkSource().getChunk(sx, sz, ChunkStatus.FULL, false);
		if (chunk == null) return null;
		LevelChunkSection section = chunk.getSection(index);
		if (section == null || section.hasOnlyAir() || !section.maybeHas(COLOURED)) return NONE;
		ArrayList<Light> found = new ArrayList<>();
		for (int y = 0; y < 16; y++) for (int z = 0; z < 16; z++) for (int x = 0; x < 16; x++) {
			BlockState s = section.getBlockState(x, y, z);
			int level15 = s.getLightEmission();
			if (level15 <= 0) continue;
			float[] tint = tints.get(s.getBlock());
			if (tint == null) continue;
			double wx = (sx << 4) + x + 0.5, wy = (sy << 4) + y + 0.5, wz = (sz << 4) + z + 0.5;
			// one light for touching blocks of a colour (a portal, a patch of soul fire): at the first one's place, the brightest level
			boolean merged = false;
			for (int i = 0; i < found.size() && !merged; i++) {
				Light o = found.get(i);
				if (o.tint == tint && Math.abs(o.x - wx) <= 2.01 && Math.abs(o.y - wy) <= 2.01 && Math.abs(o.z - wz) <= 2.01) {
					if (level15 > o.level) found.set(i, new Light(o.x, o.y, o.z, level15, tint));
					merged = true;
				}
			}
			if (!merged && found.size() < MAX_PER_SECTION) found.add(new Light(wx, wy, wz, level15, tint));
		}
		return found.isEmpty() ? NONE : found.toArray(new Light[0]);
	}
}
