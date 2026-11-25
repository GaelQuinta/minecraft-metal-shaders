package mcopt.metal.mixin.own;

import com.mojang.blaze3d.vertex.PoseStack;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.SortedSet;
import mcopt.metal.own.OwnTerrain;
import mcopt.metal.own.OwnVisible;
import net.minecraft.client.Camera;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.client.renderer.LevelRenderer;
import net.minecraft.client.renderer.blockentity.state.BlockEntityRenderState;
import net.minecraft.client.renderer.chunk.SectionRenderDispatcher;
import net.minecraft.client.renderer.extract.LevelExtractor;
import net.minecraft.client.renderer.feature.ModelFeatureRenderer;
import net.minecraft.client.renderer.state.level.LevelRenderState;
import net.minecraft.core.BlockPos;
import net.minecraft.server.level.BlockDestructionProgress;
import net.minecraft.util.Util;
import net.minecraft.world.level.block.entity.BlockEntity;
import net.minecraft.world.phys.Vec3;
import org.jspecify.annotations.Nullable;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * -Dmcopt.own.int.visible=true: vanilla's per-frame block-entity extraction walks every visible section (~10k at RD 16) to find
 * the few hundred whose mesh renders block entities. Here only those sections are taken (OwnVisible's set, filtered to this
 * generation's visible ones, in vanilla's visible order), with vanilla's body otherwise unchanged (the same per-section test, the
 * same per-block-entity extraction, the global block entities after). =verify lets vanilla run and checks every frame that the
 * block entities ours would take, in order, are vanilla's.
 */
@Mixin(LevelExtractor.class)
abstract class OwnIntBlockEntitiesMixin {
	@Shadow
	@Final
	private Minecraft minecraft;
	@Shadow
	@Final
	private LevelRenderer levelRenderer;
	@Shadow
	private @Nullable ClientLevel level;
	@Unique
	private final int[] mcopt$count = new int[1];
	@Unique
	private long mcopt$frames, mcopt$bad, mcopt$lastLog;

	@Inject(method = "extractVisibleBlockEntities", at = @At("HEAD"), cancellable = true)
	private void mcopt$blockEntities(Camera camera, float deltaPartialTick, LevelRenderState levelRenderState, CallbackInfo ci) {
		if (!OwnVisible.ON && !OwnVisible.VERIFY || OwnTerrain.get() == null) return;
		long chunkFadeDuration = Util.toMillis(this.minecraft.options.chunkSectionFadeInTime().get());
		SectionRenderDispatcher.RenderSection[] sections = OwnVisible.visibleWithBlockEntities(this.mcopt$count);
		int n = this.mcopt$count[0];
		if (OwnVisible.VERIFY) {
			List<BlockEntity> ours = new ArrayList<>(), vanilla = new ArrayList<>();
			for (int i = 0; i < n; i++) collect(sections[i], chunkFadeDuration, ours);
			for (SectionRenderDispatcher.RenderSection s : this.levelRenderer.visibleSections()) collect(s, chunkFadeDuration, vanilla);
			this.mcopt$frames++;
			if (!ours.equals(vanilla)) this.mcopt$bad++;
			long now = System.nanoTime();
			if (now - this.mcopt$lastLog > 5_000_000_000L) {
				System.out.println("mcopt-own visible verify: " + this.mcopt$frames + " frames, block-entity sequence mismatches " + this.mcopt$bad
					+ " (this frame " + vanilla.size() + " block entities in " + n + " candidate sections)");
				this.mcopt$lastLog = now;
			}
			return;
		}
		// vanilla's body, over the candidate sections instead of every visible section
		Vec3 cameraPos = camera.position();
		double camX = cameraPos.x();
		double camY = cameraPos.y();
		double camZ = cameraPos.z();
		PoseStack poseStack = new PoseStack();
		for (int i = 0; i < n; i++) {
			SectionRenderDispatcher.RenderSection section = sections[i];
			List<BlockEntity> renderableBlockEntities = section.getSectionMesh().getRenderableBlockEntities();
			if (!renderableBlockEntities.isEmpty() && !(section.getVisibility(Util.getMillis(), chunkFadeDuration) < 0.3F)) {
				for (BlockEntity blockEntity : renderableBlockEntities) {
					if (mcopt.metal.shade.ShadeEntityCull.ON && mcopt.metal.shade.ShadeEntityCull.isBlockEntityOccluded(this.level, blockEntity, camX, camY, camZ)) {
						continue;
					}
					BlockPos blockPos = blockEntity.getBlockPos();
					SortedSet<BlockDestructionProgress> progresses = this.level.destructionProgress().get(blockPos.asLong());
					ModelFeatureRenderer.CrumblingOverlay breakProgress;
					if (progresses != null && !progresses.isEmpty()) {
						poseStack.pushPose();
						poseStack.translate(blockPos.getX() - camX, blockPos.getY() - camY, blockPos.getZ() - camZ);
						breakProgress = new ModelFeatureRenderer.CrumblingOverlay(progresses.last().getProgress(), poseStack.last());
						poseStack.popPose();
					} else {
						breakProgress = null;
					}
					BlockEntityRenderState state = this.levelRenderer.blockEntityRenderDispatcher().tryExtractRenderState(blockEntity, deltaPartialTick, breakProgress, false);
					if (state != null) levelRenderState.blockEntityRenderStates.add(state);
				}
			}
		}
		Iterator<BlockEntity> iterator = this.level.getGloballyRenderedBlockEntities().iterator();
		while (iterator.hasNext()) {
			BlockEntity blockEntity = iterator.next();
			if (blockEntity.isRemoved()) {
				iterator.remove();
			} else {
				BlockEntityRenderState state = this.levelRenderer.blockEntityRenderDispatcher().tryExtractRenderState(blockEntity, deltaPartialTick, null, true);
				if (state != null) levelRenderState.blockEntityRenderStates.add(state);
			}
		}
		ci.cancel();
	}

	@Unique
	private static void collect(SectionRenderDispatcher.RenderSection section, long fade, List<BlockEntity> out) {
		List<BlockEntity> list = section.getSectionMesh().getRenderableBlockEntities();
		if (!list.isEmpty() && !(section.getVisibility(Util.getMillis(), fade) < 0.3F)) out.addAll(list);
	}
}
