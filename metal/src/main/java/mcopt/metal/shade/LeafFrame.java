// Copyright 2026 mcopt-shade contributors. Apache-2.0.
package mcopt.metal.shade;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Set;
import mcopt.metal.mixin.AtlasDoubleAtlasAccess;
import net.minecraft.client.renderer.texture.TextureAtlas;

/** Leaf sprite identity follows atlas reloads; no per-frame model traversal or GPU texture allocation. */
public final class LeafFrame {
	public static final int OFFSET = 2304, CAPACITY = 16, SIZE = 16 + CAPACITY * 16;
	private static final Set<String> NAMES = Set.of("oak", "spruce", "birch", "jungle", "acacia", "dark_oak",
		"mangrove", "cherry", "azalea", "flowering_azalea", "pale_oak");
	private static volatile float[] bounds = new float[0];

	private LeafFrame() {}

	public static void atlasUploaded(TextureAtlas atlas) {
		if (!Shade.ENABLED || !atlas.location().getPath().endsWith("atlas/blocks.png")) return;
		float[] next = new float[CAPACITY * 4];
		int count = 0;
		for (var sprite : ((AtlasDoubleAtlasAccess) atlas).mcopt$adSprites()) {
			var name = sprite.contents().name();
			String path = name.getPath();
			if (!name.getNamespace().equals("minecraft") || !path.startsWith("block/") || !path.endsWith("_leaves")) continue;
			if (!NAMES.contains(path.substring(6, path.length() - 7)) || count == CAPACITY) continue;
			int at = count++ * 4;
			next[at] = sprite.getU0(); next[at + 1] = sprite.getV0();
			next[at + 2] = sprite.getU1(); next[at + 3] = sprite.getV1();
		}
		bounds = java.util.Arrays.copyOf(next, count * 4);
	}

	static void pack(ByteBuffer frame, ShadeFrame f) {
		// This independent region does not change ShadeLook's ABI (including other local material extensions).
		frame.order(ByteOrder.LITTLE_ENDIAN);
		float[] rects = bounds;
		float wind = f.dimension == ShadeFrame.DIM_OVERWORLD ? Live.f("mcopt.shade.user.leafWind", 1f, 0f, 2f) : 0f;
		frame.putFloat(OFFSET, wind * (0.8f + 0.2f * f.rain));
		frame.putFloat(OFFSET + 4, f.gameTimeSeconds / 3600f);
		frame.putFloat(OFFSET + 8, rects.length / 4);
		frame.putFloat(OFFSET + 12, 0f);
		for (int i = 0; i < CAPACITY * 4; i++) frame.putFloat(OFFSET + 16 + i * 4, i < rects.length ? rects[i] : 0f);
	}
}
