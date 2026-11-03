from pathlib import Path
import subprocess
import os,sys
here=Path(__file__).resolve().parent;r=here.parents[2];out=Path(sys.argv[1] if len(sys.argv)>1 else '/tmp/cloud-byteorder').resolve();out.mkdir(exist_ok=True);s=(r/'metal/src/main/java/mcopt/metal/shade/clouds/ShadeClouds.java').read_text();statement=next(l.strip() for l in s.splitlines() if 'putFloat(' in l and 'CLOUDS0 + 12' in l)
source='''import java.nio.*;
import mcopt.metal.shade.*;
import mcopt.metal.shade.clouds.*;
public class CloudByteOrderCheck {
 public static void main(String[] args) {
  // ShadeBindings.currentLook() returns a slice: Java resets its byte order to BIG_ENDIAN.
  ByteBuffer parent=ByteBuffer.allocateDirect(4096).order(ByteOrder.LITTLE_ENDIAN);
  ByteBuffer look=parent.slice(1024,ShadeLook.SIZE);
  CloudParams params=new CloudParams();params.packLook(look,true);
  for (int stableHistory : new int[]{0,1}) {
  '''+statement+'''
  float mode=look.duplicate().order(ByteOrder.LITTLE_ENDIAN).getFloat(ShadeLook.CLOUDS0+12);
  System.out.println("actual update store, shader reads cloud mode "+mode);
  if(mode!=(stableHistory==0?1f:3f)) throw new AssertionError("clouds disabled by byte-swapped mode");
  }
 }
}'''
(out/'CloudByteOrderCheck.java').write_text(source)
cache=Path(os.environ.get('GRADLE_USER_HOME', str(r/'.gradle-cache')))/'caches/modules-2/files-2.1';deps=[str(p) for g in ['org.joml/joml','org.lwjgl/lwjgl','org.lwjgl/lwjgl-stb','net.fabricmc/fabric-loader'] for p in (cache/g).rglob('*.jar') if 'sources' not in p.name];cp=':'.join([str(r/'metal/build/classes/java/main'),str(r/'metal/src/main/resources')]+deps);j=Path(os.environ['JAVA_HOME'])/'bin'
subprocess.run([str(j/'javac'),'-cp',cp,'-d',str(out),str(out/'CloudByteOrderCheck.java')],check=True);subprocess.run([str(j/'java'),'-cp',str(out)+':'+cp,'CloudByteOrderCheck'],check=True)
