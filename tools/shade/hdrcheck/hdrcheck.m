// Copyright 2026 mcopt-shade contributors. Apache-2.0.
// Execute the production Metal tone mapper and native presenter, without a game window.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
#include "../../../metal/src/main/native/mcxdr.m"
// The harness has no other encoder open or shade globals to bind.
id<MTLCommandBuffer> mc_frame_cmd(Enc *enc) { return enc->cmd; }
int mc_shade_bind_render(id<MTLRenderCommandEncoder> enc) { return 0; }

static id<MTLDevice> device;
static id<MTLCommandQueue> queue;
static id<MTLLibrary> postLibrary;
static void check(BOOL ok, const char *what) { if (!ok) { fprintf(stderr, "FAIL %s\n", what); exit(1); } }
static void complete(id<MTLCommandBuffer> cb) {
    [cb commit]; [cb waitUntilCompleted];
    check(cb.status == MTLCommandBufferStatusCompleted && !cb.error, cb.error ? cb.error.description.UTF8String : "GPU completion");
}
static id<MTLTexture> texture(MTLPixelFormat fmt, int w, int h) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModeShared;
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    id<MTLTexture> t = [device newTextureWithDescriptor:d];
    check(t != nil, "texture allocation"); return t;
}
static void fill(id<MTLTexture> t, float r, float g, float b, float a) {
    size_t count = t.width * t.height, bpp = t.pixelFormat == MTLPixelFormatRGBA8Unorm ? 4 : 8;
    void *data = calloc(count, bpp);
    for (size_t i = 0; i < count; i++) {
        float v[4] = {r, g, b, a};
        for (int k = 0; k < 4; k++) {
            if (bpp == 4) ((uint8_t *)data)[4*i+k] = (uint8_t)lroundf(fminf(1, fmaxf(0, v[k]))*255);
            else ((_Float16 *)data)[4*i+k] = v[k];
        }
    }
    [t replaceRegion:MTLRegionMake2D(0,0,t.width,t.height) mipmapLevel:0 withBytes:data bytesPerRow:t.width*bpp]; free(data);
}
static void clearOn(id<MTLCommandBuffer> cb, id<MTLTexture> t, float value, float alpha) {
    MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture=t; rp.colorAttachments[0].loadAction=MTLLoadActionClear;
    rp.colorAttachments[0].storeAction=MTLStoreActionStore;
    rp.colorAttachments[0].clearColor=MTLClearColorMake(value,value,value,alpha);
    [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
}
static float linear(float x) { return x <= .04045f ? x/12.92f : powf((x+.055f)/1.055f,2.4f); }
static void p3(float *c, float *out) {
    out[0]=.822462f*c[0]+.177538f*c[1];
    out[1]=.033194f*c[0]+.966806f*c[1];
    out[2]=.017083f*c[0]+.072397f*c[1]+.910520f*c[2];
}
static void expect(id<MTLTexture> out, float r, float g, float b, const char *name) {
    size_t count=out.width*out.height;
    _Float16 *pixels=malloc(count*8);
    [out getBytes:pixels bytesPerRow:out.width*8 fromRegion:MTLRegionMake2D(0,0,out.width,out.height) mipmapLevel:0];
    float c[3]={r,g,b}, expected[3]; p3(c,expected);
    for(size_t i=0;i<count;i++) for(int k=0;k<3;k++)
        check(isfinite((float)pixels[i*4+k]) && fabsf((float)pixels[i*4+k]-expected[k]) < .012f, name);
    free(pixels);
}
static void curves(NSString *folder) {
    NSError *error=nil;
    NSString *src=[NSString stringWithContentsOfFile:[folder stringByAppendingPathComponent:@"post.metal"] encoding:NSUTF8StringEncoding error:&error];
    src=[src stringByAppendingString:@"\nkernel void hdr_test(device const float4 *inputs [[buffer(1)]], device float4 *outputs [[buffer(2)]], constant ShadeFinalParams &p [[buffer(0)]], constant ShadeLook &l [[buffer(17)]], uint i [[thread_position_in_grid]]) { outputs[i]=float4(shadeFullHdr(inputs[i].rgb,l,p),1); }\n"];
    MTLCompileOptions *opts=[MTLCompileOptions new]; opts.languageVersion=MTLLanguageVersion3_0;
    id<MTLLibrary> lib=[device newLibraryWithSource:src options:opts error:&error];
    check(lib != nil, error.description.UTF8String);
    postLibrary=lib;
    id<MTLComputePipelineState> pipe=[device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"hdr_test"] error:&error];
    check(pipe != nil, error.description.UTF8String);
    NSData *data=[NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"curves.bin"]];
    check(data.length==30*16, "Java curve fixtures"); const float *cs=data.bytes;
    enum {N=516};
    id<MTLBuffer> input=[device newBufferWithLength:N*16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> output=[device newBufferWithLength:N*16 options:MTLResourceStorageModeShared];
    float *in=input.contents;
    for(int i=0;i<512;i++) for(int c=0;c<4;c++) in[4*i+c]=i==0?0:exp2f(-14+i*25.f/511);
    in[512*4]=in[512*4+1]=in[512*4+2]=.18f;
    in[513*4]=in[513*4+1]=in[513*4+2]=1.f;
    in[514*4]=1000; in[514*4+1]=10; in[514*4+2]=.01;
    in[515*4]=.01; in[515*4+1]=10; in[515*4+2]=1000;
    for(int row=0;row<30;row++) for(int brightness=0;brightness<3;brightness++) {
        float l[272]={0}, p[24]={0};
        for(int k=0;k<3;k++) { l[816/4+k*5]=1; l[864/4+k*5]=1; l[368/4+k]=1; }
        l[384/4]=cs[row*4]; l[384/4+1]=.92f;
        p[16]=2; p[17]=cs[row*4+1]; p[18]=cs[row*4+2]; p[19]=cs[row*4+3]; p[23]=(float[]){.5,1,2}[brightness];
        id<MTLCommandBuffer> cb=[queue commandBuffer]; id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder];
        [e setComputePipelineState:pipe]; [e setBuffer:input offset:0 atIndex:1]; [e setBuffer:output offset:0 atIndex:2];
        [e setBytes:p length:sizeof p atIndex:0]; [e setBytes:l length:sizeof l atIndex:17];
        [e dispatchThreads:MTLSizeMake(N,1,1) threadsPerThreadgroup:MTLSizeMake(32,1,1)]; [e endEncoding]; complete(cb);
        float *v=output.contents;
        for(int i=0;i<N;i++) for(int k=0;k<3;k++) check(isfinite(v[4*i+k]) && v[4*i+k]>=0 && v[4*i+k]<=p[17]+.001, "finite, nonnegative, peak bounded");
        for(int i=1;i<512;i++) check(v[i*4]+1e-5>=v[(i-1)*4], "monotonic gray ramp");
        if(brightness==1) check(fabsf(v[512*4]-.2f)<.0002, "middle gray remains anchored");
        if(brightness==1 && p[17]>=4 && cs[row*4]>=1.4f) check(v[513*4]>1, "ordinary bright surfaces exceed SDR white");
    }
    printf("OK 90 GPU tone-curve configurations: gray anchor, monotonicity, scene brightness, saturated colours, peak bounds\n");
}

static void compositor(void) {
    mc_xdr_enable(1); mc_xdr_e5(0);
    check(mc_xdr_ready(device), "native EDR pipelines");
    for(int size=0;size<2;size++) {
        int w=size?12:8, h=size?10:6;
        id<MTLTexture> main=texture(MTLPixelFormatRGBA8Unorm,w,h);
        id<MTLTexture> hdr=texture(MTLPixelFormatRGBA16Float,w/2,h/2);
        id<MTLTexture> out=texture(MTLPixelFormatRGBA16Float,w,h);
        fill(main,128/255.f,128/255.f,128/255.f,0); fill(hdr,2,1,.5,1);
        Enc enc={0}; enc.cmd=[queue commandBuffer];
        mc_xdr_full_frame(&enc,hdr,main,1,4);
        check(mc_xdr_compose(enc.cmd,main,out,0), "compose complete world"); complete(enc.cmd);
        expect(out,2,1,.5,"uncovered HDR bypasses SDR image");
        for(int kind=0;kind<3;kind++) {
            fill(main,128/255.f,128/255.f,128/255.f,0);
            enc.cmd=[queue commandBuffer]; mc_xdr_full_frame(&enc,hdr,main,kind==1?.5:1,4);
            float a=kind==2?128/255.f:1;
            float m=kind==2?192/255.f:1;
            clearOn(enc.cmd,main,m,a);
            mc_xdr_compose(enc.cmd,main,out,0); complete(enc.cmd);
            float ui=linear(fminf(1,(m-(128/255.f)*(1-a))/a))*a*(kind==1?.5:1);
            expect(out,2*(1-a)+ui,1*(1-a)+ui,.5*(1-a)+ui,"opaque/translucent HUD and UI brightness");
        }
        // The following frame must not reuse HDR (e.g. title screen or skipped present).
        enc.cmd=[queue commandBuffer]; mc_xdr_compose(enc.cmd,main,out,0); complete(enc.cmd);
        float s=linear(192/255.f); expect(out,s,s,s,"stale frame falls back to SDR");
        // Register a frame but compose a different buffer: same-command-buffer protection.
        enc.cmd=[queue commandBuffer]; mc_xdr_full_frame(&enc,hdr,main,1,4); complete(enc.cmd);
        id<MTLCommandBuffer> other=[queue commandBuffer]; mc_xdr_compose(other,main,out,0); complete(other);
        expect(out,s,s,s,"skipped frame cannot leak to next command buffer");
        [main release]; [hdr release]; [out release];
    }
    printf("OK native HDR compositor: world, opaque/translucent HUD, UI brightness, reduced output, resize, stale/skipped frames\n");
}
static void orientationAndLegacy(void) {
    id<MTLTexture> main=texture(MTLPixelFormatRGBA8Unorm,8,6);
    id<MTLTexture> hdr=texture(MTLPixelFormatRGBA16Float,4,3);
    id<MTLTexture> out=texture(MTLPixelFormatRGBA16Float,8,6);
    id<MTLTexture> stage=texture(MTLPixelFormatRGB9E5Float,8,6);
    fill(main,128/255.f,128/255.f,128/255.f,0);
    _Float16 pattern[4*3*4];
    for(int y=0;y<3;y++) for(int x=0;x<4;x++) {
        int i=(y*4+x)*4; pattern[i]=.5+x*.5; pattern[i+1]=.25+y*.5; pattern[i+2]=.375; pattern[i+3]=1;
    }
    [hdr replaceRegion:MTLRegionMake2D(0,0,4,3) mipmapLevel:0 withBytes:pattern bytesPerRow:4*8];
    _Float16 normal[8*6*4], flipped[8*6*4];
    for(int flip=0;flip<2;flip++) {
        Enc enc={0}; enc.cmd=[queue commandBuffer];
        mc_xdr_full_frame(&enc,hdr,main,1,4); mc_xdr_compose(enc.cmd,main,out,flip); complete(enc.cmd);
        [out getBytes:flip?flipped:normal bytesPerRow:8*8 fromRegion:MTLRegionMake2D(0,0,8,6) mipmapLevel:0];
    }
    for(int y=0;y<6;y++) for(int x=0;x<8;x++) for(int k=0;k<3;k++)
        check(normal[(y*8+x)*4+k]==flipped[((5-y)*8+x)*4+k],"direct present orientation with reduced HDR size");
    mc_xdr_e5(1);
    Enc enc={0}; enc.cmd=[queue commandBuffer];
    mc_xdr_full_frame(&enc,hdr,main,1,4); mc_xdr_compose(enc.cmd,main,stage,0); complete(enc.cmd);
    uint32_t packed[8*6]; [stage getBytes:packed bytesPerRow:8*4 fromRegion:MTLRegionMake2D(0,0,8,6) mipmapLevel:0];
    enc.cmd=[queue commandBuffer]; mc_xdr_full_frame(&enc,hdr,main,1,4); mc_xdr_compose(enc.cmd,main,out,1); complete(enc.cmd);
    [out getBytes:flipped bytesPerRow:8*8 fromRegion:MTLRegionMake2D(0,0,8,6) mipmapLevel:0];
    for(int y=0;y<6;y++) for(int x=0;x<8;x++) for(int k=0;k<3;k++) {
        uint32_t v=packed[y*8+x]; float value=((v>>(9*k))&511)*exp2f((int)(v>>27)-24);
        check(fabsf(value-(float)flipped[((5-y)*8+x)*4+k])<.0041,"queued RGB9E5 and direct presentation agree");
    }
    mc_xdr_e5(0);
    fill(hdr,.5,.5,.5,1);
    enc.cmd=[queue commandBuffer]; mc_xdr_frame(&enc,hdr); mc_xdr_compose(enc.cmd,main,out,0); complete(enc.cmd);
    float v=linear(128/255.f)+.5;
    expect(out,v,v,v,"legacy highlight addition unchanged after full-scene mode");
    mc_xdr_frame(&enc,nil);
    enc.cmd=[queue commandBuffer]; mc_xdr_compose(enc.cmd,main,out,0); complete(enc.cmd);
    v=linear(128/255.f); expect(out,v,v,v,"explicit SDR fallback");
    printf("OK reduced-output orientation, queued/direct presentation, mode switch and SDR fallback\n");
    [main release]; [hdr release]; [out release]; [stage release];
}

// Measures the real lean final shader + native presentation, including the full
// mode's SDR reference copy. Fixed synthetic scene, no haze/VL/bloom or game CPU.
static void benchmark(NSString *folder) {
    const int w=3840,h=2160;
    id<MTLTexture> main=texture(MTLPixelFormatRGBA8Unorm,w,h);
    id<MTLTexture> hdr=texture(MTLPixelFormatRGBA16Float,w,h);
    id<MTLTexture> excess=texture(MTLPixelFormatRG11B10Float,w,h);
    id<MTLTexture> out=texture(MTLPixelFormatRGB9E5Float,w,h);
    id<MTLTexture> inputs[2];
    _Float16 *pixels=malloc((size_t)w*h*8);
    for(int k=0;k<2;k++) {
        inputs[k]=texture(MTLPixelFormatRGBA16Float,w,h);
        for(int y=0;y<h;y++) for(int x=0;x<w;x++) {
            size_t i=((size_t)y*w+x)*4;
            float v=exp2f(-6.f+12.f*(x+k*.3f)/w)*(0.75f+0.25f*((x/8+y/8)%2));
            pixels[i]=v; pixels[i+1]=v*(.5f+.5f*y/h); pixels[i+2]=v*.4f; pixels[i+3]=1;
        }
        [inputs[k] replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:pixels bytesPerRow:w*8];
    }
    free(pixels);
    MTLTextureDescriptor *dd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:w height:h mipmapped:NO];
    dd.storageMode=MTLStorageModePrivate; dd.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
    id<MTLTexture> depth=[device newTextureWithDescriptor:dd];
    id<MTLCommandBuffer> init=[queue commandBuffer];
    MTLRenderPassDescriptor *dr=[MTLRenderPassDescriptor renderPassDescriptor];
    dr.depthAttachment.texture=depth; dr.depthAttachment.loadAction=MTLLoadActionClear; dr.depthAttachment.clearDepth=0;
    dr.depthAttachment.storeAction=MTLStoreActionStore; [[init renderCommandEncoderWithDescriptor:dr] endEncoding]; complete(init);
    id<MTLRenderPipelineState> pipes[2]; NSError *error=nil;
    for(int k=0;k<2;k++) {
        MTLRenderPipelineDescriptor *d=[MTLRenderPipelineDescriptor new];
        d.vertexFunction=[postLibrary newFunctionWithName:@"shade_fs_vs"];
        d.fragmentFunction=[postLibrary newFunctionWithName:k?@"shade_final_hdr_lean":@"shade_final_xdr_lean"];
        d.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
        d.colorAttachments[1].pixelFormat=k?MTLPixelFormatRGBA16Float:MTLPixelFormatRG11B10Float;
        pipes[k]=[device newRenderPipelineStateWithDescriptor:d error:&error]; check(pipes[k]!=nil,error.description.UTF8String);
    }
    float look[280]={0}, frame[512]={0}, gpu[256]={0}, resource[256]={0};
    NSData *data=[NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"curves.bin"]];
    const float *cs=data.bytes;
    for(int i=0;i<3;i++) { look[816/4+i*5]=1; look[864/4+i*5]=1; look[368/4+i]=1; }
    look[384/4]=1.4; look[384/4+1]=.92; look[384/4+2]=cs[12*4+2]; look[384/4+3]=cs[12*4+3];
    look[400/4]=1; look[400/4+2]=1; look[352/4+3]=.0025;
    for(int m=0;m<4;m++) for(int i=0;i<4;i++) frame[m*16+i*5]=1;
    gpu[176/4]=1;
    MTLSamplerDescriptor *sd=[MTLSamplerDescriptor new]; sd.minFilter=sd.magFilter=MTLSamplerMinMagFilterLinear;
    id<MTLSamplerState> sampler=[device newSamplerStateWithDescriptor:sd];
    NSString *path=[folder stringByAppendingPathComponent:@"samples.csv"];
    FILE *csv=fopen(path.UTF8String,"w"); check(csv!=NULL,"open benchmark CSV");
    fprintf(csv,"pair,order,mode,batch,gpu_ms_per_frame\n");
    for(int pair=0;pair<8;pair++) for(int order=0;order<2;order++) {
        int mode=order^(pair&1); double sum=0;
        for(int batch=0;batch<32;batch++) { @autoreleasepool {
            Enc enc={0}; enc.cmd=[queue commandBuffer];
            for(int f=0;f<16;f++) {
                float p[24]={0}; p[2]=batch*16+f; p[5]=1; p[12]=w; p[13]=h; p[14]=.3;
                p[16]=mode?2:1; p[17]=4; p[18]=mode?cs[15*4+2]:2; p[19]=mode?cs[15*4+3]:3.5; p[23]=1;
                MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture=main; rp.colorAttachments[1].texture=mode?hdr:excess;
                for(int i=0;i<2;i++) { rp.colorAttachments[i].loadAction=MTLLoadActionDontCare; rp.colorAttachments[i].storeAction=MTLStoreActionStore; }
                id<MTLRenderCommandEncoder> r=[enc.cmd renderCommandEncoderWithDescriptor:rp];
                [r setRenderPipelineState:pipes[mode]];
                for(int i=0;i<6;i++) [r setFragmentTexture:i==2?depth:inputs[f%2] atIndex:i];
                [r setFragmentTexture:inputs[0] atIndex:17]; [r setFragmentSamplerState:sampler atIndex:13];
                [r setFragmentBytes:p length:sizeof p atIndex:0]; [r setFragmentBytes:frame length:sizeof frame atIndex:16];
                [r setFragmentBytes:look length:sizeof look atIndex:17]; [r setFragmentBytes:gpu length:sizeof gpu atIndex:18];
                [r setFragmentBytes:resource length:sizeof resource atIndex:19];
                [r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [r endEncoding];
                if(mode) mc_xdr_full_frame(&enc,hdr,main,1,4); else mc_xdr_frame(&enc,excess);
                check(mc_xdr_compose(enc.cmd,main,out,0),"benchmark compose");
            }
            complete(enc.cmd);
            check(enc.cmd.GPUEndTime>enc.cmd.GPUStartTime,"GPU timestamps");
            if(batch>=8) {
                double ms=(enc.cmd.GPUEndTime-enc.cmd.GPUStartTime)*1000/16;
                sum+=ms; fprintf(csv,"%d,%d,%s,%d,%.6f\n",pair,order,mode?"scene":"highlights",batch-8,ms);
            }
        } }
        printf("BENCH {\"pair\":%d,\"order\":%d,\"mode\":\"%s\",\"mean_gpu_ms\":%.6f}\n",pair,order,mode?"scene":"highlights",sum/24); fflush(stdout);
    }
    fclose(csv);
}

int main(int argc,const char **argv) {
    @autoreleasepool {
        check(argc>=2,"usage: hdrcheck fixture-directory [perf]");
        device=MTLCreateSystemDefaultDevice(); queue=[device newCommandQueue];
        curves([NSString stringWithUTF8String:argv[1]]); compositor(); orientationAndLegacy();
        if(argc>2 && !strcmp(argv[2],"perf")) benchmark([NSString stringWithUTF8String:argv[1]]);
        printf("HDR checks passed on %s\n",device.name.UTF8String);
    }
    return 0;
}
