// Copyright 2026 mcopt-shade contributors. Apache-2.0.
// Reuse the production-pass test's setup helpers; no game/window is created.
#define main binding_check_main
#include "passcheck.m"
#undef main
#import <ImageIO/ImageIO.h>
static void png(id<MTLTexture> t, NSString *path) {
    int w=(int)t.width,h=(int)t.height;__fp16 *f=malloc(w*h*8);unsigned char *b=malloc(w*h*4);
    [t getBytes:f bytesPerRow:w*8 fromRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0];
    for(int i=0;i<w*h;i++){for(int c=0;c<3;c++)b[i*4+c]=(unsigned char)lrintf(fminf(1,fmaxf(0,f[i*4+c]))*255);b[i*4+3]=255;}
    CFDataRef data=CFDataCreate(NULL,b,w*h*4);CGDataProviderRef provider=CGDataProviderCreateWithCFData(data);CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef img=CGImageCreate(w,h,8,32,w*4,space,(CGBitmapInfo)kCGImageAlphaLast,provider,NULL,false,kCGRenderingIntentDefault);
    CGImageDestinationRef dest=CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],CFSTR("public.png"),1,NULL);
    CGImageDestinationAddImage(dest,img,NULL);require(CGImageDestinationFinalize(dest),@"PNG export");
    CFRelease(dest);CGImageRelease(img);CGColorSpaceRelease(space);CGDataProviderRelease(provider);CFRelease(data);free(b);free(f);
}
static void scene(id<MTLTexture> t) {
    int w=(int)t.width,h=(int)t.height;__fp16 *v=calloc(w*h*4,sizeof(*v));
    for(int y=0;y<h;y++)for(int x=0;x<w;x++){
        float u=(x+.5f)/w,q=(y+.5f)/h,rr=.025f,gg=.026f,bb=.027f;
        if(q>.7){rr=gg=bb=.12f;}
        if(u>.33&&u<.65&&q>.30&&q<.70){rr=gg=bb=.25f;}
        float dx=u-.20f,dy=q-.42f;
        if(dx*dx+dy*dy<.002f){rr=gg=bb=24;}
        if(u>.74&&u<.85&&q>.3&&q<.65){rr=20;gg=7;bb=.8;}
        if(u>.1&&u<.3&&q>.77&&q<.8){rr=.05;gg=.2;bb=4;}
        v[4*(y*w+x)]=rr;v[4*(y*w+x)+1]=gg;v[4*(y*w+x)+2]=bb;v[4*(y*w+x)+3]=1;
    }
    [t replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:v bytesPerRow:w*8];free(v);
}
int main(int argc,const char **argv){@autoreleasepool{
    require(argc==5,@"usage: bloomcheck post.metal reference.metal probe.metal OUT");
    NSString *out=@(argv[4]);NSError *error=nil;
    NSString *src=[NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&error];
    src=[src stringByAppendingString:[NSString stringWithContentsOfFile:@(argv[2]) encoding:NSUTF8StringEncoding error:&error]];
    src=[src stringByAppendingString:[NSString stringWithContentsOfFile:@(argv[3]) encoding:NSUTF8StringEncoding error:&error]];
    id<MTLDevice> dev=MTLCreateSystemDefaultDevice();require(dev!=nil,@"No Metal device");
    Ctx ctx={0};ctx.device=dev;ctx.queue=[dev newCommandQueue];Enc *enc=calloc(1,sizeof(Enc));enc->ctx=&ctx;
    MTLCompileOptions *opts=[MTLCompileOptions new];opts.languageVersion=MTLLanguageVersion3_0;
    id<MTLLibrary> lib=[dev newLibraryWithSource:src options:opts error:&error];require(lib!=nil,error.description);
    id<MTLRenderPipelineState> down0=pipeline(dev,lib,@"shade_bloom_down0"),down=pipeline(dev,lib,@"shade_bloom_down"),up=pipeline(dev,lib,@"shade_bloom_up"),old=pipeline(dev,lib,@"shade_bloom_up_reference"),probe=pipeline(dev,lib,@"bloom_probe");
    NSData *lookData=[NSData dataWithContentsOfFile:[out stringByAppendingPathComponent:@"look.bin"]];require(lookData!=nil,@"look fixture missing");
    id<MTLBuffer> look=[dev newBufferWithBytes:lookData.bytes length:lookData.length options:MTLResourceStorageModeShared];
    id<MTLBuffer> gpu=[dev newBufferWithLength:512 options:MTLResourceStorageModeShared];mc_shade_set_m2(&ctx,look,0,gpu);
    NSData *hdr=[NSData dataWithContentsOfFile:[out stringByAppendingPathComponent:@"hdr.bin"]];require(hdr.length==96,@"HDR fixture missing");
    float params[28]={0};memcpy(params,hdr.bytes,96);
    id<MTLComputePipelineState> contract=[dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"halation_contract"] error:&error];require(contract!=nil,error.description);
    id<MTLBuffer> checks=[dev newBufferWithLength:10*16 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb=[ctx.queue commandBuffer];id<MTLComputeCommandEncoder> ce=[cb computeCommandEncoder];
    [ce setComputePipelineState:contract];[ce setBuffer:checks offset:0 atIndex:0];[ce dispatchThreads:MTLSizeMake(5,1,1) threadsPerThreadgroup:MTLSizeMake(5,1,1)];[ce endEncoding];[cb commit];[cb waitUntilCompleted];require(cb.status==MTLCommandBufferStatusCompleted,cb.error.description);
    float *cv=checks.contents;for(int i=0;i<5;i++)for(int c=0;c<3;c++){
        require(fabsf(cv[i*8+4+c])<1e-6,@"halation disabled changed image");
        if(i!=3)require(fabsf(cv[i*8+c])<1e-6,@"halation tinted a core, flat field, dim surface or pure blue light");
    }
    require(cv[24]>cv[25]&&cv[25]>cv[26]&&cv[26]>0,@"fringe is not warm");
    printf("PASS halation contracts: neutral fields/cores/dim surfaces/blue lights unchanged; warm fringe; zero disables\n");
    double worst[2]={0};int cases=0;
    for(int scenario=0;scenario<25;scenario++){@autoreleasepool{
        BOOL preview=scenario==24;int w=preview?960:256+(scenario&1),h=preview?540:170+(scenario&1),n=7;
        float peak=(float[]){.1f,4,64,30000}[scenario%4];
        id<MTLTexture> input=texture(dev,w,h);if(preview)scene(input);else fill(input,scenario,peak);
        id<MTLTexture> levels[7],accum[2][7];int lw=w,lh=h;
        float weight[7],sum=0;
        float spectrum=(float[]){.3f,.6f,.9f}[scenario%3];
        for(int i=0;i<n;i++){lw=MAX(1,(lw+1)/2);lh=MAX(1,(lh+1)/2);levels[i]=texture(dev,lw,lh);for(int k=0;k<2;k++)accum[k][i]=texture(dev,lw,lh);weight[i]=powf(i+1,spectrum);sum+=weight[i];}
        float p[4]={1,1,1,0};id<MTLTexture> inputs[]={input};
        mc_shade_pass(enc,down0,levels[0],0,inputs,1,p,16,"test down0",1);
        for(int i=1;i<n;i++){inputs[0]=levels[i-1];mc_shade_pass(enc,down,levels[i],0,inputs,1,NULL,0,"test down",0);}
        int first=peak==30000&&!preview?1:0;
        for(int k=first;k<2;k++)for(int i=n-1;i>=1;i--){
            p[0]=weight[i]/(k?sum:1);p[1]=i==n-1?0:1;
            id<MTLTexture> ins[]={levels[i],i==n-1?levels[i]:accum[k][i+1]};
            mc_shade_pass(enc,k?up:old,accum[k][i],0,ins,2,p,16,"test up",0);
        }
        id<MTLTexture> outputs[2]={texture(dev,w,h),texture(dev,w,h)};
        for(int display=0;display<2;display++){
            params[27]=display;
            for(int k=first;k<2;k++){
                params[24]=k?1:1/sum;params[25]=weight[0]/(k?sum:1);params[26]=0;
                id<MTLTexture> ins[]={input,accum[k][1],levels[0]};mc_shade_pass(enc,probe,outputs[k],0,ins,3,params,sizeof(params),"test composite",-1);
            }
            finish(enc);size_t bytes=w*h*8;__fp16 *a=malloc(bytes),*b=malloc(bytes);
            if(!first)[outputs[0] getBytes:a bytesPerRow:w*8 fromRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0];
            [outputs[1] getBytes:b bytesPerRow:w*8 fromRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0];
            for(int i=0;i<w*h*4;i++){require(isfinite((float)b[i]),@"nonfinite optimized pyramid");if(!first){require(isfinite((float)a[i]),@"nonfinite reference");worst[display]=fmax(worst[display],fabs((float)b[i]-(float)a[i]));}}
            free(a);free(b);cases++;
        }
        if(preview){
            params[24]=1;params[25]=weight[0]/sum;params[27]=0;
            for(int k=0;k<2;k++){params[26]=k?.08f:0;id<MTLTexture> ins[]={input,accum[1][1],levels[0]};mc_shade_pass(enc,probe,outputs[k],0,ins,3,params,sizeof(params),"halation preview",-1);}
            finish(enc);png(outputs[0],[out stringByAppendingPathComponent:@"bloom.png"]);png(outputs[1],[out stringByAppendingPathComponent:@"halation.png"]);
        }
    }}
    printf("Pyramid %d SDR/HDR cases: 3 spectra, odd/even sizes, moving spots/checkers/waves, peaks 0.1..30000; max display delta SDR %.7f, HDR %.7f\n",cases,worst[0],worst[1]);
    require(worst[0]<=1./255 && worst[1]<=.02,@"bloom optimization exceeds display error budget");
    printf("PASS finite HDR pyramid and bloom output error budget\n");free(enc);
}return 0;}
