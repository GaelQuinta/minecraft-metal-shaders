// Copyright 2026 mcopt-shade contributors. Apache-2.0.
package mcopt.metal.shade.light;
import java.nio.*;
import java.lang.reflect.*;
import java.lang.management.ManagementFactory;
import java.util.*;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.chunk.LevelChunkSection;
public class OccupancyCheck {
    static final BlockState STONE=new BlockState(true,true), SLAB=new BlockState(false,true), AIR=LevelChunkSection.AIR;
    static final long BUDGET=1_000_000_000L;
    static int checks;
    static void check(boolean ok,String message){if(!ok)throw new AssertionError(message);checks++;}
    static void invariant(Occupancy o) throws Exception {
        Field f=Occupancy.class.getDeclaredField("dirty");f.setAccessible(true);
        Field count=Occupancy.class.getDeclaredField("dirtyCount");count.setAccessible(true);
        int dirty=0;for(boolean b:(boolean[])f.get(o))if(b)dirty++;
        check(count.getInt(o)==dirty,"dirty count mismatch");
    }
    static void compare(Occupancy a,BaselineOccupancy b,IntBuffer ab,IntBuffer bb) throws Exception {
        check(ab.equals(bb),"occupancy pixels differ");check(a.generation==b.generation,"generation differs");invariant(a);
    }
    public static void main(String[] args) throws Exception {
        IntBuffer ab=IntBuffer.allocate(Occupancy.BYTES/4),bb=IntBuffer.allocate(Occupancy.BYTES/4);
        Occupancy a=new Occupancy(ab);BaselineOccupancy b=new BaselineOccupancy(bb);
        ClientLevel level=new ClientLevel();level.block(1,4,1,STONE);level.block(2,4,1,SLAB);
        Random random=new Random(7);int x=0,y=8,z=0;
        for(int step=0;step<180;step++) {
            if(step%17==0){x=random.nextInt(400)-200;y=random.nextInt(140)-30;z=random.nextInt(400)-200;}
            if(step%31==0)level=new ClientLevel();
            if(step%23==0)level.loaded=false;
            if(step%23==2){level.loaded=true;a.section(x>>4,y>>4,z>>4);b.section(x>>4,y>>4,z>>4);}
            if(step%19==0)System.setProperty("mcopt.shade.dynLights.fullOccluders",step%38==0?"true":"false");
            BlockState state=step%3==0?STONE:step%3==1?SLAB:AIR;
            level.block(x+1,y,z,state);a.block(x+1,y,z,state);b.block(x+1,y,z,state);
            a.section((x+1)>>4,y>>4,z>>4);b.section((x+1)>>4,y>>4,z>>4);
            // Repeated notifications must not inflate the dirty count.
            a.section((x+1)>>4,y>>4,z>>4);b.section((x+1)>>4,y>>4,z>>4);
            ClientLevel current=step%41==0?null:level;
            a.update(current,x,y,z,BUDGET);b.update(current,x,y,z,BUDGET);compare(a,b,ab,bb);
            check(a.blocked(x-.5,y+.5,z+.5,x+3.5,y+.5,z+.5)==b.blocked(x-.5,y+.5,z+.5,x+3.5,y+.5,z+.5),"ray differs");
        }
        // Block notifications and round-robin healing still update settled caches.
        System.setProperty("mcopt.shade.dynLights.fullOccluders","true");level=new ClientLevel();
        a.update(level,0,8,0,BUDGET);b.update(level,0,8,0,BUDGET);
        check(a.pending==0,"settled window still pending");
        level.block(1,4,1,STONE);a.block(1,4,1,STONE);b.block(1,4,1,STONE);
        check(a.solid(1,4,1),"block update lost");
        level.block(1,4,1,AIR); // Deliberately omit the notification: self-healing must still work.
        for(int i=0;i<520;i++){a.update(level,0,8,0,BUDGET);b.update(level,0,8,0,BUDGET);compare(a,b,ab,bb);}
        check(!a.solid(1,4,1),"round-robin recovery lost");
        System.out.println("PASS "+checks+" occupancy checks: blocks, repeated section updates, missing chunks, occluder settings, world changes, teleports, rays and missed-update recovery");
        var bean=(com.sun.management.ThreadMXBean)ManagementFactory.getThreadMXBean();long tid=Thread.currentThread().threadId();
        for(int i=0;i<5000;i++){a.update(level,0,8,0,300_000);b.update(level,0,8,0,300_000);}
        double[][] times=new double[2][9];long[] bytes=new long[2];
        for(int round=0;round<9;round++)for(int order=0;order<2;order++){
            int mode=order^(round&1);long mem=bean.getThreadAllocatedBytes(tid),start=System.nanoTime();
            for(int i=0;i<10000;i++)if(mode==0)b.update(level,0,8,0,300_000);else a.update(level,0,8,0,300_000);
            times[mode][round]=(System.nanoTime()-start)/10000.;bytes[mode]=(bean.getThreadAllocatedBytes(tid)-mem)/10000;
        }
        long[] moved=new long[2];
        for(int mode=0;mode<2;mode++){
            long start=bean.getThreadAllocatedBytes(tid);
            for(int i=0;i<100;i++)if(mode==0)b.update(null,i*128,8,0,300_000);else a.update(null,i*128,8,0,300_000);
            moved[mode]=(bean.getThreadAllocatedBytes(tid)-start)/100;
        }
        System.out.printf(Locale.ROOT,"New occupancy window clear allocations: %d -> %d bytes/update%n",moved[0],moved[1]);
        Arrays.sort(times[0]);Arrays.sort(times[1]);
        System.out.printf(Locale.ROOT,"Settled in-memory window median: %.3f -> %.3f us/update; allocations %d -> %d bytes/update (synthetic CPU fixture, not game FPS)%n",times[0][4]/1000,times[1][4]/1000,bytes[0],bytes[1]);
    }
}
