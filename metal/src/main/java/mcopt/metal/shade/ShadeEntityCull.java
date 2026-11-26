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

import it.unimi.dsi.fastutil.ints.Int2LongOpenHashMap;
import it.unimi.dsi.fastutil.longs.Long2LongOpenHashMap;
import mcopt.metal.shade.shadow.ShadowPass;
import net.minecraft.client.multiplayer.ClientChunkCache;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.core.BlockPos;
import net.minecraft.world.entity.AreaEffectCloud;
import net.minecraft.world.entity.Display;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.LightningBolt;
import net.minecraft.world.entity.Marker;
import net.minecraft.world.entity.Mob;
import net.minecraft.world.entity.animal.squid.GlowSquid;
import net.minecraft.world.entity.boss.enderdragon.EndCrystal;
import net.minecraft.world.entity.boss.enderdragon.EnderDragon;
import net.minecraft.world.entity.boss.enderdragon.EnderDragonPart;
import net.minecraft.world.entity.boss.wither.WitherBoss;
import net.minecraft.world.entity.monster.Blaze;
import net.minecraft.world.entity.monster.cubemob.MagmaCube;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.entity.projectile.hurtingprojectile.Fireball;
import net.minecraft.world.level.LightLayer;
import net.minecraft.world.level.block.entity.BeaconBlockEntity;
import net.minecraft.world.level.block.entity.BlockEntity;
import net.minecraft.world.level.block.entity.CampfireBlockEntity;
import net.minecraft.world.level.block.entity.JigsawBlockEntity;
import net.minecraft.world.level.block.entity.StructureBlockEntity;
import net.minecraft.world.level.block.entity.TheEndGatewayBlockEntity;
import net.minecraft.world.level.block.entity.TheEndPortalBlockEntity;
import net.minecraft.world.level.block.entity.TrialSpawnerBlockEntity;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.chunk.LevelChunk;
import net.minecraft.world.level.chunk.LevelChunkSection;
import net.minecraft.world.phys.AABB;

/**
 * (2.0.1) Conservative 3D voxel-DDA occlusion culling for entities and block entities hidden behind solid terrain
 * (underground caves, closed houses, hills). Original Apache-2.0 implementation; off when mcopt.shade=false or
 * -Dmcopt.shade.entityCull=false.
 */
public final class ShadeEntityCull {
	public static final boolean ON = Shade.ENABLED && !"false".equals(System.getProperty("mcopt.shade.entityCull"));
	private static final boolean LOG = Boolean.getBoolean("mcopt.shade.entityCull.log");
	private static final double MIN_DIST_SQ = 10.0 * 10.0;
	private static final double SHADOW_SAFE_DIST_SQ = 36.0 * 36.0;
	private static final double PAD = 0.30;
	private static final int MAX_STEPS = 96;
	private static final long CACHE_TTL_FRAMES = 3L;

	private static ClientLevel lastLevel;
	private static long frame;
	private static double lastCamX = Double.NaN, lastCamY, lastCamZ;
	private static final Int2LongOpenHashMap entityCache = new Int2LongOpenHashMap(256);
	private static final Long2LongOpenHashMap beCache = new Long2LongOpenHashMap(256);
	private static long logTime;
	private static int statEntTested, statEntCulled, statBeTested, statBeCulled;

	static {
		entityCache.defaultReturnValue(Long.MIN_VALUE);
		beCache.defaultReturnValue(Long.MIN_VALUE);
	}

	private ShadeEntityCull() {
	}

	/** Called once per frame before entity / block-entity extraction. */
	public static void beginFrame(ClientLevel level, double camX, double camY, double camZ) {
		if (!ON) return;
		frame++;
		if (level != lastLevel) {
			lastLevel = level;
			entityCache.clear();
			beCache.clear();
			lastCamX = camX;
			lastCamY = camY;
			lastCamZ = camZ;
		} else {
			double dx = camX - lastCamX, dy = camY - lastCamY, dz = camZ - lastCamZ;
			if (dx * dx + dy * dy + dz * dz > 0.35 * 0.35 || entityCache.size() > 2048 || beCache.size() > 2048) {
				entityCache.clear();
				beCache.clear();
				lastCamX = camX;
				lastCamY = camY;
				lastCamZ = camZ;
			}
		}
		if (LOG) {
			long now = System.nanoTime();
			if (now - logTime > 5_000_000_000L) {
				logTime = now;
				System.out.println(String.format(java.util.Locale.ROOT,
					"[mcopt] shade entityCull: entities culled %d/%d, blockEntities culled %d/%d",
					statEntCulled, statEntTested, statBeCulled, statBeTested));
				statEntTested = statEntCulled = statBeTested = statBeCulled = 0;
			}
		}
	}

	/** Returns true iff entity is conservatively proven to be fully hidden behind solid opaque terrain. */
	public static boolean isEntityOccluded(ClientLevel level, Entity entity, double camX, double camY, double camZ) {
		if (!ON || level == null || entity == null) return false;
		if (LOG) statEntTested++;
		if (neverCullEntity(entity)) return false;

		AABB box = entity.getBoundingBox();
		double cx = 0.5 * (box.minX + box.maxX);
		double cy = 0.5 * (box.minY + box.maxY);
		double cz = 0.5 * (box.minZ + box.maxZ);
		double dx = cx - camX, dy = cy - camY, dz = cz - camZ;
		double dist2 = dx * dx + dy * dy + dz * dz;
		if (dist2 < MIN_DIST_SQ) return false;
		// Huge entities (ghasts, bosses, modded giants) stay visible
		if (box.maxX - box.minX > 4.0 || box.maxY - box.minY > 4.0 || box.maxZ - box.minZ > 4.0) return false;

		// Shadow safety: during sunlit frames, don't cull outdoor entities inside the near shadow cascade so shadows peeking around corners stay intact
		if (dist2 < SHADOW_SAFE_DIST_SQ && ShadowPass.enabled() && !ShadowPass.lightIsMoon()) {
			if (level.getBrightness(LightLayer.SKY, entity.blockPosition()) >= 10) return false;
		}

		int id = entity.getId();
		long cached = entityCache.get(id);
		if (cached != Long.MIN_VALUE) {
			long age = frame - (cached >>> 1);
			if (age >= 0 && age < CACHE_TTL_FRAMES) {
				boolean occ = (cached & 1L) != 0L;
				if (LOG && occ) statEntCulled++;
				return occ;
			}
		}

		boolean occ = isBoxOccluded(level, camX, camY, camZ,
			box.minX - PAD, box.minY - PAD, box.minZ - PAD,
			box.maxX + PAD, box.maxY + PAD, box.maxZ + PAD, cx, cy, cz);
		entityCache.put(id, (frame << 1) | (occ ? 1L : 0L));
		if (LOG && occ) statEntCulled++;
		return occ;
	}

	/** Returns true iff block entity is conservatively proven to be fully hidden behind solid opaque terrain. */
	public static boolean isBlockEntityOccluded(ClientLevel level, BlockEntity be, double camX, double camY, double camZ) {
		if (!ON || level == null || be == null) return false;
		if (LOG) statBeTested++;
		if (be instanceof BeaconBlockEntity || be instanceof TheEndGatewayBlockEntity || be instanceof TheEndPortalBlockEntity
			|| be instanceof CampfireBlockEntity || be instanceof TrialSpawnerBlockEntity
			|| be instanceof StructureBlockEntity || be instanceof JigsawBlockEntity) return false;

		BlockPos pos = be.getBlockPos();
		double cx = pos.getX() + 0.5, cy = pos.getY() + 0.5, cz = pos.getZ() + 0.5;
		double dx = cx - camX, dy = cy - camY, dz = cz - camZ;
		double dist2 = dx * dx + dy * dy + dz * dz;
		if (dist2 < MIN_DIST_SQ) return false;

		long key = pos.asLong();
		long cached = beCache.get(key);
		if (cached != Long.MIN_VALUE) {
			long age = frame - (cached >>> 1);
			if (age >= 0 && age < CACHE_TTL_FRAMES) {
				boolean occ = (cached & 1L) != 0L;
				if (LOG && occ) statBeCulled++;
				return occ;
			}
		}

		// Generous 1.5x1.5x1.5 box around the block (covers double chests, hanging signs, bells, beds)
		double minX = pos.getX() - 0.35, minY = pos.getY() - 0.25, minZ = pos.getZ() - 0.35;
		double maxX = pos.getX() + 1.35, maxY = pos.getY() + 1.35, maxZ = pos.getZ() + 1.35;
		boolean occ = isBoxOccluded(level, camX, camY, camZ, minX, minY, minZ, maxX, maxY, maxZ, cx, cy, cz);
		beCache.put(key, (frame << 1) | (occ ? 1L : 0L));
		if (LOG && occ) statBeCulled++;
		return occ;
	}

	private static boolean neverCullEntity(Entity e) {
		if (e instanceof Player || e instanceof EnderDragon || e instanceof WitherBoss || e instanceof EnderDragonPart
			|| e instanceof AreaEffectCloud || e instanceof LightningBolt || e instanceof Display || e instanceof Marker
			|| e instanceof Blaze || e instanceof MagmaCube || e instanceof GlowSquid || e instanceof EndCrystal
			|| e instanceof Fireball) return true;
		if (e.isCurrentlyGlowing() || e.hasCustomName() || e.isPassenger() || e.isVehicle() || e.isOnFire()) return true;
		if (e instanceof Mob mob && mob.isLeashed()) return true;
		return false;
	}

	/** Center ray first (fail-fast for visible objects), then all 8 corners of the padded AABB. */
	private static boolean isBoxOccluded(ClientLevel level, double camX, double camY, double camZ,
		double minX, double minY, double minZ, double maxX, double maxY, double maxZ,
		double cx, double cy, double cz) {
		ClientChunkCache chunks = level.getChunkSource();
		int minSecY = level.getMinSectionY();
		int secCount = level.getSectionsCount();
		if (!rayBlocked(chunks, minSecY, secCount, camX, camY, camZ, cx, cy, cz)) return false;
		if (!rayBlocked(chunks, minSecY, secCount, camX, camY, camZ, minX, minY, minZ)) return false;
		if (!rayBlocked(chunks, minSecY, secCount, camX, camY, camZ, maxX, minY, minZ)) return false;
		if (!rayBlocked(chunks, minSecY, secCount, camX, camY, camZ, minX, maxY, minZ)) return false;
		if (!rayBlocked(chunks, minSecY, secCount, camX, camY, camZ, maxX, maxY, minZ)) return false;
		if (!rayBlocked(chunks, minSecY, secCount, camX, camY, camZ, minX, minY, maxZ)) return false;
		if (!rayBlocked(chunks, minSecY, secCount, camX, camY, camZ, maxX, minY, maxZ)) return false;
		if (!rayBlocked(chunks, minSecY, secCount, camX, camY, camZ, minX, maxY, maxZ)) return false;
		return rayBlocked(chunks, minSecY, secCount, camX, camY, camZ, maxX, maxY, maxZ);
	}

	/**
	 * Fast integer 3D Amanatides-Woo voxel DDA from camera eye to target point.
	 * Returns true ONLY if a loaded, strictly opaque full-cube block (isSolidRender) lies strictly between start and target.
	 */
	private static boolean rayBlocked(ClientChunkCache chunks, int minSecY, int secCount,
		double x0, double y0, double z0, double x1, double y1, double z1) {
		int ix = floor(x0), iy = floor(y0), iz = floor(z0);
		int tx = floor(x1), ty = floor(y1), tz = floor(z1);
		if (ix == tx && iy == ty && iz == tz) return false;

		double dx = x1 - x0, dy = y1 - y0, dz = z1 - z0;
		int stepX = dx > 0 ? 1 : -1;
		int stepY = dy > 0 ? 1 : -1;
		int stepZ = dz > 0 ? 1 : -1;

		double tDeltaX = dx == 0.0 ? Double.POSITIVE_INFINITY : Math.abs(1.0 / dx);
		double tDeltaY = dy == 0.0 ? Double.POSITIVE_INFINITY : Math.abs(1.0 / dy);
		double tDeltaZ = dz == 0.0 ? Double.POSITIVE_INFINITY : Math.abs(1.0 / dz);

		double tMaxX = dx == 0.0 ? Double.POSITIVE_INFINITY : (dx > 0 ? (ix + 1.0 - x0) : (x0 - ix)) * tDeltaX;
		double tMaxY = dy == 0.0 ? Double.POSITIVE_INFINITY : (dy > 0 ? (iy + 1.0 - y0) : (y0 - iy)) * tDeltaY;
		double tMaxZ = dz == 0.0 ? Double.POSITIVE_INFINITY : (dz > 0 ? (iz + 1.0 - z0) : (z0 - iz)) * tDeltaZ;

		int cachedCx = Integer.MIN_VALUE, cachedCz = Integer.MIN_VALUE;
		LevelChunk chunk = null;

		for (int s = 0; s < MAX_STEPS; s++) {
			if (tMaxX < tMaxY) {
				if (tMaxX < tMaxZ) {
					if (tMaxX >= 1.0) return false;
					ix += stepX;
					tMaxX += tDeltaX;
				} else {
					if (tMaxZ >= 1.0) return false;
					iz += stepZ;
					tMaxZ += tDeltaZ;
				}
			} else if (tMaxY < tMaxZ) {
				if (tMaxY >= 1.0) return false;
				iy += stepY;
				tMaxY += tDeltaY;
			} else {
				if (tMaxZ >= 1.0) return false;
				iz += stepZ;
				tMaxZ += tDeltaZ;
			}
			// Reached target voxel: unobstructed
			if (ix == tx && iy == ty && iz == tz) return false;

			int secIdx = (iy >> 4) - minSecY;
			if (secIdx < 0 || secIdx >= secCount) continue; // above/below world = air

			int cx = ix >> 4, cz = iz >> 4;
			if (cx != cachedCx || cz != cachedCz) {
				chunk = chunks.getChunk(cx, cz, false);
				cachedCx = cx;
				cachedCz = cz;
			}
			if (chunk == null) return false; // unloaded chunk: stay visible

			LevelChunkSection section = chunk.getSection(secIdx);
			if (section.hasOnlyAir()) continue;

			BlockState state = section.getBlockState(ix & 15, iy & 15, iz & 15);
			if (state.isSolidRender()) return true;
		}
		return false;
	}

	private static int floor(double v) {
		int i = (int) v;
		return v < i ? i - 1 : i;
	}
}
