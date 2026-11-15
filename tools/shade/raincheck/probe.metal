// Copyright 2026 mcopt-shade contributors. Apache-2.0.
constant float distances[5]={0.25,2.0,6.0,16.0,32.0};
kernel void rain_preview(device const float4 *in [[buffer(0)]],device float4 *out [[buffer(1)]],constant ShadeFrame &f [[buffer(16)]],constant ShadeLook &l [[buffer(17)]],constant ShadeGpu &g [[buffer(18)]],texture2d<half> lut [[texture(17)]],uint i [[thread_position_in_grid]]) {
 constexpr sampler s(filter::linear,address::clamp_to_edge);
 float4 pixel=float4(f.screen.x*.5,f.screen.y*.5,f.proj[3][2]/12.-f.proj[2][2],1);
 float4 rain=shadeWeather3(in[i],pixel,f,l,g,lut,s);
 float3 composite=mix(float3(.06,.09,.075),rain.rgb,rain.a);
 out[i]=float4(shadeLinearToSrgbExact(shadeDisplay(composite,l)),1);
}
kernel void rain_probe(device float4 *out [[buffer(0)]],constant ShadeFrame &f [[buffer(16)]],constant ShadeLook &l [[buffer(17)]],constant ShadeGpu &g [[buffer(18)]],texture2d<half> lut [[texture(17)]],uint i [[thread_position_in_grid]]) {
 float a=float(i%16)/15.0, d=distances[(i/16)%5];
 float4 pixel=float4(f.screen.x*.5,f.screen.y*.5,f.proj[3][2]/d-f.proj[2][2],1);
 float3 col=i<80?float3(.25,.4,.6):float3(.95,.95,.95);
 constexpr sampler s(filter::linear,address::clamp_to_edge);
 out[i]=shadeWeather3(float4(col,a),pixel,f,l,g,lut,s);
}
