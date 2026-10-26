/* Copyright 2026 mcopt-shade contributors.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy at https://www.apache.org/licenses/LICENSE-2.0
 * Unless required by applicable law or agreed to in writing, software distributed
 * under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
 * CONDITIONS OF ANY KIND, either express or implied. See the License for details.
 */
// Camera motion only; output is pre-exposed HDR. Input depth is reversed-Z world depth, before the hand.
struct ShadeMotionOut { float4 position [[position]]; float2 uv; };
vertex ShadeMotionOut shade_motion_vs(uint id [[vertex_id]]) {
    float2 p = float2(id == 1 ? 3.0 : -1.0, id == 2 ? 3.0 : -1.0);
    return {float4(p,0.0,1.0), float2(p.x*0.5+0.5,0.5-p.y*0.5)};
}
constexpr sampler motionLinear(filter::linear,address::clamp_to_edge);
constexpr sampler motionPoint(filter::nearest,address::clamp_to_edge);
struct ShadeMotionParams { float4 config; float4 size; };
fragment float4 shade_motion_fs(ShadeMotionOut in [[stage_in]], texture2d<float> scene [[texture(0)]],
    depth2d<float> depth [[texture(1)]], constant ShadeMotionParams &p [[buffer(0)]],
    constant ShadeFrame &f [[buffer(16)]], constant ShadeLook &L [[buffer(17)]]) {
    float2 uv = in.uv / p.config.yz;
    if (any(uv>1.0)) return float4(0.0);
    float2 jitter = f.jitter.xy*0.5;
    float2 depthUv = uv + (p.config.w>0.5 ? jitter : float2(0.0));
    float2 depthScale = p.size.xy / float2(depth.get_width(),depth.get_height());
    float z = depth.sample(motionPoint,clamp(depthUv,0.0,1.0)*depthScale);
    float4 center = scene.sample(motionLinear,in.uv);
    // f.invViewProj includes current jitter. Matrix reprojection uses unjittered screen coordinates.
    float4 world = f.invViewProj * float4(depthUv*2.0-1.0,z,1.0);
    float viewDepth = 1.0 / max(abs(world.w),1e-8);
    if (viewDepth < 0.5 || L.dt.x<=0.0 || L.dt.x>0.1 || L.exposureRef.w>0.5) return center;
    float4 old = L.prevViewProjNoJitter * world;
    if (old.w <= 1e-6) return center;
    float2 oldUv = old.xy/old.w*0.5+0.5;
    float2 unjitteredUv = depthUv-jitter;
    // Fixed 1/120 s shutter at 100%; velocity / dt makes the appearance independent of frame rate.
    float2 velocity = (unjitteredUv-oldUv) * (p.config.x / (120.0*max(L.dt.x,0.001)));
    float len = length(velocity);
    // Camera cuts/teleports: skip rather than smear a new view. Cap the normal trail to 4% of the image.
    if (length(unjitteredUv-oldUv)>0.25) return center;
    velocity *= min(1.0,0.04/max(len,1e-8));
    if (len*float(scene.get_width())<0.5) return center;
    float3 sum = center.rgb; float weight = 1.0;
    for (int i=0; i<10; i++) {
        float t = (float(i)+0.5)/10.0-0.5;
        float2 at = uv+velocity*t;
        if (any(at<0.0)||any(at>1.0)) continue;
        float dz = depth.sample(motionPoint,clamp(at+(p.config.w>0.5?jitter:float2(0.0)),0.0,1.0)*depthScale);
        // Reject samples across strong silhouettes; do not smear the background over a near surface.
        float ratio = z>1e-7 && dz>1e-7 ? min(z,dz)/max(z,dz) : (z<=1e-7 && dz<=1e-7 ? 1.0 : 0.0);
        float w = smoothstep(0.5,0.9,ratio);
        sum += scene.sample(motionLinear,at*p.config.yz).rgb*w; weight += w;
    }
    return float4(sum/weight,center.a);
}
