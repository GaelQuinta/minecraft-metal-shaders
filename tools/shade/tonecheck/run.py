#!/usr/bin/env python3
# Copyright 2026 mcopt-shade contributors. Apache-2.0.
"""After :metal:build. Args: output folder, baseline JAR. Offscreen only; JDK 25 and Metal required."""
import os,struct,subprocess,sys
from pathlib import Path
here=Path(__file__).resolve().parent;root=here.parents[2];clouds=here.parent/'clouds'
out=Path(sys.argv[1]).resolve();out.mkdir(parents=True,exist_ok=True)
java=Path(os.environ['JAVA_HOME'])/'bin'
cache=Path(os.environ.get('GRADLE_USER_HOME',str(Path.home()/'.gradle')))/'caches/modules-2/files-2.1'
deps=[]
for group in ['org.joml/joml','org.lwjgl/lwjgl','org.lwjgl/lwjgl-stb','net.fabricmc/fabric-loader']:
 deps.extend(str(p) for p in sorted((cache/group).rglob('*.jar')) if 'sources' not in p.name and 'javadoc' not in p.name)
cp=os.pathsep.join([str(root/'metal/build/classes/java/main'),str(root/'metal/src/main/resources')]+deps)
def run(args,env=None):subprocess.run([str(a) for a in args],check=True,env=env)
run([java/'javac','-cp',cp,'-d',out,here/'ToneFixtures.java'])
for tag,classpath in [('tone-before',os.pathsep.join([str(Path(sys.argv[2]).resolve())]+deps)),('tone-after',cp)]:
 run([java/'java','--enable-native-access=ALL-UNNAMED','-Dmcopt.shade=true','-cp',str(out)+os.pathsep+classpath,'ToneFixtures',out/tag])
run(['clang','-fobjc-arc','-O2','-framework','Foundation','-framework','Metal',here/'tonecheck.m','-o',out/'tonecheck'])
run([out/'tonecheck',out/'tone-before',out/'tone-after'])
