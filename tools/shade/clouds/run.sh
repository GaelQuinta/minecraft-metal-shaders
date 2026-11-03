#!/bin/sh
# Copyright 2026 mcopt-shade contributors. Licensed under the Apache License, Version 2.0.
#
# Offline preview of the volumetric clouds (no game): packs real ShadeFrame/ShadeLook/CloudParams for a set of scenarios
# (CloudPreviewFrames), runs the real passes of clouds.metal for N frames (checkerboard + history converge) and writes PNGs,
# or times the passes at a given output size. Needs a built metal module (./gradlew :metal:build).
#   tools/shade/clouds/run.sh png  [W H scale frames regex]   -> $OUT/png/<scenario>.png (+ _dome / _shadow variants)
#   tools/shade/clouds/run.sh time [W H scale frames regex]   -> GPU ms per pass (default 3024x1964, scale 0.4: balanced)
# CLOUDS_JOPTS="-Dkey=val ...": system properties for packing the frames (live look keys, e.g. -Dmcopt.shade.clouds.density=2).
# CLOUDS_DEV=<bits>: CloudParams' M3.1 dev bits (CloudConfig.DEV_*; 3072 = M3's resolve taps and march sky lookups).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
METAL="$HERE/../../../metal"
OUT="${CLOUDS_OUT:-${TMPDIR:-/tmp}/mcopt-clouds-preview}"
JAVA_BIN="${JAVA_HOME:+$JAVA_HOME/bin/}"
MODE="${1:-png}"
if [ "$MODE" = time ]; then W="${2:-3024}"; H="${3:-1964}"; else W="${2:-1280}"; H="${3:-832}"; fi
SCALE="${4:-0.4}"; FRAMES="${5:-24}"; ONLY="${6:-}"
JOML="$(find ~/.gradle/caches/modules-2 -name 'joml-1.10*.jar' | grep -v sources | head -1)"
JSPEC="$(find ~/.gradle/caches -name 'jspecify-*.jar' | grep -v sources | head -1)"
CP="$METAL/build/classes/java/main:$METAL/src/main/resources:$JOML:$JSPEC"
# (v12-opt) CloudParams.pack reads the style setting through ShadeClouds, whose static buffers need LWJGL (jar + its macOS natives)
LWJGL_DIR="$HOME/Library/Application Support/PrismLauncher/libraries/org/lwjgl"
for j in "$LWJGL_DIR"/lwjgl/3.4.3/lwjgl-3.4.3.jar "$LWJGL_DIR"/lwjgl-natives-macos-arm64/3.4.3/lwjgl-natives-macos-arm64-3.4.3.jar; do [ -f "$j" ] && CP="$CP:$j"; done
# CLOUDS_RES=<dir>: a directory holding mcopt/shade/*.metal overrides, ahead of the sources (instrumented experiments)
[ -n "$CLOUDS_RES" ] && CP="$CLOUDS_RES:$CP"
rm -rf "$OUT/classes" "$OUT/frames" && mkdir -p "$OUT/classes" "$OUT/frames" "$OUT/png"
"${JAVA_BIN}javac" -d "$OUT/classes" -cp "$CP" "$HERE/CloudPreviewFrames.java" "$HERE/CloudPreviewSource.java"
"${JAVA_BIN}java" -cp "$OUT/classes:$CP" CloudPreviewSource "$OUT/clouds_preview.metal" "$OUT/lut.metal" "$HERE/preview_composite.metal"
# CLOUDS_DEFS="#define X 1 ...": extra MSL defines ahead of the passes (experiments)
if [ -n "$CLOUDS_DEFS" ]; then printf '%b\n' "$CLOUDS_DEFS" | cat - "$OUT/clouds_preview.metal" > "$OUT/cp.tmp" && mv "$OUT/cp.tmp" "$OUT/clouds_preview.metal"; fi
"${JAVA_BIN}java" ${CLOUDS_JOPTS:-} -Dclouds.dev="${CLOUDS_DEV:-0}" -Dclouds.yawRate="${CLOUDS_YAWRATE:-0}" -Dclouds.wind="${CLOUDS_WIND:-1}" -cp "$OUT/classes:$CP" CloudPreviewFrames "$OUT/frames" "$W" "$H" "$SCALE" "$FRAMES" "$ONLY"
clang -fobjc-arc -O1 -Wno-enum-conversion -framework Foundation -framework Metal -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers \
	"$HERE/cloudpreview.m" -o "$OUT/cloudpreview"
cd "$OUT"
for f in frames/*.params; do
	n="$(basename "$f" .params)"
	if [ "$MODE" = time ]; then
		./cloudpreview clouds_preview.metal lut.metal frames "$n" "$W" "$H" time | grep -v bakes
	else
		./cloudpreview clouds_preview.metal lut.metal frames "$n" "$W" "$H" "png/$n.png" 0 >/dev/null
		[ -n "$CLOUDS_EXTRA" ] && ./cloudpreview clouds_preview.metal lut.metal frames "$n" "$W" "$H" "png/${n}_dome.png" 1 >/dev/null
		[ -n "$CLOUDS_EXTRA" ] && ./cloudpreview clouds_preview.metal lut.metal frames "$n" "$W" "$H" "png/${n}_shadow.png" 2 >/dev/null
		echo "wrote $OUT/png/$n.png"
	fi
done
