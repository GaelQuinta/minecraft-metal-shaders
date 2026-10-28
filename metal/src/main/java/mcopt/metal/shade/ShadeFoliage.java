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
import java.util.List;
import java.util.Locale;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.LivingEntity;
import net.minecraft.world.phys.Vec3;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.system.MemoryUtil;

/**
 * (1.2.7, issue #18) Waving foliage: leaves, grass, flowers, crops and vines move in the wind (more in rain and storms), their
 * shadows with them, and plants make way for the player and mobs. The motion itself is own/terrain.metal's ownSway (own_vs and
 * own_shadow_vs); this class tells it what moves and how hard.
 * <ul>
 * <li>When the block atlas is uploaded (ShadePbr.atlasUploaded): a class per foliage sprite, by name, into a small map over the
 * atlas (a texel per {@code cell} atlas pixels, the class in red) that the vertex stage reads at a quad's centre.</li>
 * <li>Every frame ({@link #frame}): ShadeSway's 224 bytes (mcown.m mco_sway_frame): the wobble phases (accumulated here in double,
 * so they never jump), the wind's direction (the rain's, ShadeWeather) and strength, the amplitudes from the settings, and up
 * to eight pushers, nearest first.</li>
 * </ul>
 * Settings (read every frame): {@code mcopt.shade.foliage.leaves} and {@code .plants} (1 = 100 %, 0 = still), {@code .push} (true).
 * Off with the shaders (mcown.m gives the cutout vertex stages F_SWAY only while shading is on).
 */
public final class ShadeFoliage {
	/** The classes (terrain.metal ownSway). */
	static final int LEAVES = 1, PLANT = 2, DOUBLE_LOWER = 3, DOUBLE_UPPER = 4, VINE = 5, CROP = 6;
	private static final int BYTES = 224, MAX_PUSHERS = 8;
	/** Amplitudes at 100 % (blocks; the shader scales them by the weather's strength and the sky light). */
	private static final float LEAVES_AMP = 0.045f, VINE_AMP = 0.02f, PLANT_AMP = 0.11f, CROP_AMP = 0.07f;

	private record Pending(int w, int h, int cell, byte[] classes, int sprites) {}

	private static Pending pending;
	/** A class map was uploaded (mcown.m holds it). */
	private static boolean haveMap;
	private static int mapW, mapH;
	private static double phase0, phase1, phase2, phase3, gustPhase;
	private static long lastNanos;
	private static final double TAU = Math.PI * 2;

	private ShadeFoliage() {
	}

	/** One sprite of the block atlas: its name's path (e.g. "block/oak_leaves") and its pixels' rectangle. */
	record Sprite(String path, int x, int y, int w, int h) {}

	/** The block atlas was uploaded (render thread): its foliage sprites' map, built here and uploaded at the next frame. */
	static void atlasUploaded(int atlasW, int atlasH, List<Sprite> sprites) {
		if (!Shade.ENABLED || atlasW <= 0 || atlasH <= 0) return;
		int min = Integer.MAX_VALUE;
		for (Sprite s : sprites) min = Math.min(min, Math.min(s.w, s.h));
		// a texel per `cell` atlas pixels: the smallest sprite's size (at least 8), doubled until the map is at most 1024 wide and high
		int cell = Integer.highestOneBit(Math.max(8, min == Integer.MAX_VALUE ? 16 : min));
		while (atlasW / cell > 1024 || atlasH / cell > 1024) cell *= 2;
		int w = Math.max(1, (atlasW + cell - 1) / cell), h = Math.max(1, (atlasH + cell - 1) / cell);
		byte[] map = new byte[w * h];
		int n = 0;
		for (Sprite s : sprites) {
			int k = classOf(s.path);
			if (k == 0) continue;
			n++;
			// every texel whose centre is inside the sprite, and always the one holding its centre (where the shader looks)
			for (int ty = Math.max(0, (s.y + cell / 2) / cell); ty < h && ty * cell + cell / 2 < s.y + s.h; ty++)
				for (int tx = Math.max(0, (s.x + cell / 2) / cell); tx < w && tx * cell + cell / 2 < s.x + s.w; tx++) map[ty * w + tx] = (byte) k;
			int cx = Math.min(w - 1, (s.x + s.w / 2) / cell), cy = Math.min(h - 1, (s.y + s.h / 2) / cell);
			map[cy * w + cx] = (byte) k;
		}
		pending = new Pending(w, h, cell, map, n);
	}

	/** A sprite's foliage class by its name (0: it doesn't move). Vanilla's names; resource packs keep them. */
	static int classOf(String path) {
		String p = path.startsWith("block/") ? path.substring(6) : path;
		if (p.endsWith("_leaves")) return LEAVES;
		if (p.equals("vine") || p.startsWith("pale_hanging_moss")) return VINE;
		if (p.endsWith("_bottom") && isDouble(p.substring(0, p.length() - 7))) return DOUBLE_LOWER;
		if (p.endsWith("_top") && isDouble(p.substring(0, p.length() - 4))) return DOUBLE_UPPER;
		if (p.equals("sunflower_front") || p.equals("sunflower_back")) return DOUBLE_UPPER;
		if (p.matches("(wheat|carrots|potatoes|beetroots|torchflower_crop)_stage\\d+")) return CROP;
		if (p.endsWith("_sapling") || p.startsWith("sweet_berry_bush_stage")) return PLANT;
		return switch (p) {
			case "short_grass", "fern", "dead_bush", "bush", "firefly_bush", "short_dry_grass", "tall_dry_grass", "dandelion", "poppy",
				"blue_orchid", "allium", "azure_bluet", "red_tulip", "orange_tulip", "white_tulip", "pink_tulip", "oxeye_daisy", "cornflower",
				"lily_of_the_valley", "wither_rose", "torchflower", "open_eyeblossom", "closed_eyeblossom", "cactus_flower" -> PLANT;
			default -> 0;
		};
	}

	private static boolean isDouble(String p) {
		return switch (p) {
			case "tall_grass", "large_fern", "lilac", "rose_bush", "peony", "sunflower", "pitcher_plant" -> true;
			default -> false;
		};
	}

	/** Every frame (ShadeFrameUpdater.update, render thread): the map when a new atlas came, then this frame's ShadeSway. */
	static void frame(ClientLevel level, double camX, double camY, double camZ, float rain, float thunder, float partial) {
		if (ShadeBindings.ctx() == 0) return;
		if (pending != null) upload(pending);
		long now = System.nanoTime();
		double dt = lastNanos == 0 ? 0 : Math.min(0.25, (now - lastNanos) / 1e9);
		lastNanos = now;
		float leaves = Live.f("mcopt.shade.foliage.leaves", 1f, 0f, 3f), plants = Live.f("mcopt.shade.foliage.plants", 1f, 0f, 3f);
		boolean push = Live.b("mcopt.shade.foliage.push", true);
		// storms blow harder and faster: amplitude through wind.y, the wobble's speed here
		float strength = 1f + 0.7f * rain + 1.0f * thunder;
		double speed = 0.85 + 0.25 * strength;
		phase0 = (phase0 + dt * 1.7 * speed) % TAU;
		phase1 = (phase1 + dt * 2.9 * speed) % TAU;
		phase2 = (phase2 + dt * 4.3 * speed) % TAU;
		phase3 = (phase3 + dt * 6.1 * speed) % TAU;
		gustPhase = (gustPhase + dt * 0.45 * speed) % TAU;
		float angle = mcopt.metal.shade.weather.ShadeWeather.ON ? mcopt.metal.shade.weather.ShadeWeather.windAngle() : 0.6f;

		try (MemoryStack stack = MemoryStack.stackPush()) {
			ByteBuffer b = stack.calloc(BYTES).order(ByteOrder.nativeOrder());
			b.putFloat(0, (float) phase0).putFloat(4, (float) phase1).putFloat(8, (float) phase2).putFloat(12, (float) phase3);
			b.putFloat(16, (float) Math.cos(angle)).putFloat(20, strength).putFloat(24, (float) Math.sin(angle)).putFloat(28, (float) gustPhase);
			b.putFloat(32, LEAVES_AMP * leaves).putFloat(36, PLANT_AMP * plants).putFloat(40, VINE_AMP * leaves).putFloat(44, CROP_AMP * plants);
			int n = push && haveMap && level != null ? pushers(level, camX, camY, camZ, partial, b) : 0;
			boolean any = haveMap && (leaves > 0 || plants > 0 || n > 0);
			b.putFloat(48, any ? mapW : 0).putFloat(52, any ? mapH : 0).putFloat(56, n).putFloat(60, push ? 1f : 0f);
			ShadeNative.swayFrame(MemoryUtil.memAddress(b));
		}
	}

	/** The nearest living entities (the player included, spectators not) within 24 blocks, into ShadeSway.push / pushH. */
	private static int pushers(ClientLevel level, double camX, double camY, double camZ, float partial, ByteBuffer b) {
		Entity[] best = new Entity[MAX_PUSHERS];
		double[] dist = new double[MAX_PUSHERS];
		int n = 0;
		for (Entity e : level.entitiesForRendering()) {
			if (!(e instanceof LivingEntity) || e.isSpectator() || e.isRemoved()) continue;
			double dx = e.getX() - camX, dy = e.getY() - camY, dz = e.getZ() - camZ, d = dx * dx + dy * dy + dz * dz;
			if (d > 24 * 24) continue;
			int i = n < MAX_PUSHERS ? n++ : MAX_PUSHERS;
			if (i == MAX_PUSHERS) {
				if (d >= dist[MAX_PUSHERS - 1]) continue;
				i = MAX_PUSHERS - 1;
			}
			while (i > 0 && dist[i - 1] > d) {
				best[i] = best[i - 1];
				dist[i] = dist[i - 1];
				i--;
			}
			best[i] = e;
			dist[i] = d;
		}
		for (int i = 0; i < n; i++) {
			Entity e = best[i];
			Vec3 p = e.getPosition(partial);
			int o = 64 + i * 16;
			b.putFloat(o, (float) (p.x - camX)).putFloat(o + 4, (float) (p.y - camY)).putFloat(o + 8, (float) (p.z - camZ))
				.putFloat(o + 12, e.getBbWidth() * 0.5f + 0.85f); // (the reach: plants within ~half a block of its side bend)
			b.putFloat(192 + i * 4, e.getBbHeight());
		}
		return n;
	}

	private static void upload(Pending p) {
		pending = null;
		long tex;
		try (MemoryStack stack = MemoryStack.stackPush()) {
			tex = ShadeNative.textureCpu(ShadeBindings.ctx(), p.w, p.h, 1, MemoryUtil.memAddress(stack.UTF8("mcopt foliage classes")));
		}
		if (tex == 0) {
			System.out.println("[mcopt] shade: foliage: class map allocation failed; foliage stays still");
			return;
		}
		ByteBuffer px = MemoryUtil.memAlloc(p.w * p.h * 4);
		try {
			for (int i = 0; i < p.w * p.h; i++) px.putInt(i * 4, p.classes[i] & 255); // (red channel, little-endian RGBA8)
			ShadeNative.textureUpload(tex, 0, 0, 0, p.w, p.h, MemoryUtil.memAddress(px), p.w * 4);
		} finally {
			MemoryUtil.memFree(px);
		}
		ShadeNative.swayClasses(tex); // (retained natively)
		ShadeNative.textureRelease(tex);
		haveMap = true;
		mapW = p.w;
		mapH = p.h;
		System.out.println(String.format(Locale.ROOT, "[mcopt] shade: foliage: %d moving sprites, class map %dx%d (%d px a texel)", p.sprites, p.w, p.h, p.cell));
	}
}
