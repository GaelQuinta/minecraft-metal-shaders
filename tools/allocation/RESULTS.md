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
