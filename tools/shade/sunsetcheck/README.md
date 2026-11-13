# Sunset colour regression

Runs the production Java atmosphere and look uniforms, Metal atmosphere, final sky LUT, SDR/HDR display transforms and diffuse lighting without launching Minecraft. Requires a built `:metal:build`, JDK 25, cached Gradle dependencies, and access to a Metal GPU.

```sh
export JAVA_HOME='/path/to/jdk-25/Contents/Home'
export GRADLE_USER_HOME="$PWD/.gradle-cache"
MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 \
  python3 tools/shade/sunsetcheck/run.py /tmp/sunset-after
```

Set `BASELINE_JAR` to test an older build; the affected 1.2.6 build should fail the green-band assertions. Then pass that output directory as a second argument when testing the new build:

```sh
BASELINE_JAR=/path/to/old-metal.jar \
  python3 tools/shade/sunsetcheck/run.py /tmp/sunset-before
python3 tools/shade/sunsetcheck/run.py /tmp/sunset-after /tmp/sunset-before
```

The sweep covers 4,186 sky directions at 13 sun elevations in each of three presets, for evening, morning, rain and the optional legacy sky. Each GPU sample contains six float4 values: raw atmosphere, SDR atmosphere, HDR atmosphere, a neutral diffuse surface, SDR final LUT, HDR final LUT. The old JAR adapter exposes the original LUT fragment body as a callable helper without changing its grading arithmetic. Current builds use the same helper as the actual LUT fragment.

Assertions check finite nonnegative output, CPU/GPU agreement, and a maximum green excess of 2% for the sun at 0–25° in the current sky. Green excess is `max(G / max(R, B) - 1, 0)` in linear output; this is a diagnostic for sky colours, not a general material-saturation metric. The legacy sky is checked for validity and CPU/GPU parity, not the new colour constraint. With a baseline, the test also checks atmosphere luminance preservation, unchanged noon/night output within floating-point tolerance, and no increase in blue dominance on neutral evening surfaces. A warmer surface becoming less orange does not count as blue dominance.

These are synthetic GPU measurements, not in-game biome screenshots. The diffuse samples sweep normal direction and shadow visibility; they do not include textures, screen-space bounce, bloom, exposure history or the display's HDR calibration. Twilight below the horizon is checked for valid output and parity, but is outside the 0–25° hue assertion.


This branch also includes the earlier daylight fill, earthy ground bounce, restrained saturation/vibrance and tint calibration. Baseline comparisons that require unchanged noon output should only be used for a sunset-only patch. The standalone sweep validates this broader palette change.
