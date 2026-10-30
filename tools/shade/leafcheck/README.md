# Leaves

Soft backlighting and a small, continuous wind deformation on the vanilla leaf sprites, including resource packs that replace those sprites. The existing **Lighting → Materials → Leaf light** control sets transmission; **Leaf wind** controls motion (0–200%, default 100%). Keep vanilla's cutout leaves enabled. This does not replace leaf textures/models or add grass blades; modded leaf sprites with different identifiers are left unchanged.

The atlas-upload callback refreshes sprite bounds. A 272-byte region at offset 2304 in the existing frame ring holds these bounds and wind parameters. Visible vertices, mesh culling and sun-shadow casters share the deformation. It fades from 32 to 64 blocks, keeping distant canopies and amortized far shadows static. Coarse culls retain a 0.1-block envelope around displaced geometry. No per-frame atlas allocation, additional draw pass or extra render target is introduced; the feature does add vertex and lighting work.

After `:metal:build`, run with JDK 25 and the Gradle cache used for the build:

```sh
python3 tools/shade/leafcheck/run.py /tmp/leafcheck
```

The native GPU checks exercise actual production vertex decoding for full, compact, quad-record and stub formats; verify colour/shadow/cull alignment, leaf atlas boundary identity, off/distance controls, section and hourly-clock continuity, bounded movement, finite lighting and shadow-gated transmission. Java fixtures cover live controls, persistence/reset and dimension guards. `tools/shade/own/check.sh` additionally specializes and links the production terrain and shadow variants.

In-game review: backlit oak/birch/spruce/cherry canopies at noon and sunset; close and distant leaves while panning; wind 0/100/200%; paused/resumed game; atlas reload; no movement on trunks, fences, doors, water or glass. Check for temporal smearing and frame-time changes in dense forest. Offscreen checks do not establish the final in-game appearance or frame rate.
