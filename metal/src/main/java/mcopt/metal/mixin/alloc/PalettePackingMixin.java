package mcopt.metal.mixin.alloc;

import com.llamalad7.mixinextras.injector.wrapmethod.WrapMethod;
import com.llamalad7.mixinextras.injector.wrapoperation.Operation;
import mcopt.metal.alloc.PalettePacking;
import net.minecraft.util.BitStorage;
import net.minecraft.world.level.chunk.Palette;
import net.minecraft.world.level.chunk.PalettedContainer;
import net.minecraft.world.level.chunk.PalettedContainerRO;
import net.minecraft.world.level.chunk.Strategy;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Redirect;

/** Reuse only pack's temporary unpacked IDs. Vanilla still owns locking, palette construction and the saved data. */
@Mixin(PalettedContainer.class)
abstract class PalettePackingMixin<T> {
	@WrapMethod(method = "pack")
	private PalettedContainerRO.PackedData<T> mcopt$packingScope(Strategy<T> strategy,
		Operation<PalettedContainerRO.PackedData<T>> original) {
		PalettePacking.enter();
		try {
			return original.call(strategy);
		} finally {
			PalettePacking.exit();
		}
	}

	// require = 0: another mod that replaces pack (as Lithium does) leaves no call to redirect; vanilla's copy then runs
	@Redirect(method = "pack", require = 0, at = @At(value = "INVOKE", target =
		"Lnet/minecraft/world/level/chunk/PalettedContainer;reencodeContents(Lnet/minecraft/util/BitStorage;Lnet/minecraft/world/level/chunk/Palette;Lnet/minecraft/world/level/chunk/Palette;)[I"))
	private int[] mcopt$packingIds(BitStorage storage, Palette<T> from, Palette<T> to) {
		return PalettePacking.reencode(storage, from, to);
	}
}
