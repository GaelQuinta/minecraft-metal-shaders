"""Headless packing and byte-for-byte mesh regression checks using a profile's cached dependencies."""
import argparse
import json
from pathlib import Path
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--baseline', type=Path, required=True)
p.add_argument('--candidate', type=Path, required=True)
p.add_argument('--manifest', type=Path, required=True)
p.add_argument('--java-home', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
a.output = a.output.resolve()
a.output.mkdir(parents=True, exist_ok=False)
classes = a.output / 'classes'
classes.mkdir()
args = json.loads(a.manifest.read_text())['args']
deps = args[args.index('-classpath') + 1]
java = a.java_home / 'bin'
cp = str(a.candidate.resolve()) + ':' + deps
sources = [Path(__file__).with_name(n) for n in ['PalettePackingCheck.java', 'MeshOrderCheck.java']]
subprocess.run([str(java / 'javac'), '-proc:none', '-cp', cp, '-d', str(classes), *map(str, sources)], check=True)
with (a.output / 'packing.log').open('w') as log:
    subprocess.run([str(java / 'java'), '-cp', str(classes) + ':' + cp, 'mcopt.allocationbench.PalettePackingCheck'], cwd=a.output, stdout=log, stderr=subprocess.STDOUT, check=True)
for mode in ['', 'plane', 'cluster', 'cell', 'facecell', 'cellrun', 'mortonrun']:
    for qrec in ['false', 'true']:
        hashes = []
        for name, jar in [('baseline', a.baseline), ('candidate', a.candidate)]:
            log = a.output / f'mesh-{mode or "emission"}-{qrec}-{name}.log'
            with log.open('w') as f:
                subprocess.run([str(java / 'java'), '--enable-native-access=ALL-UNNAMED',
                    f'-Dmcopt.own.mesh.order={mode}', f'-Dmcopt.own.mesh.qrec={qrec}', '-Dmcopt.own.compact=true',
                    '-cp', str(classes) + ':' + str(jar.resolve()) + ':' + deps,
                    'mcopt.metal.own.MeshOrderCheck'], cwd=a.output, stdout=f, stderr=subprocess.STDOUT, check=True)
            hashes.append(next(x for x in log.read_text().splitlines() if x.startswith('MESH_ORDER_CHECK')))
        if hashes[0] != hashes[1]: raise AssertionError((mode, qrec, hashes))
        print('PASS', mode or 'emission', 'qrec=' + qrec, flush=True)
print((a.output / 'packing.log').read_text())
