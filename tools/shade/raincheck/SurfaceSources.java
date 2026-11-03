// Copyright 2026 mcopt-shade contributors. Apache-2.0.
import java.nio.file.*;
import java.util.zip.*;
import mcopt.metal.shade.*;
public class SurfaceSources {
 public static void main(String[] a)throws Exception{
  Path out=Path.of(a[0]);Files.createDirectories(out);
  String prelude=ShadeMsl.post();
  try(ZipFile baseline=new ZipFile(a[1])){
   String rain=new String(baseline.getInputStream(baseline.getEntry("mcopt/shade/weather.metal")).readAllBytes(),java.nio.charset.StandardCharsets.UTF_8);
   Files.writeString(out.resolve("before.metal"),prelude+"\n#define SHADE_WEATHER\n"+rain);
  }
  Files.writeString(out.resolve("after.metal"),prelude+"\n#define SHADE_WEATHER\n"+ShadeMsl.resource("weather.metal"));
  String weather="struct main0_in {float4 c [[user(locn0)]];}; struct main0_out {float4 fragColor [[color(0)]];}; float4 calculateFinalColor(float4 c){return c;} fragment main0_out main0(main0_in in [[stage_in]]) { main0_out out = {}; out.fragColor = calculateFinalColor(in.c); return out;}";
  String patched=ShadeMsl.weather(weather);if(!patched.contains("out.fragColor = shadeWeather3("))throw new AssertionError("rain patch not applied");
  Files.writeString(out.resolve("patched-weather.metal"),patched);
 }
}
