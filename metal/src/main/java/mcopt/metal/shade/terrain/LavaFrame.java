// Copyright 2026 mcopt-shade contributors. Apache-2.0.
package mcopt.metal.shade.terrain;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import mcopt.metal.shade.ShadeLook;
import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.block.FluidModel;
import net.minecraft.client.renderer.texture.TextureAtlasSprite;
import net.minecraft.world.level.material.Fluids;

/** Lava identity follows the current resource pack's fluid sprites, independently of the water module. */
public final class LavaFrame {
	private LavaFrame() {}

	public static void pack(ByteBuffer look) {
		look = look.duplicate().order(ByteOrder.LITTLE_ENDIAN);
		try {
			FluidModel model = Minecraft.getInstance().getModelManager().getFluidStateModelSet().get(Fluids.LAVA.defaultFluidState());
			TextureAtlasSprite still = model.stillMaterial().sprite(), flow = model.flowingMaterial().sprite();
			rect(look, ShadeLook.LAVA_STILL, still);
			rect(look, ShadeLook.LAVA_FLOW, flow);
		} catch (RuntimeException unavailable) {
			// ShadeLook.pack cleared both rectangles; no stale coordinates during a resource reload.
			for (int i = ShadeLook.LAVA_STILL; i < ShadeLook.SIZE; i += 4) look.putFloat(i, 0f);
		}
	}

	private static void rect(ByteBuffer out, int at, TextureAtlasSprite sprite) {
		out.putFloat(at, sprite.getU0()).putFloat(at + 4, sprite.getV0())
			.putFloat(at + 8, sprite.getU1()).putFloat(at + 12, sprite.getV1());
	}
}
