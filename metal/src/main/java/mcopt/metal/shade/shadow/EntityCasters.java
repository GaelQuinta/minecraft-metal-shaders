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
package mcopt.metal.shade.shadow;

import java.util.Map;
import mcopt.metal.MetalDrawTap;

/**
 * M3 (bible E08 "entity shadows", M3c): entities, block entities, dropped items, armour and moving blocks cast sun shadows.
 * <ol>
 * <li>Record: during the HDR world passes, MetalDrawTap reports every quad draw; the caster pipelines' draws (their vertex
 * buffer range, quad count, stride, uv offset and texture) are kept natively (mc_shadow_entity_record).</li>
 * <li>Commit (ShadePost.beforeHand, the end of the world): the recorded vertices are copied by one blit into the shadow
 * pass's own buffer (the game's vertex buffers are pooled per frame).</li>
 * <li>Cast: the next frame's near cascade draws them after the terrain (shadow.metal shadow_entity_vs/fs: depth only, the
 * texture's alpha tested, shifted from the camera they were recorded with onto this frame's).</li>
 * </ol>
 * One frame of latency (invisible at entity speeds); only the near cascade (receivers further away keep the terrain's
 * shadows). mcopt.shade.entityShadows=false turns it off (startup: the casters' pipeline and buffer); (1.1) the settings
 * screen's live switch is mcopt.shade.entityShadows.pause (read every frame): our entity shadows off and vanilla's blob back.
 */
public final class EntityCasters {
	public static final boolean ON = mcopt.metal.shade.Shade.SHADOWS && mcopt.metal.shade.ShadeConfig.HDR
		&& Boolean.parseBoolean(System.getProperty("mcopt.shade.entityShadows", "true"));

	/** Pipelines that cast, with their alpha cutoff (the game's own: 0.1 for cutouts; 0.5 for translucent ones). */
	static final Map<String, Float> CASTERS = Map.ofEntries(
		Map.entry("minecraft:pipeline/entity_solid", 0.1f), Map.entry("minecraft:pipeline/entity_solid_offset_forward", 0.1f),
		Map.entry("minecraft:pipeline/entity_solid_glint", 0.1f),
		Map.entry("minecraft:pipeline/entity_cutout", 0.1f), Map.entry("minecraft:pipeline/entity_cutout_cull", 0.1f),
		Map.entry("minecraft:pipeline/entity_cutout_z_offset", 0.1f), Map.entry("minecraft:pipeline/entity_cutout_dissolve", 0.1f),
		Map.entry("minecraft:pipeline/entity_translucent", 0.5f), Map.entry("minecraft:pipeline/entity_translucent_cull", 0.5f),
		Map.entry("minecraft:pipeline/armor_cutout_no_cull", 0.1f), Map.entry("minecraft:pipeline/armor_cutout_no_cull_glint", 0.1f),
		Map.entry("minecraft:pipeline/item_cutout", 0.1f), Map.entry("minecraft:pipeline/item_translucent", 0.5f),
		Map.entry("minecraft:pipeline/item_translucent_glint", 0.5f),
		Map.entry("minecraft:pipeline/solid_block", 0.1f), Map.entry("minecraft:pipeline/cutout_block", 0.5f));

	private static long shadow;
	private static int recorded, dropped;
	/** This frame draws the near cascade (set in beginFrame): otherwise nothing is recorded or copied (Nether, End). */
	private static boolean active;
	/**
	 * mcopt.shade.entityShadows.pause, read every frame (mcbench's zoo_noshadow phase: the cost A/B in one session; (1.1) the
	 * settings screen's live "entity shadows off"): nothing recorded or cast, and vanilla's blob shadow stays (dropBlob).
	 */
	private static boolean paused;
	private static boolean installed;

	private EntityCasters() {
	}

	private static final MetalDrawTap.Listener TAP = (pipeline, vertexBuffer, firstVertex, quads, stride, uvOffset, texture) -> {
		Float cutoff = CASTERS.get(pipeline);
		long s = shadow;
		if (!active || paused || cutoff == null || s == 0 || quads <= 0 || texture == 0) return;
		if (ShadowNative.entityRecord(s, vertexBuffer, firstVertex, quads, stride, uvOffset, texture, cutoff) == 0) recorded++;
		else dropped++;
	};

	/**
	 * The shadow pass made its native state (ShadowPass.create): make the casters' pipeline and buffer (only now, only with
	 * entity shadows on) and start listening. A failure here leaves the terrain shadows as they are.
	 */
	static void attach(long nativeShadow) {
		if (!ON || nativeShadow == 0) return;
		try (org.lwjgl.system.MemoryStack stack = org.lwjgl.system.MemoryStack.stackPush()) {
			long err = stack.ncalloc(1, 1024, 1);
			if (ShadowNative.entityInit(nativeShadow, err, 1024) != 0) {
				System.out.println("[mcopt] shade: entity shadows off (" + org.lwjgl.system.MemoryUtil.memUTF8(err) + "); terrain shadows kept");
				return;
			}
		}
		shadow = nativeShadow;
		if (!installed) {
			installed = true;
			MetalDrawTap.listener = TAP;
		}
	}

	static void detach() {
		shadow = 0;
		if (installed) {
			installed = false;
			MetalDrawTap.listener = null;
		}
	}

	/** Before this frame's world passes: drop whatever a frame that never reached its commit recorded. */
	static void beginFrame(ShadowPass p) {
		paused = Boolean.getBoolean("mcopt.shade.entityShadows.pause");
		if (shadow != 0 && recorded + dropped > 0) ShadowNative.entityReset(shadow);
		recorded = dropped = 0;
		boolean was = active;
		// (2.0.1 opt) night already uses vanilla blob shadows (dropBlob checks !lightIsMoon): skip recording, copying and drawing entity casters under moonlight
		active = shadow != 0 && p.nearThisFrame() && !ShadowPass.lightIsMoon();
		// no near cascade this frame (Nether, End): forget the ready casters once (their textures are released)
		if (was && !active && shadow != 0) {
			fresh = false;
			ShadowNative.entityShift(shadow, 0f, 0f, 0f, 1);
		}
	}

	/**
	 * M3: vanilla's blob shadow piece at pos (EntityRenderer.extractShadowPiece) is dropped where a real shadow replaces it:
	 * entity casters ready, a shadow map this frame, the sun casting (the moon's shadows are too faint to replace it), and
	 * sky light >= 5 at the piece, the receivers' gate (terrain and entities skip the map at sky light <= 0.3). Caves, dark
	 * interiors, the Nether, the End and the night keep the blob. (The blob's own vertex lightmap is always 15/15, so this
	 * is decided here, not in its shader.)
	 */
	public static boolean dropBlob(net.minecraft.world.level.Level level, net.minecraft.core.BlockPos pos) {
		// M3.3 (dims): in the End (no sky light) the key light's map shades every receiver: the blob goes wherever it draws
		boolean end = mcopt.metal.shade.dims.ShadeDims.endDropsBlob();
		// (1.1) paused (mcopt.shade.entityShadows.pause, live): no entity casts our shadow, so vanilla's blob stays everywhere
		if (!LOG) {
			return shadow != 0 && !paused && ShadowPass.enabled() && !ShadowPass.lightIsMoon()
				&& (end || level.getBrightness(net.minecraft.world.level.LightLayer.SKY, pos) >= BLOB_SKY);
		}
		// M3.3: the same decision, counted by reason for the log (mcopt.shade.entityShadows.log)
		if (shadow == 0 || paused || !ShadowPass.enabled()) {
			blobKeptNoMap++;
			return false;
		}
		if (ShadowPass.lightIsMoon()) {
			blobKeptMoon++;
			return false;
		}
		int sky = level.getBrightness(net.minecraft.world.level.LightLayer.SKY, pos);
		if (!end && sky < BLOB_SKY) {
			blobKeptDark++;
			blobDarkSkyMax = Math.max(blobDarkSkyMax, sky);
			return false;
		}
		blobDropped++;
		return true;
	}

	private static int blobDropped, blobKeptNoMap, blobKeptMoon, blobKeptDark, blobDarkSkyMax;

	/** Sky light from which receivers use the shadow map (sky / 15 > 0.3). */
	private static final int BLOB_SKY = 5;

	// the camera the committed casters were recorded with; fresh: committed since the last cast
	private static double camX, camY, camZ;
	private static boolean fresh;
	private static final boolean LOG = Boolean.getBoolean("mcopt.shade.entityShadows.log");
	private static long lastLog;
	private static int lastRecorded, lastDropped;

	/** The near cascade is about to draw (camera x, y, z): shift last frame's casters onto it. */
	static void prepareCast(long frame, double x, double y, double z) {
		if (shadow == 0) return;
		boolean stale = !fresh || paused;
		fresh = false;
		double dx = camX - x, dy = camY - y, dz = camZ - z;
		if (dx * dx + dy * dy + dz * dz > 64 * 64) stale = true; // a teleport: they'd land in the wrong place
		ShadowNative.entityShift(shadow, (float) dx, (float) dy, (float) dz, stale ? 1 : 0);
		if (LOG && System.nanoTime() - lastLog > 4_000_000_000L) {
			lastLog = System.nanoTime();
			System.out.println("[mcopt] shade: entity casters: " + ShadowNative.entityCount(shadow) + " draws cast this frame" + (stale ? " (stale: dropped)" : "")
				+ ", last frame recorded " + lastRecorded + ", dropped " + lastDropped + ", shift " + String.format("%.3f %.3f %.3f", dx, dy, dz)
				+ "; blob pieces since last line: dropped " + blobDropped + ", kept (no map " + blobKeptNoMap + ", moon " + blobKeptMoon + ", sky light < "
				+ BLOB_SKY + " " + blobKeptDark + (blobKeptDark > 0 ? ", max " + blobDarkSkyMax : "") + ")");
			blobDropped = blobKeptNoMap = blobKeptMoon = blobKeptDark = blobDarkSkyMax = 0;
		}
	}

	/** End of the world (ShadePost.beforeHand): copy this frame's recorded casters for the next frame's near cascade. */
	public static void commit(long enc) {
		ShadowPass p = ShadowPass.instance();
		if (shadow == 0 || p == null || !active) return;
		ShadowNative.entityCommit(enc, shadow);
		camX = p.camX();
		camY = p.camY();
		camZ = p.camZ();
		fresh = true;
		lastRecorded = recorded;
		lastDropped = dropped;
		recorded = dropped = 0;
	}

	/** Casters drawn into this frame's near cascade (for logs and tests). */
	public static int count() {
		return shadow == 0 ? 0 : ShadowNative.entityCount(shadow);
	}
}
