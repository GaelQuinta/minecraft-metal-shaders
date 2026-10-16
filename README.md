# Metal Shaders

**Native Metal shaders for Minecraft: Java Edition on Apple Silicon Macs.** Real-time shadows, volumetric clouds, god rays,
reflective water, HDR and more, written directly in Metal instead of going through OpenGL, at the full resolution of a
Retina display.

![Sunset over the lake](media/hero.jpg)

<p align="center">
  <a href="https://github.com/GaelQuinta/minecraft-metal-shaders/releases/latest"><b>Download</b></a> ·
  <a href="#install">Install</a> ·
  <a href="#performance">Performance</a> ·
  <a href="#features">Features</a> ·
  <a href="#support">☕ Support</a> ·
  <a href="#español">Español</a>
</p>

> **Alpha.** It runs well on the Mac it was built on (MacBook Pro M4), but expect bugs. Back up your worlds.

## Why

Every shader pack for Java Edition runs through Iris on OpenGL, and OpenGL on macOS has been frozen since 2011. On a
MacBook Pro M4 at its native 3024×1964, Iris + Complementary Reimagined runs at about **22 FPS**.

Metal Shaders is a fork of [mcopt](https://github.com/noahdunnagan/mcopt), a mod that gives Minecraft 26.3 a Metal
renderer and, since mcopt 0.3, its own terrain renderer (no Sodium needed). On top of it, every effect is written from
scratch in Metal Shading Language and runs inside the game's own frame, with Apple-GPU-specific tricks (tile memory, compressed render targets, a custom temporal upscaler). Same Mac,
same resolution: **90–120 FPS** with the balanced preset, and **135–150 FPS** at 1440p.

## Videos

Recorded in-game on a MacBook Pro M4 (the camera paths were scripted with the test harness in `bench/`).

| [![Showcase video](media/video-showcase.jpg)](https://github.com/GaelQuinta/minecraft-metal-shaders/releases/download/v1.0-alpha/metal-shaders-showcase.mp4) | [![Presets video](media/video-presets.jpg)](https://github.com/GaelQuinta/minecraft-metal-shaders/releases/download/v1.0-alpha/metal-shaders-presets.mp4) |
|---|---|
| **Showcase** (85 s): sunsets, god rays, water, survival, auroras | **Every preset × every resolution** with F3 (49 s) |

### Gallery

| | |
|---|---|
| ![Lake at sunset](media/lake_sunset.jpg) | ![Cherry grove at sunset](media/cherry_high_sunset.jpg) |
| ![God rays in the jungle](media/jungle_sunset.jpg) | ![Above the clouds](media/clouds_above_sunset.jpg) |
| ![Red sunset over a snowy taiga](media/snowy_red_sunset.jpg) | ![Red sunset on the lake](media/lake_red_sunset.jpg) |
| ![Aurora over the snowy slopes](media/aurora_slopes.jpg) | ![Aurora and stars over the lake](media/night_lake_stars.jpg) |
| ![Morning in the cherry grove](media/cherry_walk_morning.jpg) | ![Badlands at sunset](media/badlands_sunset.jpg) |

Full-resolution photos (3024×1964) are in the [release](https://github.com/GaelQuinta/minecraft-metal-shaders/releases/latest).

## Performance

MacBook Pro 14" M4 (10-core GPU), macOS 26, Minecraft 26.3, measured in-game with 1.0-alpha while recording the videos
above (the recorder costs a few FPS). F3 shows the numbers in each clip. 1.2 (mcopt 0.3, no Sodium) runs at the same speed as before: measured against 1.1 on the same Mac, +0.8 % in a lake test and −1.1 % in a fast flight over new terrain (+1.6 % / −0.5 % with Distant Horizons).

Average FPS over each 10-second clip, 16 chunks, while recording the video (F3 on):

| Preset | Output | Lake sunset | Cherry forest | Mountain sunrise |
|---|---|---|---|---|
| Performance | 3024×1964 (native) | 94 | 128 | 128 |
| Performance | 2218×1440 | 136 | 165 | 150 |
| Performance | 1662×1080 | 159 | 249 | 223 |
| Balanced | 3024×1964 (native) | 92 | 118 | 118 |
| Balanced | 2218×1440 | 137 | 148 | 142 |
| Balanced | 1662×1080 | 142 | 220 | 194 |
| Quality | 3024×1964 (native) | 55 | 85 | 78 |
| Quality | 2218×1440 | 86 | 119 | 107 |
| Quality | 1662×1080 | 113 | 179 | 155 |
| Ultra | 3024×1964 (native) | 42 | 70 | 63 |
| Ultra | 2218×1440 | 66 | 105 | 89 |
| Ultra | 1662×1080 | 92 | 155 | 126 |

For reference, on the same Mac: Iris + Complementary Reimagined (OpenGL) at 3024×1964 ≈ 22 FPS, at 1080p ≈ 43 FPS.

## Features

- **Shadows** from the sun and the moon (cascaded shadow maps, soft contact-hardening shadows), coloured shadows through
  stained glass, entity shadows.
- **Lighting**: sky light, block light and bounce, held lights (a torch in your hand lights the world around you, around
  corners), emissive blocks.
- **Sky**: physically based atmosphere, sun and moon discs, stars and the Milky Way, **aurora** in cold biomes.
- **An in-game settings menu** (pause menu → **Shaders...**): about 120 settings on 11 pages (lighting, shadows, colour and
  camera, atmosphere, god rays, clouds, night sky, water, weather, Nether and End, performance), in English and Spanish, most
  of them applied live while you watch.
- **Volumetric clouds** with cloud shadows, lit by the sunset; or **blocky clouds**: Minecraft's own cloud shapes with volume,
  sunlight, shadows and reflections; or the game's normal clouds.
- **God rays** (volumetric light) through forests, cave mouths and clouds; morning mist and forest air.
- **Water**: waves, screen-space reflections, refraction, absorption, caustics, foam, **waterfalls with white water**,
  underwater fog and light shafts.
- **Weather**: wet surfaces and puddles, rain ripples, lightning.
- **HDR** pipeline with bloom, auto-exposure, a filmic tonemap, and **XDR/EDR** output on Liquid Retina XDR displays.
- **TAAU** (temporal anti-aliasing and upscaling) and dynamic resolution; an **output resolution** button in the pause menu.
- Nether and End looks.
- **Distant Horizons** support: the far LODs are lit by the same shaders (lighting, fog, water reflections).
- Presets: `performance`, `balanced`, `quality`, `ultra`; looks: `epic`, `storybook`, `natural`.
- Runs on **macOS 15 Sequoia, 26 and 27**. The shaders compile in the background, so the first world load after installing
  or updating macOS takes a fraction of a second instead of a few seconds.

## Install

You need:

- An **Apple Silicon Mac** (M1 or newer) on **macOS 15 Sequoia** or later
- **Minecraft: Java Edition 26.3** with **Fabric Loader 0.19.5** or newer, on **Java 25**

That's all: since 1.2 **Sodium is not needed** (mcopt 0.3 draws the terrain itself), and the game won't start with Sodium
installed next to it.

Steps:

1. Install Fabric for 26.3 ([installer](https://fabricmc.net/use/installer/), or in Prism Launcher: new instance → 26.3 → Fabric).
2. Put `metal-shaders-<version>.jar` (from [Releases](https://github.com/GaelQuinta/minecraft-metal-shaders/releases/latest))
   in your `mods` folder.
3. Start the game. The shaders are on from the first launch (balanced preset).

**Updating from 1.0:** take Sodium out of the `mods` folder and replace the old Metal Shaders jar. Your settings are kept
(the config's `profile=alpha` line changes to `profile=indie` by itself, the terrain renderer the shaders light).

**Settings:** pause the game and press **Shaders...** (above the Resolution and Output buttons). Changes show at once behind
the menu; the ones marked with `*` apply after restarting the game. **Reset page** / **Reset all** bring back the defaults.
The **Fabulous** graphics preset works too (since 1.2.2; before, it made the water invisible).
**General → Shaders: On/Off** (since 1.2.1) turns the shaders off after a restart, so the game runs plain mcopt 0.3 (Metal
without effects, more FPS); the pause menu keeps its **Shaders...** button to turn them back on.
Everything you change is saved in `config/mcopt.properties` in your game folder (written on the first launch), where you can
also edit it by hand:

| Key | Values | Default |
|---|---|---|
| `mcopt.shade` | `true` / `false` (false = mcopt's plain Metal renderer) | `true` |
| `mcopt.shade.preset` | `performance`, `balanced`, `quality`, `ultra` | `balanced` |
| `mcopt.shade.look` | `epic`, `storybook`, `natural` | `epic` |
| `mcopt.shade.resolution` | `auto`, `native`, `2160`, `1800`, `1600`, `1440`, `1200`, `1080` (also the **Resolution** button in the pause menu) | `auto` |
| `mcopt.shade.output` | `native`, `2160`, `1440`, `1200`, `1080`, `900` (also the **Output** button in the pause menu) | `native` |
| `profile` | `indie` (mcopt's own terrain renderer, needed by the shaders), `none` | `indie` |

For the most FPS: Video Settings → VSync off, Max Framerate unlimited. To see your FPS, press **F3**.

**Distant Horizons** (optional): add Distant Horizons 3.3.4 for 26.3 and Fabric API to the mods folder. It runs on Metal
too, and its far terrain is lit by the same shaders (DH's own SSAO, anti-aliasing and fog are turned off while they run).
Since **1.2.2**, **Shaders... → Performance → Distant Horizons** picks DH's distance and detail from presets tested with the
shaders (DH's own / Performance 32 chunks / Balanced 64, the default / Quality 96 / Ultra 128; on an M4 at 1080p with 8 normal
chunks: about 168 / 134 / 114 / 109 FPS), and DH's far water always gets the shaders' water, even with DH's transparency off.
With DH, 8 to 12 normal chunks look and run well.

- **Bottom half of the screen dark with DH?** DH's *Vanilla Fade Mode* is on `DOUBLE_PASS` (DH's default), which clashes
  with the shaders. Since **1.0-alpha.2** the mod sets it to `NONE` by itself at startup. On 1.0-alpha: open
  `config/DistantHorizons.toml`, set `vanillaFadeMode = "NONE"` (or `SINGLE_PASS`), and restart the game (DH reads it only
  at startup).

## How it was made

- `metal/` — the mod (fork of mcopt 0.3.0-alpha.2). The shading code is in `metal/src/main/resources/mcopt/shade/*.metal`
  (the terrain's in `terrain_own.metal`) and `metal/src/main/java/mcopt/metal/shade/`. Everything new sits behind
  `mcopt.shade` flags: with `mcopt.shade=false` the mod behaves like upstream mcopt.
- `docs/shader-bible.md` — the design of every effect (E01–E27), frame budgets and licensing. `docs/research/` — studies
  of Apple GPUs, the 26.3 renderer, Iris, Distant Horizons and other packs' techniques. `docs/releases/` — notes of every
  version (in Spanish).
- `bench/` — the test harness: `mcbench` (an in-game benchmark mod: a fixed world, camera routes, screenshots, frame
  times, and the "cine" mode that recorded the videos above) and the scripts that launch the game and measure it.

Build: `./gradlew :metal:build` with JDK 25 → `metal/build/libs/`.

<!-- support:start -->
## Support

Metal Shaders is free and open source, and it will stay that way. If you enjoy it and want to say thanks, you can buy me a
coffee on [Ko-fi](https://ko-fi.com/gaelquintanilla) or [GitHub Sponsors](https://github.com/sponsors/GaelQuinta). It helps me keep testing and adding things. It's built on [mcopt](https://github.com/noahdunnagan/mcopt)
by Noah Dunnagan, so a star on his repo is a nice thank-you too.

<p>
<a href="https://ko-fi.com/gaelquintanilla"><img alt="Support on Ko-fi" src="https://img.shields.io/badge/Ko--fi-Buy%20me%20a%20coffee-FF5E5B?logo=kofi&logoColor=white"></a>
<a href="https://github.com/sponsors/GaelQuinta"><img alt="GitHub Sponsors" src="https://img.shields.io/badge/GitHub%20Sponsors-Sponsor-EA4AAA?logo=githubsponsors&logoColor=white"></a>
</p>
<!-- support:end -->

## Credits and licences

- **mcopt** by Noah Dunnagan — Apache-2.0. Since 1.2 (mcopt 0.3) nothing is derived from Sodium; versions up to 1.0-alpha.4
  had Sodium-derived terrain shaders under the PolyForm Shield 1.0.0 licence.
- Portions of the clouds and volumetric light are adapted from **Photon Shaders** by sixthsurge, from its MIT-licensed
  snapshot `26c2906e` (`LICENSES/MIT-Photon.txt`). Other techniques credited in `NOTICE` (SE Natural Bloom, MJP's
  Catmull-Rom, public papers). No code from Complementary, BSL or SEUS: those were only studied.
- Distant Horizons is LGPL and is not included; install it separately.
- Shader code and the harness: Apache-2.0. Not affiliated with Mojang or Microsoft.

Made by Gael Quintanilla, with Claude (Anthropic) writing most of the code.

---

## Español

**Shaders nativos en Metal para Minecraft Java en Macs con Apple Silicon.** Sombras, nubes volumétricas, rayos de sol
(godrays), agua con reflejos, HDR y más, escritos directamente en Metal en lugar de pasar por OpenGL.

En una MacBook Pro M4 a resolución completa (3024×1964), Iris + Complementary corre a ~22 FPS. Con Metal Shaders,
la misma Mac a la misma resolución da **90–120 FPS** (preset balanceado), y **135–150 FPS** a 1440p.

**Instalación:** Mac con Apple Silicon y macOS 15 Sequoia o más nuevo (también 26 y 27), Minecraft 26.3 con Fabric 0.19.5 y
Java 25. Desde la 1.2 **ya no hace falta Sodium** (mcopt 0.3 dibuja el terreno por su cuenta; con Sodium instalado el juego no
arranca). Pon el jar de [Releases](https://github.com/GaelQuinta/minecraft-metal-shaders/releases/latest) en la carpeta `mods`
y abre el juego: los shaders se activan solos (preset balanceado). **Si vienes de la 1.0:** quita Sodium de `mods` y cambia el
jar viejo por el nuevo; tus ajustes se conservan.

**Ajustes:** pausa el juego y entra a **Shaders...**: unos 120 ajustes en 11 páginas (iluminación, sombras, color y cámara,
atmósfera, rayos de sol, nubes, cielo de noche, agua, clima, Nether y End, rendimiento), en español e inglés según el idioma del
juego. Casi todos se ven al momento; los marcados con `*` se aplican al reiniciar. Nubes: volumétricas, **cuadradas** (las de
Minecraft con volumen, luz y sombras), las normales del juego, o ninguna. **General → Shaders: Sí/No** (desde la 1.2.1) los apaga al reiniciar para usar mcopt 0.3 tal cual (más FPS); el botón **Shaders...** sigue en el menú de pausa para volver a prenderlos. La resolución de salida se cambia con el botón
**"Salida"** del menú de pausa. Compatible con Distant Horizons 3.3.4 + Fabric API (opcional); desde la 1.2.2, en **Shaders... → Rendimiento → Distant Horizons** eliges presets de DH probados con los shaders (Rendimiento, Balanceado, Calidad, Ultra), y el agua lejana de DH siempre tiene los reflejos de los shaders. El preset gráfico **Fabulous** ya funciona (antes el agua se volvía invisible). Si con DH la mitad de
abajo de la pantalla se ve oscura (versión 1.0-alpha): en `config/DistantHorizons.toml` pon `vanillaFadeMode = "NONE"` y
reinicia el juego; desde la 1.0-alpha.2 el mod lo hace solo.

Es una versión alfa: haz respaldo de tus mundos.

<!-- apoyo:start -->
**Apoyar el proyecto:** es gratis y lo seguirá siendo. Si te gusta y quieres invitarme un café: [Ko-fi](https://ko-fi.com/gaelquintanilla) o [GitHub Sponsors](https://github.com/sponsors/GaelQuinta).
<!-- apoyo:end -->
