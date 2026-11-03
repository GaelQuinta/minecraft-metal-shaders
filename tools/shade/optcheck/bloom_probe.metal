// Copyright 2026 mcopt-shade contributors. Apache-2.0.
struct BloomProbeParams { ShadeFinalParams hdr; float4 flags; };
fragment half4 bloom_probe(ShadeFsOut in [[stage_in]], texture2d<half> scene [[texture(0)]], texture2d<half> accum [[texture(1)]],
    texture2d<half> level0 [[texture(2)]], constant BloomProbeParams &p [[buffer(0)]], constant ShadeLook &L [[buffer(17)]]) {
    float3 s=float3(scene.sample(shadeLinearClamp,in.uv).rgb), n=float3(level0.sample(shadeLinearClamp,in.uv).rgb);
    float3 b=(float3(accum.sample(shadeLinearClamp,in.uv).rgb)+n*p.flags.y)*p.flags.x;
    float3 c=shadeBloomComposite(s,b,n,.16,p.flags.z);
    return half4(half3(p.flags.w>0.5?shadeFullHdr(c,L,p.hdr):shadeLinearToSrgbExact(shadeDisplay(c,L))),1.0h);
}
kernel void halation_contract(device float4 *out [[buffer(0)]],uint i [[thread_position_in_grid]]) {
    float3 s,b,n;
    if(i==0){s=b=n=float3(10);} // uniform bright field, no colour cast
    else if(i==1){s=float3(10);b=n=float3(2);} // bright core stays unchanged
    else if(i==2){s=float3(.03);b=n=float3(.3);} // ordinary brightness, no halation
    else if(i==3){s=float3(.03);b=n=float3(3);} // highlight fringe, red > green > blue
    else {s=float3(.03);b=n=float3(0,0,10);} // pure blue emission acquires no red fringe
    float3 base=mix(s,b,.16);
    out[i*2]=float4(shadeBloomComposite(s,b,n,.16,.08)-base,1);
    out[i*2+1]=float4(shadeBloomComposite(s,b,n,.16,0)-base,1);
}
