// Copyright 2026 mcopt-shade contributors. Apache-2.0.
// Frozen 1.2.6 nine-fetch tent for differential GPU testing.
fragment half4 shade_bloom_up_reference(ShadeFsOut in [[stage_in]], texture2d<half> level [[texture(0)]], texture2d<half> coarser [[texture(1)]],
                              constant ShadeBloomUp &p [[buffer(0)]]) {
	half3 l = level.sample(shadeLinearClamp, in.uv).rgb;
	float2 t = 1.0 / float2(coarser.get_width(), coarser.get_height());
	// 3x3 tent upsample of the coarser accumulation
	// (1.2.4, GitHub issue #8) the tent's weights (4, 2, 1) / 16 applied per tap: summed first, 16 taps of a sun core held at
	// the first level's 30000 overflowed half (Inf, then NaN in the final pass)
	half3 u = coarser.sample(shadeLinearClamp, in.uv).rgb * 0.25h;
	u += coarser.sample(shadeLinearClamp, in.uv + float2(t.x, 0)).rgb * 0.125h + coarser.sample(shadeLinearClamp, in.uv - float2(t.x, 0)).rgb * 0.125h
	    + coarser.sample(shadeLinearClamp, in.uv + float2(0, t.y)).rgb * 0.125h + coarser.sample(shadeLinearClamp, in.uv - float2(0, t.y)).rgb * 0.125h;
	u += coarser.sample(shadeLinearClamp, in.uv + t).rgb * 0.0625h + coarser.sample(shadeLinearClamp, in.uv - t).rgb * 0.0625h
	    + coarser.sample(shadeLinearClamp, in.uv + float2(t.x, -t.y)).rgb * 0.0625h + coarser.sample(shadeLinearClamp, in.uv + float2(-t.x, t.y)).rgb * 0.0625h;
	return half4(l * half(p.w.x) + u * half(p.w.y), 1.0h);
}
