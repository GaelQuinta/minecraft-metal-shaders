#!/usr/bin/env python3
# Copyright 2026 mcopt-shade contributors. Apache-2.0.
import os,subprocess,sys
from pathlib import Path
here=Path(__file__).resolve().parent;root=here.parents[2];out=Path(sys.argv[1]).resolve();out.mkdir(parents=True,exist_ok=True)
java=Path(os.environ['JAVA_HOME'])/'bin';cache=Path(os.environ.get('GRADLE_USER_HOME',root/'.gradle-cache'))/'caches/modules-2/files-2.1'
deps=[str(p) for g in ['org.joml/joml','org.lwjgl/lwjgl','org.lwjgl/lwjgl-stb','net.fabricmc/fabric-loader'] for p in (cache/g).rglob('*.jar') if 'sources' not in p.name]
cp=':'.join([str(root/'metal/build/classes/java/main'),str(root/'metal/src/main/resources')]+deps)
subprocess.run([str(java/'javac'),'-cp',cp,'-d',str(out),str(here/'Fixtures.java')],check=True)
subprocess.run([str(java/'java'),'-Dmcopt.shade=true','-cp',str(out)+':'+cp,'Fixtures',str(out)],check=True)
subprocess.run(['clang','-fobjc-arc','-O2','-framework','Foundation','-framework','Metal','-framework','CoreGraphics','-framework','ImageIO','-framework','UniformTypeIdentifiers',str(here/'check.m'),'-o',str(out/'check')],check=True)
subprocess.run([str(out/'check'),str(out),str(here/'probe.metal')],check=True)
