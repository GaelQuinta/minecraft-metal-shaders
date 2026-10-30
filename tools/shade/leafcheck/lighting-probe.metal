// Copyright 2026 mcopt-shade contributors. Apache-2.0.
kernel void leaf_lighting(constant ShadeFrame &f [[buffer(0)]], constant ShadeLook &l [[buffer(1)]],
    device float4 *out [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    float angle=float(i%128)*6.2831853/128.0;
    half3 n=half3(cos(angle),0,sin(angle));
    bool leaf=i>=128;
    half shadow=(i>=256 && i<512) ? 0.0h : 1.0h;
    out[i]=float4(shadeLit2(half3(.12h,.24h,.06h),n,1.0h,0.0h,shadow,false,true,f,l,leaf,(i>=384 ? 1.0 : -1.0)*f.lightDirWorld.xyz),1);
}
