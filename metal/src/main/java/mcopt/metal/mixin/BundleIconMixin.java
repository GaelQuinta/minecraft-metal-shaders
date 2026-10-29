package mcopt.metal.mixin;

import com.mojang.blaze3d.platform.Window;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/** The native Minecraft.app supplies a layered bundle icon instead of a runtime bitmap. */
@Mixin(Window.class)
abstract class BundleIconMixin {
    @Inject(method = "setIcon(Lnet/minecraft/server/packs/PackMetadataResources;Lcom/mojang/blaze3d/platform/IconSet;)V",
            at = @At("HEAD"), cancellable = true)
    private void mcopt$preserveBundleIcon(CallbackInfo ci) {
        if (Boolean.getBoolean("mcopt.app.preserveIcon")) ci.cancel();
    }
}
