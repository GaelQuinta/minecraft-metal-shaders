"""Load actual client mixins and round-trip palettes without opening Minecraft's window."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import zipfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('jar', type=Path)
p.add_argument('--manifest', type=Path, required=True, help='Existing profile manifest with cached Prism classpath')
p.add_argument('--java-home', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--mod', type=Path, action='append', default=[], help='Actual compatibility mod jar; repeat as needed')
p.add_argument('--palette-packing', choices=['true', 'false'])
p.add_argument('--expect-conflict', action='store_true', help='Require the original packing redirect failure')
a = p.parse_args()
root = a.output.resolve()
root.mkdir(parents=True, exist_ok=False)
game = root / 'game'
(game / 'mods').mkdir(parents=True)
(game / 'config').mkdir()
(game / 'config/mcopt.properties').write_text('profile=none\n')
jar = a.jar.resolve()
mods = [jar, *(mod.resolve() for mod in a.mod)]
for mod in mods:
    if (game / 'mods' / mod.name).exists():
        raise ValueError('Duplicate mod filename: ' + mod.name)
    shutil.copy2(mod, game / 'mods')
original = json.loads(a.manifest.read_text())['args']
deps = original[original.index('-classpath') + 1]
java = a.java_home / 'bin'
classes = root / 'classes'
classes.mkdir()
sources = [Path(__file__).with_name(n) for n in ['PalettePackingCheck.java', 'PaletteCompatibilityCheck.java']]
subprocess.run([str(java / 'javac'), '-proc:none', '-cp', str(jar) + ':' + deps,
                '-d', str(classes), *map(str, sources)], check=True)
with zipfile.ZipFile(game / 'mods/palette-compatibility-check.jar', 'w') as archive:
    for file in classes.rglob('*.class'):
        archive.write(file, str(file.relative_to(classes)))
    archive.writestr('fabric.mod.json', json.dumps({
        'schemaVersion': 1, 'id': 'palette-compatibility-check', 'version': '1', 'environment': 'client',
        'entrypoints': {'preLaunch': ['mcopt.allocationbench.PaletteCompatibilityCheck']}}))
args = [str(java / 'java'), '-XstartOnFirstThread', '-Xmx1G', '--enable-native-access=ALL-UNNAMED',
        '-Djava.awt.headless=true', '-Dmcopt.profile=none', '-Dmcopt.preload=false']
if a.palette_packing is not None:
    args.append('-Dmcopt.alloc.palettePacking=' + a.palette_packing)
args += ['-classpath', deps, 'net.fabricmc.loader.impl.launch.knot.KnotClient',
         '--gameDir', str(game), '--version', '26.3', '--accessToken', '0']
(root / 'manifest.json').write_text(json.dumps({
    'mods': [{'path': str(mod), 'sha256': hashlib.sha256(mod.read_bytes()).hexdigest()} for mod in mods],
    'args': args, 'expectedConflict': a.expect_conflict,
    'protocol': 'Fabric client preLaunch: load transformed PalettedContainer, verify mixin selection, packing round trips/concurrency/nesting; exit before game window.'
}, indent=2) + '\n')
with (root / 'game.log').open('w') as log:
    result = subprocess.run(args, cwd=game, stdout=log, stderr=subprocess.STDOUT, timeout=90)
log = (root / 'game.log').read_text()
if a.expect_conflict:
    if result.returncode == 0 or 'mcopt$packingIds' not in log or 'failed injection check' not in log:
        raise RuntimeError('Expected original packing conflict was not reproduced; inspect game.log')
    print('PASS: reproduced original packing redirect conflict')
elif result.returncode or 'PALETTE_COMPATIBILITY_CHECK PASS' not in log:
    raise RuntimeError('Compatibility check failed; inspect game.log')
else:
    print(next(line for line in log.splitlines() if 'PALETTE_COMPATIBILITY_CHECK PASS' in line))
