#!/usr/bin/env python3
# Copyright 2026 mcopt-shade contributors. Licensed under the Apache License, Version 2.0.
import pathlib, subprocess, sys, tempfile
here = pathlib.Path(__file__).resolve().parent
root = here.parents[2]
out = pathlib.Path(sys.argv[1]) if len(sys.argv)>1 else pathlib.Path(tempfile.mkdtemp(prefix='mcopt-127-'))
out.mkdir(parents=True, exist_ok=True)
def function(text, name):
    start = text.rfind('static inline ', 0, text.index(name+'('))
    begin = text.index('{', start); depth = 1; end = begin+1
    while depth:
        depth += (text[end]=='{') - (text[end]=='}'); end += 1
    return text[start:end]
srcdir = pathlib.Path(sys.argv[2]) if len(sys.argv)>2 else root/'metal/src/main/resources/mcopt/shade'
post=(srcdir/'shade_post.metal').read_text(); vl=(srcdir/'vl.metal').read_text()
src='#include <metal_stdlib>\nusing namespace metal;\nconstexpr sampler shadeLinearClamp(filter::linear,address::clamp_to_edge);\nstruct VlParams {float4 size;float4 shape;};\n'
src+='\n'.join([function(post,'shadeVlScaled'),function(post,'shadeVlUpsample'),function(vl,'vlUpsample')])
src+='''
kernel void probe(texture2d<half> light [[texture(0)]], texture2d<half> depth [[texture(1)]],
 device float4 *out [[buffer(0)]], constant float4 &q [[buffer(1)]], constant VlParams &p [[buffer(2)]]) {
 out[0]=float4(shadeVlUpsample(light,depth,float2(.5),q.x,224,float2(q.y),0,1,true));
 out[1]=float4(float3(vlUpsample(depth,float2(4*q.y),q.x,p)),1);
}
'''
(out/'probe.metal').write_text(src)
subprocess.run(['clang','-fobjc-arc','-O2','-framework','Foundation','-framework','Metal',str(here/'check.m'),'-o',str(out/'check')],check=True)
subprocess.run([str(out/'check'),str(out/'probe.metal')],check=True)
