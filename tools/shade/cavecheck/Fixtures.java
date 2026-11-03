// Copyright 2026 mcopt-shade contributors. Apache-2.0.
import java.nio.*;
import java.nio.file.*;
import mcopt.metal.shade.*;
public class Fixtures {
 public static void main(String[] args) throws Exception {
  Path out=Path.of(args[0]);Files.createDirectories(out);
  Files.writeString(out.resolve("source.metal"),"#define SHADE_DL_KERNELS\n"+ShadeMsl.post());
  for(String scene:new String[]{"cave-day","cave-night","outside-day","outside-night","storm","kelvin"}) {
   ShadeFrame f=new ShadeFrame();double[]dir=new double[3];ShadeSky.celestial(scene.endsWith("night")?Math.PI:0,dir);
   f.sunDir.set((float)dir[0],(float)dir[1],(float)dir[2]);f.moonDir.set(f.sunDir).negate();
   f.eyeSkyLight=scene.startsWith("outside")||scene.equals("storm")?15:0;
   f.rain=f.thunder=scene.equals("storm")?1:0;f.minAmbient=.0125f;f.width=960;f.height=620;
   ShadeLook l=new ShadeLook();for(int i=0;i<60;i++){f.updateAtmosphere(0,true);l.update(f,0,.25f);}
   System.setProperty("mcopt.shade.user.torchKelvin",scene.equals("kelvin")?"3200":"0");
   ByteBuffer b=ByteBuffer.allocateDirect(ShadeFrame.SIZE+ShadeLook.SIZE).order(ByteOrder.LITTLE_ENDIAN);
   f.pack(b.slice(0,ShadeFrame.SIZE));l.pack(b.slice(ShadeFrame.SIZE,ShadeLook.SIZE),f);
   byte[] bytes=new byte[b.capacity()];b.get(bytes);Files.write(out.resolve(scene+".bin"),bytes);
  }
 }
}
