# Fantasy profile

The `fantasy` profile combines the existing Fantasy lighting style with the optional painterly HDR post filter. It is intended for Apple Silicon Macs running Metal Shaders; it is not a generic Iris shader-pack preset.

## Enable it

In `<game directory>/config/mcopt.properties`, set:

```properties
profile=fantasy
```

Restart Minecraft. The profile keeps mcopt's own terrain renderer enabled, enables Metal Shaders, selects the Fantasy look and balanced quality, chooses turquoise water, and sets a restrained painterly finish. Explicit `mcopt.*` values in this config file and JVM `-Dmcopt.*` options override profile defaults.

The painterly pass is enabled at 35% by this profile. Set `mcopt.shade.fantasy.painterly=0` to disable it; with strength zero, the tensor and Kuwahara passes are not encoded. You can also adjust the settings live from **Pause → Shaders... → Fantasy**.

## What the look uses

- Softened direct-light terminators and violet-blue shadow fill, with warmer, stronger daytime sun.
- Broader block-light falloff; the existing coloured-light system remains active.
- Lower valley mist, using the shader's height-aware atmosphere.
- The existing HDR bloom and filmic tone curve.
- An optional structure-tensor pass and oriented 8-sector Kuwahara filter after temporal resolve and before bloom/tonemapping, with a distance-scaled brush and subtle grain.
- The existing layered wave water/reflection renderer, with the profile choosing a turquoise palette.

Foliage backlighting and volumetric cloud scattering remain provided by the renderer's existing foliage and cloud systems; this profile does not add a new foliage vertex format or replace the cloud marcher.

## Tuning

The profile values can be overridden in `config/mcopt.properties`:

| Setting | Default | Effect |
|---|---:|---|
| `mcopt.shade.fantasy.painterly` | `0.35` | Brush strength, 0–1; zero skips both passes |
| `mcopt.shade.fantasy.brush` | `3.0` | Brush radius in output pixels, 2–5 |
| `mcopt.shade.fantasy.grain` | `0.35` | Paper-grain mix, 0–1 |
| `mcopt.shade.fantasy.softness` | `0.85` | Soft terminator strength, 0–1 |
| `mcopt.shade.fantasy.shadowTint` | `0.55` | Cool shaded-side fill, 0–1 |
| `mcopt.shade.fantasy.blockLight` | `0.5` | Broader torch-light falloff, 0–1 |
| `mcopt.shade.fantasy.mist` | `1.0` | Valley mist strength, 0–2 |

For a lighter GPU load, turn the painterly setting off or choose the `performance` shader quality preset. The painterly filter is an optional additional cost when enabled.
