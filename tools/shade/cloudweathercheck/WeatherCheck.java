// Copyright 2026 mcopt-shade contributors. Apache-2.0.
import mcopt.metal.shade.clouds.CloudWeather;
public class WeatherCheck {
    static void require(boolean ok,String message){if(!ok)throw new AssertionError(message);}
    public static void main(String[] args){
        int clear=0,total=0;float max=0,sum=0,jump=0;
        for(int seed=0;seed<16;seed++){
            CloudWeather w=new CloudWeather();float last=-1,lastCir=0;
            for(int step=0;step<4800;step++){
                double days=-2+step/240.;w.update(days,0,0,1f/60,true,seed);
                require(Float.isFinite(w.coverage)&&Float.isFinite(w.cirrus),"nonfinite weather");
                if(w.coverage==0&&w.cirrus==0)clear++;total++;sum+=w.coverage;max=Math.max(max,w.coverage);
                if(last>=0)jump=Math.max(jump,Math.max(Math.abs(last-w.coverage),Math.abs(lastCir-w.cirrus)));
                last=w.coverage;lastCir=w.cirrus;
            }
        }
        System.out.printf("Clear periods %.2f%%, mean coverage %.5f, peak %.5f, max change per 100 ticks %.6f%n",100.0*clear/total,sum/total,max,jump);
        if(args.length>0&&args[0].equals("report"))return;
        require(clear/(double)total>.15,"weather never/far too rarely clears");
        require(max<=.361,"fair-weather coverage too high");require(jump<.025,"weather transition jumps");
        for(int seed=0;seed<32;seed++){
            CloudWeather w=new CloudWeather();w.update(seed*.31,1,1,0,true,seed);
            require(w.coverage>.9&&w.storm==1,"storm coverage lost");
        }
        System.out.println("PASS real clear periods, gradual daytime weather, bounded coverage and storm preservation");
    }
}
