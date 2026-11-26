package mcopt.metal.own;

import com.mojang.blaze3d.vertex.VertexConsumer;
import java.util.function.Supplier;
import net.fabricmc.fabric.api.client.renderer.v1.Renderer;
import net.fabricmc.fabric.api.client.renderer.v1.mesh.MutableQuadView;
import net.fabricmc.fabric.api.client.renderer.v1.mesh.QuadEmitter;
import net.fabricmc.fabric.api.client.renderer.v1.render.AltModelBlockRenderer;
import net.minecraft.client.color.block.BlockColors;
import net.minecraft.client.renderer.block.BlockAndTintGetter;
import net.minecraft.client.renderer.block.dispatch.BlockStateModel;
import net.minecraft.client.renderer.chunk.ChunkSectionLayer;
import net.minecraft.client.renderer.texture.OverlayTexture;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.block.state.BlockState;
import org.jspecify.annotations.Nullable;

/**
 * Our mesher's FRAPI path (OwnApi): what Fabric API's own SectionCompiler patch does, with our quads as the destination. Per
 * section a new block tesselator from the active renderer (Renderer.altModelBlockRenderer, as Fabric API's patch makes one
 * per compile: the renderer culls, lights (AO or flat, emissive), tints and offsets each quad); per worker one quad emitter
 * whose emit writes the finished quad as compact quads for solid and cutout (the bytes OwnTerrain.store makes of what
 * Fabric API's patch would have put in vanilla's BufferBuilder: same floats, ABGR colour, packed light) or, translucent,
 * with QuadView.buffer into the translucent BufferBuilder, as Fabric API's patch does. The layer is the quad's own (QuadView.chunkLayer: FRAPI's blend mode).
 * Loaded only when fabric-renderer-api-v1 is.
 */
final class OwnFrapi implements OwnApi.Mesher {
	private static final ThreadLocal<OwnFrapi> LOCAL = ThreadLocal.withInitial(OwnFrapi::new);

	private final QuadEmitter emitter = Renderer.get().quadEmitter(this::emitted);
	private @Nullable AltModelBlockRenderer blocks;
	private @Nullable OwnQuads quads;
	private @Nullable Supplier<VertexConsumer> translucent;
	private @Nullable VertexConsumer translucentSink;
	private final float[] p = new float[12], uv = new float[8];
	private final int[] abgr = new int[4], light = new int[4];
	private static final net.minecraft.core.Direction[] DIRS = net.minecraft.core.Direction.values();
	private final BlockPos.MutableBlockPos leafPos = new BlockPos.MutableBlockPos();
	private int leafCullMask;

	private OwnFrapi() {
	}

	static OwnApi.Mesher get(boolean ambientOcclusion, BlockColors blockColors, OwnQuads quads, Supplier<VertexConsumer> translucent) {
		OwnFrapi f = LOCAL.get();
		f.blocks = Renderer.get().altModelBlockRenderer(ambientOcclusion, true, blockColors);
		f.quads = quads;
		f.translucent = translucent;
		f.translucentSink = null;
		f.leafCullMask = 0;
		return f;
	}

	@Override
	public void block(float x, float y, float z, BlockAndTintGetter level, BlockPos pos, BlockState state, BlockStateModel model, long seed) {
		int mask = 0;
		if (OwnBlockRenderer.CULL_LEAVES && state.getBlock() instanceof net.minecraft.world.level.block.LeavesBlock) {
			int px = pos.getX(), py = pos.getY(), pz = pos.getZ();
			BlockPos.MutableBlockPos cur = this.leafPos;
			for (net.minecraft.core.Direction dir : DIRS) {
				int nx = px + dir.getStepX(), ny = py + dir.getStepY(), nz = pz + dir.getStepZ();
				BlockState nb = level.getBlockState(cur.set(nx, ny, nz));
				if (!(nb.getBlock() instanceof net.minecraft.world.level.block.LeavesBlock)) continue;
				net.minecraft.core.Direction opp = dir.getOpposite();
				boolean enclosed = true;
				for (net.minecraft.core.Direction d : DIRS) {
					if (d == opp) continue;
					BlockState ns = level.getBlockState(cur.set(nx + d.getStepX(), ny + d.getStepY(), nz + d.getStepZ()));
					if (!ns.isSolidRender() && !(ns.getBlock() instanceof net.minecraft.world.level.block.LeavesBlock)) {
						enclosed = false;
						break;
					}
				}
				if (enclosed) mask |= 1 << dir.ordinal();
			}
		}
		this.leafCullMask = mask;
		this.blocks.tesselateBlock(this.emitter, x, y, z, level, pos, state, model, seed);
		this.leafCullMask = 0;
	}

	private void emitted(MutableQuadView quad) {
		if (this.leafCullMask != 0) {
			net.minecraft.core.Direction cf = quad.cullFace();
			if (cf != null && (this.leafCullMask & (1 << cf.ordinal())) != 0) return;
		}
		ChunkSectionLayer layer = quad.chunkLayer();
		if (layer == ChunkSectionLayer.SOLID || layer == ChunkSectionLayer.CUTOUT) {
			// what quad.buffer + BufferBuilder (BLOCK format: position, ABGR colour, uv, packed light) would store, read straight
			// from the quad: no face normal (the BLOCK format has none), no per-vertex calls
			float[] p = this.p, uv = this.uv;
			int[] abgr = this.abgr, light = this.light;
			for (int v = 0; v < 4; v++) {
				p[v * 3] = quad.x(v);
				p[v * 3 + 1] = quad.y(v);
				p[v * 3 + 2] = quad.z(v);
				uv[v * 2] = quad.u(v);
				uv[v * 2 + 1] = quad.v(v);
				int c = quad.color(v);
				abgr[v] = c & 0xFF00FF00 | (c & 0xFF0000) >> 16 | (c & 0xFF) << 16;
				light[v] = quad.lightmap(v);
			}
			this.quads.layers[layer == ChunkSectionLayer.SOLID ? 0 : 1].quad(p, abgr, uv, light);
			return;
		}
		VertexConsumer sink = this.translucentSink;
		if (sink == null) sink = this.translucentSink = this.translucent.get();
		quad.buffer(OverlayTexture.NO_OVERLAY, sink);
	}
}
