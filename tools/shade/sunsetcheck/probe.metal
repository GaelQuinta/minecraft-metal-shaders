// Copyright 2026 mcopt-shade contributors. Apache-2.0.
// Production post + sky LUT library. Raw atmosphere, SDR/HDR atmosphere, neutral surface, SDR/HDR LUT.
kernel void sunset_probe(device float4 *out [[buffer(0)]], constant ShadeFinalParams &P [[buffer(1)]],
                         constant ShadeFrame &f [[buffer(16)]], constant ShadeLook &L [[buffer(17)]],
                         uint id [[thread_position_in_grid]]) {
    float alt = float(id / 91) * (2.0 * M_PI_F / 180.0), az = float(id % 91) * (2.0 * M_PI_F / 180.0);
    float3 dir=float3(-cos(az)*cos(alt),sin(alt),sin(az)*cos(alt)), trans;
    float3 sky=shadeSkyRadiance(dir,f,trans,L.skyGoldH.w>0.5);
    out[id*6]=float4(sky,1);
    out[id*6+1]=float4(shadeDisplay(sky*f.time.z,L),1);
    out[id*6+2]=float4(shadeFullHdr(sky*f.time.z,L,P),1);
    float3 lut = float3(half3(shadeSkyLutRadiance(dir,f,L)));
    out[id*6+4]=float4(shadeDisplay(lut*f.time.z,L),1);
    out[id*6+5]=float4(shadeFullHdr(lut*f.time.z,L,P),1);
    // Sweep face orientation and sun visibility; neutral material detects casts independently of biome green.
    half3 normal=half3(dir); half shadow=half(id%17)/16.0h;
    float3 surface=shadeLit2(half3(.25h),normal,1.0h,0.0h,shadow,false,false,f,L);
    out[id*6+3]=float4(shadeFullHdr(surface*f.time.z,L,P),1);
}
