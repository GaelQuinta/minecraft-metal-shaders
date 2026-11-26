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

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Arrays;
import java.util.IdentityHashMap;
import java.util.Map;
import mcopt.metal.own.OwnPalette;
import mcopt.metal.shade.Live;
import mcopt.metal.shade.ShadeMsl;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.chunk.LevelChunk;
import net.minecraft.world.level.chunk.LevelChunkSection;
import net.minecraft.world.level.chunk.Palette;
import net.minecraft.world.level.chunk.status.ChunkStatus;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.system.MemoryUtil;

/**
 * (1.2.8, issue #61, Gael 2026-11-14: "that lights look the colour they should give off, always") Coloured block light, the CPU
 * side of colorlight.metal (which explains the volume): which world section each slot of the two windows holds, the slots' block
 * ids (read from the client's chunk sections a few a frame, nearest first, again when a block or section changes), and each
 * frame the slots to spread (those within a section of a coloured light, and a while after it went, so its light fades out) and
 * to empty.
 *
 * <p>Block ids (a byte a block; the coarse cascade a byte per 4^3 blocks): 0 air and anything light passes as through air, 1-14
 * a block that dims light by that much (vanilla's light dampening), 15 opaque, 16 + class x 16 + level a light of that class
 * (colorlight.metal SHADE_CL_CLASS; class 0 for every light of a torch's colours). A coarse cell: its brightest light, else opaque
 * when 48 of its 64 blocks are, else air.
 *
 * <p>mcopt.shade.coloredLights (live, true) and .strength / .glow (live, 1 / 1); -Dmcopt.shade.coloredLights.module=false leaves
 * the whole thing out of the shaders. Render thread only (the client level's thread: block and section changes arrive there too).
 */
public final class ColorLights {
	public static final boolean ON = DynLightMsl.COLOR;
	/** Fine window (sections), coarse window (64-block coarse sections). */
	static final int FX = 16, FY = 8, FZ = 16, CX = 12, CY = 4, CZ = 12;
	static final int FINE = FX * FY * FZ, COARSE = CX * CY * CZ, CELLS = 4096;
	static final long TOTAL = (long) (FINE + COARSE) * CELLS;
	private static final int HEADER = 80, LIST_CAP = 3 * (FINE + COARSE) + 64, RING = 6;
	/** Frames a slot keeps spreading after it was last near a coloured light (its light fades out in about 32 steps), then emptied. */
	private static final int LINGER = 48;
	/** Frames between the log lines (mcopt.shade.coloredLights.logEvery; 600 while measuring, ~1 min at 120 fps by default). */
	static final int LOG_EVERY = Math.max(Integer.getInteger("mcopt.shade.coloredLights.logEvery", 7200), 60);
	private static final long NONE = Long.MIN_VALUE;
	private static final long BUDGET_NS = Long.getLong("mcopt.shade.coloredLights.budgetUs", 1200L) * 1000L;

	private static long state, idsAddress, header;
	private static ByteBuffer headerBuf, idsBuf;
	private static boolean failed, fallback;
	private static int slot, frame;
	private static ClientLevel lastLevel;
	private static int fx0 = Integer.MIN_VALUE, fy0, fz0, cx0 = Integer.MIN_VALUE, cy0, cz0;
	private static long levelFrame;
	private static boolean fineSettled, coarseSettled;

	private static final long[] fineKey = new long[FINE];
	/** 0 unread, 1 read, 2 not loaded when last tried. */
	private static final byte[] fineState = new byte[FINE];
	private static final boolean[] fineColored = new boolean[FINE];
	private static final int[] fineLinger = new int[FINE];
	private static final boolean[] fineNear = new boolean[FINE];
	/** (2.0.1 opt) Remaining spread steps until each fine slot is guaranteed converged (0 = converged, skip GPU flood). */
	private static final int[] fineDirty = new int[FINE];
	/** A slot's coloured flag or the windows changed: the near sets are worked out again. */
	private static boolean nearDirty = true;

	private static final long[] coarseKey = new long[COARSE];
	/** Per coarse slot, a bit per real section (4 x 4 x 4) read; of those not loaded; of those with a coloured light. */
	private static final long[] coarseRead = new long[COARSE], coarseUnloaded = new long[COARSE], coarseColored = new long[COARSE];
	private static final int[] coarseLinger = new int[COARSE];
	private static final boolean[] coarseNear = new boolean[COARSE];
	/** (2.0.1 opt) Remaining coarse spread steps until each coarse slot is guaranteed converged (0 = converged, skip GPU flood). */
	private static final int[] coarseDirty = new int[COARSE];
	private static final int COARSE_CONVERGE = 16;

	private static final int[] clears = new int[LIST_CAP];
	private static int clearCount;
	/** Window cells (x, y, z packed by 8 bits) in order of distance from the window's centre. */
	private static final int[] FINE_ORDER = order(FX, FY, FZ), COARSE_ORDER = order(CX, CY, CZ);

	private static final int[] pal = new int[CELLS];
	private static final byte[] fineBuf = new byte[CELLS], coarseBuf = new byte[64];
	private static final short[] palMap = new short[CELLS];
	private static final int[] cellOpaque = new int[64], cellLight = new int[64];
	private static final boolean[] prevFineNear = new boolean[FINE], prevCoarseNear = new boolean[COARSE];
	private static final Map<BlockState, Byte> IDS = new IdentityHashMap<>();
	private static Map<Block, Integer> classes;

	private ColorLights() {
	}

	private static int[] order(int x, int y, int z) {
		Integer[] o = new Integer[x * y * z];
		for (int i = 0; i < o.length; i++) o[i] = i;
		double hx = (x - 1) / 2.0, hy = (y - 1) / 2.0, hz = (z - 1) / 2.0;
		Arrays.sort(o, (a, b) -> Double.compare(d2(a, x, z, hx, hy, hz), d2(b, x, z, hx, hy, hz)));
		int[] r = new int[o.length];
		for (int i = 0; i < r.length; i++) {
			int k = o[i];
			r[i] = (k % x) | (k / (x * z)) << 8 | (k / x % z) << 16;
		}
		return r;
	}

	private static double d2(int k, int x, int z, double hx, double hy, double hz) {
		double dx = k % x - hx, dy = (k / (x * z) - hy) * 2.0, dz = k / x % z - hz; // (vertically closer counts more: the view is level)
		return dx * dx + dy * dy + dz * dz;
	}

	/** Shader source for the kernels' library. */
	static String kernelSource() {
		return "#define SHADE_CL_KERNELS\n" + ShadeMsl.resource("colorlight.metal");
	}

	/** Called from DynLights.init (ShadeBindings.init: before any shaded pipeline draws). */
	static void init(long ctx) {
		if (!ON || state != 0 || failed) return;
		try (MemoryStack stack = MemoryStack.stackPush()) {
			ByteBuffer src = MemoryUtil.memUTF8(kernelSource());
			try {
				long err = stack.nmalloc(1, 4096);
				MemoryUtil.memPutByte(err, (byte) 0);
				state = DynLightNative.clCreate(ctx, MemoryUtil.memAddress(src), FX * 16, FY * 16, FZ * 16, CX * 16, CY * 16, CZ * 16, TOTAL, LIST_CAP, RING, err, 4096);
				if (state == 0) throw new IllegalStateException(MemoryUtil.memUTF8(err));
			} finally {
				MemoryUtil.memFree(src);
			}
			idsAddress = DynLightNative.clIds(state);
			idsBuf = MemoryUtil.memByteBuffer(idsAddress, (int) TOTAL);
			header = MemoryUtil.nmemCalloc(1, HEADER);
			headerBuf = MemoryUtil.memByteBuffer(header, HEADER).order(ByteOrder.nativeOrder());
			DynLightNative.clHeader(state, header);
			Arrays.fill(fineKey, NONE);
			Arrays.fill(coarseKey, NONE);
			// the textures start undefined: every slot emptied with the first frame's work
			for (int s = 0; s < FINE; s++) clear(s, false);
			for (int s = 0; s < COARSE; s++) clear(s, true);
			System.out.println(String.format(java.util.Locale.ROOT, "[mcopt] shade: coloured lights on (%d x %d x %d blocks fine, %d x %d x %d coarse; %.0f MB)",
				FX * 16, FY * 16, FZ * 16, CX * 64, CY * 64, CZ * 64, TOTAL * 5 / 1048576.0)); // (4 bytes a cell of texture, 1 of block id)
		} catch (Throwable e) {
			failed = true;
			state = 0;
			System.out.println("[mcopt] shade: coloured lights failed to start, off: " + e);
			fallback(ctx);
		}
	}

	/** The stand-in bindings (module on in the shaders, but no volume). */
	static void fallback(long ctx) {
		if (!ON || fallback) return;
		try {
			fallback = DynLightNative.clFallback(ctx);
		} catch (Throwable f) {
			System.out.println("[mcopt] shade: coloured lights fallback bindings failed: " + f);
		}
	}

	// ---- block ids -------------------------------------------------------------------------------------------------------

	private static int classOf(Block b) {
		if (classes == null) {
			Map<Block, Integer> m = new IdentityHashMap<>();
			for (Block blk : BuiltInRegistries.BLOCK) {
				String p = BuiltInRegistries.BLOCK.getKey(blk).getPath();
				int c = p.startsWith("soul_") ? 1
					: p.equals("redstone_torch") || p.equals("redstone_wall_torch") || p.equals("redstone_ore") || p.equals("deepslate_redstone_ore") ? 2
					: p.equals("copper_torch") || p.equals("copper_wall_torch") || p.endsWith("copper_lantern") ? 3
					: p.equals("nether_portal") || p.equals("crying_obsidian") || p.endsWith("amethyst_cluster") || p.endsWith("amethyst_bud") || p.equals("respawn_anchor") ? 4
					: p.equals("verdant_froglight") ? 5
					: p.equals("pearlescent_froglight") ? 6
					: p.equals("sea_lantern") || p.equals("conduit") ? 7
					: 0;
				if (c != 0) m.put(blk, c);
			}
			classes = m;
		}
		return classes.getOrDefault(b, 0);
	}

	private static int idOf(BlockState s) {
		Byte c = IDS.get(s);
		if (c != null) return c & 255;
		int id;
		int e = s.getLightEmission();
		if (e > 0) {
			id = 16 + classOf(s.getBlock()) * 16 + Math.min(e, 15);
		} else {
			int d = s.getLightDampening();
			id = d >= 15 ? 15 : Math.max(0, d);
		}
		IDS.put(s, (byte) id);
		return id;
	}

	private static final int LOADED = 1, COLORED = 2;

	/**
	 * Reads world section (sx, sy, sz) into fineBuf (when fine) and coarseBuf (its 4^3 coarse cells, order y, z, x). Returns
	 * LOADED | COLORED, 0 when its chunk isn't loaded.
	 */
	private static int read(ClientLevel level, int sx, int sy, int sz, boolean fine) {
		if (fine) statFine++;
		else statCoarse++;
		LevelChunk chunk = level.getChunkSource().getChunk(sx, sz, ChunkStatus.FULL, false);
		if (chunk == null) return 0;
		int index = sy - level.getMinSectionY();
		LevelChunkSection sec = index >= 0 && index < level.getSectionsCount() ? chunk.getSection(index) : null;
		if (sec == null || sec.hasOnlyAir()) {
			if (fine) Arrays.fill(fineBuf, (byte) 0);
			Arrays.fill(coarseBuf, (byte) 0);
			return LOADED;
		}
		Palette<BlockState> p = OwnPalette.unpack(sec.getStates(), pal);
		int n = p.getSize();
		boolean local = n <= CELLS;
		// (2.0.1 opt) pre-scan palette entries once (O(paletteSize) instead of O(4096) checks) and fast-path single-entry & uniform coarse sections
		if (local && n > 0) {
			boolean anyOpaque = false, anyLight = false, anyNonOpaque = false;
			for (int k = 0; k < n; k++) {
				int id = idOf(p.valueFor(k));
				palMap[k] = (short) id;
				if (id == 15) anyOpaque = true;
				else {
					anyNonOpaque = true;
					if (id >= 16) anyLight = true;
				}
			}
			if (n == 1) {
				int id = palMap[0];
				if (fine) Arrays.fill(fineBuf, (byte) id);
				Arrays.fill(coarseBuf, (byte) (id >= 16 ? id : id == 15 ? 15 : 0));
				return LOADED | (id >= 32 ? COLORED : 0);
			}
			if (!fine) {
				if (!anyOpaque && !anyLight) {
					Arrays.fill(coarseBuf, (byte) 0);
					return LOADED;
				}
				if (!anyNonOpaque) {
					Arrays.fill(coarseBuf, (byte) 15);
					return LOADED;
				}
			}
		}
		Arrays.fill(cellOpaque, 0);
		Arrays.fill(cellLight, 0);
		boolean colored = false;
		for (int i = 0; i < CELLS; i++) {
			int k = pal[i];
			int id = local && k < n ? palMap[k] : idOf(p.valueFor(k));
			if (fine) fineBuf[i] = (byte) id;
			int x = i & 15, z = (i >> 4) & 15, y = i >> 8, c = ((y >> 2) * 4 + (z >> 2)) * 4 + (x >> 2);
			if (id == 15) {
				cellOpaque[c]++;
			} else if (id >= 16) {
				if (((id - 16) & 15) > ((cellLight[c] - 16) & 15) || cellLight[c] == 0) cellLight[c] = id;
				if (id >= 32) colored = true;
			}
		}
		for (int c = 0; c < 64; c++) coarseBuf[c] = (byte) (cellLight[c] != 0 ? cellLight[c] : cellOpaque[c] >= 48 ? 15 : 0);
		return LOADED | (colored ? COLORED : 0);
	}

	// ---- windows -----------------------------------------------------------------------------------------------------------

	private static int mod(int a, int m) {
		int r = a % m;
		return r < 0 ? r + m : r;
	}

	private static long key(int x, int y, int z) {
		return ((long) x & 0x3FFFFFL) << 42 | ((long) z & 0x3FFFFFL) << 20 | ((long) y & 0xFFFFFL);
	}

	private static int fineSlot(int sx, int sy, int sz) {
		if (sx < fx0 || sx >= fx0 + FX || sy < fy0 || sy >= fy0 + FY || sz < fz0 || sz >= fz0 + FZ) return -1;
		return (mod(sy, FY) * FZ + mod(sz, FZ)) * FX + mod(sx, FX);
	}

	private static int coarseSlot(int cx, int cy, int cz) {
		if (cx < cx0 || cx >= cx0 + CX || cy < cy0 || cy >= cy0 + CY || cz < cz0 || cz >= cz0 + CZ) return -1;
		return (mod(cy, CY) * CZ + mod(cz, CZ)) * CX + mod(cx, CX);
	}

	private static void clear(int s, boolean coarse) {
		if (clearCount < clears.length) clears[clearCount++] = coarse ? s | 0x80000000 : s;
	}

	/** (2.0.1 opt) Marks fine slot s and its 26 neighbours as needing up to steps more flood steps to converge. */
	private static void markFine(int s, int steps) {
		if (fx0 == Integer.MIN_VALUE) return;
		int mx = s % FX, mz = (s / FX) % FZ, my = s / (FX * FZ);
		int wx = mod(mx - fx0, FX), wy = mod(my - fy0, FY), wz = mod(mz - fz0, FZ);
		for (int dy = -1; dy <= 1; dy++) for (int dz = -1; dz <= 1; dz++) for (int dx = -1; dx <= 1; dx++) {
			int x = wx + dx, y = wy + dy, z = wz + dz;
			if (x < 0 || x >= FX || y < 0 || y >= FY || z < 0 || z >= FZ) continue;
			int n = fineSlot(fx0 + x, fy0 + y, fz0 + z);
			if (fineDirty[n] < steps) fineDirty[n] = steps;
		}
	}

	/** (2.0.1 opt) Marks coarse slot s and its 26 neighbours as needing up to steps more coarse flood steps to converge. */
	private static void markCoarse(int s, int steps) {
		if (cx0 == Integer.MIN_VALUE) return;
		int mx = s % CX, mz = (s / CX) % CZ, my = s / (CX * CZ);
		int wx = mod(mx - cx0, CX), wy = mod(my - cy0, CY), wz = mod(mz - cz0, CZ);
		for (int dy = -1; dy <= 1; dy++) for (int dz = -1; dz <= 1; dz++) for (int dx = -1; dx <= 1; dx++) {
			int x = wx + dx, y = wy + dy, z = wz + dz;
			if (x < 0 || x >= CX || y < 0 || y >= CY || z < 0 || z >= CZ) continue;
			int n = coarseSlot(cx0 + x, cy0 + y, cz0 + z);
			if (coarseDirty[n] < steps) coarseDirty[n] = steps;
		}
	}

	/** Each slot to the world section the window puts in it; a slot whose section changed is unread and (if it had light) emptied. */
	private static void place(int nfx0, int nfy0, int nfz0, int ncx0, int ncy0, int ncz0) {
		if (nfx0 != fx0 || nfy0 != fy0 || nfz0 != fz0 || ncx0 != cx0 || ncy0 != cy0 || ncz0 != cz0) nearDirty = true;
		if (nfx0 != fx0 || nfy0 != fy0 || nfz0 != fz0) {
			fineSettled = false;
			coarseSettled = false;
			fx0 = nfx0;
			fy0 = nfy0;
			fz0 = nfz0;
			for (int my = 0; my < FY; my++) for (int mz = 0; mz < FZ; mz++) for (int mx = 0; mx < FX; mx++) {
				int s = (my * FZ + mz) * FX + mx;
				int wx = fx0 + mod(mx - fx0, FX), wy = fy0 + mod(my - fy0, FY), wz = fz0 + mod(mz - fz0, FZ);
				long k = key(wx, wy, wz);
				if (k == fineKey[s]) continue;
				if (fineKey[s] != NONE) unreadCoarse(fineKey[s]);
				fineKey[s] = k;
				fineState[s] = 0;
				fineColored[s] = false;
				MemoryUtil.memSet(idsAddress + (long) s * CELLS, 0, CELLS);
				if (fineLinger[s] != 0) clear(s, false);
				fineLinger[s] = 0;
				markFine(s, LINGER);
			}
		}
		if (ncx0 != cx0 || ncy0 != cy0 || ncz0 != cz0) {
			coarseSettled = false;
			cx0 = ncx0;
			cy0 = ncy0;
			cz0 = ncz0;
			for (int my = 0; my < CY; my++) for (int mz = 0; mz < CZ; mz++) for (int mx = 0; mx < CX; mx++) {
				int s = (my * CZ + mz) * CX + mx;
				int wx = cx0 + mod(mx - cx0, CX), wy = cy0 + mod(my - cy0, CY), wz = cz0 + mod(mz - cz0, CZ);
				long k = key(wx, wy, wz);
				if (k == coarseKey[s]) continue;
				coarseKey[s] = k;
				coarseRead[s] = coarseUnloaded[s] = coarseColored[s] = 0L;
				MemoryUtil.memSet(idsAddress + (long) (FINE + s) * CELLS, 0, CELLS);
				if (coarseLinger[s] != 0) clear(s, true);
				coarseLinger[s] = 0;
				markCoarse(s, COARSE_CONVERGE);
			}
		}
	}

	/** A section's coarse cells to be read again (it left the fine window, whose reads wrote them). */
	private static void unreadCoarse(long k) {
		int sx = (int) (k >> 42), sz = (int) (k << 22 >> 42), sy = (int) (k << 44 >> 44);
		int cx = Math.floorDiv(sx, 4), cy = Math.floorDiv(sy, 4), cz = Math.floorDiv(sz, 4);
		int c = coarseSlot(cx, cy, cz);
		if (c >= 0 && coarseKey[c] == key(cx, cy, cz)) coarseRead[c] &= ~(1L << (((sy - cy * 4) * 4 + (sz - cz * 4)) * 4 + (sx - cx * 4)));
	}

	/** Section (sx, sy, sz)'s coarse cells into its coarse slot (if the window holds it), with its read / coloured bits. */
	private static void putCoarse(int sx, int sy, int sz, int flags) {
		int cx = Math.floorDiv(sx, 4), cy = Math.floorDiv(sy, 4), cz = Math.floorDiv(sz, 4);
		int s = coarseSlot(cx, cy, cz);
		if (s < 0) return;
		int rx = sx - cx * 4, ry = sy - cy * 4, rz = sz - cz * 4;
		long bit = 1L << ((ry * 4 + rz) * 4 + rx);
		coarseRead[s] |= bit;
		if ((flags & LOADED) == 0) {
			coarseUnloaded[s] |= bit;
			if (coarseColored[s] != 0L && (coarseColored[s] &= ~bit) == 0L) nearDirty = true;
			return;
		}
		coarseUnloaded[s] &= ~bit;
		long was = coarseColored[s];
		if ((flags & COLORED) != 0) coarseColored[s] |= bit;
		else coarseColored[s] &= ~bit;
		if ((was == 0L) != (coarseColored[s] == 0L)) nearDirty = true;
		long base = idsAddress + (long) (FINE + s) * CELLS;
		for (int c = 0; c < 64; c++) {
			int x = rx * 4 + (c & 3), z = rz * 4 + ((c >> 2) & 3), y = ry * 4 + (c >> 4);
			MemoryUtil.memPutByte(base + (y * 16 + z) * 16 + x, coarseBuf[c]);
		}
		markCoarse(s, COARSE_CONVERGE);
	}

	// ---- changes -----------------------------------------------------------------------------------------------------------

	static void sectionChanged(int sx, int sy, int sz) {
		if (state == 0) return;
		int s = fineSlot(sx, sy, sz);
		if (s >= 0 && fineKey[s] == key(sx, sy, sz)) {
			fineState[s] = 0;
			fineSettled = false;
			markFine(s, LINGER);
		}
		int cx = Math.floorDiv(sx, 4), cy = Math.floorDiv(sy, 4), cz = Math.floorDiv(sz, 4);
		int c = coarseSlot(cx, cy, cz);
		if (c >= 0 && coarseKey[c] == key(cx, cy, cz)) {
			coarseRead[c] &= ~(1L << (((sy - cy * 4) * 4 + (sz - cz * 4)) * 4 + (sx - cx * 4)));
			coarseSettled = false;
			markCoarse(c, COARSE_CONVERGE);
		}
	}

	// ---- the frame ---------------------------------------------------------------------------------------------------------

	/** This frame's reads, slot lists and header, and its spread on enc's frame command buffer (DynLights.frame, before the world). */
	static void frame(long enc, ClientLevel level, double camX, double camY, double camZ) {
		if (state == 0) return;
		boolean on = level != null && Live.b("mcopt.shade.coloredLights", true);
		ByteBuffer h = headerBuf;
		if (!on) {
			h.putInt(12, 0);
			DynLightNative.clHeader(state, header);
			return;
		}
		if (level != lastLevel) {
			// another level: every slot unread (the window's next placement finds them all changed); cells emptied
			lastLevel = level;
			Arrays.fill(fineKey, NONE);
			Arrays.fill(coarseKey, NONE);
			Arrays.fill(fineDirty, 0);
			Arrays.fill(coarseDirty, 0);
			fx0 = cx0 = Integer.MIN_VALUE;
			fineSettled = coarseSettled = false;
			for (int s = 0; s < FINE; s++) if (fineLinger[s] != 0) clear(s, false);
			for (int s = 0; s < COARSE; s++) if (coarseLinger[s] != 0) clear(s, true);
			levelFrame = frame;
		}
		frame++;
		int bx = (int) Math.floor(camX), by = (int) Math.floor(camY), bz = (int) Math.floor(camZ);
		place((bx >> 4) - FX / 2, (by >> 4) - FY / 2, (bz >> 4) - FZ / 2, Math.floorDiv(bx, 64) - CX / 2, Math.floorDiv(by, 64) - CY / 2, Math.floorDiv(bz, 64) - CZ / 2);

		// reads: the fine window nearest first, then the coarse window's sections past it (within the render distance)
		long t0 = System.nanoTime(), end = t0 + (frame - levelFrame < 240 ? 3 * BUDGET_NS : BUDGET_NS);
		boolean retry = frame % 60 == 0;
		if (!fineSettled || retry) {
			boolean budgetHit = false;
			for (int o : FINE_ORDER) {
				int sx = fx0 + (o & 255), sy = fy0 + ((o >> 8) & 255), sz = fz0 + (o >> 16);
				int s = fineSlot(sx, sy, sz);
				if (fineState[s] == 1 || fineState[s] == 2 && !retry) continue;
				if (System.nanoTime() > end) {
					budgetHit = true;
					break;
				}
				int f = read(level, sx, sy, sz, true);
				boolean was = fineColored[s];
				if ((f & LOADED) != 0) {
					idsBuf.put(s * CELLS, fineBuf);
					fineState[s] = 1;
					fineColored[s] = (f & COLORED) != 0;
					markFine(s, LINGER);
				} else {
					fineState[s] = 2;
					fineColored[s] = false;
				}
				if (was != fineColored[s]) nearDirty = true;
				putCoarse(sx, sy, sz, f);
			}
			if (!budgetHit) fineSettled = true;
		}
		if (!coarseSettled || retry) {
			int rd = Minecraft.getInstance().options.getEffectiveRenderDistance() + 1;
			int csx = bx >> 4, csz = bz >> 4;
			boolean budgetHit = false;
			for (int o : COARSE_ORDER) {
				if (System.nanoTime() > end) {
					budgetHit = true;
					break;
				}
				int cx = cx0 + (o & 255), cy = cy0 + ((o >> 8) & 255), cz = cz0 + (o >> 16);
				int s = coarseSlot(cx, cy, cz);
				if (retry) {
					coarseRead[s] &= ~coarseUnloaded[s];
					coarseUnloaded[s] = 0L;
				}
				long missing = ~coarseRead[s];
				while (missing != 0L) {
					if (System.nanoTime() > end) {
						budgetHit = true;
						break;
					}
					int b = Long.numberOfTrailingZeros(missing);
					missing &= missing - 1;
					int sx = cx * 4 + (b & 3), sz = cz * 4 + ((b >> 2) & 3), sy = cy * 4 + (b >> 4);
					if (fineSlot(sx, sy, sz) >= 0) { // (the fine read writes its coarse cells; unreadCoarse when it leaves the fine window)
						coarseRead[s] |= 1L << b;
						continue;
					}
					if (Math.max(Math.abs(sx - csx), Math.abs(sz - csz)) > rd) {
						putCoarse(sx, sy, sz, 0); // (beyond the render distance: never loaded, asked again on a retry)
						continue;
					}
					putCoarse(sx, sy, sz, read(level, sx, sy, sz, false));
				}
				if (budgetHit) break;
			}
			if (!budgetHit) coarseSettled = true;
		}

		// what spreads: the slots within a section of a coloured light, and a while after; then emptied
		long t1 = System.nanoTime();
		statRead += t1 - t0;
		if (nearDirty) {
			near();
			statNear++;
		}
		emit(enc, h, t0);
	}

	private static void near() {
		nearDirty = false;
		System.arraycopy(fineNear, 0, prevFineNear, 0, FINE);
		Arrays.fill(fineNear, false);
		for (int s = 0; s < FINE; s++) {
			if (!fineColored[s]) continue;
			int mx = s % FX, mz = (s / FX) % FZ, my = s / (FX * FZ);
			int wx = mod(mx - fx0, FX), wy = mod(my - fy0, FY), wz = mod(mz - fz0, FZ); // window coordinates
			for (int dy = -1; dy <= 1; dy++) for (int dz = -1; dz <= 1; dz++) for (int dx = -1; dx <= 1; dx++) {
				int x = wx + dx, y = wy + dy, z = wz + dz;
				if (x < 0 || x >= FX || y < 0 || y >= FY || z < 0 || z >= FZ) continue;
				fineNear[fineSlot(fx0 + x, fy0 + y, fz0 + z)] = true;
			}
		}
		for (int s = 0; s < FINE; s++) if (fineNear[s] != prevFineNear[s]) markFine(s, LINGER);
		System.arraycopy(coarseNear, 0, prevCoarseNear, 0, COARSE);
		Arrays.fill(coarseNear, false);
		for (int s = 0; s < COARSE; s++) {
			long bits = coarseColored[s];
			if (bits == 0L) continue;
			int mx = s % CX, mz = (s / CX) % CZ, my = s / (CX * CZ);
			int wx = mod(mx - cx0, CX), wy = mod(my - cy0, CY), wz = mod(mz - cz0, CZ);
			coarseNear[s] = true;
			// a coloured light reaches ~4 coarse cells: into a neighbouring coarse section only from a section on that side's border
			int lo = 0, hi = 0; // per axis bit 0 x, 1 y, 2 z: some coloured section on the low / high border
			for (long b = bits; b != 0L; b &= b - 1) {
				int i = Long.numberOfTrailingZeros(b), rx = i & 3, rz = (i >> 2) & 3, ry = i >> 4;
				lo |= (rx == 0 ? 1 : 0) | (ry == 0 ? 2 : 0) | (rz == 0 ? 4 : 0);
				hi |= (rx == 3 ? 1 : 0) | (ry == 3 ? 2 : 0) | (rz == 3 ? 4 : 0);
			}
			for (int dy = -1; dy <= 1; dy++) for (int dz = -1; dz <= 1; dz++) for (int dx = -1; dx <= 1; dx++) {
				if (dx < 0 && (lo & 1) == 0 || dx > 0 && (hi & 1) == 0 || dy < 0 && (lo & 2) == 0 || dy > 0 && (hi & 2) == 0
					|| dz < 0 && (lo & 4) == 0 || dz > 0 && (hi & 4) == 0) continue;
				int x = wx + dx, y = wy + dy, z = wz + dz;
				if (x < 0 || x >= CX || y < 0 || y >= CY || z < 0 || z >= CZ) continue;
				coarseNear[coarseSlot(cx0 + x, cy0 + y, cz0 + z)] = true;
			}
		}
		for (int s = 0; s < COARSE; s++) if (coarseNear[s] != prevCoarseNear[s]) markCoarse(s, COARSE_CONVERGE);
	}

	private static void emit(long enc, ByteBuffer h, long t0) {
		slot = (slot + 1) % RING;
		long list = DynLightNative.clList(state, slot);
		int n = 0;
		for (int i = 0; i < clearCount; i++) MemoryUtil.memPutInt(list + 4L * n++, clears[i]);
		int nClear = n;
		clearCount = 0;
		boolean spread = Live.b("mcopt.shade.coloredLights.spread", true);
		boolean converge = Live.b("mcopt.shade.coloredLights.converge", true);
		boolean coarseStep = spread && (frame & 1) == 0;
		int activeFine = 0, activeCoarse = 0;
		for (int s = 0; s < FINE; s++) {
			if (fineNear[s]) fineLinger[s] = frame;
			else if (fineLinger[s] != 0 && frame - fineLinger[s] >= LINGER) {
				fineLinger[s] = 0;
				fineDirty[s] = 0;
				clear(s, false); // (next frame's list)
			}
			if (fineLinger[s] != 0) {
				activeFine++;
				if (!converge || fineDirty[s] > 0) {
					MemoryUtil.memPutInt(list + 4L * n++, s);
					if (spread && fineDirty[s] > 0) fineDirty[s]--;
				}
			}
		}
		int nFine = n - nClear;
		for (int s = 0; s < COARSE; s++) {
			if (coarseNear[s]) coarseLinger[s] = frame;
			else if (coarseLinger[s] != 0 && frame - coarseLinger[s] >= LINGER) {
				coarseLinger[s] = 0;
				coarseDirty[s] = 0;
				clear(s, true);
			}
			if (coarseLinger[s] != 0) {
				activeCoarse++;
				if (!converge || coarseDirty[s] > 0) {
					MemoryUtil.memPutInt(list + 4L * n++, s | 0x80000000);
					if (coarseStep && coarseDirty[s] > 0) coarseDirty[s]--;
				}
			}
		}
		int nCoarse = n - nClear - nFine;

		// (2.0.1 opt) fineMin.w = 0 when zero coloured lights exist anywhere in either window: skips all per-vertex 3D texture reads!
		// fineDim.w / coarseDim.w signal per-cascade activity so fine-only worlds skip coarse 3D fetches too.
		h.putInt(0, fx0).putInt(4, fy0).putInt(8, fz0).putInt(12, (activeFine > 0 || activeCoarse > 0) ? 1 : 0);
		h.putInt(16, FX).putInt(20, FY).putInt(24, FZ).putInt(28, activeFine > 0 ? 1 : 0);
		h.putInt(32, cx0).putInt(36, cy0).putInt(40, cz0).putInt(44, FINE * CELLS);
		h.putInt(48, CX).putInt(52, CY).putInt(56, CZ).putInt(60, activeCoarse > 0 ? 1 : 0);
		h.putFloat(64, Live.f("mcopt.shade.coloredLights.strength", 1f, 0f, 1f)).putFloat(68, Live.f("mcopt.shade.coloredLights.glow", 1f, 0f, 3f))
			.putFloat(72, 16f).putFloat(76, 0f);
		DynLightNative.clHeader(state, header);
		DynLightNative.clFrame(enc, state, slot, nClear, spread ? nFine : 0, coarseStep ? nCoarse : 0, 1);
		cpuNanos = System.nanoTime() - t0;
		lastFine = nFine;
		lastCoarse = nCoarse;
		statCpu += cpuNanos;
		if (frame % LOG_EVERY == 0) {
			System.out.println(String.format(java.util.Locale.ROOT,
				"[mcopt] shade: coloured lights: %d fine and %d coarse slots spreading, last %d frames: cpu %.3f ms a frame (reads %.3f), %d fine and %d coarse reads, near sets %d",
				nFine, nCoarse, LOG_EVERY, statCpu / (LOG_EVERY * 1e6), statRead / (LOG_EVERY * 1e6), statFine, statCoarse, statNear));
			statCpu = statRead = 0;
			statFine = statCoarse = statNear = 0;
		}
	}

	private static long cpuNanos, statCpu, statRead;
	private static int statFine, statCoarse, statNear;
	private static int lastFine, lastCoarse;
}
