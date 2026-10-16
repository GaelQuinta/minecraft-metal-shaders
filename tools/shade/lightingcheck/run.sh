#!/bin/sh
# Copyright 2026 mcopt-shade contributors. Apache-2.0.
# Build first. Optional BASELINE_JAR verifies Current against a previous release's real classes/shaders.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/mcopt-lightingcheck.XXXXXX")}"
mkdir -p "$OUT/classes"
JOML="$(find "$HOME/.gradle/caches/modules-2/files-2.1/org.joml/joml" -name 'joml-*.jar' ! -name '*sources*' | head -1)"
DEPS="$JOML"
LW="$HOME/Library/Application Support/PrismLauncher/libraries/org/lwjgl"
for j in "$LW/lwjgl/3.4.3/lwjgl-3.4.3.jar" "$LW/lwjgl-natives-macos-arm64/3.4.3/lwjgl-natives-macos-arm64-3.4.3.jar"; do DEPS="$DEPS:$j"; done
CP="$ROOT/metal/build/classes/java/main:$ROOT/metal/src/main/resources:$DEPS"
JAVABIN="${JAVA_HOME:+$JAVA_HOME/bin/}"
"${JAVABIN}javac" -cp "$CP" -d "$OUT/classes" "$HERE/Fixtures.java"
"${JAVABIN}java" --enable-native-access=ALL-UNNAMED -Dmcopt.shade=true -cp "$CP:$OUT/classes" Fixtures "$OUT"
if [ -n "${BASELINE_JAR:-}" ]; then
  "${JAVABIN}java" --enable-native-access=ALL-UNNAMED -Dmcopt.shade=true -cp "$BASELINE_JAR:$DEPS:$OUT/classes" Fixtures "$OUT/baseline" baseline
fi
clang -fobjc-arc -O2 -framework Foundation -framework Metal "$HERE/check.m" -o "$OUT/check"
"$OUT/check" "$OUT" "$HERE/probe.metal" "${2:-check}"
