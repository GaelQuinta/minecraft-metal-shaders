#!/usr/bin/env python3
# Copyright 2026 mcopt-shade contributors. Apache-2.0.
from pathlib import Path
import subprocess,os
import sys
r=Path(__file__).resolve().parents[3];out=Path(sys.argv[1]).resolve();out.mkdir(parents=True,exist_ok=True)
j=Path(os.environ['JAVA_HOME'])/'bin';cache=Path(os.environ.get('GRADLE_USER_HOME',str(Path.home()/'.gradle')))/'caches/modules-2/files-2.1'
deps=[str(p) for group in ['org.joml/joml','org.lwjgl/lwjgl','org.lwjgl/lwjgl-stb','net.fabricmc/fabric-loader'] for p in sorted((cache/group).rglob('*.jar')) if 'sources' not in p.name and 'javadoc' not in p.name]
cp=os.pathsep.join([str(r/'metal/build/classes/java/main'),str(r/'metal/src/main/resources')]+deps)
def run(a):subprocess.run([str(x) for x in a],check=True)
run([j/'javac','-cp',cp,'-d',out,r/'tools/shade/lavacheck/LavaSources.java',r/'tools/shade/own/OwnDump.java'])
run([j/'java','-Dmcopt.shade=true','-cp',str(out)+':'+cp,'LavaSources',out/'lava.metal'])
run([j/'java','-Dmcopt.shade=true','-cp',str(out)+':'+cp,'OwnDump',out/'terrain'])
run(['clang','-fobjc-arc','-O2','-framework','Foundation','-framework','Metal',r/'tools/shade/lavacheck/check.m','-o',out/'check'])
run([out/'check',out/'lava.metal',r/'tools/shade/lavacheck/probe.metal'])
run(['clang','-fobjc-arc','-O1','-framework','Foundation','-framework','Metal',r/'tools/shade/pipecheck.m','-o',out/'pipecheck'])
for p in sorted((out/'terrain').glob('frag_*.metal')):run([out/'pipecheck','compile',p])
print('PASS all 22 terrain libraries including PBR, Nether, dry and water')
