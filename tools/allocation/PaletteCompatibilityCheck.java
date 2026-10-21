package mcopt.allocationbench;

import java.util.Arrays;
import net.fabricmc.loader.api.FabricLoader;
import net.fabricmc.loader.api.entrypoint.PreLaunchEntrypoint;
import net.minecraft.world.level.chunk.PalettedContainer;

/** Run through Fabric's real client mixin loader, then exit before opening a window. */
public final class PaletteCompatibilityCheck implements PreLaunchEntrypoint {
    @Override public void onPreLaunch() {
        try {
            boolean lithium = FabricLoader.getInstance().isModLoaded("lithium");
            boolean expected = !lithium && Boolean.parseBoolean(System.getProperty("mcopt.alloc.palettePacking", "true"));
            // Loading this class reproduces the login and integrated-server failure.
            boolean applied = Arrays.stream(PalettedContainer.class.getDeclaredMethods())
                .anyMatch(method -> method.getName().contains("mcopt$packingIds"));
            if (applied != expected) throw new AssertionError("Packing mixin applied=" + applied + ", expected=" + expected);
            PalettePackingCheck.run(expected);
            System.out.println("PALETTE_COMPATIBILITY_CHECK PASS lithium=" + lithium + " packingMixin=" + applied);
            System.exit(0);
        } catch (Throwable failure) {
            failure.printStackTrace();
            System.exit(1); // Do not fall through to Minecraft's graphical crash dialog.
        }
    }
}
