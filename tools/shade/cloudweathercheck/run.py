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
run([java/'javac','-cp',cp,'-d',out,here/'WeatherCheck.java',clouds/'CloudPreviewFrames.java',clouds/'CloudPreviewSource.java'])
run([java/'java','-cp',str(out)+os.pathsep+cp,'WeatherCheck'])
run([java/'java','--enable-native-access=ALL-UNNAMED','-cp',str(out)+os.pathsep+cp,'CloudPreviewSource',out/'clouds.metal',out/'lut.metal',clouds/'preview_composite.metal'])
run([java/'java','--enable-native-access=ALL-UNNAMED','-cp',str(out)+os.pathsep+cp,'CloudPreviewFrames',out/'frames','960','620','.4','48','noon_up|afternoon_back|sunset_toward|storm'])
run(['clang','-fobjc-arc','-O1','-Wno-enum-conversion','-framework','Foundation','-framework','Metal','-framework','CoreGraphics','-framework','ImageIO','-framework','UniformTypeIdentifiers',clouds/'cloudpreview.m','-o',out/'preview'])
for p in sorted((out/'frames').glob('*.params')):run([out/'preview',out/'clouds.metal',out/'lut.metal',out/'frames',p.stem,'960','620',out/(p.stem+'.png'),'0'])
# A true zero-coverage front must leave both sky and ground-shadow transmittance at one.
for ext in ['frame','look']:(out/'frames'/('clear.'+ext)).write_bytes((out/'frames'/('noon_up.'+ext)).read_bytes())
p=bytearray((out/'frames/noon_up.params').read_bytes())
for offset in range(0,len(p),448):
 struct.pack_into('<f',p,offset+176,0) # cumulus coverage
 struct.pack_into('<f',p,offset+216,0) # cirrus coverage
(out/'frames/clear.params').write_bytes(p)
env=os.environ.copy();env['CLOUDS_DUMP']=str(out/'clear.bin');env['CLOUDS_SHADOW_DUMP']=str(out/'clear-shadow.bin')
run([out/'preview',out/'clouds.metal',out/'lut.metal',out/'frames','clear','960','620',out/'clear.png','0'],env)
for rgba in struct.iter_unpack('<eeee',(out/'clear.bin').read_bytes()):assert rgba==(0.,0.,0.,1.),rgba
for (transmission,) in struct.iter_unpack('<e',(out/'clear-shadow.bin').read_bytes()):assert transmission==1.,transmission
print('PASS clear sky: all march pixels transparent; all 65,536 cloud-shadow pixels fully lit')
