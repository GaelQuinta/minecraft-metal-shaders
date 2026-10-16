#!/bin/sh
# Copyright 2026 mcopt-shade contributors. Apache-2.0.
# Build the mod first. Compile the real game's GLSL with LWJGL, adapt it, and render it on Metal.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/mcopt-beaconcheck.XXXXXX")}"
mkdir -p "$OUT/classes"
python3 - "$HERE" "$OUT" <<'PYTHON'
import os, pathlib, subprocess, sys
here, out = map(pathlib.Path, sys.argv[1:])
root = here.parents[2]
lw = pathlib.Path(os.environ.get('LWJGL_DIR', str(pathlib.Path.home() / 'Library/Application Support/PrismLauncher/libraries/org/lwjgl')))
jars = [str(p) for name in ['lwjgl', 'lwjgl-natives-macos-arm64', 'lwjgl-shaderc', 'lwjgl-shaderc-natives-macos-arm64', 'lwjgl-spvc', 'lwjgl-spvc-natives-macos-arm64'] for p in (lw / name / '3.4.3').glob('*.jar')]
cp = ':'.join([str(root / 'metal/build/classes/java/main'), str(root / 'metal/src/main/resources')] + jars)
java = pathlib.Path(os.environ['JAVA_HOME']) / 'bin' if 'JAVA_HOME' in os.environ else pathlib.Path('')
mc = os.environ.get('MC_JAR', str(pathlib.Path.home() / '.gradle/caches/fabric-loom/26.3/minecraft-client.jar'))
subprocess.run([str(java / 'javac'), '-cp', cp, '-d', str(out / 'classes'), str(here / 'Translate.java'), str(here / 'Fixtures.java')], check=True)
cp += ':' + str(out / 'classes')
subprocess.run([str(java / 'java'), '--enable-native-access=ALL-UNNAMED', '-cp', cp, 'Translate', mc, str(out / 'beacon.metal')], check=True)
subprocess.run([str(java / 'java'), '-cp', cp, 'Fixtures', str(out / 'beacon.metal'), str(out)], check=True)
PYTHON
clang -fobjc-arc -O2 -framework Foundation -framework Metal "$HERE/check.m" -o "$OUT/check"
"$OUT/check" "$OUT"
