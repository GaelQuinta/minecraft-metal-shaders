# Full-scene HDR

Enable **Shaders → Colour and camera → HDR display → HDR mode → Full scene**.
Keep **HDR output** on Automatic (default) or On; changing that master output
setting requires restarting. Mode and brightness controls update live after
returning to the world. The default remains Highlights for compatibility.

Equivalent `config/mcopt.properties` settings:

```properties
mcopt.shade.xdr=auto
mcopt.shade.hdrMode=scene
mcopt.shade.hdrSceneBrightness=1.0
mcopt.shade.hdrUiBrightness=1.0
mcopt.shade.xdrPeak=4
```

`hdrSceneBrightness` is a pre-tone-map exposure multiplier (0.5–2).
`hdrUiBrightness` scales the HUD and held item (0.25–2). The HDR peak is a cap in
multiples of SDR white, limited by the display's live headroom, not a promise of
an absolute brightness in nits. The existing `shade`, `hdr` and `skydims` master
settings must be enabled. An SDR screen or no available headroom uses SDR output.

## Rendering

The source world already contains linear pre-exposed HDR lighting. Full-scene
mode applies a continuous Lottes curve to that image, using the existing grade
matrices and contrast. Its middle-gray anchor remains 0.18 → 0.20. The scene white
anchor moves to `12 * sqrt(headroom)` and maps to the available peak. Scene
brightness changes exposure before this transform. After grading, a common RGB
scale bounds the peak without independently clipping channels. The legacy SDR
curve and inverse remain unchanged, including the vanilla/Distant Horizons bridge.

The final pass writes a complete display-linear RGBA16F world image alongside
an SDR compatibility image. Unlike Highlights, there is no brightness threshold
or empty-highlight skip. The complete HDR image is presented through the existing
extended-linear Display P3 Metal layer. The present queue still uses its existing
RGB9E5 staging format; direct presentation preserves the existing matching option.

Before hand/HUD rendering, the SDR compatibility image is copied at window size.
At presentation, this reference and main's alpha recover the aggregate overlaid
SDR colour in the game's sRGB blend space; the result is converted to linear light
and composited over the HDR world. Uncovered world pixels bypass SDR quantization.
Opaque UI covers the world completely. Alpha-zero colour edits retain their
linear difference (e.g. additive overlays). HDR data and reference validity are
limited to the same command buffer; stale, skipped or invalid frames use SDR.
Reduced output sizes are sampled by UV; the reference is captured after upscaling.

This preserves compatibility with existing hand/HUD drawing without rerendering
them. It assumes ordinary source-over alpha coverage for translucent overlays;
unusual mod blend operations may need dedicated handling. The hand stays SDR.
Pause/inventory and other screens with background effects use SDR, matching the
existing safe menu behavior; chat keeps HDR. F2 screenshots and existing recordings
use the SDR compatibility image. Full HDR menu blur, HDR capture and HDR hand
lighting are separate follow-up work. Third-party terrain converted from SDR
cannot recover lighting information it never supplied.

## GPU checks

Build first, then run on Apple Silicon with Python-free native/Java tools:

```sh
./gradlew :metal:build
tools/shade/validate.sh
MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 tools/shade/hdrcheck/run.sh /tmp/hdr-check
```

The harness uses the production Java curve solver, the production assembled Metal
shader, and the native presenter source. It checks 90 combinations of contrast,
headroom and scene brightness: middle-gray anchor, monotonic gradients, finite
colours, saturated input and peak bounds. Native GPU tests cover opaque and
translucent HUD, UI brightness, resize, reduced output sizes, orientation, queued
and direct output, switching to Highlights/SDR, and stale/skipped frames. This is
headless validation, not in-game visual approval on every screen or shader preset.

For a reproducible synthetic GPU cost comparison, **without Metal validation**:

```sh
tools/shade/hdrcheck/run.sh /tmp/hdr-cost perf
```

The benchmark runs the production lean final shaders and native compositor at
3840×2160, including the full mode's SDR reference copy. It uses alternating
patterned HDR inputs, peak 4, scene/UI brightness 1, sharpening 0.3, and disables
haze, volumetrics and bloom to isolate the affected stages. Eight paired runs
alternate mode order. Each run discards 128 warmup frames and measures 384 frames
in 24 non-overlapping GPU command buffers of 16 frames. GPU timestamps exclude
CPU submission gaps. `samples.csv` contains all measured batches; `BENCH` lines
report each run mean. It excludes world rendering, UI draws, the final staging
copy to the drawable and window-system presentation; it is not whole-game FPS.

Initial Apple M4 Pro result: median run means 0.915 ms (Highlights) and 1.226 ms
(Full scene), with an average paired increase of 0.314 ms. Timing depends on GPU
clocks, thermals and scene content. Use in-game frame timings to measure the full
impact. At equal 4K output/window sizes the additional reference and larger HDR
image consume approximately 63 MiB versus the highlight-only images, excluding
in-flight resources during resizing or mode switches.
