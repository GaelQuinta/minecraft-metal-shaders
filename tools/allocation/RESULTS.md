# Allocation results — 2026-10-20

Hardware: M4 Pro (20-core GPU), macOS 27.0.1, Java 25.0.1. Release base: `v1.2.5-alpha`. Candidate: `1.2.5-alpha-allocation-fix.1`. See [README.md](README.md) for the protocol, commands and correctness checks.

## Amplified-world comparison

Four fresh-world runs in release → candidate → candidate → release order. Same seed, fixed camera route, 12-chunk view distance and 4 GiB maximum heap. All runs retained focus and ended with 637 loaded client chunks. Each row covers the 30-second flight.

| Run | Allocation (MiB/s) | GC count | Total GC pause (ms) | Longest GC (ms) | Longest frame (ms) | Average FPS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| amplified-baseline | 386.4 | 62 | 178.1 | 14.95 | 18.11 | 119.6 |
| amplified-candidate | 321.2 | 52 | 149.9 | 13.50 | 15.85 | 119.4 |
| amplified-candidate-repeat | 323.9 | 50 | 142.0 | 10.73 | 13.52 | 119.4 |
| amplified-baseline-repeat | 394.5 | 65 | 167.2 | 11.05 | 14.04 | 119.4 |

Mean allocation fell from **390.4 to 322.6 MiB/s (17.4%)**. Mean collection count fell from **63.5 to 51 (19.7%)** per flight, and total GC pause time fell from **172.7 to 146.0 ms (15.5%)**. The stationary phases allocated 19.4–20.6 MiB/s in the release and 13.2–14.1 MiB/s in the candidate.

Frame throughput was effectively unchanged at the 120 FPS limit. No flight frame exceeded 20 ms in either version. The longest frames overlapped GC pauses, but the maximum varied between repetitions; these short tests do not establish a reliable improvement in worst-case frame time or prove that issue #14 is fully fixed.

## Allocation sources and checks

In the first amplified baseline, weighted JFR samples attributed approximately 70.5 MiB/s to the temporary IDs in `PalettedContainer.reencodeContents` and 13.7 MiB/s to `OwnQuads.Layer.order`. Both disappeared from the candidate’s sampled hot paths after buffer reuse. Sampled attribution is approximate; aggregate reductions above use thread allocation counters. New-world generation and other chunk work still account for substantial allocation.

The transformed in-game packing check measured 448 bytes per uniform block-section pack after warm-up, confirming that the recurring 16 KiB temporary ID array was removed. Packing round-trip/concurrency/nesting checks passed. All 14 mesh comparisons (seven sort modes, compact records on/off) matched the release byte-for-byte. The clean final build passed, and its non-directory entries matched the game-tested candidate; duplicated generated files were excluded by building in a fresh temporary output directory.

## Limits

The earlier normal-world baseline allocated 286.0 MiB/s during flight, compared with 386.4–394.5 MiB/s for amplified terrain. The earlier normal run began at the spawn position rather than the later fixed origin, so this is a workload observation, not an isolated measurement of the preset alone. Amplified terrain increases generation/meshing work; the section arrays themselves remain fixed-size.

The issue video showed roughly 1 GiB/s and much lower FPS. These disposable, small-window tests did not reproduce that severity. They used the mod and Fabric Loader, without the user’s other mods or existing worlds. Real saves, larger view distances, other mods, GPU load and different heap/collector settings can change the result. Heap rises and drops will continue: reducing temporary allocation does not eliminate garbage collection.

No Prism instance, world or JVM configuration was modified. ProMotion experiments remain on their existing checkpoint. This candidate contains only the allocation changes on top of release 1.2.5.

Final jar SHA-256: `a7ac62259a0c423a954acfadb83c833c4b904f5231c2297ea6cd203694309544`.

## Lithium compatibility correction — 2026-10-20

The first candidate failed with Lithium 0.26.2+mc26.3: Lithium replaces `PalettedContainer.pack`, removing the call targeted by our required `mcopt$packingIds` redirect. Fabric then rejects the class when joining a server or creating an integrated-server world. In the reported log, the multiplayer exception is presented as a network protocol error; the single-player crash has the same injection failure.

The allocation mixin now yields to Lithium, which already caches its packing scratch arrays. Explicitly setting `mcopt.alloc.palettePacking=true` does not bypass this compatibility guard. Other allocation changes remain enabled, and builds without Lithium still use our packing optimization. The original allocation percentages above were measured without Lithium; they are not a performance claim for the combined stack.

The new headless compatibility harness runs Fabric's actual client mixin transformation, verifies whether our redirect was applied, and exercises packing round trips, concurrent workers, nested calls and retained saved data. It exits before Minecraft opens a window. Results under `work/gc-investigation/lithium-compat`:

| Build / companion mods | Result |
| --- | --- |
| Original candidate + Lithium | Reproduced the exact required-redirect failure |
| Original candidate + Lithium, packing explicitly disabled | Passed; workaround confirmed |
| Corrected candidate alone | Passed; packing mixin active |
| Corrected candidate + Lithium | Passed; packing mixin skipped |
| Corrected candidate + C2ME + Fabric API | Passed; packing mixin active |
| Corrected candidate + Lithium + C2ME + Fabric API | Passed; packing mixin skipped |
| Corrected candidate alone, packing explicitly disabled | Passed; opt-out preserved |
| Corrected candidate + Lithium, packing explicitly enabled | Passed; compatibility guard preserved |
| Corrected candidate + 23 installed companion mod jars | Passed; packing mixin skipped |

C2ME was 0.4.2-alpha.0.90+26.3 and Fabric API was 0.162.0+26.3. Each run used a separate directory and `profile=none` with background class preloading disabled, to isolate transformation and packing without starting the renderer. Logs and manifests record exact jars and hashes. These checks reproduce and fix the shared class-loading failure; they are not live multiplayer login or single-player gameplay tests.

The corrected Java/native build passed. Comparing jar entries with the first candidate shows changes only to `AllocMixinPlugin.class` and the two version metadata files; mesh-sorting code and native rendering binaries are identical. No existing worlds, Prism configuration or installed mods were modified.

Test jar: `metal-1.2.5-alpha-allocation-fix.2.jar`. SHA-256: `cb59107f21807dd1b3bce862a27708b376e10f899151ad1aeb8cbf9fce09c31f`. The PR retains the release version in its build file; the distinct test version is applied by the local build configuration.
