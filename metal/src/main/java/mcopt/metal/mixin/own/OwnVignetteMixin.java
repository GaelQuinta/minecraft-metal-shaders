package mcopt.metal.mixin.own;

import com.mojang.renderpearl.api.pipeline.RenderPipeline;
import mcopt.metal.own.OwnVignette;
import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.gui.Hud;
import net.minecraft.resources.Identifier;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Redirect;

/** Preserve the original extraction and ordering unless the verified vignette blend is the identity. */
@Mixin(Hud.class)
abstract class OwnVignetteMixin {
	@Redirect(method = "extractVignette", at = @At(value = "INVOKE",
		target = "Lnet/minecraft/client/gui/GuiGraphicsExtractor;blit(Lcom/mojang/renderpearl/api/pipeline/RenderPipeline;Lnet/minecraft/resources/Identifier;IIFFIIIII)V"))
	private void mcopt$neutralVignette(GuiGraphicsExtractor graphics, RenderPipeline pipeline, Identifier texture,
		int x, int y, float u, float v, int width, int height, int textureWidth, int textureHeight, int color) {
		if (!OwnVignette.skip(pipeline, color)) graphics.blit(pipeline, texture, x, y, u, v, width, height, textureWidth, textureHeight, color);
	}
}
