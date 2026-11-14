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
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Iterator;
import java.util.Map;
import mcopt.metal.shade.Shade;
import mcopt.metal.shade.ShadeMsl;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.client.player.LocalPlayer;
import net.minecraft.client.renderer.state.level.CameraRenderState;
import net.minecraft.core.BlockPos;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.HumanoidArm;
import net.minecraft.world.entity.LightningBolt;
import net.minecraft.world.entity.LivingEntity;
import net.minecraft.world.entity.animal.squid.GlowSquid;
import net.minecraft.world.entity.boss.enderdragon.EndCrystal;
import net.minecraft.world.entity.decoration.ItemFrame;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.entity.item.PrimedTnt;
import net.minecraft.world.entity.monster.Blaze;
import net.minecraft.world.entity.monster.cubemob.MagmaCube;
import net.minecraft.world.entity.projectile.FireworkRocketEntity;
import net.minecraft.world.entity.projectile.arrow.SpectralArrow;
import net.minecraft.world.entity.projectile.hurtingprojectile.DragonFireball;
import net.minecraft.world.entity.projectile.hurtingprojectile.LargeFireball;
import net.minecraft.world.entity.projectile.hurtingprojectile.SmallFireball;
import net.minecraft.world.entity.vehicle.minecart.AbstractMinecart;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.phys.Vec3;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.system.MemoryUtil;

/**
 * Dynamic lights (M3): what moves and glows lights its surroundings in real time — the torch in the player's hand (either
 * hand), other players and mobs holding luminous items, dropped luminous items, burning mobs, blazes, magma cubes, glow
 * squid, fire and spectral arrows, fireballs, lit TNT, furnace minecarts, fireworks, lightning (dynlight.metal has the
 * shading model and bindings, DYNLIGHTS.md the integration).
 *
 * <p>Per frame, at LevelRenderer.render HEAD (ShadeFrameUpdater, after the frame's globals are published): gather the
 * sources within {@link DynLightConfig#RANGE} blocks, fade each in and out (keyed by entity and hand), flicker fire, keep
 * the {@link DynLightConfig#MAX} strongest (the local player's hands first), give the nearest ones a visibility volume,
 * write lights + the light grid into this frame's ring slot (buffer 24), refresh the block occupancy and encode the
 * visibility kernel before the world passes. Render thread only.
 */
public final class DynLights {
	/** The module is compiled into the shaders and bound (static final: off, every hook is dead code). */
	public static final boolean ON = DynLightConfig.ENABLED;
	/** This frame's light count (0: the terrain can take its lean variant without dynamic-light code, ShadeLean). */
	private static volatile int lastCount;

	public static int activeCount() {
		return lastCount;
	}
	/** The local player's packed light follows what it holds (DynLightEntityRendererMixin); at startup, see {@link #handLight}. */
	public static final boolean HAND_LIGHT = ON && DynLightConfig.HAND;

	/** (1.1) live: HAND_LIGHT with mcopt.shade.dynLights.hand read now (the mixin is applied whenever the module is on). */
	public static boolean handLight() {
		return ON && DynLightConfig.hand();
	}
	static final int MAX = 64, GRID_X = 16, GRID_Y = 12, GRID_Z = 16, CELL = 8;
	/** Blocks short of its reach where a light stops (dynlight.metal SHADE_DL_CUT). */
	static final double CUT = 2.0;
	/** The irradiance volume (dynlight.metal SHADE_DL_IRR_*): blocks around the camera, one voxel each. */
	static final int IRR_X = 96, IRR_Y = 64, IRR_Z = 96;
	/** ShadeDynLights (dynlight.metal): header 64 + lights 64 x 64 (FT2.9: + shape) + cells 3072 x 8. */
	static final int LIGHT_BYTES = 64, LIGHTS_OFFSET = 64, CELLS_OFFSET = LIGHTS_OFFSET + MAX * LIGHT_BYTES, BYTES = CELLS_OFFSET + GRID_X * GRID_Y * GRID_Z * 8;
	/**
	 * Ring slots of the light buffer and of the occupancy copies: more than the frames that can be in flight
	 * (-Dmcopt.metal.inFlight, 2 by default) plus the one being written; mcdynlight.m holds at most 8.
	 */
	static final int RING = Math.max(4, Math.min(8, Integer.getInteger("mcopt.metal.inFlight", 2) + 2));
	private static final int VIS_PARAMS = 16 + 64 * 32;
	/** Fade time constants (s): quick to light up, a little slower to go out. */
	private static final float TAU_IN = 0.06f, TAU_OUT = 0.18f;

	private static long state;
	private static boolean failed, fallback;
	/** The occupancy's CPU bits and the generation last copied to the GPU. */
	private static long occAddress;
	private static int occUploaded = Integer.MIN_VALUE;
	private static final ByteBuffer[] ring = new ByteBuffer[RING];
	private static int slot;
	private static Occupancy occupancy;
	/**
	 * The voxels of the irradiance volume that may hold light (texture coordinates, min xyz then max xyz; empty: min > max).
	 * Starts as the whole volume: the first dispatch clears whatever a new texture holds.
	 */
	private static final int[] irrBox = {0, 0, 0, IRR_X - 1, IRR_Y - 1, IRR_Z - 1};
	private static int irrVoxels;
	private static long visParams;
	/** (FT2.11) the native side has the flood fill's pipelines (shade_dl_flood): mcopt.shade.dynLights.soft can be honoured. */
	private static boolean flood;
	private static final Map<Long, Src> SOURCES = new HashMap<>();
	private static final ArrayList<Src> ACTIVE = new ArrayList<>();
	private static final long[] cells = new long[GRID_X * GRID_Y * GRID_Z];
	private static long lastNanos, lastLog;
	private static int frame;
	private static float time;
	private static double camX, camY, camZ;
	/** The local player's hand light this frame (absolute world position, reach, rgb tint x intensity) for the CPU query. */
	private static int volumesLastFrame, volumesComputed;
	private static long cpuNanos;

	/** One light source, keyed by entity id and kind (hands, fire, body, item). */
	static final class Src {
		final long key;
		double x, y, z;
		float reach, r, g, b, spec;
		/** (FT2.9) core radius (blocks) and omnidirectional (the player's own light): dynlight.metal ShadeDynLight.shape. */
		float core = 0.75f;
		boolean omni;
		boolean fire, seen, hand, selected;
		float cur, target, seed, score;
		int slab = -1, volGen;
		boolean wantVolume;
		/** (FT2.11) its slab holds the flood fill's detour (shade_dl_flood) rather than rays' 0/1: ShadeDynLight.shape.z. */
		boolean volSoft;
		double volX, volY, volZ;
		float volReach;

		Src(long key) {
			this.key = key;
			this.seed = (float) ((key * 0x9E3779B97F4A7C15L >>> 40) & 0xFFFF) / 6553.6f;
		}
	}

	private DynLights() {
	}

	/** Binds this frame's lights and the visibility volumes (ShadeBindings.bind / rebind). */
	public static void bind(long enc) {
		if (state != 0 || fallback) DynLightNative.bind(enc);
	}

	/**
	 * Creates the buffers, the occupancy and the visibility kernel (ShadeBindings.init, so the bindings exist before any shaded
	 * pipeline draws). False when it failed (logged once).
	 */
	public static boolean init(long ctx) {
		if (state != 0) return true;
		if (failed) return false;
		try (MemoryStack stack = MemoryStack.stackPush()) {
			ByteBuffer src = MemoryUtil.memUTF8(DynLightConfig.source());
			try {
				long err = stack.nmalloc(1, 4096);
				MemoryUtil.memPutByte(err, (byte) 0);
				long t0 = mcopt.metal.shade.ShadeCompile.now();
				state = DynLightNative.create(ctx, MemoryUtil.memAddress(src), BYTES, RING, Math.max(1, DynLightConfig.VOLUMES), Occupancy.BYTES, IRR_X, IRR_Y, IRR_Z, err, 4096);
				mcopt.metal.shade.ShadeCompile.setup("dynamic lights", t0);
				if (state == 0) throw new IllegalStateException(MemoryUtil.memUTF8(err));
				flood = DynLightNative.hasFlood(state);
				if (!flood) System.out.println("[mcopt] shade: dynamic lights: no flood fill pipeline, rays only (mcopt.shade.dynLights.soft has no effect)");
			} finally {
				MemoryUtil.memFree(src);
			}
			for (int i = 0; i < RING; i++) ring[i] = MemoryUtil.memByteBuffer(DynLightNative.contents(state, i), BYTES).order(ByteOrder.LITTLE_ENDIAN);
			occAddress = MemoryUtil.nmemCalloc(1, Occupancy.BYTES);
			occupancy = new Occupancy(MemoryUtil.memByteBuffer(occAddress, Occupancy.BYTES).order(ByteOrder.LITTLE_ENDIAN).asIntBuffer());
			visParams = MemoryUtil.nmemCalloc(1, VIS_PARAMS);
			System.out.println("[mcopt] shade: dynamic lights on (" + DynLightConfig.describe() + ")");
			return true;
		} catch (Throwable e) {
			failed = true;
			state = 0;
			System.out.println("[mcopt] shade: dynamic lights failed to start, off: " + e);
			e.printStackTrace();
			// the shaders still declare the module's slots: bind zeroed stand-ins (no lights) rather than nothing
			try {
				fallback = DynLightNative.fallback(ctx, BYTES);
			} catch (Throwable f) {
				System.out.println("[mcopt] shade: dynamic lights fallback bindings failed too: " + f);
			}
			return false;
		}
	}

	// ---- the CPU side of a frame ----------------------------------------------------------------------------------------

	/**
	 * This frame's lights: gather, fade, pick, pack into the next ring slot (bound from now on), refresh the occupancy and
	 * encode the visibility volumes (enc's frame command buffer, before the world passes).
	 */
	public static void frame(long ctx, long enc, CameraRenderState camera, ClientLevel level, float partial) {
		if (!init(ctx)) return;
		long t0 = System.nanoTime();
		float dt = lastNanos == 0 ? 0f : Math.min((t0 - lastNanos) / 1e9f, 0.25f);
		lastNanos = t0;
		time = (time + dt) % 4096f;
		frame++;
		camX = camera.pos.x;
		camY = camera.pos.y;
		camZ = camera.pos.z;
		slot = (slot + 1) % RING;
		DynLightNative.slot(state, slot);
		ByteBuffer b = ring[slot];

		if (occupancy != null && DynLightConfig.OCCLUSION) occupancy.update(level, camX, camY, camZ, DynLightConfig.OCC_BUDGET_US * 1000L);
		for (Src s : SOURCES.values()) s.seen = false;
		if (level != null) gather(level, camera, partial);
		// fade: toward 1 while seen, toward 0 once gone; drop what has faded out
		float kin = dt <= 0f ? 1f : 1f - (float) Math.exp(-dt / TAU_IN), kout = dt <= 0f ? 1f : 1f - (float) Math.exp(-dt / TAU_OUT);
		ACTIVE.clear();
		for (Iterator<Src> it = SOURCES.values().iterator(); it.hasNext();) {
			Src s = it.next();
			s.target = s.seen ? 1f : 0f;
			s.cur += (s.target - s.cur) * (s.target > s.cur ? kin : kout);
			if (!s.seen && s.cur < 0.01f) {
				freeSlab(s);
				it.remove();
				continue;
			}
			double dx = s.x - camX, dy = s.y - camY, dz = s.z - camZ;
			// rank by what the light is (a visible one at full weight even while it fades in), with hysteresis: lights already
			// in the list (x1.15) and those holding a visibility slab (x1.15 more) keep their place against a near tie, so
			// lights around the 64-light or 16-slab cut don't flip in and out (or between occluded and not) as the camera moves
			s.score = (s.seen ? 1f : s.cur) * s.reach / (1f + (float) (dx * dx + dy * dy + dz * dz) / 256f) * (s.selected ? 1.15f : 1f)
				* (s.slab >= 0 ? 1.15f : 1f) + (s.hand ? 1000f : 0f);
			s.wantVolume = false;
			ACTIVE.add(s);
		}
		ACTIVE.sort((p, q) -> Float.compare(q.score, p.score));
		// -Dmcopt.shade.dynLights.pause (read every frame; the bench sets it at run time for an A/B in one session): no lights
		if (Boolean.getBoolean("mcopt.shade.dynLights.pause")) ACTIVE.clear();
		int count = Math.min(ACTIVE.size(), DynLightConfig.max()); // (1.1) live cap
		lastCount = count;
		for (int i = 0; i < ACTIVE.size(); i++) {
			Src s = ACTIVE.get(i);
			s.selected = i < count;
			if (!s.selected) s.cur = 0f; // left out (past the cap): fades in again when it makes the list, no pop at full strength
		}

		// visibility volumes: the strongest lights near enough for the occupancy window keep a slab of the 3D texture while
		// they stay selected; a slab is recomputed only when its light moved, changed reach or the occupancy changed.
		// (FT2.11, both read every frame) -Dmcopt.shade.dynLights.playerShadows (false): the player's own light (at the eye: the
		// camera sees nothing it doesn't reach) gets no volume, no shadows at all, as in Photon, Complementary and BSL (Gael
		// 2026-10-11: hard shadows and a sudden step from shadow to light around his torch); true = FT2.10. -Dmcopt.shade.dynLights.soft
		// (true): the volumes hold the detour light takes around what stands in its way (it bends around corners and fades behind
		// them, like a placed torch's); false = FT2.10's rays.
		boolean playerShadows = Boolean.parseBoolean(System.getProperty("mcopt.shade.dynLights.playerShadows", "false").trim());
		boolean soft = flood && !"false".equalsIgnoreCase(System.getProperty("mcopt.shade.dynLights.soft", "true").trim());
		int volumes = 0, dirty = 0;
		if (DynLightConfig.OCCLUSION && occupancy != null) {
			int gen = occupancy.generation;
			for (int i = 0; i < ACTIVE.size(); i++) {
				Src s = ACTIVE.get(i);
				boolean want = false;
				// lightning and other wide flashes: open sky anyway
				if (i < count && volumes < DynLightConfig.VOLUMES && s.reach <= 16f && (playerShadows || !s.omni)) {
					double dx = s.x - camX, dy = s.y - camY, dz = s.z - camZ;
					want = Math.abs(dx) <= DynLightConfig.VOLUME_RANGE && Math.abs(dy) <= DynLightConfig.VOLUME_RANGE && Math.abs(dz) <= DynLightConfig.VOLUME_RANGE;
				}
				if (want) volumes++;
				else freeSlab(s);
				s.wantVolume = want;
			}
			for (int i = 0; i < count; i++) {
				Src s = ACTIVE.get(i);
				if (!s.wantVolume) continue;
				boolean fresh = false;
				if (s.slab < 0) {
					s.slab = allocSlab();
					fresh = true;
				}
				if (s.slab < 0) continue;
				if (!fresh && s.volReach == s.reach && s.volSoft == soft && Math.abs(s.volX - s.x) < 0.04 && Math.abs(s.volY - s.y) < 0.04
					&& Math.abs(s.volZ - s.z) < 0.04 && (s.volGen == gen || !occupancy.changedSince(s.x, s.y, s.z, s.reach, s.volGen))) {
					s.volGen = gen; // nothing it reaches changed: keep the slab
					continue;
				}
				int ox = (int) Math.floor(s.x) - 16, oy = (int) Math.floor(s.y) - 16, oz = (int) Math.floor(s.z) - 16;
				long p = visParams + 16 + dirty * 32L;
				MemoryUtil.memPutInt(p, ox);
				MemoryUtil.memPutInt(p + 4, oy);
				MemoryUtil.memPutInt(p + 8, oz);
				MemoryUtil.memPutInt(p + 12, s.slab);
				MemoryUtil.memPutFloat(p + 16, (float) (s.x - ox));
				MemoryUtil.memPutFloat(p + 20, (float) (s.y - oy));
				MemoryUtil.memPutFloat(p + 24, (float) (s.z - oz));
				MemoryUtil.memPutFloat(p + 28, s.reach);
				s.volX = s.x;
				s.volY = s.y;
				s.volZ = s.z;
				s.volReach = s.reach;
				s.volSoft = soft;
				s.volGen = gen;
				dirty++;
			}
		}
		MemoryUtil.memPutInt(visParams, dirty);
		MemoryUtil.memPutInt(visParams + 4, soft ? 1 : 0); // DlVisParams.info.y: the flood fill (FT2.11)
		volumesLastFrame = volumes;
		volumesComputed = dirty;

		// header
		int gx0 = Math.floorDiv((int) Math.floor(camX) + 4, CELL) * CELL - GRID_X * CELL / 2;
		int gy0 = Math.floorDiv((int) Math.floor(camY) + 4, CELL) * CELL - GRID_Y * CELL / 2;
		int gz0 = Math.floorDiv((int) Math.floor(camZ) + 4, CELL) * CELL - GRID_Z * CELL / 2;
		b.putInt(0, count).putInt(4, volumes).putInt(8, frame).putInt(12, 0);
		b.putFloat(16, (float) (gx0 - camX)).putFloat(20, (float) (gy0 - camY)).putFloat(24, (float) (gz0 - camZ)).putFloat(28, 1f / CELL);
		// (1.1) strength, spec and entity live
		b.putFloat(32, Math.max(1, DynLightConfig.VOLUMES)).putFloat(36, DynLightConfig.strength()).putFloat(40, DynLightConfig.spec()).putFloat(44, DynLightConfig.entity());
		int ix0 = (int) Math.floor(camX) - IRR_X / 2, iy0 = (int) Math.floor(camY) - IRR_Y / 2, iz0 = (int) Math.floor(camZ) - IRR_Z / 2;
		b.putFloat(48, (float) (ix0 - camX)).putFloat(52, (float) (iy0 - camY)).putFloat(56, (float) (iz0 - camZ)).putFloat(60, count > 0 ? 1f : 0f);
		// lights + grid
		java.util.Arrays.fill(cells, 0L);
		boolean flickers = DynLightConfig.flicker(); // (1.1) live
		for (int i = 0; i < count; i++) {
			Src s = ACTIVE.get(i);
			float flick = s.fire && flickers ? flicker(s.seed) : 1f;
			float k = s.cur * flick;
			int at = LIGHTS_OFFSET + i * LIGHT_BYTES;
			b.putFloat(at + 48, s.core).putFloat(at + 52, s.omni ? 1f : 0f).putFloat(at + 56, s.slab >= 0 && s.volSoft ? 1f : 0f).putFloat(at + 60, 0f);
			float rx = (float) (s.x - camX), ry = (float) (s.y - camY), rz = (float) (s.z - camZ);
			b.putFloat(at, rx).putFloat(at + 4, ry).putFloat(at + 8, rz).putFloat(at + 12, s.reach);
			b.putFloat(at + 16, s.r * k).putFloat(at + 20, s.g * k).putFloat(at + 24, s.b * k).putFloat(at + 28, s.spec);
			if (s.slab >= 0) {
				// (FT2.8, audit idx 76) the origin the slab was BUILT with (vol*: a light that moved under 0.04 keeps its slab, and a
				// block line crossed in between shifted every lookup by a block: the wall's occlusion one block off)
				int ox = (int) Math.floor(s.volX) - 16, oy = (int) Math.floor(s.volY) - 16, oz = (int) Math.floor(s.volZ) - 16;
				b.putFloat(at + 32, (float) (ox - camX)).putFloat(at + 36, (float) (oy - camY)).putFloat(at + 40, (float) (oz - camZ)).putFloat(at + 44, s.slab);
			} else {
				b.putFloat(at + 32, 0f).putFloat(at + 36, 0f).putFloat(at + 40, 0f).putFloat(at + 44, -1f);
			}
			// cells the light's sphere reaches (radius: the reach less the shader's cut, SHADE_DL_CUT), corners of its box dropped
			double rr = Math.max(s.reach - CUT, 0.5), rr2 = rr * rr;
			int x0 = clamp((int) Math.floor((s.x - rr - gx0) / CELL), GRID_X), x1 = clamp((int) Math.floor((s.x + rr - gx0) / CELL), GRID_X);
			int y0 = clamp((int) Math.floor((s.y - rr - gy0) / CELL), GRID_Y), y1 = clamp((int) Math.floor((s.y + rr - gy0) / CELL), GRID_Y);
			int z0 = clamp((int) Math.floor((s.z - rr - gz0) / CELL), GRID_Z), z1 = clamp((int) Math.floor((s.z + rr - gz0) / CELL), GRID_Z);
			if (x0 < 0 || y0 < 0 || z0 < 0) continue;
			long bit = 1L << i;
			for (int y = y0; y <= y1; y++) {
				double cy = Math.max(gy0 + y * CELL, Math.min(s.y, gy0 + (y + 1) * CELL)) - s.y;
				for (int z = z0; z <= z1; z++) {
					double cz = Math.max(gz0 + z * CELL, Math.min(s.z, gz0 + (z + 1) * CELL)) - s.z;
					for (int x = x0; x <= x1; x++) {
						double cx = Math.max(gx0 + x * CELL, Math.min(s.x, gx0 + (x + 1) * CELL)) - s.x;
						if (cx * cx + cy * cy + cz * cz <= rr2) cells[(y * GRID_Z + z) * GRID_X + x] |= bit;
					}
				}
			}
		}
		b.position(CELLS_OFFSET);
		b.asLongBuffer().put(cells);
		b.position(0);
		// lights that fall off the list keep the cells' bits clear; unused light slots are never named by a cell
		if (dirty > 0) {
			if (occupancy.generation != occUploaded) { // the bits changed since the copy the GPU has: a fresh ring slot
				DynLightNative.occupancy(state, occAddress);
				occUploaded = occupancy.generation;
			}
			DynLightNative.vis(enc, state, visParams, VIS_PARAMS, dirty);
		}
		if (count > 0) { // the terrain's irradiance volume from these lights and slabs, only where they reach (+ last frame's box)
			int bx0 = IRR_X, by0 = IRR_Y, bz0 = IRR_Z, bx1 = -1, by1 = -1, bz1 = -1;
			for (int i = 0; i < count; i++) {
				Src s = ACTIVE.get(i);
				double rr = s.reach - CUT + 1.0, lx = s.x - ix0 - 0.5, ly = s.y - iy0 - 0.5, lz = s.z - iz0 - 0.5;
				if (rr <= 0) continue;
				int ax = Math.max(0, (int) Math.floor(lx - rr)), ay = Math.max(0, (int) Math.floor(ly - rr)), az = Math.max(0, (int) Math.floor(lz - rr));
				int cx = Math.min(IRR_X - 1, (int) Math.ceil(lx + rr)), cy = Math.min(IRR_Y - 1, (int) Math.ceil(ly + rr)), cz = Math.min(IRR_Z - 1, (int) Math.ceil(lz + rr));
				if (ax > cx || ay > cy || az > cz) continue;
				bx0 = Math.min(bx0, ax); by0 = Math.min(by0, ay); bz0 = Math.min(bz0, az);
				bx1 = Math.max(bx1, cx); by1 = Math.max(by1, cy); bz1 = Math.max(bz1, cz);
			}
			int ux0 = Math.min(bx0, irrBox[0]), uy0 = Math.min(by0, irrBox[1]), uz0 = Math.min(bz0, irrBox[2]);
			int ux1 = Math.max(bx1, irrBox[3]), uy1 = Math.max(by1, irrBox[4]), uz1 = Math.max(bz1, irrBox[5]);
			if (ux1 >= ux0 && uy1 >= uy0 && uz1 >= uz0) DynLightNative.irr(enc, state, ux0, uy0, uz0, ux1 - ux0 + 1, uy1 - uy0 + 1, uz1 - uz0 + 1);
			irrBox[0] = bx0; irrBox[1] = by0; irrBox[2] = bz0; irrBox[3] = bx1; irrBox[4] = by1; irrBox[5] = bz1;
			irrVoxels = ux1 >= ux0 ? (ux1 - ux0 + 1) * (uy1 - uy0 + 1) * (uz1 - uz0 + 1) : 0;
		}
		cpuNanos = System.nanoTime() - t0;
		if (DynLightConfig.LOG && t0 - lastLog > 2_000_000_000L) {
			lastLog = t0;
			System.out.println(String.format(java.util.Locale.ROOT, "[mcopt] shade: dynamic lights %d (of %d sources), %d volumes (%d computed), %d irradiance voxels, cpu %.3f ms (occupancy %.3f ms, %d sections filled, %d waiting)",
				count, SOURCES.size(), volumes, volumesComputed, irrVoxels, cpuNanos / 1e6, occupancy == null ? 0 : occupancy.nanosLastFrame / 1e6, occupancy == null ? 0 : occupancy.filledLastFrame,
				occupancy == null ? 0 : occupancy.pending));
		}
	}

	private static final boolean[] SLAB_USED = new boolean[Math.max(1, DynLightConfig.VOLUMES)];

	private static int allocSlab() {
		for (int i = 0; i < DynLightConfig.VOLUMES; i++) {
			if (!SLAB_USED[i]) {
				SLAB_USED[i] = true;
				return i;
			}
		}
		return -1;
	}

	private static void freeSlab(Src s) {
		if (s.slab >= 0) SLAB_USED[s.slab] = false;
		s.slab = -1;
	}

	/** -1 below the grid (the light is skipped), else the cell index clamped to n - 1. */
	private static int clamp(int c, int n) {
		return c < -64 ? -1 : Math.max(0, Math.min(n - 1, c));
	}

	/** A gentle flame flicker around 1 (three incommensurate sines per light). */
	private static float flicker(float seed) {
		float t = time;
		return 1f + 0.075f * (0.5f * (float) Math.sin(t * 9.7f + seed) + 0.3f * (float) Math.sin(t * 15.3f + seed * 2.1f)
			+ 0.2f * (float) Math.sin(t * 23.9f + seed * 4.3f));
	}

	private static Src source(long key) {
		Src s = SOURCES.get(key);
		if (s == null) {
			s = new Src(key);
			SOURCES.put(key, s);
		}
		s.seen = true;
		return s;
	}

	private static void set(Src s, double x, double y, double z, float level, float[] tint, float intensity, boolean fire) {
		s.x = x;
		s.y = y;
		s.z = z;
		s.reach = level;
		s.r = tint[0] * intensity;
		s.g = tint[1] * intensity;
		s.b = tint[2] * intensity;
		s.fire = fire;
		s.spec = 1f;
		s.core = 0.75f;
		s.omni = false;
	}

	private static void set(Src s, double x, double y, double z, DynLightTable.Def d, float scale) {
		s.x = x;
		s.y = y;
		s.z = z;
		s.reach = d.level() * scale;
		s.r = d.r();
		s.g = d.g();
		s.b = d.b();
		s.fire = d.fire();
		s.spec = 1f;
		s.core = 0.75f;
		s.omni = false;
	}

	private static final int KIND_MAIN = 0, KIND_OFF = 1, KIND_BODY = 2, KIND_FIRE = 3;

	private static long key(Entity e, int kind) {
		return (long) e.getId() << 3 | kind;
	}

	private static void gather(ClientLevel level, CameraRenderState camera, float partial) {
		Minecraft mc = Minecraft.getInstance();
		LocalPlayer player = mc.player;
		boolean firstPerson = camera.isFirstPerson && player != null && mc.getCameraEntity() == player;
		double range = DynLightConfig.range(), range2 = range * range; // (1.1) range, hand and others live
		if (player != null && DynLightConfig.hand() && !player.isSpectator()) {
			hands(player, partial, firstPerson ? camera : null);
		}
		if (!DynLightConfig.others()) return;
		for (Entity e : level.entitiesForRendering()) {
			if (e == player && (firstPerson || player.isSpectator())) {
				if (e.displayFireAnimation()) fire(e, partial); // burning: the player's own fire lights the scene too
				continue;
			}
			Vec3 p = e.getPosition(partial);
			double dx = p.x - camX, dy = p.y - camY, dz = p.z - camZ;
			if (dx * dx + dz * dz > range2 || Math.abs(dy) > 40) continue;
			if (e instanceof ItemEntity item) {
				DynLightTable.Def d = DynLightTable.of(item.getItem());
				if (d.level() > 0) set(source(key(e, KIND_BODY)), p.x, p.y + 0.3, p.z, d, 1f);
			} else if (e instanceof ItemFrame frame) {
				DynLightTable.Def d = DynLightTable.of(frame.getItem());
				if (d.level() > 0) set(source(key(e, KIND_BODY)), p.x, p.y, p.z, d, 0.85f);
			} else if (e instanceof LivingEntity living) {
				if (e == player) hands(player, partial, null);
				else if (!living.isInvisible() || living.isOnFire()) heldBy(living, partial);
				if (e instanceof Blaze) {
					set(source(key(e, KIND_BODY)), p.x, p.y + e.getBbHeight() * 0.55, p.z, 12, DynLightTable.BLAZE, 1f, true);
				} else if (e instanceof MagmaCube cube) {
					set(source(key(e, KIND_BODY)), p.x, p.y + e.getBbHeight() * 0.5, p.z, Math.min(6 + 2 * cube.getSize(), 13), DynLightTable.MAGMA, 0.9f, false);
				} else if (e instanceof GlowSquid squid && squid.getDarkTicksRemaining() <= 0) {
					set(source(key(e, KIND_BODY)), p.x, p.y + e.getBbHeight() * 0.5, p.z, 7, DynLightTable.SQUID, 0.7f, false);
				}
			} else if (e instanceof SpectralArrow) {
				set(source(key(e, KIND_BODY)), p.x, p.y, p.z, 8, DynLightTable.SPECTRAL, 0.8f, false);
			} else if (e instanceof DragonFireball) {
				set(source(key(e, KIND_BODY)), p.x, p.y, p.z, 12, DynLightTable.DRAGON, 1f, true);
			} else if (e instanceof LargeFireball) {
				set(source(key(e, KIND_BODY)), p.x, p.y, p.z, 14, DynLightTable.FIRE, 1.1f, true);
			} else if (e instanceof SmallFireball) {
				set(source(key(e, KIND_BODY)), p.x, p.y, p.z, 11, DynLightTable.FIRE, 1f, true);
			} else if (e instanceof PrimedTnt tnt) {
				// vanilla flashes the block white every 10 ticks, faster near the end: the light pulses with it
				float fuse = tnt.getFuse() - partial + 1f;
				float pulse = fuse / 5f % 2f < 1f ? 1f : 0.35f;
				set(source(key(e, KIND_BODY)), p.x, p.y + 0.5, p.z, 11, DynLightTable.FLASH, pulse, false);
			} else if (e instanceof FireworkRocketEntity) {
				set(source(key(e, KIND_BODY)), p.x, p.y, p.z, 13, DynLightTable.ROCKET, 1.1f, true);
			} else if (e instanceof LightningBolt) {
				set(source(key(e, KIND_BODY)), p.x, p.y + 4, p.z, 15, DynLightTable.LIGHTNING, 3f, false);
			} else if (e instanceof EndCrystal) {
				set(source(key(e, KIND_BODY)), p.x, p.y + 1, p.z, 10, DynLightTable.CRYSTAL, 0.9f, false);
			} else if (e instanceof AbstractMinecart cart) {
				int emission = cart.getDisplayBlockState().getLightEmission();
				if (emission > 0) set(source(key(e, KIND_BODY)), p.x, p.y + 0.5, p.z, emission, DynLightTable.FIRE, 1f, true);
			}
			// anything burning (mobs, players, arrows on fire, minecarts in lava...): fire light at its centre
			if (e.displayFireAnimation() && !(e instanceof Blaze)) fire(e, partial);
		}
	}

	private static void fire(Entity e, float partial) {
		Vec3 p = e.getPosition(partial);
		float size = Math.max(e.getBbWidth(), e.getBbHeight());
		set(source(key(e, KIND_FIRE)), p.x, p.y + e.getBbHeight() * 0.5, p.z, size < 0.6f ? 12 : 15, DynLightTable.FIRE, 1.15f, true);
	}

	/** A mob's or another player's main / off hand items, at the hands of its model (body yaw, arm side). */
	private static void heldBy(LivingEntity e, float partial) {
		ItemStack main = e.getMainHandItem(), off = e.getOffhandItem();
		DynLightTable.Def dm = DynLightTable.of(main), doff = DynLightTable.of(off);
		if (dm.level() <= 0 && doff.level() <= 0) return;
		Vec3 p = e.getPosition(partial);
		double yaw = Math.toRadians(e.yBodyRotO + (e.yBodyRot - e.yBodyRotO) * partial);
		double fx = -Math.sin(yaw), fz = Math.cos(yaw), rx = -Math.cos(yaw), rz = -Math.sin(yaw);
		double h = e.getBbHeight(), w = Math.max(0.3, e.getBbWidth());
		double side = w * 0.62, fwd = w * 0.45, y = p.y + h * (e.isBaby() ? 0.45 : 0.5);
		double mainSide = e.getMainArm() == HumanoidArm.RIGHT ? 1 : -1;
		if (dm.level() > 0) setInAir(source(key(e, KIND_MAIN)), p.x, y, p.z, p.x + rx * side * mainSide + fx * fwd, y, p.z + rz * side * mainSide + fz * fwd, dm);
		if (doff.level() > 0) setInAir(source(key(e, KIND_OFF)), p.x, y, p.z, p.x - rx * side * mainSide + fx * fwd, y, p.z - rz * side * mainSide + fz * fwd, doff);
	}

	/**
	 * A held light at (x, y, z), pulled back toward its holder's centre (ax, ay, az) when it sits inside an opaque block or a
	 * block stands between them: hugging a wall, the hand (0.6 block from the eye) would otherwise be inside the wall and
	 * light the room behind it (the visibility walk starts at the light's own cell).
	 */
	private static void setInAir(Src s, double ax, double ay, double az, double x, double y, double z, DynLightTable.Def d) {
		if (occupancy != null && DynLightConfig.OCCLUSION) {
			for (int k = 0; k < 4; k++) {
				if (!occupancy.solid((int) Math.floor(x), (int) Math.floor(y), (int) Math.floor(z)) && !occupancy.blocked(ax, ay, az, x, y, z)) break;
				x = ax + (x - ax) * 0.5;
				y = ay + (y - ay) * 0.5;
				z = az + (z - az) * 0.5;
				if (k == 3) {
					x = ax;
					y = ay;
					z = az;
				}
			}
		}
		set(s, x, y, z, d, 1f);
	}

	/** (FT2.9) The flat core of the player's own light (blocks): the walls of a 1-wide tunnel get as much as the floor. */
	private static final float PLAYER_CORE = 1.5f;

	/**
	 * The local player's hands. (FT2.9, -Dmcopt.shade.dynLights.playerLight, read every frame; false = FT2.8.1) One light at the
	 * eye, as bright as the brighter hand, omnidirectional and with a wider core: what the player carries lights every block
	 * around alike, as in Photon, Complementary and BSL (their held light is centred on the player), not the walls on the
	 * hand's side in a bright disc (Gael). Otherwise in first person at the visible item (in front of the eye, low, to the side
	 * of its arm), in third person like any other player's.
	 */
	private static void hands(LocalPlayer player, float partial, CameraRenderState fp) {
		if (!"false".equalsIgnoreCase(System.getProperty("mcopt.shade.dynLights.playerLight", "true").trim())) {
			DynLightTable.Def dm = DynLightTable.of(player.getMainHandItem()), doff = DynLightTable.of(player.getOffhandItem());
			DynLightTable.Def d = doff.level() > dm.level() ? doff : dm;
			if (d.level() > 0) {
				Src s = source(key(player, KIND_MAIN));
				if (fp != null) {
					set(s, fp.pos.x, fp.pos.y, fp.pos.z, d, 1f);
				} else {
					Vec3 e = player.getEyePosition(partial);
					set(s, e.x, e.y, e.z, d, 1f);
				}
				s.core = PLAYER_CORE;
				s.omni = true;
			}
			markHands(player);
			return;
		}
		if (fp == null) {
			heldBy(player, partial);
			markHands(player);
			return;
		}
		DynLightTable.Def dm = DynLightTable.of(player.getMainHandItem()), doff = DynLightTable.of(player.getOffhandItem());
		if (dm.level() <= 0 && doff.level() <= 0) return;
		double yaw = Math.toRadians(fp.yRot), pitch = Math.toRadians(fp.xRot);
		double cp = Math.cos(pitch);
		double fx = -Math.sin(yaw) * cp, fy = -Math.sin(pitch), fz = Math.cos(yaw) * cp;
		double rx = -Math.cos(yaw), rz = -Math.sin(yaw);
		// up = right x forward
		double ux = -rz * fy, uy = rz * fx - rx * fz, uz = rx * fy;
		double mainSide = player.getMainArm() == HumanoidArm.RIGHT ? 1 : -1;
		double cx = fp.pos.x, cy = fp.pos.y, cz = fp.pos.z;
		if (dm.level() > 0) {
			double s = 0.42 * mainSide;
			setInAir(source(key(player, KIND_MAIN)), cx, cy, cz, cx + fx * 0.45 + rx * s - ux * 0.32, cy + fy * 0.45 - uy * 0.32, cz + fz * 0.45 + rz * s - uz * 0.32, dm);
		}
		if (doff.level() > 0) {
			double s = -0.42 * mainSide;
			setInAir(source(key(player, KIND_OFF)), cx, cy, cz, cx + fx * 0.45 + rx * s - ux * 0.32, cy + fy * 0.45 - uy * 0.32, cz + fz * 0.45 + rz * s - uz * 0.32, doff);
		}
		markHands(player);
	}

	private static void markHands(LocalPlayer player) {
		Src m = SOURCES.get(key(player, KIND_MAIN)), o = SOURCES.get(key(player, KIND_OFF));
		if (m != null) m.hand = true;
		if (o != null) o.hand = true;
	}

	// ---- the CPU query (the local player's packed light) ------------------------------------------------------------------

	/**
	 * The dynamic block light level (0..15) reaching absolute (x, y, z) from this frame's lights (after the last frame()),
	 * occluded through the block occupancy: what the local player's first-person hand and body take (the mixin raises their
	 * packed light to it).
	 */
	public static int levelAt(double x, double y, double z) {
		if (state == 0) return 0;
		float best = 0f, strength = DynLightConfig.strength(); // (1.1) live, as the frame's
		for (int i = 0, n = Math.min(ACTIVE.size(), DynLightConfig.max()); i < n; i++) {
			Src s = ACTIVE.get(i);
			double dx = s.x - x, dy = s.y - y, dz = s.z - z;
			double d = Math.sqrt(dx * dx + dy * dy + dz * dz);
			if (d >= s.reach - CUT) continue;
			float lv = (float) (s.reach - Math.max(d, s.core)) * Math.min(s.cur, 1f) * strength;
			if (lv <= best) continue;
			if (!s.hand && occupancy != null && occupancy.blocked(s.x, s.y, s.z, x, y, z)) continue;
			best = lv;
		}
		return Math.min(15, Math.round(best));
	}

	/** Block changes from the client level (ShadeLightClientLevelMixin). */
	public static void blockChanged(BlockPos pos, net.minecraft.world.level.block.state.BlockState now) {
		if (occupancy != null) occupancy.block(pos.getX(), pos.getY(), pos.getZ(), now);
	}

	public static void sectionChanged(int sx, int sy, int sz) {
		if (occupancy != null) occupancy.section(sx, sy, sz);
	}

	public static void sectionsChanged(int x0, int y0, int z0, int x1, int y1, int z1) {
		if (occupancy == null) return;
		if ((long) (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1) > 4096) return;
		for (int y = y0; y <= y1; y++) for (int z = z0; z <= z1; z++) for (int x = x0; x <= x1; x++) occupancy.section(x, y, z);
	}

	static boolean shadeOn() {
		return Shade.ENABLED;
	}
}
