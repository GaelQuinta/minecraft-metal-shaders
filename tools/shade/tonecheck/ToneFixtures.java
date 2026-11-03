// Copyright 2026 mcopt-shade contributors. Apache-2.0.
import java.nio.*;
import java.nio.file.*;
import mcopt.metal.shade.*;
public class ToneFixtures {
    public static void main(String[] args)throws Exception{
        Path out=Path.of(args[0]);Files.createDirectories(out);Files.writeString(out.resolve("post.metal"),ShadeMsl.post());
        for(String look:new String[]{"epic","storybook","natural"})for(int angle:new int[]{-15,0,60}){
            System.setProperty("mcopt.shade.look",look);
            ShadeFrame f=new ShadeFrame();float y=(float)Math.sin(Math.toRadians(angle));f.sunDir.set(-(float)Math.sqrt(1-y*y),y,0);f.moonDir.set(f.sunDir).negate();
            f.eyeSkyLight=15;f.minAmbient=.0125f;f.width=960;f.height=620;f.updateAtmosphere(0,true);ShadeLook l=new ShadeLook();l.update(f,0,1f/60);
            ByteBuffer b=ByteBuffer.allocateDirect(ShadeLook.SIZE+96).order(ByteOrder.LITTLE_ENDIAN);l.pack(b.slice(0,ShadeLook.SIZE),f);
            int p=ShadeLook.SIZE;b.putFloat(p+64,2);b.putFloat(p+68,4);b.position(p+72);l.putHdrCurve(b,4);b.putFloat(p+92,1);
            byte[] bytes=new byte[b.capacity()];b.get(0,bytes);Files.write(out.resolve(look+"_"+angle+".bin"),bytes);
            System.out.printf("%s %d contrast %.5f%n",look,angle,l.contrast);
        }
    }
}
