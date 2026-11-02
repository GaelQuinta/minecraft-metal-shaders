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

package mcopt.pacingbench;

import com.google.gson.GsonBuilder;
import mcopt.metal.GpuTimes;
import mcopt.metal.Latency;
import mcopt.metal.shade.dims.ShadeXdr;
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
import net.minecraft.world.level.levelgen.Heightmap;
import net.minecraft.world.level.gamerules.GameRules;
import org.lwjgl.sdl.SDLVideo;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.TimeUnit;

/** Fixed startup policy and display settings; disposable flat world only. */
public class PacingBench implements ClientModInitializer {
    static Minecraft mc;
    static final boolean fullscreen = Boolean.getBoolean("mcopt.bench.fullscreen");
    static final boolean hdr = Boolean.parseBoolean(System.getProperty("mcopt.bench.hdr", "true"));
    static final boolean fresh = Boolean.getBoolean("mcopt.metal.presentFresh");
    static final Map<String, Map<String, Object>> phases = new LinkedHashMap<>();
    static Map<String, Object> current;
    static Map<Integer, Integer> caps;
    static int frames, unfocused, wrongMode, changedSize, moved;
    static boolean variableLoad;
    static long loadStartedNs;
    static void check(boolean ok, String why) { if (!ok) throw new AssertionError(why); }
    static void note(String text) { System.out.println("PACING_BENCH " + text); }
    static void game(Runnable work) throws Exception { mc.submit(work).get(30, TimeUnit.SECONDS); }

    public static void polled() {
        Latency.lastPollNs = System.nanoTime();
        if (current == null) return;
        frames++;
        caps.merge(mc.getFramerateLimitTracker().getFramerateLimit(), 1, Integer::sum);
        long flags = SDLVideo.SDL_GetWindowFlags(mc.getWindow().handle());
        if ((flags & SDLVideo.SDL_WINDOW_INPUT_FOCUS) == 0) unfocused++;
        if (((flags & SDLVideo.SDL_WINDOW_FULLSCREEN) != 0) != fullscreen) wrongMode++;
        if (mc.getWindow().getWidth() != (int)current.get("width") || mc.getWindow().getHeight() != (int)current.get("height")) changedSize++;
        if (mc.player != null) {
            mc.player.setXRot(15);
            mc.player.setYRot(0);
            mc.player.setDeltaMovement(0, 0, 0);
            mc.player.setPos(.5, mc.player.getY(), .5);
        }
        if (Math.abs(mc.player.getX() - .5) > .1 || Math.abs(mc.player.getZ() - .5) > .1
                || Math.abs(mc.player.getXRot() - 15) > 1 || Math.abs(mc.player.getYRot()) > 1) moved++;
    }

    static void phase(int i, int cap, boolean load) throws Exception {
        game(() -> {
            check(mc.gui.screen() == null && mc.gui.overlay() == null, "Gameplay visible");
            mc.options.framerateLimit().set(cap);
            mc.getFramerateLimitTracker().setFramerateLimit(cap);
            variableLoad = load;
            loadStartedNs = System.nanoTime();
            if (mc.player != null) {
                mc.player.setXRot(15);
                mc.player.setYRot(0);
                mc.player.setDeltaMovement(0, 0, 0);
                mc.player.setPos(.5, mc.player.getY(), .5);
            }
            note("prepare " + i + " cap=" + cap + " load=" + load + " fresh=" + fresh);
        });
        Thread.sleep(3000);
        game(() -> {
            current = new LinkedHashMap<>();
            current.put("cap", cap); current.put("fresh", fresh); current.put("load", load);
            current.put("candidate", Boolean.getBoolean("mcopt.bench.candidate"));
            current.put("adaptivePacing", Boolean.getBoolean("mcopt.metal.adaptivePacing"));
            current.put("adaptiveSafetyMarginMs", Double.parseDouble(System.getProperty("mcopt.metal.adaptiveSafetyMarginMs", "1.5")));
            current.put("adaptiveWindowSize", Integer.getInteger("mcopt.metal.adaptiveWindowSize", 8));
            double scheduleMs = Double.parseDouble(System.getProperty("mcopt.metal.presentScheduleMs", "0"));
            current.put("scheduleMs", scheduleMs);
            current.put("loadScale", Double.parseDouble(System.getProperty("mcopt.bench.loadScale", "1")));
            current.put("loadStepMs", Long.getLong("mcopt.bench.loadStepMs", 237L));
            current.put("width", mc.getWindow().getWidth()); current.put("height", mc.getWindow().getHeight());
            current.put("hdr", hdr); current.put("fullscreen", fullscreen);
            check(ShadeXdr.active() == hdr && (!hdr || ShadeXdr.fullScene()), "Expected HDR mode");
            check(mc.options.enableVsync().get(), "VSync stays enabled");
            current.put("context", BenchContext.capture(mc.getWindow().handle(), true));
            var q = GpuTimes.presentQueueSnapshot();
            check((boolean)q.get("enabled") == fresh, "Native candidate setting matches request");
            check(Math.abs(((Number)q.getOrDefault("scheduleBudgetNs", 0L)).longValue() / 1e6 - scheduleMs) < .0001,
                "Native presentation deadline matches request");
            current.put("queueStart", q);
            current.put("nanoRange", new long[]{System.nanoTime(), 0});
            current.put("epochStartMs", System.currentTimeMillis());
            loadStartedNs = System.nanoTime();
            current.put("loadStartedNs", loadStartedNs);
            caps = new LinkedHashMap<>(); frames = unfocused = wrongMode = changedSize = moved = 0;
            phases.put(i + "-" + cap + (load ? "-loaded" : "-light"), current);
            note("measure " + i);
        });
        Thread.sleep(Long.getLong("mcopt.bench.sampleMs", 10000L));
        game(() -> {
            ((long[])current.get("nanoRange"))[1] = System.nanoTime();
            current.put("queueEnd", GpuTimes.presentQueueSnapshot());
            current.put("caps", caps); current.put("frames", frames); current.put("unfocused", unfocused);
            current.put("wrongMode", wrongMode); current.put("changedSize", changedSize); current.put("moved", moved);
            current = null;
            note("complete " + i + " frames=" + frames + " unfocused=" + unfocused + " wrongMode=" + wrongMode + " changedSize=" + changedSize + " moved=" + moved);
            check(unfocused + wrongMode + changedSize + moved == 0, "Focus, window and camera remain fixed");
        });
    }

    public void onInitializeClient() {
        Thread.ofPlatform().daemon().start(() -> {
            try {
                Thread.sleep(18000);
                mc = Minecraft.getInstance();
                game(() -> {
                    mc.options.inactivityFpsLimit().set(InactivityFpsLimit.MINIMIZED);
                    mc.createWorldOpenFlows().createFreshLevel("fresh-frame-benchmark",
                        new LevelSettings("Fresh frame benchmark", GameType.CREATIVE,
                            new LevelSettings.DifficultySettings(Difficulty.PEACEFUL, false, false), true, WorldDataConfiguration.DEFAULT),
                        new WorldOptions(1234L, false, false),
                        p -> p.lookupOrThrow(Registries.WORLD_PRESET).getOrThrow(WorldPresets.FLAT).value().createWorldDimensions(), mc.gui.screen());
                });
                boolean ready = false;
                for (int i = 0; i < 90; i++) {
                    Thread.sleep(500);
                    if (mc.submit(() -> mc.level != null && mc.player != null && mc.gui.screen() == null
                            && mc.gui.overlay() == null).get(30, TimeUnit.SECONDS)) { ready = true; break; }
                }
                check(ready, "World loaded");
                var server = mc.getSingleplayerServer();
                var playerId = mc.submit(() -> mc.player.getUUID()).get(10, TimeUnit.SECONDS);
                server.submit(() -> {
                    var level = server.overworld();
                    level.getGameRules().set(GameRules.ADVANCE_TIME, false, server);
                    level.getGameRules().set(GameRules.ADVANCE_WEATHER, false, server);
                    level.getGameRules().set(GameRules.SPAWN_MOBS, false, server);
                    server.getCommands().performPrefixedCommand(server.createCommandSourceStack(), "time set day");
                    server.getCommands().performPrefixedCommand(server.createCommandSourceStack(), "weather clear");
                    var player = server.getPlayerList().getPlayer(playerId);
                    check(player != null, "Benchmark player exists");
                    player.teleportTo(level, .5, level.getHeight(Heightmap.Types.MOTION_BLOCKING_NO_LEAVES, 0, 0), .5,
                        java.util.Set.of(), 0, 15, false);
                }).get(10, TimeUnit.SECONDS);
                game(() -> SDLVideo.SDL_RaiseWindow(mc.getWindow().handle()));
                Thread.sleep(5000);
                String[] plan = System.getProperty("mcopt.bench.phases", "50,60,120,120g").split(",");
                for (int i = 0; i < plan.length; i++) {
                    boolean load = plan[i].endsWith("g");
                    int cap = Integer.parseInt(load ? plan[i].substring(0, plan[i].length() - 1) : plan[i]);
                    phase(i, cap, load);
                }
                Thread.sleep(4000);
                game(() -> {
                    Map<String, Object> report = new LinkedHashMap<>();
                    report.put("format", 2); report.put("gpu", GpuTimes.snapshot(phases)); report.put("phases", phases);
                    report.put("latencyMeaning", "After SDL input poll to Metal presentedTime; not physical input-to-photon latency");
                    try { Files.writeString(Path.of(System.getProperty("mcopt.bench.output")), new GsonBuilder().setPrettyPrinting().create().toJson(report)); }
                    catch (Exception e) { throw new RuntimeException(e); }
                    String telPath = System.getProperty("mcopt.metal.telemetryOutput");
                    if (telPath != null) {
                        try {
                            Class.forName("mcopt.metal.FrameSchedule").getMethod("dumpTelemetry", String.class).invoke(null, telPath);
                        } catch (Throwable ignored) {}
                    }
                    note("PASS"); mc.stop();
                });
            } catch (Throwable t) { t.printStackTrace(); note("FAIL"); Runtime.getRuntime().halt(70); }
        });
    }
}
