# Allocation investigation for issue #14

Based on `v1.2.5-alpha` (`a5b5a98ef6b1ea47b0e713b8bd3ae687f8d473e7`).

[Issue #14](https://github.com/GaelQuinta/minecraft-metal-shaders/issues/14) shows roughly 1 GiB/s of Java allocation during flight, with large drops in used heap. Those drops are consistent with garbage collection; the video alone does not establish a leak or the duration of a collection pause.

## Changes

- `PalettedContainer.pack` reuses worker-local temporary IDs instead of allocating an `int[4096]` for every block section and an `int[64]` for biomes. Vanilla still controls its locking, palette order, saved longs and returned stream. The scratch scope lasts until packing returns, is released in `finally`, and separates recursive calls. It retains at most four buffers of each standard size per thread (about 65 KiB); unusual sizes/deeper recursion use temporary arrays. `-Dmcopt.alloc.palettePacking=false` disables this mixin for comparison or compatibility diagnosis.
- The mod's mesh sorter reuses its temporary metadata arrays across buckets and section rebuilds, retaining only the largest bucket's workspace per existing worker-local layer. Finished runs and mesh data keep independent storage. Compact quad record sorting shares the existing native vertex scratch buffer rather than allocating/freeing another buffer per bucket.

When Lithium is installed, the palette-packing mixin automatically steps aside, including when `mcopt.alloc.palettePacking=true` is explicitly set. Lithium replaces `pack` and already reuses temporary IDs; applying our redirect to that replacement caused class loading to fail during server login and single-player world creation. The mesh-sorting changes remain active. On an older build, `-Dmcopt.alloc.palettePacking=false` avoids this conflict. The allocation measurements below were taken without Lithium and do not establish the same benefit with it installed.

No renderer, lighting, world format, collector selection, heap size or view-distance behavior is changed.

## Profiling

Requires Java 25 and cached Prism Launcher dependencies for Minecraft 26.3, Fabric Loader 0.19.5 and LWJGL 3.4.3. Build the mod first. Each run uses a fresh offline temporary directory/world and never edits a Prism instance. Keep its small window focused until it closes.

```sh
python3 tools/allocation/profile.py /path/to/mod.jar \
  --java-home "$JAVA_HOME" --output /tmp/profile-baseline --amplified

python3 tools/allocation/profile.py /path/to/candidate.jar \
  --java-home "$JAVA_HOME" --output /tmp/profile-candidate --amplified --verify

python3 tools/allocation/analyze.py /tmp/profile-baseline --java-home "$JAVA_HOME"
python3 tools/allocation/analyze.py /tmp/profile-candidate --java-home "$JAVA_HOME"
```

Omit `--amplified` for a normal world. `--prepare-only` compiles the helper without opening Minecraft. `--verify` is for the candidate; it checks palette results and confirms the mixin is active before measurements start.

Protocol: fixed seed 1234, fixed route from `(0,160,0)` toward positive Z, spectator flight at 25 blocks/s, 12 render chunks, 5 simulation chunks, 120 FPS limit, VSync, windowed 640×400 logical size, full-scene HDR, 4 GiB maximum heap. After loading/settling, record 20 seconds stationary and 30 seconds flying. Timeout after 330 seconds. Focus loss fails the run.

Outputs include a jar hash/launch manifest, game and GC logs, per-phase JFR recordings, thread allocation counters, frame timestamps, and analysis JSON. Allocation totals use thread counters, not sampled weights; threads that terminate before the final snapshot are not included. JFR stacks locate allocation sources. The first allocation sample from each thread is discarded because its weight can include allocations preceding the recording. Frame/GC overlap uses a measured wall-clock/monotonic-clock anchor; it establishes temporal overlap, not exclusive causation.

The profiler contains no production code and is not included in the delivered jar.

## Correctness checks

```sh
python3 tools/allocation/check.py \
  --baseline /path/to/release.jar --candidate /path/to/candidate.jar \
  --manifest /tmp/profile-baseline/manifest.json \
  --java-home "$JAVA_HOME" --output /tmp/allocation-checks
```

Packing checks compare IDs and palette encounter order against Minecraft's unchanged reencoder, cover zero-bit/nonzero/global palettes, block/biome/unusual sizes, four concurrent workers, nested calls beyond the retention limit, and delayed consumption of saved data after scratch reuse. The in-game check also exercises the transformed `pack` method and round-trips actual saved sections.

Mesh checks compare SHA-256 digests against the release jar for all seven ordering modes, with and without compact quad records. Fixtures repeatedly grow, shrink, empty and refill all facing buckets; digests include vertices, records, planes, bounds, materials, classes and draw runs.

The compatibility check uses Fabric's real client mixin loader and the supplied mod jars, then exits before opening a game window. It verifies that the packing redirect is present without Lithium (unless explicitly disabled), absent with Lithium, and runs the packing correctness checks against the transformed classes. `--mod` can be repeated to include C2ME and its dependencies. Each run uses a separate disposable game directory; it does not connect to servers or open existing worlds.

```sh
python3 tools/allocation/compat-check.py /path/to/candidate.jar \
  --manifest /tmp/profile-baseline/manifest.json --java-home "$JAVA_HOME" \
  --mod /path/to/lithium.jar --output /tmp/palette-lithium-check
```

Omit `--mod` for the vanilla-packing path. `--palette-packing false` checks the opt-out; `--palette-packing true` checks that explicit enablement still respects the Lithium guard. `--expect-conflict` verifies that an older candidate reproduces the original `mcopt$packingIds` injection failure, rather than accepting an unrelated startup error as a successful reproduction.

See `RESULTS.md` for the measured results and limitations.
