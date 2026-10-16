// Copyright 2026 mcopt-shade contributors. Apache-2.0.
// Appended to the production shader library; no duplicate lighting or tone-map implementation.
static float3 probeLight(uint id, constant ShadeFrame &f, constant ShadeLook &L) {
    half sky = half(id % 16) / half(15), block = half((id / 16) % 4) / half(3), shadow = half((id / 64) % 2);
    uint face = (id / 128) % 3;
    half3 n = face == 0 ? half3(0,1,0) : face == 1 ? half3(1,0,0) : half3(0,0,1);
    return shadeLit2(half3(.65h), n, sky, block, shadow, false, false, f, L);
}
kernel void probe(device float4 *result [[buffer(0)]], constant ShadeFrame &f [[buffer(16)]],
                  constant ShadeLook &L [[buffer(17)]], uint id [[thread_position_in_grid]]) {
    result[id] = float4(probeLight(id, f, L), 1);
}
kernel void displayProbe(device float4 *result [[buffer(0)]], constant ShadeFinalParams &P [[buffer(1)]],
                         constant ShadeFrame &f [[buffer(16)]], constant ShadeLook &L [[buffer(17)]],
                         constant ShadeGpu &g [[buffer(18)]], uint id [[thread_position_in_grid]]) {
    result[id] = float4(shadeFullHdr(probeLight(id,f,L) * g.exposure.x, L, P), 1);
}
