/*
 * Copyright 2026 mcopt-shade contributors
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
 * License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
 * law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
 * OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
 * limitations under the License.
 */
package mcopt.metal.mixin.shade;

import mcopt.metal.shade.ShadeOutput;
import mcopt.metal.shade.ShadeResolution;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.components.Button;
import net.minecraft.client.gui.screens.PauseScreen;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.network.chat.Component;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * M3.1: a "Resolución del mundo" button at the bottom of the pause menu (with a world loaded): each click cycles the native
 * shading's render resolution (ShadeResolution: auto, native, 2160p ... 1080p), applied on the next frame and kept in
 * config/mcopt.properties. Only with the native shading's TAAU (it owns the render scale). (M3.3's hidden frame generation
 * button went with upstream's frame generation in the mcopt 0.3 port.)
 * (1.1) Above them "Shaders..." opens ShadeSettingsScreen (look, light, sky and water settings); with
 * mcopt.shade.settingsButton=false it is left out. (1.2.1) With the shaders off it is the only button, opening ShadeOffScreen.
 */
@Mixin(PauseScreen.class)
abstract class ShadePauseScreenMixin extends Screen {
	protected ShadePauseScreenMixin(Component title) {
		super(title);
	}

	@Inject(method = "init", at = @At("TAIL"))
	private void mcopt$resolutionButton(CallbackInfo ci) {
		Minecraft mc = Minecraft.getInstance();
		if (mc.level == null) return;
		if (!mcopt.metal.shade.Shade.ENABLED) { // (1.2.1) shaders off: only "Shaders..." (ShadeOffScreen: the switch to turn them on)
			Screen self = this;
			this.addRenderableWidget(Button.builder(Component.literal("Shaders..."), button -> mc.gui.setScreen(new mcopt.metal.shade.ShadeOffScreen(self)))
				.bounds(this.width / 2 - 102, this.height - 28, 204, 20).build());
			return;
		}
		// M3.3 robustness: not when TAAU failed to set up (no render scale to choose; the button did nothing, run rb4);
		// mcopt.shade.robustFallback=false: M3.2 (shown anyway)
		boolean resolution = mcopt.metal.shade.taa.ShadeTaa.ON
			&& !(mcopt.metal.shade.taa.ShadeTaa.failed() && !"false".equals(System.getProperty("mcopt.shade.robustFallback")));
		// (2026-10-09) the output resolution's button to its right (ShadeOutput: the whole window at that resolution; with
		// mcopt.shade.outputMode=taau only the shaded frame, then not with Distant Horizons: "Nativa (DH)", does nothing)
		boolean output = resolution;
		if (resolution) {
			int w = mc.getWindow().getWidth(), h = mc.getWindow().getHeight();
			this.addRenderableWidget(Button.builder(Component.literal(ShadeResolution.label(w, h)), button -> {
				ShadeResolution.cycle(mc.gameDirectory.toPath());
				button.setMessage(Component.literal(ShadeResolution.label(mc.getWindow().getWidth(), mc.getWindow().getHeight())));
			}).bounds(output ? this.width / 2 - 206 : this.width / 2 - 102, this.height - 28, 204, 20).build());
		}
		if (output) {
			this.addRenderableWidget(Button.builder(Component.literal(ShadeOutput.label()), button -> {
				if (ShadeOutput.available()) ShadeOutput.cycle(mc.gameDirectory.toPath());
				button.setMessage(Component.literal(ShadeOutput.label()));
			}).tooltip(net.minecraft.client.gui.components.Tooltip.create(Component.literal(ShadeOutput.tooltip())))
				.bounds(this.width / 2 + 2, this.height - 28, 204, 20).build());
		}
		int row = resolution ? this.height - 52 : this.height - 28;
		if (mcopt.metal.shade.Shade.ENABLED && !"false".equals(System.getProperty("mcopt.shade.settingsButton"))) {
			Screen self = this;
			this.addRenderableWidget(Button.builder(Component.literal(mcopt.metal.shade.ShadeLang.t("Shaders...", "Shaders...")),
					button -> mc.gui.setScreen(new mcopt.metal.shade.ShadeSettingsScreen(self)))
				.tooltip(net.minecraft.client.gui.components.Tooltip.create(Component.literal(mcopt.metal.shade.ShadeLang.t(
					"Ajustes de los shaders: estilo, brillo, rayos de sol, neblina, nubes y agua.",
					"Shader settings: style, brightness, god rays, haze, clouds and water."))))
				.bounds(this.width / 2 - 102, row, 204, 20).build());
		}
	}
}
