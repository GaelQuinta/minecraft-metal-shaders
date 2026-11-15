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
package mcopt.metal.shade.terrain;

import com.mojang.blaze3d.vertex.VertexConsumer;
import net.minecraft.client.renderer.block.BlockAndTintGetter;
import net.minecraft.client.renderer.block.FluidRenderer;
import net.minecraft.core.BlockPos;
import net.minecraft.util.LightCoordsUtil;

/**
 * (1.2.4, GitHub issue #9) Smooth light on water faces. Vanilla's FluidRenderer gives every face of a water block one light
 * value (max of the block and the one above it), so a lake lit by torches shows one flat square per block, a step of a whole
 * light level from each to the next; the shade's torch light makes those steps plain to see. Sodium (the terrain until 1.1)
 * lit fluids per corner, which 1.2's move to mcopt's own terrain lost. Here each vertex gets the average, over the four block
 * columns around its corner, of vanilla's own value for that column (max of the two blocks on either side of the vertex's
 * height): the same light as vanilla in an even field, blended across block edges, and the same value for every face that
 * shares the corner (tops, the sides of falls, bottoms), so they meet without seams. A column with both blocks opaque (a
 * solid shore) has no light of its own and is left out. Only water (lava lights itself) and only with the native shading
 * (mcopt.shade.fluidLight=false: vanilla's flat light); OwnMesher wraps its fluid output with it per compile.
 */
public final class ShadeFluidLight implements VertexConsumer {
	public static final boolean ON = mcopt.metal.shade.Shade.ENABLED && !"false".equals(System.getProperty("mcopt.shade.fluidLight"));

	private final BlockAndTintGetter level;
	private final int ox, oy, oz;
	private final FluidRenderer.Output inner;
	private final BlockPos.MutableBlockPos cursor = new BlockPos.MutableBlockPos();
	private VertexConsumer out;
	/** The fluid being tesselated is water (set by OwnMesher before each FluidRenderer.tesselate). */
	public boolean water;
    /** Actual falling-fluid state, not just a vertical face of a source block. */
    public boolean falling;
    /** Water composites at alpha one; reserve 254 in the unused vertex alpha for falling water. */
    public static int materialColor(int color, boolean water, boolean falling) {
        return water && falling ? (color & 0x00ffffff) | 0xfe000000 : color;
    }
	/** The last corners and their light: a top face is sent twice (its back face for the view from below) with the same corners. */
	private final long[] keys = new long[8];
	private final int[] values = new int[8];
	private int next;
	/**
	 * (1.2.5) Each block's light (or OPAQUE) as read, for the 18^3 blocks a section's corners can reach (the section and 1 around):
	 * a block is shared by up to 8 corners, so it is read once per compile. Made on the first water vertex (no water, no array).
	 */
	private int[] samples;
	private static final int UNREAD = Integer.MIN_VALUE, OPAQUE = -1, SPAN = 18;

	private ShadeFluidLight(BlockAndTintGetter level, BlockPos origin, FluidRenderer.Output inner) {
		this.level = level;
		this.ox = origin.getX();
		this.oy = origin.getY();
		this.oz = origin.getZ();
		this.inner = inner;
		java.util.Arrays.fill(this.keys, Long.MIN_VALUE);
	}

	/** An output whose builders get water's vertices with smooth light; origin: the section's (FluidRenderer's vertices are relative to it). */
	public static FluidRenderer.Output wrap(FluidRenderer.Output inner, BlockAndTintGetter level, BlockPos origin, ShadeFluidLight[] holder) {
		ShadeFluidLight light = new ShadeFluidLight(level, origin, inner);
		holder[0] = light;
		return layer -> {
			light.out = inner.getBuilder(layer);
			return light;
		};
	}

	@Override
	public void addVertex(float x, float y, float z, int color, float u, float v, int overlayCoords, int lightCoords, float nx, float ny, float nz) {
		this.out.addVertex(x, y, z, materialColor(color, this.water, this.falling), u, v, overlayCoords, this.water && ON ? this.corner(x, y, z, lightCoords) : lightCoords, nx, ny, nz);
	}

	/** The smooth light at the block corner nearest to a vertex (section-relative), or vanilla's when no column has light. */
	private int corner(float x, float y, float z, int flat) {
		int cx = this.ox + Math.round(x), cy = this.oy + Math.round(y), cz = this.oz + Math.round(z);
		long key = ((long) cx & 0x3FFFFFF) << 38 | ((long) cy & 0xFFF) << 26 | (long) cz & 0x3FFFFFF;
		for (int i = 0; i < 8; i++) if (this.keys[i] == key) return this.values[i];
		int block = 0, sky = 0, n = 0;
		for (int dz = -1; dz <= 0; dz++) {
			for (int dx = -1; dx <= 0; dx++) {
				int lo = this.sample(cx + dx, cy - 1, cz + dz), hi = this.sample(cx + dx, cy, cz + dz);
				if (lo < 0 && hi < 0) continue;
				int c = lo < 0 ? hi : hi < 0 ? lo : LightCoordsUtil.max(lo, hi);
				block += LightCoordsUtil.smoothBlock(c);
				sky += LightCoordsUtil.smoothSky(c);
				n++;
			}
		}
		int value = n == 0 ? flat : LightCoordsUtil.smoothPack((block + n / 2) / n, (sky + n / 2) / n);
		this.keys[this.next] = key;
		this.values[this.next] = value;
		this.next = (this.next + 1) & 7;
		return value;
	}

	/** Vanilla's light coords of a block, or -1 for an opaque one (no light inside). */
	private int sample(int x, int y, int z) {
		int i = (x - this.ox + 1) + SPAN * ((y - this.oy + 1) + SPAN * (z - this.oz + 1));
		int[] cache = this.samples;
		if (cache == null) {
			cache = this.samples = new int[SPAN * SPAN * SPAN];
			java.util.Arrays.fill(cache, UNREAD);
		}
		int v = cache[i];
		if (v != UNREAD) return v;
		BlockPos p = this.cursor.set(x, y, z);
		net.minecraft.world.level.block.state.BlockState state = this.level.getBlockState(p);
		v = state.isSolidRender() ? OPAQUE : LightCoordsUtil.getLightCoords(LightCoordsUtil.BrightnessGetter.DEFAULT, this.level, state, p);
		cache[i] = v;
		return v;
	}

	private static UnsupportedOperationException unsupported() {
		return new UnsupportedOperationException("shade fluid light: BLOCK-format addVertex only");
	}

	@Override
	public VertexConsumer addVertex(float x, float y, float z) {
		throw unsupported();
	}

	@Override
	public VertexConsumer setColor(int r, int g, int b, int a) {
		throw unsupported();
	}

	@Override
	public VertexConsumer setColor(int color) {
		throw unsupported();
	}

	@Override
	public VertexConsumer setUv(float u, float v) {
		throw unsupported();
	}

	@Override
	public VertexConsumer setUv1(int u, int v) {
		throw unsupported();
	}

	@Override
	public VertexConsumer setUv2(int u, int v) {
		throw unsupported();
	}

	@Override
	public VertexConsumer setUv3(float u, float v) {
		throw unsupported();
	}

	@Override
	public VertexConsumer setNormal(float x, float y, float z) {
		throw unsupported();
	}

	@Override
	public VertexConsumer setLineWidth(float width) {
		throw unsupported();
	}
}
