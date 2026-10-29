#!/usr/bin/env python3
# Copyright 2026 mcopt-shade contributors. Apache-2.0.
# Compiles production Occupancy unchanged against a small in-memory Minecraft world API.
import os, re, subprocess, sys
from pathlib import Path
here=Path(__file__).resolve().parent
root=here.parents[2]
out=Path(sys.argv[1]).resolve();out.mkdir(parents=True,exist_ok=True)
base=Path(sys.argv[2]).read_text() if len(sys.argv)>2 else subprocess.check_output(['git','show','846d7e8:metal/src/main/java/mcopt/metal/shade/light/Occupancy.java'],cwd=root,text=True)
sources={
'net/minecraft/world/level/block/state/BlockState.java':'''package net.minecraft.world.level.block.state;
public record BlockState(boolean isSolidRender, boolean canOcclude) {}''',
'net/minecraft/world/level/chunk/status/ChunkStatus.java':'''package net.minecraft.world.level.chunk.status; public enum ChunkStatus { FULL }''',
'net/minecraft/world/level/chunk/PalettedContainer.java':'''package net.minecraft.world.level.chunk;
import java.util.function.Predicate;
public class PalettedContainer<T> {
 private final Object[] cells; public PalettedContainer(Object[] cells){this.cells=cells;}
 @SuppressWarnings("unchecked") public T get(int x,int y,int z){return (T)cells[(y*16+z)*16+x];}
 @SuppressWarnings("unchecked") public boolean maybeHas(Predicate<T> p){for(Object c:cells)if(p.test((T)c))return true;return false;}
}''',
'net/minecraft/world/level/chunk/LevelChunkSection.java':'''package net.minecraft.world.level.chunk;
import java.util.Arrays;
import net.minecraft.world.level.block.state.BlockState;
public class LevelChunkSection {
 public static final BlockState AIR=new BlockState(false,false);
 private final BlockState[] cells=new BlockState[4096]; private int occupied;
 public LevelChunkSection(){Arrays.fill(cells,AIR);}
 public void set(int x,int y,int z,BlockState b){int i=(y*16+z)*16+x;if(cells[i]!=AIR)occupied--;cells[i]=b;if(b!=AIR)occupied++;}
 public boolean hasOnlyAir(){return occupied==0;}
 public PalettedContainer<BlockState> getStates(){return new PalettedContainer<>(cells);}
}''',
'net/minecraft/world/level/chunk/LevelChunk.java':'''package net.minecraft.world.level.chunk;
import net.minecraft.client.multiplayer.ClientLevel;
public record LevelChunk(ClientLevel level,int x,int z) {
 public LevelChunkSection getSection(int index){return level.section(x,index+level.getMinSectionY(),z);}
}''',
'net/minecraft/client/multiplayer/ClientLevel.java':'''package net.minecraft.client.multiplayer;
import java.util.*;
import net.minecraft.world.level.chunk.*;
import net.minecraft.world.level.chunk.status.ChunkStatus;
import net.minecraft.world.level.block.state.BlockState;
public class ClientLevel {
 private final Map<String,LevelChunkSection> sections=new HashMap<>();
 private final LevelChunkSection air=new LevelChunkSection();
 public boolean loaded=true; public int reads;
 public int getMinSectionY(){return -4;} public int getSectionsCount(){return 24;}
 public ClientLevel getChunkSource(){return this;}
 public LevelChunk getChunk(int x,int z,ChunkStatus status,boolean create){reads++;return loaded?new LevelChunk(this,x,z):null;}
 public LevelChunkSection section(int x,int y,int z){return sections.getOrDefault(x+":"+y+":"+z,air);}
 public void block(int x,int y,int z,BlockState state){sections.computeIfAbsent((x>>4)+":"+(y>>4)+":"+(z>>4),k->new LevelChunkSection()).set(x&15,y&15,z&15,state);}
}''',
'mcopt/metal/shade/light/Occupancy.java':(root/'metal/src/main/java/mcopt/metal/shade/light/Occupancy.java').read_text(),
'mcopt/metal/shade/light/BaselineOccupancy.java':re.sub(r'\bOccupancy\b','BaselineOccupancy',base),
'mcopt/metal/shade/light/OccupancyCheck.java':(here/'OccupancyCheck.java').read_text(),
}
paths=[]
for name,source in sources.items():
 p=out/'src'/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(source);paths.append(str(p))
java=Path(os.environ['JAVA_HOME'])/'bin'
subprocess.run([str(java/'javac'),'-d',str(out/'classes')]+paths,check=True)
subprocess.run([str(java/'java'),'-cp',str(out/'classes'),'mcopt.metal.shade.light.OccupancyCheck'],check=True)
