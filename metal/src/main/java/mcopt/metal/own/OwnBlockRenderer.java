package mcopt.metal.own;

import com.mojang.blaze3d.vertex.QuadInstance;
import it.unimi.dsi.fastutil.ints.IntArrayList;
import it.unimi.dsi.fastutil.objects.ObjectArrayList;
import java.util.List;
import net.minecraft.client.color.block.BlockColors;
import net.minecraft.client.color.block.BlockTintSource;
import net.minecraft.client.renderer.block.BlockQuadOutput;
import net.minecraft.client.renderer.block.dispatch.BlockStateModel;
import net.minecraft.client.renderer.block.dispatch.BlockStateModelPart;
import net.minecraft.client.resources.model.geometry.BakedQuad;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.util.ARGB;
import net.minecraft.util.LightCoordsUtil;
import net.minecraft.util.RandomSource;
import net.minecraft.world.level.CardinalLighting;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.phys.Vec3;
import org.joml.Vector3fc;
import org.jspecify.annotations.Nullable;

/**
 * -Dmcopt.own.mesh.ao=true (with .region): vanilla's ModelBlockRenderer.tesselateBlock and BlockModelLighter's smooth (AO) and
 * flat lighting restated over OwnRegion with int coordinates: the same model parts, face culls, light and shade samples, float
 * arithmetic, blends, tints and quad order, so the same QuadInstance reaches the output for every quad. What goes: the BlockPos
 * objects (relative / setWithOffset), the list iterators, the lighter's hash caches. Tables: vanilla's AdjacencyInfo and
 * AmbientVertexRemap, generated from its source (indexed by Direction.ordinal(), which is get3DDataValue()).
 */
final class OwnBlockRenderer {
	static final boolean ON = Boolean.getBoolean("mcopt.own.mesh.ao");
	private static final Direction[] DIRECTIONS = Direction.values();
	// SizeInfo indices: DOWN 0, UP 1, NORTH 2, SOUTH 3, WEST 4, EAST 5, FLIP_DOWN 6, FLIP_UP 7, FLIP_NORTH 8, FLIP_SOUTH 9, FLIP_WEST 10, FLIP_EAST 11
	private static final Direction[][] CORNERS = {
		{Direction.WEST, Direction.EAST, Direction.NORTH, Direction.SOUTH},
		{Direction.EAST, Direction.WEST, Direction.NORTH, Direction.SOUTH},
		{Direction.UP, Direction.DOWN, Direction.EAST, Direction.WEST},
		{Direction.WEST, Direction.EAST, Direction.DOWN, Direction.UP},
		{Direction.UP, Direction.DOWN, Direction.NORTH, Direction.SOUTH},
		{Direction.DOWN, Direction.UP, Direction.NORTH, Direction.SOUTH},
	};
	/** [facing][vertex 0..3][8 SizeInfo indices]; doNonCubicWeight is true for every facing. */
	private static final int[][][] WEIGHTS = {
		{{10, 3, 10, 9, 4, 9, 4, 3}, {10, 2, 10, 8, 4, 8, 4, 2}, {11, 2, 11, 8, 5, 8, 5, 2}, {11, 3, 11, 9, 5, 9, 5, 3}},
		{{5, 3, 5, 9, 11, 9, 11, 3}, {5, 2, 5, 8, 11, 8, 11, 2}, {4, 2, 4, 8, 10, 8, 10, 2}, {4, 3, 4, 9, 10, 9, 10, 3}},
		{{1, 10, 1, 4, 7, 4, 7, 10}, {1, 11, 1, 5, 7, 5, 7, 11}, {0, 11, 0, 5, 6, 5, 6, 11}, {0, 10, 0, 4, 6, 4, 6, 10}},
		{{1, 10, 7, 10, 7, 4, 1, 4}, {0, 10, 6, 10, 6, 4, 0, 4}, {0, 11, 6, 11, 6, 5, 0, 5}, {1, 11, 7, 11, 7, 5, 1, 5}},
		{{1, 3, 1, 9, 7, 9, 7, 3}, {1, 2, 1, 8, 7, 8, 7, 2}, {0, 2, 0, 8, 6, 8, 6, 2}, {0, 3, 0, 9, 6, 9, 6, 3}},
		{{6, 3, 6, 9, 0, 9, 0, 3}, {6, 2, 6, 8, 0, 8, 0, 2}, {7, 2, 7, 8, 1, 8, 1, 2}, {7, 3, 7, 9, 1, 9, 1, 3}},
	};
	private static final int[][] REMAP = {{0, 1, 2, 3}, {2, 3, 0, 1}, {3, 0, 1, 2}, {0, 1, 2, 3}, {3, 0, 1, 2}, {1, 2, 3, 0}};
	private static final int[][] CX = new int[6][4], CY = new int[6][4], CZ = new int[6][4];

	static {
		for (int f = 0; f < 6; f++) {
			for (int k = 0; k < 4; k++) {
				CX[f][k] = CORNERS[f][k].getStepX();
				CY[f][k] = CORNERS[f][k].getStepY();
				CZ[f][k] = CORNERS[f][k].getStepZ();
			}
		}
	}

	private static final ThreadLocal<OwnBlockRenderer> LOCAL = ThreadLocal.withInitial(OwnBlockRenderer::new);
	private boolean ambientOcclusion;
	private BlockColors blockColors;
	private final RandomSource random = RandomSource.createThreadLocalInstance(0L);
	private final List<BlockStateModelPart> parts = new ObjectArrayList<>();
	private final BlockPos.MutableBlockPos scratchPos = new BlockPos.MutableBlockPos();
	private final QuadInstance quadInstance = new QuadInstance();
	private int tintCacheIndex = -1;
	private int tintCacheValue;
	private boolean tintSourcesInitialized;
	private final List<@Nullable BlockTintSource> tintSources = new ObjectArrayList<>();
	private final IntArrayList computedTintValues = new IntArrayList();
	// the lighter's per-quad shape state
	private boolean faceCubic, facePartial;
	private final float[] faceShape = new float[12];

	/** This thread's renderer, set up for a compile (one per thread, reused). */
	static OwnBlockRenderer get(boolean ambientOcclusion, BlockColors blockColors) {
		OwnBlockRenderer r = LOCAL.get();
		r.ambientOcclusion = ambientOcclusion;
		r.blockColors = blockColors;
		return r;
	}

	void tesselateBlock(BlockQuadOutput output, float x, float y, float z, OwnRegion level, BlockPos pos, BlockState blockState, BlockStateModel model, long seed) {
		this.random.setSeed(seed);
		model.collectParts(this.random, this.parts);
		if (!this.parts.isEmpty()) {
			try {
				Vec3 offset = blockState.getOffset(pos);
				if (this.ambientOcclusion && blockState.getLightEmission() == 0 && this.parts.getFirst().useAmbientOcclusion()) {
					this.tesselateAmbientOcclusion(output, x + (float) offset.x, y + (float) offset.y, z + (float) offset.z, level, blockState, pos);
				} else {
					this.tesselateFlat(output, x + (float) offset.x, y + (float) offset.y, z + (float) offset.z, level, blockState, pos);
				}
			} finally {
				this.parts.clear();
				this.resetTintCache();
			}
		}
	}

	private void resetTintCache() {
		this.tintCacheIndex = -1;
		if (this.tintSourcesInitialized) {
			this.tintSources.clear();
			this.computedTintValues.clear();
			this.tintSourcesInitialized = false;
		}
	}

	/** (2.0.1) Smart depth-2 interior leaf culling when shading is active (off when mcopt.shade=false or -Dmcopt.shade.cullLeaves=false). */
	static final boolean CULL_LEAVES = mcopt.metal.shade.Shade.ENABLED && !"false".equals(System.getProperty("mcopt.shade.cullLeaves"));

	private static boolean isLeafOpaque(BlockState s) {
		return s.isSolidRender() || s.getBlock() instanceof net.minecraft.world.level.block.LeavesBlock;
	}

	private boolean shouldRenderFace(OwnRegion level, BlockState state, Direction direction, int px, int py, int pz) {
		int nx = px + direction.getStepX(), ny = py + direction.getStepY(), nz = pz + direction.getStepZ();
		BlockState neighbor = level.stateAt(nx, ny, nz);
		if (!Block.shouldRenderFace(state, neighbor, direction)) return false;
		if (CULL_LEAVES && state.getBlock() instanceof net.minecraft.world.level.block.LeavesBlock
			&& neighbor.getBlock() instanceof net.minecraft.world.level.block.LeavesBlock) {
			// Cull interior leaf-to-leaf face ONLY when the neighbor leaf is completely enclosed on all 5 other sides by leaves or solid blocks:
			// preserves the entire outer leaf shell and the 2nd visible layer behind alpha holes while cutting ~40-60% of buried interior leaf quads.
			Direction opp = direction.getOpposite();
			for (Direction d : DIRECTIONS) {
				if (d == opp) continue;
				if (!isLeafOpaque(level.stateAt(nx + d.getStepX(), ny + d.getStepY(), nz + d.getStepZ()))) return true;
			}
			return false;
		}
		return true;
	}

	private void tesselateAmbientOcclusion(BlockQuadOutput output, float x, float y, float z, OwnRegion level, BlockState state, BlockPos pos) {
		int px = pos.getX(), py = pos.getY(), pz = pos.getZ();
		int cacheValid = 0, shouldRenderFaceCache = 0;
		List<BlockStateModelPart> parts = this.parts;
		for (int p = 0, np = parts.size(); p < np; p++) {
			BlockStateModelPart part = parts.get(p);
			for (Direction direction : DIRECTIONS) {
				int cacheMask = 1 << direction.ordinal();
				boolean validCacheForDirection = (cacheValid & cacheMask) != 0;
				boolean shouldRenderFace = (shouldRenderFaceCache & cacheMask) != 0;
				if (!validCacheForDirection || shouldRenderFace) {
					List<BakedQuad> culledQuads = part.getQuads(direction);
					if (!culledQuads.isEmpty()) {
						if (!validCacheForDirection) {
							shouldRenderFace = this.shouldRenderFace(level, state, direction, px, py, pz);
							cacheValid |= cacheMask;
							if (shouldRenderFace) shouldRenderFaceCache |= cacheMask;
						}
						if (shouldRenderFace) {
							for (int q = 0, nq = culledQuads.size(); q < nq; q++) {
								BakedQuad quad = culledQuads.get(q);
								this.prepareQuadAmbientOcclusion(level, state, pos, px, py, pz, quad);
								this.putQuadWithTint(output, x, y, z, level, state, pos, quad);
							}
						}
					}
				}
			}
			List<BakedQuad> unculled = part.getQuads(null);
			for (int q = 0, nq = unculled.size(); q < nq; q++) {
				BakedQuad quad = unculled.get(q);
				this.prepareQuadAmbientOcclusion(level, state, pos, px, py, pz, quad);
				this.putQuadWithTint(output, x, y, z, level, state, pos, quad);
			}
		}
	}

	private void tesselateFlat(BlockQuadOutput output, float x, float y, float z, OwnRegion level, BlockState state, BlockPos pos) {
		int px = pos.getX(), py = pos.getY(), pz = pos.getZ();
		int cacheValid = 0, shouldRenderFaceCache = 0;
		List<BlockStateModelPart> parts = this.parts;
		for (int p = 0, np = parts.size(); p < np; p++) {
			BlockStateModelPart part = parts.get(p);
			for (Direction direction : DIRECTIONS) {
				int cacheMask = 1 << direction.ordinal();
				boolean validCacheForDirection = (cacheValid & cacheMask) != 0;
				boolean shouldRenderFace = (shouldRenderFaceCache & cacheMask) != 0;
				if (!validCacheForDirection || shouldRenderFace) {
					List<BakedQuad> culledQuads = part.getQuads(direction);
					if (!culledQuads.isEmpty()) {
						if (!validCacheForDirection) {
							shouldRenderFace = this.shouldRenderFace(level, state, direction, px, py, pz);
							cacheValid |= cacheMask;
							if (shouldRenderFace) shouldRenderFaceCache |= cacheMask;
						}
						if (shouldRenderFace) {
							// the block's own state with the neighbour's light, as BlockModelLighter.getLightCoords(state, level, relativePos)
							int lightCoords = level.lightAt(state, px + direction.getStepX(), py + direction.getStepY(), pz + direction.getStepZ());
							for (int q = 0, nq = culledQuads.size(); q < nq; q++) {
								BakedQuad quad = culledQuads.get(q);
								this.prepareQuadFlat(level, state, pos, px, py, pz, lightCoords, quad);
								this.putQuadWithTint(output, x, y, z, level, state, pos, quad);
							}
						}
					}
				}
			}
			List<BakedQuad> unculled = part.getQuads(null);
			for (int q = 0, nq = unculled.size(); q < nq; q++) {
				BakedQuad quad = unculled.get(q);
				this.prepareQuadFlat(level, state, pos, px, py, pz, -1, quad);
				this.putQuadWithTint(output, x, y, z, level, state, pos, quad);
			}
		}
	}

	private final int[] aoSplit = new int[4];
	/** OwnQrec: the compile's quad sink (set by OwnMesher), told each quad's pre-tint colours and tint. */
	@Nullable OwnQuads qrecSink;

	private void putQuadWithTint(BlockQuadOutput output, float x, float y, float z, OwnRegion level, BlockState state, BlockPos pos, BakedQuad quad) {
		// native shading: OwnIntAoMixin's split, restated (the AO grey out before the tint, back as the corners' alpha after)
		if (OwnQrStat.ON) {
			// (measurement: were the corners grey before the tint, so the colour is exactly grey x tint?)
			boolean grey = true;
			for (int v = 0; v < 4; v++) {
				int c = this.quadInstance.getColor(v);
				grey &= (c >>> 24) == 255 && (c >> 16 & 255) == (c >> 8 & 255) && (c >> 8 & 255) == (c & 255);
			}
			OwnQrStat.GREY.get()[0] = grey ? 1 : 0;
		}
		boolean split = OwnMaterials.ON && OwnMaterials.compiling();
		if (split) {
			for (int v = 0; v < 4; v++) {
				this.aoSplit[v] = this.quadInstance.getColor(v) >>> 8 & 0xFF;
				this.quadInstance.setColor(v, -1);
			}
		}
		int tintIndex = quad.materialInfo().tintIndex();
		if (OwnQrec.ON && this.qrecSink != null) {
			// (OwnQrec: the corners before the tint, and the tint, so the record can hold grey x tint; checked against the result)
			int tint = tintIndex != -1 ? this.getTintColor(level, state, pos, tintIndex) : -1;
			QuadInstance qi = this.quadInstance;
			this.qrecSink.hint(qi.getColor(0), qi.getColor(1), qi.getColor(2), qi.getColor(3), tint);
			if (tintIndex != -1) qi.multiplyColor(tint);
		} else if (tintIndex != -1) this.quadInstance.multiplyColor(this.getTintColor(level, state, pos, tintIndex));
		if (split) for (int v = 0; v < 4; v++) this.quadInstance.setColor(v, this.quadInstance.getColor(v) & 0x00FFFFFF | this.aoSplit[v] << 24);
		output.put(x, y, z, quad, this.quadInstance);
	}

	private int getTintColor(OwnRegion level, BlockState state, BlockPos pos, int tintIndex) {
		if (this.tintCacheIndex == tintIndex) return this.tintCacheValue;
		int tintColor = this.computeTintColor(level, state, pos, tintIndex);
		this.tintCacheIndex = tintIndex;
		this.tintCacheValue = tintColor;
		return tintColor;
	}

	private int computeTintColor(OwnRegion level, BlockState state, BlockPos pos, int tintIndex) {
		if (!this.tintSourcesInitialized) {
			List<BlockTintSource> sources = this.blockColors.getTintSources(state);
			int n = sources.size();
			if (n > 0) {
				this.tintSources.addAll(sources);
				for (int i = 0; i < n; i++) this.computedTintValues.add(-1);
			}
			this.tintSourcesInitialized = true;
		}
		if (tintIndex >= this.tintSources.size()) return -1;
		BlockTintSource tintSource = this.tintSources.set(tintIndex, null);
		if (tintSource != null) {
			int computedTintValue = tintSource.colorInWorld(state, level, pos);
			this.computedTintValues.set(tintIndex, computedTintValue);
			return computedTintValue;
		}
		return this.computedTintValues.getInt(tintIndex);
	}

	// ---- BlockModelLighter, restated ----

	private void prepareQuadFlat(OwnRegion level, BlockState state, BlockPos pos, int px, int py, int pz, int lightCoords, BakedQuad quad) {
		QuadInstance out = this.quadInstance;
		if (lightCoords == -1) {
			this.prepareQuadShape(level, state, pos, quad, false);
			Direction d = quad.direction();
			out.setLightCoords(this.faceCubic ? level.lightAt(state, px + d.getStepX(), py + d.getStepY(), pz + d.getStepZ()) : level.lightAt(state, px, py, pz));
		} else {
			out.setLightCoords(lightCoords);
		}
		out.setColor(ARGB.gray(directionalBrightness(level.cardinalLighting(), quad, quad.direction())));
	}

	private static float directionalBrightness(CardinalLighting cardinalLighting, BakedQuad quad, Direction actualDirection) {
		Direction override = quad.materialInfo().shadeDirectionOverride();
		return override != null ? cardinalLighting.byFace(override) : cardinalLighting.byFace(actualDirection);
	}

	private void prepareQuadShape(OwnRegion level, BlockState state, BlockPos pos, BakedQuad quad, boolean ambientOcclusion) {
		float minX = 32.0F, minY = 32.0F, minZ = 32.0F, maxX = -32.0F, maxY = -32.0F, maxZ = -32.0F;
		for (int i = 0; i < 4; i++) {
			Vector3fc position = quad.position(i);
			float x = position.x(), y = position.y(), z = position.z();
			minX = Math.min(minX, x);
			minY = Math.min(minY, y);
			minZ = Math.min(minZ, z);
			maxX = Math.max(maxX, x);
			maxY = Math.max(maxY, y);
			maxZ = Math.max(maxZ, z);
		}
		if (ambientOcclusion) {
			float[] s = this.faceShape;
			s[4] = minX;
			s[5] = maxX;
			s[0] = minY;
			s[1] = maxY;
			s[2] = minZ;
			s[3] = maxZ;
			s[10] = 1.0F - minX;
			s[11] = 1.0F - maxX;
			s[6] = 1.0F - minY;
			s[7] = 1.0F - maxY;
			s[8] = 1.0F - minZ;
			s[9] = 1.0F - maxZ;
		}
		// switches on the ordinal (DOWN 0, UP 1, NORTH 2, SOUTH 3, WEST 4, EAST 5): an enum switch on a foreign enum goes
		// through an invokedynamic bootstrap that the profile shows; same branches as vanilla's
		int d = quad.direction().ordinal();
		this.facePartial = switch (d) {
			case 0, 1 -> minX >= 1.0E-4F || minZ >= 1.0E-4F || maxX <= 0.9999F || maxZ <= 0.9999F;
			case 2, 3 -> minX >= 1.0E-4F || minY >= 1.0E-4F || maxX <= 0.9999F || maxY <= 0.9999F;
			default -> minY >= 1.0E-4F || minZ >= 1.0E-4F || maxY <= 0.9999F || maxZ <= 0.9999F;
		};
		this.faceCubic = switch (d) {
			case 0 -> minY == maxY && (minY < 1.0E-4F || state.isCollisionShapeFullBlock(level, pos));
			case 1 -> minY == maxY && (maxY > 0.9999F || state.isCollisionShapeFullBlock(level, pos));
			case 2 -> minZ == maxZ && (minZ < 1.0E-4F || state.isCollisionShapeFullBlock(level, pos));
			case 3 -> minZ == maxZ && (maxZ > 0.9999F || state.isCollisionShapeFullBlock(level, pos));
			case 4 -> minX == maxX && (minX < 1.0E-4F || state.isCollisionShapeFullBlock(level, pos));
			default -> minX == maxX && (maxX > 0.9999F || state.isCollisionShapeFullBlock(level, pos));
		};
	}

	private void prepareQuadAmbientOcclusion(OwnRegion level, BlockState state, BlockPos centerPosition, int px, int py, int pz, BakedQuad quad) {
		if (OwnRegion.AOCACHE) {
			this.prepareQuadAmbientOcclusionCached(level, state, centerPosition, px, py, pz, quad);
			return;
		}
		this.prepareQuadShape(level, state, centerPosition, quad, true);
		Direction direction = quad.direction();
		int f = direction.ordinal();
		int dx = direction.getStepX(), dy = direction.getStepY(), dz = direction.getStepZ();
		int bx = this.faceCubic ? px + dx : px, by = this.faceCubic ? py + dy : py, bz = this.faceCubic ? pz + dz : pz;
		int[] cx = CX[f], cy = CY[f], cz = CZ[f];
		int x0 = bx + cx[0], y0 = by + cy[0], z0 = bz + cz[0];
		BlockState state0 = level.stateAt(x0, y0, z0);
		int light0 = level.lightAt(state0, x0, y0, z0);
		float shade0 = level.shadeAt(state0, x0, y0, z0);
		int x1 = bx + cx[1], y1 = by + cy[1], z1 = bz + cz[1];
		BlockState state1 = level.stateAt(x1, y1, z1);
		int light1 = level.lightAt(state1, x1, y1, z1);
		float shade1 = level.shadeAt(state1, x1, y1, z1);
		int x2 = bx + cx[2], y2 = by + cy[2], z2 = bz + cz[2];
		BlockState state2 = level.stateAt(x2, y2, z2);
		int light2 = level.lightAt(state2, x2, y2, z2);
		float shade2 = level.shadeAt(state2, x2, y2, z2);
		int x3 = bx + cx[3], y3 = by + cy[3], z3 = bz + cz[3];
		BlockState state3 = level.stateAt(x3, y3, z3);
		int light3 = level.lightAt(state3, x3, y3, z3);
		float shade3 = level.shadeAt(state3, x3, y3, z3);
		boolean lightPermeable0 = level.stateAt(x0 + dx, y0 + dy, z0 + dz).isLightPermeable();
		boolean lightPermeable1 = level.stateAt(x1 + dx, y1 + dy, z1 + dz).isLightPermeable();
		boolean lightPermeable2 = level.stateAt(x2 + dx, y2 + dy, z2 + dz).isLightPermeable();
		boolean lightPermeable3 = level.stateAt(x3 + dx, y3 + dy, z3 + dz).isLightPermeable();
		float shadeCorner02;
		int lightCorner02;
		if (!lightPermeable2 && !lightPermeable0) {
			shadeCorner02 = shade0;
			lightCorner02 = light0;
		} else {
			int x = x0 + cx[2], y = y0 + cy[2], z = z0 + cz[2];
			BlockState s = level.stateAt(x, y, z);
			shadeCorner02 = level.shadeAt(s, x, y, z);
			lightCorner02 = level.lightAt(s, x, y, z);
		}
		float shadeCorner03;
		int lightCorner03;
		if (!lightPermeable3 && !lightPermeable0) {
			shadeCorner03 = shade0;
			lightCorner03 = light0;
		} else {
			int x = x0 + cx[3], y = y0 + cy[3], z = z0 + cz[3];
			BlockState s = level.stateAt(x, y, z);
			shadeCorner03 = level.shadeAt(s, x, y, z);
			lightCorner03 = level.lightAt(s, x, y, z);
		}
		float shadeCorner12;
		int lightCorner12;
		if (!lightPermeable2 && !lightPermeable1) {
			shadeCorner12 = shade0;
			lightCorner12 = light0;
		} else {
			int x = x1 + cx[2], y = y1 + cy[2], z = z1 + cz[2];
			BlockState s = level.stateAt(x, y, z);
			shadeCorner12 = level.shadeAt(s, x, y, z);
			lightCorner12 = level.lightAt(s, x, y, z);
		}
		float shadeCorner13;
		int lightCorner13;
		if (!lightPermeable3 && !lightPermeable1) {
			shadeCorner13 = shade0;
			lightCorner13 = light0;
		} else {
			int x = x1 + cx[3], y = y1 + cy[3], z = z1 + cz[3];
			BlockState s = level.stateAt(x, y, z);
			shadeCorner13 = level.shadeAt(s, x, y, z);
			lightCorner13 = level.lightAt(s, x, y, z);
		}
		int lightCenter = level.lightAt(state, px, py, pz);
		BlockState nextState = level.stateAt(px + dx, py + dy, pz + dz);
		if (this.faceCubic || !nextState.isSolidRender()) lightCenter = level.lightAt(nextState, px + dx, py + dy, pz + dz);
		float shadeCenter = this.faceCubic ? level.shadeAt(level.stateAt(bx, by, bz), bx, by, bz) : level.shadeAt(level.stateAt(px, py, pz), px, py, pz);
		int[] remap = REMAP[f];
		QuadInstance out = this.quadInstance;
		if (this.facePartial) {
			float[] s = this.faceShape;
			int[][] w = WEIGHTS[f];
			float tempShade1 = (shade3 + shade0 + shadeCorner03 + shadeCenter) * 0.25F;
			float tempShade2 = (shade2 + shade0 + shadeCorner02 + shadeCenter) * 0.25F;
			float tempShade3 = (shade2 + shade1 + shadeCorner12 + shadeCenter) * 0.25F;
			float tempShade4 = (shade3 + shade1 + shadeCorner13 + shadeCenter) * 0.25F;
			int tc1 = LightCoordsUtil.smoothBlend(light3, light0, lightCorner03, lightCenter);
			int tc2 = LightCoordsUtil.smoothBlend(light2, light0, lightCorner02, lightCenter);
			int tc3 = LightCoordsUtil.smoothBlend(light2, light1, lightCorner12, lightCenter);
			int tc4 = LightCoordsUtil.smoothBlend(light3, light1, lightCorner13, lightCenter);
			for (int v = 0; v < 4; v++) {
				int[] wv = w[v];
				float w01 = s[wv[0]] * s[wv[1]], w23 = s[wv[2]] * s[wv[3]], w45 = s[wv[4]] * s[wv[5]], w67 = s[wv[6]] * s[wv[7]];
				out.setColor(remap[v], ARGB.gray(Math.clamp(tempShade1 * w01 + tempShade2 * w23 + tempShade3 * w45 + tempShade4 * w67, 0.0F, 1.0F)));
				out.setLightCoords(remap[v], LightCoordsUtil.smoothWeightedBlend(tc1, tc2, tc3, tc4, w01, w23, w45, w67));
			}
		} else {
			float lightLevel1 = (shade3 + shade0 + shadeCorner03 + shadeCenter) * 0.25F;
			float lightLevel2 = (shade2 + shade0 + shadeCorner02 + shadeCenter) * 0.25F;
			float lightLevel3 = (shade2 + shade1 + shadeCorner12 + shadeCenter) * 0.25F;
			float lightLevel4 = (shade3 + shade1 + shadeCorner13 + shadeCenter) * 0.25F;
			out.setLightCoords(remap[0], LightCoordsUtil.smoothBlend(light3, light0, lightCorner03, lightCenter));
			out.setLightCoords(remap[1], LightCoordsUtil.smoothBlend(light2, light0, lightCorner02, lightCenter));
			out.setLightCoords(remap[2], LightCoordsUtil.smoothBlend(light2, light1, lightCorner12, lightCenter));
			out.setLightCoords(remap[3], LightCoordsUtil.smoothBlend(light3, light1, lightCorner13, lightCenter));
			out.setColor(remap[0], ARGB.gray(lightLevel1));
			out.setColor(remap[1], ARGB.gray(lightLevel2));
			out.setColor(remap[2], ARGB.gray(lightLevel3));
			out.setColor(remap[3], ARGB.gray(lightLevel4));
		}
		out.scaleColor(directionalBrightness(level.cardinalLighting(), quad, direction));
	}

	private void prepareQuadAmbientOcclusionCached(OwnRegion level, BlockState state, BlockPos centerPosition, int px, int py, int pz, BakedQuad quad) {
		this.prepareQuadShape(level, state, centerPosition, quad, true);
		// AOCACHE: every sample through the per-position memo (same values as the stateAt / lightAt / shadeAt calls it replaces)
		Direction direction = quad.direction();
		int f = direction.ordinal();
		int dx = direction.getStepX(), dy = direction.getStepY(), dz = direction.getStepZ();
		int bx = this.faceCubic ? px + dx : px, by = this.faceCubic ? py + dy : py, bz = this.faceCubic ? pz + dz : pz;
		int[] cx = CX[f], cy = CY[f], cz = CZ[f];
		int x0 = bx + cx[0], y0 = by + cy[0], z0 = bz + cz[0];
		int light0 = aoL(level, x0, y0, z0);
		float shade0 = aoS(level, x0, y0, z0);
		int x1 = bx + cx[1], y1 = by + cy[1], z1 = bz + cz[1];
		int light1 = aoL(level, x1, y1, z1);
		float shade1 = aoS(level, x1, y1, z1);
		int x2 = bx + cx[2], y2 = by + cy[2], z2 = bz + cz[2];
		int light2 = aoL(level, x2, y2, z2);
		float shade2 = aoS(level, x2, y2, z2);
		int x3 = bx + cx[3], y3 = by + cy[3], z3 = bz + cz[3];
		int light3 = aoL(level, x3, y3, z3);
		float shade3 = aoS(level, x3, y3, z3);
		boolean lightPermeable0 = aoP(level, x0 + dx, y0 + dy, z0 + dz);
		boolean lightPermeable1 = aoP(level, x1 + dx, y1 + dy, z1 + dz);
		boolean lightPermeable2 = aoP(level, x2 + dx, y2 + dy, z2 + dz);
		boolean lightPermeable3 = aoP(level, x3 + dx, y3 + dy, z3 + dz);
		float shadeCorner02;
		int lightCorner02;
		if (!lightPermeable2 && !lightPermeable0) {
			shadeCorner02 = shade0;
			lightCorner02 = light0;
		} else {
			int x = x0 + cx[2], y = y0 + cy[2], z = z0 + cz[2];
			shadeCorner02 = aoS(level, x, y, z);
			lightCorner02 = aoL(level, x, y, z);
		}
		float shadeCorner03;
		int lightCorner03;
		if (!lightPermeable3 && !lightPermeable0) {
			shadeCorner03 = shade0;
			lightCorner03 = light0;
		} else {
			int x = x0 + cx[3], y = y0 + cy[3], z = z0 + cz[3];
			shadeCorner03 = aoS(level, x, y, z);
			lightCorner03 = aoL(level, x, y, z);
		}
		float shadeCorner12;
		int lightCorner12;
		if (!lightPermeable2 && !lightPermeable1) {
			shadeCorner12 = shade0;
			lightCorner12 = light0;
		} else {
			int x = x1 + cx[2], y = y1 + cy[2], z = z1 + cz[2];
			shadeCorner12 = aoS(level, x, y, z);
			lightCorner12 = aoL(level, x, y, z);
		}
		float shadeCorner13;
		int lightCorner13;
		if (!lightPermeable3 && !lightPermeable1) {
			shadeCorner13 = shade0;
			lightCorner13 = light0;
		} else {
			int x = x1 + cx[3], y = y1 + cy[3], z = z1 + cz[3];
			shadeCorner13 = aoS(level, x, y, z);
			lightCorner13 = aoL(level, x, y, z);
		}
		// the centre block's state is the state at the centre position (the block loop reads it there)
		int lightCenter = aoL(level, px, py, pz);
		BlockState nextState = level.stateAt(px + dx, py + dy, pz + dz);
		if (this.faceCubic || !nextState.isSolidRender()) lightCenter = aoL(level, px + dx, py + dy, pz + dz);
		float shadeCenter = this.faceCubic ? aoS(level, bx, by, bz) : aoS(level, px, py, pz);
		int[] remap = REMAP[f];
		QuadInstance out = this.quadInstance;
		if (this.facePartial) {
			float[] s = this.faceShape;
			int[][] w = WEIGHTS[f];
			float tempShade1 = (shade3 + shade0 + shadeCorner03 + shadeCenter) * 0.25F;
			float tempShade2 = (shade2 + shade0 + shadeCorner02 + shadeCenter) * 0.25F;
			float tempShade3 = (shade2 + shade1 + shadeCorner12 + shadeCenter) * 0.25F;
			float tempShade4 = (shade3 + shade1 + shadeCorner13 + shadeCenter) * 0.25F;
			int tc1 = LightCoordsUtil.smoothBlend(light3, light0, lightCorner03, lightCenter);
			int tc2 = LightCoordsUtil.smoothBlend(light2, light0, lightCorner02, lightCenter);
			int tc3 = LightCoordsUtil.smoothBlend(light2, light1, lightCorner12, lightCenter);
			int tc4 = LightCoordsUtil.smoothBlend(light3, light1, lightCorner13, lightCenter);
			for (int v = 0; v < 4; v++) {
				int[] wv = w[v];
				float w01 = s[wv[0]] * s[wv[1]], w23 = s[wv[2]] * s[wv[3]], w45 = s[wv[4]] * s[wv[5]], w67 = s[wv[6]] * s[wv[7]];
				out.setColor(remap[v], ARGB.gray(Math.clamp(tempShade1 * w01 + tempShade2 * w23 + tempShade3 * w45 + tempShade4 * w67, 0.0F, 1.0F)));
				out.setLightCoords(remap[v], LightCoordsUtil.smoothWeightedBlend(tc1, tc2, tc3, tc4, w01, w23, w45, w67));
			}
		} else {
			float lightLevel1 = (shade3 + shade0 + shadeCorner03 + shadeCenter) * 0.25F;
			float lightLevel2 = (shade2 + shade0 + shadeCorner02 + shadeCenter) * 0.25F;
			float lightLevel3 = (shade2 + shade1 + shadeCorner12 + shadeCenter) * 0.25F;
			float lightLevel4 = (shade3 + shade1 + shadeCorner13 + shadeCenter) * 0.25F;
			out.setLightCoords(remap[0], LightCoordsUtil.smoothBlend(light3, light0, lightCorner03, lightCenter));
			out.setLightCoords(remap[1], LightCoordsUtil.smoothBlend(light2, light0, lightCorner02, lightCenter));
			out.setLightCoords(remap[2], LightCoordsUtil.smoothBlend(light2, light1, lightCorner12, lightCenter));
			out.setLightCoords(remap[3], LightCoordsUtil.smoothBlend(light3, light1, lightCorner13, lightCenter));
			out.setColor(remap[0], ARGB.gray(lightLevel1));
			out.setColor(remap[1], ARGB.gray(lightLevel2));
			out.setColor(remap[2], ARGB.gray(lightLevel3));
			out.setColor(remap[3], ARGB.gray(lightLevel4));
		}
		out.scaleColor(directionalBrightness(level.cardinalLighting(), quad, direction));
	}

	private static int aoL(OwnRegion level, int x, int y, int z) {
		int i = level.aoIndex(x, y, z);
		return i >= 0 ? level.aoLight(i, x, y, z) : level.lightAt(level.stateAt(x, y, z), x, y, z);
	}

	private static float aoS(OwnRegion level, int x, int y, int z) {
		int i = level.aoIndex(x, y, z);
		return i >= 0 ? level.aoShade(i, x, y, z) : level.shadeAt(level.stateAt(x, y, z), x, y, z);
	}

	private static boolean aoP(OwnRegion level, int x, int y, int z) {
		int i = level.aoIndex(x, y, z);
		return i >= 0 ? level.aoPerm(i, x, y, z) : level.stateAt(x, y, z).isLightPermeable();
	}
}
