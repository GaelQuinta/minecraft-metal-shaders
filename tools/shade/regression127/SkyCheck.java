// Copyright 2026 mcopt-shade contributors. Licensed under the Apache License, Version 2.0.
package mcopt.metal.shade;
import java.io.*;
import java.lang.management.ManagementFactory;
import java.nio.file.*;
/** Compare the real atmosphere against a baseline jar, including reuse across sun/weather changes; price allocations. */
public class SkyCheck {
 static float sink;
 static ShadeSky.Sky sky(int i) {
  double a=i*.013;float x=(float)-Math.sin(a),y=(float)Math.cos(a)*.8660254f,z=(float)Math.cos(a)*.5f;
  return new ShadeSky.Sky(x,y,z,-x,-y,-z,(i%8)/7f,(i%11)/10f,(i%5)/4f);
 }
 static void put(DataOutputStream d,float[] v)throws IOException{for(float f:v)d.writeFloat(f);}
 public static void main(String[]args)throws Exception{
  ShadeSky.Result r=new ShadeSky.Result();
  try(var d=new DataOutputStream(Files.newOutputStream(Path.of(args[0])))){
   for(int i=0;i<1024;i++){
    ShadeSky.compute(sky(i),r);put(d,r.lightDir);put(d,r.light);put(d,r.ambientSky);put(d,r.ambientGround);
    put(d,r.ambientToward);put(d,r.ambientAway);put(d,r.zenith);for(float[] h:r.horizon)put(d,h);d.writeFloat(r.sceneLuma);
   }
  }
  // A changed and then restored atmosphere must not keep scratch from a previous call.
  for(int i=0;i<3000;i++){ShadeSky.compute(sky(i),r);sink+=r.sceneLuma;}
  var bean=(com.sun.management.ThreadMXBean)ManagementFactory.getThreadMXBean();
  long id=Thread.currentThread().threadId(),bytes=bean.getThreadAllocatedBytes(id),start=System.nanoTime();
  for(int i=0;i<10000;i++){ShadeSky.compute(sky(i),r);sink+=r.sceneLuma;}
  long elapsed=System.nanoTime()-start,allocated=bean.getThreadAllocatedBytes(id)-bytes;
  System.out.printf("sky CPU %.2f us/call, %.1f allocated bytes/call (including Sky input), guard %g%n",elapsed/10000./1000,allocated/10000.,sink);
  if(args.length>1&&args[1].equals("new")){
   var s=new ShadeSky.Sky(-.999f,.03f,0,.999f,-.03f,0,1,0,0);float[] full=new float[3],neutral=new float[3],toward=new float[3];
   ShadeSky.sunsetAway=1;ShadeSky.radiance(s,1,0,0,full);ShadeSky.radiance(s,-1,0,0,toward);
   ShadeSky.sunsetAway=0;ShadeSky.radiance(s,1,0,0,neutral);float[] unchanged=new float[3];ShadeSky.radiance(s,-1,0,0,unchanged);
   for(int k=0;k<3;k++)if(toward[k]!=unchanged[k])throw new AssertionError("sun-facing sky changed");
   if(Math.abs(ShadeSky.luma(full[0],full[1],full[2])-ShadeSky.luma(neutral[0],neutral[1],neutral[2]))>1e-5)throw new AssertionError("away luminance changed");
   if(Math.abs(neutral[0]-neutral[1])+Math.abs(neutral[1]-neutral[2])>=Math.abs(full[0]-full[1])+Math.abs(full[1]-full[2]))throw new AssertionError("away chroma not reduced");
   ShadeSky.sunsetAway=1;System.out.println("OK opposite sunset control: reduced chroma, preserved luminance and sun-facing sky");
  }
 }
}
