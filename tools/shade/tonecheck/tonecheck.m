// Copyright 2026 mcopt-shade contributors. Apache-2.0.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
static void check(BOOL b,const char *msg){if(!b){fprintf(stderr,"FAIL %s\n",msg);exit(1);}}
int main(int argc,const char **argv){@autoreleasepool{
 check(argc==3,"usage: tonecheck before after");id<MTLDevice>d=MTLCreateSystemDefaultDevice();check(d!=nil,"No Metal device");id<MTLCommandQueue>q=[d newCommandQueue];
 float levels[]={0,.005,.01,.02,.04,.08,.18,.36,1,4,12};enum{N=11};float inputs[N*4];for(int i=0;i<N;i++){for(int c=0;c<3;c++)inputs[i*4+c]=levels[i];inputs[i*4+3]=1;}
 id<MTLBuffer>in=[d newBufferWithBytes:inputs length:sizeof(inputs) options:MTLResourceStorageModeShared];
 float values[2][9][N*8];
 for(int k=0;k<2;k++){
  NSString *path=@(argv[k+1]);NSError*err=nil;NSString *source=[NSString stringWithContentsOfFile:[path stringByAppendingPathComponent:@"post.metal"] encoding:NSUTF8StringEncoding error:&err];
  source=[source stringByAppendingString:@"\nkernel void tone_test(device const float4 *v [[buffer(1)]],device float4 *o [[buffer(2)]],constant ShadeLook &l [[buffer(17)]],constant ShadeFinalParams &p [[buffer(0)]],uint i [[thread_position_in_grid]]){o[i*2]=float4(shadeDisplay(v[i].rgb,l),1);o[i*2+1]=float4(shadeFullHdr(v[i].rgb,l,p),1);}\n"];
  MTLCompileOptions*opts=[MTLCompileOptions new];opts.languageVersion=MTLLanguageVersion3_0;id<MTLLibrary>lib=[d newLibraryWithSource:source options:opts error:&err];if(!lib)fprintf(stderr,"%s\n",err.description.UTF8String);check(lib!=nil,"compile production tone source");
  id<MTLComputePipelineState>pso=[d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"tone_test"] error:&err];check(pso!=nil,"tone pipeline");
  int scenario=0;for(NSString *name in @[@"epic",@"storybook",@"natural"])for(NSNumber *angle in @[@(-15),@0,@60]){
   NSData*data=[NSData dataWithContentsOfFile:[path stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%@.bin",name,angle]]];NSUInteger lookSize=data.length-96;check(lookSize==1088 || lookSize==1120,"uniform layout");
   id<MTLBuffer>out=[d newBufferWithLength:N*32 options:MTLResourceStorageModeShared];id<MTLCommandBuffer>cb=[q commandBuffer];id<MTLComputeCommandEncoder>e=[cb computeCommandEncoder];
   [e setComputePipelineState:pso];[e setBuffer:in offset:0 atIndex:1];[e setBuffer:out offset:0 atIndex:2];[e setBytes:data.bytes length:lookSize atIndex:17];[e setBytes:(char*)data.bytes+lookSize length:96 atIndex:0];[e dispatchThreads:MTLSizeMake(N,1,1) threadsPerThreadgroup:MTLSizeMake(N,1,1)];[e endEncoding];[cb commit];[cb waitUntilCompleted];check(cb.status==MTLCommandBufferStatusCompleted,"GPU execution");memcpy(values[k][scenario++],out.contents,N*32);
  }
 }
 float minReduction=1,maxAnchor=0;
 for(int s=0;s<9;s++)for(int mode=0;mode<2;mode++)for(int c=0;c<3;c++){
  float *a=values[0][s],*b=values[1][s];int offset=4*mode+c;
  for(int i=0;i<N;i++){check(isfinite(b[8*i+offset]),"nonfinite tone");if(i>0)check(b[8*i+offset]>=b[8*(i-1)+offset],"nonmonotonic tone");}
  check(b[8*2+offset]>=a[8*2+offset],"dark tones crushed further");
  float oldC=logf(a[8*4+offset]/a[8*3+offset]),newC=logf(b[8*4+offset]/b[8*3+offset]);
  check(newC<oldC,"shadow contrast not reduced");minReduction=fminf(minReduction,1-newC/oldC);
  maxAnchor=fmaxf(maxAnchor,fabsf(b[8*6+offset]-a[8*6+offset]));
 }
 printf("PASS 18 production SDR/HDR tone cases: dark-patch log contrast reduced at least %.1f%%; mid-gray max change %.7f; monotonic and finite\n",100*minReduction,maxAnchor);
 check(maxAnchor<.015,"mid-gray shifted too far");
}return 0;}
