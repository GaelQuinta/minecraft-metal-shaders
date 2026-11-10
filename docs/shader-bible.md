# The Shader Bible: an original, Metal-native design for mcopt-shade (M2–M4, plus M1 polish)

Report name: `shader-bible`. This is a design document. It reproduces no shaderpack code, launched nothing, and ran no GPU work.
I read the M1 worktrees (`work/wt/m1-shade`, `work/wt/m1-shadow`) **read-only** so this spec extends their data contract instead
of fighting it.

**Who this is for.** The implementation agents for M2, M3 and M4, and whoever polishes M1. Every effect follows one template:
1. **Look**: the target, and which studied pack does it best and why.
2. **Technique**: original, or "adapt from \<permissive file\> with attribution".
3. **Algorithm**: equations, sample counts, resolutions, temporal reuse.
4. **Hook**: where it plugs in.
5. **Cost & tiers**.
6. **Data & deps**.

**Sources digested:**
- `critique.md` (§5 milestones, §6 architecture);
- `apple-gpu.md` (measured M4 costs);
- `mcopt-architecture.md` and `mc-renderer.md` (hooks, data);
- the four pack studies (`packs/complementary.md`, `seus.md`, `bsl.md`, `photon-and-permissive.md`);
- the M1 shared header `shade_common.metal` and the shadow receiver header `shade_shadow.metal`.

**Conventions used throughout**

| Term | Meaning |
|---|---|
| Output | 3024×1964 (5.94 MP), Apple M4 10-core GPU, 120 Hz panel |
| Internal | the jittered render resolution: s·output. **0.67x = 2016×1309 (2.64 MP)**, 0.75x = 2268×1473 (3.34 MP), 0.5x = 1512×982 (1.48 MP) |
| P / B / Q / U | Performance / Balanced / Quality / Ultra tier (§5) |
| (meas.) | measured on this M4 in `apple-gpu.md`; everything else is an estimate |
| World space | **camera-relative** world space, +y up (M1 convention). Absolute = `cameraBlock + cameraFract + P` |
| Depth | **reversed-Z**, 1 = near, 0 = far/sky, cleared to 0, `GreaterEqual` |
| Texture rows | GL order (row 0 = bottom). Full-screen passes: `uv = (px+0.5)/size`, `ndc = uv*2-1`, no flip |
| Colour | linear Rec.709 primaries, **pre-exposed** in every HDR target (§1.5) |
| Hooks H1–H14 | defined in §1.2 |

---

## 0. The decisions (read this if nothing else)

1. **Identity of the look: "physically lit, art-directed".**
   - **The physical core** follows Photon/SEUS: one atmosphere model feeds the sky, sun colour, ambient light, fog,
     clouds and reflections.
   - **An art layer** (`ShadeLook`, computed on the CPU each frame) adds the warmth, readability and time-of-day
     storytelling that make Complementary and BSL beloved.
   - We ship **three look presets on one engine**:
     - **Epic** (default; cinematic, Unbound/SEUS-like);
     - **Storybook** (Reimagined/BSL-like: blocky soft clouds, pixel-snapped water, punchier palette);
     - **Natural** (Photon/SEUS-like restraint).
   - The names are ours; we never use any pack's name in the product.
2. **HDR everywhere after M2.** The world renders into a **pre-exposed linear RGBA16F** target at internal resolution.
   Every post pass is a **fragment pass into a compressible (private, no ShaderWrite) target**, because apple-gpu §0.2
   measured that as 2–3× cheaper than compute.
3. **Tonemapper: "Shade Filmic", our own AgX-structured, Lottes-parameterised curve** (§E21). It has three parts:
   - a luminance-preserving inset matrix, which gives path-to-white and hue stability;
   - a per-channel Lottes-2016 curve anchored at mid-grey, whose white point = SDR 1.0 or the **XDR headroom**;
   - a partial outset.

   ACES is rejected because of hue skew, crushed darks and poor EDR adaptability. Stock AgX is rejected as a
   *parameter set* (flat look, fixed log range), but its *structure* is kept.
4. **Exposure** = pre-balanced lighting (the Complementary/Photon philosophy) **plus** a bounded, partial auto-exposure:
   ±1.75 EV around a time-of-day reference, with adaptation factor λ = 0.55 so night stays darker than day.
5. **Sky** = the Hillaire 2020 LUT set: transmittance, multi-scatter, sky-view, aerial-perspective froxels. It replaces
   M1's 8-step analytic integral and M1's `horizon[8]` table, which breaks once the sun path is tilted.
6. **Temporal upscaling** = **our own single-pass fragment TAAU** (0.62–0.72 ms meas.), with **dynamic resolution
   through a viewport sub-rect**. MetalFX temporal is only an Ultra option (4.5–6 ms marginal, meas.). The default
   floor is 0.67x, and the transient floor is 0.6x.
7. **Material data without touching Sodium's vertex format:** two **baked atlases** built at atlas stitch time.
   - A class mask (R8Uint).
   - A parameter atlas (RGBA8) in **labPBR 1.3 "_s" encoding**, filled by our own albedo heuristics. That makes
     labPBR resource packs a drop-in replacement.

   Runtime cost: one fetch.
8. **Shadows** keep M1's 2 cached cascades and add, in order:
   - PCSS-lite with contact sharpening and sky-light leak gating (M1 polish/M2);
   - coloured translucent shadows and caustics, then entity shadows (M3);
   - inline hardware RT (M4).
9. **Clouds**: two styles.
   - **Epic/Natural:** a Nubis-style volumetric cumulus layer (public SIGGRAPH talks) with a weather map,
     multi-scatter octaves and our own ½×½ checkerboard reprojection.
   - **Storybook:** **SDF-voxel clouds** sphere-traced from the game's own cloud texture.
10. **Code adaptation** is allowed only from:
    - Photon @ `26c2906e` (MIT, minus the exclusions in §8);
    - Spectrum (MIT);
    - SE Natural Bloom & Dirty Lens and SEGI (MIT);
    - MJP's Catmull-Rom gist (MIT);
    - AMD FidelityFX (MIT; verify the LICENSE before use).

    Complementary, BSL, SEUS Renewed/PTGI and post-2025 Photon are **technique-only**. Every number in this document
    that looks like a pack constant is either our own value or a public physical constant.

---

## 1. Pipeline architecture

### 1.1 What exists after M1 (do not break)

- `ShadeFrame`: a 1008-byte UBO at `buffer(16)` for both stages, packed by `ShadeFrame.java`. The layout is fixed and is
  quoted in §2.1.
- The shadow map at `texture(16)`: a `depth2d_array<float>` with 2 cascades, reversed-Z, cleared to 0.
- `sampler(12)`: a linear compare sampler, `GreaterEqual`.
- The receiver helpers in `shade_shadow.metal`:
  - `shade_shadow_uv`;
  - `shade_shadow_pcf` (4 taps, a 3×3 tent);
  - `shade_shadow_offset` (normal offset);
  - `shade_shadow` (cascade blend).
- `ShadowConfig`:
  - `mcopt.shade.shadowRes` 2048;
  - `shadowDist` 128 (the far half-width);
  - `shadowNear` = dist/4, pushed 40% ahead of the camera;
  - `shadowFarEvery` 4;
  - `shadowCull` `camera` (default) or `light`;
  - `shadowFaces` `sun`.
- Lit Sodium terrain (forward, LDR RGBA8), the sky pipeline overrides, the face-shade-off mixin and
  `MetalShaderRegistry`.
- M1 tonemaps **inside** each shaded pipeline (`shadeOutput`). M2 moves the tonemap to one final pass. Shaded pipelines
  then write pre-exposed HDR.

### 1.2 Hook catalogue (all M1–M4 effects plug into these)

| Hook | Where (mcopt / decomp) | Used for |
|---|---|---|
| **H1** frame setup | `LevelRenderer.render` HEAD mixin (pattern `LodLevelRendererMixin`). CPU packs `ShadeFrame` + `ShadeLook`; GPU work goes on a compute encoder from `mc_frame_cmd(enc)` | LUTs, SH, cloud maps, canopy probe, LPV flood fill, generated-asset (re)builds |
| **H2** shadow pass | M1 `ShadowLevelRendererMixin`, its own encoder before "Main"/"Solid" | cascades, translucent colour/depth (M3), entity shadow map (M3) |
| **H3** sky override | registry MSL for `minecraft:pipeline/sky`, `sunrise_sunset`, `stars`, `celestial`, `end_sky` | atmosphere, sun/moon, stars, Milky Way, aurora, End sky |
| **H4** lit terrain | `sodium_terrain.{vs,fs}.metal` (plain + pulled stay identical) | lighting model, waving, SSS, fog/AP, material fetch |
| **H5** HDR redirect | `MetalHooks.Redirect` for "Sky"+"Main"; PSO **format variants** (critique §6.3) | RGBA16F world target at internal res; M3: TBDR attachments + `PassDelegate` |
| **H6** translucent switch | `MetalRenderPass.setPipeline` → `sodium:pipeline/translucent_terrain`; `mc_render_suspend`/`resume` | scene/depth copy, hi-Z, cloud march + reconstruction, cloud composite, water/glass |
| **H7** pre-hand post | wrap `GameRenderer.render3dHud` (pattern `GameRendererFrameGenMixin`) | world-depth capture, GTAO, VL, atmosphere composite, canopy factor |
| **H8** pre-GUI post | `FogRenderer.endFrame()` (the MetalFx hook; restores the real main target) | exposure histogram, TAAU, bloom, final grade/tonemap → main (SDR) or the EDR image |
| **H9** GUI / present | `GuiRendererFrameGenMixin` (draws the GUI over black and over white), `mc_layer_configure`, `mc_present` | XDR composite and present |
| **H10** pipeline overrides | `MetalShaderRegistry` MSL for entities, items, particles, weather, block models, screen effects, world border, vanilla clouds (off) | entity/hand lighting, reactive mask, lit particles and rain |
| **H11** atlas/model reload | after `ModelManager` reload / block atlas stitch | material class mask, parameter atlas, labPBR atlases, sprite tables |
| **H12** Sodium mixins | `CardinalLighting.byFace` (M1); the AO→vertex-alpha mixin (M2) | separated AO |
| **H13** settings | Sodium options page (borrow PR #10's `MetalOptions`), `config/mcopt.properties` | presets, live toggles |
| **H14** far terrain | `columns.metal` lighting; `lod_*_gbuffer` in M3 | consistent sun, sky and fog on mcopt LOD |

### 1.3 Frame graph, M2 (forward HDR)

```
FRAME N  (internal = s × output; s in [0.6, 1.0] from dynamic resolution)
H1  CPU: ShadeFrame (M1) + ShadeLook (§2.2) + weather/biome/eye smoothing; DRS controller picks s
    GPU compute (mc_frame_cmd):
      [on change] transmittance LUT 256×64, multi-scatter LUT 32×32
      sky-view LUT 192×108 → env map 128×64 (atmosphere + low-step clouds + Milky Way average) → SH9 (1 threadgroup)
      aerial-perspective froxel LUT 32×32×32 → [weather change] cloud weather map 512²
      cloud shadow map 512² (every 2nd frame) → canopy probe (1 threadgroup) → exposure finalize (1 thread)
H2  shadow cascades (M1): near every frame, far cached
--  vanilla "Update light" (lightmap): unchanged; we keep using it as the vanilla light-level response
H5  "Sky"+"Main" → sceneHDR RGBA16F (internal), sceneDepth D32F
H3    sky pass: skyView + sun/moon/halo + stars/Milky Way/aurora (sky pixels only)
H4    Sodium solid → cutout (lit, AO, SSS, waving, fog/AP inline); far LOD (H14); entities/block entities/particles (H10)
H6  switch to translucent terrain:
      suspend → blit sceneHDR→sceneCopy, sceneDepth→depthCopy → hi-Z max pyramid (5 mips, R16F linear)
      → cloud march (½×½ internal, checkerboard) → cloud reconstruction (½×½ history) → resume
      → full-screen cloud composite (by cloud distance vs depth; AP applied at cloud distance)
      → water/glass/ice forward (waves, Fresnel, SSR from last frame's TAAU output, refraction from sceneCopy,
        absorption, caustics, foam; writes tint/reactive side images) → weather, border, translucent entities/particles
H7  render3dHud HEAD: copy world depth → GTAO ½ (from depthCopy) → VL ½ (+temporal) → atmosphere composite into sceneHDR
--  vanilla: hand (lit override), screen effects (reactive)
H8  FogRenderer.endFrame: bloom L0 from sceneHDR (Karis-averaged 13-tap) → bloom down chain → exposure histogram (on L2)
      → TAAU (internal → output RGBA16F history) → bloom up chain
      → FINAL (bloom lerp + fog glow + Purkinje + vignette + Shade Filmic + grade + flare sprites + RCAS + dither)
      → main RGBA8 (SDR) | edrImage RGBA16F (XDR)
H9  GUI at native (XDR: GUI drawn over black and white, composited) → present
```

### 1.4 Frame graph, M3 (tile-deferred) and M4 (RT)

The single change is H5. "Main" becomes one TBDR render pass, through `MetalHooks.setRedirector` + `PassDelegate`, with
these attachments (apple-gpu §2.1 recipe; layout modelled on `columns.metal:1336-1375`):

| Att. | Format | Storage | Content |
|---|---|---|---|
| color0 | RGBA16F | **store** | lit HDR (pre-exposed); a = 1 |
| color1 | RGBA8 | memoryless | albedo.rgb (sRGB-encoded), a = material class / 255 |
| color2 | RGBA8 | memoryless | octahedral normal (2×8), block light, sky light (8-bit, IGN-dithered) |
| color3 | RGBA8 | memoryless | labPBR params (smoothness, f0/metal, porosity/SSS, emission) |
| color4 | RG16F | **store** | motion (Δuv to the previous frame; 0 for static terrain, which TAAU recomputes from depth) |
| color5 | R32F | memoryless | linear view distance (fragment shaders cannot read the depth attachment) |
| depth | D32F | **store** | needed by TAAU, SSR, clouds and VL |

Draw order: solid (no discard) → cutout → entities → **one full-screen lighting triangle** that reads `[[color(1..5)]]`
and writes color0. The lighting runs the exact same function as M2's forward path, so M2 and M3 must share
`shade_light.metal`.

- **M4** adds an inline any-hit sun ray in that lighting draw (TLAS through `useHeap`, fragment stage). It also adds RT
  water/glossy reflection rays and RTAO/GI on Ultra.
- In M3/M4 the H6 suspend is no longer extra: the TBDR pass ends naturally, and the translucent pass is a new encoder
  that loads color0 and depth.

### 1.5 Global conventions every shader follows

- **Pre-exposure.**
  - Every shaded output is multiplied by `ShadeGpu.exposure.x` (last frame's adapted exposure) before writing.
  - TAAU rescales its history by `exposure.x / exposure.z` (now/previous).
  - Reason: night scenes stay out of `half` denormals (the minimum normal is 6.1e-5), and bright skies stay below 65504.
- **Precision.** Use `half` for colours, normals, BRDF and fog terms. Use `float` for positions, depths, distances,
  matrices, noise coordinates and anything accumulated over more than 64 steps.
- **Noise.**
  - Spatial blue noise: a 128² 4-channel CC0 texture (Christoph Peters, §8), or the interleaved-gradient noise (IGN,
    Jimenez 2014), `IGN(p) = fract(52.9829189·fract(0.06711056·x + 0.00583715·y))`.
  - Temporal decorrelation: the R1 sequence `frame·0.6180339887`.
  - Rotations: R2 (`0.7548776662, 0.5698402910`).
  - Every stochastic loop dithers its start offset; TAAU and the per-effect histories resolve the noise.
- **Function constants, not `#define`s,** for tiers and features (`[[function_constant(n)]]`). Specialisation is
  near-instant, and variants are pre-warmed at resource reload (critique M2.1).
- **Constexpr samplers** in MSL (`constexpr sampler s(filter::linear, address::repeat, mip_filter::linear)`) avoid the
  sampler-slot shortage. Only the compare sampler (`sampler(12)`, M1) is bound.
- **Side images** (reactive mask, translucent tint) are written from fragment shaders through `texture2d<…,
  access::read_write>` with `[[raster_order_group(0)]]`. They are our own small textures created with ShaderWrite. The
  bandwidth penalty is irrelevant at 1–4 B/px written only by the pixels that need them.
- **Sky test:** `depth == 0.0`. Linear distance: from `invViewProj`, or from color5 in M3.

### 1.6 Render targets (at 0.67x internal; allocated at the preset's **maximum** scale for DRS)

| Name | Format | Resolution | Usage / compression | Lifetime | MB |
|---|---|---|---|---|---|
| sceneHDR | RGBA16F | internal | RT\|SR, compressible | frame | 21 |
| sceneDepth | D32F | internal | existing main depth | frame | 10.6 |
| sceneCopy | RGBA16F | internal | blit destination, compressible | frame (H6→H6) | 21 |
| depthCopy | D32F | internal | blit | frame | 10.6 |
| hiZ | R16F, 5 mips | ½ internal | RT\|SR | frame | 3.5 |
| cloudCur / cloudDist | RGBA16F **lossy** / R16F | ½×½ internal | RT\|SR | frame | 5.3 / 1.3 |
| cloudHist ×2 | RGBA16F + RG16F | ½×½ internal | ping-pong, lossy | persistent | 2×7.9 |
| vlCur | RG11B10F lossy + R8 | ½ internal | RT\|SR | frame | 3.3 |
| vlHist ×2 | RGBA16F lossy | ½ internal | ping-pong | persistent | 2×5.3 |
| aoHist ×2 | RGBA16F | ½ internal | (AO, bent normal xy, linear depth) | persistent | 2×5.3 |
| prevDepth | R16F (linear) | internal | written by TAAU | persistent | 5.3 |
| tint | RGBA8 | internal | ShaderWrite side image | frame | 10.6 |
| reactive | R8 | internal | ShaderWrite side image | frame | 2.6 |
| taaHist ×2 | RGBA16F (rgb, a = age) | output | compressible, ping-pong | persistent | 2×47.5 |
| bloom chain | RG11B10F lossy | ½ internal … 1/128 | RT\|SR | frame | ≈4 |
| main | RGBA8 | output | game's own (SDR out + GUI) | frame | 23.8 |
| edrImage | RGBA16F | output | XDR only | frame | 47.5 |
| shadow array | D32F (or D16) 2×2048² | – | M1 | persistent | 32 (16) |
| shadowTint + shadowTDepth | RGBA8 + R16Unorm 2048² | near cascade | M3 | persistent | 16 + 8 |

- Sum: ≈ 360 MB at the 0.67x maximum, or ≈ 470 MB with a native-scale maximum.
- Put the frame-transient targets in one **aliasable `MTLHeap`**: sceneCopy, cloudCur, vlCur, bloom and the hi-Z
  pyramid are never alive at the same time as the TAAU temporaries. That saves about 50–70 MB.
- Every persistent and frame target goes into mcopt's residency set (`mcmetal.m:136-176`), not into per-encoder
  `useResource` calls.

### 1.7 Bindings (shade slots 16–19, reserved by M1)

| Slot | Content | Writer | Milestone |
|---|---|---|---|
| `buffer(16)` | `ShadeFrame` (M1, 1008 B) | CPU | M1 |
| `buffer(17)` | `ShadeLook` (§2.2, ≈1 KB): art layer, weather, effect parameters | CPU | M2 |
| `buffer(18)` | `ShadeGpu` (§2.3): SH9, exposure, sun visibility, canopy factor | GPU kernels (H1/H8) | M2 |
| `buffer(19)` | `ShadeResources` **argument buffer** (§2.4): every shade texture | CPU (on create/resize) | M2 |
| `texture(16)` | shadow array (M1) | shadow pass | M1 |
| `texture(17–19)` | pass-local inputs (e.g. sceneCopy in the water pass) | – | M2 |
| `sampler(12)` | compare sampler (M1) | – | M1 |

- Rebind rules are unchanged from critique §2.3: after `Native.renderBegin == 0`, in `MetalRenderPass.rebind`, and in
  `reapplyPipeline`.
- Argument buffers are Tier 2 on Apple9 (apple-gpu §1.1). Residency comes from the residency set.

### 1.8 Fork changes this design needs (beyond M1)

1. `MetalPipeline` keeps `CreateInfo` + MSL, plus `variant(colorFormats[], depth)` (critique §6.3). Needed for the
   RGBA16F redirect (M2) and the MRT G-buffer (M3).
2. **Render-scale viewport sub-rect.**
   - `openRender` sets the viewport and scissor to `ShadeLook.renderScale.zw` instead of the full attachment.
   - `GlobalSettingsUniform.ScreenSize` follows the active size (the existing `@ModifyArg` in `GameRendererFxMixin`).
   - Every full-screen pass maps `uv` into the sub-rect.
3. Native helpers in `mcshade.m`:
   - suspend/copy/resume at H6;
   - side images with ShaderWrite;
   - GPU frame time readback from `MTLCommandBuffer.GPUStartTime/GPUEndTime`, for DRS.
4. `mc_layer_configure` / `mc_present`: an EDR mode (RGBA16Float, `extendedLinearDisplayP3`,
   `wantsExtendedDynamicRangeContent`) and a per-frame headroom query. M1's `MetalFx` blit path stays untouched.
5. Sodium AO→alpha mixin (H12) behind the shade toggle, with a chunk rebuild on toggle.

---

## 2. Data contract

### 2.1 `ShadeFrame` (M1, buffer 16): unchanged, with M2 semantics notes

The fields are fixed by M1 (1008 B). M2 reinterprets three of them and stops using one:
- `time.z` (exposure): in M2 it mirrors `ShadeGpu.exposure.x` for back-compatibility. New code reads `ShadeGpu`.
- `sunColor` / `ambientSky` / `ambientGround`: still CPU-computed. The M2 lighting reads `ShadeGpu.sunAtCamera` and the
  SH9 instead, and keeps `ShadeFrame` as the fallback when the LUTs are disabled (P-tier "LUT off" debug).
- `horizon[8]`: **deprecated in M2.** It assumes the sun moves in the x-y plane, so it breaks with a tilted sun path. The
  sky-view LUT replaces it.
- `reserved0/1`, `flags3`: leave them to M1.

### 2.2 `ShadeLook` (buffer 17, CPU-written each frame, new in M2)

This is the proposed layout. The Java packer and the MSL struct must change together, as with `ShadeFrame`.

```
struct ShadeLook {                    // offsets in bytes
  float4x4 viewProjNoJitter;          //   0  this frame, unjittered (TAAU, SSR reprojection)
  float4x4 prevViewProjNoJitter;      //  64  last frame, re-based on this frame's camera (as M1 prevViewProj)
  float4x4 celestial;                 // 128  world dir -> celestial frame (stars, Milky Way wheel with the sun; tilt included)
  float4x4 cloudShadowVP;             // 192  camera-relative world -> cloud-shadow map clip (light space, ±512 blocks)
  float4 sunGeom;    // 256 x path tilt (rad), y sun angular radius (rad), z moon angular radius, w sun elevation (rad)
  float4 sunArt;     // 272 rgb art-graded sun/moon light (linear, /pi, pre-exposure), w direct crossfade 0..1
  float4 ambientArt; // 288 rgb tint applied to SH sky light, w ground-bounce strength
  float4 bounce;     // 304 rgb ground albedo for bounce (biome-driven), w cave minimum light
  float4 grade0;     // 320 x EV bias, y saturation, z vibrance, w log-contrast
  float4 grade1;     // 336 rgb white-balance gain (Bradford-derived, in 709), w Purkinje strength
  float4 grade2;     // 352 rgb lift (shadows), w toe
  float4 grade3;     // 368 rgb gain (highlights), w inset amount s_in
  float4 tonemap;    // 384 x contrast a, y shoulder d, z b, w beta (b, beta solved on the CPU from mid-grey in/out, scene white W, peak output.x)
  float4 output;     // 400 x display peak (1 = SDR, else EDR headroom), y paper-white scale, z dither amp, w RCAS strength
  float4 bloom;      // 416 x mix m, y scatter exponent, z fog-glow k, w lens-dirt amount
  float4 fogR;       // 432 rgb haze sigma (1/block), w scale height H_R (blocks)
  float4 fogM;       // 448 x mist sigma (1/block), y H_M, z mist base y, w mist albedo
  float4 fogMisc;    // 464 x haze base y, y border-fog start fraction, z AP metres per block, w cave fog density
  float4 vl;         // 480 x strength, y max distance (blocks), z HG g, w step count
  float4 wet;        // 496 x wetness, y puddles, z snow cover, w rain intensity (smoothed)
  float4 wind;       // 512 xy wind dir (unit, xz), z speed (blocks/s), w gust strength
  float4 clouds0;    // 528 x base y, y top y, z coverage, w type (0 stratus .. 1 towering)
  float4 clouds1;    // 544 xy wind offset (blocks, wrapped to the noise period), z cirrus coverage, w cirrus y
  float4 clouds2;    // 560 x sigma max, y style (0 off, 1 SDF voxel, 2 volumetric), z primary steps, w light steps
  float4 water;      // 576 x wave amplitude, y wave scale, z foam, w water surface y above the camera (underwater)
  float4 waterAbs;   // 592 rgb absorption sigma_a (1/block) from the biome water colour, w scattering sigma_s
  float4 heldLight;  // 608 rgb colour x level/15 (main + off hand, max), w radius (blocks)
  float4 eye;        // 624 xyz feet position (camera-relative), w smoothed eye sky light 0..1
  float4 biomeA;     // 640 smoothed weights: hot-dry, cold-snow, humid-jungle, swamp
  float4 biomeB;     // 656 smoothed weights: ocean, pastel (cherry/mushroom), pale garden, cave/deep dark
  float4 night;      // 672 x star brightness, y Milky Way, z aurora strength, w moon phase angle (rad)
  float4 ssr;        // 688 x steps, y thickness (blocks), z max distance, w enabled
  float4 taa;        // 704 x alpha min, y clip gamma, z history age cap, w reset (1 = drop history)
  float4 renderScale;// 720 x scale s, y texture mip bias, zw active internal size (px)
  float4 exposureCfg;// 736 x EV min, y EV max, z adapt-up tau (s), w adapt-down tau (s)
  float4 dimTint;    // 752 rgb dimension ambient (Nether biome / End), w dimension fog density
  float4 flash;      // 768 xyz direction (End flash or lightning), w intensity
  float4 dt;         // 784 x frame dt (s), y time (s, wrapped 3600), z day index (float), w rising (+1) / setting (-1)
  int4   tier;       // 800 x tier 0..3, y feature bits, z look preset 0..2, w debug view id
  float4 pad[13];    // 816..1023 room for M3/M4
};
```

### 2.3 `ShadeGpu` (buffer 18, GPU-written, read next frame or later in the same frame)

```
struct ShadeGpu {
  float4 sh[9];        // irradiance SH (order 2, cosine-convolved) of the env map, linear, NOT pre-exposed
  float4 sunAtCamera;  // rgb E_sun x T(camera -> sun) / pi (from the transmittance LUT), w sun visibility (horizon fade)
  float4 moonAtCamera; // rgb moon light at the camera / pi, w moon illuminated fraction
  float4 exposure;     // x applied exposure (this frame), y target, z previous frame's applied, w EV
  float4 scene;        // x mean log2 luminance, y canopy factor 0..1, z lens-flare sun visibility, w cloud cover at the sun
  uint4  histogram[16];// 64 bins of log luminance (written by the H8 histogram kernel)
};
```

### 2.4 `ShadeResources` (buffer 19, argument buffer)

Every entry below is created once, or on resize/reload. The `ShadeResources` struct in `shade_common.metal` declares
them in this order:

| Field | Type | Size | Built by |
|---|---|---|---|
| `transLut` | `texture2d<half>` RGBA16F | 256×64 | H1 (on atmosphere parameter change) |
| `msLut` | `texture2d<half>` RGBA16F | 32×32 | H1 (on change) |
| `skyView` | `texture2d<half>` RGBA16F | 192×108 (P 128×72, U 256×144) | H1 every frame |
| `envMap` | `texture2d<half>` RGBA16F, 5 mips (roughness prefilter) | 128×64 | H1 every frame (P: every 2nd) |
| `apLut` | `texture3d<half>` RGBA16F | 32×32×32 (U ×48 slices) | H1 every frame |
| `cloudWeather` | `texture2d<half>` RGBA8 | 512² (period 8192 blocks) | H1 on weather change |
| `cloudShadow` | `texture2d<half>` R8 lossy | 512² | H1 every 2nd frame |
| `noiseShape` | `texture3d<half>` RGBA8 | 128³ | load (compute) |
| `noiseDetail` | `texture3d<half>` RGB8 (in RGBA8) | 32³ | load |
| `curl2d` | `texture2d<half>` RG8 | 128² | load |
| `blueNoise` | `texture2d<half>` RGBA8 | 128² | file (CC0) |
| `waterWaves` | `texture2d_array<half>` RGBA8 | 128²×64 frames | load (FFT bake, §E14) |
| `caustics` | `texture2d_array<half>` RGBA8 (4 depths) | 128²×64 | load (from the same FFT) |
| `milkyWay` | `texture2d<half>` RGBA16F | 1024×512 | load (procedural, §E04) |
| `moonAlbedo` | `texture2d<half>` R8 | 256² | load (procedural) |
| `endNebula` | `texture2d<half>` RGBA16F | 1024×512 | load (procedural, §E25) |
| `lensDirt` | `texture2d<half>` R8 | 512² | load (procedural) |
| `matClass` | `texture2d<uint>` R8Uint | block atlas size (÷4 if > 2048²) | H11 |
| `matParams` | `texture2d<half>` RGBA8 + mips | block atlas size | H11 |
| `labNormal` | `texture2d<half>` RGBA8 (optional) | block atlas size | H11 (labPBR packs) |
| `blackbody` | `texture1d<half>` RGBA16F | 256 (1000–20000 K) | load (CPU, CIE fit) |
| `lpv` | `texture3d<half>` RG11B10F ×2 | 128×64×128 | H1 (M3) |
| `shadowTint`, `shadowTDepth`, `entityShadow` | 2D | 2048², 2048², 1024² | H2 (M3) |
| `aoPrev`, `cloudPrev`, `vlPrev`, `taaPrev`, `prevDepth`, `hiZ`, `depthCopy`, `sceneCopy` | 2D | §1.6 | per frame (swap pointers by rewriting 8 entries, ≈ 0 cost) |

Load-time generation costs about 15–40 ms of GPU once, and ≈ 25 MB. Nothing is shipped as an image except the CC0 blue
noise.

### 2.5 Material classes (atlas class mask, R8Uint): **our** taxonomy

- Bits 0–5 = class. Bit 6 = "upper half of a two-block plant". Bit 7 = sparkle/glint.
- **Classification order:**
  1. For each `BlockState`, the baked model's quad sprites come from `ModelManager`.
  2. The block's **tags** (`#leaves`, `#flowers`, `#crops`, `#logs`, `#planks`, `#ice`, `#snow`, …) and registry id
     assign the class.
  3. Sprite-name patterns are the fallback.
  4. A sprite used by several blocks takes the highest-priority class: emitter > fluid > translucent > foliage > rest.
- Because classes come from block identity, resource-pack and modded blocks inherit sensible classes.

| ID | Class | Typical blocks | Consumers |
|---|---|---|---|
| 0 | default solid | anything unclassified | lighting |
| 1 | rough mineral | stone, deepslate, cobble, andesite, ore hosts | params heuristics |
| 2 | polished mineral | polished_*, smooth_*, quartz, concrete, glazed terracotta | specular |
| 3 | wood | logs, planks, stripped logs | specular |
| 4 | metal | iron/gold/copper (all oxidation stages)/netherite blocks, chains, anvils, bars | metal f0 (labPBR 230–237) |
| 5 | gem/crystal | diamond, emerald, lapis, amethyst block | specular, sparkle |
| 6 | granular | sand, red sand, gravel, dirt, mud, clay | wet darkening, sparkle (sand) |
| 7 | snow | snow, snow block, powder snow | sparkle, SSS |
| 8 | opaque ice | packed ice, blue ice | specular |
| 9 | fabric | wool, carpet | rough |
| 10 | leaves | `#leaves` | SSS, waving (whole block), no vanilla AO |
| 11 | short plant | grass, fern, flowers, saplings, mushrooms, dead bush | SSS, waving (top vertices) |
| 12 | tall plant | tall grass, large fern, two-block flowers (bit 6 = upper) | waving (graded) |
| 13 | crop | wheat, carrots, potatoes, beetroot, stems, nether wart | waving (small) |
| 14 | hanging | vines, weeping/twisting/cave vines, hanging roots, glow lichen | sway along the face |
| 15 | floating | lily pad | bob |
| 16 | stiff plant | sugar cane, bamboo, cactus | slow sway |
| 17 | grass-top / soil-top | grass block top, mycelium, podzol | wet darkening, puddle mask |
| 20 | water | water still/flow | water shader, waves |
| 21 | lava | lava still/flow | emission, heat shimmer |
| 24 | clear glass | glass, panes | glass shader |
| 25 | stained glass | stained glass/panes | tint, coloured shadows |
| 26 | translucent ice | ice | refraction, tint |
| 27 | gel | slime, honey | tint, refraction |
| 28 | portal | nether portal | parallax swirl |
| 29 | tinted glass | tinted glass | dark tint |
| 32 | flame, warm | torch, wall torch, campfire, fire, candle flame | emission (luminance threshold), 1900 K |
| 33 | flame, soul | soul torch/fire/campfire/lantern | emission, cyan |
| 34 | warm lamp | glowstone, shroomlight, jack o'lantern, lit redstone lamp | emission, 3000 K |
| 35 | cool lamp | sea lantern, beacon, conduit, end rod | emission, 7500 K + cyan |
| 36 | redstone | dust (lit), torch, lit ore, repeater/comparator lights | emission (hue mask red) |
| 37 | magma | magma block | emission (hue mask orange) |
| 38 | froglight | ochre/verdant/pearlescent | emission (per-sprite colour) |
| 39 | bio-glow | sculk family, amethyst cluster, glow berries, glow lichen | emission (teal/violet/warm) |
| 40 | ore | all `*_ore` | optional "glowing ores" emission (per-texel contrast with the sprite border) |
| 41 | lantern | lantern, soul lantern | emission + swing (entity-free sway of the hanging model, small) |

**Parameter atlas (RGBA8, labPBR 1.3 `_s` encoding):**
- R = perceptual smoothness.
- G = f0. Values 0–229 are linear f0 = G/255. 230–237 = hard-coded metals: iron, gold, aluminium, chrome, copper, lead,
  platinum, silver.
- B = porosity (0–64) or SSS (65–255).
- A = emission 0–254, with 255 = none.

Our CPU heuristics (§E12) write this encoding. A resource pack's `_s` sprite replaces our value per sprite when present.

### 2.6 CPU-side state (Java, all smoothed per frame)

| State | Source | Smoothing |
|---|---|---|
| wetness | `rainLevel` × sky exposure at the camera | rise half-life 20 s, decay 60 s |
| puddles | wetness | lags wetness by 30 s; dries with a 120 s half-life |
| snow cover | precipitation = snow at the camera × rain level | rise 40 s, decay 300 s |
| biome weights (8) | biome at the camera (5×5 samples, 8-block spacing), mapped by climate and tags to the 8 categories | τ = 6 s |
| eye sky light | `ClientLevel` sky light at the eye | τ = 1.5 s |
| weather system | §E05.6: daily temperature/humidity/wind from hashed day index + biome + rain | τ = 30 s |
| held light | main/off-hand item → emission level + our colour table | none |
| underwater surface y | scan block states upward from the eye (≤ 16 blocks) while in water | none |
| moon phase angle | `moonPhase` × 45° | none |
| rising/setting | sign of d(sunY)/dt | none |

### 2.7 Histories (previous-frame data)

| History | Res | Used by | Reset rule |
|---|---|---|---|
| taaHist (rgb pre-exposed, a = age) | output | TAAU; **SSR colour source** (reprojected) | teleport > 8 blocks, resize, dimension change, F3+T |
| prevDepth (linear) | internal | TAAU disocclusion; AO/VL/cloud reprojection checks | same |
| cloudHist | ½×½ | clouds | world time jump > 2 s, style change |
| vlHist | ½ | VL | camera cut |
| aoHist | ½ | GTAO, consumed next frame by lighting | depth mismatch per pixel |
| exposure (`ShadeGpu.exposure.z`) | – | pre-exposure rescale | – |
| previous matrices (`ShadeLook`, M1 `prevViewProj`) | – | everything temporal | – |

---
## 3. Art direction (original; inspired by what makes the studied packs beautiful)

### 3.1 The commandments

What we learned from the four studies, restated as our own rules:

1. **One light, many consumers.** Sun colour, sky, ambient, fog, clouds and reflections all derive from one atmosphere
   plus one art layer. Nothing hand-picks its own sky colour. This is the SEUS E12 and Photon lesson, and
   Complementary's sky⇄fog consistency.
2. **Warm key, cool fill.**
   - Sunlit surfaces lean warm and shadowed surfaces lean sky-blue at every hour except overcast.
   - The temperature *difference* between key and fill carries the time of day: small at noon, large at golden hour.
3. **Darkness is readable and coloured, never grey mush.**
   - Night is blue-violet and desaturated (Purkinje).
   - Caves are near-black but not crushed.
   - Torches own the night.
   - There is always a floor (§3.5).
4. **Highlights roll to white; nothing clips, nothing turns neon.** This comes from the inset/outset tonemap and from
   energy-conserving bloom mixed in at 8–14% instead of added.
5. **Distance glows.** Aerial perspective plus fog glow (bloom weighted by fog) makes far terrain luminous and soft,
   especially at golden hour, in rain and in humid biomes.
6. **Blocks stay readable.** Face orientation must always be legible:
   - the SH sky ambient makes up > side > down;
   - a mild east/west asymmetry separates the sides;
   - AO is curved by light.

   We are "Minecraft, but beautiful" (BSL), not photoreal clay.
7. **Life everywhere:** waving plants that respect shelter, backlit leaves that glow, glittering water, drifting clouds
   with shadows, twinkling stars.
8. **Every day is a little different.** A daily weather state changes clouds, haze and wind (Photon's best idea,
   re-implemented in our own way).

### 3.2 Time-of-day keyframes (by **sun elevation e**, after the sun-path tilt; CPU Catmull-Rom → `ShadeLook`)

How to read the columns:
- **Chroma γ**: the power applied to the *normalised* physical light chroma (§E01). Values above 1 saturate the
  physically correct sun colour.
- **Light×**: an art multiplier on the light's luminance.
- **EV ref**: the exposure the auto-exposure is pulled toward (§E20). Positive means a brighter exposure than noon.
- **Shadow/key**: the *target* luminance ratio of a white surface in shadow vs in direct light. Tune `ambientArt` until
  screenshots hit it.
- **σ_M**: the Mie mist density at the mist base, ×10⁻³/block.
- **WB**: the white-balance shift in mired. Negative = cooler image, which compensates for the warm light at golden
  hour only partially.

| e | Phase | Chroma γ | Light× | Ambient tint (×SH) | EV ref | Sat | Contrast a | Bloom m | VL k | σ_M | WB | Shadow/key |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| ≤ −15° | Night (moon key) | 1.00 | moon 1.0 × phase (0.30–1.0) | (0.80, 0.88, 1.16) | +3.0 | 0.72 | 1.28 | 0.14 | 0.30 | 1.5 | −20 | 0.45 |
| −9° | Nautical twilight | 1.00 | moon 0.7 | (0.84, 0.86, 1.20) | +2.5 | 0.82 | 1.30 | 0.13 | 0.15 | 2.0 | −25 | 0.60 |
| −4° | **Blue hour** (no direct sun) | – | 0 (crossfaded) | (0.86, 0.84, 1.22) | +1.8 | 1.12 | 1.32 | 0.12 | 0.05 | 2.5 | −30 | 1.00 |
| 0° | Sun on the horizon | 1.60 | 0.85 | (1.04, 0.93, 1.05) | +0.9 | 1.18 | 1.36 | 0.12 | 1.00 | 5.0 | +55 | 0.32 |
| 5° | **Golden hour** | 1.40 | 1.00 | (1.00, 0.95, 1.05) | +0.5 | 1.14 | 1.38 | 0.10 | 0.85 | 4.0 | +40 | 0.28 |
| 12° | Late golden | 1.18 | 1.00 | (0.98, 0.98, 1.04) | +0.25 | 1.08 | 1.40 | 0.09 | 0.55 | 2.5 | +18 | 0.26 |
| 25° | Morning / afternoon | 1.05 | 1.00 | (0.96, 1.00, 1.06) | +0.1 | 1.04 | 1.40 | 0.08 | 0.32 | 1.2 | +5 | 0.24 |
| 45° | Day | 1.00 | 1.00 | (0.95, 1.00, 1.08) | 0 | 1.02 | 1.40 | 0.075 | 0.22 | 0.6 | 0 | 0.22 |
| ≥ 65° | High noon | 1.00 | 1.00 | (0.95, 1.00, 1.10) | −0.05 | 1.00 | 1.42 | 0.075 | 0.18 | 0.5 | −5 | 0.21 |

- **Morning/evening asymmetry** (`dt.w`). Mornings get σ_M ×1.6 (ground mist), WB −10, Sat −0.04. Evenings get
  σ_M ×0.9, WB +12, Sat +0.05, and a warmer bounce (+10% red in `bounce`).
- **The sun↔moon handover is a crossfade.** Direct light × `smoothstep(0.0, 0.035, |sunY|)` on each side, so shadows
  never pop when M1's `lightDirWorld` switches. The VL and specular strengths follow the same factor.
- **The moon key** scales with the illuminated fraction (1 − cos φ)/2 (full 1.0, new ≥ 0.30 floor) and with clear sky.
  New-moon nights rely on starlight + airglow + the Milky Way in the env map (§E04).

### 3.3 Target palettes (sRGB hex of what the **screen** should show at the sample points; tuning targets, not constants)

| Key | Zenith | Horizon (toward sun / away) | Sunlit grass | Sunlit white stone | Shadowed white stone | Accent |
|---|---|---|---|---|---|---|
| High noon | #3C7FD6 | #AECBEA / #A6C2E4 | #6DA83E | #F2EFE8 | #8EA3C2 | sun disc #FFF8EE |
| Morning | #4A86D4 | #D9DCE0 / #A9C1E0 | #73A443 | #F5E9D9 | #8A9EC0 | ground mist #CBD6E2 |
| Golden hour | #4B6CB0 | #FFB46A / #B7A7C9 | #9C9A3E | #F2B776 | #6C7DA6 | long shafts #FFC27C |
| Sun on horizon | #3E5597 | #FF8B3E→#FF5D37 / #9A86B6 | #8B7038 | #E58D55 | #5B6593 | cloud bellies #D9584C, tops #FFC17C |
| Blue hour | #1E2D63 | #E59C9F (anti-solar pink band) / #6D78B5 | #2F4639 | #6C79A8 | #4C578A | first stars |
| Night, full moon | #0B1530 | #1D2A4C / #142140 | #1D2B2A | #4E5C7C | #1B2339 | torch pool #FFB06A, moon #E8EEFF |
| Night, new moon | #070B18 | #0E1528 | #0E1514 | #222A3E | #141A28 | Milky Way core #E9D6B8 |
| Rain | #7B848F | #A2A9B1 | #4F6A44 | #A3A7AC | #6E757E | wet stone gloss |
| Thunderstorm | #3C424C | #59606B | #33452F | #6E737A | #4A5058 | flash #DDE5FF |
| Snowfall / snowy day | #B8C7DA | #D7DFEA | – | snow #F4F7FF | snow shade #8FA5C9 | sparkles |

### 3.4 Biome feels (smoothed `biomeA/B` weights blend these over the baseline; vanilla biome fog/sky/water colours stay as inputs)

| Biome group | Haze σ_R× / σ_M× | Haze tint | Ground bounce | Grade (WB, Sat) | Signature extras |
|---|---|---|---|---|---|
| Plains, meadow (baseline) | 1.0 / 1.0 | #A9C4E8 | #6E8F4A | 0, 1.00 | clean blue distance |
| Forest, birch | 1.0 / 1.3 | #A8C2C9 | #4F7A3A | 0, 1.02 | strong canopy VL, morning mist under trees |
| Dark forest | 1.2 / 2.2 | #8FA3A0 | #3B5A2E | −5, 0.95 | ambient −15%, green-tinted VL |
| Pale garden | 1.0 / 4.0 | #C9CCCC | #8E918C | −20, 0.60 | near fog, grey-white eerie light, eyeblossom glow pops |
| Jungle, bamboo | 1.2 / 2.0 | #A9C7B0 | #4E8A36 | +10, 1.08 (greens +) | humid glow, dense shafts |
| Swamp, mangrove | 1.1 / 2.6 | #9FAF86 | #5E6B3A | +5, 0.92 | yellow-green haze, murky water (§E14) |
| Desert, savanna | 0.8 / 0.6 | #E3D2B0 | #D2B98A | +15, 1.04, contrast +0.05 | very warm fill from the sand, optional noon heat shimmer |
| Badlands | 0.9 / 1.4 | #D7B48C | #B5683E | +20, 1.06 | dusty orange distance; rain becomes a sandstorm (σ_M ×6, #C89A62) |
| Snowy plains / ice spikes / frozen ocean / snowy slopes | 0.9 / 1.0 | #C9D6E8 | #E8EEF6 | −15, 0.95 | bright shadows, snow glitter, aurora-eligible |
| Taiga, old growth | 1.0 / 1.8 (mornings) | #A9B8C4 | #4A6040 | −8, 0.92 | cool desaturated greens |
| Ocean, beach | 1.1 / 0.8 | #9DC0EA | #D9CFA8 | +3, 1.04 | sun glitter roads, deep blue distance |
| Mushroom fields | 1.0 / 1.5 | #C8A9C8 | #8A6E80 | +5, 1.05 | pink haze |
| Cherry grove | 1.0 / 1.4 | #E6C4D6 | #E7A9C4 | +8, 1.06, bloom +0.02 | pink bounce light under the trees |
| High altitude (y > 150) | natural thinning | – | – | −5, 1.02 | crisp; valleys below stay hazy because the haze is height-based |
| Lush caves | – (cave) | fog #4C6B4A | #5E8F3E | +5, 1.05 | glow berries bloom warm |
| Dripstone caves | – | fog #5A4A3E | #7A6450 | +10, 0.95 | warm dusty dark |
| Deep dark | – | fog #050810 | #10141A | −10, 0.85 | exposure floor −0.6 EV, sculk #2FD3C6 bloom ×1.5, strong Purkinje |
| Generic caves | – | fog #1A1E26 | #2A2A2E | 0, 0.92 | torch-dominated, near-black between lights |

### 3.5 Readability floors and ceilings (post-exposure, pre-tonemap linear luminance; enforced by tuning, checked by the harness)

| Situation | Target |
|---|---|
| White surface, full sun, noon | 2.2–2.8 (rolled by the shoulder to about 0.92–0.95 display) |
| White surface in sun shadow, noon | 0.45–0.65 |
| White surface, full-moon night, open sky | 0.10–0.16 |
| White surface, new-moon night | ≥ 0.035 |
| Cave, no block light, sky light 0 | 0.010–0.016 (lifted by the toe; never pure black on an XDR panel) |
| Within 2 blocks of a torch | 0.9–1.4 |
| Sky zenith at noon | 0.9–1.3 |
| Sun disc (pre-tonemap) | ≥ 60 (bloom carries the glow; in XDR it reaches the panel peak) |

### 3.6 Look presets (one engine, three art presets)

| Parameter | **Epic** (default) | **Storybook** | **Natural** |
|---|---|---|---|
| Inspiration | Unbound, SEUS, Photon drama | Reimagined, BSL warmth | Photon, SEUS restraint |
| Sun path tilt | −30° | −15° | −25° |
| Sun disc | procedural, 0.45° radius, limb darkened | regraded vanilla sun sprite, or rounded-square SDF disc | procedural, 0.35° |
| Clouds | volumetric cumulus + cirrus | SDF voxel clouds from the game's cloud map | volumetric, less coverage |
| Water | FFT waves, glossy, sun glitter | waves sampled on a 16 px/block grid (pixel ripples), clearer | FFT, near-invisible surface, strong absorption |
| Chroma γ multiplier | ×1.0 | ×1.15 | ×0.9 |
| Saturation offset | +0.02 | +0.10 | 0 |
| Contrast a | 1.40 | 1.30 | 1.30 |
| Bloom m multiplier | ×1.0 | ×1.25 | ×0.8 |
| Auto-exposure λ | 0.55 | 0.40 (flatter) | 0.70 |
| VL multiplier | ×1.0 | ×1.25 | ×0.8 |
| Moon | procedural, real phase shading | vanilla phase sprite, regraded | procedural |
| Lens flare | off | optional | off |

---
## 4. Effects

Every effect uses the template from the header: **Look**, **Technique**, **Algorithm**, **Hook**, **Cost & tiers**,
**Data & deps**. Costs are GPU ms at 0.67x internal for P/B unless a row says otherwise, and at native for Q/U.

---

### E01. The colour state and art layer (`ShadeLook`), the foundation of everything

- **Look.** Each pack has a "central colour state" that every effect reads:
  - Complementary computes it per pixel from `skyColor`, sun height, rain and biome;
  - BSL authors it in sqrt space;
  - Photon builds it from the physical sun colour plus exposure "magic".

  Ours makes that state explicit, computed once on the CPU, and physically seeded.
- **Technique (original).**
  1. **Physical seed.** Sun and moon light at the camera come from the transmittance LUT, written by the GPU to
     `ShadeGpu.sunAtCamera` (fallback: M1's CPU `ShadeSky` mirror). Ambient comes from the SH9 of the env map.
  2. **Chroma power.** Let c be the physical light, Y = luma(c), and q = c/Y. Then
     q′ = q^γ / luma(q^γ) and c_art = Y·q′·Light×. With γ > 1 the sunset chroma deepens without changing the
     luminance. This is the generalised form of the "raise the sunset colour to a power" trick shared by every studied
     pack.
  3. **Keyframe interpolation.** Use a centripetal Catmull-Rom in **e** over the §3.2 rows. Colours are interpolated in
     √-space and squared afterwards (perceptually even blends).
  4. **Modifiers, applied in this order:** morning/evening asymmetry → biome weights (§3.4, weighted average of
     deltas) → weather (rain: Sat ×0.75, contrast −0.08, bloom +0.03, σ_M up to ×8 with snow ×5, direct light
     × (1 − 0.9·rain), WB −10) → dimension overrides (§E24/E25) → user exposure compensation.
- **Hook.** H1 (Java `ShadeLook.pack()`).
- **Cost.** 0 GPU, about 20 µs CPU.
- **Data/deps.** `ShadeFrame` (M1), the smoothed CPU state (§2.6), `ShadeGpu` from the previous frame (one frame of lag
  is invisible).

---

### E02. Atmosphere sky (LUT-based)

- **Look.**
  - **Photon** does the sky best: a physical Rayleigh/Mie/ozone sky gives correct golden hours, a pink anti-solar
    band and a luminous blue hour. A small art grade then stretches the colourful horizon band upward.
  - **SEUS E12** proves the payoff of using the same functions for terrain haze, clouds and reflections.
  - **Complementary's** gradient sky is beautiful because it is *art-graded*. We get that feel from the post-LUT grade
    (horizon stretch, blue-hour saturation, rain desaturation), not from a hand-made gradient.
- **Technique.** Re-implement **Hillaire, "A Scalable and Production Ready Sky and Atmosphere Rendering Technique"
  (EGSR 2020)** from the paper. Its LUT parameterisations come from Bruneton 2008/2017 (public math). Adapting Photon's
  MIT `atmosphere.glsl` mapping helpers is *allowed* (§8), but not needed.
- **Algorithm.**
  - **Planet** (km):
    - R_g = 6360, R_t = 6460.
    - ρ_R = e^{−h/8}, ρ_M = e^{−h/1.2}, ozone tent ρ_O = max(0, 1 − |h − 25|/15).
    - σ_s,R = (5.802, 13.558, 33.1)·10⁻³; σ_s,M = 3.996·10⁻³·m; σ_a,M = 0.444·10⁻³·m;
      σ_a,O = (0.650, 1.881, 0.085)·10⁻³. These are published Earth values, the same as M1's constants.
    - Mie multiplier m = 1 + 5·rain + 2·humidity + biome haze.
    - Camera altitude h_c = 0.2 km + max(y − 63, 0)·0.001.
  - **Transmittance LUT** 256×64 RGBA16F:
    - u = x_μ, v = x_r with the Bruneton mapping: H = √(R_t² − R_g²), ρ = √(r² − R_g²), d = distance to the top
      boundary, x_μ = (d − (R_t − r))/(ρ + H − (R_t − r)), x_r = ρ/H.
    - T = exp(−Σσ_t·∫ρ ds), 40 midpoint steps.
    - Rebuilt only when m or the ozone changes (≈ 0.01 ms).
  - **Multi-scatter LUT** 32×32 over (μ_s, r):
    - 64 stratified directions × 20 steps;
    - L₂ = ∫ T_v·σ_s·T_sun·(1/4π)·E dt (+ ground albedo 0.3·T·μ_s/π at the ground hit);
    - f_ms = ∫ T_v·σ_s·(1/4π) dt, both averaged over the sphere;
    - Ψ_ms = L₂/(1 − f_ms).
    - This is the term that keeps twilight blue instead of grey. Rebuilt on change (≈ 0.03 ms).
  - **Sky-view LUT** 192×108 RGBA16F, every frame:
    - u = φ/π (azimuth relative to the sun, mirrored: the sky is symmetric about the sun's vertical plane, and the
      vanilla moon sits at φ = π).
    - v = ½ + ½·sign(l)·√(|l|/(π/2)), with l = elevation minus the horizon dip.
    - March 32 steps (P: 24) with the energy-conserving step integral S·(1 − e^{−σ_tΔ})/σ_t (Hillaire 2015).
    - In-scatter = σ_s,R·P_R(ν) + σ_s,M·P_CS(ν, 0.6) + (σ_s,R + σ_s,M)·Ψ_ms, times T_sun and the planet shadow. A moon
      term uses the same T_view with E_moon.
    - **Alpha** stores the Mie single-scatter integral *without* phase (luminance). It is used per pixel to add the
      tight aureole (E03).
  - **Env map** 128×64 RGBA16F, equirect, every frame (P: every 2nd):
    - sky-view + a 12-step cloud march (E05) + the Milky Way average (E04) + the ground (dark albedo 0.15 × SH-up × ½);
    - 5 mips, prefiltered by a 4-tap cosine-power blur per mip for rough reflections.
  - **SH9:** one threadgroup of 256 threads, R2-distributed env samples, `simd_sum` reduction, Ramamoorthi–Hanrahan
    cosine-convolution weights (π, 2π/3, π/4) → `ShadeGpu.sh` (not pre-exposed).
  - **Aerial-perspective froxels** 32×32×32 RGBA16F:
    - slice depth d_k = D·((k + ½)/32)², with D = render distance in blocks × `fogMisc.z` metres/block (default 12)
      converted to km;
    - one thread per column marches cumulatively and stores in-scatter (rgb) and mean transmittance (a).
  - **Art grade at lookup:**
    - **Horizon stretch:** sample at l′ = l − 0.35·l·e^{−l/0.2} for l ≥ 0.
    - **Blue-hour chroma boost:** 1 + 0.25·e^{−((e + 4°)/3°)²} around luma.
    - **Rain:** desaturate 60% toward a cool grey and dim by (1 − 0.45·thunder).
    - Underground: fade the lower sky toward the cave fog when eye sky light < 0.2.
- **Hook.**
  - H1 compute builds the LUTs.
  - H3 sky override, for sky pixels only: `skyView(dir)` + aureole + sun/moon/stars/Milky Way/aurora.
  - Every lit or fogged pixel reads `apLut`, `envMap` and `sh`.
- **Cost & tiers.**

  | Tier | Sky-view | Env | AP | Total |
  |---|---|---|---|---|
  | P | 128×72, 24 steps | every 2nd frame, clouds 8 steps | 32³ | ≈ 0.05 ms + sky pixels 0.02–0.04 |
  | B | 192×108, 32 | every frame, 12 | 32³ | ≈ 0.07 |
  | Q | 192×108, 32 | every frame, 12 | 32³ | ≈ 0.08 (native sky pixels 0.06) |
  | U | 256×144, 40 | every frame, 16 | 32×32×48 | ≈ 0.12 |

- **Data/deps.**
  - Inputs: `ShadeFrame.sunDirWorld/moonDirWorld/atmosphere/weather`; `ShadeLook.sunGeom` (tilt), `fog*`, `clouds*`.
  - Outputs: `transLut`, `msLut`, `skyView`, `envMap`, `apLut`, `ShadeGpu.sh/sunAtCamera/moonAtCamera`.
  - Replaces M1's `shadeSkyRadiance` and `horizon[8]`. Keep M1's code as the "LUT off" fallback.

---

### E03. Sun and moon discs, glare and aureole

- **Look.**
  - **SEUS E12:** a *small, very bright* sun disc, with the big Mie aureole and bloom carrying the glow.
  - **Photon:** limb darkening that reddens the edge.
  - **Unbound:** a procedural cratered moon with phases.
  - **Storybook** keeps the vanilla sprites, regraded (Reimagined), or a rounded-square disc.
- **Technique (original).**
- **Algorithm.**
  - **Sun.**
    - Angular radius α_s (Epic 0.45°, Natural 0.35°). Disc coordinate ρ = angle(dir, sun)/α_s, μ = √(1 − ρ²).
    - Quadratic limb darkening I = 1 − u(1 − μ) − v(1 − μ)², per channel (u, v) = R (0.40, 0.25), G (0.55, 0.20),
      B (0.70, 0.12).
    - Radiance L_disc = E_sun·T(dir)/(π·α_s²·(1 − u/3 − v/6))·I, where T comes from the transmittance LUT, so the
      disc turns red and dims at the horizon.
    - Anti-alias the edge with `smoothstep(1 + w, 1 − w, ρ)`, w = 1.5·pixel angle / α_s.
    - **Storybook square sun:** replace ρ with the L⁴-norm in the sun's tangent frame.
  - **Aureole** (per sky pixel): L += A_sky·chroma(sunAtCamera)·E·(P_CS(ν, 0.82) − P_CS(ν, 0.6))·k_a, with A_sky the
    sky-view alpha (Mie integral) and k_a = 1 (Epic) or 0.7 (Natural). Rain scales it by (1 − 0.7·rain).
  - **Moon.**
    - Disc of 0.55°; sphere normal n from the disc coordinate.
    - Albedo from `moonAlbedo`, generated: maria = low-frequency fBm thresholded, plus about 60 crater profiles
      (bowl + raised rim + ray noise).
    - Shading uses the **Lommel–Seeliger** law L = a·μ₀/(μ₀ + μ)·E_moonSun (flat, lunar-correct).
    - The phase light direction is the sun direction rotated about the moon's up axis by φ = `moonPhase`·45°
      (vanilla's phase index).
    - Earthshine 0.012 on the dark side. Halo: P_CS(ν, 0.9)·0.02 when clear.
    - Moonlight intensity for the scene = full-moon value × (1 − cos φ)/2, floor 0.3 (art).
  - Vanilla `celestial`/`sunrise_sunset` draw nothing: the override's fragment discards, so there is no double sun.
- **Hook.** H3 (sky pass, sky pixels only).
- **Cost.** About 0 (a few ALU ops on sky pixels; one texture fetch for the moon). All tiers.
- **Data/deps.** E02 LUTs, `ShadeLook.sunGeom/night`, `moonAlbedo`. Bloom (E19) and XDR (E23) make it glow.

---

### E04. Night sky: stars, Milky Way, aurora

- **Look.**
  - **Photon:** blackbody-coloured, twinkling stars that wheel with the sky.
  - **SEUS:** moon-phase-dependent darkness, with starlight in the ambient.
  - **Complementary:** auroras at full moon in snowy biomes are a beloved surprise.
  - Our addition: a real **Milky Way** band so new-moon nights are spectacular, not empty.
- **Technique (original).** Note: Photon's star code is "based on" a Shadertoy entry with no stated license, so it is
  **not** adapted (§8).
- **Algorithm.**
  - **Celestial frame.** `ShadeLook.celestial` rotates world directions about the tilted celestial pole with the sun
    angle, so stars rise and set with the sun path.
  - **Stars** (per sky pixel, only when the sky luminance is below 0.05 pre-exposure or at night):
    1. Map the direction to a cube face and a cell on a 512² grid per face.
    2. Test the 4 nearest cells: a star exists if hash₁ < 0.06.
    3. Magnitude m = −1 + 7.5·hash₂^0.45 (more faint stars than bright ones); flux F = 10^(−0.4m)·k_star.
    4. Temperature from a mixture: 55% 3200–5200 K, 35% 5200–7500 K, 10% 7500–15000 K, looked up in the `blackbody`
       1D texture (CIE 1931 fit, normalised luminance).
    5. Angular position jittered inside the cell.
    6. Radiance = F·G(θ; σ)/(2πσ²), with **σ = max(0.6·output pixel angle, 0.3·cell angle)**: an energy-conserving
       Gaussian, stable under TAAU and resolution-independent.
    7. Twinkle (scintillation) ×(1 + 0.35·airmass·(n(t·7 + hash₃) − 0.5)), airmass = 1/max(dir.y, 0.05).
    8. Extinction × sky-view T alpha.
    9. Stars are simply *added* to the sky radiance, so daylight hides them physically and they appear through
       twilight on their own.
  - **Milky Way** (`milkyWay`, baked at load in galactic coordinates (ℓ, b), sampled through the celestial matrix plus
    the galactic tilt of 62.9° to the "equator" = the sun-path plane):
    - Bulge B = 2.2·exp(−(ℓ_c²/12°² + b²/6°²)), with ℓ_c the wrapped angle to the galactic centre.
    - Disc D = exp(−|b|/(3° + 3°·cos²(ℓ/2)))·(0.6 + 0.4·fBm₃(dir·6)).
    - Dust lanes: × (1 − 0.75·ridge(fBm₃(dir·9))·exp(−|b|/2°)).
    - Star clouds: + 0.3·fBm₃(dir·40)^4.
    - Colour: core (1.0, 0.86, 0.66) → arms (0.74, 0.82, 1.0) by |ℓ_c|.
    - Peak radiance about 4× the faint-star background. Also accumulated (at low res) into the env map, so new-moon
      ambient carries a faint cool starlight.
  - **Aurora** (night, clear, cold-biome weight > 0.3, hashed per in-game night with 30% probability; "Always" option
    in U):
    - A thin curved shell between 0.9 and 1.6 km "virtual" altitude (projected onto the sky dome; no terrain occlusion
      except depth == 0).
    - March 12 (P) / 16 (Q) / 24 (U) steps.
    - The curtain field is 2D in the shell plane: c = fBm₂(x·0.0004 + warp(t)) with a domain warp from `curl2d`;
      curtain line I = exp(−((c − 0.5)/0.035)²).
    - Vertical rays: × (0.55 + 0.45·n(s·45 + t·0.3)), with s the along-line coordinate.
    - Height colour (shell fraction h): violet fringe (0.42, 0.30, 1.0) at h < 0.08; green (0.20, 1.0, 0.45) peaking at
      h ≈ 0.25; crimson (1.0, 0.22, 0.35)×0.45 above h > 0.6.
    - Pure emission summed along the ray, × strength `night.z`.
    - A dimmed copy goes into the env map, so snow and water reflect a green glow and the SH tints the ground faintly
      green.
- **Hook.** H3 for the per-pixel stars and aurora; H1 env map; load-time bakes.
- **Cost & tiers.**
  - Stars: 4 hash cells ≈ 0.02 ms (all tiers).
  - Milky Way: 1 fetch.
  - Aurora: P 0.06 / Q 0.12 / U 0.2 ms, only when active.
- **Data/deps.** E02, `blackbody`, `milkyWay`, `ShadeLook.celestial/night`, cold-biome weight, weather.

---

### E05. Clouds (volumetric, SDF-voxel, cirrus) and cloud shadows

- **Look.**
  - **Photon** does clouds best: enormous layered clouds, a daily weather state, multi-scatter "powdery" cores with dark
    bellies and silver linings, aerial perspective, cloud shadows and rays from clouds.
  - **Unbound:** bright silver rims.
  - **SEUS:** clouds reach the horizon and glow warm at sunset; coverage varies over days.
  - **Reimagined:** rounded blocky clouds that keep Minecraft's identity (our Storybook style).
- **Technique (original), from public research:**
  - Schneider & Vos, *The Real-time Volumetric Cloudscapes of Horizon Zero Dawn* (SIGGRAPH 2015), and Schneider's
    *Nubis* talks (2017, 2022): weather map, height gradient, remap erosion, Beer–powder;
  - Wrenninge et al., multiple-scattering octaves;
  - Hillaire 2015 (energy-conserving integration).

  Photon's MIT cloud code (§8) may be consulted or adapted for layer shaping and reprojection details, with attribution.
  The design below stands on its own.
- **Algorithm, volumetric cumulus (Epic/Natural):**
  1. **Slab.** Base y_b = 240, top y_t = 400 (blocks).
     - Earth-curvature drop y′ = y + d_h²/(2·R_c), with R_c = 40 000 blocks, so the layer curves down to the
       horizon.
     - Ray clipped to [y_b, y_t] and to 12 000 blocks (P: 8 000).
  2. **Weather map** `cloudWeather` (512², period 8192 blocks, scrolled by `clouds1.xy`):
     - R = coverage: Worley-fBm remapped by the daily coverage;
     - G = type;
     - B = precipitation darkening;
     - A = cirrus coverage.
     Rebuilt by an H1 compute only when the weather state changes.
  3. **Density** at p, with height fraction h:
     - Height gradient G(h, type) = R(h, 0, 0.08, 0, 1)·R(h, top − 0.25, top, 1, 0), top = 0.3 + 0.7·type, where
       R is the linear remap.
     - Base: n_lo = `noiseShape`(p·1/1800): a 128³ RGBA8 Perlin-Worley in R and Worley fBm in GBA; combine
       0.625R + 0.25G + 0.125B.
     - d₀ = R(n_lo·G, 1 − 0.95·cov, 1, 0, 1)·cov.
     - Erosion: n_hi = `noiseDetail`(p·1/180 + curl offset), 3-octave Worley; e = mix(n_hi, 1 − n_hi,
       saturate(10h)) (wispy bottoms, billowy tops).
     - d = R(d₀, 0.35·e, 1, 0, 1).
     - σ_t = d·σ_max, with σ_max = 0.045/block (P/B/Q) and albedo 0.99.
  4. **Primary march.**
     - N_p = 24 (P) / 32 (B) / 48 (Q) / 64 (U) steps over the clipped segment, with the step growing linearly with
       distance (×(1 + d/3000)).
     - Empty-space skipping: when the weather coverage under the ray < 0.02, take ×4 steps.
     - Start jittered by blue noise + R1.
     - Stop at T < 0.02, or at the scene depth (½-res hi-Z, the farthest surface in the 2×2 block).
  5. **Light** at each non-empty sample:
     - Optical depth τ_L from N_L = 4 (P) / 6 (Q) cone samples toward L with step lengths 6, 12, 24, 48 (+96, 192)
       blocks; the last two samples use base noise only.
     - **Multiple scattering, 4 octaves:** S = Σ_{i=0..3} a^i·σ_s·exp(−b^i·τ_L)·P(ν, c^i·g), with a = 0.55,
       b = 0.45, c = 0.5, g = 0.82.
     - Phase P(ν, g) = 0.75·HG(ν, g) + 0.25·HG(ν, −0.25·g/0.82), plus a silver-lining lobe 0.12·HG(ν, 0.97) on
       octave 0 only. Normalise HG to integrate to 1 over the sphere.
     - **Powder:** × (1 − e^{−2·σ_t·4})·(1 − 0.6·max(ν, 0)) + 0.6·max(ν, 0) (dark edges away from the sun, bright
       toward it).
     - **Ambient:** E_amb = mix(SH(−y)·0.5, SH(+y), h)·(1 − 0.5·d) × the precipitation darkening.
     - **Sun colour at the cloud:** E_sun·T_LUT(r_cloud, μ_s). Clouds stay orange after the ground has gone dim.
     - Integrate: L += T·(S·E_sun_cloud + σ_s·E_amb/4π)·(1 − e^{−σ_tΔ})/σ_t; T *= e^{−σ_tΔ}.
  6. **Aerial perspective** at the transmittance-weighted mean distance d̄ ("apparent distance"): blend toward the
     sky-view radiance along the ray with 1 − exp(−d̄/8000). This gives hazy, blue distant clouds.
  7. **Temporal reconstruction.**
     - March at **½×½ internal** resolution in a **2×2 checkerboard** (one quarter of those pixels per frame), so
       1/16 of internal pixels per frame.
     - Reproject the ½×½ history by d̄ advected by wind × dt.
     - History is valid if its reprojected position is on screen and the terrain there is not nearer than d̄;
       otherwise age = 0.
     - Pixels not marched this frame (the other 3 checkerboard slots) output the reprojected history; if it is
       invalid, they take a bilinear fill from this frame's marched neighbours.
     - The marched slot blends: out = mix(history, new, 1/min(age + 1, 12)), so new pixels converge in about 4 visits.
     - Clamp history to the 3×3 min/max only when |Δuv| > 2 px (fast turns).
     - Output: RGBA16F (scattering rgb pre-exposed, a = T) and RG16F (d̄, age).
  8. **Composite** (H6 after resume, internal res): one full-screen triangle with a bilateral 4-tap upsample of the ½×½
     result. Pixel p receives clouds if depth == 0, or if its linear distance > d̄, or if its border-fog factor > 0.7.
     Blend: dst·T + S.
- **Algorithm, SDF voxel clouds (Storybook):**
  - Source: the game's own cloud texture as loaded by `CloudRenderer` (one texel = a 12×12-block cell, slab 4 blocks
    high, or 8 in the "Chunky" option).
  - At load or resource reload, bake a 2D **signed distance field** (1024², 4 px per cell) with a corner rounding
    radius of 2 blocks.
  - **Sphere-trace** the slab: distance = max(sdf₂(x, z), |y − y_c| − h/2) − rounding, up to 32 steps, hit at
    ε = 0.05.
  - Shade the hit:
    - normal from the SDF gradient;
    - wrap-lit sun NL (w = 0.5) × a soft self-shadow from 3 SDF taps toward L;
    - ambient = SH;
    - rim = 0.3·(1 − N·V)^3·HG(ν, 0.7);
    - a 1-block soft alpha edge from the SDF;
    - AP as above.
  - Same ½×½ + checkerboard + reprojection path. Cost about 60% of the volumetric P tier.
- **Cirrus** (all styles except "off"): one sample on a curved plane at y = 1100:
  - density = cov_c·R(fBm₂(p·1/2600 + curl warp·0.3), 0.45, 1, 0, 1), stretched 4:1 along the wind;
  - lit by E_sun_cloud·HG(ν, 0.6) + SH(+y)·0.3;
  - composited behind the cumulus in the same pass (+1 fetch). Not shadowing.
- **Cloud shadows** (`cloudShadow`, 512² R8 in light space, ±512 blocks, every 2nd frame):
  - per texel: τ = Σ_layers σ_max·d(p_mid)·thickness/|L_y| with base noise only; store e^{−τ}.
  - Consumers:
    - lighting (1 bicubic fetch);
    - VL crepuscular steps (E07);
    - PCSS penumbra widening under clouds (E08);
    - water glints (E14).
- **The daily weather system (CPU, original).**
  - Day index → hashed temperature T, humidity H and wind W, smoothed across day boundaries with smoothstep. Biome
    weights bias them: hot-dry → T up, H down; cold → T down; humid → H up.
  - Coverage = 0.25 + 0.55·H + 0.35·rain, minus 0.2 if T is high and H low.
  - Type = saturate(0.2 + 0.6·H·T + 0.4·W) (towering on hot humid windy days).
  - Rain raises coverage over 60 s, so clouds visibly thicken while the vanilla rain level ramps.
  - Morning mist σ_M and haze also follow H.
  - Weather is not consistent across clients (it is cosmetic); seed it with the world seed hash if available so the
    same world looks the same every time.
- **Hook.**
  - H1: weather map, cloud shadow, env map clouds.
  - H6 (M2/M3): march, reconstruction and composite, *before* translucents, so water refracts terrain under clouds
    correctly and reflects clouds through the env map or SSR.
  - Vanilla `clouds`/`flat_clouds` are disabled through an H10 discard override, or by cancelling the cloud render.
- **Cost & tiers** (march + reconstruction + composite):

  | Tier | Style default | Res / checkerboard | Steps (primary/light) | Est. ms |
  |---|---|---|---|---|
  | P | volumetric | ½×½, 2×2 checkerboard | 24/4 | 0.30–0.45 |
  | B | volumetric | ½×½, 2×2 checkerboard | 32/4 | 0.40–0.60 |
  | Q (native) | volumetric | ½×½, 2×2 checkerboard | 48/6 | 0.70–1.10 |
  | U (native) | volumetric + towering + cirrus detail | ½×½, no checkerboard | 64/6 | 1.2–1.8 |

- **Data/deps.** `noiseShape`, `noiseDetail`, `curl2d`, `cloudWeather`, E02 LUTs, SH, the hi-Z from H6, `ShadeLook.clouds*`,
  `wind`; histories `cloudHist`.

---

### E06. Distance fog, aerial perspective, height haze, border fog

- **Look.**
  - **Complementary** is the reference for *feel*: valleys hazy and peaks clear (altitude-dependent haze); distant
    terrain dissolves into exactly the sky colour behind it; the fog glows toward the sun at dawn.
  - **Photon:** low morning ground mist and biome-tinted humidity.
  - **SEUS:** terrain haze matching the sky model.
- **Technique (original), in three physically consistent layers:**
  - (a) **planetary aerial perspective** from `apLut`;
  - (b) **local height haze and mist**, analytic, in block units;
  - (c) **border fog** to the sky-view.
- **Algorithm.**
  - **(a) AP:** L ← L·T_ap + S_ap, sampled at (screen uv, √(d/D)).
  - **(b) Local layers** k ∈ {haze R, mist M}:
    - density ρ_k(y) = exp(−max(y − y_k, 0)/H_k);
    - defaults: haze y_R = sea + 16, H_R = 48, σ_R = (0.22, 0.48, 1.0)·1.1·10⁻³/block (bluish); mist y_M = sea + 4,
      H_M = 10, σ_M from §3.2;
    - optical depth along the ray from y_c with direction component d_y over length t:
      τ_k = σ_k·H_k·(e^{−(y_c − y_k)/H_k} − e^{−(y_c + t·d_y − y_k)/H_k})/d_y for both endpoints above y_k. If the
      segment crosses y_k, split at s* = (y_k − y_c)/d_y and add σ_k·length below y_k. For |d_y| < 10⁻³ use
      σ_k·t·ρ_k(y_c + t·d_y/2).
    - **In-scatter**, for both layers:
      S = (1 − e^{−τ})·Σ_k (τ_k/τ)·[a_k·(E_sun·Φ_k(ν)·V_sun + L̄_sky)]·M_k
      - τ = Σ τ_k;
      - Φ_R = 3(1 + ν²)/16π, Φ_M = 0.8·HG(ν, 0.76) + 0.2·HG(ν, −0.2);
      - L̄_sky = the mean sky radiance from SH band 0;
      - M_k = 1/(1 − 0.5·a_k), a cheap multiple-scatter boost;
      - a_R = 1, a_M = 0.9 (0.6 in rain).
    - **V_sun:** if VL is on, the sun term is evaluated only on [min(t, D_vl), t] (VL owns the near segment, with real
      shadows). If VL is off, over [0, t] × cloud shadow at the segment midpoint.
    - **Evening glow** (art): S_M × (1 + 0.6·e^{−((e + 1°)/2.5°)²}).
  - **(c) Border fog:** f_b = smoothstep(β·R, R, ℓ₄(x, z)), with ℓ₄ = (x⁴ + z⁴)^{1/4} (chunk-shaped), R = render
    distance − 8 blocks, β = 0.78. L ← mix(L, skyView(dir with elevation clamped ≥ 0), f_b).
  - **Media fogs** from vanilla state (`ShadeFrame.fogColor.a > 0`, `flags.y`):
    - water: owned by E14/E26;
    - lava, powder snow, blindness, darkness: exponential toward a version of `fogColor` scaled to the scene by the
      ambient luminance, using vanilla's environmental start/end.
  - **Cave fog:** σ_c = `fogMisc.w`·(1 − eye sky light) toward the biome cave colour (§3.4); subtle; it gives depth
    to big caverns.
  - **Rain:** σ_M ×(1 + 7·rain), the haze turns grey (a desaturation of the σ_R colour), and the border fog starts at
    β = 0.6.
- **Hook.**
  - Inline in every lit fragment: terrain (H4), entities (H10), water (E14), the M3 lighting draw.
  - The sky pass skips (a)–(c).
  - Clouds use (a) at d̄.
  - The final pass reuses the fog amount for the fog glow (E19).
- **Cost.** ≈ 0 (≈ 30 ALU + 1 3D fetch in geometry-bound passes). All tiers. U adds a 3D noise "patchy mist" (1 fetch
  modulating ρ_M, ±40%).
- **Data/deps.** E02 (`apLut`, `skyView`, SH), `ShadeLook.fog*`, `eye`, `ShadeFrame.fogRange` (vanilla render distance).

---

### E07. Volumetric light (god rays), crepuscular rays, underwater shafts

- **Look.**
  - **Complementary** does it best: *scene-aware* shafts, strong in forests and cave mouths and subtle in open plains;
    saturated orange at sunset, blue-tinted underwater, coloured through stained glass.
  - **BSL:** dramatic at dawn and dusk.
  - **SEUS:** shimmering caustic shafts underwater.
  - **Photon:** rays *from clouds*.
- **Technique (original).** Ray-march the local fog model (E06b) with real visibility; temporal accumulation; our own
  "canopy factor".
- **Algorithm.**
  - Per ½-internal pixel:
    - D = min(linear depth, `vl.y`); `vl.y` defaults: P 160 / Q 224 blocks.
    - Samples t_i = D·((i + ξ)/N)², N = `vl.w`: P 12, B 14, Q 20, U 28.
    - At p_i: σ_s, σ_t from E06b; visibility V_i = (near cascade if inside, else far) `sample_compare` (one hardware
      2×2 tap) × `cloudShadow` × (M3) the coloured-shadow tint.
    - Camera transmittance T_i from the closed form of E06b.
    - Accumulate L += T_i·σ_s(p_i)·Φ(ν)·E_sun·V_i·(1 − e^{−σ_tΔ_i})/σ_t, with Φ = 0.85·HG(ν, g_t) + 0.15·HG(ν, −0.2)
      and g_t from 0.55 (noon) to 0.8 (golden hour).
  - **Crepuscular extension:** beyond D (or beyond the cascade range for sky pixels), add 4 (P) / 8 (Q) sparse steps
    to 1500 blocks that sample **only** `cloudShadow` with the haze density. This gives rays fanning from cloud gaps,
    independent of terrain shadows.
  - **Strength** = `vl.x` (keyframes) × (0.6 + 0.8·canopy) × (1 − 0.6·rain) × the sun/moon crossfade. Moon shafts are
    at 0.3× with the moon key.
  - **Canopy factor (original).** An H1 kernel, 64 threads, samples the far cascade at 64 points on two rings
    (radius 6 and 14 blocks) at eye + 3 and eye + 10 blocks. f = fraction shadowed; target = smoothstep(0.15, 0.6, f);
    integrated with τ = 4 s into `ShadeGpu.scene.y`.
    - Open plains → about 0 (subtle haze).
    - Forest or cave mouth → about 1 (strong shafts, denser near-field mist via σ_M ×(1 + 0.8·canopy)).
  - **Underwater:**
    - σ from the water medium (E14);
    - sun irradiance E_sun·T_water(y_surface − p.y)·caustic(p) from the `caustics` array, using `water.w` as the
      surface height;
    - N +4;
    - D = min(depth, 48).
  - **Temporal:** reproject with linear depth; history weight 0.88 (P) / 0.9 (Q); clamp to the 3×3 YCoCg min/max of the
    current ½-res frame.
  - **Upsample and composite** (H7 composite, internal res): 4 nearest ½-res taps with bilinear × exp(−|Δz|/(0.03z))
    weights; add to sceneHDR.
- **Hook.** H7 (needs the world depth; runs before the hand).
- **Cost & tiers.** Measured 16 taps at ½ res: 0.32 ms at 0.5x, 0.47 ms at 0.67x, 0.80 ms at native.

  | Tier | Taps + crepuscular | Est. ms |
  |---|---|---|
  | P | 12 + 4 | 0.38–0.45 |
  | B | 14 + 4 | 0.45–0.55 |
  | Q (native) | 20 + 8 | 0.95–1.15 |
  | U (native) | 28 + 8 | 1.3–1.5 |

  Off in the Nether. The End uses the beam density (E25).
- **Data/deps.** Shadow array (M1), `cloudShadow`, `caustics`, E06 parameters, `ShadeGpu.scene.y`, `vlHist`, world depth
  from H7.

---

### E08. Shadows: filtering, coloured glass, foliage, entities, RT

- **Look.**
  - **Photon:** PCSS that is crisp at contact and soft with distance, sharpened so tiny penumbrae stay hard, and
    softer under clouds (overcast mood).
  - **SEUS:** disc-shaped penumbrae with no "target rings", coloured stained-glass shadows, water caustic shadows.
  - **BSL:** clean, readable shadows that never shimmer.
- **Technique (original), on top of M1.** Receiver normal offset (M1's `shade_shadow_offset`) + slope-scaled raster bias
  (M1). **Never** use Complementary's block-centre pull or Photon's Complementary-derived bias function (§8).
- **Algorithm.**
  - **PCSS-lite (M1 polish / M2), near cascade (far cascade: fixed 2-texel PCF):**
    1. **Blocker search:** 2 `gather` calls on the depth slice (8 depths) within a radius r_s = tan(θ_s)·16 blocks
       (θ_s = art sun radius, 0.6° Epic) converted to texels. z̄_b = mean of the depths nearer to the light than the
       receiver; if none, lit (early out).
    2. **Penumbra** in blocks: w = (z_r − z̄_b)·tan(θ_s)·(5 − 4·cloudShadow) (overcast widening), clamped to
       [0.5 texel, r_s].
    3. **Filter:** N_f Vogel-disc taps (P 8, B 12, Q 16) of radius w, rotated by 2π·(IGN(px) + R1(frame)). Each tap is
       a hardware 2×2 `sample_compare`, so there are no rings and TAAU resolves the rotation.
    4. **Contact sharpening:** s′ = saturate((s − ½)·k + ½) with k = clamp(2·texel/w, 1, 3).
    5. **Thickness** for SSS: t_th = max(z_r − z̄_b, 0) in blocks, exported to E09.
  - **Leak gate:** direct light × smoothstep(0.08, 0.40, sky light) (E09). Vanilla sky light 0 never gets sun, even
    where the cascade misses an occluder.
  - **Far edge:** beyond the far cascade, fade to a fake visibility smoothstep(0.75, 0.95, sky light) × cloud shadow,
    over the last 12% of the cascade.
  - **Foliage:** pass the light-facing normal (two-sided). Leaves get w ×1.5 and a per-tap depth jitter of up to
    0.25 block, which lets light leak a little into canopies.
  - **Coloured translucent shadows (M3):**
    - The shadow pass gets a second pipeline group for translucent casters (classes 20, 24–29) drawn into the
      **near** cascade only:
      - colour target `shadowTint` RGBA8, cleared white, multiply blend of the transmittance tint:
        glass (0.92 grey), stained glass (albedo²·(1 − α) + α·albedo), water (absorption over 1 block × the caustics
        factor);
      - `shadowTDepth` R16Unorm with a max blend (the translucent caster nearest to the light, reversed-Z);
      - depth test against the opaque cascade without depth write.
    - Receiver: V_rgb = V_opaque × (z_r < z_t ? tint : 1). One extra fetch pair, only when V_opaque > 0 (a cheap
      branch).
    - Caustics: water casters write the caustic sample at the caster's (x, z) instead of a flat tint, so floors and
      walls under water get light ripples.
  - **Entity shadows (M3):** entities have no data in the cascade pass.
    - During the main pass, mcopt **records** the entity draws (vertex slices + pipelines), as `MetalTerrain.record`
      does for terrain.
    - Next frame's H2 **replays** them, depth-only, into `entityShadow` (1024², ±24 blocks around the player, sun
      frustum).
    - Receivers multiply by one 4-tap PCF of it.
    - One frame of latency (8 ms) is invisible except on very fast motion.
  - **RT (M4):**
    - One any-hit ray per pixel inside the lighting draw, direction jittered within the cone θ_s (blue noise + R1),
      TLAS of section BLASes plus a leaf intersection function (apple-gpu §4).
    - Contact-hardening is natural.
    - Coloured shadows through an intersection function that multiplies the glass tint into the payload.
    - The cascades remain only for VL (the far cascade, cached) and for SSS thickness. RT gives thickness with a
      second short ray.
- **Hook.** H2 (cascades, translucent group, entity replay); receivers in H4/H10/M3 lighting/E14.
- **Cost & tiers.**

  | Tier | Map | Filter | Coloured | Entities | Est. ms |
  |---|---|---|---|---|---|
  | P | 2×2048², near ±32 every frame, far ±128 every 4 frames | 8 taps | M3: on | M3: on | 0.7–1.0 (meas. class) |
  | B | same | 12 | on | on | 0.75–1.05 |
  | Q | near 2048² ±40, far ±160 every 3 frames | 16 | on | on | 0.9–1.3 |
  | U (M4) | inline RT + far cascade for VL | cone ray | on | BLAS | 0.05–0.3 inline + about 0.3 VL map |

  Filter taps are hidden in the geometry-bound pass (apple-gpu §2.1).
- **Data/deps.** M1 shadow contract; `cloudShadow`; material classes (translucent casters, foliage); `ShadeLook.sunGeom.y`.

---

### E09. Lighting model: sun, sky, block light, AO, bounce, GI tiers

- **Look.**
  - Complementary's warm/cool storytelling and "never clips, never flat" readability;
  - BSL's sky-light-squared gating, so caves are honest;
  - Photon's SH sky ambient along bent normals plus a warm bounce in shadows;
  - SEUS's honest HDR (sun ≫ sky ≫ torch).
- **Technique (original),** one function `shade_light()` shared by forward (M2) and TBDR (M3). Lights add physically in
  linear HDR. Complementary's quadrature combine is deliberately *not* used: with physical light ratios and our
  tonemapper, a torch in sunlight is naturally negligible.
- **Algorithm.** The symbols:

  | Symbol | Meaning |
  |---|---|
  | A | linear albedo (atlas × vertex tint) |
  | α_v | vanilla AO from the vertex alpha (E10; leaves 1) |
  | N_g | geometric normal (quad corners) |
  | N | shading normal (= N_g unless water, puddle or labPBR) |
  | b, k | block and sky light in [0, 1] |
  | S | E08 visibility (rgb) |
  | C | cloud shadow |
  | AO_g | GTAO (E10) |
  | B | bent normal |
  | E_L | `sunArt` (the moon at night) |
  | x_c | crossfade factor |

  1. **Sky access:** g = k^2.2. **Direct gate:** G_d = smoothstep(0.08, 0.40, k).
  2. **Direct diffuse:** W = saturate((N·L + 0.2)/1.2). Foliage W_f = 0.45 + 0.55·|N·L|.
     D = E_L·W·S·C·G_d·α_v^0.5·x_c.
  3. **Sky ambient:**
     - E_sky = SH_irr(B, aperture) × `ambientArt` × g.
     - The visibility cone is sin²(aperture) = AO_amb (zonal-harmonic cone convolution of the SH, as in the GTAO paper).
     - AO_amb = multibounce(min(α_v^1.5, AO_g), A) with the published GTAO multi-bounce fit:
       AO′ = max(AO, ((a·AO + b)·AO + c)·AO), where a = 2.0404ρ − 0.3324, b = −4.7951ρ + 0.6417,
       c = 2.7552ρ + 0.6903 and ρ = luma(A).
  4. **Ground bounce (fake one-bounce GI):** E_bnc = E_L·max(L_y, 0)·ρ_ground·(0.5 − 0.5·N_y)·g·AO_amb·
     `ambientArt.w`, with ρ_ground = `bounce.rgb` (biome: grass green, sand warm, snow white).
     - **Shadow warm fill:** + E_L·0.035·(1 − luma(S))·g²·AO_amb (shadows stay alive).
  5. **Block light:**
     - E_blk = K(T)·F(b)·mix(α_v^1.5, 1, b⁴), with **F(b) = 2.2·b⁷ + 0.55·b^2.4** (hot core next to the source,
       broad tail: F(1) = 2.75, F(0.5) ≈ 0.12).
     - K(T) from `blackbody` at 2700 K (Epic) / 2500 K (Storybook) / 2900 K (Natural), normalised to luma 1.
     - × (1 − 0.25·smoothstep(0.5, 1, k)·day) (gentle daytime fade).
     - M3: hue from the LPV (E11).
  6. **Hand light:** E_hand = `heldLight.rgb`·1/(1 + (d/r)²)·smoothstep(3r, 0, d), with d = |P − eye|.
     E_blk ← E_blk + E_hand·(1 − 0.5·F(b)/2.75).
  7. **Minimum light:** E_min = `bounce.w`·(1 − g)·(0.62, 0.70, 0.95). Night vision adds 0.6·(0.9, 0.95, 1.0).
  8. **Emission:** L_e = mix(A, A/max(A), 0.5)·e·8·classGain, with e from the params alpha (E12). Emissive texels
     ignore AO and the face term.
  9. **SSS** (classes 7, 10–16):
     - T_sss = exp(−σ·t_th), σ = 2.5·(1.2 − luma(A)) (thin bright leaves glow more).
     - L_sss = E_L·G_d·C·x_c·A·√(A/luma(A))·T_sss·(0.35·4π·HG(−V·L, 0.6) + 0.15)·sss.
     - **Sheen rim:** + E_L·S·0.25·(1 − |N·V|)⁴·4π·HG(−V·L, 0.4)·sss (grass edges flare toward the sun).
  10. **Specular:**
      - GGX, r = (1 − s)², α = r².
      - **Sphere-light normalisation** for the sun (Karis 2013, "representative point": α′ = saturate(α + θ_s/2),
        energy × (α/α′)²).
      - Height-correlated Smith visibility.
      - Fresnel: Schlick with f0 from the params, or conductor (n, k) for labPBR metal ids 230–237 (published optical
        constants; f0/f82 form, Hoffman 2019).
      - Spec_dir = E_L·S·C·G_d·x_c·N·L·D·Vis·F, soft-clamped x/(1 + x/24).
      - **Environment:** L_env = envMap(R, mip = 4r)·(f0·A_e + B_e) (the published analytic split-sum fit) ×
        specOcc × g². specOcc = saturate((N·V + AO)^{2^{−16r−1}} − 1 + AO) (Lagarde 2014).
  11. **Compose:**
      L = A·(1 − metal)·(D + E_sky + E_bnc + E_blk + E_min)·Face(N) + Spec_dir + L_env + L_sss + L_e, with the
      readability term Face(N) = 1 − 0.06·|N_x|·(1 − |N_y|).
  12. **Fog/AP** (E06) → × exposure → write.
- **GI tiers.**
  - **P/B:** SH sky + bounce fill (above).
  - **Q (M3):** + LPV coloured block light (E11) + optional GTAO-modulated "near-field bounce": albedo-weighted SH
    lift in concave corners, 0 cost.
  - **U (M4):** RT diffuse GI with a voxel radiance cache (§E09-U).
- **§E09-U, RT GI (M4 Ultra, optional).**
  - Voxel radiance cache 128³ RG11B10F around the camera, filled from CPU block data (as LPV, E11).
  - Each frame, 32k cells trace 1 hardware RT ray (cosine), add sky/sun/emission at the hit, and EMA-blend (α 0.05).
    That is an infinite-bounce feedback, energy-clamped so albedo^n ≤ 0.8.
  - Per pixel: 1 ray at ½ internal; at a hit, look up the cache plus sun visibility; on a miss, the env map.
  - Then temporal (variance-guided α) + 3 à-trous iterations with luminance-normalised weights + bilateral upsample.
  - These are SEGI (MIT) and SVGF (public) ideas; SEGI's temporal and bilateral passes may be adapted (§8).
  - Est. 1.0–1.8 ms (seus.md §18).
- **Hook.** `shade_light.metal` included by H4, H10, E14 and the M3 lighting draw.
- **Cost.** +0.10–0.30 ms at 0.67x over the geometry-bound pass (P), +0.2–0.4 at native (Q).
- **Data/deps.** E02 (SH, sunAtCamera, envMap), E08, E10, E11, E12 params, `ShadeLook` (`sunArt`, `ambientArt`,
  `bounce`, `heldLight`, `eye`).

---
### E10. Ambient occlusion: vanilla AO separation, GTAO, RTAO

- **Look.**
  - **Complementary:** AO is *re-curved by light*, deeper on bright sunlit tops, which gives contact contrast at noon.
  - **BSL:** vanilla AO squared plus SSAO without edge halos.
  - **Photon:** GTAO with bent normals feeding the sky light (soft, directional occlusion).
- **Technique.**
  - (1) Separate Sodium's baked AO from the colour (H12 mixin).
  - (2) GTAO from the public paper (Jimenez et al., *Practical Real-Time Strategies for Accurate Indirect Occlusion*,
    2016), our own implementation. Photon's MIT `gtao.glsl` may be adapted (§8).
  - (3) RTAO in M4 U.
- **Algorithm.**
  - **AO separation (M2):**
    - Mixin into Sodium 0.9.3's quad colour write for the solid and cutout passes: rgb = biome tint (face shade is
      already off from M1), alpha = AO (0..255).
    - Translucent quads keep their baked behaviour.
    - Shader: α_v = color.a (1 when the toggle is off).
    - Re-implement the idea; Iris's `separateAo` mixins are LGPL and are reference only. Verify where Sodium 0.9.3
      multiplies brightness into ABGR before writing the mixin.
  - **Light-curved vanilla AO** (inside E09): direct × α_v^0.5; ambient × α_v^1.5. Strong light therefore shows
    stronger *relative* contact darkening, because the ambient share is curved harder than the direct share.
  - **GTAO** (½ internal, at H7 from `depthCopy`, i.e. opaque only):
    - P: 1 slice × 3 steps per side with temporal slice rotation (R1).
    - Q: 2 slices × 4 steps.
    - World radius 1.75 blocks → screen radius r = 1.75·P₁₁·h/(2z), clamped ≤ 48 px at ½ res.
    - Thickness heuristic: a horizon sample that rises more than 1.5 blocks above the receiver is clamped, so thin
      fences don't over-occlude.
    - Normals from depth derivatives (the smaller of the left/right and up/down differences); in M3 from the stored
      octahedral normal.
    - Outputs AO and the bent normal (oct).
    - Temporal: reproject, α = 0.15 (P) / 0.12 (Q), depth-reject if |Δz| > 3% of z; store (AO, bent.xy, linear z) in
      `aoHist`.
  - **Consumption:** the forward lighting runs *before* this frame's GTAO, so lighting samples **last frame's**
    `aoHist` at prevUV(P) (`ShadeLook.prevViewProjNoJitter`), with a depth check; on failure AO = 1. Photon already
    proves that one frame of latency is invisible for a 10-frame-accumulated AO.
  - **RTAO (M4 U):** 1 ray per ½-res pixel, 2 blocks, cosine distribution, the same temporal path (meas. 0.60 ms at 0.5x
    full res; ½-res ≈ 0.3–0.4).
- **Hook.** H12 (mixin), H7 (GTAO), E09 (consumption).
- **Cost & tiers.**
  - P: GTAO 1×3 at ½ = 0.10–0.14 ms.
  - B: 2×3 = 0.14–0.18.
  - Q (native ½): 2×4 = 0.30–0.38.
  - U: RTAO 0.35–0.5.
  - Measured anchor: 8-sample SSAO at ½ costs 0.16 / 0.36 ms at 0.67x / native.
- **Data/deps.** `depthCopy` (H6), `aoHist`, `ShadeLook.prevViewProjNoJitter`, the Sodium mixin.

---

### E11. Emissives, block-light colour, coloured light volume

- **Look.**
  - **Complementary:** only the flame or bright pixels of an emissive texture glow; distant torches become soft dots;
    "ACT" coloured light is the feature Mac users miss most.
  - **SEUS:** Kelvin-warm torchlight, warm caves.
  - **Photon:** emission masked by hue and lightness.
  - On Metal we *can* do coloured light (compute + 3D textures), which makes it a headline feature.
- **Technique (original).** Emission is baked per texel into the params atlas alpha (E12) by class rules. Block-light
  colour comes from a blackbody (Kelvin). The **coloured light volume** (M3) is a flood fill, a generic technique; Photon's
  MIT `lpv/*` may be adapted.
- **Algorithm.**
  - **Emission rules at stitch time** (per texel, linear luminance Y and HSV of the albedo; e ∈ [0, 1] →
    labPBR A = 254·e):
    - Flame (32/33): e = smoothstep(0.55, 0.85, Y)^1.5.
    - Lamps (34/35): e = 0.35 + 0.65·smoothstep(0.35, 0.8, Y).
    - Redstone (36): e = smoothstep(0.35, 0.6, red-dominance)·smoothstep(0.25, 0.6, V).
    - Magma (37): hue ∈ [15°, 45°]·smoothstep(0.4, 0.8, V).
    - Froglight (38): 0.9.
    - Bio-glow (39): e = smoothstep(0.5, 0.9, S·V) (bright saturated texels only).
    - Glowing ores (40, option): e = smoothstep(0.12, 0.35, |c − c_border|), with c_border = the mean of the sprite's
      outer ring.
    - Lava (21): e = 0.6 + 0.4·Y.
  - **Kelvin palette (art):** flame 2000 K, soul 9000 K ×(0.6, 1.0, 1.1), warm lamp 3000 K, cool lamp 7500 K
    ×(0.85, 1.0, 1.1), redstone (1.0, 0.18, 0.12), lava/magma 1700 K, froglights from the sprite's average colour.
    The default block-light colour for vanilla light levels is 2700 K (E09).
  - **Distant emissives:** beyond 48 blocks, the emissive sample uses mip bias +2, so lights don't sparkle; TAAU +
    bloom turn them into soft glows. There is no extra pass.
  - **Coloured light volume (M3, Q/U; B optional):**
    - `lpv` is 2 × 128×64×128 RG11B10F (4 MB each), camera-centred, scrolled in 16-block steps.
    - **Sources come from the CPU**, not voxelised from meshes: on section load or change, scan the `LevelChunkSection`
      palette (skip sections without emissive or tinted states) and write an R8Uint id per voxel:
      0 air, 1 opaque (the state occludes light), 2..63 = light colour index (block light level packed in 4 bits),
      64..127 = translucent tint index.
    - Upload the changed sections' 4 KB slices into an R8Uint 128×64×128 `lpvIds`.
    - **GPU flood fill**, 2 iterations per frame over a checkerboard half:
      L′(v) = 0 if opaque; else max(Σ₆ L(n)/6.2·tint(v), emitter(v)), where emitter = colour × level/15. The "max"
      keeps sources sharp; the loss of 0.2/6.2 per step bounds the range to about 15 blocks like vanilla.
    - Shading: sample at P + 0.5·N_g (trilinear) → hue h = L/max(luma(L), ε). E_blk keeps **vanilla's lightmap
      intensity** (stable, correct occlusion) and takes the **hue** from the volume:
      E_blk = F(b)·mix(K(2700 K), h, 0.85·saturate(luma(L)·4)).
    - Optional **coloured light fog** (U): 8 steps at ½ res in the VL pass adding σ_s·L_lpv.
- **Hook.** H11 (emission bake); H1 (LPV ids upload + flood fill); E09/E19.
- **Cost & tiers.**
  - Emission: 0.
  - LPV (M3): flood fill ≈ 0.10–0.20 ms/frame (2 × 1M voxels × 7 taps, cache-friendly), shading 1 fetch, upload ≤ 0.02 ms
    on change.
  - B: off by default; Q: on; U: on + light fog (+0.1).
- **Data/deps.** E12 params atlas, `blackbody`, `lpv`, section-change events (`ClientLevel`/Sodium section rebuild
  callbacks).

---

### E12. Materials: baked IPBR atlas, specular, labPBR, glints

- **Look.** Complementary's IPBR makes metals shine, stone faintly sheen and ores glow **with no resource pack**, which is
  a big part of the "expensive" feel. BSL and Photon support labPBR when present.
- **Technique (original).** A heuristic material bake from vanilla albedo at atlas stitch time, on the CPU in Java,
  using our own rules, written in labPBR `_s` encoding so labPBR packs replace it per sprite. labPBR 1.3 itself is a
  public community format spec.
- **Algorithm.**
  - **Smoothness rules** (s ∈ [0, 1]; Y = linear luminance, σ_Y = sprite luminance std):
    - default 0.12;
    - rough mineral 0.10 + 0.25·Y²;
    - polished 0.45 + 0.25·Y;
    - wood 0.18;
    - metal 0.55 + 0.35·Y (the darkest texels 0.3);
    - gem 0.80;
    - granular 0.05;
    - snow 0.30;
    - opaque ice 0.85;
    - fabric 0.02;
    - leaves 0.35;
    - plants 0.25;
    - grass-top 0.15.
    - High-contrast sprites (σ_Y > 0.2) get −0.1 (cracks look rough).
  - **f0:** default 0.04 (G = 10). Metals use hard-coded ids: iron 230, gold 231, copper 234 (oxidised copper:
    dielectric f0 0.04, with the patina smoother). Polished 0.045, gem 0.06.
  - **Porosity/SSS (B):** granular 50, wood 30, stone 35, fabric 60 (porosity drives wet darkening, E13); leaves 200,
    plants 170, snow 120 (SSS amount, E09).
  - **Emission (A):** E11 rules.
  - **Glint bit** (mask bit 7) for snow, sand and gems:
    - per-texel hash h(texel, block position) > 0.985 → that texel gets a perturbed microfacet normal (hash direction
      within 25°) and s = 0.97;
    - in sunlight this produces sparkles that are stable under TAAU (fixed in texel space).
  - **labPBR (M3, optional):** at H11, for every sprite also try `<name>_s.png` and `<name>_n.png` from the resource
    manager and stitch them into same-layout atlases; per-sprite precedence over the bake.
    - Normal: RG = xy, B = AO, A = height. TBN from the quad corners: T = normalize(Δp₁·Δv₂ − Δp₂·Δv₁)/det, N = N_g.
    - Normals fade to flat by mip level (the UV-derivative mip estimate) to stop distant sparkle.
    - **POM (U only):** 16–32 steps within 24 blocks in a **separate pipeline drawn after normal opaque terrain**,
      because depth writes defeat hidden-surface removal (apple-gpu §1.2).
  - **Reflections on opaque:** for s ≥ 0.75 or metals, plus puddles (E13), Q/U add SSR exactly as for water (E14) at
    ½ res; P/B use env map reflections only.
- **Hook.** H11 (bake), E09 (consumption), H4 (one `matParams` fetch at the same uv as the albedo, nearest filter;
  mips built with an average of s and f0 and a max of e).
- **Cost.** Bake: ≈ 30–80 ms CPU at reload (vanilla atlas), off-thread. Runtime: 1 RGBA8 fetch (+1 for labPBR normals,
  +0.1–0.3 ms at 0.67x in a geometry-bound pass, apple-gpu "heavier material" row).
- **Data/deps.** `matClass`, `matParams`, (`labNormal`), E09/E13/E14.

---

### E13. Rain, wetness, puddles, ripples, snow

- **Look.**
  - **SEUS:** wet, darkened materials, ripples, rain fog, a desaturated sun.
  - **BSL:** puddles with expanding ripple rings, per-biome rain tints.
  - **Photon:** puddles only outdoors on up-facing surfaces; slanted, tinted rain streaks.
- **Technique (original).**
- **Algorithm.**
  - **Wet mask:** ω = `wet.x`·smoothstep(0.85, 0.97, k)·(no block light > 0.5)·(1 − biome cold/dry suppress) (snow
    biomes get frost instead; deserts get none).
  - **Wet darkening:** A ← A^(1 + 0.6·ω·porosity) (porous materials darken). s ← mix(s, 0.85, ω·(1 − porosity)·0.6).
  - **Puddles** (up-facing, N_g.y > 0.99, classes 1, 2, 6, 17):
    - mask P = smoothstep(0.55, 0.65, fBm₂(xz/14)·0.7 + 0.3·n(xz/3)) × `wet.y`;
    - in a puddle: s = 0.96, f0 = 0.02, N = ripple normal, albedo ×0.8.
  - **Ripples:**
    - Hashed rotated grid cells of 1.2 blocks, 2 offset grids.
    - Per cell: drop time t₀ = hash·period (period 1.1 s), position jitter, radius ρ = (t − t₀)·0.9.
    - Profile h = sin(14·(d − ρ))·e^{−6(t − t₀)}·smoothstep(ρ + 0.15, ρ, d).
    - Normal from analytic derivatives, scaled by rain intensity.
    - Also applied to water surfaces under open sky (E14).
  - **Rain streaks** (`weather` pipeline override, H10):
    - lit by E09's ambient + block light + 0.25·sun;
    - alpha ∝ intensity (0.18–0.35);
    - a slight refraction look: brighten the streak by 0.3·luma(sceneCopy at the offset), i.e. the bright background
      shows through;
    - lean along the wind (vertex shear 0.2·`wind.xy`);
    - writes `reactive` = 0.8.
  - **Snow particles:** alpha 0.6, lit, sparkle off.
  - **Snow cover (option):** up-facing grass/leaves/plants get `wet.z`·smoothstep(0.9, 1, N_y) blend toward snow albedo
    (0.92) + glint.
  - **Rain atmosphere** (via E01/E06): σ_M ↑, haze grey, sky desaturated, shadows softened by cloud cover (E08 w ×),
    bloom +0.03, VL ×0.4.
  - **Lightning:** vanilla bolt entity / sky flash → `ShadeLook.flash` = a direction toward the bolt with an intensity
    envelope. While active it adds a cold directional light (no shadows) and lights cloud bellies (cloud ambient
    ×(1 + 4·flash)).
- **Hook.** H4/E09 (wetness, puddles), H10 (weather), E14 (ripples), H1 (`wet` from the CPU).
- **Cost.** About 0.02–0.06 ms (ALU only where ω > 0). All tiers. Puddle reflections are env-map-only in P/B and SSR in Q/U.
- **Data/deps.** `ShadeLook.wet/wind/flash`, E12 porosity, classes.

---

### E14. Water: waves, reflection, refraction, absorption, caustics, foam, underwater

- **Look.**
  - **Photon:** nearly invisible glassy surface, colour from absorption, the biome water colour turned into absorption.
  - **SEUS:** physical cyan absorption with depth, wave-aware Fresnel, animated depth-layered caustics, underwater
    shafts.
  - **BSL:** normals flattening at grazing angles (a calm horizon), strong distant mirror.
  - **Unbound:** sun glitter.
  - **Reimagined:** pixel-respecting ripples (Storybook).
- **Technique (original).**
  - Waves from a **load-time Tessendorf FFT bake** (public 2001 paper), looped in time.
  - Caustics baked from **the same height field** (SEUS's published idea; our implementation).
  - SSR sampling **last frame's TAAU output** (the technique Photon uses; generic). Photon's MIT `water_normal.glsl` is
    adaptable, but not needed.
- **Algorithm.**
  - **FFT bake** (H11/load, CPU Java or GPU compute):
    - Phillips spectrum, wind 3.5 m/s along +x, tile L = 8 blocks, grid 128².
    - Frequencies quantised ω_q = (2π/T)·round(ωT/2π) with **loop T = 8 s**.
    - 64 frames → `waterWaves` RGBA8: (∂h/∂x, ∂h/∂z) ×0.5 + 0.5 scaled by the max slope, h, Jacobian J (for crest
      foam).
  - **Caustics bake:**
    - For each frame, refract a 512² grid of sun rays (n = 1.333) through the surface and splat the photon density onto
      receiver planes at depths 0.5, 1.5, 3 and 6 blocks.
    - Equivalent analytic form: intensity = 1/|det J_refract|, clamped to [0, 4]; blur 1 px.
    - Store 4 depths in the RGBA channels of `caustics` (128²×64).
  - **Surface normal** (water fragment, camera-relative position P, absolute xz):
    - Two octaves: o₁ at xz/8 (0°), o₂ at xz/2.7 (rotated 37°, time ×1.3). Frame = t·8 mod 64, interpolated between 2
      layers.
    - Slope = o₁ + 0.45·o₂, amplitude `water.x` (0.06) × (1 + 2·rain + 1.5·windiness) × g² (calm indoors).
    - Flowing water: advect along the flow direction, taken from the flow sprite's UV orientation (corner fetch) ×
      speed 1.2 blocks/s.
    - **Distance and grazing flatten:** amp × e^{−d/96}; N = normalize(mix(N_w, N_g, 0.7·(1 − N·V)^4)).
    - Parallax: 2 steps (Q: 4) on h.
    - **Storybook:** quantise the sample position to 1/16 block → pixel ripples, plus vanilla water texture luminance
      streaks as highlights.
    - Rain ripples (E13) are added under open sky.
  - **Fresnel:** exact dielectric for n = 1.333 (s and p polarisation averaged). Wave-aware F_eff = mix(F(N), F(N_g),
    0.5·(1 − e^{−d/64})). Underwater-looking-up uses the n = 1/1.333 branch with total internal reflection.
  - **Reflection:**
    - **SSR in the water fragment:** Hi-Z march on `hiZ` (max-depth pyramid, reversed-Z), starting 0.2 blocks off the
      surface; 16 (P) / 24 (Q) iterations + 4 binary refinements; thickness 0.6·(1 + d/64) blocks; screen-edge fade 8%.
    - **Colour = `taaPrev`** at the hit reprojected by `prevViewProjNoJitter` × exposure ratio. This already contains
      clouds, VL, translucents and fog.
    - **Miss / fallback:** envMap(R, mip from roughness) × g⁴ (no sky reflections under roofs) + **sun glint**: GGX
      with r = 0.02 + 0.08·(1 − e^{−d/48}) (roughness grows as normals average out, so distant water shows long glitter
      roads) × S × C, soft-clamped.
    - **M4:** 1 RT ray per water pixel (closest hit, hit shading from E09-lite + a shadow ray), measured cheaper than
      24-step SSR.
  - **Refraction:**
    - uv_r = uv + N_view.xy·0.05·min(Δd, 4)/max(z, 1), where Δd = the floor distance − the surface distance from
      `depthCopy`.
    - If `depthCopy(uv_r)` is nearer than the surface, uv_r = uv.
    - Floor colour F = sceneCopy(uv_r).
  - **Absorption and body colour:**
    - σ_a = σ_pure + 0.25·max(−ln(tint/tint_ref), 0), with σ_pure = (0.32, 0.06, 0.03)/block (art-scaled near pure
      water), tint = the biome water colour from the vertex colour, tint_ref = the vanilla default water colour
      (linear). Swamps go greener and murkier; warm oceans go clearer and more cyan.
    - σ_s = 0.012·(1 + 2·swamp).
    - Path ℓ = |P_floor − P_surface| (refracted).
    - T = e^{−(σ_a + σ_s)ℓ}.
    - L_in = (1 − T)·(σ_s/σ_t)·(E_L·S·4π·HG(ν, 0.4)·0.5 + E_sky·g + E_blk).
    - **Caustics on the floor** (M2 approximation inside the water shader):
      F ← F·(1 + (caus(xz_floor − L.xz/L.y·Δy, depth Δy) − 0.5)·1.2·e^{−Δy/6}·S_surface). M3 does it properly in the
      lighting via the coloured shadow pass.
    - Body: L_t = F·T + L_in.
  - **Foam:** shore f = (1 − smoothstep(0, 0.4 + 0.3·n, Δy_vertical))·0.55; crest foam where J < 0.35 on windy or rain
    days (open water only); foam is lit diffuse white and cuts reflection.
  - **Compose:** L = mix(L_t, L_refl, F_eff)·(1 − f) + f·L_foam + glint. Write **alpha = 1** (the shader composited what
    is behind itself). Write `tint` = T (for VL and rain behind water) and `reactive` = 0.25 (animated normals).
- **Underwater view:** see E26.
- **Hook.** H6 (after the copies and the cloud composite), via the `sodium:pipeline/translucent_terrain` fragment variant
  that branches on class 20.
- **Cost & tiers.** Forward water on 20–40% of pixels (est.) + SSR (meas. class: 30% rows × 24 steps already in apple-gpu
  frame numbers).

  | Tier | Waves | SSR | Parallax | Caustics | Est. ms |
  |---|---|---|---|---|---|
  | P | 2 octaves | 16 + 4 | 0 | floor approximation | 0.45–0.75 |
  | B | 2 | 20 + 4 | 2 | same | 0.55–0.85 |
  | Q (native) | 2 + detail | 24 + 4 | 4 | + M3 shadow-pass caustics | 1.0–1.6 |
  | U (M4) | same | RT ray | 4 | same | 0.9–1.4 |

  Zero when no water is visible.
- **Data/deps.** `waterWaves`, `caustics`, `sceneCopy`, `depthCopy`, `hiZ`, `taaPrev`, `envMap`, SH, E08 shadow, E06 fog,
  `ShadeLook.water/waterAbs/wind`; histories `taaHist`.

---

### E15. Glass, ice, slime, portals and other translucents

- **Look.**
  - **Complementary:** distant glass becomes more reflective and opaque, like real windows; stained glass tints light.
  - **SEUS:** "proper deferred + forward" translucents with no sorting glitches.
- **Technique (original).** Same translucent override as water, branching on class.
- **Algorithm.**
  - Clear glass (24): n = 1.5; F as for water; reflection env (+SSR in Q); transmission tint (0.94, 0.97, 1.0); slight
    refraction (×0.3 of water's); keep the texture's frame/streak pixels (texel alpha > 0.5) lit opaque.
  - Stained (25): tint τ = albedo^(2/|N·V|) (thicker at grazing); its own lit albedo where texel alpha > 0.6.
  - Ice (26): refraction ×0.8 of water's, tint (0.85, 0.93, 1.0), faint SSS glow under sun.
  - Slime/honey (27): tint = albedo², refraction ×0.5.
  - Tinted glass (29): τ = 0.15.
  - Portal (28): **parallax swirl**: 6 layers sampled from the portal sprite at depths 0.15·i along V (tangent space),
    each rotated by t·(0.2 + 0.07i) around the block-face centre, summed with weights 0.7^i; emission (0.55, 0.25, 1.0)
    ×6; reactive = 1.
  - All write `tint` (multiply in the side image) and are composited with alpha 1 over `sceneCopy` like water. Water
    behind glass is still correct, because glass reads `sceneCopy` and the water was drawn into the target. Keep vanilla
    draw order (Sodium sorts translucents).
- **Hook.** H6 translucent fragment variant.
- **Cost.** Included in E14's translucent pass (≈ 0.05–0.15 ms extra when glass fills the screen).
- **Data/deps.** As E14.

---

### E16. Waving foliage and living blocks

- **Look.**
  - **Photon:** gusty wind with wobble, plants bending away from the player, shadows that wave too.
  - **BSL:** lanterns swing, lily pads bob, grass bends as you walk.
  - **Complementary:** gentle, top-vertices-only motion, never indoors.
- **Technique (original).**
- **Algorithm** (vertex stage of the **cutout** pipelines only, so solid terrain pays nothing):
  - Material class from `matClass` at the vertex uv; one R8Uint fetch per cutout vertex.
  - **Weight w** from the corner fetch: w = (y − y_min,quad)/(y_max,quad − y_min,quad) for classes 11/13 (top vertices
    move); class 12 adds 1 if bit 6 (upper half); leaves w = 1.
  - **Wind:**
    - gust γ = (0.5 + 0.5·n₂(xz/40 − `wind.xy`·t·`wind.z`·0.2))²·`wind.w`;
    - wobble ω = 0.6·sin(1.9t + φ) + 0.3·sin(3.7t + 1.3φ) + 0.15·sin(7.1t + 2.1φ), φ = dot(P_abs, (0.37, 0.11, 0.53))·6.
  - **Displacement:** Δ = (`wind.xy`·γ + ω·(0.5, 0, 0.4))·amp·w·g²_v, with g_v = the vertex sky light (none indoors),
    × (0.4 + 0.6·windiness) × (1 + rain). amp: short plant 0.12, tall 0.18, crop 0.07, leaves 0.035 (3D:
    ω·(0.6, 0.25, 0.5)), hanging 0.06 along the face normal, stiff 0.03.
  - **Player push:** Δ −= normalize(Q)·0.35·e^{−|Q|²/0.6}·w, with Q = (P − feet)·(1, 0.4, 1) within 1.5 blocks
    (classes 11/12/13).
  - **Floating** (15): y += 0.02·sin(1.3t + φ).
  - **Lantern** (41): the hanging model rotates about its top attachment point, angle 2°·sin(1.1t + φ), using the
    corner-fetch quad bounds.
  - **The same function** runs in the shadow vertex function (M1's pulled replay) and, in M3, computes the previous
    frame's displacement for **motion vectors** (t − dt).
  - Keep varyings within 40 B (vertex-bound terrain on Apple, `sodium_terrain.vs.metal:6-12`).
- **Hook.** H4 vertex + H2 shadow vertex.
- **Cost.** About +3–8% of the cutout vertex work: ≈ 0.03–0.08 ms. All tiers; P uses wobble only (no gust noise fetch).
- **Data/deps.** `matClass`, `ShadeLook.wind/eye/wet`, the vertex sky light.

---

### E17. Entities, block entities, hand, particles

- **Look.** Entities lit *consistently* with terrain: same sun, shadows, sky ambient and fog. This is something even
  Complementary only half does under Iris. The hand is lit by its surroundings, and particles glow with block light.
- **Technique (original).** MSL overrides through `MetalShaderRegistry` (H10) for:
  - `entity_solid`, `entity_cutout*`, `entity_translucent*`, `item_*`, `armor_*`;
  - `solid_block`, `cutout_block`, `translucent_block`;
  - `opaque_particle`, `translucent_particle`, `eyes`, `energy_swirl`, `beacon_beam_*`, `end_crystal_beam`.

  Each one includes `shade_light.metal`. These pipelines have real vertex normals (`Normal RGBA8_SNORM`), lightmap `UV2`
  and overlay `UV1`.
- **Algorithm.**
  - Normal → world space via the inverse view rotation.
  - Lighting = E09 with α_v = 1, S = the cascade (+ the M3 entity map for self-shadowing), the GTAO history (entities
    receive AO), and the overlay hurt-flash kept as vanilla.
  - The vanilla `Lighting` directional lights are ignored.
  - Emissive layers (`eyes`, glowing spider eyes, `energy_swirl`) use emission × 6.
  - `entity_translucent` uses premultiplied output, fogged.
  - **Hand** (`render3dHud`, its own projection):
    - world normal = inverse(view rotation) × the hand-space normal;
    - shadow = the sample at the eye position (one tap of the near cascade at `eye`);
    - ambient = SH at the eye × eye sky light;
    - block light = the hand's lightmap.
    - The hand gets **no fog**.
    - Its depth range marks it for TAAU (motion 0, H8).
  - **Particles:** lit by lightmap + SH + sun (no shadow test in P; shadowed in Q). Rain and splash particles write
    `reactive`.
  - **Screen effects** (`fire_screen_effect`, `block_screen_effect`, `vignette`): unchanged colour; they write
    `reactive` = 1 so TAAU doesn't smear them.
  - **Motion vectors (M3):** entity pipelines in the TBDR pass write color4 = current clip − previous clip.
    - The previous transform comes from a per-render-state cache keyed by entity id and part (pose matrices last frame).
    - Missing → camera motion + reactive 0.5.
    - Metallum's MIT `MetallumEntityMotion.metal` is a usable reference (§8).
- **Hook.** H10; M3 MRT variants through the `PassDelegate`.
- **Cost.** Entities are geometry-bound: 0.3–0.8 ms (est., apple-gpu §7.1), lighting adds ≈ 0.05–0.1.
- **Data/deps.** E09; shadow array; `aoHist`; `ShadeLook.eye/heldLight`; M3 entity motion cache.

---

### E18. TAA / TAAU and dynamic resolution (+ MetalFX option)

- **Look.**
  - **SEUS:** a clean, filmic, very stable image with a "Responsive vs Stable" choice.
  - **Photon:** variance clipping, pixel-age weighting, off-centre rejection, confidence-weighted upscaling.
  - **BSL:** modest history weight, so the image stays sharp.
  - Pixel-art textures must not shimmer or smear.
- **Technique (original single-pass fragment TAAU).** Built from public ingredients:
  - Karis 2014 (YCoCg clip, tonemapped weighting);
  - Jimenez 2016 (5-tap Catmull-Rom history; MJP's MIT gist may be adapted);
  - Salvi (variance clipping);
  - "confidence" weighting from the TAA survey (Yang et al. 2020).

  Photon's MIT `c3/c4` TAAU logic is adaptable (§8), and FidelityFX FSR2 (MIT, verify) is a reference for the
  reactive/lock ideas.
- **Algorithm** (per output pixel q, one fragment pass into compressible RGBA16F `taaHist`):
  1. **Jitter:** Halton(2, 3) with N = clamp(round(8/s²), 8, 32) phases (32 at 0.5x, 18 at 0.67x). It is applied in
     `proj` for every world draw (the existing `CameraFxMixin`). Mip bias = log2(s) (−0.58 at 0.67x); pixel-art safe
     per apple-gpu §3.1.
  2. **Input position:** p = (q + ½)·s − ½ − j_px.
  3. **Gather** the 3×3 internal samples around round(p). Spatial reconstruction weight w_i = BH(|x_i − p|/r), a
     Blackman–Harris approximation with r = max(1, 1/s)·0.85.
     - C_cur = Σw_i·c̃_i / Σw_i, where c̃ = c/(1 + luma(c)) (Karis compression).
     - Moments μ, σ over the 3×3 in YCoCg of c̃.
  4. **Motion:** take the depth of the **nearest** sample in the 3×3 (max reversed-Z), reconstruct P, project with
     `prevViewProjNoJitter` → uv_prev.
     - Hand pixels (main depth > 0 after the hand pass) → uv_prev = uv.
     - M3: if color4 holds per-object motion, use it.
  5. **History:** H = CatmullRom5(`taaPrev`, uv_prev) × (exposure.x/exposure.z).
  6. **Disocclusion:** if uv_prev is off-screen, or |prevDepth(uv_prev) − z_expected| > 0.02·z + 0.05 → age = 0.
  7. **Rectify:** clip H̃ toward μ inside the box μ ± γσ (γ = 1.0 Responsive, 1.25 Stable, +0.5 when the camera is
     still). Use an AABB clip, not a clamp.
  8. **Blend:**
     - α = max(1/(age + 1), α_min), α_min = 0.08 (Stable) / 0.12 (Responsive);
     - α ← max(α, 0.85·reactive);
     - **confidence:** α ← α·saturate(w_center_sum·1.6), so output pixels far from any input sample trust history more
       (needed for upscaling);
     - out = mix(H̃, C̃, α) → decompress; a = min(age + 1, 32).
  9. Also write prevDepth (internal-res linear depth) in the same frame (a small separate pass or an MRT).
- **Sharpening:** RCAS-style (FidelityFX, MIT; verify) in the final pass, strength 0.25 at native and 0.4 at 0.67x.
- **Dynamic resolution:**
  - Read the GPU time of the frame's command buffers (`GPUEndTime − GPUStartTime`, sum of `pre` + `cmd`).
  - EMA over 12 frames → T.
  - Target T* = 0.86·frame budget (7.2 ms at 120 Hz; 14.3 ms at 60).
  - s′ = s·√(T*/T), clamped to ±0.04 per change, quantised to multiples of 1/64; apply only if |Δs| > 0.015 and at least
    8 frames since the last change.
  - Bounds per preset (§5). **Never default below 0.67x; only transient drops to 0.60x** (critique C2).
  - Render into a **viewport sub-rect** of targets allocated at the maximum scale (§1.8), so changes cost nothing.
  - TAAU reads `renderScale.zw` and history survives the change (positions are in output space).
- **MetalFX option (U, or a user choice):** the existing `MetalFx` path, fixed per apple-gpu §3.3:
  - depth/motion captured at H7;
  - `exposureTexture` = a 1×1 of 1/exposure;
  - reactive mask = `reactive`;
  - writing into the main texture directly (no blit);
  - `inputContentWidth` for DRS.

  Marginal cost 4.5–6 ms (meas.).
- **Hook.** H8 (TAAU), H1 (DRS decision for the next frame), `CameraFxMixin` (jitter).
- **Cost.** Meas. 0.62 ms (0.5x → output), 0.72 (0.67x), 1.26 (native TAA). + prevDepth write 0.05.
- **Data/deps.** `taaHist` ×2, `prevDepth`, `reactive`, `ShadeLook.taa/renderScale/prevViewProjNoJitter`, `ShadeGpu.exposure`.

---

### E19. Bloom, fog glow, lens dirt

- **Look.**
  - **SEUS (natural bloom):** threshold-free, energy-conserving (lerp, not add), a wide veiling tail, plus a
    depth-aware "fog bloom" that makes distant air glow.
  - **Complementary/Photon:** about 12% lerp gives the dreamy glow without blowing out.
  - **BSL:** about 20%, stronger and softer.
- **Technique.** **Adapt the composite maths of SE Natural Bloom & Dirty Lens** (MIT, © 2019 sonicether, §8): the lerp
  composite, the octave spectrum weights i^s, and the fog-bloom octave bell with fog fix. The pyramid structure is the
  public CoD:AW dual filter (Jimenez 2014: 13-tap downsample, tent upsample), as measured in apple-gpu (0.74 ms).
- **Algorithm.**
  - **L0** = ½ internal from sceneHDR (pre-TAAU, so the full-res read is saved), using the 13-tap downsample with a
    **Karis average** (weights 1/(1 + luma)) on this first level only, to kill jitter-fireflies.
  - Levels L1..L6 (P/B), L1..L7 (Q/U): 13-tap down; tent up with progressive accumulation
    U_i = L_i + w_i·up(U_{i+1}), with the normalised spectrum weights w_i ∝ i^`bloom.y` (y = 0.6 Epic, 0.9 Storybook,
    0.3 Natural).
  - Format: RG11B10F, lossy compression.
  - **Composite** (final pass, output res, bilinear from U₀):
    C ← mix(C, U₀, m) with m = `bloom.x` (keyframes 0.075–0.14) + `bloom.z`·(1 − T_fog(q)), where T_fog is recomputed
    from the internal depth with the E06 closed forms (one depth fetch + 2 exp). That is the **fog glow**: distance and
    rain glow, but the near field stays crisp.
  - **Lens dirt (option):** C ← mix(C, U₃·(1 + 4·dirt(q)), `bloom.w`·dirt(q)), with `lensDirt` procedurally generated
    (Worley smudges + streaks).
  - **Emissives and the sun** produce glow naturally (HDR values ≫ 1) with no threshold; caves get m +0.02 (glowing
    torches).
- **Hook.** H8.
- **Cost & tiers.** Measured 0.74 ms when built from the output image; from internal ≈ 0.45–0.55 (est. saving 0.2–0.3).

  | Tier | Levels | Source | Est. ms |
  |---|---|---|---|
  | P | 6 | internal | 0.45 |
  | B | 6 | internal | 0.5 |
  | Q | 7 | internal | 0.6 (native internal: 0.74 meas. class) |
  | U | 7 + dirt | TAAU output | 0.75 |

- **Data/deps.** sceneHDR, depth, `ShadeLook.bloom/fog*`, `lensDirt`.

---
### E20. Auto-exposure

- **Look.**
  - **Complementary and Photon** (default) use **no** auto-exposure: brightness is pre-balanced, so night stays night
    and caves stay caves.
  - **SEUS** uses smooth, centre-weighted auto-exposure with honest dark interiors.
  - We combine them: pre-balanced references, plus a *partial*, *bounded* adaptation that reads as "the eye adjusting"
    without flattening the day/night story.
- **Technique (original).** A log-luminance histogram on a small bloom level. Spectrum's MIT `histogram.glsl` /
  `autoexposure.glsl` may be consulted or adapted (§8).
- **Algorithm.**
  - **Histogram:**
    - an H8 compute kernel over bloom L2 (≈ 1/8 internal: 252×164 at 0.67x);
    - 64 bins of log₂ of the *scene* luminance (pre-exposure removed) over [−14, +8];
    - weight = e^{−r²/0.3} (centre) × (1 − 0.6·hand box), where the hand box is a soft rectangle covering the
      bottom-right 30%;
    - threadgroup atomics + `simd_sum`;
    - → `ShadeGpu.histogram`.
  - **Reduce** (1 thread): weighted mean of log₂L between the **40th and 92nd percentiles** → ℓ̄. The sun disc and
    black pockets are ignored.
  - **Target:**
    - log₂E* = λ·(log₂0.18 − ℓ̄ + c_cal) + (1 − λ)·log₂E_ref(e) + EV_bias;
    - λ = 0.55 (Epic) / 0.40 / 0.70;
    - E_ref(e) = E_noon·2^{EV ref(e)} (§3.2) — the pre-balanced reference;
    - **bounds:** log₂E* ∈ [log₂E_ref − 1.75, log₂E_ref + 1.75] ∩ [`exposureCfg.x`, `exposureCfg.y`].
    - Caves and the deep dark get an extra cap of +1.5 EV above E_ref(night) so they stay dark.
  - **Adapt:** log₂E ← log₂E + (log₂E* − log₂E)·(1 − e^{−dt/τ}), with τ = 0.6 s when the scene gets brighter and
    2.2 s when it gets darker (eye-like asymmetry).
  - **Calibrate** E_noon so that a white surface in noon sun lands at 2.4 (§3.5); c_cal absorbs the average scene
    albedo (0.18).
  - **Output:** `ShadeGpu.exposure` = (E next frame, E*, E previous, log₂E). Shaders use pre-exposure with E (§1.5). The
    final pass applies no extra exposure.
- **Hook.** H8 (histogram after the bloom L2 downsample, reduce right after), consumed from the next frame.
- **Cost.** ≈ 0.02–0.04 ms. All tiers; "Off" = λ 0 (pure reference).
- **Data/deps.** Bloom L2, `ShadeLook.exposureCfg/grade0.x`, keyframes.

---

### E21. Tonemap and colour grading: the decision

- **Look.**
  - Highlights bleach toward white like film (Complementary's "path to white", SEUS's hue-aware highlights).
  - Saturated emitters (lava, fire, sunsets) keep their hue instead of skewing to yellow or neon.
  - Midtones are rich (BSL, Complementary vibrance).
  - Darks are lifted and neutral, not crushed.
  - The curve must stretch to the **XDR headroom**.

**Candidates compared** (all are about the same cost, ≈ 0.35 ms meas. for "bloom + AgX + vignette → 8-bit"):

| Criterion | ACES (RRT+ODT or fit) | AgX (stock) | Lottes per-channel (Photon/Complementary family) | BSL Reinhard-in-crosstalk | **Shade Filmic (ours)** |
|---|---|---|---|---|---|
| Hue stability of bright saturated colours | poor (blue→purple, red→orange skews) | excellent | fair (channels clip at different rates → yellow/neon) | good | **excellent** (inset) |
| Path to white | weak, late | excellent | good | good | **excellent, tunable (s_in)** |
| Midtone richness without a look pass | strong but contrasty | flat, desaturated | good | good | **good** (outset + vibrance) |
| Dark handling | crushes | soft | parametric | soft | **parametric + soft floor** |
| EDR/XDR adaptation | needs separate ODTs per peak | fixed log range (−12.47…+4.03 EV) | trivially (white point) | asymptote change | **peak = headroom; mid-grey fixed** |
| Tunability by artists | low | low | **mid-grey in/out, contrast, shoulder, white** | 2 knobs | **same as Lottes + inset/outset** |

**Decision: Shade Filmic.** It keeps AgX's *structure* (inset → per-channel sigmoid → outset), which is what gives hue
stability and path-to-white, and uses Lottes's 2016 generalised curve (public GDC talk) as the sigmoid, because it is
anchored by mid-grey and white point. That makes EDR a one-parameter change. ACES is rejected; stock AgX is rejected as a
parameter set. Offer **"Vivid"** (Storybook: more contrast and saturation, less inset) and **"Film"** (Natural) as
parameter presets, not other operators.

- **Algorithm** (final pass; scene-referred input c = the pre-exposed, bloomed and fog-glowed HDR, linear Rec.709):
  1. **Purkinje** (E22) → **vignette** → **white balance** (`grade1.rgb`; the CPU builds it as a Bradford adaptation
     from 6504 K to the mired-shifted white) → **scene saturation/vibrance** around luma w = (0.2126, 0.7152, 0.0722):
     - c ← Y + sat·(c − Y);
     - vibrance: c ← Y + (c − Y)·(1 + vib·(1 − chroma/0.6)).
  2. **Inset:** M(s) = (1 − s)·I + s·𝟙wᵀ, a luminance-preserving desaturation; c_i = M(s_in)·c, s_in = 0.20 (Epic),
     0.12 (Vivid), 0.24 (Film).
  3. **Curve** per channel: f(x) = x^a/(x^{a·d}·b + β), with the constraints f(m_i) = m_o and f(W) = P solved
     exactly:
     - b = (W^a/P − m_i^a/m_o)/(W^{a·d} − m_i^{a·d});
     - β = m_i^a/m_o − m_i^{a·d}·b.

     Defaults: a = 1.40, d = 0.92, m_i = 0.18, m_o = 0.20; SDR: W = 16, P = 1. **XDR:** P = H (headroom), W = 16·√H;
     m_o unchanged, so midtones match SDR exactly and only highlights gain range.

     b and β are computed on the CPU per frame into `tonemap.zw` (they only change when the parameters do).
     Because d < 1, f keeps rising slowly past W, so clamp the result to P. The inset has already pulled those
     values toward white, so the clamp does not show as a hue break.
  4. **Outset:** y_o = M(s_out)⁻¹·y with the closed form M(s)⁻¹ = (I − s·𝟙wᵀ)/(1 − s), s_out = 0.6·s_in; clamp ≥ 0.
     This re-saturates midtones while highlights keep the inset's path to white.
  5. **Soft black floor:** y ← y + φ·e^{−3y/φ}, φ = `grade2.w` (0.0025 SDR, 0.0015 XDR). Deep shadows never hit pure
     zero.
  6. **Display grade** (CDL-style, per keyframe): y ← (y·gain + lift)^γ_d with gain = `grade3.rgb`, lift =
     `grade2.rgb`, γ_d = 1; then display saturation in √ space (the BSL-like vibrance feel, our parameters).
  7. **Encode:**
     - SDR: exact piecewise sRGB OETF, plus triangular-PDF blue-noise dither of ±1 LSB (`output.z`).
     - XDR: 709→P3 matrix, × paper-white, no OETF (extended linear).
- **Per-time-of-day grading:** all parameters are keyframed (§3.2) and blended (§3.4, weather), on the CPU. The teal and
  orange separation comes from the physical warm key / cool fill plus WB, not from hue-isolated grading. An optional
  32³ **creative LUT** (M3) can be baked by compute from the parameters when "Custom look" is used.
- **Hook.** H8 final pass.
- **Cost.** ≈ 0.35–0.40 ms (meas. class). All tiers.
- **Data/deps.** `ShadeLook.tonemap/grade*/output`, E22, E23.

---

### E22. Camera and lens: the final pass ordering, vignette, flare, sharpening, grain, optional DOF/blur

- **Look.**
  - **Photon:** restraint (nearly invisible vignette, CAS, dither).
  - **BSL:** a classic multi-ghost flare with an anamorphic streak (fun, as an option).
  - **SEUS:** a filmic softness option.
- **Technique (original).**
- **Algorithm (one output-resolution fragment pass, in this order):**
  1. Read the TAAU output at q (5-tap cross for RCAS), with an underwater wobble of 0.002·sin(…) on the uv when
     submerged.
  2. Bloom lerp + fog glow + dirt (E19).
  3. **Purkinje**, before the tonemap:
     - rod response V_r = dot(c, (−0.06, 0.54, 0.36)), from a published XYZ→rod fit (verify the coefficients);
     - β = `grade1.w`·saturate((log₂E − log₂E_noon − 1.5)/2.5)·(1 − smoothstep(0.04, 0.4, luma(c)));
     - c ← mix(c, V_r·(0.60, 0.78, 1.0)/luma(0.60, 0.78, 1.0), 0.75β).
     - Replaces M1's `rods` term in `shadeOutput`.
  4. **Vignette:** c ×= 1 − v·r^2.4, with r = the aspect-corrected radius from the centre; v = 0.12 (caves 0.22,
     underwater 0.3). The bright-sparing factor (1 − 0.5·saturate(luma(c) − 1)) keeps the sun intact.
  5. **Tonemap + grade** (E21).
  6. **RCAS-like sharpening** on the tonemapped luma, with the cross neighbours tonemapped by the same cheap curve
     approximation; strength `output.w`.
  7. **Grain/dither:** dither always. Optional night grain: ±0.6%·β blue noise (ISO feel).
  8. **Lens flare** (option): a separate instanced draw of 8 ghost quads plus 1 anamorphic streak after the final pass.
     - Ghost positions along the sun–centre axis at fractions (−0.6, −0.35, −0.2, 0.2, 0.45, 0.7, 1.1, 1.5).
     - Rounded-hexagon SDF ghosts with spectral tint (wavelength by index).
     - Intensity × `ShadeGpu.scene.z` (sun visibility: a 16-tap depth probe around the sun's screen position + cloud
       transmittance at the sun, temporally smoothed in H8) × (1 − rain).
- **DOF / motion blur (U, "photo mode" only):**
  - DOF: ½-res 24-tap Vogel gather with CoC from depth (0.3–0.5 ms);
  - camera motion blur: 8 taps along the velocity, hand masked (0.3 ms).
  - Off by default (they hurt readability and fps).
- **Hook.** H8.
- **Cost.** Inside the 0.35–0.40 ms final; flare +0.02.
- **Data/deps.** TAAU output, bloom, `ShadeGpu`, `ShadeLook`.

---

### E23. EDR / XDR output for the Liquid Retina XDR panel

- **Look.** On this MacBook Pro the sun disc, specular glints, lava, torches, lightning and bloom cores can be **really
  brighter than paper white**. This is one of the most dramatic upgrades available, and no GL shaderpack can do it on
  macOS.
- **Technique (original, standard Apple EDR).** Metallum-Sergey's MIT `MetallumPresent.metal` (headroom mapping) is a
  reference (§8).
- **Algorithm.**
  - **Layer** (`mc_layer_configure`): `pixelFormat = RGBA16Float`, `colorspace = extendedLinearDisplayP3`,
    `wantsExtendedDynamicRangeContent = YES`, `framebufferOnly = YES`.
  - **Headroom H:**
    - read each frame (cheap; or on `NSScreen` change notifications) from
      `NSScreen.maximumExtendedDynamicRangeColorComponentValue`, which depends on the brightness slider (typically
      2–8 on this panel; up to 16 at low brightness);
    - P = min(H, user cap): "Auto", 2×, 4× or 8×; default cap 4×;
    - smooth with τ = 0.5 s so tonemapped highlights don't jump when macOS changes H.
    - Full-screen bright content (noon sky) stays near 1–1.3 because m_o is unchanged; only highlights use the
      headroom. That respects the panel's sustained full-screen limit.
  - **Final pass:** E21 with P = H, then 709→P3 (exact matrix), × paper white `output.y` (1.0) → `edrImage`.
  - **GUI** (must stay SDR and must not be tonemapped):
    - reuse FrameGen's proven mechanism (`GuiRendererFrameGenMixin`): draw the GUI into the RGBA8 main over **black**
      and over **white**;
    - coverage α = 1 − mean(white − black);
    - colour = black (premultiplied), sRGB→linear, × paper white;
    - out = gui + edr·(1 − α).
    - This handles every vanilla blend mode, including the inverting crosshair.
  - **Present:** an `mc_present` variant drawing `out` into the RGBA16F drawable.
  - **Screenshots** (F2 reads the RGBA8 main): on a screenshot frame, run the SDR final into main once. The
    `Screenshot.grab` mixin sets the flag.
- **Hook.** H8 (final variant), H9 (GUI, present), the fork's layer and present changes (§1.8).
- **Cost.** +0.1–0.2 ms (second GUI draw) + about 0.1–0.2 ms (8 B/px drawable, compositor) (apple-gpu §5.3 est.).
  Available in all tiers; default **on** when an XDR panel is detected (the user can turn it off).
- **Data/deps.** E21, `ShadeLook.output`.

---

### E24. Nether look

- **Look.**
  - **Complementary:** per-biome palettes, lava glow from below, glowing haze, ash storms.
  - **BSL:** clean per-biome fog colours with darks tinted by the biome.
  - **Photon:** restraint, with block light and fog doing the work.
  - Ours: **a hot, layered, glowing atmosphere** where distance dissolves into coloured smoke.
- **Technique (original).** `flags.x == NETHER`: no sun, no cascades, no clouds, no VL.
- **Algorithm.**
  - **Ambient:** `dimTint` = the biome palette (below) at 0.6 luminance. **Lava up-light:** ambient from below
    E_up = lavaGlow·(0.5 − 0.5·N_y)·(0.6 + 0.4·n(t)), so ceilings and undersides glow warm.
  - **Biome palettes** (fog / ambient / accent, hex):

    | Biome | Fog | Ambient | Accent |
    |---|---|---|---|
    | Nether wastes | #3A0F08 | #7A2A14 | lava #FF6A1E |
    | Crimson forest | #3A0610 | #8A1E2A | shroomlight #FFB060 |
    | Warped forest | #0A2A2E | #1E6E6A | violet #5A2A7A |
    | Soul sand valley | #0E2A33 | #2E7A8A | soul fire #3FE0FF |
    | Basalt deltas | #3A3A40 | #6A6A72 | ash #CFCFD6 |

  - **Fog:** σ = `dimTint.w`·(1 + 0.6·fBm₃(P/48 + t·0.02)) (Q/U: **"heat haze" volume**, a ¼-res 10-step march with
    lava-lit in-scatter toward the fog colour, 0.15–0.25 ms; P: analytic exponential only), plus a 4th-power border fog.
  - **Heat shimmer** (Q/U, option): in the final pass, uv offset of 0.6 px·n(uv·40 + t)·saturate((d − 24)/64).
  - **Bloom:** m +0.03; lava emission ×1.4; Purkinje off; auto-exposure λ 0.3 (stay moody).
- **Hook.** E01 (CPU palette), E06, E09, E19, E22 branches; no extra passes in P.
- **Cost.** P ≈ 0; Q +0.2 ms (haze volume).
- **Data/deps.** Biome at the camera, vanilla Nether fog colour (as a tint input).

---

### E25. End look

- **Look.**
  - **Complementary:** a lavender End with volumetric "beams" and flashes.
  - **Photon:** a purple-green emissive fog and an animated solar-flare sun.
  - **BSL:** a speckled starfield.
  - Ours: **a cold, vast void**: deep indigo sky, a baked nebula, sharp stars, a pale violet "dead star" key light with
    shadows, and luminous curtains rising from the void around the island. Palette: violet + cyan accents (distinct
    from the studied packs' purple/orange).
- **Technique (original).**
- **Algorithm.**
  - **Sky:** gradient #07050F (zenith) → #1C1230 (horizon) + `endNebula` (baked fBm emission with domain warp, two hues
    #6A3FA0 / #2F7F8F, slowly rotated) + stars (E04 at 1.5× density).
  - **Key light:** a fixed direction (elevation 55°, azimuth 30°), colour #C7B8FF at 0.35 of the noon sun, with shadows
    (cascades on; the light never moves, so the far cascade stays cached). The sky-view LUT is not used; SH comes from
    the End env map (sky + nebula).
  - **Beams:** the VL pass with density ρ = B(θ·9 + n₁(t))·exp(−|y − 50|/90)·smoothstep(30, 120, r), with r, θ the polar
    coordinates around (0, 0), B a ridged noise curtain, colour #9A6AFF with #6AE0FF filaments. It moves slowly and
    calms after the dragon dies (vanilla dragon fight state → CPU flag).
  - **End flash** (26.x `SkyRenderState` flash): `ShadeLook.flash` adds a directional cyan-violet light with an
    envelope, brightening beams in its direction.
  - **Fog:** low density #1A1030; exposure λ 0.4.
- **Hook.** H3 (sky), H7 (beams via VL), E09.
- **Cost.** Like the overworld minus clouds: VL beams 0.4–0.5 ms (P).
- **Data/deps.** `endNebula`, vanilla End state.

---

### E26. Underwater, lava, powder snow, blindness/darkness (camera inside media)

- **Look.**
  - **SEUS/Photon:** physical absorption, so 10 blocks of water turn cyan-blue and the view fades into depth.
  - Caustic shafts.
  - **Snell's window** looking up.
  - **Complementary:** a gentle wobble and readable "bright cave water".
- **Technique (original).**
- **Algorithm** (camera in water: `flags2.y`):
  - **View path:** every opaque/translucent fragment gets T = e^{−σ_t·d}, L ← L·T + (1 − T)·L_water, with σ from
    `waterAbs` and L_water = (σ_s/σ_t)·(E_sky·g_eye·0.4 + E_sun·S_eye·e^{−σ_a·(surfaceY − y)}·0.25)·tintNorm.
    `water.w` = the surface y. Vanilla water fog distance is ignored; the visibility multiplier comes from the
    Respiration/Conduit effects.
  - **Looking up at the surface:**
    - inside the critical angle (48.6°): refracted sky/env (Snell's window), plus caustic sparkle;
    - outside it: total internal reflection, with SSR into the underwater scene and a fallback to L_water.
  - **VL:** E07's underwater branch (caustic shafts).
  - **Final:** wobble, vignette 0.3, chromatic split 0.4 px (option).
  - **Lava:** σ_t = 2.5/block, colour (1.0, 0.35, 0.05)·6. **Powder snow:** σ_t = 1.2, colour (0.85, 0.9, 1.0)·ambient.
  - **Blindness/darkness:** vanilla distances; darkness pulses exposure −1 EV with the effect's pulse.
- **Hook.** E06/E09/E14/E22 branches on `flags`.
- **Cost.** About 0 (P); VL underwater +0.05.
- **Data/deps.** `ShadeLook.water/waterAbs`, `ShadeFrame.flags/fogColor`.

---

### E27. Far terrain (mcopt LOD) and distance consistency

- **Look.** No visible seam between Sodium chunks and mcopt's far terrain. Mountains on the horizon carry the same sun,
  shadow mood and aerial perspective (critique §7.8).
- **Technique.** Use the same `shade_light()` with a reduced input set.
- **Algorithm.**
  - M2: in `columns.metal` (H14), use the same sun/SH/AP/fog/border functions with S = cloud shadow ×
    smoothstep(0.75, 0.95, k) (no cascade).
  - M3: enable `lod_*_gbuffer` (`Lod.java:455,495`) so far terrain enters the TBDR G-buffer and gets identical
    lighting.
  - Far water uses E14 without SSR (env map only).
- **Cost.** About 0.
- **Data/deps.** E02/E06/E09; the far-terrain G-buffer layout.

---
## 5. Quality tiers

| Setting | **Performance** | **Balanced** | **Quality** | **Ultra** |
|---|---|---|---|---|
| Target | 120 fps | 100–120 fps | 60–80 fps (DRS keeps ≥ 60) | 60 fps |
| Internal scale (DRS range) | 0.67 (0.60–0.75) | 0.80 (0.67–0.90) | 1.0 (0.85–1.0) | 1.0 (0.9–1.0), or MetalFX at 0.75 |
| Upscaler | TAAU, Responsive | TAAU, Stable | TAA (native), Stable | TAA, or MetalFX temporal (fixed) |
| Sky-view / env | 128×72 / every 2nd frame | 192×108 / every frame | 192×108 / every frame | 256×144 / every frame |
| Clouds | volumetric 24/4, ½×½ checkerboard | 32/4 | 48/6 | 64/6, no checkerboard, towering + cirrus detail |
| Shadows | 2048², 8 PCSS taps | 12 taps | 16 taps, near ±40 | inline RT cone (M4) + VL cascade |
| Coloured shadows / caustics (M3) | off | on | on | on (RT tint) |
| Entity shadows (M3) | off | on | on | RT entity BLAS (M4) |
| VL | 12 + 4 taps | 14 + 4 | 20 + 8 | 28 + 8, coloured light fog |
| AO | GTAO 1×3 | GTAO 2×3 | GTAO 2×4 | RTAO (M4) |
| Water reflections | SSR 16 | SSR 20 | SSR 24 | RT (M4) |
| Opaque reflections | env only | env only | SSR on s ≥ 0.75 / puddles / metals | RT glossy (M4) |
| Coloured light volume (M3) | off | off | on | on + light fog |
| GI | SH + bounce | SH + bounce | + LPV | RT GI cache (M4) |
| Bloom | 6 levels, internal source | 6 | 7 | 7 + dirt, TAAU-output source |
| Waving | wobble only | full | full | full |
| labPBR / POM | labPBR if a pack is present | same | same | + POM |
| Nether heat haze / shimmer | off | off | on | on |
| Aurora steps | 12 | 12 | 16 | 24 |
| DOF / motion blur | – | – | – | photo-mode option |
| XDR | on if the panel supports it (all tiers) | | | |

The defaults per look preset (§3.6) are orthogonal to the tier.

---

## 6. Roadmap: ordered by beauty per millisecond

The beauty score (1–10) is my judgement of the visible impact in typical play. Cost is at 0.67x (P) unless noted.
"B/ms" is the ratio (∞ = free or net-saving).

| # | Effect | Beauty | Cost (ms) | B/ms | Milestone |
|---|---|---|---|---|---|
| 1 | Lighting model v2 (wrap, bounce, warm fill, SSS terms, block curve, Kelvin, readability), ALU only | 8 | 0.05–0.1 | ~100 | **M1 polish** |
| 2 | Art layer `ShadeLook` + keyframes + sun-path tilt + sun/moon crossfade | 8 | 0 | ∞ | **M1 polish** |
| 3 | Procedural sun disc/aureole, moon phases, stars, Milky Way | 6 | 0.03 | 200 | **M1 polish** |
| 4 | Height haze + border fog to sky + evening glow | 7 | ≈ 0 | ∞ | **M1 polish** |
| 5 | PCSS-lite + contact sharpening + leak gate + far fade | 6 | ≈ 0 (hidden) | ∞ | **M1 polish** |
| 6 | **HDR target + pre-exposure + Shade Filmic + grade** | 9 | 0.35 + HDR overhead ≈ 0.25 | 15 | **M2a** |
| 7 | **Natural bloom + fog glow** | 7 | 0.45 | 15 | **M2a** |
| 8 | Bounded auto-exposure + Purkinje | 5 | 0.03 | 170 | **M2a** |
| 9 | Hillaire LUT sky + AP + env map + SH9 skylight | 8 | 0.08 | 100 | **M2b** |
| 10 | Material atlases (class + params) + AO separation | 6 (enabler) | 0.02 | 300 | **M2c** |
| 11 | Waving foliage + leaf SSS/sheen | 7 | 0.05 | 140 | **M2c** |
| 12 | Emissive glow + Kelvin + glowing-ore option + glints | 6 | 0.02 | 300 | **M2c** |
| 13 | **TAAU + DRS + settings** (enables 120 fps; saves ≈ 3 ms vs native) | 6 | −3 (net) | ∞ | **M2d** |
| 14 | **Water** (FFT waves, SSR, refraction, absorption, foam, caustic approximation) | 9 when visible | 0.45–0.75 | ~15 | **M2e** |
| 15 | Glass/ice/portal translucents | 4 | 0.05 | 80 | **M2e** |
| 16 | **VL** + canopy factor + crepuscular + underwater shafts | 7 | 0.40 | 17 | **M2f** |
| 17 | GTAO with bent normals | 5 | 0.12 | 40 | **M2f** |
| 18 | XDR output | 8 on this panel | 0.2–0.4 | 25 | **M2 stretch** (critique placed it in M3; pull it forward, it is cheap and visible) |
| 19 | **Volumetric clouds** + cirrus + cloud shadows + daily weather | 9 | 0.30–0.45 | 23 | **M3a** |
| 20 | SDF voxel clouds (Storybook) | 7 | 0.2–0.3 | 28 | **M3a** |
| 21 | TBDR deferred + entity MRT + motion vectors | 4 (consistency) | −0.3 (saves) | ∞ | **M3b** |
| 22 | Entity lighting overrides (M2 forward first) | 6 | 0.05–0.1 | 70 | **M2c → M3b** |
| 23 | Coloured shadows + shadow-pass caustics | 6 | 0.10–0.20 | 40 | **M3c** |
| 24 | Entity shadow map (replay) | 5 | 0.10–0.15 | 40 | **M3c** |
| 25 | Rain wetness, puddles, ripples, lightning, snow cover | 5 in weather | 0.03 | 170 | **M3d** |
| 26 | Aurora | 5 (occasional) | 0.06–0.12 | 50 | **M3d** |
| 27 | Coloured light volume (LPV) | 7 at night/caves | 0.10–0.20 | 45 | **M3e** |
| 28 | Nether haze/shimmer, End beams/nebula | 6 in dimension | 0.2–0.5 | 15 | **M3e** |
| 29 | Lens flare / dirt, DOF photo mode | 3 | 0.02 / 0.4 | – | **M3e (optional)** |
| 30 | RT sun shadows (inline) | 7 | −0.5 (net vs cascades) | ∞ | **M4** |
| 31 | RT water + glossy reflections | 6 | ≈ 0 vs SSR | ∞ | **M4** |
| 32 | RTAO | 4 | 0.35–0.5 | 10 | **M4 (U)** |
| 33 | RT GI cache | 8 | 1.0–1.8 | 5 | **M4 (U)** |
| 34 | labPBR normals + POM | 5 (with packs) | 0.2–0.5 | 12 | **M3/M4 (U)** |

**Milestone packaging.** Each one ships to the user as a new Prism instance, per critique §5.

- **M1 polish** (after M1 lands; ALU and CPU only): items 1–5.
- **M2a "it glows"**: 6–8. The single biggest visual jump.
- **M2b "real sky"**: 9.
- **M2c "living materials"**: 10–12 and 22.
- **M2d "full Retina at 120"**: 13.
- **M2e "water"**: 14–15.
- **M2f "light shafts"**: 16–18.
- **M3**: 19–29.
- **M4**: 30–34.

Dependencies:
- 6 → 7, 8, 13, 18.
- 9 → 14 and 19 (env map, AP).
- 10 → 11, 12, 14, 23, 27.
- 13 → 14 (SSR from history) and 16, 17, 19 (temporal reuse).
- 21 → 24, 33.

---

## 7. Frame budgets (GPU ms at 3024×1964 output)

**Assumptions:**
- Measured items come from apple-gpu.md (marked meas.); the rest are estimates.
- "Real scene" items (entities, water, GUI) follow critique §3.
- Typical overworld daytime frame with about 30% water on screen and clouds in the sky.
- Shadows are M1 cached cascades (pre-M4).
- **Performance** budget target 7.2 ms (DRS headroom for 120 Hz, 8.33 ms). **Quality** target 12.5–16.7 ms
  (60–80 fps).

| Pass | **Performance** (0.67x → TAAU) | **Quality** (native + TAA) |
|---|---|---|
| H1 compute: LUTs, env map, SH9, AP, cloud weather/shadow, canopy, exposure reduce | 0.08–0.12 | 0.10–0.15 |
| Shadow cascades (near every frame, far cached, sun-facing faces) | 0.70–1.00 (meas. class) | 0.90–1.30 |
| Sky pass (sky pixels: atmosphere, sun/moon, stars) | 0.03–0.05 | 0.06–0.08 |
| Opaque terrain, lit (geometry-bound; 1.42 / 1.81 meas.) + lighting, material, waving | 1.60–1.75 | 2.10–2.30 |
| Entities, block entities, particles (lit) | 0.30–0.80 | 0.50–1.00 |
| H6: suspend/store/reload + colour/depth copies + hi-Z | 0.25–0.40 | 0.60–0.90 |
| Clouds (march + reconstruction + composite) | 0.30–0.45 | 0.70–1.10 |
| Water/glass forward + SSR (when visible) | 0.45–0.75 | 1.00–1.60 |
| GTAO (½) | 0.10–0.14 | 0.30–0.38 |
| VL (½) + composite | 0.38–0.45 | 0.95–1.15 |
| Coloured shadows + LPV (M3; off in P) | – | 0.20–0.40 |
| Hand + screen effects | 0.05–0.10 | 0.10 |
| Bloom pyramid | 0.45 | 0.60–0.74 |
| Exposure histogram | 0.03 | 0.03 |
| TAAU / TAA + prevDepth | 0.77 (0.72 meas.) | 1.34 (1.26 meas.) |
| Final (bloom mix, Purkinje, Shade Filmic, grade, RCAS, dither) | 0.35–0.40 (meas. class) | 0.40 |
| GUI + present | 0.20–0.40 | 0.40–0.80 (incl. XDR) |
| **Total** | **≈ 6.0–8.1 ms** (124–167 fps; DRS holds 120 in heavy scenes by dipping to 0.60–0.64) | **≈ 10.3–13.8 ms** (72–97 fps) |
| XDR on (P) | +0.2–0.4 | included above |
| M4 RT shadows instead of cascades | −0.5 to −0.8 | −0.6 to −1.0 |

**Cross-checks:**
- critique §3 gives 0.67x + TAAU with cascades + VL + SSR = 7.6–9.6 ms real, and native rich = 11–13 ms.
- Our P total is ≈ 0.5–1.5 ms lower because the clouds, AO and VL are budgeted at reduced resolution with temporal
  reuse, and because the M2 HDR forward pass avoids a stored G-buffer.
- **If M0/M2 calibration shows P above 8 ms:** first cut clouds to 16 steps (−0.1), then VL to 10 taps (−0.06), then
  water SSR to 12 (−0.1), then let the DRS floor reach 0.60x. Never cut TAAU or the final pass.

**Balanced** (0.8x) ≈ 7.6–10.2 ms (98–131 fps, DRS-managed). **Ultra** = Quality + RT GI (1.0–1.8) + RTAO (0.35–0.5) +
cloud U (+0.5) + VL U (+0.3) − cascades (−0.8) ≈ 12–16.5 ms (60–83 fps). Alternatively 0.75x + MetalFX ≈ 13–16 ms.

Thermals: the 14" MBP on battery may down-clock after about 10 minutes (critique §2). DRS absorbs it; the user sees
resolution change, not stutter.

---

## 8. Licensing: what code may be adapted, and the attribution required

**Rule.** We write original MSL. "Adapt" means porting a specific function or module from a **verified permissive
source** to MSL, with the notice kept. Everything else is **technique-only**: re-derive it from public papers or from
the descriptions in this document. Never paste or translate restricted code. Review checklist for every PR: "Does any
function body come from a pack? If yes, which license and which file?"

### 8.1 Adaptable (verified LICENSE files in `work/`)

| Source | License (verified) | May adapt | **Excluded inside it** | Attribution |
|---|---|---|---|---|
| **Photon @ `26c2906e`** (`work/packs/photon-mit-26c2906e/`, last MIT tree, 2025-01-09) | MIT, "Copyright © 2025 Benjamin Stott 'sixthsurge'" (`LICENSE`, checked) | `include/sky/atmosphere.glsl` (LUT mappings, Chapman) + `image/atmosphere/scattering.dat`; `include/sky/projection.glsl`; `include/utility/spherical_harmonics.glsl`; `include/sky/clouds/*`, `program/d1_clouds.*`, `d2_clouds_upscaling.*`; `include/lighting/shadows.glsl` (PCF/PCSS/colour parts); `diffuse_lighting.glsl`, `colors/light_color.glsl`, `handheld_lighting.glsl`; `bsdf.glsl`, `specular_lighting.glsl`, `include/misc/raytracer.glsl`; `include/lighting/ao/gtao.glsl` + `program/d3_ao.*`; `include/fog/*`; `program/c0_vl.vsh` (air-fog coefficients by time of day / biome / rain; 2026-11 golden-hour mist) and the time uniforms of `shaders.properties` (`me_fade`, `me_weight`, `time_sunrise` / `time_noon` / `time_sunset` / `time_midnight`); `include/misc/water_normal.glsl`, `rain_puddles.glsl`; `program/c3_taau_prep.*`, `c4_taa_exposure.*`; bloom `c5–c13`; Lottes path of `c14_color_grading.*`; `include/misc/purkinje_shift.glsl`; `include/sky/aurora.glsl`; `include/vertex/displacement.glsl`; `include/lighting/lpv/*`; data `worley_noise.dat`, `curl_noise.dat` | ① `include/lighting/distortion.glsl` **shadow bias and edge leak fix** ("Shadow bias method from Complementary Reimagined… thanks to Emin": personal permission; **do not copy**); ② the **fancy nether portal** (Complementary idea, used with permission); ③ **stars in `include/sky/sky.glsl`** ("based on" a Shadertoy entry, Md2SR3, with no stated license, so Shadertoy's default CC BY-NC-SA applies: **do not copy**); ④ the hash at `include/utility/random.glsl:79` (Shadertoy origin: **do not copy**); ⑤ `include/utility/color.glsl` blackbody and `encoding.glsl` packing ("from Jessie-LC open-source-utility-code", license unverified: **re-derive**); ⑥ `include/lighting/directional_lightmaps.glsl` (Ninjamike snippet, unverified: skip); ⑦ `include/aces/*` (AMPAS license; not needed); ⑧ `image/galaxy.png` (NASA; we generate our own) | Header in each adapted `.metal`: `Portions adapted from Photon Shaders by Benjamin Stott ("sixthsurge"), MIT License, commit 26c2906e.` Full MIT text in `THIRD_PARTY_NOTICES`. Keep embedded third-party credits (MJP, Bruneton, IQ) where present |
| **Spectrum** (`work/packs/spectrum/`) | MIT, "Copyright (c) 2017-2018 Jacob Eriksson" (checked) | `include/color/display_transform/*` (an alternative display transform for a future "Natural" variant), `program/histogram.glsl` + `autoexposure.glsl`, `include/fragment/waterCaustics.fsh`, `program/rsmCompute.glsl` / `rsmFilterIteration.glsl` | the **Dave Hoskins hash** at `include/utility/noise.glsl:74` (CC-BY-SA); check each file's header before adapting | `Portions adapted from Spectrum by Jacob Eriksson (Zombye), MIT License.` |
| **SE Natural Bloom & Dirty Lens** (`work/packs/seus/SE-Natural-Bloom-Dirty-Lens/`) | MIT, "Copyright (c) 2019 sonicether" (checked) | the composite maths of `Assets/SE Natural Bloom/Shaders/SENaturalBloomAndDirtyLens.shader` (lerp composite, i^s spectrum, fog-bloom bell + fog fix) → E19 | lens-dirt PNGs: allowed, but we generate our own | `Bloom composite adapted from SE Natural Bloom & Dirty Lens (c) 2019 sonicether, MIT License.` |
| **SEGI** (`work/packs/seus/SEGI/`) | MIT, "Copyright (c) 2017 sonicether" (checked) | cone-trace loop, temporal blend with world-position rejection, depth+normal bilateral blur/upsample, voxel feedback bounce → E09-U | – | `Portions adapted from SEGI (c) 2017 sonicether, MIT License.` |
| **Metallum (Sergey fork)** (`work/community/metallum-sergey/`) | MIT text, but the copyright line reads "Copyright (c) Microsoft Corporation" (an unedited template, checked) | `MetallumPresent.metal` headroom mapping (E23), `MetallumEntityMotion.metal` (E17), `MetallumHdrEffects.metal` histogram ideas | none known; **ambiguity:** the stated holder is wrong | Keep the LICENSE text verbatim and credit "Metallum contributors (kokodio/metallum, SergeyWithNormalName/metallum)" (critique §2.9) |
| **minecraft-metal-renderer** (Kausik-Velaga) | MIT, "Copyright (c) 2026 Minecraft Metal Renderer contributors" (checked) | little of value for shading (`native/shaders/presentation.metal`) | – | standard MIT notice |
| **MJP Catmull-Rom 5-tap** (gist referenced at Photon `include/utility/bicubic.glsl:50`) | MIT (as stated in the source comment) | TAAU history sampling (E18) | – | `Catmull-Rom sampling after Matt Pettineo (MJP), MIT.` |
| **AMD FidelityFX** (RCAS/EASU, FSR2): not downloaded | MIT per AMD GPUOpen (**verify the LICENSE before use**) | RCAS sharpening (E22); FSR2 reactive/lock ideas (E18) | – | AMD copyright + MIT text |
| **Christoph Peters blue-noise textures** | CC0 (per author; verify) | `blueNoise` | – | credit (courtesy) |

### 8.2 Technique-only (study, describe in our own words, implement from public sources)

| Source | Why |
|---|---|
| Complementary Reimagined/Unbound r5.9.3 | Complementary License 1.7: modification and redistribution of parts are outside "Normal Usage"; everything else is All Rights Reserved. (The MPL-2.0 `anisotropicFiltering.glsl` is the only exception, and we don't need it.) |
| BSL v10.1.8 | All Rights Reserved; redistributing derivatives needs the author's permission |
| SEUS Renewed / PTGI / legacy | SEUS License forbids using "snippets from its source code" in other work. **Not downloaded** (EULA acceptance needs the user's OK) |
| Photon after 2025-01-09 (`work/packs/photon`, main) | custom license: no redistribution on Modrinth or CurseForge; unsafe for a project that may be published there |
| Iris, Vitrail | LGPL: reference only (shadow-tree idea, separateAo idea) |
| Noble, Alpha Piscium, Sundial Lite | GPL-3.0: reference only |
| Bliss, Solas, Super Duper Vanilla, Lux, RRe36 packs, Shrimple, Visual Vibrance | restrictive |
| Glimmer (MIT) | its README credits Complementary-derived shadow bias and Photon code: avoid those parts |

### 8.3 Public techniques we implement from the original papers or talks (no license issue)

- Hillaire 2015 (*Physically Based and Unified Volumetric Rendering in Frostbite*) and 2020 (*A Scalable and
  Production Ready Sky and Atmosphere Rendering Technique*).
- Bruneton & Neyret 2008, Bruneton 2017 (atmosphere maths; the reference code is BSD-3).
- Schneider & Vos 2015/2017/2022 (Nubis clouds); Wrenninge et al. (multiple-scattering octaves).
- Tessendorf 2001 (FFT ocean).
- Jimenez 2014 (IGN, CoD:AW bloom), Jimenez et al. 2016 (GTAO, bent normals, multibounce).
- Karis 2013 (sphere-light normalisation, split-sum), Karis 2014 (TAA).
- Salvi (variance clipping); Yang et al. 2020 (TAA survey).
- Lottes 2016 (tonemap curve); AgX (Sobotka): structure only.
- Lagarde & de Rousiers 2014 (specular occlusion); Heitz 2014 (Smith); Hoffman 2019 (f0/f82).
- Ramamoorthi & Hanrahan 2001 (SH irradiance).
- Neckel & Labs (limb darkening); CIE 1931 (blackbody); Lommel–Seeliger (moon).
- Kirk & O'Brien 2011 (scotopic vision); labPBR 1.3 (format spec).

---

## 9. M1 polish backlog (to apply after the M1 workflow merges; do not touch M1 now)

All of these are ALU or CPU changes inside M1's own files. None needs M2's HDR.

1. **Sun-path tilt** in `ShadeFrame.java`: rotate the sun/moon directions by RotX(tilt), default −30° (Epic). The shadow
   pass already takes `lightDir`.
2. **Sun/moon handover crossfade** x_c (§3.2) on direct, specular and VL. M1's `lightDirWorld` switches abruptly today.
3. **Leak gate** smoothstep(0.08, 0.40, sky light) on the direct term, plus the **far-cascade fade** to
   smoothstep(0.75, 0.95, k).
4. **PCSS-lite** in `shade_shadow.metal` for the near cascade (keep the 4-tap tent for the far cascade), plus
   two-sided foliage normals and a thicker leaf kernel.
5. **Lighting v2** in `shade()`: wrap 0.2, ground bounce, warm fill, F(b) block curve, 2700 K, minimum light, the
   readability term (E09 steps 1–7 and 11).
6. **Height haze + ℓ₄ border fog** (E06 b, c), with M1's `horizon[8]` as a temporary border colour.
7. **Procedural sun, moon, stars and Milky Way** in the sky override (E03/E04). The Milky Way texture bake can start
   here.
8. **`ShadeLook` (buffer 17) CPU skeleton** with the keyframe table, so tuning can begin before HDR. Hot-reload
   `config/mcopt-shade/look-<preset>.json` on F3+T (art iteration without rebuilds).

---

## 10. Tuning and validation protocol (no runs now; for when the user OKs launches)

- **Reference matrix.**
  - Times: e = −15, −4, 0, 5, 25, 60°.
  - Places: plains, forest, desert, snowy, ocean, swamp, cave, deep dark, Nether wastes, End.
  - Weather: clear, rain, thunder.
  - Camera bookmarks are scripted by the critique-M0 bench route and captured with `Screenshot.grab`.
  - Compare against §3.3–3.5 targets and against the user's own reference screenshots of the packs they love
    (reference images only, no code).
- **Luminance probes.** Debug view 12 prints the pre-tonemap linear luminance at 5 fixed screen probes and the
  histogram percentiles. Tuning edits the JSON keyframes until §3.5 holds.
- **Debug views** (`tier.w`):
  - 1 albedo, 2 normals, 3 material class, 4 params;
  - 5 AO (vanilla / GTAO), 6 shadow visibility;
  - 7 direct only, 8 ambient only, 9 VL only, 10 clouds only, 11 fog only;
  - 12 false-colour exposure + probes;
  - 13 TAAU age/disocclusion, 14 motion, 15 reactive;
  - 16 LPV slice, 17 a per-pass timing overlay from `mcopt.metal.trace`.
- **Pricing.** Every new pass gets priced with `-Dmcopt.metal.trace=N` at P and Q before merging. Keep an
  `OptimizationHistory.md`-style log of rejected ideas (the Metallum practice). Prototype risky passes in
  `work/bench-apple-gpu` first.
- **Image-quality gates.**
  - No visible shimmer on distant leaves, fences or rails at P; no ghosting behind moving mobs (M3 motion) or on water.
  - Stars stable while turning.
  - No banding in blue-hour skies (dither on).
  - No light leaks in a 1×1 tunnel at noon.
  - No shadow pop at the sun/moon handover.
  - No XDR GUI halo.

---

## 11. Risks and open questions

1. **The M1 contract is frozen** (1008 B `ShadeFrame`). All new data goes to `ShadeLook`/`ShadeGpu`. Coordinate
   `buffer(17–19)` ownership with the M1 author before M2 starts.
2. **AO separation mixin** depends on Sodium 0.9.3 internals (pinned < 0.9.4). Fallback: keep the baked AO and drop the
   α_v curves (the look loses some contact contrast).
3. **H6 suspend/resume** costs one store and reload (budgeted 0.25–0.40 ms P). Vanilla's classic-transparency order draws
   translucent *features* before translucent terrain, so translucent entities end up in `sceneCopy`: acceptable.
   Verify that Sodium's translucent terrain writes depth, or water SSR thickness tests need the copy taken earlier.
4. **Hand detection** assumes main depth holds only the hand after `render3dHud` clears it (decomp `GameRenderer:687`).
   Verify under mcopt with no post chain active.
5. **DRS through a viewport sub-rect** touches vanilla target sizing (entity outline target, post chains, `ScreenSize`).
   Prototype it first. Fallback: discrete scale levels with pooled targets.
6. **Pixel-art under TAAU:** mip bias, Sodium's RGSS, and leaf alpha edges may shimmer. Mitigate with a reactive boost on
   cutout edges, or α_min ↑ for class 10.
7. **XDR GUI double draw** must not collide with FrameGen (they share the mixin). Make them mutually exclusive, as
   MetalFX and FrameGen already are.
8. **Memory** ≈ 0.36–0.47 GB of targets + about 25 MB of assets (+ 230–500 MB of RT acceleration structures in M4) on
   16 GB. Use heap aliasing; gate M4 on free memory.
9. **Art-tuning time** is the real schedule risk (critique §8.2). JSON hot reload and luminance probes are
   non-negotiable tools.
10. **The weather system is per client** (cosmetic). Seeding from the world seed keeps a world consistent between
    sessions; multiplayer clients may disagree.
11. **License hygiene:** the §8 exclusions inside "MIT" trees (Photon's stars and bias, Spectrum's hash) are easy to
    copy by accident. Run the review checklist on every PR.
