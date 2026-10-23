"""Allocation/GC profile; uses cached Prism dependencies and a disposable offline world."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("jar", type=Path)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--java-home", type=Path, required=True)
parser.add_argument("--prepare-only", action="store_true")
parser.add_argument("--amplified", action="store_true")
parser.add_argument("--verify", action="store_true", help="Check packing through the applied mixin before profiling")
opts = parser.parse_args()
jar = opts.jar.resolve()
output = opts.output.resolve()
output.mkdir(parents=True, exist_ok=False)  # preserve previous measurements
prism = Path.home() / "Library/Application Support/PrismLauncher"
game = Path(tempfile.mkdtemp(prefix="mcopt-allocation-", dir="/private/tmp"))
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
    "pauseOnLostFocus:false\nenableVsync:true\nmaxFps:120\nfullscreen:false\n"
    "renderDistance:12\nsimulationDistance:5\nlang:en_us\nonboardAccessibility:false\n")
(game / "config/mcopt.properties").write_text(
    "mcopt.shade=true\nmcopt.shade.hdrMode=scene\nmcopt.shade.output=2160\n")
classes = output / "classes"
classes.mkdir(exist_ok=True)
sources = [Path(__file__).with_name(name) for name in ["AllocationBench.java", "FrameMixin.java"]]
if opts.verify:
    sources.append(Path(__file__).with_name("PalettePackingCheck.java"))
subprocess.run([str(java / "javac"), "-proc:none", "-classpath", ":".join(cp + [str(jar)]),
                "-d", str(classes), *map(str, sources)], check=True)
with zipfile.ZipFile(game / "mods/allocation-bench.jar", "w") as archive:
    for file in classes.rglob("*.class"):
        archive.write(file, str(file.relative_to(classes)))
    archive.writestr("fabric.mod.json", json.dumps({
        "schemaVersion": 1, "id": "allocation-bench", "version": "1", "environment": "client",
        "entrypoints": {"client": ["mcopt.allocationbench.AllocationBench"]}, "mixins": ["allocation-bench.mixins.json"]}))
    archive.writestr("allocation-bench.mixins.json", json.dumps({
        "required": True, "package": "mcopt.allocationbench.mixin", "compatibilityLevel": "JAVA_25",
        "client": ["FrameMixin"]}))
args = [
    str(java / "java"), "-XstartOnFirstThread", "-Xmx4G", "--enable-native-access=ALL-UNNAMED",
    "-Dmcopt.shade=true", "-Dmcopt.shade.diag=true",
    f"-Dmcopt.allocbench.output={output}",
    f"-Dmcopt.allocbench.amplified={str(opts.amplified).lower()}",
    f"-Dmcopt.allocbench.verify={str(opts.verify).lower()}",
    f"-Xlog:gc*:file={output / 'gc.log'}:time,uptime,level,tags",
    "-classpath", ":".join(cp), "net.fabricmc.loader.impl.launch.knot.KnotClient",
    "--username", "AllocationTest", "--uuid", "00000000-0000-0000-0000-000000000001",
    "--accessToken", "0", "--version", "26.3", "--gameDir", str(game),
    "--assetsDir", str(prism / "assets"), "--assetIndex", "34", "--width", "640", "--height", "400"]
if opts.prepare_only:
    print("Prepared without launching:", game)
    raise SystemExit(0)
(output / "manifest.json").write_text(json.dumps({
    "jar": str(jar), "sha256": hashlib.sha256(jar.read_bytes()).hexdigest(),
    "game": str(game), "args": args, "metalValidation": False,
    "worldPreset": "amplified" if opts.amplified else "normal",
    "protocol": "Windowed HDR, VSync 120 cap, 12 chunks, fresh seed 1234; JFR stationary 20s then flight 30s at 25 blocks/s",
}, indent=2) + "\n")
# Do not profile with the Metal validation layer; this is a cadence measurement.
env = {k: v for k, v in os.environ.items() if not k.startswith("MTL_DEBUG")}
with (output / "game.log").open("w") as log:
    process = subprocess.Popen(args, cwd=game, stdout=log, stderr=subprocess.STDOUT, env=env)
    (output / "game-pid").write_text(str(process.pid))
    try:
        code = process.wait(timeout=330)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)
        raise
print("Game exit:", code, "profile:", game)
if code or "ALLOCATION_BENCH PASS" not in (output / "game.log").read_text():
    raise RuntimeError("Allocation test did not finish; inspect game.log")
print("Profiles:", output)
