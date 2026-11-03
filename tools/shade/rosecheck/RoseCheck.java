// Copyright 2026 mcopt-shade contributors. Apache-2.0.
import mcopt.metal.shade.*;
public class RoseCheck {
 static float rose(float angle,float rain){ShadeFrame f=new ShadeFrame();float y=(float)Math.sin(Math.toRadians(angle));f.sunDir.set(-(float)Math.sqrt(1-y*y),y,0);f.moonDir.set(f.sunDir).negate();f.eyeSkyLight=15;f.rain=rain;f.width=960;f.height=620;f.updateAtmosphere(0,true);ShadeLook l=new ShadeLook();l.update(f,0,1f/60);return l.skyRose;}
 public static void main(String[]args){for(String look:new String[]{"epic","storybook","natural"}){System.setProperty("mcopt.shade.look",look);float last=rose(-15,0),slope=0;for(int i=1;i<=5500;i++){float angle=-15+i*.01f,v=rose(angle,0),next=(v-last)/.01f;if(!Float.isFinite(v)||v<0||v>.51||Math.abs(next-slope)>.001)throw new AssertionError("abrupt rose at "+angle);if(rose(angle,1)!=0)throw new AssertionError("rose in rain");last=v;slope=next;}if(rose(-10,0)!=0||rose(34,0)!=0)throw new AssertionError("endpoints");}System.out.println("PASS 16500 rose steps, bounded slope changes, clear endpoints and rain suppression");}
}
