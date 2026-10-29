kernel void lava_probe(device float4 *out [[buffer(0)]],constant ShadeLook &l [[buffer(17)]],uint i [[thread_position_in_grid]]) {
 float t=float(i)/255.;float3 texel=mix(float3(.45,.08,.01),float3(1,.9,.2),t);
 float3 c=shadeLavaSurface(texel,float3(0),0,1);
 out[i]=float4(c,shadeLavaSprite(float2(t,.3),l)?1.:0.);
}
