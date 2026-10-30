// Copyright 2026 mcopt-shade contributors. Apache-2.0.
kernel void leaf_vertices(device const void *arena [[buffer(0)]], device const Section *sections [[buffer(1)]],
    device const Rec *recs [[buffer(2)]], device const uint *lists [[buffer(3)]], constant DrawFrame &df [[buffer(4)]],
    constant Projection &proj [[buffer(5)]], constant Globals &g [[buffer(6)]], constant Terrain &t [[buffer(7)]],
    constant OwnShadowFrame &sf [[buffer(8)]], constant OwnShadowCascade &sc [[buffer(9)]],
    constant ShadeLeaves &leaves [[buffer(10)]], device float4 *out [[buffer(11)]],
    texture2d<float> light [[texture(0)]], uint i [[thread_position_in_grid]]) {
    constexpr sampler sm(filter::nearest);
    float3 rel;
    VOut v = ownVertex(i, int3(sections[0].x,sections[0].y,sections[0].z),0,df,arena,proj,g,t,light,sm,rel,true,leaves);
    OwnShadowOut s = ownShadowVertex(i,0,sf,sc,arena,sections,recs,lists,leaves);
    out[i*3] = float4(v.shadePos,float(v.shadeLeaf));
    out[i*3+1] = s.pos;
    out[i*3+2] = ownClip(i,int3(sections[0].x,sections[0].y,sections[0].z),df,arena,proj,g,t,rel,true,leaves);
}
kernel void leaf_field(constant ShadeLeaves &l [[buffer(0)]], device float4 *out [[buffer(1)]], uint i [[thread_position_in_grid]]) {
    int3 origin = int3(int(i%16)*16-128,64,int(i/16)*16-128);
    float3 p = float3(16,1,0);
    float3 a = shadeLeafOffset(p,origin,l), b=shadeLeafOffset(p-float3(16,0,0),origin+int3(16,0,0),l);
    out[2*i]=float4(a,length(a-b));
    out[2*i+1]=float4(shadeLeafOffset(p,origin+int3(512,0,-512),l),0);
}
