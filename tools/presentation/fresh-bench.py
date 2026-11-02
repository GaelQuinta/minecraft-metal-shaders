# Copyright 2026 mcopt-shade contributors. Licensed under the Apache License, Version 2.0.
"""Fresh-frame A/B test; cached dependencies and a disposable offline world."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("jar", type=Path)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--java-home", type=Path, required=True)
parser.add_argument("--prepare-only", action="store_true")
parser.add_argument("--fresh", action="store_true")
parser.add_argument("--schedule-ms", type=float, default=0, help="Experimental input-relative deadline; zero disables it")
parser.add_argument("--fullscreen", action="store_true")
parser.add_argument("--sdr", action="store_true")
parser.add_argument("--phases", default="50,60,120,120g", help="Comma-separated caps; g adds varying GPU load")
parser.add_argument("--sample-ms", type=int, default=10000)
parser.add_argument("--load-scale", type=float, default=1.0, help="GPU work multiplier, 0.25 to 4; affects only g phases")
parser.add_argument("--load-step-ms", type=int, default=237, help="Time between GPU workload changes, 100 to 5000 ms")
parser.add_argument("--output-height", type=int, help="Shader output height; zero keeps native output")
parser.add_argument("--telemetry", action="store_true", help="Record high-precision in-memory telemetry to telemetry.json")
parser.add_argument("--adaptive-pacing", action="store_true", help="Enable GPU-readiness adaptive pacing")
parser.add_argument("--adaptive-safety-margin-ms", type=float, default=1.5, help="Safety margin in ms for adaptive pacing")
parser.add_argument("--adaptive-window-size", type=int, default=8, help="Window size for GPU duration estimator")
opts = parser.parse_args()
if not 0 <= opts.schedule_ms <= 50 or (opts.fresh and opts.schedule_ms):
    parser.error('Use a schedule of 0–50 ms, separately from --fresh')
if not re.fullmatch(r'\d+g?(,\d+g?)*', opts.phases) or any(int(x.rstrip('g')) not in range(10, 261, 5) for x in opts.phases.split(',')):
    parser.error('Phases must use caps from 10 to 260 in steps of 5, with optional g')
if not 1000 <= opts.sample_ms <= 60000:
    parser.error('Sample duration must be 1000–60000 ms')
if not .25 <= opts.load_scale <= 4:
    parser.error('GPU load scale must be 0.25–4')
if not 100 <= opts.load_step_ms <= 5000:
    parser.error('GPU load step must be 100–5000 ms')
jar = opts.jar.resolve()
output = opts.output.resolve()
output.mkdir(parents=True, exist_ok=False)  # preserve previous measurements
prism = Path.home() / "Library/Application Support/PrismLauncher"
game = Path(tempfile.mkdtemp(prefix="mcopt-pacing-ab-", dir="/private/tmp"))
(output / "game-path").write_text(str(game))
java = opts.java_home / "bin"
cp = []
for uid, version in [("org.lwjgl3", "3.4.3"), ("net.minecraft", "26.3"), ("net.fabricmc.fabric-loader", "0.19.5")]:
    meta = json.loads((prism / f"meta/{uid}/{version}.json").read_text())
    for lib in meta.get("libraries", []) + ([meta["mainJar"]] if "mainJar" in meta else []):
        allowed = not lib.get("rules")
        for rule in lib.get("rules", []):
            os_rule = rule.get("os", {})
            if os_rule.get("name", "osx-arm64") == "osx-arm64" and os_rule.get("arch", "aarch64") in ["aarch64", "arm64"]:
                allowed = rule["action"] == "allow"
        if not allowed:
            continue
        group, artifact, ver, *classifier = lib["name"].split(":")
        filename = artifact + "-" + ver + ("-" + classifier[0] if classifier else "") + ".jar"
        path = prism / "libraries" / group.replace(".", "/") / artifact / ver / filename
        if not path.exists():
            raise FileNotFoundError(path)
        cp.append(str(path))
(game / "mods").mkdir()
(game / "config").mkdir()
shutil.copy2(jar, game / "mods")
(game / "options.txt").write_text(
    f"pauseOnLostFocus:false\nenableVsync:{'true'}\nmaxFps:120\n"
    f"fullscreen:{str(opts.fullscreen).lower()}\nexclusiveFullscreen:false\n"
    "renderDistance:4\nsimulationDistance:5\nlang:en_us\nonboardAccessibility:false\n")
(game / "config/mcopt.properties").write_text(
    f"mcopt.shade=true\nmcopt.shade.xdr={str(not opts.sdr).lower()}\nmcopt.shade.hdrMode=scene\n"
    f"mcopt.shade.output={opts.output_height if opts.output_height is not None else (900 if opts.fullscreen else 2160)}\n")
classes = output / "classes"
classes.mkdir(exist_ok=True)
sources = [Path(__file__).with_name(name) for name in ["PacingBench.java", "PollTimingMixin.java", "GpuLoad.java", "GpuLoadMixin.java", "BenchContext.java"]]
subprocess.run([str(java / "javac"), "-proc:none", "-classpath", ":".join(cp + [str(jar)]),
                "-d", str(classes), *map(str, sources)], check=True)
with zipfile.ZipFile(game / "mods/pacing-bench.jar", "w") as archive:
    for file in classes.rglob("*.class"):
        archive.write(file, str(file.relative_to(classes)))
    archive.writestr("fabric.mod.json", json.dumps({
        "schemaVersion": 1, "id": "pacing-bench", "version": "1", "environment": "client",
        "entrypoints": {"client": ["mcopt.pacingbench.PacingBench"]}, "mixins": ["pacing-bench.mixins.json"]}))
    archive.writestr("pacing-bench.mixins.json", json.dumps({
        "required": True, "package": "mcopt.pacingbench.mixin", "compatibilityLevel": "JAVA_25",
        "client": ["PollTimingMixin", "GpuLoadMixin"]}))
load_library = output / "libpacingload.dylib"
subprocess.run(["clang", "-fno-objc-arc", "-O2", "-Wall", "-dynamiclib", "-mmacosx-version-min=15.0",
    "-I", str(Path(__file__).resolve().parents[2] / "metal/src/main/native"),
    "-framework", "AppKit", "-framework", "Metal", "-framework", "QuartzCore",
    str(Path(__file__).with_name("load.m")), str(Path(__file__).with_name("context.m")),
    "-o", str(load_library)], check=True)
args = [
    str(java / "java"), "-XstartOnFirstThread", "-Xmx2G", "--enable-native-access=ALL-UNNAMED",
    "-Dmcopt.shade=true", "-Dmcopt.shade.diag=false",
    f"-Dmcopt.metal.presentFresh={str(opts.fresh).lower()}",
    f"-Dmcopt.metal.presentScheduleMs={opts.schedule_ms}",
    f"-Dmcopt.bench.candidate={str(opts.fresh or opts.schedule_ms > 0 or opts.adaptive_pacing).lower()}",
    "-Dmcopt.metal.presentQueue=acquire",
    "-Dmcopt.metal.gpuTimes=true", "-Dmcopt.metal.latency=true",
    f"-Dmcopt.bench.output={output / 'measurements.json'}",
    f"-Dmcopt.bench.loadLibrary={load_library}",
    f"-Dmcopt.bench.fullscreen={str(opts.fullscreen).lower()}",
    f"-Dmcopt.bench.hdr={str(not opts.sdr).lower()}",
    f"-Dmcopt.bench.phases={opts.phases}", f"-Dmcopt.bench.sampleMs={opts.sample_ms}",
    f"-Dmcopt.bench.loadScale={opts.load_scale}",
    f"-Dmcopt.bench.loadStepMs={opts.load_step_ms}",
    *(["-Dmcopt.metal.telemetry=true", f"-Dmcopt.metal.telemetryOutput={output / 'telemetry.json'}"] if opts.telemetry else []),
    *(["-Dmcopt.metal.adaptivePacing=true",
       f"-Dmcopt.metal.adaptiveSafetyMarginMs={opts.adaptive_safety_margin_ms}",
       f"-Dmcopt.metal.adaptiveWindowSize={opts.adaptive_window_size}"] if opts.adaptive_pacing else []),
    "-classpath", ":".join(cp), "net.fabricmc.loader.impl.launch.knot.KnotClient",
    "--username", "PacingTest", "--uuid", "00000000-0000-0000-0000-000000000001",
    "--accessToken", "0", "--version", "26.3", "--gameDir", str(game),
    "--assetsDir", str(prism / "assets"), "--assetIndex", "34", "--width", "640", "--height", "400"]
if opts.fullscreen:
    args.append("--fullscreen")
(output / "manifest.json").write_text(json.dumps({
    "jar": str(jar), "sha256": hashlib.sha256(jar.read_bytes()).hexdigest(),
    "game": str(game), "args": args, "fresh": opts.fresh,
    "telemetry": opts.telemetry,
    "adaptivePacing": opts.adaptive_pacing,
    "adaptiveSafetyMarginMs": opts.adaptive_safety_margin_ms,
    "adaptiveWindowSize": opts.adaptive_window_size,
    "scheduleMs": opts.schedule_ms, "candidate": opts.fresh or opts.schedule_ms > 0 or opts.adaptive_pacing,
    "fullscreen": opts.fullscreen, "hdr": not opts.sdr,
    "phases": opts.phases, "sampleMs": opts.sample_ms, "outputHeight": opts.output_height,
    "loadScale": opts.load_scale,
    "loadStepMs": opts.load_step_ms,
    "harnessSha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sources
        + [Path(__file__), Path(__file__).with_name('load.m'), Path(__file__).with_name('context.m')]},
    "protocol": "Fixed startup display/policy; native VSync on; varying GPU work BEFORE staging signal; 3s settle per phase; disposable flat world seed 1234"
}, indent=2) + "\n")
if opts.prepare_only:
    print("Prepared without launching:", game)
    raise SystemExit(0)
# Do not profile with the Metal validation layer; this is a cadence measurement.
env = {k: v for k, v in os.environ.items() if not k.startswith("MTL_DEBUG")}
with (output / "game.log").open("w") as log:
    process = subprocess.Popen(args, cwd=game, stdout=log, stderr=subprocess.STDOUT, env=env)
    (output / "game-pid").write_text(str(process.pid))
    try:
        code = process.wait(timeout=120 + len(opts.phases.split(',')) * (3 + opts.sample_ms / 1000))
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)
        raise
for trace in (game / "logs").glob("mcopt-presentation-*.log"):
    shutil.copy2(trace, output / trace.name)
print("Game exit:", code, "profile:", game)
if code or "PACING_BENCH PASS" not in (output / "game.log").read_text():
    raise RuntimeError("Pacing test did not finish; inspect game.log")
print("Measurements:", output / "measurements.json")
