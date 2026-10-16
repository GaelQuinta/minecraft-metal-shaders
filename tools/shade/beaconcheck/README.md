# Beacon brightness checks

Build with `./gradlew :metal:build`, then run `tools/shade/beaconcheck/run.sh [output-directory]` on a Mac with Metal access.
Uses JDK 25, Python 3, clang, the cached Minecraft 26.3 client, and Prism's LWJGL 3.4.3 libraries.
`JAVA_HOME`, `MC_JAR`, and `LWJGL_DIR` can override those locations.

The harness extracts the actual beacon fragment GLSL, compiles it through shaderc and SPIRV-Cross, then applies the production HDR adapter.
It checks both beam pipeline names and verifies unrelated pipelines and unrecognised shader shapes retain their fallback conversion.
144 GPU render cases cover 1x/4x/8x radiance, white/tinted/black textures, opaque/translucent alpha, normal alpha blending,
near/partial/full fog, and translucent fog. The added light must equal unfogged beam radiance times the extra intensity and fog transmittance.
Set `MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1` to check GPU API and shader usage too.

These are rendering regression checks, not an in-game visual assessment or performance benchmark.
