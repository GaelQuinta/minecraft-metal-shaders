// Copyright 2026 mcopt-shade contributors. Apache-2.0.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
static void need(BOOL ok, NSString *s) { if(!ok){fprintf(stderr,"FAIL %s\n",s.UTF8String);exit(1);} }
static id<MTLDevice> dev;
static id<MTLLibrary> lib(NSString *p, NSString *extra) {
 NSError*e=nil;NSString*s=[NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:&e];need(s!=nil,e.description);
 MTLCompileOptions*o=[MTLCompileOptions new];o.languageVersion=MTLLanguageVersion3_0;
 id<MTLLibrary>l=[dev newLibraryWithSource:[s stringByAppendingString:extra] options:o error:&e];need(l!=nil,e.description);return l;
}
static id<MTLTexture> tex(MTLPixelFormat fmt,int n,BOOL depth){MTLTextureDescriptor*d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:n height:n mipmapped:NO];d.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;d.storageMode=depth?MTLStorageModePrivate:MTLStorageModeShared;return [dev newTextureWithDescriptor:d];}
int main(int argc,const char**argv){@autoreleasepool{
 need(argc>=2,@"usage: check fixture-dir [overlay-only]");dev=MTLCreateSystemDefaultDevice();need(dev!=nil,@"device");id<MTLCommandQueue>queue=[dev newCommandQueue];NSString*dir=@(argv[1]);
 NSData*data=[NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"day.bin"]];need(data.length>=2112,@"fixture");
 id<MTLBuffer>f=[dev newBufferWithBytes:data.bytes length:1024 options:0],l=[dev newBufferWithBytes:(char*)data.bytes+1024 length:data.length-1024 options:0];
 float*look=l.contents;look[528/4]=-10;look[528/4+3]=3;look[544/4+3]=0;
 float gpu[128]={0};gpu[176/4]=1;
 id<MTLTexture>depth=tex(MTLPixelFormatDepth32Float,4,YES),out=tex(MTLPixelFormatRGBA16Float,4,NO),hist=tex(MTLPixelFormatRGBA16Float,2,NO),dist=tex(MTLPixelFormatR32Float,2,NO),bits=tex(MTLPixelFormatR16Uint,2,NO);
 _Float16 rgba[16];for(int i=0;i<16;i++)rgba[i]=i%4==3?.5:.3;float ds[4]={100,100,100,100};uint16_t codes[4]={1701,1701,1701,1701};
 [hist replaceRegion:MTLRegionMake2D(0,0,2,2) mipmapLevel:0 withBytes:rgba bytesPerRow:16];[dist replaceRegion:MTLRegionMake2D(0,0,2,2) mipmapLevel:0 withBytes:ds bytesPerRow:8];[bits replaceRegion:MTLRegionMake2D(0,0,2,2) mipmapLevel:0 withBytes:codes bytesPerRow:4];
 id<MTLCommandBuffer>cb=[queue commandBuffer];MTLRenderPassDescriptor*clear=[MTLRenderPassDescriptor renderPassDescriptor];clear.depthAttachment.texture=depth;clear.depthAttachment.loadAction=MTLLoadActionClear;clear.depthAttachment.storeAction=MTLStoreActionStore;clear.depthAttachment.clearDepth=0;[[cb renderCommandEncoderWithDescriptor:clear] endEncoding];
 NSError*err=nil;id<MTLLibrary>cl=lib([dir stringByAppendingPathComponent:@"clouds.metal"],@"");MTLRenderPipelineDescriptor*pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=[cl newFunctionWithName:@"cloud_vs"];pd.fragmentFunction=[cl newFunctionWithName:@"cloud_over"];pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA16Float;pd.colorAttachments[0].blendingEnabled=YES;pd.colorAttachments[0].sourceRGBBlendFactor=MTLBlendFactorOne;pd.colorAttachments[0].destinationRGBBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
 id<MTLRenderPipelineState>p=[dev newRenderPipelineStateWithDescriptor:pd error:&err];need(p!=nil,err.description);MTLRenderPassDescriptor*rp=[MTLRenderPassDescriptor renderPassDescriptor];rp.colorAttachments[0].texture=out;rp.colorAttachments[0].loadAction=MTLLoadActionClear;rp.colorAttachments[0].storeAction=MTLStoreActionStore;rp.colorAttachments[0].clearColor=MTLClearColorMake(.2,.2,.2,1);
 id<MTLRenderCommandEncoder>e=[cb renderCommandEncoderWithDescriptor:rp];uint32_t mode=3;[e setRenderPipelineState:p];[e setFragmentBytes:&mode length:4 atIndex:0];[e setFragmentBuffer:f offset:0 atIndex:16];[e setFragmentBuffer:l offset:0 atIndex:17];[e setFragmentBytes:gpu length:sizeof gpu atIndex:18];[e setFragmentTexture:depth atIndex:0];[e setFragmentTexture:dist atIndex:1];[e setFragmentTexture:hist atIndex:2];[e setFragmentTexture:bits atIndex:3];[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[e endEncoding];[cb commit];[cb waitUntilCompleted];need(cb.status==MTLCommandBufferStatusCompleted,cb.error.description);
 _Float16 result[64];[out getBytes:result bytesPerRow:32 fromRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0];float lo=1,hi=0;for(int i=0;i<16;i++){lo=fminf(lo,result[i*4]);hi=fmaxf(hi,result[i*4]);}printf("empty-depth sky range %.4f..%.4f\n",lo,hi);need(hi-lo<.001&&fabs(hi-.2)<.001,@"cloud overlay duplicates sky below the horizon");
 if(argc==3)return 0;
 NSString*probe=@"\nkernel void front(constant ShadeLook& l [[buffer(0)]], constant ShadeResources& r [[buffer(1)]], device float4* o [[buffer(2)]],uint i [[thread_position_in_grid]]){bool ground=l.clouds0.x>0;float d=i<2?(ground?400:200):20;float y=(i%2==0?-.01:.01)*d;if(ground)y=d*.6;o[i]=shadeCloudsForeground(float3(0,y,-d),l,r);}\n";
 id<MTLLibrary>pl=lib([dir stringByAppendingPathComponent:@"prelude.metal"],probe);id<MTLFunction>fn=[pl newFunctionWithName:@"front"];id<MTLComputePipelineState>cp=[dev newComputePipelineStateWithFunction:fn error:&err];need(cp!=nil,err.description);
 id<MTLArgumentEncoder>ae=[fn newArgumentEncoderWithBufferIndex:1];id<MTLBuffer>args=[dev newBufferWithLength:ae.encodedLength options:0],dst=[dev newBufferWithLength:64 options:0];[ae setArgumentBuffer:args offset:0];[ae setTexture:dist atIndex:9];[ae setTexture:hist atIndex:14];[ae setTexture:bits atIndex:15];
 for(int ground=0;ground<2;ground++)for(int stable=0;stable<2;stable++)for(int empty=0;empty<2;empty++){
  look[528/4]=ground?128:-10;look[528/4+1]=ground?278:140;
  for(int j=0;j<4;j++)ds[j]=ground?400:100;[dist replaceRegion:MTLRegionMake2D(0,0,2,2) mipmapLevel:0 withBytes:ds bytesPerRow:8];
  look[528/4+3]=stable?3:1;for(int j=0;j<4;j++)codes[j]=empty?4095:(ground?2213:1701);[bits replaceRegion:MTLRegionMake2D(0,0,2,2) mipmapLevel:0 withBytes:codes bytesPerRow:4];
  cb=[queue commandBuffer];id<MTLComputeCommandEncoder>ce=[cb computeCommandEncoder];[ce setComputePipelineState:cp];[ce setBuffer:l offset:0 atIndex:0];[ce setBuffer:args offset:0 atIndex:1];[ce setBuffer:dst offset:0 atIndex:2];for(id<MTLTexture>t in @[hist,dist,bits])[ce useResource:t usage:MTLResourceUsageRead];[ce dispatchThreads:MTLSizeMake(4,1,1) threadsPerThreadgroup:MTLSizeMake(4,1,1)];[ce endEncoding];[cb commit];[cb waitUntilCompleted];need(cb.status==MTLCommandBufferStatusCompleted,cb.error.description);
  float*v=dst.contents;for(int j=0;j<4;j++)need(fabs(v[j]-v[4+j])<1e-6,@"DH continuity across horizon");need(v[11]==1&&v[15]==1,@"near terrain occludes cloud");need(fabs(v[3]-(stable&&empty?1:.5))<.001,ground?@"ground view: high mountains erase foreground clouds":@"far terrain cloud and clear-history handling");
 }
 // Exercise the near-terrain pass's actual depth rejection too, including a clear history pixel,
 // rather than only checking the DH helper above.
 look[528/4]=128;look[528/4+1]=278;
 for(int stable=0;stable<2;stable++)for(int near=0;near<2;near++)for(int empty=0;empty<2;empty++){
  uint32_t overlayMode=stable?3:1;float z=near?20:200;float*frame=f.contents;
  float terrainDepth=(frame[128/4+10]*-z+frame[128/4+14])/(frame[128/4+11]*-z+frame[128/4+15]);
  for(int j=0;j<4;j++){ds[j]=100;codes[j]=empty?4095:1701;}
  [dist replaceRegion:MTLRegionMake2D(0,0,2,2) mipmapLevel:0 withBytes:ds bytesPerRow:8];
  [bits replaceRegion:MTLRegionMake2D(0,0,2,2) mipmapLevel:0 withBytes:codes bytesPerRow:4];
  cb=[queue commandBuffer];clear.depthAttachment.clearDepth=terrainDepth;[[cb renderCommandEncoderWithDescriptor:clear]endEncoding];
  e=[cb renderCommandEncoderWithDescriptor:rp];[e setRenderPipelineState:p];[e setFragmentBytes:&overlayMode length:4 atIndex:0];[e setFragmentBuffer:f offset:0 atIndex:16];[e setFragmentBuffer:l offset:0 atIndex:17];[e setFragmentBytes:gpu length:sizeof gpu atIndex:18];[e setFragmentTexture:depth atIndex:0];[e setFragmentTexture:dist atIndex:1];[e setFragmentTexture:hist atIndex:2];[e setFragmentTexture:bits atIndex:3];[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[e endEncoding];[cb commit];[cb waitUntilCompleted];need(cb.status==MTLCommandBufferStatusCompleted,cb.error.description);
  [out getBytes:result bytesPerRow:32 fromRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0];
  float expected=near||(stable&&empty)?.2:.4;
  for(int j=0;j<16;j++)need(fabs(result[4*j]-expected)<.001,near?@"near terrain must hide clouds":@"clouds must cover terrain behind them from below");
 }
 printf("PASS DH and near terrain from ground/elevated views, near/far occlusion, stable/classic history, no duplicate sky\n");
}return 0;}
