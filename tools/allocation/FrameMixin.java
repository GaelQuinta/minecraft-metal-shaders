package mcopt.allocationbench.mixin;

import mcopt.allocationbench.AllocationBench;
import net.minecraft.client.Minecraft;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(Minecraft.class)
abstract class FrameMixin {
    @Inject(method = "runTick", at = @At("HEAD"))
    private void allocation$frame(boolean advanceGameTime, CallbackInfo ci) { AllocationBench.frame(); }
    @Inject(method = "renderFrame", at = @At("HEAD"))
    private void allocation$pose(boolean advanceGameTime, CallbackInfo ci) { AllocationBench.pose(); }
}
