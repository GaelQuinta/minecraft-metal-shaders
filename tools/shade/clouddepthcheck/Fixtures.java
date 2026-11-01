// Copyright 2026 mcopt-shade contributors. Apache-2.0.
import java.nio.*;
import java.nio.file.*;
import mcopt.metal.shade.*;
import mcopt.metal.shade.clouds.CloudConfig;
public class Fixtures {
 public static void main(String[] args) throws Exception {
  Path out=Path.of(args[0]);Files.createDirectories(out);
  Files.writeString(out.resolve("clouds.metal"),CloudConfig.source());
  Files.writeString(out.resolve("prelude.metal"),ShadeMsl.prelude());
  Files.writeString(out.resolve("post.metal"),ShadeMsl.post());
  for(String name:new String[]{"day","night"}) {
   ShadeFrame f=new ShadeFrame();double[]dir=new double[3];ShadeSky.celestial(name.equals("night")?Math.PI:0,dir);
   f.sunDir.set((float)dir[0],(float)dir[1],(float)dir[2]);f.moonDir.set(f.sunDir).negate();
   f.width=4;f.height=4;f.eyeSkyLight=15;f.minAmbient=.0125f;
   f.view.identity();f.proj.setPerspective((float)Math.toRadians(70),1,768,.05f,true);
   f.proj.mul(f.view,f.viewProj);f.viewProj.invert(f.invViewProj);f.prevViewProj.set(f.viewProj);
   f.updateAtmosphere(0,true);ShadeLook l=new ShadeLook();l.update(f,0,1f/60);
   ByteBuffer b=ByteBuffer.allocateDirect(ShadeFrame.SIZE+ShadeLook.SIZE).order(ByteOrder.LITTLE_ENDIAN);
   f.pack(b);l.pack(b.slice(ShadeFrame.SIZE,ShadeLook.SIZE),f);
   byte[]a=new byte[b.capacity()];b.position(0);b.get(a);Files.write(out.resolve(name+".bin"),a);
  }
 }
}
