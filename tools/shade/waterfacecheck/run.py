from pathlib import Path
import subprocess
import sys
here=Path(__file__).resolve().parent;r=here.parents[2];out=Path(sys.argv[1] if len(sys.argv)>1 else '/tmp/water-classification').resolve();out.mkdir(exist_ok=True)
water=(r/'metal/src/main/resources/mcopt/shade/water.metal').read_text()
# Pull the actual production predicate and its uniform layout into a minimal GPU probe.
a=water.index('static inline bool shadeWaterIsFall(');b=water.index('\n}',a)+2
fn=water[a:b];tagged='vertexAlpha' in fn
src='#include <metal_stdlib>\nusing namespace metal;\nstruct ShadeWaterParams {float4 dummy;float4 state;};\n'+fn+'\n'
# Uniform is a real constant-buffer argument, as in the production fragment.
src=src+'''kernel void classify(device uint *out [[buffer(0)]],constant ShadeWaterParams &wp [[buffer(1)]],uint i [[thread_position_in_grid]]) {
 float ny=i<2?0:1;float alpha=(i%2)==0?1.0:254.0/255.0;
 out[i]=shadeWaterIsFall(ny,1.0,wp'''+(',alpha' if tagged else '')+''');
}'''
(out/'probe.metal').write_text(src)
subprocess.run(['clang','-fobjc-arc','-O2','-framework','Foundation','-framework','Metal',str(here/'check.m'),'-o',str(out/'test')],check=True)
subprocess.run([str(out/'test'),str(out/'probe.metal')],check=True)
