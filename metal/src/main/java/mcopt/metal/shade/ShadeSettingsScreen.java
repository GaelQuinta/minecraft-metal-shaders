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
package mcopt.metal.shade;

import com.mojang.serialization.Codec;
import java.util.ArrayList;
import java.util.List;
import net.minecraft.ChatFormatting;
import net.minecraft.client.Minecraft;
import net.minecraft.client.OptionInstance;
import net.minecraft.client.Options;
import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.gui.components.AbstractWidget;
import net.minecraft.client.gui.components.Button;
import net.minecraft.client.gui.components.Tooltip;
import net.minecraft.client.gui.layouts.LinearLayout;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.gui.screens.options.OptionsSubScreen;
import net.minecraft.network.chat.CommonComponents;
import net.minecraft.network.chat.Component;

/**
 * (1.1) The shader settings, from the pause menu's "Shaders..." button, laid out like the game's own option screens: the main
 * page (preset, style and a button per page of ShadeOptions) and one page each (sliders and cycling buttons, two per row, under
 * section headers). Every text is in Spanish or English by the game's language (ShadeLang). Changes show on the next frame
 * behind the screen (no blur over the world, so a slider's effect can be judged while dragging it); options marked * apply at
 * the next start. Leaving a page writes the changed settings to config/mcopt.properties (ShadeSettings.save).
 */
public final class ShadeSettingsScreen extends OptionsSubScreen {
	/** null: the main page. */
	private final ShadeOptions.Page page;

	public ShadeSettingsScreen(Screen lastScreen) {
		this(lastScreen, null);
	}

	private ShadeSettingsScreen(Screen lastScreen, ShadeOptions.Page page) {
		super(lastScreen, Minecraft.getInstance().options,
			Component.literal(page == null ? ShadeLang.t("Ajustes de shaders", "Shader settings") : page.title()));
		this.page = page;
	}

	private static String t(String es, String en) {
		return ShadeLang.t(es, en);
	}

	private static Component header(String es, String en) {
		return Component.literal(t(es, en)).withStyle(ChatFormatting.UNDERLINE, ChatFormatting.BOLD);
	}

	/** The option's widget: a slider (applied while dragging) or a cycling button. Captions are translation keys: no '%' in them. */
	static OptionInstance<Integer> instance(ShadeOption o) {
		String cap = o.caption().replace("%", "");
		String tip = o.tooltip();
		OptionInstance.TooltipSupplier<Integer> tooltip = tip == null ? OptionInstance.noTooltip() : OptionInstance.cachedConstantTooltip(Component.literal(tip));
		if (o.kind == ShadeOption.Kind.SLIDER) {
			return new OptionInstance<>(cap, tooltip, (c, v) -> Options.genericValueLabel(c, Component.literal(o.valueText(v))),
				new OptionInstance.IntRange(o.min, o.max), o.pos(), o::set);
		}
		List<Integer> values = new ArrayList<>();
		for (int i = o.min; i <= o.max; i++) values.add(i);
		// (the cycling button puts "caption: " in front of this)
		return new OptionInstance<>(cap, tooltip, (c, v) -> Component.literal(o.valueText(v)), new OptionInstance.Enum<>(values, Codec.INT), o.pos(), o::set);
	}

	@Override
	protected void addOptions() {
		if (this.list == null) return;
		if (this.page == null) {
			this.list.addHeader(header("Calidad", "Quality"));
			this.list.addSmall(instance(ShadeOptions.PRESET), instance(ShadeOptions.STYLE));
			this.list.addSmall(instance(ShadeOptions.ATMOSPHERE)); // (1.2.9 look pass)
			this.list.addHeader(header("Ajustes", "Settings"));
			List<AbstractWidget> buttons = new ArrayList<>();
			for (ShadeOptions.Page p : ShadeOptions.PAGES) {
				buttons.add(Button.builder(Component.literal(p.title() + "..."), b -> this.minecraft.gui.setScreen(new ShadeSettingsScreen(this, p)))
					.tooltip(Tooltip.create(Component.literal(t(p.tipEs(), p.tipEn())))).build());
			}
			this.list.addSmall(buttons);
			// (1.2.1) the shaders' on/off switch, applied at the next start (off: plain mcopt 0.3)
			this.list.addHeader(header("General", "General"));
			this.list.addBig(ShadeToggle.button(this.minecraft.gameDirectory.toPath()));
			return;
		}
		// a page: pairs of options under their headers (an odd one out takes the left half)
		List<OptionInstance<?>> row = new ArrayList<>();
		for (Object item : this.page.items()) {
			if (item instanceof String[] h) {
				if (!row.isEmpty()) this.list.addSmall(row.toArray(OptionInstance[]::new));
				row.clear();
				this.list.addHeader(header(h[0], h[1]));
			} else if (item instanceof ShadeOption o) {
				row.add(instance(o));
			}
		}
		if (!row.isEmpty()) this.list.addSmall(row.toArray(OptionInstance[]::new));
	}

	/** (1.2.1) The main page's small "☕" support button in the top-right corner (ShadeToggle.supportButton). */
	@Override
	protected void init() {
		super.init();
		if (this.page == null) this.addRenderableWidget(ShadeToggle.supportButton(this));
	}

	@Override
	protected void addFooter() {
		LinearLayout footer = this.layout.addToFooter(LinearLayout.horizontal().spacing(8));
		boolean main = this.page == null;
		footer.addChild(Button.builder(Component.literal(main ? t("Restaurar todo", "Reset all") : t("Restaurar página", "Reset page")), button -> {
			// everything back to the released look (the preset stays: a performance choice, not a look)
			for (ShadeOption o : main ? ShadeOptions.all() : this.page.options()) if (o != ShadeOptions.PRESET) o.reset();
			this.minecraft.gui.setScreen(new ShadeSettingsScreen(this.lastScreen, this.page));
		}).tooltip(Tooltip.create(Component.literal(main ? t("Todos los ajustes como vienen (el preset no cambia).", "Every setting back to default (the preset stays).")
			: t("Los ajustes de esta página como vienen.", "This page's settings back to default.")))).build());
		footer.addChild(Button.builder(CommonComponents.GUI_DONE, button -> this.onClose()).build());
	}

	/** No blur: the world behind shows each change as it is made. */
	@Override
	protected void extractBlurredBackground(GuiGraphicsExtractor graphics) {
	}

	@Override
	public void removed() {
		super.removed();
		ShadeSettings.save(this.minecraft.gameDirectory.toPath());
	}
}
