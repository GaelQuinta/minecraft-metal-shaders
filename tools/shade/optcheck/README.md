# Bloom checks

Build `:metal:build` with JDK 25, then run from the repository root:

```sh
JAVA_HOME=/path/to/jdk-25 GRADLE_USER_HOME="$PWD/.gradle-cache" \
  MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 \
  python3 tools/shade/optcheck/run.py /tmp/metal-optcheck
```

No game or window is launched. The native tests call `mc_shade_pass` in the built dylib, using production-assembled MSL.

- `PassAbiCheck.java`: exercises the actual Java FFM wrapper against the packaged native library for each binding mode.
- `passcheck.m`: full versus scoped global bindings must produce identical pixels for all three bloom passes, including odd sizes and extreme HDR inputs. The first downsample must still set `ShadeGpu.xdrHot`.
- `bloomcheck.m`: compares the normalized four-fetch pyramid to the frozen nine-fetch reference over three octave spectra, odd/even sizes, moving spots, checkerboards and waves. SDR error must stay below one 8-bit display step; HDR error below 0.02 relative to SDR white. The 30000-radiance stress cases only require the new pyramid to remain finite, since the old unnormalized accumulation overflows. `bloom.png` and `halation.png` are synthetic rendered previews, not Minecraft screenshots.
- Halation contracts check no added colour on uniform fields, highlight cores, dim surfaces or purely blue emission, a red/amber fringe on bright boundaries, and exact disabling at zero. Java checks that its strength follows the existing Bloom control.

Timings from validation runs are not GPU performance measurements. The CPU fixture's timings and allocation counts describe the fixture only; they are not frame-time or FPS claims. The retained main-thread allocations include the fixture's chunk wrappers.
