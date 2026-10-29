// Copyright 2026 mcopt-shade contributors. Apache-2.0.
package mcopt.metal.shade;
/** Exercise the real FFM wrapper and packaged dylib; null pipeline/target is a supported no-op. */
public class PassAbiCheck {
    public static void main(String[] args) {
        ShadeRender.pass(0,0,0,0,null,null,"default ABI check");
        for(int globals:new int[]{ShadeRender.GLOBALS_ALL,ShadeRender.GLOBALS_NONE,ShadeRender.GLOBALS_GPU})
            ShadeRender.pass(0,0,0,0,null,null,"scoped ABI check",globals);
        System.out.println("PASS production Java/native pass ABI: default and all scoped modes");
    }
}
