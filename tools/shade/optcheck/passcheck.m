// Copyright 2026 mcopt-shade contributors. Apache-2.0.
// Calls the production native pass encoder from the built dylib, without launching Minecraft.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
#import "../../../metal/src/main/native/mcmetal.h"
extern void *mc_shade_new(Ctx *ctx);
extern void mc_shade_set(id<MTLBuffer>, uint64_t, id<MTLTexture>, id<MTLSamplerState>);
extern void mc_shade_set_m2(Ctx *, id<MTLBuffer>, uint64_t, id<MTLBuffer>);
extern void mc_shade_pass(Enc *, id<MTLRenderPipelineState>, id<MTLTexture>, int, id<MTLTexture> const *, int, const void *, int, const char *, int);
static void require(BOOL ok, NSString *message) { if (!ok) { fprintf(stderr,"FAIL %s\n",message.UTF8String); exit(1); } }
static id<MTLTexture> texture(id<MTLDevice> dev, int w, int h) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:w height:h mipmapped:NO];
    d.storageMode=MTLStorageModeShared; d.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
    return [dev newTextureWithDescriptor:d];
}
static id<MTLRenderPipelineState> pipeline(id<MTLDevice> dev,id<MTLLibrary> lib,NSString *fs) {
    MTLRenderPipelineDescriptor *d=[MTLRenderPipelineDescriptor new];
    d.vertexFunction=[lib newFunctionWithName:@"shade_fs_vs"]; d.fragmentFunction=[lib newFunctionWithName:fs];
    d.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA16Float;
    NSError *error=nil; id<MTLRenderPipelineState> p=[dev newRenderPipelineStateWithDescriptor:d error:&error];
    require(p!=nil,error.description); return p;
}
static void finish(Enc *enc) { [enc->cmd commit]; [enc->cmd waitUntilCompleted]; require(enc->cmd.status==MTLCommandBufferStatusCompleted,enc->cmd.error.description); enc->cmd=nil; }
static void fill(id<MTLTexture> t, int frame, float peak) {
    int w=(int)t.width,h=(int)t.height; __fp16 *p=calloc(w*h*4,sizeof(*p));
    for(int y=0;y<h;y++)for(int x=0;x<w;x++){
        float sx=w*.45f+frame*.43f,sy=h*.6f+frame*.17f;
        float dx=x-sx,dy=y-sy;
        float spot=expf(-(dx*dx+dy*dy)/8.f);
        float v=peak*(.005f+spot*.995f);
        if(frame%3==1)v=peak*((x+y)&1 ? 1.f : .0001f);
        if(frame%3==2)v=peak*(.5f+.5f*sinf(x*.73f+frame*.37f)*cosf(y*.31f-frame*.13f));
        p[4*(y*w+x)]=v; p[4*(y*w+x)+1]=v*.43f; p[4*(y*w+x)+2]=v*.12f; p[4*(y*w+x)+3]=1;
    }
    [t replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:p bytesPerRow:w*8]; free(p);
}
int main(int argc,const char **argv) { @autoreleasepool {
    require(argc==2,@"usage: passcheck post.metal");
    id<MTLDevice> dev=MTLCreateSystemDefaultDevice(); require(dev!=nil,@"No Metal device");
    Ctx ctx={0}; ctx.device=dev;ctx.queue=[dev newCommandQueue];
    Enc *enc=calloc(1,sizeof(Enc));enc->ctx=&ctx;
    mc_shade_new(&ctx);
    id<MTLBuffer> frame=[dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    id<MTLBuffer> look=[dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    id<MTLBuffer> gpu=[dev newBufferWithLength:512 options:MTLResourceStorageModeShared];
    mc_shade_set(frame,0,nil,nil);mc_shade_set_m2(&ctx,look,0,gpu);
    NSError *error=nil;
    NSString *source=[NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&error]; require(source!=nil,error.description);
    MTLCompileOptions *options=[MTLCompileOptions new];options.languageVersion=MTLLanguageVersion3_0;
    id<MTLLibrary> lib=[dev newLibraryWithSource:source options:options error:&error];require(lib!=nil,error.description);
    NSArray<NSString *> *names=@[@"shade_bloom_down0",@"shade_bloom_down",@"shade_bloom_up"];
    int checks=0;
    for(int mode=0;mode<3;mode++){
        id<MTLRenderPipelineState> p=pipeline(dev,lib,names[mode]);
        for(int variant=0;variant<4;variant++){
            int w=variant&1 ? 63:64,h=variant&1 ? 43:42;
            id<MTLTexture> inputs[]={texture(dev,w*2,h*2),texture(dev,(w+1)/2,(h+1)/2)};
            fill(inputs[0],variant,variant&2?30000:4);fill(inputs[1],variant+1,variant&2?30000:4);
            id<MTLTexture> outputs[]={texture(dev,w,h),texture(dev,w,h)};
            unsigned hot[2];
            float params[4]={mode==2?.7f:1.f,mode==2?.3f:1.f,variant&2?1.f:0.f,0};
            for(int lean=0;lean<2;lean++){
                memset(gpu.contents,0,512);
                mc_shade_pass(enc,p,outputs[lean],0,inputs,mode==2?2:1,params,16,"binding regression",lean?(mode==0?1:0):-1);
                finish(enc);hot[lean]=((unsigned *)gpu.contents)[464/4];
            }
            size_t bytes=w*h*8;__fp16 *a=malloc(bytes),*b=malloc(bytes);
            [outputs[0] getBytes:a bytesPerRow:w*8 fromRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0];
            [outputs[1] getBytes:b bytesPerRow:w*8 fromRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0];
            require(memcmp(a,b,bytes)==0,[NSString stringWithFormat:@"%@ scoped bindings changed pixels",names[mode]]);
            for(int i=0;i<w*h*4;i++)require(isfinite((float)b[i]),[NSString stringWithFormat:@"%@ variant %d nonfinite output at %d: %g",names[mode],variant,i,(float)b[i]]);
            require(hot[0]==hot[1],@"XDR detection differs");
            if(mode==0 && (variant&2))require(hot[1]==1,@"missing HDR hot flag");
            free(a);free(b);checks++;
        }
    }
    printf("PASS %d production bloom passes: full/scoped bindings byte-identical, finite, HDR detection preserved (%s)\n",checks,dev.name.UTF8String);
    free(enc);
}return 0;}
