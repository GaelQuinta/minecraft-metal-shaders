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
package mcopt.metal.mixin.shade;

import mcopt.metal.shade.ShadeEntityCull;
import net.minecraft.client.Camera;
import net.minecraft.client.DeltaTracker;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.client.renderer.culling.Frustum;
import net.minecraft.client.renderer.extract.LevelExtractor;
import net.minecraft.client.renderer.state.level.LevelRenderState;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.phys.Vec3;
import org.jspecify.annotations.Nullable;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

/** (2.0.1) Hooks LevelExtractor to advance the per-frame occlusion cache and cull entities fully hidden behind solid blocks. */
@Mixin(LevelExtractor.class)
abstract class ShadeLevelExtractorMixin {
	@Shadow
	private @Nullable ClientLevel level;

	@Inject(method = "extractVisibleEntities", at = @At("HEAD"))
	private void mcopt$beginEntityCull(Camera camera, Frustum frustum, DeltaTracker deltaTracker, LevelRenderState output, CallbackInfo ci) {
		if (!ShadeEntityCull.ON || this.level == null) return;
		Vec3 pos = camera.position();
		ShadeEntityCull.beginFrame(this.level, pos.x(), pos.y(), pos.z());
	}

	@Inject(method = "isEntityVisible", at = @At("RETURN"), cancellable = true)
	private void mcopt$cullOccludedEntity(Entity entity, Frustum frustum, double camX, double camY, double camZ, float partialTicks,
		long chunkFadeDuration, CallbackInfoReturnable<Boolean> cir) {
		if (cir.getReturnValue() && ShadeEntityCull.ON && ShadeEntityCull.isEntityOccluded(this.level, entity, camX, camY, camZ)) {
			cir.setReturnValue(false);
		}
	}
}
