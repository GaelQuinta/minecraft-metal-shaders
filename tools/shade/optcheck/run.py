#!/usr/bin/env python3
# Copyright 2026 mcopt-shade contributors. Apache-2.0.
"""After :metal:build: JDK 25, clang and Metal access required. Never launches Minecraft."""
import os, subprocess, sys
from pathlib import Path
here=Path(__file__).resolve().parent;root=here.parents[2]
out=Path(sys.argv[1]).resolve();out.mkdir(parents=True,exist_ok=True)
java=Path(os.environ['JAVA_HOME'])/'bin'
cache=Path(os.environ.get('GRADLE_USER_HOME',str(Path.home()/'.gradle')))/'caches/modules-2/files-2.1'
deps=[]
for group in ['org.joml/joml','org.lwjgl/lwjgl','org.lwjgl/lwjgl-stb','net.fabricmc/fabric-loader']:
    deps.extend(str(p) for p in sorted((cache/group).rglob('*.jar')) if 'sources' not in p.name and 'javadoc' not in p.name)
cp=os.pathsep.join([str(root/'metal/build/classes/java/main'),str(root/'metal/src/main/resources'),str(root/'metal/build/resources/main')]+deps)
def run(args):subprocess.run([str(x) for x in args],check=True)
run([java/'javac','-cp',cp,'-d',out,here/'PassFixtures.java',here/'PassAbiCheck.java'])
run([java/'java','--enable-native-access=ALL-UNNAMED','-cp',cp+os.pathsep+str(out),'mcopt.metal.shade.PassAbiCheck'])
run([java/'java','--enable-native-access=ALL-UNNAMED','-Dmcopt.shade=true','-cp',cp+os.pathsep+str(out),'PassFixtures',out/'post.metal'])
lib=root/'metal/build/natives/natives/libmcmetal.dylib'
for tool in ['passcheck','bloomcheck']:
    run(['clang','-fobjc-arc','-O2','-framework','Foundation','-framework','Metal','-framework','ImageIO','-framework','CoreGraphics',here/(tool+'.m'),lib,'-Wl,-rpath,'+str(lib.parent),'-o',out/tool])
run([out/'passcheck',out/'post.metal'])
run([out/'bloomcheck',out/'post.metal',here/'bloom_reference.metal',here/'bloom_probe.metal',out])
