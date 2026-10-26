/* Copyright 2026 mcopt-shade contributors.
 * Licensed under the Apache License, Version 2.0.
 * https://www.apache.org/licenses/LICENSE-2.0
 */
package mcopt.metal.mixin.shade;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import net.minecraft.client.renderer.texture.SpriteContents;
import net.minecraft.client.renderer.texture.SpriteLoader;
import net.minecraft.resources.Identifier;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.ModifyVariable;

/** Data maps are loaded by ShadePbr, not stitched into the colour atlas (which would triple its size). */
@Mixin(SpriteLoader.class)
public class ShadePbrSpritesMixin {
	@Shadow @Final private Identifier location;

	@ModifyVariable(method = "stitch", at = @At("HEAD"), argsOnly = true)
	private List<SpriteContents> mcopt$pbrMaps(List<SpriteContents> sprites) {
		if (!location.getPath().endsWith("atlas/blocks.png")) return sprites;
		var names = new HashSet<Identifier>();
		for (var s : sprites) names.add(s.name());
		var kept = new ArrayList<SpriteContents>(sprites.size());
		int removed = 0;
		for (var s : sprites) {
			String path = s.name().getPath();
			if ((path.endsWith("_n") || path.endsWith("_s")) && names.contains(s.name().withPath(path.substring(0,path.length()-2)))) {
				s.close(); removed++;
			} else kept.add(s);
		}
		if (removed > 0) System.out.println("[mcopt] shade: PBR: " + removed + " data sprites excluded from colour atlas");
		return kept;
	}
}
