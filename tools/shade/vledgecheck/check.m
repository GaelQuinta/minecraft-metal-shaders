// Copyright 2026 mcopt-shade contributors. Apache-2.0.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>

static void require(BOOL ok, NSString *why) {
    if (!ok) { fprintf(stderr, "%s\n", why.UTF8String); exit(2); }
}
static void put4(float *p, int offset, float x, float y, float z, float w) {
    p[offset/4]=x; p[offset/4+1]=y; p[offset/4+2]=z; p[offset/4+3]=w;
}

int main(int argc, const char **argv) { @autoreleasepool {
    require(argc==2 || argc==3, @"usage: check fixture-dir [source-override.metal]");
    NSString *dir=@(argv[1]); NSError *error=nil;
    id<MTLDevice> dev=MTLCreateSystemDefaultDevice(); require(dev!=nil,@"No Metal device");
    NSString *path=argc==3 ? @(argv[2]) : [dir stringByAppendingPathComponent:@"vl.metal"];
    NSString *src=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    MTLCompileOptions *opt=[MTLCompileOptions new];
    opt.languageVersion=MTLLanguageVersion3_0; opt.mathMode=MTLMathModeFast;
    id<MTLLibrary> lib=[dev newLibraryWithSource:src options:opt error:&error]; require(lib!=nil,error.description);
    MTLFunctionConstantValues *fc=[MTLFunctionConstantValues new];
    bool hdr=true; [fc setConstantValue:&hdr type:MTLDataTypeBool atIndex:0];
    id<MTLFunction> fs=[lib newFunctionWithName:@"vl_march" constantValues:fc error:&error]; require(fs!=nil,error.description);
    MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
    pd.vertexFunction=[lib newFunctionWithName:@"vl_vs"]; pd.fragmentFunction=fs;
    pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA16Float;
    pd.colorAttachments[1].pixelFormat=MTLPixelFormatR8Unorm;
    id<MTLRenderPipelineState> pipe=[dev newRenderPipelineStateWithDescriptor:pd error:&error]; require(pipe!=nil,error.description);
    id<MTLCommandQueue> queue=[dev newCommandQueue];
    id<MTLTexture> (^tex)(MTLPixelFormat,int,int)=^id<MTLTexture>(MTLPixelFormat format,int w,int h) {
        MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
        d.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
        d.storageMode=format==MTLPixelFormatDepth32Float ? MTLStorageModePrivate : MTLStorageModeShared;
        return [dev newTextureWithDescriptor:d];
    };
    enum { W=320, H=200, FRAME=1024 };
    id<MTLTexture> raw=tex(MTLPixelFormatRGBA16Float,W,H), sky=tex(MTLPixelFormatR8Unorm,W,H);
    id<MTLTexture> prev=tex(MTLPixelFormatR8Unorm,W,H), depth=tex(MTLPixelFormatDepth32Float,W*2,H*2);
    MTLTextureDescriptor *sd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:1 height:1 mipmapped:NO];
    sd.textureType=MTLTextureType2DArray; sd.arrayLength=2;
    sd.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget; sd.storageMode=MTLStorageModePrivate;
    id<MTLTexture> shadow=[dev newTextureWithDescriptor:sd];
    MTLTextureDescriptor *gd=[MTLTextureDescriptor new];
    gd.textureType=MTLTextureType3D; gd.width=gd.height=gd.depth=1; gd.pixelFormat=MTLPixelFormatR8Unorm;
    gd.usage=MTLTextureUsageShaderRead; gd.storageMode=MTLStorageModeShared;
    id<MTLTexture> grid=[dev newTextureWithDescriptor:gd];
    unsigned char one=255;
    [grid replaceRegion:MTLRegionMake3D(0,0,0,1,1,1) mipmapLevel:0 slice:0 withBytes:&one bytesPerRow:1 bytesPerImage:1];
    id<MTLTexture> lut=tex(MTLPixelFormatRGBA16Float,1,1);
    uint16_t zero[4]={0}; [lut replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:zero bytesPerRow:8];
    id<MTLArgumentEncoder> ae=[fs newArgumentEncoderWithBufferIndex:19];
    id<MTLBuffer> resources=[dev newBufferWithLength:ae.encodedLength options:MTLResourceStorageModeShared];
    [ae setArgumentBuffer:resources offset:0];
    for (int i=0;i<16;i++) [ae setTexture:lut atIndex:i];
    MTLSamplerDescriptor *cs=[MTLSamplerDescriptor new]; cs.compareFunction=MTLCompareFunctionGreaterEqual;
    id<MTLSamplerState> cmp=[dev newSamplerStateWithDescriptor:cs];
    cs.compareFunction=MTLCompareFunctionNever; cs.minFilter=cs.magFilter=MTLSamplerMinMagFilterLinear;
    id<MTLSamplerState> lin=[dev newSamplerStateWithDescriptor:cs];
    id<MTLCommandBuffer> init=[queue commandBuffer];
    MTLRenderPassDescriptor *clear=[MTLRenderPassDescriptor renderPassDescriptor];
    clear.depthAttachment.texture=depth; clear.depthAttachment.loadAction=MTLLoadActionClear;
    clear.depthAttachment.storeAction=MTLStoreActionStore; clear.depthAttachment.clearDepth=0;
    [[init renderCommandEncoderWithDescriptor:clear] endEncoding]; [init commit]; [init waitUntilCompleted];

    // Air-mode defaults, with no forest medium or shadow casters. The only possible
    // shadow in this clear scene is from the actual screen-space crepuscular march.
    float params[124]={0}, stateData[4]={0};
    float *p=params, *state=stateData;
    put4(p,0,W,H,W*2,H*2);                       // size: quality preset's half resolution
    put4(p,16,1,128,16,.68);                      // shape
    put4(p,32,0,0,0,12); put4(p,48,0,48,.12,.05);
    put4(p,64,1,.8,.5,0);                        // light
    put4(p,80,.2,10,1,6);                        // crep: golden-hour strength
    put4(p,96,W,H*1.292,.6,123);                  // sunPx, temporal/filter flags
    put4(p,144,.9,0,4,0);                        // temporal
    put4(p,176,.7,6,0,0); put4(p,192,0,16,0,0);  // gate and extra
    put4(p,208,24,16,0,0); put4(p,240,0,0,1,1);  // mist, history live extent
    put4(p,256,1,1,0,0);                         // extra sunset rays
    put4(p,352,1,8,.1,26); put4(p,368,128,0,1,.55);
    put4(p,384,-64,-24,-64,2); put4(p,400,0,0,0,4);
    put4(p,416,.3,.85,24,.05); put4(p,480,1.5,20,0,1);
    _Float16 *pixels=malloc(W*H*8);
    unsigned char *mask=malloc(W*H);
    float (^render)(int,NSString *)=^float(int camera,NSString *dump) {
        NSData *u=[NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"camera%d.bin",camera]]];
        NSUInteger LOOK=u.length-FRAME; require(LOOK==1088 || LOOK==1120,@"Uniform layout changed: update the test bindings");
        id<MTLCommandBuffer> cb=[queue commandBuffer];
        MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture=raw; rp.colorAttachments[1].texture=sky;
        for (int i=0;i<2;i++) {
            rp.colorAttachments[i].loadAction=MTLLoadActionDontCare;
            rp.colorAttachments[i].storeAction=MTLStoreActionStore;
        }
        id<MTLRenderCommandEncoder> e=[cb renderCommandEncoderWithDescriptor:rp];
        [e setRenderPipelineState:pipe];
        [e setFragmentBytes:u.bytes length:FRAME atIndex:16];
        [e setFragmentBytes:(const char*)u.bytes+FRAME length:LOOK atIndex:17];
        [e setFragmentBytes:p length:496 atIndex:0]; [e setFragmentBytes:state length:16 atIndex:1];
        [e setFragmentBuffer:resources offset:0 atIndex:19]; [e useResource:lut usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
        [e setFragmentTexture:depth atIndex:0]; [e setFragmentTexture:prev atIndex:1];
        [e setFragmentTexture:grid atIndex:2]; [e setFragmentTexture:shadow atIndex:16]; [e setFragmentTexture:lut atIndex:17];
        [e setFragmentSamplerState:cmp atIndex:12]; [e setFragmentSamplerState:lin atIndex:13];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding];
        [cb commit]; [cb waitUntilCompleted]; require(cb.status==MTLCommandBufferStatusCompleted,cb.error.description);
        [raw getBytes:pixels bytesPerRow:W*8 fromRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0];
        float mx=0;
        for (int i=0;i<W*H;i++) for (int c=0;c<4;c++) {
            float v=pixels[i*4+c]; require(isfinite(v),@"Non-finite light");
            if (c<3) mx=fmaxf(mx,fabsf(v));
        }
        if (dump) [[NSData dataWithBytes:pixels length:W*H*8] writeToFile:[dir stringByAppendingPathComponent:dump] atomically:YES];
        return mx;
    };
    int failed=0, total=0; float worst=0;
    const int counts[]={6,8,10,12,32};
    for (int small=0;small<2;small++) {
        float live=small ? .75 : 1;
        p[62]=p[63]=live;
        // Deliberately poison unused allocation: DRS must sample only last frame's live area.
        for (int y=0;y<H;y++) for (int x=0;x<W;x++) mask[y*W+x]=x<W*live && y<H*live ? 255 : 0;
        [prev replaceRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0 withBytes:mask bytesPerRow:W];
        for (int smooth=0;smooth<2;smooth++) for (int n=0;n<5;n++) for (int camera=0;camera<9;camera++) {
            p[27]=123+4*smooth; p[21]=counts[n];
            NSString *dump=!small && !smooth && n==2 ? [NSString stringWithFormat:@"camera%d.rgba16",camera] : nil;
            float mx=render(camera,dump); worst=fmaxf(worst,mx); total++; failed+=mx>.001;
        }
    }
    printf("Clear sky: %d/%d cases pass; worst false shadow %.6f\n",total-failed,total,worst);
    p[62]=p[63]=1; p[21]=10; p[27]=123;
    memset(mask,0,W*H); [prev replaceRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0 withBytes:mask bytesPerRow:W];
    float blocked=render(0,@"blocked.rgba16");
    // The centre's complete ray is covered and should retain its previous shading exactly.
    float centre=(float)pixels[(H/2*W+W/2)*4];
    float behind=render(5,nil);
    p[37]=1; float reset=render(0,nil); p[37]=0;
    p[20]=0; float disabled=render(0,nil);
    printf("Occlusion control %.6f (centre %.6f); behind-camera %.6f; reset %.6f; disabled %.6f\n",blocked,centre,behind,reset,disabled);
    failed += blocked<.5 || behind>.001 || reset>.001 || disabled>.001;
    printf("%s: viewport coverage must not cast sunlight shadows\n",failed?"FAIL":"PASS");
    free(pixels); free(mask); return failed?1:0;
}}
