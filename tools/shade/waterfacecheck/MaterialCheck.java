import mcopt.metal.shade.terrain.ShadeFluidLight;
public class MaterialCheck {
 public static void main(String[] args) {
  for(int rgb:new int[]{0xff3377aa,0xff000000,0xffffffff}) {
   if(ShadeFluidLight.materialColor(rgb,true,false)!=rgb)throw new AssertionError("source water altered");
   if(ShadeFluidLight.materialColor(rgb,false,true)!=rgb)throw new AssertionError("non-water altered");
   int tag=ShadeFluidLight.materialColor(rgb,true,true);
   if((tag>>>24)!=254 || (tag&0xffffff)!=(rgb&0xffffff))throw new AssertionError("fall tag lost RGB");
  }
  System.out.println("PASS real mesher material tag: falling water only; RGB retained");
 }
}
