// Copyright 2026 mcopt-shade contributors. Apache-2.0.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
#include <stdint.h>
static id<MTLDevice> dev; static id<MTLCommandQueue> queue;
static void require(BOOL ok, const char *why) { if (!ok) { fprintf(stderr,"FAIL %s\n",why); exit(1); } }
static NSString *readSource(NSString *p) { NSError *e=nil; NSString *s=[NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:&e];require(s!=nil,p.UTF8String);return s; }
static id<MTLLibrary> library(NSString *s) { NSError *e=nil;MTLCompileOptions *o=[MTLCompileOptions new];o.languageVersion=MTLLanguageVersion3_0;id<MTLLibrary> l=[dev newLibraryWithSource:s options:o error:&e];if (!l) fprintf(stderr,"%s\n",e.description.UTF8String);require(l!=nil,"metal source");return l; }
static id<MTLComputePipelineState> makePipeline(id<MTLLibrary> l,NSString *name,MTLFunctionConstantValues *cv) { NSError *e=nil;id<MTLFunction> f=cv?[l newFunctionWithName:name constantValues:cv error:&e]:[l newFunctionWithName:name];id<MTLComputePipelineState> p=f?[dev newComputePipelineStateWithFunction:f error:&e]:nil;if(!p) fprintf(stderr,"%s\n",e.description.UTF8String);require(p!=nil,name.UTF8String);return p; }
static id<MTLBuffer> buffer(NSUInteger bytes) { return [dev newBufferWithLength:bytes options:MTLResourceStorageModeShared]; }
static void finish(id<MTLCommandBuffer> cb,id<MTLComputeCommandEncoder> enc,int n) { [enc dispatchThreads:MTLSizeMake(n,1,1) threadsPerThreadgroup:MTLSizeMake(MIN(n,32),1,1)];[enc endEncoding];[cb commit];[cb waitUntilCompleted];if(cb.error)fprintf(stderr,"%s\n",cb.error.description.UTF8String);require(cb.status==MTLCommandBufferStatusCompleted,"gpu execution"); }
static void identity(float *m) { for(int i=0;i<16;i++)m[i]=i%5==0?1:0; }
static void vertices(NSString *source,NSString *probe) {
    int cases=0;
    for(int format=0;format<4;format++) {
        id<MTLLibrary> l=library([NSString stringWithFormat:@"%@%@\n%@",format>=2?@"#define OWN_QREC\n":@"",source,probe]);
        MTLFunctionConstantValues *cv=[MTLFunctionConstantValues new];BOOL yes=YES,no=NO;int zero=0;
        BOOL compact=format>0;[cv setConstantValue:&compact type:MTLDataTypeBool atIndex:1];
        for(int i=2;i<=4;i++)[cv setConstantValue:&no type:MTLDataTypeBool atIndex:i];
        [cv setConstantValue:&zero type:MTLDataTypeInt atIndex:7];[cv setConstantValue:&no type:MTLDataTypeBool atIndex:8];
        [cv setConstantValue:&yes type:MTLDataTypeBool atIndex:9];
        id<MTLComputePipelineState> p=makePipeline(l,@"leaf_vertices",cv);
        id<MTLBuffer> b[12]; int sizes[]={256,32,32,4,80,64,48,80,48,80,272,192};
        for(int i=0;i<12;i++)b[i]=buffer(sizes[i]);
        float xy[4][2]={{0,0},{1,0},{1,1},{0,1}};
        for(int leaf=0;leaf<2;leaf++) for(int far=0;far<2;far++) for(int enabled=0;enabled<2;enabled++) for(int tick=0;tick<8;tick++) {
            for(int i=0;i<12;i++)memset(b[i].contents,0,sizes[i]);
            for(int v=0;v<4;v++) {
                float u=leaf?.125f+xy[v][0]*.125f:.5f+xy[v][0]*.125f, vv=.125f+xy[v][1]*.125f;
                if(format==0) {
                    uint8_t *dst=(uint8_t*)b[0].contents+v*28;float pos[]={xy[v][0],xy[v][1],0};memcpy(dst,pos,12);memset(dst+12,255,4);memcpy(dst+16,&u,4);memcpy(dst+20,&vv,4);int16_t li[]={0,240};memcpy(dst+24,li,4);
                } else {
                    uint8_t *dst=(uint8_t*)b[0].contents+(format==3?64:0)+v*16;
                    uint16_t pos[]={(uint16_t)((xy[v][0]+8)*2048),(uint16_t)((xy[v][1]+8)*2048),16384};memcpy(dst,pos,6);dst[6]=0;dst[7]=240;memset(dst+8,255,4);uint16_t uv[]={(uint16_t)(u*65536),(uint16_t)(vv*65536)};memcpy(dst+12,uv,4);
                }
            }
            if(format==2) {
                uint32_t *w=b[0].contents; memset(w,0,40);
                for(int v=0;v<4;v++){uint32_t x=xy[v][0],y=xy[v][1];w[0]|=(x|y<<1)<<(v*3);w[0]|=(x|y<<1)<<(12+v*2);}
                w[1]=16384u|(18432u<<16);w[2]=w[1];w[3]=16384u|(16384u<<16);
                w[4]=(leaf?8192u:32768u)|((leaf?16384u:40960u)<<16);w[5]=8192u|(16384u<<16);
                w[6]=w[7]=0xffffffffu;w[8]=w[9]=0xf000f000u;
            } else if(format==3) {uint32_t*w=b[0].contents;w[0]=0x80000000u;w[1]=1;}
            ((int*)b[1].contents)[2]=far?-96:-8;((uint32_t*)b[2].contents)[2]=1u<<9;
            ((int*)b[4].contents)[1]=1000;((int*)b[4].contents)[2]=100;identity((float*)b[4].contents+4);identity(b[5].contents);identity(b[7].contents);identity(b[9].contents);
            float *le=b[10].contents;le[0]=enabled?1:0;le[1]=tick*.17f;le[2]=1;le[4]=le[5]=.125f;le[6]=le[7]=.25f;
            id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder];[e setComputePipelineState:p];for(int i=0;i<12;i++)[e setBuffer:b[i] offset:0 atIndex:i];
            finish(cb,e,4);float*out=b[11].contents;
            for(int v=0;v<4;v++) {
                require(out[v*12+3]==leaf,"leaf classification (all corners, including atlas boundaries)");
                for(int k=0;k<3;k++) {
                    float a=out[v*12+k],shadow=out[v*12+4+k],clip=out[v*12+8+k]*(k==1?-1:1);
                    require(isfinite(a)&&fabsf(a-shadow)<2e-6&&fabsf(a-clip)<2e-6,"visible/shadow/mesh-cull position agreement");
                    float original=k==0?xy[v][0]:k==1?xy[v][1]:(far?-96:-8);
                    require(fabsf(a-original)<.081,"bounded deformation");
                    if(!leaf||!enabled||far)require(a==original,"unchanged non-leaf, disabled and distant vertices");
                }
            }
            cases++;
        }
    }
    printf("%d production vertex cases: full/compact/record/stub, matching shadows and culling, leaf identity and off/distance controls\n",cases);
}
static void field(NSString *source,NSString *probe) {
    id<MTLLibrary> l=library([source stringByAppendingString:probe]);id<MTLComputePipelineState> p=makePipeline(l,@"leaf_field",nil);
    id<MTLBuffer> params=buffer(272),out=buffer(4096*32);float *f=params.contents;f[0]=2;float peak=0; float *first=calloc(4096*8,sizeof(float));
    for(int t=0;t<32;t++) {
        f[1]=t/31.f;id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder];[e setComputePipelineState:p];[e setBuffer:params offset:0 atIndex:0];[e setBuffer:out offset:0 atIndex:1];finish(cb,e,4096);
        float*x=out.contents;if(t==0)memcpy(first,x,4096*32);if(t==31)for(int i=0;i<4096*8;i++)require(fabsf(x[i]-first[i])<1e-5,"hourly clock continuity");for(int i=0;i<4096;i++){require(x[i*8+3]<1e-5,"section boundary continuity");for(int k=0;k<3;k++){require(isfinite(x[i*8+k])&&fabsf(x[i*8+k])<=.08001,"finite bounded wind");require(fabsf(x[i*8+k]-x[i*8+4+k])<1e-5,"far-world periodic continuity");peak=fmaxf(peak,fabsf(x[i*8+k]));}}
    }
    free(first);require(peak>.06,"wind actually moves");printf("131072 wind samples: section/far-world continuity, maximum axis displacement %.5f blocks\n",peak);
}
static void lighting(NSString *out,NSString *src,NSString *probe) {
    id<MTLLibrary> l=library([src stringByAppendingString:probe]);id<MTLComputePipelineState> p=makePipeline(l,@"leaf_lighting",nil);
    for(NSString*scene in @[@"noon",@"sunset",@"night"]) {
        NSData *d=[NSData dataWithContentsOfFile:[out stringByAppendingPathComponent:[scene stringByAppendingString:@".bin"]]];require(d.length>=2112,"lighting fixtures");
        id<MTLBuffer> f=[dev newBufferWithBytes:d.bytes length:1024 options:0],look=[dev newBufferWithBytes:(const uint8_t*)d.bytes+1024 length:d.length-1024 options:0],dst=buffer(640*16);
        id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder];[e setComputePipelineState:p];[e setBuffer:f offset:0 atIndex:0];[e setBuffer:look offset:0 atIndex:1];[e setBuffer:dst offset:0 atIndex:2];finish(cb,e,640);
        float *x=dst.contents;float mn[2]={1e9,1e9},mx[2]={0,0};
        for(int i=0;i<640;i++)for(int k=0;k<3;k++)require(isfinite(x[i*4+k])&&x[i*4+k]>=0,"finite lighting");
        for(int i=0;i<256;i++){int c=i/128;float lum=x[i*4]*.2126+x[i*4+1]*.7152+x[i*4+2]*.0722;mn[c]=fminf(mn[c],lum);mx[c]=fmaxf(mx[c],lum);}
        if([scene isEqualToString:@"sunset"])require(mx[1]-mn[1]<mx[0]-mn[0],"softer side-face contrast at low sun");
        for(int i=0;i<128;i++)for(int k=0;k<3;k++)require(x[(256+i)*4+k]==x[(384+i)*4+k],"shadowed leaves have no view-dependent glow");
        if([scene isEqualToString:@"sunset"])require(x[128*4+1]>x[512*4+1],"sunlight through leaves strengthens toward the light");
        printf("%s face-light range %.5f -> %.5f\n",scene.UTF8String,mx[0]-mn[0],mx[1]-mn[1]);
    }
}
int main(int argc,const char**argv){@autoreleasepool{
    require(argc==3,"usage: check out tools");dev=MTLCreateSystemDefaultDevice();require(dev!=nil,"metal device");queue=[dev newCommandQueue];
    NSString*out=@(argv[1]),*tools=@(argv[2]);NSString*src=readSource([out stringByAppendingPathComponent:@"own.metal"]),*probe=readSource([tools stringByAppendingPathComponent:@"vertex-probe.metal"]);
    vertices(src,probe);field(src,probe);lighting(out,readSource([out stringByAppendingPathComponent:@"lighting.metal"]),readSource([tools stringByAppendingPathComponent:@"lighting-probe.metal"]));
    return 0;
}}
