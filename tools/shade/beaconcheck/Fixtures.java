// Copyright 2026 mcopt-shade contributors. Apache-2.0.
import java.nio.file.*;
import mcopt.metal.shade.*;
public class Fixtures {
 public static void main(String[] a) throws Exception {
  String src=Files.readString(Path.of(a[0])), normal=ShadeMsl.hdrFragment(src);
  Path out=Path.of(a[1]); Files.createDirectories(out);
  Files.writeString(out.resolve("baseline.metal"),normal);
  for(String type:new String[]{"opaque","translucent"}) {
   String patched=ShadeBeacon.fragment("minecraft:pipeline/beacon_beam_"+type,src);
   if(!patched.contains(".rgb + shadeBeaconEmission("))throw new AssertionError("beam not patched");
   Files.writeString(out.resolve(type+".metal"),patched);
  }
  for(String name:new String[]{"minecraft:pipeline/entity_translucent","minecraft:pipeline/beacon_beam_oit_accumulate","minecraft:pipeline/lightning"})
   if(!ShadeBeacon.fragment(name,src).equals(normal))throw new AssertionError("unrelated stage changed");
  String altered=src.replace("calculateFinalColor", "customFinalColor");
  if(!ShadeBeacon.fragment("minecraft:pipeline/beacon_beam_opaque",altered).equals(ShadeMsl.hdrFragment(altered)))throw new AssertionError("fallback changed");
  String noColor=src.replace("[[color(0)]]","[[color(1)]]");
  if(!ShadeBeacon.fragment("minecraft:pipeline/beacon_beam_opaque",noColor).equals(noColor))throw new AssertionError("non-color0 changed");
  System.out.println("OK both beam stages patched, unrelated/custom/unsupported stages unchanged");
 }
}
