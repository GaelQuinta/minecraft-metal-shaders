#!/usr/bin/env python3
# Copyright 2026 mcopt-shade contributors. Licensed under the Apache License, Version 2.0.
"""Build first. Run the actual settings classes in four presets, and compare atmosphere outputs with BASELINE_JAR."""
import os, pathlib, subprocess, tempfile
here=pathlib.Path(__file__).resolve().parent;root=here.parents[2]
out=pathlib.Path(tempfile.mkdtemp(prefix='mcopt127-java-'))
java=pathlib.Path(os.environ['JAVA_HOME'])/'bin'
joml=next(p for p in (pathlib.Path.home()/'.gradle/caches/modules-2/files-2.1/org.joml/joml').rglob('joml-*.jar') if 'sources' not in p.name)
lw=pathlib.Path.home()/'Library/Application Support/PrismLauncher/libraries/org/lwjgl'
cp=':'.join(map(str,[root/'metal/build/classes/java/main',root/'metal/src/main/resources',joml,lw/'lwjgl/3.4.3/lwjgl-3.4.3.jar',lw/'lwjgl-natives-macos-arm64/3.4.3/lwjgl-natives-macos-arm64-3.4.3.jar']))
subprocess.run([str(java/'javac'),'-cp',cp,'-d',str(out),str(here/'PercentCheck.java'),str(here/'SkyCheck.java')],check=True)
for preset in ['performance','balanced','quality','ultra']:
    r=subprocess.run([str(java/'java'),'--enable-native-access=ALL-UNNAMED','-Dmcopt.shade=true','-Dmcopt.shade.preset='+preset,'-cp',str(out)+':'+cp,'mcopt.metal.shade.PercentCheck',str(out/preset)],text=True,capture_output=True)
    (out/(preset+'.log')).write_text(r.stdout+r.stderr)
    if r.returncode: raise RuntimeError(r.stdout+r.stderr)
    print(preset,r.stdout.splitlines()[-1])
subprocess.run([str(java/'java'),'-cp',str(out)+':'+cp,'mcopt.metal.shade.SkyCheck',str(out/'new.bin'),'new'],check=True)
if 'BASELINE_JAR' in os.environ:
    subprocess.run([str(java/'java'),'-cp',str(out)+':'+os.environ['BASELINE_JAR'],'mcopt.metal.shade.SkyCheck',str(out/'old.bin')],check=True)
    assert (out/'old.bin').read_bytes()==(out/'new.bin').read_bytes(),'atmosphere changed at default settings'
    print('OK 1024 default atmosphere cases: bitwise identical to baseline')
print('Evidence:',out)
