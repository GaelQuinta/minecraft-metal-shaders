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
run([java/'javac','-cp',cp,'-d',out,clouds/'CloudPreviewFrames.java',clouds/'CloudPreviewSource.java'])
run([java/'java','--enable-native-access=ALL-UNNAMED','-cp',str(out)+os.pathsep+cp,'CloudPreviewSource',out/'clouds.metal',out/'lut.metal',clouds/'preview_composite.metal'])
run([java/'java','--enable-native-access=ALL-UNNAMED','-cp',str(out)+os.pathsep+cp,'CloudPreviewFrames',out/'frames','960','620','.4','48','noon_up|afternoon_back|sunset_toward|storm'])
run(['clang','-fobjc-arc','-O1','-Wno-enum-conversion','-framework','Foundation','-framework','Metal','-framework','CoreGraphics','-framework','ImageIO','-framework','UniformTypeIdentifiers',clouds/'cloudpreview.m','-o',out/'preview'])
for p in sorted((out/'frames').glob('*.params')):run([out/'preview',out/'clouds.metal',out/'lut.metal',out/'frames',p.stem,'960','620',out/(p.stem+'.png'),'0'])
