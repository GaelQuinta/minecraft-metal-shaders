// Copyright 2026 mcopt-shade contributors. Apache-2.0. https://www.apache.org/licenses/LICENSE-2.0
// Local regression checks against the actual compiled ShadePbr implementation.
package mcopt.metal.shade;
public final class PbrMipCheck {
    static void check(boolean ok, String msg) { if (!ok) throw new AssertionError(msg); }
    public static void main(String[] args) {
        int flat = 0xffff8080;
        check(ShadePbr.mip(new int[] {flat,flat,flat,flat},2,2,true)[0]==flat,"neutral normal changed");
        check(ShadePbr.mip(new int[] {0,0,0,0},2,2,false)[0]==0,"unlit texels gained emission/F0");
        int e = ShadePbr.mip(new int[] {0xfe000000,0,0,0},2,2,false)[0]>>>24;
        check(e==64,"emission must average in linear space, without the 255 sentinel");
        int metal = ShadePbr.mip(new int[] {0x0000e600,0,0,0},2,2,false)[0];
        check(((metal>>>8)&255)==230,"conductor ID averaged into dielectric F0");
        int p = ShadePbr.mip(new int[] {0xffff80ff,flat,flat,flat},2,2,true)[0];
        double x=(p&255)/127.5-1,y=((p>>>8)&255)/127.5-1;
        check(x*x+y*y<=1.001,"normal mip left unit hemisphere");
        check(ShadePbr.mip(new int[] {flat},1,1,true)[0]==flat,"1x1 mip changed");
        System.out.println("PBR mip invariants: 6 checks passed");
    }
}
