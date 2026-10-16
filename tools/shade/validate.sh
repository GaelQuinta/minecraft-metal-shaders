#!/bin/sh
# Copyright 2026 mcopt-shade contributors. Licensed under the Apache License, Version 2.0.
#
# Validates every MSL variant native shading compiles at runtime, assembled exactly like MetalPipeline does (slot defines +
# "#define MCOPT_SHADE" + shade_common.metal + stage, for the plain and pulled terrain vertex stages, all three terrain
# fragments, the sky pipelines with two uniform orders, the sky LUT pass, the volumetric light passes, the TAAU passes), plus the upstream terrain MSL:
#   1. compile each with the Metal runtime compiler (MSL 3.0, fast math), like mc_library_new;
#   2. build a real MTLRenderPipelineState per vertex/fragment pair with mcopt's vertex layouts (catches stage interface
#      mismatches that compiling alone doesn't) and print the bound slots.
# Needs a built metal module (./gradlew :metal:build). Usage: tools/shade/validate.sh   (JAVA_HOME = a JDK 25)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
METAL="$HERE/../../metal"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/mcopt-shade-validate.XXXXXX")" # private: parallel runs (other worktrees) must not share it
JAVA_BIN="${JAVA_HOME:+$JAVA_HOME/bin/}"
rm -rf "$OUT" && mkdir -p "$OUT/classes"
clang -fobjc-arc -O1 -framework Foundation -framework Metal "$HERE/pipecheck.m" -o "$OUT/pipecheck"
clang -fobjc-arc -O1 -framework Foundation -framework Metal "$HERE/vlcheck.m" -o "$OUT/vlcheck"
clang -fobjc-arc -O1 -framework Foundation -framework Metal "$HERE/cloudcheck.m" -o "$OUT/cloudcheck"
CP="$METAL/build/classes/java/main:$METAL/src/main/resources:$(find ~/.gradle/caches -name 'jspecify-*.jar' | grep -v sources | head -1)"
"${JAVA_BIN}javac" -d "$OUT/classes" -cp "$CP" "$HERE/ShadeMslDump.java"
# VALIDATE_PROPS="-Dx=y ...": more switches for the dump (e.g. a startup-only shader variant under test)
"${JAVA_BIN}java" -Dmcopt.shade=true -Dmcopt.shade.glossy=true $VALIDATE_PROPS -cp "$OUT/classes:$CP" ShadeMslDump "$OUT/variants"  # opt-in features on: the widest variant
cp "$HERE"/gen_*.fs.metal "$OUT/"
cd "$OUT"
fail=0
for f in variants/*.metal; do
	./pipecheck compile "$f" >/dev/null || { echo "FAIL compile $f"; ./pipecheck compile "$f"; fail=1; }
done
# (v12, mcopt 0.3: no Sodium terrain variants when its sources are gone; own terrain is tools/shade/own/check.sh)
[ -f variants/shade_translucentnowater.vs.metal ] && { ./pipecheck sodium variants/shade_translucentnowater.vs.metal variants/shade_translucentnowater.fs.metal || fail=1; }
# Distant Horizons' LOD terrain: our vertex and fragment stages agree (FT2.8: the packed flat word)
for v in dh_terrain dh_terrain_jitter; do
	for fs in dh_terrain dh_terrain_water; do
		PIPECHECK_HDR= ./pipecheck auto "variants/$v.vs.metal" "variants/$fs.fs.metal" || fail=1
	done
done
[ -f variants/hdr_translucentnowater.vs.metal ] && { ./pipecheck sodium variants/hdr_translucentnowater.vs.metal variants/hdr_translucentnowater.fs.metal || fail=1; }
for k in solid cutout translucent; do
	for p in up shade hdr; do
		[ -f variants/${p}_$k.vs.metal ] || continue
		./pipecheck sodium variants/${p}_$k.vs.metal variants/${p}_$k.fs.metal || fail=1
		[ -f variants/${p}_$k.pulled.vs.metal ] && { ./pipecheck none variants/${p}_$k.pulled.vs.metal variants/${p}_$k.fs.metal || fail=1; }
	done
done
for i in 0 1; do ./pipecheck pos variants/sky$i.vs.metal variants/sky$i.fs.metal || fail=1; ./pipecheck pos variants/hdrsky$i.vs.metal variants/hdrsky$i.fs.metal || fail=1; done
# M3.3 (dims): the sky's lean variant and the reduced-resolution aurora pass (ShadeAurora, RGBA16F target)
for i in 0 1; do ./pipecheck pos variants/hdrsky$i.vs.metal variants/hdrskylean$i.fs.metal || fail=1; done
./pipecheck compile variants/aurora_pass.metal || fail=1
./pipecheck compile variants/stars.vs.metal || fail=1
# M3 End sky box (POSITION_TEX_COLOR), and the post library's XDR final pass (two color targets, mcxdr.m)
for i in 0 1; do ./pipecheck postexcolor variants/endsky$i.vs.metal variants/endsky$i.fs.metal || fail=1; ./pipecheck postexcolor variants/hdrendsky$i.vs.metal variants/hdrendsky$i.fs.metal || fail=1; done
./pipecheck mrt variants/post.metal variants/post.metal shade_fs_vs shade_final_xdr || fail=1
./pipecheck mrt variants/post.metal variants/post.metal shade_fs_vs shade_final_xdr_dims || fail=1
./pipecheck mrt variants/post.metal variants/post.metal shade_fs_vs shade_final_xdr_lean || fail=1 # (v12-opt) the lean final pass
for fn in shade_final_hdr shade_final_hdr_dims shade_final_hdr_lean; do
	PIPECHECK_FULL_HDR=1 ./pipecheck mrt variants/post.metal variants/post.metal shade_fs_vs "$fn" || fail=1
done
./pipecheck compile variants/post.metal || fail=1
./pipecheck compile "$METAL/src/main/resources/mcopt/shade/shadow.metal" || fail=1 # shadow pass + coloured-shadow tint pass
./pipecheck postex variants/celestial.vs.metal gen_position_tex.fs.metal || fail=1
./pipecheck poscolor variants/sunrise.vs.metal gen_position_color.fs.metal || fail=1
./pipecheck lut variants/sky_lut.metal variants/sky_lut.metal shade_lut_vs shade_lut_fs || fail=1
# the shadow pass (mcshadow.m): terrain casters and M3 entity casters
./pipecheck compile "$METAL/src/main/resources/mcopt/shade/shadow.metal" || fail=1
# volumetric light (mcvl.m): every pass, LDR and HDR composite, canopy kernel
./vlcheck variants/vl.metal || fail=1
# (v12-opt) volumetric clouds (mcclouds.m): every pass, the generic ones and the lean march and resolves (function constants)
./cloudcheck variants/clouds_passes.metal || fail=1
# dynamic lights (mcdynlight.m): the visibility kernel
./pipecheck compile variants/dynlight_vis.metal || fail=1
# clouds / weather against vanilla's generated stages, when a dump dir is given (MCOPT_GEN_DIR=<-Dmcopt.metal.dumpMsl dir>)
if [ -n "$MCOPT_GEN_DIR" ]; then
	./pipecheck none "$MCOPT_GEN_DIR/minecraft_pipeline_clouds.vs.metal" variants/clouds.fs.metal || fail=1
	./pipecheck none "$MCOPT_GEN_DIR/minecraft_pipeline_clouds.vs.metal" variants/hdrclouds.fs.metal || fail=1
	./pipecheck pos variants/stars.vs.metal "$MCOPT_GEN_DIR/minecraft_pipeline_stars.fs.metal" || fail=1
	[ -f variants/weather.fs.metal ] && { ./pipecheck compile variants/weather.fs.metal >/dev/null && echo "OK   variants/weather.fs.metal (compile)" || { ./pipecheck compile variants/weather.fs.metal; fail=1; }; }
	# M3 weather: HDR weather fragment, slanted weather vertex stages, the HDR lightning bolt
	for f in hdrweather.fs weather.vs hdrweather.vs lightning.fs hdrlightning.fs; do
		[ -f variants/$f.metal ] && { ./pipecheck compile variants/$f.metal >/dev/null && echo "OK   variants/$f.metal (compile)" || { ./pipecheck compile variants/$f.metal; fail=1; }; }
	done
	n=0; for f in variants/hdrgen/*.fs.metal; do
		./pipecheck compile "$f" >/dev/null || { echo "FAIL compile $f"; ./pipecheck compile "$f" | head -5; fail=1; }; n=$((n+1))
	done
	echo "OK   $n game fragments converted for the HDR target (ShadeMsl.hdrFragment) compile"
	# M3 entity lighting (ShadeEntity): patched vertex + fragment pairs as real pipelines into an RGBA16F target
	n=0; for v in variants/entity/*.vs.metal; do
		[ -f "$v" ] || continue
		PIPECHECK_HDR=1 ./pipecheck auto "$v" "${v%.vs.metal}.fs.metal" >/dev/null || { echo "FAIL entity $v"; PIPECHECK_HDR=1 ./pipecheck auto "$v" "${v%.vs.metal}.fs.metal" | head -8; fail=1; }; n=$((n+1))
	done
	echo "OK   $n entity / item / particle pipelines lit by shade (ShadeEntity) build"
	n=0; for f in variants/hdrgen/*.vs.metal; do
		[ -f "$f" ] || continue
		./pipecheck compile "$f" >/dev/null || { echo "FAIL compile $f"; ./pipecheck compile "$f" | head -5; fail=1; }; n=$((n+1))
	done
	echo "OK   $n game vertex stages with dynamic lights (DynLightMsl.patch) compile"
fi
# TAAU passes (mctaa.m + taa.metal): both TAA_HDR variants, real resolve + output pipelines
TMPDIR="$OUT" "$HERE/taatest/run.sh" compile || fail=1
echo "validate: $([ $fail = 0 ] && echo ALL OK || echo FAILURES) ($OUT)"
exit $fail
