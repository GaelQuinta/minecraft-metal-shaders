// Copyright 2026 mcopt-shade contributors. Apache-2.0.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
static void require(BOOL ok, NSString *why) { if(!ok) { fprintf(stderr,"%s\n",why.UTF8String); exit(1); } }
int main(int argc,const char **argv) { @autoreleasepool {
    require(argc==3,@"usage: check fixture-dir probe.metal");
    NSString *dir=@(argv[1]); NSError *error=nil;
    id<MTLDevice> dev=MTLCreateSystemDefaultDevice(); require(dev!=nil,@"No Metal device (run with GPU access)");
    NSString *src=[NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"post.metal"] encoding:NSUTF8StringEncoding error:&error];
    src=[src stringByAppendingString:[NSString stringWithContentsOfFile:@(argv[2]) encoding:NSUTF8StringEncoding error:&error]];
    MTLCompileOptions *opts=[MTLCompileOptions new]; opts.languageVersion=MTLLanguageVersion3_0;
    id<MTLLibrary> lib=[dev newLibraryWithSource:src options:opts error:&error]; require(lib!=nil,error.description);
    id<MTLComputePipelineState> pipe=[dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"sunset_probe"] error:&error]; require(pipe!=nil,error.description);
    id<MTLCommandQueue> queue=[dev newCommandQueue];
    enum {COUNT=46*91, FRAME=1024};
    id<MTLBuffer> out=[dev newBufferWithLength:COUNT*96 options:MTLResourceStorageModeShared];
    NSString *names=[NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"names.txt"] encoding:NSUTF8StringEncoding error:&error];
    for(NSString *name in [names componentsSeparatedByString:@"\n"]) {
        if(!name.length) continue;
        NSData *u=[NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:[name stringByAppendingString:@".bin"]]];
        NSUInteger LOOK=u.length-FRAME-96; require(LOOK==1088 || LOOK==1120,@"Uniform size mismatch"); const char *bytes=u.bytes;
        id<MTLCommandBuffer> cb=[queue commandBuffer]; id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder];
        [e setComputePipelineState:pipe]; [e setBuffer:out offset:0 atIndex:0];
        [e setBytes:bytes+FRAME+LOOK length:96 atIndex:1]; [e setBytes:bytes length:FRAME atIndex:16]; [e setBytes:bytes+FRAME length:LOOK atIndex:17];
        [e dispatchThreads:MTLSizeMake(COUNT,1,1) threadsPerThreadgroup:MTLSizeMake(64,1,1)]; [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
        require(cb.status==MTLCommandBufferStatusCompleted,cb.error.description);
        require([[NSData dataWithBytes:out.contents length:out.length] writeToFile:[dir stringByAppendingPathComponent:[name stringByAppendingString:@".gpu"]] atomically:YES],@"Write failed");
    }
    printf("Rendered production atmosphere, SDR/HDR and neutral surfaces on %s\n",dev.name.UTF8String);
} return 0; }
