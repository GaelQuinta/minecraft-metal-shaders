# 1.2.7 regressions

Build with JDK 25 on an Apple Silicon Mac first.

```sh
./gradlew --no-daemon :metal:build
BASELINE_JAR=/absolute/path/to/metal-shaders-1.2.6-alpha.jar \
  python3 tools/shade/regression127/java-check.py
python3 tools/shade/regression127/run.py
```

`JAVA_HOME` must point to JDK 25. The Java runner uses locally cached JOML and Prism's LWJGL 3.4.3, like the other shader tools.
It checks all positions of the twelve affected percentage sliders in four presets, property values, file persistence,
reload, removal of default overrides, and the intentionally non-unit physical bases. It also checks invalid saved VL scales.

The sky fixture compares 1,024 sun/weather results with a baseline JAR, exercising reuse of one result across changing inputs.
It separately checks the optional opposite-sunset control and reports CPU time and allocated bytes. Timing this small routine
does not establish a game-wide FPS or GC improvement.

The GPU runner extracts **the production functions** from `shade_post.metal` and `vl.metal` and executes both on Metal.
Eight fixtures cover constant light/transmission, sky hidden by foreground texels, an outer same-depth observation, very close
geometry against sky, live texture subrects, valid negative haze corrections, and missing distant geometry. The original
1.2.6 shader fails the foreground-to-background borrowing assertion. Optional arguments: output directory and an alternate
directory holding the two shader source files, for checking the baseline.

These tiny fixtures demonstrate the depth reconstruction defect and its correction. They do not reproduce every Minecraft
scene, the specific M5 Pro video in #19, or the long-session native M5 crash in #16. Run the normal MSL/terrain checks and
`mcbench-run` game comparisons separately; don't collect performance timings while compiling or decoding recordings.
