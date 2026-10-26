#!/bin/sh
# Copyright 2026 mcopt-shade contributors. Apache-2.0.
# Checks decoded labPBR mip invariants against the built Java classes (no game or GPU needed).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
OUT="$(mktemp -d "${TMPDIR:-/tmp}/pbrcheck.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
JH="${JAVA_HOME:-$ROOT/../../tools/jdk-25.0.4.1+1/Contents/Home}"
CP="$ROOT/metal/build/classes/java/main"
"$JH/bin/javac" -cp "$CP" -d "$OUT" "$HERE/PbrMipCheck.java"
"$JH/bin/java" -cp "$OUT:$CP" mcopt.metal.shade.PbrMipCheck
