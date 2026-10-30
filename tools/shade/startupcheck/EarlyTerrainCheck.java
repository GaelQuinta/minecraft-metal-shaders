package mcopt.metal;
import java.util.*;
import java.util.concurrent.*;
import mcopt.metal.shade.*;
import mcopt.metal.shade.terrain.ShadeTerrain;
public class EarlyTerrainCheck {
 public static void main(String[] args)throws Exception {
  long ctx=MetalBridge.createHeadlessContext();
  if(ShadeRender.ready())throw new AssertionError("must begin before world globals");
  ShadeCompile.start(ctx);
  var field=ShadeTerrain.class.getDeclaredField("LIBRARIES");field.setAccessible(true);
  Map<?,?> m=(Map<?,?>)field.get(null);
  if(m.isEmpty())throw new AssertionError("no terrain warmup before world");
  long t=System.nanoTime();
  for(Object v:m.values())if(((CompletableFuture<?>)v).get(60,TimeUnit.SECONDS).equals(0L))throw new AssertionError("terrain library failed");
  int count=m.size();ShadeTerrain.warmUp(ctx);
  if(m.size()!=count||ShadeRender.ready())throw new AssertionError("requires world or duplicate work");
  System.out.printf("PASS %d terrain stages prepared before any world globals in %.2f s; repeated warmup reuses them%n",count,(System.nanoTime()-t)/1e9);
 }
}
