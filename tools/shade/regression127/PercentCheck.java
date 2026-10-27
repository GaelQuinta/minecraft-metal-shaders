// Copyright 2026 mcopt-shade contributors. Licensed under the Apache License, Version 2.0.
package mcopt.metal.shade;
import java.nio.file.*;
import java.util.*;
/** Exercises actual menu positions, property values, save/reload and default removal for issue #21. */
public class PercentCheck {
 public static void main(String[] args) throws Exception {
  String[] keys={"caveFog","dynLights.strength","clouds.shadowStrength","sharpen","hdrSceneBrightness","hdrUiBrightness","vl.scaleLive","clouds.scale","water.falls","water.torchCaustics","weatherTime","drsFloor"};
  Path dir=Path.of(args[0]);int count=0;
  for(String key:keys) {
   ShadeOption o=ShadeOptions.all().stream().filter(s->s.key.equals("mcopt.shade."+key)).findFirst().orElseThrow();
   for(int pos=o.min;pos<=o.max;pos++) {
    o.set(pos);float got=Float.parseFloat(System.getProperty(o.key));
    if(Math.abs(got-pos/100f)>1e-5||o.pos()!=pos)throw new AssertionError(o.key+" "+pos+" -> "+got);
    count++;
   }
   int p=o.defaultPos()==o.min?o.max:o.min;o.set(p);ShadeSettings.save(dir);
   Properties saved=new Properties();try(var r=Files.newBufferedReader(dir.resolve("config/mcopt.properties"))){saved.load(r);}
   if(Math.abs(Float.parseFloat(saved.getProperty(o.key))-p/100f)>1e-5)throw new AssertionError("save "+o.key);
   System.clearProperty(o.key);System.setProperty(o.key,saved.getProperty(o.key));if(o.pos()!=p)throw new AssertionError("reload "+o.key);
   o.reset();ShadeSettings.save(dir);
   if(Files.readString(dir.resolve("config/mcopt.properties")).contains(o.key+"="))throw new AssertionError("reset "+o.key);
  }
  // These two intentionally use physical bases, not unit multipliers: don't break them when fixing the twelve.
  for(String key:new String[]{"vl.airForest","wetDark"}) {
   ShadeOption o=ShadeOptions.all().stream().filter(s->s.key.equals("mcopt.shade."+key)).findFirst().orElseThrow();
   o.set(100);float expected=key.equals("wetDark")?.002f:.017f;
   if(Math.abs(Float.parseFloat(System.getProperty(o.key))-expected)>1e-6)throw new AssertionError("physical base "+key);
  }
	 for(String value:new String[]{"0.005","0","-1","NaN","Infinity","1.1","0.2","1"}) {
	  System.setProperty("mcopt.shade.vl.scaleLive",value);
	  float expected=value.equals("0.2")?.2f:value.equals("1")?1f:.5f;
	  if(mcopt.metal.shade.vl.VlConfig.scaleLive(.5f)!=expected)throw new AssertionError("invalid VL resolution "+value);
	 }
  System.out.println("OK "+count+" percentage positions; 12 save/reload/reset cases; physical bases preserved");
 }
}
