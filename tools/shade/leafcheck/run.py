#!/usr/bin/env python3
# Copyright 2026 mcopt-shade contributors. Apache-2.0.
import os, pathlib, subprocess, sys
here=pathlib.Path(__file__).resolve().parent; root=here.parents[2]
out=pathlib.Path(sys.argv[1] if len(sys.argv)>1 else '/tmp/metal-leafcheck');out.mkdir(parents=True,exist_ok=True)
java=pathlib.Path(os.environ['JAVA_HOME'])/'bin';cache=pathlib.Path(os.environ.get('GRADLE_USER_HOME',str(pathlib.Path.home()/'.gradle')))/'caches'
cp=[str(root/'metal/build/classes/java/main'),str(root/'metal/src/main/resources')]
for group in ['org.joml/joml','org.lwjgl/lwjgl','org.lwjgl/lwjgl-stb','net.fabricmc/fabric-loader','org.jspecify/jspecify']:
 cp += [str(p) for p in (cache/'modules-2/files-2.1'/group).rglob('*.jar') if 'sources' not in p.name]
cp += [str(p) for p in cache.rglob('minecraft-merged-deobf-26.3.jar')]
cp=':'.join(cp);classes=out/'classes';classes.mkdir(exist_ok=True)
subprocess.run([str(java/'javac'),'-cp',cp,'-d',str(classes),str(here/'Fixtures.java')],check=True)
subprocess.run([str(java/'java'),'--enable-native-access=ALL-UNNAMED','-Dmcopt.shade=true','-cp',cp+':'+str(classes),'mcopt.metal.shade.Fixtures',str(out)],check=True)
subprocess.run(['clang','-fobjc-arc','-O2','-framework','Foundation','-framework','Metal',str(here/'check.m'),'-o',str(out/'check')],check=True)
subprocess.run([str(out/'check'),str(out),str(here)],check=True)
