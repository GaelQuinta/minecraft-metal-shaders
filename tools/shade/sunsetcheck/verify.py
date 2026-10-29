#!/usr/bin/env python3
# Copyright 2026 mcopt-shade contributors. Apache-2.0.
import array
import json
from pathlib import Path
import sys

out=Path(sys.argv[1]); rows=[]; failures=[]
baseline=Path(sys.argv[2]) if len(sys.argv)>2 else None
unchanged_error=0.0; luminance_error=0.0
for name in (out/'names.txt').read_text().splitlines():
    expected=array.array('f',(out/(name+'.sky')).read_bytes())
    actual=array.array('f',(out/(name+'.gpu')).read_bytes())
    worst=[0.0]*6; parity=0.0
    for i in range(len(expected)//4):
        cpu=expected[i*4:i*4+3]; raw=actual[i*24:i*24+3]
        parity=max(parity,max(abs(a-b) for a,b in zip(cpu,raw))/max(max(cpu),.001))
        for stage in range(6):
            c=actual[i*24+stage*4:i*24+stage*4+3]
            if not all(0<=v<60000 for v in c): failures.append(name+' invalid radiance')
            worst[stage]=max(worst[stage],c[1]/max(c[0],c[2],1e-6)-1)
    elevation=int(name.rsplit('_',1)[1])
    if baseline:
        old=array.array('f',(baseline/(name+'.gpu')).read_bytes())
        if len(old)!=len(actual): raise ValueError(name+' baseline size mismatch')
        if elevation in (-15,-9,60):
            unchanged_error=max(unchanged_error,max(abs(a-b) for a,b in zip(actual,old)))
        for i in range(len(expected)//4):
            luma=lambda values:sum(c*w for c,w in zip(values,(.2126,.7152,.0722)))
            before=luma(old[i*24:i*24+3]); after=luma(actual[i*24:i*24+3])
            luminance_error=max(luminance_error,abs(before-after)/max(before,.001))
        if '_evening_' in name and 0<=elevation<=25:
            def blue_excess(values):
                return max(0.0,max(values[i+14]/max(values[i+12],values[i+13],1e-6)-1 for i in range(0,len(values),24)))
            if blue_excess(actual)>blue_excess(old)+.02: failures.append(name+' increased blue cast on neutral surfaces')
    rows.append(dict(name=name,green_excess=worst,cpu_gpu_relative_error=parity))
    if parity>.005: failures.append(name+' CPU/GPU atmosphere mismatch')
    if '_legacy_' not in name and 0<=elevation<=25 and max(worst)>.02: failures.append(name+' green excess above 2%: '+str(worst))
(out/'measurements.json').write_text(json.dumps(rows,indent=2)+'\n')
graded=[r for r in rows if '_legacy_' not in r['name'] and 0<=int(r['name'].rsplit('_',1)[1])<=25]
print('Sunset sweep, sun 0..25 degrees (raw / SDR / HDR / neutral surface / LUT SDR / LUT HDR):',*[f'{100*max(r["green_excess"][i] for r in graded):.2f}%' for i in range(6)])
print('CPU/GPU atmosphere relative error:',f'{max(r["cpu_gpu_relative_error"] for r in rows):.6f}')
if baseline:
    print(f'Unchanged noon/night max difference: {unchanged_error:.7f}; atmosphere luminance relative difference: {luminance_error:.7f}')
    if unchanged_error>.0001: failures.append('Noon/night changed')
    if luminance_error>.001: failures.append('Atmosphere correction changed brightness')
if failures:
    print('\n'.join(failures)); sys.exit(1)
print('PASS sunset hue, finite radiance and CPU/GPU atmosphere agreement in all three presets')
