// Copyright 2026 mcopt-shade contributors. Apache-2.0.
import java.nio.*;
import java.nio.file.*;
import mcopt.metal.shade.*;
public class PassFixtures {
    public static void main(String[] args) throws Exception {
        Path out=Path.of(args[0]);
        Files.writeString(out, ShadeMsl.post());
        ShadeFrame f=new ShadeFrame();f.sunDir.set(-.5f,.866f,0);f.moonDir.set(f.sunDir).negate();
        f.eyeSkyLight=15;f.minAmbient=.0125f;f.width=960;f.height=620;f.updateAtmosphere(0,true);
        ShadeLook l=new ShadeLook();l.update(f,0,1f/60);
        ByteBuffer b=ByteBuffer.allocateDirect(ShadeLook.SIZE).order(ByteOrder.LITTLE_ENDIAN);l.pack(b,f);
        byte[] bytes=new byte[b.capacity()];b.get(0,bytes);Files.write(out.resolveSibling("look.bin"),bytes);
        ByteBuffer p=ByteBuffer.allocate(96).order(ByteOrder.LITTLE_ENDIAN);
        p.putFloat(64,2);p.putFloat(68,4);p.position(72);l.putHdrCurve(p,4);p.putFloat(92,1);
        Files.write(out.resolveSibling("hdr.bin"),p.array());
        for(int strength:new int[]{0,100,200}){
            System.setProperty("mcopt.shade.user.bloom",Integer.toString(strength));ShadeSettings.sync();l.pack(b,f);
            float actual=b.getFloat(ShadeLook.USER2+8);
            if(Math.abs(actual-.04f*strength/100)>1e-6)throw new AssertionError("halation packing: "+actual);
        }
        System.out.println("PASS halation follows Bloom 0/100/200% in the production uniform layout");
    }
}
