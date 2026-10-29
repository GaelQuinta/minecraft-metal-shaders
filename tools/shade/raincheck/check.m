// Copyright 2026 mcopt-shade contributors. Apache-2.0.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
static void ok(BOOL b,NSString *s){if(!b){fprintf(stderr,"FAIL %s\n",s.UTF8String);exit(1);}}
int main(int argc,const char **argv){@autoreleasepool{
 ok(argc==4,@"usage: check source-dir probe.metal fixture-dir");NSError *err=nil;id<MTLDevice>d=MTLCreateSystemDefaultDevice();ok(d!=nil,@"GPU unavailable");id<MTLCommandQueue>q=[d newCommandQueue];NSString *dir=@(argv[1]),*fd=@(argv[3]);
 NSString *probe=[NSString stringWithContentsOfFile:@(argv[2]) encoding:NSUTF8StringEncoding error:&err];
 NSData*ff=[NSData dataWithContentsOfFile:[fd stringByAppendingPathComponent:@"noon_up.frame"]],*ll=[NSData dataWithContentsOfFile:[fd stringByAppendingPathComponent:@"noon_up.look"]];ok(ff.length>=1024&&(ll.length==1088||ll.length==1120),@"fixture sizes");
 float before[2][7][160*4];float minRatio=1,maxRatio=0;
 for(int lite=0;lite<2;lite++)for(int version=0;version<2;version++){
  NSString *src=[NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:version?@"after.metal":@"before.metal"] encoding:NSUTF8StringEncoding error:&err];
  src=[NSString stringWithFormat:@"#define MCOPT_HDR\n%@%@\n%@\n%@",lite?@"#define SHADE_WX_LITE\n":@"",src,@"",probe];
  MTLCompileOptions*opt=[MTLCompileOptions new];opt.languageVersion=MTLLanguageVersion3_0;id<MTLLibrary>lib=[d newLibraryWithSource:src options:opt error:&err];ok(lib!=nil,err.description);
  id<MTLComputePipelineState>p=[d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"rain_probe"] error:&err];ok(p!=nil,err.description);
  MTLTextureDescriptor*td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:1 height:1 mipmapped:NO];td.usage=MTLTextureUsageShaderRead;td.storageMode=MTLStorageModeShared;id<MTLTexture>lut=[d newTextureWithDescriptor:td];uint16_t sky[4]={0x4900,0x4500,0x4000,0x3c00};[lut replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:sky bytesPerRow:8];
  for(int scene=0;scene<7;scene++){
   float f[256],l[280],g[128]={0};memcpy(f,ff.bytes,sizeof f);memset(l,0,sizeof l);memcpy(l,ll.bytes,ll.length);g[176/4]=1;
   l[(496+12)/4]=scene==0?.2:1;l[(512+12)/4]=scene==2?1:0;l[768/4+3]=scene==3?2:0;
   if(scene==4){for(int j=0;j<3;j++){f[544/4+j]*=.001;f[560/4+j]*=.001;}}
   if(scene==5)f[608/4+3]=1;if(scene==6)((int*)f)[960/4]=1;
   id<MTLBuffer>o=[d newBufferWithLength:160*16 options:MTLResourceStorageModeShared];id<MTLCommandBuffer>b=[q commandBuffer];id<MTLComputeCommandEncoder>e=[b computeCommandEncoder];[e setComputePipelineState:p];[e setBuffer:o offset:0 atIndex:0];[e setBytes:f length:sizeof f atIndex:16];[e setBytes:l length:sizeof l atIndex:17];[e setBytes:g length:sizeof g atIndex:18];[e setTexture:lut atIndex:17];[e dispatchThreads:MTLSizeMake(160,1,1) threadsPerThreadgroup:MTLSizeMake(32,1,1)];[e endEncoding];[b commit];[b waitUntilCompleted];ok(b.status==MTLCommandBufferStatusCompleted,b.error.description);
   float *v=o.contents;for(int i=0;i<160;i++){
    for(int c=0;c<4;c++)ok(isfinite(v[i*4+c])&&v[i*4+c]>=0,@"finite nonnegative rain");ok(v[i*4+3]<=1,@"rain alpha bounded");
    if(!version)continue;
    if(scene==2||scene>=5)for(int c=0;c<4;c++)ok(fabsf(v[i*4+c]-before[lite][scene][i*4+c])<.00001,@"snow/media/dimension regression");
    if(scene<2 && (i/16)%5>=2 && i%16>0){float r=v[i*4+3]/before[lite][scene][i*4+3];ok(r<1,@"rain curtain opacity not reduced");minRatio=fminf(minRatio,r);maxRatio=fmaxf(maxRatio,r);}
    if(i%16==0)ok(v[i*4+3]==0,@"empty rain texel opaque");
   }
   if(!version)memcpy(before[lite][scene],v,160*16);
  }
 }
 printf("PASS 28 rain cases (full/lite, light/heavy/night/snow/lightning/media/dimension), opacity %.0f-%.0f%% lower beyond 6 blocks\n",100*(1-maxRatio),100*(1-minRatio));
}return 0;}
