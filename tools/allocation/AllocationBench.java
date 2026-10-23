package mcopt.allocationbench;

import com.google.gson.GsonBuilder;
import com.sun.management.ThreadMXBean;
import java.lang.management.ManagementFactory;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.*;
import java.util.concurrent.TimeUnit;
import jdk.jfr.Configuration;
import jdk.jfr.Recording;
import net.fabricmc.api.ClientModInitializer;
import net.minecraft.client.Minecraft;
import net.minecraft.client.InactivityFpsLimit;
import net.minecraft.core.registries.Registries;
import net.minecraft.world.Difficulty;
import net.minecraft.world.level.GameType;
import net.minecraft.world.level.LevelSettings;
import net.minecraft.world.level.WorldDataConfiguration;
import net.minecraft.world.level.levelgen.WorldOptions;
import net.minecraft.world.level.levelgen.presets.WorldPresets;
import net.minecraft.world.phys.Vec3;
import org.lwjgl.sdl.SDLVideo;

/** Test-only allocation and GC profile. Runs in a disposable world, never a player save. */
public class AllocationBench implements ClientModInitializer {
    static Minecraft mc;
    static long[] frames = new long[40000];
    static int count, unfocused, fullscreen;
    static boolean measuring, moving, posing;
    static long phaseStart;
    static double x, y, z;
    static final Path out = Path.of(System.getProperty("mcopt.allocbench.output"));
    static final ThreadMXBean threads = (ThreadMXBean)ManagementFactory.getThreadMXBean();

    static void game(Runnable r) throws Exception { mc.submit(r).get(30, TimeUnit.SECONDS); }
    static void require(boolean ok, String why) { if (!ok) throw new AssertionError(why); }
    static void note(String text) { System.out.println("ALLOCATION_BENCH " + text); }

    public static void frame() {
        if (!measuring) return;
        require(count < frames.length, "Frame recorder full");
        frames[count++] = System.nanoTime();
        long flags = SDLVideo.SDL_GetWindowFlags(mc.getWindow().handle());
        if ((flags & SDLVideo.SDL_WINDOW_INPUT_FOCUS) == 0) unfocused++;
        if ((flags & SDLVideo.SDL_WINDOW_FULLSCREEN) != 0) fullscreen++;
    }
    public static void pose() {
        if (!posing || mc.player == null) return;
        double dz = moving ? (System.nanoTime() - phaseStart) * 1e-9 * 25 : 0;
        mc.player.getAbilities().mayfly = true;
        mc.player.getAbilities().flying = true;
        mc.player.setDeltaMovement(Vec3.ZERO);
        mc.player.snapTo(x, y, z + dz, 0, 15);
        mc.player.setYHeadRot(0);
        mc.player.setYBodyRot(0);
    }

    static Map<Long, Long> allocated() {
        long[] ids = threads.getAllThreadIds(), bytes = threads.getThreadAllocatedBytes(ids);
        Map<Long, Long> result = new HashMap<>();
        for (int i = 0; i < ids.length; i++) if (bytes[i] >= 0) result.put(ids[i], bytes[i]);
        return result;
    }
    static void phase(String name, boolean fly, int seconds) throws Exception {
        try (Recording recording = new Recording(Configuration.getConfiguration("profile"))) {
            recording.enable("jdk.ObjectAllocationSample").withStackTrace().with("throttle", "200/s");
            recording.start();
            Map<Long, Long> before = allocated();
            game(() -> {
                count = unfocused = fullscreen = 0;
                moving = fly;
                phaseStart = System.nanoTime();
                measuring = true;
                note("measure " + name);
            });
            Thread.sleep(seconds * 1000L);
            Map<String, Object> report = new LinkedHashMap<>();
            game(() -> {
                measuring = false;
                long a = System.nanoTime();
                java.time.Instant instant = java.time.Instant.now();
                long b = System.nanoTime();
                report.put("clockNano", a + (b - a) / 2);
                report.put("clockEpochNs", instant.getEpochSecond() * 1_000_000_000L + instant.getNano());
                report.put("clockBracketNs", b - a);
                report.put("durationNs", System.nanoTime() - phaseStart);
                report.put("origin", new double[]{x, y, z});
                report.put("frameNs", Arrays.copyOf(frames, count));
                report.put("unfocusedFrames", unfocused);
                report.put("fullscreenFrames", fullscreen);
                report.put("cap", mc.getFramerateLimitTracker().getFramerateLimit());
                report.put("chunks", mc.level.getChunkSource().getLoadedChunksCount());
                moving = false;
            });
            Map<Long, Long> after = allocated();
            List<Map<String,Object>> allocations = new ArrayList<>();
            for (var e : after.entrySet()) {
                long bytes = e.getValue() - before.getOrDefault(e.getKey(), 0L);
                var info = threads.getThreadInfo(e.getKey());
                allocations.add(Map.of("id", e.getKey(), "name", info == null ? "ended" : info.getThreadName(), "bytes", bytes));
            }
            report.put("threadAllocatedBytes", allocations);
            recording.stop();
            recording.dump(out.resolve(name + ".jfr"));
            Files.writeString(out.resolve(name + ".json"), new GsonBuilder().setPrettyPrinting().create().toJson(report));
            note("complete " + name + " frames=" + count + " unfocused=" + unfocused);
            require(fullscreen == 0 && unfocused == 0, "Windowed/focused profile required");
        }
    }

    public void onInitializeClient() {
        Thread.ofPlatform().daemon().start(() -> {
            try {
                Thread.sleep(15000);
                if (Boolean.getBoolean("mcopt.allocbench.verify")) {
                    Class.forName("mcopt.allocationbench.PalettePackingCheck").getMethod("run", boolean.class).invoke(null, true);
                }
                mc = Minecraft.getInstance();
                game(() -> {
                    mc.options.framerateLimit().set(120);
                    mc.options.enableVsync().set(true);
                    mc.options.inactivityFpsLimit().set(InactivityFpsLimit.MINIMIZED);
                    mc.createWorldOpenFlows().createFreshLevel("allocation-profile",
                        new LevelSettings("Allocation profile", GameType.CREATIVE,
                            new LevelSettings.DifficultySettings(Difficulty.PEACEFUL, false, false),
                            true, WorldDataConfiguration.DEFAULT), new WorldOptions(1234L, false, false),
                        p -> p.lookupOrThrow(Registries.WORLD_PRESET).getOrThrow(
                            Boolean.getBoolean("mcopt.allocbench.amplified") ? WorldPresets.AMPLIFIED : WorldPresets.NORMAL).value().createWorldDimensions(),
                        mc.gui.screen());
                });
                boolean ready = false;
                for (int i = 0; i < 120; i++) {
                    Thread.sleep(500);
                    if (mc.submit(() -> mc.level != null && mc.player != null && mc.gui.screen() == null
                            && mc.gui.overlay() == null).get(30, TimeUnit.SECONDS)) { ready = true; break; }
                }
                require(ready, "World loaded");
                game(() -> {
                    require((SDLVideo.SDL_GetWindowFlags(mc.getWindow().handle()) & SDLVideo.SDL_WINDOW_FULLSCREEN) == 0, "Windowed only");
                    SDLVideo.SDL_RaiseWindow(mc.getWindow().handle());
                    x = 0; y = 160; z = 0; posing = true;
                    var server = mc.getSingleplayerServer();
                    server.execute(() -> {
                        for (String cmd : List.of("gamemode spectator @a", "gamerule player_movement_check false",
                                "gamerule advance_time false", "gamerule advance_weather false", "time set day", "weather clear"))
                            server.getCommands().performPrefixedCommand(server.createCommandSourceStack().withSuppressedOutput(), cmd);
                    });
                });
                Thread.sleep(10000);
                int previous = -1, stable = 0;
                for (int i = 0; i < 50; i++) {
                    Thread.sleep(1000);
                    int chunks = mc.submit(() -> mc.level.getChunkSource().getLoadedChunksCount()).get();
                    boolean built = mc.submit(() -> mc.levelRenderer.hasRenderedAllSections()).get();
                    stable = chunks == previous && built ? stable + 1 : 0;
                    previous = chunks;
                    if (stable >= 3) break;
                }
                threads.setThreadAllocatedMemoryEnabled(true);
                phase("stationary", false, 20);
                phase("flight", true, 30);
                note("PASS");
                game(() -> mc.stop());
            } catch (Throwable t) {
                t.printStackTrace(); note("FAIL"); Runtime.getRuntime().halt(70);
            }
        });
    }
}
