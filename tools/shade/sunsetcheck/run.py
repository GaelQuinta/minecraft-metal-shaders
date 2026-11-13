#!/usr/bin/env python3
# Copyright 2026 mcopt-shade contributors. Apache-2.0.
"""Build :metal:build first. Run with JDK 25 and Metal access. Optional BASELINE_JAR."""
import os
from pathlib import Path
import subprocess
import sys

here=Path(__file__).resolve().parent
root=here.parents[2]
out=Path(sys.argv[1]).resolve(); out.mkdir(parents=True,exist_ok=True)
cache=Path(os.environ.get('GRADLE_USER_HOME',str(Path.home()/'.gradle')))/'caches/modules-2/files-2.1'
deps=[]
for group in ['org.joml/joml','org.lwjgl/lwjgl','org.lwjgl/lwjgl-stb','net.fabricmc/fabric-loader']:
    deps.extend(str(p) for p in sorted((cache/group).rglob('*.jar')) if 'sources' not in p.name and 'javadoc' not in p.name)
base=[os.environ['BASELINE_JAR']] if 'BASELINE_JAR' in os.environ else [str(root/'metal/build/classes/java/main'),str(root/'metal/src/main/resources')]
cp=os.pathsep.join(base+deps)
java=Path(os.environ['JAVA_HOME'])/'bin' if 'JAVA_HOME' in os.environ else Path('')
classes=out/'classes'; classes.mkdir(exist_ok=True)
def run(args): subprocess.run([str(a) for a in args],check=True)
run([java/'javac','-cp',cp,'-d',classes,here/'SunsetFixtures.java'])
run([java/'java','--enable-native-access=ALL-UNNAMED','-Dmcopt.shade=true','-cp',str(classes)+os.pathsep+cp,'SunsetFixtures',out])
run(['clang','-fobjc-arc','-O2','-framework','Foundation','-framework','Metal',here/'check.m','-o',out/'check'])
run([out/'check',out,here/'probe.metal'])
sys.exit(subprocess.run([sys.executable,str(here/'verify.py'),str(out)]+sys.argv[2:]).returncode)
