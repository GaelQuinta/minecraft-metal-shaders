#!/usr/bin/env python3
# Copyright 2026 mcopt-shade contributors. Apache-2.0.
import os,subprocess,sys
from pathlib import Path
here=Path(__file__).resolve().parent;root=here.parents[2];out=Path(sys.argv[1]).resolve();out.mkdir(parents=True,exist_ok=True)
java=Path(os.environ['JAVA_HOME'])/'bin';cache=Path(os.environ['GRADLE_USER_HOME'])/'caches'
deps=[str(p) for g in ['org.joml/joml','org.lwjgl/lwjgl','org.lwjgl/lwjgl-stb','net.fabricmc/fabric-loader','org.jspecify/jspecify'] for p in (cache/'modules-2/files-2.1'/g).rglob('*.jar') if 'sources' not in p.name]
deps += [str(p) for p in cache.rglob('minecraft-merged-deobf-26.3.jar')]
cp=':'.join([str(out),str(root/'metal/build/classes/java/main'),str(root/'metal/build/resources/main')]+deps)
subprocess.run([str(java/'javac'),'-cp',cp,'-d',str(out),str(here/'EarlyTerrainCheck.java')],check=True)
subprocess.run([str(java/'java'),'--enable-native-access=ALL-UNNAMED','-Dmcopt.shade=true','-cp',cp,'mcopt.metal.EarlyTerrainCheck'],check=True)
