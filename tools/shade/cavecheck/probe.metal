// Copyright 2026 mcopt-shade contributors. Apache-2.0.
// Calls production lighting and colour functions; normals differ at the same distance from the held light.
kernel void caveProbe(device float4* out [[buffer(0)]],constant ShadeDynLights& D [[buffer(1)]],
 constant ShadeFrame& f [[buffer(16)]],constant ShadeLook& L [[buffer(17)]],texture3d<half> vis [[texture(0)]],
 texture3d<half> irr [[texture(1)]],texture3d<half> dirs [[texture(2)]],uint i [[thread_position_in_grid]]) {
 if(i==0)out[i]=float4(shadeLit2(half3(.5),half3(0,1,0),0,0,0,false,false,f,L),1);
 if(i==1)out[i]=float4(shadeLowLightColour(float3(.01),.001,L),1);
 if(i==2||i==3){float3 n=i==2?float3(0,0,1):float3(1,0,0);out[i]=float4(shadeDynamicLights(D,vis,float3(0,0,-3),n,false,0),1);}
 if(i==4||i==5){float3 n=i==4?float3(0,0,1):float3(1,0,0);out[i]=float4(shadeDynamicLightsVol(D,irr,dirs,float3(0,0,-3),n,false,0),1);}
 if(i==6||i==7)out[i]=float4(shadeDynamicLights(D,vis,float3(0,0,i==6?-3:-8),float3(0,0,1),false,0),1);
 if(i==8)out[i]=float4(f.ambientBlock.rgb,1);
 if(i==9)out[i]=float4(shadeLit2(half3(.5),half3(0,1,0),1,0,1,false,false,f,L),1);
 if(i==10||i==11){
#ifdef MCOPT_SHADE_TORCH_LIGHT
  out[i]=float4(shadeDynamicLights(D,vis,float3(0,0,i==10?-1.5:-8),float3(0,0,1),false,0,f.ambientBlock.rgb),1);
#else
  out[i]=float4(f.ambientBlock.rgb*shadeDynamicLights(D,vis,float3(0,0,i==10?-1.5:-8),float3(0,0,1),false,0),1);
#endif
 }
 if(i==12||i==13)out[i]=float4(shadeLit2(half3(.5),half3(0,1,0),0,half(i==12?14.0/15.0:7.0/15.0),0,false,false,f,L),1);
}

// Optional tunnel preview: actual block texture, diffuse irradiance volume, low-light colour and display transform.
kernel void caveRoom(device float4* out [[buffer(0)]],constant ShadeDynLights& D [[buffer(1)]],
 constant ShadeFrame& f [[buffer(16)]],constant ShadeLook& L [[buffer(17)]],texture3d<half> vis [[texture(0)]],
 texture3d<half> irr [[texture(1)]],texture3d<half> dirs [[texture(2)]],texture2d<float> stone [[texture(3)]],uint2 px [[thread_position_in_grid]]) {
 uint2 sz=uint2(f.screen.xy);if(any(px>=sz))return;
 float2 uv=(float2(px)+.5)/float2(sz);float3 ray=normalize(float3((uv.x*2-1)*float(sz.x)/sz.y*.65,(1-uv.y*2)*.65-.08,-1));
 float3 hit=float3(ray.x<0?-1.5:1.5,ray.y<0?-1.6:1.4,-12)/ray;
 float t=min(min(hit.x,hit.y),hit.z);float3 p=ray*t,n=hit.x<=hit.y&&hit.x<=hit.z?float3(ray.x<0?1:-1,0,0):hit.y<=hit.z?float3(0,ray.y<0?1:-1,0):float3(0,0,1);
 float2 tile=n.x!=0?p.zy:n.y!=0?p.xz:p.xy;constexpr sampler s(filter::nearest,address::repeat);
 half3 albedo=half3(shadeSrgbToLinearExact(stone.sample(s,tile).rgb));
 float3 c=shadeLit2(albedo,half3(n),0,0,0,false,false,f,L);
#ifdef MCOPT_SHADE_TORCH_LIGHT
 c+=float3(albedo)*shadeDynamicLightsVol(D,irr,dirs,p,n,false,0,f.ambientBlock.rgb);
#else
 c+=float3(albedo)*f.ambientBlock.rgb*shadeDynamicLightsVol(D,irr,dirs,p,n,false,0);
#endif
 float ex=f.time.z;c=shadeLowLightColour(c*ex,shadeLuma(c),L);
 out[px.y*sz.x+px.x]=float4(shadeLinearToSrgbExact(saturate(shadeDisplay(c,L))),1);
}
