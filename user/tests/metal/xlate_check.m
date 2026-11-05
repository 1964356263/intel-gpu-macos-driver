// SPDX-License-Identifier: MIT
// xlate_check: the plugin's shader path without a B580. Compiles mtl_smoke's kernel source with whatever Metal device
// this machine has (Apple's front end makes the AIR), takes the library's metallib container and hands it to the
// built plugin's nvmtl_translate_metallib (the function -[NVMTLDevice newLibraryWithData:] calls): metallib -> AIR ->
// LLVM text (air-runtime/libLLVM.dylib) -> SPIR-V (libnvmtl_translate.dylib). Runs on any Mac (x86_64; Rosetta is fine).
//
//   NVMTL_LOG_PATH=<log> NVMTL_AIRCACHE=<dir> ./xlate_check <path to NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver> [out.spv]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <stdio.h>

static NSString *const kSource =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "kernel void fill(device uint *out [[buffer(0)]], constant uint &k [[buffer(1)]],\n"
     "                 uint gid [[thread_position_in_grid]]) {\n"
     "    out[gid] = gid * 3u + k;\n"
     "}\n";

typedef NSDictionary<NSString *, NSData *> *(*translate_fn)(NSData *, NSDictionary **, NSDictionary **);

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: %s NVMTLDriver [out.spv]\n", argv[0]); return 2; }
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { fprintf(stderr, "no Metal device to run the front end\n"); return 1; }
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:kSource options:[MTLCompileOptions new] error:&err];
        if (!lib) { fprintf(stderr, "front end: %s\n", err.localizedDescription.UTF8String); return 1; }
        SEL s = sel_registerName("libraryDataContents");
        if (![lib respondsToSelector:s]) { fprintf(stderr, "%s has no libraryDataContents\n", object_getClassName(lib)); return 1; }
        NSData *mtlb = ((id (*)(id, SEL))objc_msgSend)(lib, s);
        printf("front end on %s: metallib %lu bytes (magic %.4s)\n", dev.name.UTF8String, (unsigned long)mtlb.length,
               (const char *)mtlb.bytes);

        void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
        translate_fn tr = (translate_fn)dlsym(h, "nvmtl_translate_metallib");
        if (!tr) { fprintf(stderr, "no nvmtl_translate_metallib in %s\n", argv[1]); return 1; }
        NSDictionary *stages = nil, *airs = nil;
        NSDictionary<NSString *, NSData *> *fns = tr(mtlb, &stages, &airs);
        if (!fns.count) { fprintf(stderr, "FAIL: translation produced nothing (see NVMTL_LOG_PATH)\n"); return 3; }
        int bad = 0;
        for (NSString *name in fns) {
            NSData *spv = fns[name];
            const uint32_t magic = spv.length >= 4 ? *(const uint32_t *)spv.bytes : 0;
            printf("  %-12s stage %-8s SPIR-V %5lu bytes magic 0x%08x%s\n", name.UTF8String,
                   [stages[name] description].UTF8String ?: "?", (unsigned long)spv.length, magic,
                   magic == 0x07230203u ? "" : "  <- NOT SPIR-V");
            if (magic != 0x07230203u) bad = 1;
            if (argc > 2 && [name isEqualToString:@"fill"]) [spv writeToFile:@(argv[2]) atomically:YES];
        }
        printf("%s\n", bad ? "FAIL" : "PASS");
        return bad ? 4 : 0;
    }
}
