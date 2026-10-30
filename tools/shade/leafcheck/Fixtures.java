// Copyright 2026 mcopt-shade contributors. Apache-2.0.
package mcopt.metal.shade;
import java.nio.*;
import java.nio.file.*;

public final class Fixtures {
    static void check(boolean ok, String why) { if (!ok) throw new AssertionError(why); }
    public static void main(String[] args) throws Exception {
        Path out = Path.of(args[0]); Files.createDirectories(out);
        Files.writeString(out.resolve("lighting.metal"), ShadeMsl.prelude());
        Files.writeString(out.resolve("own.metal"), ShadeMsl.ownPrefix() + new String(Fixtures.class.getResourceAsStream("/mcopt/own/terrain.metal").readAllBytes()));
        ShadeFrame f = new ShadeFrame(); f.dimension = ShadeFrame.DIM_OVERWORLD;
        ByteBuffer bytes = ByteBuffer.allocate(2816).order(ByteOrder.LITTLE_ENDIAN);
        ShadeOption wind = ShadeOptions.all().stream().filter(o -> o.key.equals("mcopt.shade.user.leafWind")).findFirst().orElseThrow();
        wind.reset(); LeafFrame.pack(bytes, f);
        check(wind.pos() == 100 && Math.abs(bytes.getFloat(LeafFrame.OFFSET) - .8f) < 1e-6, "wind default");
        wind.set(0); LeafFrame.pack(bytes, f); check(bytes.getFloat(LeafFrame.OFFSET) == 0, "wind disabled live");
        wind.set(200); f.rain=1; LeafFrame.pack(bytes, f); check(bytes.getFloat(LeafFrame.OFFSET) == 2, "wind bounded in rain");
        ShadeSettings.save(out.resolve("settings"));
        check(Files.readString(out.resolve("settings/config/mcopt.properties")).contains("mcopt.shade.user.leafWind=2"), "wind persists");
        f.dimension = ShadeFrame.DIM_NETHER; LeafFrame.pack(bytes, f); check(bytes.getFloat(LeafFrame.OFFSET) == 0, "no nether wind");
        wind.reset(); ShadeSettings.save(out.resolve("settings"));
        check(!Files.readString(out.resolve("settings/config/mcopt.properties")).contains("mcopt.shade.user.leafWind="), "reset removes override");
        for (String scene : new String[]{"noon", "sunset", "night"}) {
            f = new ShadeFrame(); double[] d = new double[3];
            ShadeSky.celestial(Math.toRadians(scene.equals("sunset") ? 88 : scene.equals("night") ? 180 : 0), d);
            f.sunDir.set((float)d[0], (float)d[1], (float)d[2]); f.moonDir.set(f.sunDir).negate();
            f.eyeSkyLight=15; f.minAmbient=.0125f; f.shadowsEnabled=true; f.width=960; f.height=540;
            f.updateAtmosphere(0,true); ShadeLook l = new ShadeLook(); l.update(f,0,1f/60);
            ByteBuffer b = ByteBuffer.allocateDirect(1024 + ShadeLook.SIZE).order(ByteOrder.LITTLE_ENDIAN);
            f.pack(b); l.pack(b.slice(1024, ShadeLook.SIZE), f);
            byte[] data=new byte[b.capacity()];b.position(0);b.get(data);Files.write(out.resolve(scene+".bin"),data);
        }
        System.out.println("leaf wind live controls, bounds, dimensions and persistence verified");
    }
}
