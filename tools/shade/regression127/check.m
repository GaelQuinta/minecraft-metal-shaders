// Copyright 2026 mcopt-shade contributors. Licensed under the Apache License, Version 2.0.
// Executes the production upsamplers on tiny textures: leaf/sky discontinuities, signed light, and live subrect bounds.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
static void check(BOOL ok, const char *why) { if (!ok) { fprintf(stderr,"FAIL %s\n",why); exit(1); } }
int main(int argc, const char **argv) { @autoreleasepool {
 check(argc==2,"shader source path");
 id<MTLDevice> dev=MTLCreateSystemDefaultDevice(); check(dev!=nil,"Metal device");
 NSError *err=nil; NSString *src=[NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[1]] encoding:NSUTF8StringEncoding error:&err];
 MTLCompileOptions *opts=[MTLCompileOptions new]; opts.languageVersion=MTLLanguageVersion3_0; opts.mathMode=MTLMathModeFast;
 id<MTLLibrary> lib=[dev newLibraryWithSource:src options:opts error:&err]; check(lib!=nil,err.description.UTF8String);
 id<MTLComputePipelineState> p=[dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"probe"] error:&err]; check(p!=nil,err.description.UTF8String);
 id<MTLCommandQueue> queue=[dev newCommandQueue];
 MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:8 height:8 mipmapped:NO];
 td.storageMode=MTLStorageModeShared; td.usage=MTLTextureUsageShaderRead;
 id<MTLTexture> light=[dev newTextureWithDescriptor:td], depth=[dev newTextureWithDescriptor:td];
 id<MTLBuffer> result=[dev newBufferWithLength:32 options:MTLResourceStorageModeShared];
 for(int test=0;test<8;test++) {
  __fp16 l[8*8*4],d[8*8*4]; float q[4]={10000,1,0,0};
  for(int y=0;y<8;y++)for(int x=0;x<8;x++) {
   int o=(y*8+x)*4; float z=10, r=.25,g=.5,b=.75,a=.8;
   if(test==0) q[0]=10;
   if(test==1||test==2||test==4||test==7) {r=-2;g=-1;b=-.5;}
   if(test==2&&x==2&&y==3) {z=10000;r=.1;g=.2;b=.3;a=.9;}
   if(test==3) {q[0]=.02;z=10000;}
   if(test==4) {q[1]=.5;if(x>=4||y>=4){z=10000;r=100;g=100;b=100;}}
   if(test==5) {q[0]=10;r=-2;g=-1;b=-.5;}
   if(test==6) {q[0]=10000;z=10000;r=-2;g=-1;b=-.5;}
   if(test==7) q[0]=200;
   l[o]=r;l[o+1]=g;l[o+2]=b;l[o+3]=a;
   d[o]=r;d[o+1]=g;d[o+2]=b;d[o+3]=z;
  }
  [light replaceRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0 withBytes:l bytesPerRow:8*8];
  [depth replaceRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0 withBytes:d bytesPerRow:8*8];
  id<MTLCommandBuffer> cb=[queue commandBuffer]; id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder];
  [e setComputePipelineState:p];[e setTexture:light atIndex:0];[e setTexture:depth atIndex:1];
  float params[8]={8*q[1],8*q[1],8*q[1],8*q[1],0,224,0,0};
  [e setBuffer:result offset:0 atIndex:0];[e setBytes:q length:sizeof q atIndex:1];[e setBytes:params length:sizeof params atIndex:2];
  [e dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];[e endEncoding];[cb commit];[cb waitUntilCompleted];
  check(cb.status==MTLCommandBufferStatusCompleted,cb.error.description.UTF8String);
  float *v=result.contents;for(int k=0;k<8;k++)check(isfinite(v[k]),"finite near/sky weights");
  if(test==0)check(fabs(v[0]-.25)<.002&&fabs(v[3]-.8)<.002&&fabs(v[4]-.25)<.002,"constant light and transmission preserved");
  if(test==1||test==4||test==7)check(fabs(v[0])<.001&&fabs(v[1])<.001&&v[3]==1&&fabs(v[4])<.001,"no foreground light/correction invented in background or inactive subrect");
  if(test==2)check(fabs(v[0]-.1)<.002&&fabs(v[3]-.9)<.002&&fabs(v[4]-.1)<.002,"matching sky from outer ring, no leaf borrowing");
  if(test==5||test==6)check(fabs(v[0]+2)<.002&&fabs(v[4]+2)<.002,"valid negative haze correction preserved");
  printf("OK GPU case %d: folded [%g,%g,%g,%g], separate [%g,%g,%g]\n",test,v[0],v[1],v[2],v[3],v[4],v[5],v[6]);
 }
 printf("OK both production VL upsamplers on %s\n",dev.name.UTF8String);
} return 0; }
