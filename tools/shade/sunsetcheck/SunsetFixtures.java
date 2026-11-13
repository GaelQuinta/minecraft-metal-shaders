// Copyright 2026 mcopt-shade contributors. Apache-2.0.
import java.nio.*;
import java.nio.file.*;
import mcopt.metal.shade.*;

/** Actual game uniforms and CPU atmosphere reference, without opening Minecraft. */
public class SunsetFixtures {
    public static void main(String[] args) throws Exception {
        Path out = Path.of(args[0]); Files.createDirectories(out);
        String lut = ShadeMsl.resource("sky_lut.metal");
        // Adapt the old fragment body only for pre-fix JAR comparisons; use the shared helper in current builds.
        if (!lut.contains("float3 shadeSkyLutRadiance(")) {
            lut = lut.replace("fragment half4 shade_lut_fs(ShadeLutOut in [[stage_in]], constant ShadeFrame &f [[buffer(16)]], constant ShadeLook &L [[buffer(17)]])", "static inline float3 shadeSkyLutRadiance(float3 dir, constant ShadeFrame &f, constant ShadeLook &L)")
                .replace("float2 uv = (in.position.xy - 0.5) / float2(SHADE_LUT_W - 1, SHADE_LUT_H - 1);", "")
                .replace("float3 dir = shadeLutDirection(uv, f);", "")
                .replace("return half4(half3(min(sky, 60000.0)), 1.0h);", "return min(sky, 60000.0);")
                .replace("return half4(half3(min(shadeAwaySunset(sky, dir, f), 60000.0)), 1.0h);", "return min(shadeAwaySunset(sky, dir, f), 60000.0);");
        }
        Files.writeString(out.resolve("post.metal"), ShadeMsl.post()+lut);
        StringBuilder names = new StringBuilder();
        for (String preset : new String[]{"epic", "storybook", "natural"}) {
            System.setProperty("mcopt.shade.look", preset);
            for (String condition : new String[]{"evening", "morning", "rain", "legacy"}) {
                boolean art = !condition.equals("legacy");
                System.setProperty("mcopt.shade.sunsetArt", Boolean.toString(art));
                ShadeSky.sunsetArt = art;
                for (int elevation : new int[]{-15,-9,-4,-2,0,2,5,8,12,18,25,35,60}) {
                    ShadeFrame f = new ShadeFrame();
                    double y = Math.sin(Math.toRadians(elevation));
                    f.sunDir.set(-(float)Math.sqrt(1-y*y), (float)y, 0); f.moonDir.set(f.sunDir).negate();
                    f.dayTime = .25f-elevation/360f; f.moonPhase=1;
                    if (condition.equals("morning")) f.dayTime = 1-f.dayTime;
                    if (condition.equals("rain")) f.rain = 1;
                    f.eyeSkyLight=15; f.minAmbient=.0125f; f.shadowsEnabled=true; f.width=960; f.height=620;
                    f.updateAtmosphere(0,true); ShadeLook l = new ShadeLook(); l.update(f,0,1f/60);
                    ByteBuffer b = ByteBuffer.allocateDirect(ShadeFrame.SIZE+ShadeLook.SIZE+96).order(ByteOrder.LITTLE_ENDIAN);
                    f.pack(b.slice(0,ShadeFrame.SIZE)); l.pack(b.slice(ShadeFrame.SIZE,ShadeLook.SIZE),f);
                    int p=ShadeFrame.SIZE+ShadeLook.SIZE;
                    b.putFloat(p+64,2); b.putFloat(p+68,4); b.position(p+72); l.putHdrCurve(b,4); b.putFloat(p+92,1);
                    String name=preset+"_"+condition+"_"+elevation; names.append(name).append('\n');
                    byte[] bytes=new byte[b.capacity()]; b.get(0,bytes); Files.write(out.resolve(name+".bin"),bytes);
                    var sky=new ShadeSky.Sky(f.sunDir.x,f.sunDir.y,f.sunDir.z,f.moonDir.x,f.moonDir.y,f.moonDir.z,1,f.rain,0);
                    ByteBuffer expected=ByteBuffer.allocate(46*91*16).order(ByteOrder.LITTLE_ENDIAN);
                    for(int alt=0;alt<=90;alt+=2) for(int az=0;az<=180;az+=2) {
                        double h=Math.cos(Math.toRadians(alt)); float[] rgb=new float[3];
                        ShadeSky.radiance(sky,(float)(-Math.cos(Math.toRadians(az))*h),(float)Math.sin(Math.toRadians(alt)),(float)(Math.sin(Math.toRadians(az))*h),rgb);
                        for(float c:rgb) expected.putFloat(c); expected.putFloat(1);
                    }
                    Files.write(out.resolve(name+".sky"),expected.array());
                }
            }
        }
        Files.writeString(out.resolve("names.txt"),names);
    }
}
