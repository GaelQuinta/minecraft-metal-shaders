# Sunlight border regression

A fast camera turn exposed the previous viewport as a rectangular shadow in the
sky's crepuscular rays. `vl_march` added every ray tap to its weight denominator,
but added no transmittance for taps outside the previous sky mask. Missing
coverage therefore behaved like an opaque blocker. Temporal accumulation then
received an already incorrect lighting buffer.

The fix treats missing coverage as unoccluded, fades measured occlusion across
four VL texels at the live mask boundary, and rejects reprojections behind the
previous camera instead of falling back to unrelated current screen coordinates.
It keeps the same render passes, texture allocations, tap counts and temporal
accumulation. Real occlusion in the covered interior is unchanged.

Build with JDK 25 using `./gradlew :metal:build`, then run on a Mac with GPU access:

```sh
JAVA_HOME=/path/to/jdk25 GRADLE_USER_HOME="$PWD/.gradle-cache" \
MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 \
python3 tools/shade/vledgecheck/run.py /tmp/vledgecheck
```

The runner assembles `VlConfig.source()` and executes the actual HDR `vl_march`
fragment on Metal with production Java camera/lighting uniforms. It uses a
clear sky, no shadow casters and clouds off, matching the reported setup. An
unobstructed sky must not acquire any shadow when the previous camera changes.

The 180 clear-sky cases cover nine camera pairs (still, horizontal/vertical
turns, abrupt reverse turns, translation and an offscreen sun), five tap counts,
point/bilinear mask reads, and full/reduced previous live extents. Unused texture
space is deliberately black to catch dynamic-resolution padding reads. Controls
verify that a fully occluded sun still casts a shadow, an invalid projection
cannot reuse unrelated occluders, and reset/disabled paths stay clear.

An optional second argument is an assembled old `vl.metal` source to run the
same test against a baseline. The output directory contains half-float RGBA
lighting buffers, not in-game screenshots.

Results on Apple Metal, 2026-10-29:

- Original shader: 50/180 clear-sky cases pass; maximum false shadow 0.600098.
- Fixed shader: 180/180 pass; maximum false shadow 0.
- Covered occlusion control: maximum 0.600098 and centre -0.534180 before/after.
- Behind-camera projection: false shadow 0.600098 before, 0 after.
- Reset and disabled controls: 0 before/after.

These tests isolate the reported screen-boundary failure. They do not measure
whole-game frame time or replace checking motion in the user's world.
