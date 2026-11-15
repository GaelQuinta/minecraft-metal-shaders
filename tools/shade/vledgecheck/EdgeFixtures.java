// Copyright 2026 mcopt-shade contributors. Apache-2.0.
import java.nio.*;
import java.nio.file.*;
import mcopt.metal.shade.*;
import mcopt.metal.shade.vl.*;
import org.joml.*;

/** Current/previous camera pairs for the production volumetric-light march, without Minecraft. */
public class EdgeFixtures {
    public static void main(String[] args) throws Exception {
        Path out = Path.of(args[0]);
        Files.createDirectories(out);
        Files.writeString(out.resolve("vl.metal"), VlConfig.source());
        float[][] turns = {{0,0}, {20,0}, {-20,0}, {0,20}, {0,-20}, {180,0}, {0,0}, {45,0}, {0,-80}};
        for (int k = 0; k < turns.length; k++) {
            ShadeFrame f = new ShadeFrame();
            f.width = 640; f.height = 400;
            f.sunDir.set(0,.2f,-.98f).normalize(); f.moonDir.set(f.sunDir).negate();
            f.eyeSkyLight = 15; f.moonPhase = 1;
            f.proj.setPerspective((float)java.lang.Math.toRadians(70),1.6f,768f,.05f,true);
            f.view.identity(); f.proj.mul(f.view,f.viewProj); f.viewProj.invert(f.invViewProj);
            Matrix4f previous = new Matrix4f()
                .rotateY((float)java.lang.Math.toRadians(turns[k][0]))
                .rotateX((float)java.lang.Math.toRadians(turns[k][1]));
            if (k == 6) previous.translate(3,2,-1); // Sky reprojection must ignore camera translation.
            f.proj.mul(previous,f.prevViewProj); f.updateAtmosphere(0,true);
            ShadeLook look = new ShadeLook(); look.update(f,0,1f/60);
            ByteBuffer b = ByteBuffer.allocateDirect(ShadeFrame.SIZE+ShadeLook.SIZE).order(ByteOrder.LITTLE_ENDIAN);
            f.pack(b.slice(0,ShadeFrame.SIZE)); look.pack(b.slice(ShadeFrame.SIZE,ShadeLook.SIZE),f);
            byte[] bytes = new byte[b.capacity()]; b.get(0,bytes);
            Files.write(out.resolve("camera"+k+".bin"),bytes);
        }
    }
}
