package mcopt.metal.mixin.own;

import com.mojang.renderpearl.api.pipeline.RenderPipeline;
import mcopt.metal.own.OwnVignette;
import mcopt.metal.shade.Shade;
import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.gui.Hud;
import net.minecraft.resources.Identifier;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Redirect;

/** Keep the vanilla warning overlay, with a restrained darkness vignette while native shading is active. */
@Mixin(Hud.class)
abstract class OwnVignetteMixin {
	@Redirect(method = "extractVignette", at = @At(value = "FIELD",
		target = "Lnet/minecraft/client/gui/Hud;vignetteBrightness:F"))
	private float mcopt$darkVignette(Hud hud) {
		if (!Shade.ENABLED) return hud.vignetteBrightness;
		// Vanilla starts as soon as local light drops. Native shading already handles that adaptation.
		float dark = Math.clamp((hud.vignetteBrightness - 0.8f) / 0.2f, 0f, 1f);
		return 0.15f * dark * dark * (3f - 2f * dark);
	}

	@Redirect(method = "extractVignette", at = @At(value = "INVOKE",
		target = "Lnet/minecraft/client/gui/GuiGraphicsExtractor;blit(Lcom/mojang/renderpearl/api/pipeline/RenderPipeline;Lnet/minecraft/resources/Identifier;IIFFIIIII)V"))
	private void mcopt$neutralVignette(GuiGraphicsExtractor graphics, RenderPipeline pipeline, Identifier texture,
		int x, int y, float u, float v, int width, int height, int textureWidth, int textureHeight, int color) {
		if (!OwnVignette.skip(pipeline, color)) graphics.blit(pipeline, texture, x, y, u, v, width, height, textureWidth, textureHeight, color);
	}
}
