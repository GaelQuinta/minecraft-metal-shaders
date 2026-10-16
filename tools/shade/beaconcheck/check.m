// Copyright 2026 mcopt-shade contributors. Apache-2.0.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
static void check(BOOL ok,const char *why){if(!ok){fprintf(stderr,"FAIL %s\n",why);exit(1);}}
static id<MTLDevice> dev;
static id<MTLCommandQueue> q;
static id<MTLTexture> input,output;
static id<MTLSamplerState> sampler;
static id<MTLRenderPipelineState> pipeline(NSString *folder,NSString *name,BOOL blend) {
 NSError *err=nil;
 NSString *src=[NSString stringWithContentsOfFile:[folder stringByAppendingPathComponent:name] encoding:NSUTF8StringEncoding error:&err];
 check(src!=nil,"fixture file");
 src=[src stringByAppendingString:@"\nstruct TestVertex { float4 pos [[position]]; float4 color [[user(locn0)]]; float2 uv [[user(locn1)]]; }; vertex TestVertex test_vs(uint i [[vertex_id]], constant float &distance [[buffer(0)]]) { float2 xy=float2((i<<1)&2,i&2)*2.0-1.0; TestVertex v; v.pos=float4(xy*distance,0.5*distance,distance); v.color=float4(1);v.uv=float2(0.5);return v;}\n"];
 MTLCompileOptions *opts=[MTLCompileOptions new];opts.languageVersion=MTLLanguageVersion3_0;
 id<MTLLibrary> lib=[dev newLibraryWithSource:src options:opts error:&err];check(lib!=nil,err.description.UTF8String);
 MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
 pd.vertexFunction=[lib newFunctionWithName:@"test_vs"];pd.fragmentFunction=[lib newFunctionWithName:@"main0"];
 pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA32Float;
 pd.colorAttachments[0].blendingEnabled=blend;
 pd.colorAttachments[0].sourceRGBBlendFactor=MTLBlendFactorSourceAlpha;
 pd.colorAttachments[0].destinationRGBBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
 id<MTLRenderPipelineState> p=[dev newRenderPipelineStateWithDescriptor:pd error:&err];check(p!=nil,err.description.UTF8String);return p;
}
static void render(id<MTLRenderPipelineState> p,float boost,float distance,float fogAlpha,float *color,float *result) {
 float look[272]={0},fog[12]={.12,.2,.3,fogAlpha,100,200,300,400,500,500},dt[40]={0};
 for(int k=0;k<3;k++){look[912/4+k*5]=1;look[960/4+k*5]=1;look[368/4+k]=1;}
 look[384/4]=1.6;look[384/4+1]=.92;look[384/4+2]=1;look[384/4+3]=1;
 look[400/4+3]=.8;look[1056/4+1]=boost;
 for(int k=0;k<4;k++)dt[32+k]=1;
 [input replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:color bytesPerRow:16];
 MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];rp.colorAttachments[0].texture=output;
 rp.colorAttachments[0].loadAction=MTLLoadActionClear;rp.colorAttachments[0].storeAction=MTLStoreActionStore;rp.colorAttachments[0].clearColor=MTLClearColorMake(.2,.2,.2,0);
 id<MTLCommandBuffer> cb=[q commandBuffer];id<MTLRenderCommandEncoder> e=[cb renderCommandEncoderWithDescriptor:rp];
 [e setRenderPipelineState:p];[e setVertexBytes:&distance length:4 atIndex:0];
 [e setFragmentBytes:fog length:sizeof fog atIndex:0];[e setFragmentBytes:dt length:sizeof dt atIndex:1];[e setFragmentBytes:look length:sizeof look atIndex:17];
 [e setFragmentTexture:input atIndex:0];[e setFragmentSamplerState:sampler atIndex:0];
 [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[e endEncoding];[cb commit];[cb waitUntilCompleted];
 check(cb.status==MTLCommandBufferStatusCompleted,cb.error.description.UTF8String);
 [output getBytes:result bytesPerRow:16 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
}
int main(int argc,const char **argv){@autoreleasepool{
 check(argc==2,"fixture directory required");dev=MTLCreateSystemDefaultDevice();check(dev!=nil,"Metal device access");q=[dev newCommandQueue];
 MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:1 height:1 mipmapped:NO];
 td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;input=[dev newTextureWithDescriptor:td];output=[dev newTextureWithDescriptor:td];
 sampler=[dev newSamplerStateWithDescriptor:[MTLSamplerDescriptor new]];
 NSString *folder=[NSString stringWithUTF8String:argv[1]];
 id<MTLRenderPipelineState> base=pipeline(folder,@"baseline.metal",NO),solid=pipeline(folder,@"opaque.metal",NO),blend=pipeline(folder,@"translucent.metal",YES);
 int count=0;
 for(int c=0;c<3;c++)for(int a=0;a<2;a++)for(int f=0;f<2;f++)for(int d=0;d<4;d++)for(int b=0;b<3;b++) {
 float colors[3][4]={{1,1,1,1},{.8,.2,.05,1},{0,0,0,1}}, col[4];memcpy(col,colors[c],sizeof col);col[3]=a?.15:1;
 float dist=(float[]){10,150,250,450}[d],boost=(float[]){1,4,8}[b],fogAlpha=f?.5:1;
 float reference[4],unfogged[4],got[4],blended[4];
 render(base,1,dist,fogAlpha,col,reference);render(base,1,10,fogAlpha,col,unfogged);
 render(solid,boost,dist,fogAlpha,col,got);render(blend,boost,dist,fogAlpha,col,blended);
 float visibility=1-fminf(1,fmaxf(0,(dist-100)/100))*fogAlpha;
 for(int k=0;k<3;k++){
  float expected=reference[k]+unfogged[k]*(boost-1)*visibility;
  check(isfinite(got[k])&&fabsf(got[k]-expected)<.0003,"radiance, colour and fog attenuation");
  check(fabsf(blended[k]-(got[k]*col[3]+.2f*(1-col[3])))<.0003,"translucent blend");
 }
 check(got[3]==col[3],"alpha preserved");count++;
 }
 printf("OK %d GPU beam cases: 1x/4x/8x, white/tinted/black, alpha, translucent blending, near/partial/full fog on %s\n",count,dev.name.UTF8String);
}return 0;}
