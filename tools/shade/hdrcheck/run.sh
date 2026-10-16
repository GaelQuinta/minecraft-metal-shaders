#!/bin/sh
# Copyright 2026 mcopt-shade contributors. Apache-2.0.
# Build first: ./gradlew :metal:build. Optional output directory, retained for inspection.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/mcopt-hdrcheck.XXXXXX")}"
mkdir -p "$OUT/classes"
JOML="$(find "$HOME/.gradle/caches/modules-2/files-2.1/org.joml/joml" -name 'joml-*.jar' ! -name '*sources*' | head -1)"
CP="$ROOT/metal/build/classes/java/main:$ROOT/metal/src/main/resources:$JOML"
JAVABIN="${JAVA_HOME:+$JAVA_HOME/bin/}"
"${JAVABIN}javac" -cp "$CP" -d "$OUT/classes" "$HERE/HdrFixtures.java"
"${JAVABIN}java" -Dmcopt.shade=true -cp "$CP:$OUT/classes" HdrFixtures "$OUT"
clang -fno-objc-arc -O2 -framework Foundation -framework Metal -framework QuartzCore -framework AppKit \
  "$HERE/hdrcheck.m" -o "$OUT/hdrcheck"
"$OUT/hdrcheck" "$OUT" "${2:-check}"
