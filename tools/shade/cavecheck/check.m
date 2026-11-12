// Copyright 2026 mcopt-shade contributors. Apache-2.0.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <math.h>
static void need(BOOL ok,NSString*s){if(!ok){fprintf(stderr,"FAIL %s\n",s.UTF8String);exit(1);}}
static id<MTLTexture> volume(id<MTLDevice>d,const _Float16*values){
 MTLTextureDescriptor*t=[MTLTextureDescriptor new];t.textureType=MTLTextureType3D;t.pixelFormat=MTLPixelFormatRGBA16Float;t.width=t.height=t.depth=2;t.usage=MTLTextureUsageShaderRead;t.storageMode=MTLStorageModeShared;
 id<MTLTexture>x=[d newTextureWithDescriptor:t];[x replaceRegion:MTLRegionMake3D(0,0,0,2,2,2) mipmapLevel:0 slice:0 withBytes:values bytesPerRow:16 bytesPerImage:32];return x;
}
int main(int argc,const char**argv){@autoreleasepool{
 need(argc==3,@"fixture folder and probe source");NSString*dir=@(argv[1]);BOOL record=getenv("CAVE_RECORD")!=NULL;id<MTLDevice>dev=MTLCreateSystemDefaultDevice();need(dev!=nil,@"Metal device");NSError*err=nil;
 NSString*src=[NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"source.metal"] encoding:NSUTF8StringEncoding error:&err];need(src!=nil,err.description);
 src=[src stringByAppendingString:[NSString stringWithContentsOfFile:@(argv[2]) encoding:NSUTF8StringEncoding error:&err]];
 MTLCompileOptions*opts=[MTLCompileOptions new];opts.languageVersion=MTLLanguageVersion3_0;
 id<MTLLibrary>lib=[dev newLibraryWithSource:src options:opts error:&err];need(lib!=nil,err.description);id<MTLComputePipelineState>pipe=[dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"caveProbe"] error:&err];need(pipe!=nil,err.description);
 id<MTLCommandQueue>queue=[dev newCommandQueue];id<MTLBuffer>D=[dev newBufferWithLength:28736 options:0],output=[dev newBufferWithLength:224 options:0];memset(D.contents,0,D.length);
 uint32_t*du=D.contents;float*df=D.contents;du[0]=1;df[4]=-64;df[5]=-48;df[6]=-64;df[7]=.125;df[8]=1;df[9]=1;df[10]=1;df[11]=1;df[12]=-48;df[13]=-32;df[14]=-48;df[15]=1;
 df[16+3]=14;df[16+4]=df[16+5]=df[16+6]=1;df[16+11]=-1;df[16+12]=1.5;df[16+13]=1;
 for(int i=4160/4;i<28736/4;i+=2)du[i]=1;
 _Float16 a[32],b[32];for(int i=0;i<8;i++){for(int j=0;j<4;j++){a[4*i+j]=1;b[4*i+j]=j>=2?1:0;}}
 id<MTLTexture>irr=volume(dev,a),dirs=volume(dev,b),vis=volume(dev,a);NSMutableDictionary*measure=[NSMutableDictionary new];BOOL passed=YES;
 for(NSString*scene in @[@"cave-day",@"cave-night",@"outside-day",@"outside-night",@"storm",@"kelvin"]){
  NSData*u=[NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:[scene stringByAppendingString:@".bin"]]];need(u.length==2112||u.length==2144,@"fixture layout");
  id<MTLCommandBuffer>cb=[queue commandBuffer];id<MTLComputeCommandEncoder>e=[cb computeCommandEncoder];[e setComputePipelineState:pipe];[e setBuffer:output offset:0 atIndex:0];[e setBuffer:D offset:0 atIndex:1];[e setBytes:u.bytes length:1024 atIndex:16];[e setBytes:(char*)u.bytes+1024 length:u.length-1024 atIndex:17];[e setTexture:vis atIndex:0];[e setTexture:irr atIndex:1];[e setTexture:dirs atIndex:2];[e dispatchThreads:MTLSizeMake(14,1,1) threadsPerThreadgroup:MTLSizeMake(14,1,1)];[e endEncoding];[cb commit];[cb waitUntilCompleted];need(cb.status==MTLCommandBufferStatusCompleted,cb.error.description);
  float*v=output.contents;NSMutableArray*rows=[NSMutableArray new];for(int i=0;i<14;i++){for(int k=0;k<3;k++)need(isfinite(v[4*i+k])&&v[4*i+k]>=0,@"finite lighting");[rows addObject:@[@(v[4*i]),@(v[4*i+1]),@(v[4*i+2])]];}measure[scene]=rows;
  if([scene hasPrefix:@"cave"]){
   float floorRatio=v[2]/v[0],rodRatio=v[6]/v[4],direct=v[12]/v[8],vol=v[20]/v[16];
   printf("%s minimum B/R %.3f, dim-grey B/R %.3f, side/front direct %.3f volume %.3f, near/far %.3f\n",scene.UTF8String,floorRatio,rodRatio,direct,vol,v[24]/v[28]);
   if(fabs(floorRatio-1)>.02||fabs(rodRatio-1)>.02||direct>.85||vol>.85||v[24]<=v[28]*2)passed=NO;
   float nearWarm=v[40]/v[42],farWarm=v[44]/v[46],placedNear=v[48]/v[50],placedFar=v[52]/v[54];
   printf("warmth R/B held near %.3f far %.3f; placed near %.3f far %.3f\n",nearWarm,farWarm,placedNear,placedFar);
   if(nearWarm<3.5||fabs(farWarm-1)>.02||placedNear<3.5||fabs(placedFar-1)>.03)passed=NO;
  }
 }
 [[NSJSONSerialization dataWithJSONObject:measure options:NSJSONWritingPrettyPrinted error:nil]writeToFile:[dir stringByAppendingPathComponent:@"measurements.json"] atomically:YES];
 const char*baseline=getenv("CAVE_BASELINE");if(baseline){NSDictionary*old=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[@(baseline) stringByAppendingPathComponent:@"measurements.json"]]options:0 error:nil];need(old!=nil,@"baseline measurements");
  for(NSString*scene in @[@"outside-day",@"outside-night",@"storm",@"kelvin"]){NSArray*indices=[scene isEqualToString:@"kelvin"]?@[@8]:@[@1,@9];for(NSNumber*index in indices)for(int k=0;k<3;k++){int i=index.intValue;need(fabs([measure[scene][i][k]floatValue]-[old[scene][i][k]floatValue])<1e-6,@"outdoor/weather grade and explicit torch Kelvin remain unchanged");}}
 }
 // Exercise the real irradiance writer: the player's direction must reach the terrain consumer.
 id<MTLComputePipelineState>irrPipe=[dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"shade_dl_irr"] error:&err];need(irrPipe!=nil,err.description);
 MTLTextureDescriptor*td=[MTLTextureDescriptor new];td.textureType=MTLTextureType3D;td.pixelFormat=MTLPixelFormatRGBA16Float;td.width=96;td.height=64;td.depth=96;td.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;td.storageMode=MTLStorageModeShared;
 id<MTLTexture>realIrr=[dev newTextureWithDescriptor:td],realDirs=[dev newTextureWithDescriptor:td];uint32_t box[4]={48,32,44,0};
 for(int mixed=0;mixed<3;mixed++){
  du[0]=mixed==1?2:1;df[20]=df[21]=df[22]=1;if(mixed==2){df[20]=.19;df[21]=1.04;df[22]=3.33;}memcpy(df+32,df+16,64);df[32+13]=0;for(int i=4160/4;i<28736/4;i+=2)du[i]=mixed==1?3:1;
  id<MTLCommandBuffer>cb=[queue commandBuffer];id<MTLComputeCommandEncoder>e=[cb computeCommandEncoder];[e setComputePipelineState:irrPipe];[e setBuffer:D offset:0 atIndex:0];[e setBytes:box length:16 atIndex:1];[e setTexture:vis atIndex:0];[e setTexture:realIrr atIndex:1];[e setTexture:realDirs atIndex:2];[e dispatchThreads:MTLSizeMake(1,1,1)threadsPerThreadgroup:MTLSizeMake(1,1,1)];[e endEncoding];[cb commit];[cb waitUntilCompleted];need(cb.status==MTLCommandBufferStatusCompleted,cb.error.description);
  _Float16 direction[4];[realDirs getBytes:direction bytesPerRow:8 bytesPerImage:8 fromRegion:MTLRegionMake3D(48,32,44,1,1,1) mipmapLevel:0 slice:0];
  printf("irradiance writer %s: direction z %.3f, held-light share %.3f\n",mixed==1?"mixed":mixed==2?"soul":"held",(float)direction[2],(float)direction[3]);
  if(direction[2]<.9||fabs((float)direction[3]-(mixed==1?.5:1))>.01)passed=NO;
  _Float16 light[4];[realIrr getBytes:light bytesPerRow:8 bytesPerImage:8 fromRegion:MTLRegionMake3D(48,32,44,1,1,1) mipmapLevel:0 slice:0];
  if((mixed==2&&light[3]!=0)||(mixed!=2&&light[3]<=0))passed=NO;
 }
 const char*stonePath=getenv("CAVE_STONE");if(stonePath){
  CGImageSourceRef imageSource=CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(stonePath)],NULL);need(imageSource!=NULL,@"stone texture");CGImageRef image=CGImageSourceCreateImageAtIndex(imageSource,0,NULL);
  size_t sw=CGImageGetWidth(image),sh=CGImageGetHeight(image);NSMutableData*pixels=[NSMutableData dataWithLength:sw*sh*4];CGColorSpaceRef cs=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);CGContextRef ctx=CGBitmapContextCreate(pixels.mutableBytes,sw,sh,8,sw*4,cs,(CGBitmapInfo)kCGImageAlphaPremultipliedLast);CGContextDrawImage(ctx,CGRectMake(0,0,sw,sh),image);CGContextRelease(ctx);CGImageRelease(image);CFRelease(imageSource);
  MTLTextureDescriptor*sd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:sw height:sh mipmapped:NO];sd.storageMode=MTLStorageModeShared;id<MTLTexture>stone=[dev newTextureWithDescriptor:sd];[stone replaceRegion:MTLRegionMake2D(0,0,sw,sh)mipmapLevel:0 withBytes:pixels.bytes bytesPerRow:sw*4];
  du[0]=1;df[20]=df[21]=df[22]=1;for(int i=4160/4;i<28736/4;i+=2)du[i]=1;memset(box,0,sizeof box);
  id<MTLCommandBuffer>cb=[queue commandBuffer];id<MTLComputeCommandEncoder>e=[cb computeCommandEncoder];[e setComputePipelineState:irrPipe];[e setBuffer:D offset:0 atIndex:0];[e setBytes:box length:16 atIndex:1];[e setTexture:vis atIndex:0];[e setTexture:realIrr atIndex:1];[e setTexture:realDirs atIndex:2];[e dispatchThreads:MTLSizeMake(96,64,96)threadsPerThreadgroup:MTLSizeMake(4,4,4)];[e endEncoding];[cb commit];[cb waitUntilCompleted];need(cb.status==MTLCommandBufferStatusCompleted,cb.error.description);
  NSData*u=[NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"cave-day.bin"]];const float*frame=u.bytes;int W=frame[848/4],H=frame[848/4+1];id<MTLBuffer>room=[dev newBufferWithLength:W*H*16 options:0];id<MTLComputePipelineState>roomPipe=[dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"caveRoom"]error:&err];need(roomPipe!=nil,err.description);
  cb=[queue commandBuffer];e=[cb computeCommandEncoder];[e setComputePipelineState:roomPipe];[e setBuffer:room offset:0 atIndex:0];[e setBuffer:D offset:0 atIndex:1];[e setBytes:u.bytes length:1024 atIndex:16];[e setBytes:(char*)u.bytes+1024 length:u.length-1024 atIndex:17];[e setTexture:vis atIndex:0];[e setTexture:realIrr atIndex:1];[e setTexture:realDirs atIndex:2];[e setTexture:stone atIndex:3];[e dispatchThreads:MTLSizeMake(W,H,1)threadsPerThreadgroup:MTLSizeMake(8,8,1)];[e endEncoding];[cb commit];[cb waitUntilCompleted];need(cb.status==MTLCommandBufferStatusCompleted,cb.error.description);
  NSMutableData*rgba=[NSMutableData dataWithLength:W*H*4];uint8_t*bytes=rgba.mutableBytes;float*rgb=room.contents;for(int i=0;i<W*H*4;i++)bytes[i]=(uint8_t)lrintf(fminf(1,fmaxf(0,rgb[i]))*255);
  ctx=CGBitmapContextCreate(bytes,W,H,8,W*4,cs,(CGBitmapInfo)kCGImageAlphaNoneSkipLast);image=CGBitmapContextCreateImage(ctx);CGImageDestinationRef dst=CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"tunnel.png"]],(__bridge CFStringRef)UTTypePNG.identifier,1,NULL);CGImageDestinationAddImage(dst,image,NULL);need(CGImageDestinationFinalize(dst),@"tunnel png");CFRelease(dst);CGImageRelease(image);CGContextRelease(ctx);CGColorSpaceRelease(cs);
 }
 if(!record)need(passed,@"neutral cave fill, restrained low-light colour, diffuse hand-light shape and falloff");
 printf("%s cave lighting probes\n",passed?"PASS":"RECORDED failing");
}return 0;}
