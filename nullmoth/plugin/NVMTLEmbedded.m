/*
 * NullMoth NVIDIA driver for macOS
 * Copyright (c) 2026 NullMoth Systems.
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <objc/runtime.h>

#import <os/lock.h>

#define NVMTL_RESID_SAMPLER (1ull << 63)
#define NVMTL_RESID_HEAP    (1ull << 62)

_Static_assert(sizeof(uintptr_t) == sizeof(uint64_t), "resource ID keys require 64-bit pointers");
// An argument buffer owned by a Managed buffer: its texture and sampler handles are read from the CPU copy and the
// embedded slots bound (default), or the slot is refused and cleared to the dummy as it was before the ray-tracing
// batch (NVMTL_EMBEDDED_MANAGED=0). One switch so a run can split the two.
static int nvmtl_embedded_managed_on(void)
{
    static int on = -1;
    if (on < 0) { const char *e = getenv("NVMTL_EMBEDDED_MANAGED"); on = !(e && e[0] == '0');
        if (!on) nvlog("embedded: argument buffers owned by Managed buffers are REFUSED as before (NVMTL_EMBEDDED_MANAGED=0)"); }
    return on;
}
static NSMapTable *nvmtl_resid_map;
static os_unfair_lock nvmtl_resid_lock = OS_UNFAIR_LOCK_INIT;
static uint64_t nvmtl_resid_seq;

static uint64_t nvmtl_resid_assign(id resource, uint64_t tag, uint32_t heapSlot)
{
    if (!resource) return 0;
    os_unfair_lock_lock(&nvmtl_resid_lock);
    if (!nvmtl_resid_map) nvmtl_resid_map = [[NSMapTable alloc]
        initWithKeyOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsIntegerPersonality
        valueOptions:NSPointerFunctionsWeakMemory capacity:0];
    // A token without a slot keeps its low 17 bits zero: the translated shader masks a handle's low word to a heap slot
    // (BINDLESS_HEAP_SLOTS = 131072) with no way to tell the two apart, so a bare sequence number there made a kernel read
    // or write through another texture's slot, or a slot whose storage descriptor nobody had written. Slot 0 is the dummy.
    uint64_t token = heapSlot ? (NVMTL_RESID_HEAP | heapSlot) : (((++nvmtl_resid_seq) << 17) | tag);
    [nvmtl_resid_map setObject:resource forKey:(__bridge id)(void *)(uintptr_t)token];
    uint64_t censusIssued = 0; NSUInteger censusLive = 0; BOOL doCensus = ((nvmtl_resid_seq & 0xFFF) == 0);
    if (doCensus) { censusIssued = nvmtl_resid_seq & ~NVMTL_RESID_SAMPLER; censusLive = nvmtl_resid_map.count; }
    os_unfair_lock_unlock(&nvmtl_resid_lock);
    if (doCensus)
        nvlog("resid census: %llu handles issued, %lu still live in the table",
              (unsigned long long)censusIssued, (unsigned long)censusLive);
    return token;
}

static id nvmtl_resid_lookup(uint64_t token)
{
    if (!token) return nil;
    os_unfair_lock_lock(&nvmtl_resid_lock);
    id resource = [nvmtl_resid_map objectForKey:(__bridge id)(void *)(uintptr_t)token];
    os_unfair_lock_unlock(&nvmtl_resid_lock);
    return resource;
}

// The same slot carries the storage descriptor (heap binding 2) for a texture a kernel may write - a shader reaches a
// written texture only through this handle in memory.
// A texture that gets no slot is read by a shader as slot 0, the dummy (nvmtl_resid_assign): its reads come back black
// and its writes are lost. The first 8 are logged verbatim with the reason, then a census every 256, so a run shows
// the population instead of guessing it.
static void nvmtl_resid_no_slot(NVMTLTexture *x, const char *why)
{
    static _Atomic unsigned long long n; const unsigned long long k = atomic_fetch_add(&n, 1) + 1;
    if (k <= 8) nvlog("resid: NO SLOT #%llu for texture %p %ux%u type %lu pixelFormat %lu usage 0x%lx storage %lu mips %u stex %d - %s",
                     k, (__bridge void *)x, x->_i.w, x->_i.h, (unsigned long)x.textureType, (unsigned long)x->_fmt, (unsigned long)x->_usage,
                     (unsigned long)x.storageMode, x->_i.mips, x->_stex ? 1 : 0, why);
    else if ((k & 255) == 0) nvlog("resid: NO SLOT census - %llu textures so far read as the dummy (last: %s)", k, why);
}
uint64_t nvmtl_resid_for_texture(id t)
{
    NVMTLTexture *x = (NVMTLTexture *)t;
    // a texture buffer has no image view: its slot holds the buffer view in the texel bindings instead
    if (x->_tbView) {
        const uint32_t ts = nvmtl_vk_bindless_put_texel(x->_tbView, x->_tbStorage);
        if (!ts) nvmtl_resid_no_slot(x, "texture buffer: the heap has no texel bindings (NVMTL_NO_HEAP_STORAGE) or no buffer view");
        return nvmtl_resid_assign(t, 0, ts);
    }
    void *sample = [x nvsampleview];
    const uint32_t slot = nvmtl_vk_bindless_put(sample);
    if (slot) nvmtl_vk_bindless_put_storage(slot, x->_stex ? [x nvview] : NULL);
    else nvmtl_resid_no_slot(x, sample ? "heap full, or no heap in this process" : "the image has no sample view");
    return nvmtl_resid_assign(t, 0, slot);
}
// A sampler's gpuResourceID carries its bindless heap slot in the low 32 bits (what a shader reading an argument buffer
// indexes the sampler heap with) and a sequence number above them, so every sampler object keeps a unique token.
uint64_t nvmtl_resid_for_sampler(id s)
{
    const uint32_t slot = nvmtl_vk_bindless_sampler_slot(((NVMTLSamplerState *)s)->_s.s);
    if (!slot) return nvmtl_resid_assign(s, NVMTL_RESID_SAMPLER, 0);
    os_unfair_lock_lock(&nvmtl_resid_lock);
    if (!nvmtl_resid_map) nvmtl_resid_map = [[NSMapTable alloc]
        initWithKeyOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsIntegerPersonality
        valueOptions:NSPointerFunctionsWeakMemory capacity:0];
    const uint64_t token = NVMTL_RESID_SAMPLER | ((++nvmtl_resid_seq & 0x3fffffffull) << 32) | slot;
    [nvmtl_resid_map setObject:s forKey:(__bridge id)(void *)(uintptr_t)token];
    os_unfair_lock_unlock(&nvmtl_resid_lock);
    return token;
}
void nvmtl_resid_texture_gone(uint64_t token) { if (token & NVMTL_RESID_HEAP) nvmtl_vk_bindless_drop((uint32_t)(token & 0xffffffffu)); }

static NSUInteger nvmtl_ss_enum(NSDictionary *st, NSString *key, NSDictionary<NSString *, NSNumber *> *map, NSUInteger fallback, BOOL *bad)
{
    id v = st[key];
    if (![v isKindOfClass:[NSString class]]) return fallback;
    NSNumber *n = map[v];
    if (!n) { *bad = YES; nvlog("static sampler: %s = %s has no Metal equivalent here", key.UTF8String, [v UTF8String]); return fallback; }
    return n.unsignedIntegerValue;
}
static id<MTLSamplerState> nvmtl_static_sampler_from(NSDictionary *st)
{
    NSDictionary *filt = @{ @"Nearest": @(MTLSamplerMinMagFilterNearest), @"Linear": @(MTLSamplerMinMagFilterLinear) };
    NSDictionary *mip = @{ @"None": @(MTLSamplerMipFilterNotMipmapped), @"Nearest": @(MTLSamplerMipFilterNearest),
                           @"Linear": @(MTLSamplerMipFilterLinear) };
    NSDictionary *addr = @{ @"ClampToEdge": @(MTLSamplerAddressModeClampToEdge), @"Repeat": @(MTLSamplerAddressModeRepeat),
                            @"MirroredRepeat": @(MTLSamplerAddressModeMirrorRepeat), @"MirrorRepeat": @(MTLSamplerAddressModeMirrorRepeat), @"ClampToZero": @(MTLSamplerAddressModeClampToZero),
                            @"ClampToBorder": @(MTLSamplerAddressModeClampToBorderColor),
                            @"MirrorClampToEdge": @(MTLSamplerAddressModeMirrorClampToEdge) };
    NSDictionary *cmp = @{ @"Never": @(MTLCompareFunctionNever), @"Less": @(MTLCompareFunctionLess), @"Equal": @(MTLCompareFunctionEqual),
                           @"LessEqual": @(MTLCompareFunctionLessEqual), @"Greater": @(MTLCompareFunctionGreater),
                           @"NotEqual": @(MTLCompareFunctionNotEqual), @"GreaterEqual": @(MTLCompareFunctionGreaterEqual),
                           @"Always": @(MTLCompareFunctionAlways), @"None": @(MTLCompareFunctionNever) };
    NSDictionary *border = @{ @"TransparentBlack": @(MTLSamplerBorderColorTransparentBlack), @"OpaqueBlack": @(MTLSamplerBorderColorOpaqueBlack),
                              @"OpaqueWhite": @(MTLSamplerBorderColorOpaqueWhite) };
    BOOL bad = NO;
    MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
    d.minFilter = (MTLSamplerMinMagFilter)nvmtl_ss_enum(st, @"min_filter", filt, MTLSamplerMinMagFilterNearest, &bad);
    d.magFilter = (MTLSamplerMinMagFilter)nvmtl_ss_enum(st, @"mag_filter", filt, MTLSamplerMinMagFilterNearest, &bad);
    d.mipFilter = (MTLSamplerMipFilter)nvmtl_ss_enum(st, @"mip_filter", mip, MTLSamplerMipFilterNotMipmapped, &bad);
    d.sAddressMode = (MTLSamplerAddressMode)nvmtl_ss_enum(st, @"address_mode_s", addr, MTLSamplerAddressModeClampToEdge, &bad);
    d.tAddressMode = (MTLSamplerAddressMode)nvmtl_ss_enum(st, @"address_mode_t", addr, MTLSamplerAddressModeClampToEdge, &bad);
    d.rAddressMode = (MTLSamplerAddressMode)nvmtl_ss_enum(st, @"address_mode_r", addr, MTLSamplerAddressModeClampToEdge, &bad);
    d.compareFunction = (MTLCompareFunction)nvmtl_ss_enum(st, @"compare_function", cmp, MTLCompareFunctionNever, &bad);
    d.borderColor = (MTLSamplerBorderColor)nvmtl_ss_enum(st, @"border_color", border, MTLSamplerBorderColorTransparentBlack, &bad);
    d.normalizedCoordinates = ![st[@"coordinates"] isEqual:@"Pixel"];
    NSNumber *an = st[@"max_anisotropy"], *lo = st[@"lod_min_clamp"], *hi = st[@"lod_max_clamp"];
    if ([an isKindOfClass:[NSNumber class]]) d.maxAnisotropy = MAX(1u, an.unsignedIntegerValue);
    if ([lo isKindOfClass:[NSNumber class]]) d.lodMinClamp = lo.floatValue;
    if ([hi isKindOfClass:[NSNumber class]]) d.lodMaxClamp = hi.floatValue;
    if (bad) return nil;
    // this plugin's device, never the system default: with the iGPU enabled that can be Apple's Intel driver, whose
    // sampler is not an NVMTLSamplerState (a tool without CoreGraphics gets the iGPU as its default device)
    return [(id<MTLDevice>)gNVMTLMainDevice newSamplerStateWithDescriptor:d];
}
static const void *NVMTL_SSAMP_KEY = &NVMTL_SSAMP_KEY;
static NSArray<NSArray *> *nvmtl_static_samplers(NVMTLFunction *fn)
{
    NSArray *cached = objc_getAssociatedObject(fn, NVMTL_SSAMP_KEY);
    if (cached) return cached;
    NSMutableArray *out = [NSMutableArray new];
    @synchronized (fn) {
        cached = objc_getAssociatedObject(fn, NVMTL_SSAMP_KEY);
        if (cached) return cached;
        char e[512] = { 0 };
        NSData *d = (fn->_air && fn->_stage.length && nvmtl_xlate_ready() && xlate_refl)
                  ? nvmtl_reflect_air_cached(fn, fn->_air, fn->_stage, e, sizeof e) : nil;
        NSDictionary *refl = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
        NSArray *all = [refl isKindOfClass:[NSDictionary class]] ? refl[@"bindings"] : nil;
        for (NSDictionary *b in [all isKindOfClass:[NSArray class]] ? all : @[]) {
            if (![b isKindOfClass:[NSDictionary class]] || ![b[@"kind"] isEqual:@"StaticSampler"]) continue;
            NSNumber *slot = b[@"metal_index"]; NSDictionary *st = b[@"static_sampler"];
            if (![slot isKindOfClass:[NSNumber class]] || ![st isKindOfClass:[NSDictionary class]]) continue;
            id<MTLSamplerState> s = nvmtl_static_sampler_from(st);
            if (s) [out addObject:@[slot, s]];
            else nvlog("static sampler: %s slot %@ NOT created - it keeps the dummy sampler", fn->_fname.UTF8String, slot);
        }
        if (out.count) nvlog("static sampler: %s binds %lu constexpr sampler(s) with their own state", fn->_fname.UTF8String, (unsigned long)out.count);
        objc_setAssociatedObject(fn, NVMTL_SSAMP_KEY, out, OBJC_ASSOCIATION_RETAIN);
    }
    return out;
}
static int nvmtl_static_samplers_on(void)
{
    static int on = -1;
    if (on < 0) { on = !getenv("NVMTL_NO_STATIC_SAMPLERS");
        nvlog("static sampler: constexpr samplers %s (NVMTL_NO_STATIC_SAMPLERS=%s)", on ? "bind their own state" : "keep the dummy sampler (OLD)",
              getenv("NVMTL_NO_STATIC_SAMPLERS") ?: "unset"); }
    return on;
}

@interface NVMTLEmbeddedPlan : NSObject {
@public
    BOOL wantSampler, storage;
    uint32_t slot;
    NSUInteger ownerIndex, fieldOffset;
    uint32_t dset, dbinding;
    NSString *bindingText;
}
@end
@implementation NVMTLEmbeddedPlan
@end
static char nvmtl_embedded_plan_key;
static BOOL nvmtl_spirv_declared(NSData *spv, uint64_t decl[2][8])
{
    memset(decl, 0, 2 * 8 * sizeof(uint64_t));
    const uint32_t *w = (const uint32_t *)spv.bytes; size_t n = spv.length / 4;
    if (!w || n < 5 || w[0] != 0x07230203u) return NO;
    uint32_t bound = w[3]; if (!bound || bound > (1u << 22)) return NO;
    int32_t *set = (int32_t *)malloc(bound * sizeof *set), *bind = (int32_t *)malloc(bound * sizeof *bind);
    if (!set || !bind) { free(set); free(bind); return NO; }
    for (uint32_t k = 0; k < bound; k++) { set[k] = -1; bind[k] = -1; }
    for (size_t i = 5; i < n; ) {
        uint32_t wc = w[i] >> 16, op = w[i] & 0xffffu;
        if (!wc || i + wc > n) { free(set); free(bind); return NO; }
        if (op == 71 && wc >= 4 && w[i + 1] < bound) {
            if (w[i + 2] == 34) set[w[i + 1]] = (int32_t)w[i + 3]; else if (w[i + 2] == 33) bind[w[i + 1]] = (int32_t)w[i + 3];
        }
        i += wc;
    }
    for (uint32_t k = 0; k < bound; k++)
        if ((set[k] == 0 || set[k] == 1) && bind[k] >= 0 && bind[k] < 512) decl[set[k]][bind[k] >> 6] |= 1ull << (bind[k] & 63);
    free(set); free(bind); return YES;
}
static NSArray<NVMTLEmbeddedPlan *> *nvmtl_embedded_plan(NVMTLFunction *fn) {
    NSArray *cached = objc_getAssociatedObject(fn, &nvmtl_embedded_plan_key);
    if (cached) return cached;
    @synchronized(fn) {
        cached = objc_getAssociatedObject(fn, &nvmtl_embedded_plan_key);
        if (cached) return cached;
        NSMutableArray *plans = [NSMutableArray new];
        uint64_t decl[2][8]; const BOOL haveDecl = nvmtl_spirv_declared(fn->_spirv, decl); unsigned heapRouted = 0;
        for (NSDictionary *entry in nvmtl_embedded_bindings(fn)) {
            NSDictionary *src = entry[@"embedded_source"];
            NSNumber *slotNum = entry[@"metal_index"];
            if (![src isKindOfClass:[NSDictionary class]] || !slotNum) continue;
            NVMTLEmbeddedPlan *plan = [NVMTLEmbeddedPlan new];
            plan->wantSampler = [entry[@"kind"] isEqualToString:@"EmbeddedArgBufferSampler"];
            plan->storage = [entry[@"access"] isKindOfClass:[NSString class]] && [entry[@"access"] isEqualToString:@"Storage"];
            plan->slot = (uint32_t)slotNum.unsignedLongValue;
            plan->ownerIndex = [src[@"buffer_index"] unsignedLongValue];
            plan->fieldOffset = [src[@"field_offset"] unsignedLongValue];
            id binding = entry[@"descriptor"][@"binding"];
            plan->bindingText = binding ? [[binding description] copy] : @"(absent)";
            { id ds = entry[@"descriptor"][@"set"];
              plan->dset = [ds respondsToSelector:@selector(unsignedIntValue)] ? [ds unsignedIntValue] : 0;
              plan->dbinding = [binding respondsToSelector:@selector(unsignedIntValue)] ? [binding unsignedIntValue] : UINT32_MAX; }
            if (haveDecl && !plan->wantSampler && plan->dset < 2 && plan->dbinding < 512 &&
                !((decl[plan->dset][plan->dbinding >> 6] >> (plan->dbinding & 63)) & 1)) { heapRouted++; continue; }
            [plans addObject:plan];
        }
        { static _Atomic unsigned said; if (heapRouted && atomic_fetch_add(&said, 1) < 8)
            nvlog("tier2: %s reads %u argument-buffer texture(s) through the bindless heap; %lu field(s) still bound per draw",
                  fn->_fname.UTF8String, heapRouted, (unsigned long)plans.count); }
        cached = [plans copy];
        objc_setAssociatedObject(fn, &nvmtl_embedded_plan_key, cached, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return cached;
    }
}

static BOOL nvmtl_embedded_info_due(_Atomic uint64_t *counter) {
    uint64_t n = atomic_fetch_add_explicit(counter, 1, memory_order_relaxed) + 1;
    return n <= 8 || (n && !(n & (n - 1)));
}
static _Atomic uint64_t nvmtl_embedded_empty_count, nvmtl_embedded_bound_count;
static void nvmtl_clear_embedded_slot(NVMTLCommandBuffer *cb, uint32_t set, uint32_t slot, BOOL sampler) {
    if (sampler) nvmtl_vk_bind_sampler(&cb->_c, set, slot, NULL);
    else {
        nvmtl_vk_bind_texture_view(&cb->_c, set, slot, NULL);
        nvmtl_vk_bind_storage_view(&cb->_c, set, slot, NULL);
    }
}
// Diagnostic (2026-10-28, Dock icons point-sampled in WindowServer): while /tmp/nvmtl-static-linear exists, a constexpr
// sampler with a nearest min or mag filter is bound as its linear twin (same mip filter, addressing and LOD clamp). A
// texture the draw samples through such a sampler then filters; one it samples through the app's sampler is unchanged.
// /tmp/nvmtl-static-linear-<n> (n 0-7) does it for sampler slot n only. Returns a mask of the slots (all: 0xff).
static unsigned nvmtl_static_linear_on(void)
{
    static uint64_t next; static unsigned on;
    const uint64_t now = nvmtl_poll_ns();
    if (now >= next) { next = now + 250000000ull; const unsigned was = on;
        on = nvmtl_diag_flag("static-linear") ? 0xffu : 0u;
        static const char *const kSlot[8] = { "static-linear-0", "static-linear-1", "static-linear-2", "static-linear-3", "static-linear-4", "static-linear-5", "static-linear-6", "static-linear-7" };
        for (unsigned k = 0; k < 8 && !on; k++) if (nvmtl_diag_flag(kSlot[k])) on |= 1u << k;
        if (on != was) nvlog("static sampler: nearest constexpr samplers bound LINEAR in slots 0x%x (/tmp/nvmtl-static-linear[-n]; 0 = as declared)", on); }
    return on;
}
static const void *NVMTL_SSAMP_LINEAR_KEY = &NVMTL_SSAMP_LINEAR_KEY;
static NVMTLSamplerState *nvmtl_static_linear_twin(NVMTLSamplerState *s)
{
    if (s->_s.desc.min_filter && s->_s.desc.mag_filter) return s;
    NVMTLSamplerState *t = objc_getAssociatedObject(s, NVMTL_SSAMP_LINEAR_KEY);
    if (t) return t;
    MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
    d.minFilter = d.magFilter = MTLSamplerMinMagFilterLinear; d.mipFilter = (MTLSamplerMipFilter)s->_s.desc.mip_filter;
    d.sAddressMode = (MTLSamplerAddressMode)s->_s.desc.address_s; d.tAddressMode = (MTLSamplerAddressMode)s->_s.desc.address_t;
    d.rAddressMode = (MTLSamplerAddressMode)s->_s.desc.address_r; d.borderColor = (MTLSamplerBorderColor)s->_s.desc.border_color;
    d.lodMinClamp = s->_s.desc.lod_min; d.lodMaxClamp = s->_s.desc.lod_max;
    t = (NVMTLSamplerState *)[(id<MTLDevice>)gNVMTLMainDevice newSamplerStateWithDescriptor:d];   // not the system default (iGPU)
    if (!t) return s;
    objc_setAssociatedObject(s, NVMTL_SSAMP_LINEAR_KEY, t, OBJC_ASSOCIATION_RETAIN);
    return t;
}
/* A function's constexpr samplers, the sampler slots they take, and its embedded argument-buffer plan: built once (they
   depend only on the function), then read by every draw without the associated-object lookups and the NSArray walk that
   were half of a draw's CPU time with no bindings changing (mtl_bind none, 2026-10-29). */
static void nvmtl_fn_bindinfo(__unsafe_unretained NVMTLFunction *fn)
{
    if (__atomic_load_n(&fn->_bindReady, __ATOMIC_ACQUIRE)) return;
    NSArray *ss = nvmtl_static_samplers_on() ? nvmtl_static_samplers(fn) : @[];
    NSArray *emb = nvmtl_embedded_plan(fn) ?: @[];
    uint16_t took = 0;
    for (NSArray *pair in ss) { const unsigned slot = [pair[0] unsignedIntValue]; if (slot < 16) took |= (uint16_t)(1u << slot); }
    @synchronized (fn) {
        if (!__atomic_load_n(&fn->_bindReady, __ATOMIC_RELAXED)) {
            fn->_bindSS = ss; fn->_bindEmb = emb; fn->_bindTook = took;
            __atomic_store_n(&fn->_bindReady, 1, __ATOMIC_RELEASE);
        }
    }
}
void nvmtl_bind_embedded(__unsafe_unretained NVMTLCommandBuffer *cb, uint32_t set, __unsafe_unretained NVMTLFunction *fn, NVMTLBuffer *__unsafe_unretained const *bufAt, const NSUInteger *offAt)
{
    if (!cb) return;
    // fn keeps both arrays for its lifetime and outlives this call (the bound pipeline holds it)
    __unsafe_unretained NSArray *staticSS = nil, *embeddedPlan = nil;
    if (fn) { nvmtl_fn_bindinfo(fn); staticSS = fn->_bindSS; embeddedPlan = fn->_bindEmb; }
    /* Constexpr samplers go into the slots the translator gives them, which are app sampler slots the pipeline does not
       use. The next pipeline may use that slot for the app's sampler, and the app does not bind it again (Metal state
       stays until changed): it sampled with the constexpr state. CoreAnimation's fixed_frag variants put a nearest
       constexpr sampler at slot 0 when they draw no image there, and the next Dock icon or glyph draw that samples through
       CA's own slot-0 sampler (linear, mip nearest, aniso 8) point-sampled - 39 of 155 icon draws of a Dock relaunch,
       2026-10-28. A slot a constexpr sampler took and this pipeline does not is given back to the app's sampler. */
    const uint16_t took = fn ? fn->_bindTook : 0;
    if (set <= 1 && (cb->_staticSamp[set] | took)) {
        const uint16_t back = cb->_staticSamp[set] & (uint16_t)~took;
        for (unsigned k = 0; k < 16; k++) if ((back >> k) & 1u) {
            __unsafe_unretained NVMTLSamplerState *a = cb->_appSamp[set][k];
            if (nvmtl_vk_bind_sampler(&cb->_c, set, k, a ? &a->_s : NULL)) nvlog("static sampler slot %u: giving it back to the app's sampler FAILED", k);
        }
        cb->_staticSamp[set] = took;
    }
    if (!fn) return;
    if (staticSS.count) {
        for (NSArray *pair in staticSS) {
            NVMTLSamplerState *s = pair[1];
            { const unsigned lin = nvmtl_static_linear_on(), slot = [pair[0] unsignedIntValue];
              if (slot < 8 && ((lin >> slot) & 1u)) s = nvmtl_static_linear_twin(s); }
            nvmtl_retain_resource(cb, s);
            if (nvmtl_vk_bind_sampler(&cb->_c, set, [pair[0] unsignedIntValue], &s->_s))
                nvlog("static sampler slot %@: bind FAILED", pair[0]);
            nvtrace("STATIC SAMPLER[%u] of %s | min %u mag %u mip %u lod %g..%g", [pair[0] unsignedIntValue], fn->_fname.UTF8String ?: "?",
                    s->_s.desc.min_filter, s->_s.desc.mag_filter, s->_s.desc.mip_filter, s->_s.desc.lod_min, s->_s.desc.lod_max);
        }
    }
    if (!embeddedPlan.count) return;
    NSArray<NVMTLEmbeddedPlan *> *embedded = embeddedPlan;
    extern int nvmtl_vk_emb_same(nvk_cmdbuf *, uint32_t, const void *, const uint64_t *, uint32_t);
    extern void nvmtl_vk_emb_note(nvk_cmdbuf *, uint32_t, const void *, const uint64_t *, uint32_t);
    uint64_t embKey[480]; uint32_t embN = 0; BOOL embKeyed = embedded.count * 3 <= 480, embSurf = NO;
    if (embKeyed) {
        for (NVMTLEmbeddedPlan *plan in embedded) {
            NVMTLBuffer *owner = plan->ownerIndex < NVMTL_NBUFAT ? bufAt[plan->ownerIndex] : nil;
            if (!owner) { embKeyed = NO; break; }
            NSUInteger base = offAt[plan->ownerIndex]; size_t msize = owner->_b.size;
            // nvmtl_buf_cpu, not _b.map: a Managed buffer keeps its CPU copy in _shadow and _b.map is
            // null there, so reading the raw map refused every slot such a buffer owns. It also
            // settles the buffer first. NVMTL_EMBEDDED_MANAGED=0 restores the old refusal (a split switch).
            const uint8_t *ocpu = (const uint8_t *)(nvmtl_embedded_managed_on() ? nvmtl_buf_cpu(owner) : owner->_b.map);
            if (!ocpu || base > msize || plan->fieldOffset > msize - base || sizeof(uint64_t) > msize - base - plan->fieldOffset) { embKeyed = NO; break; }
            uint64_t h = 0; memcpy(&h, ocpu + base + plan->fieldOffset, sizeof h);
            embKey[embN++] = (uint64_t)(uintptr_t)(__bridge void *)owner; embKey[embN++] = base; embKey[embN++] = h;
        }
        if (embKeyed && nvmtl_vk_emb_same(&cb->_c, set, (__bridge void *)fn, embKey, embN)) return;
    }

    for (NVMTLEmbeddedPlan *plan in embedded) {
        BOOL wantSampler = plan->wantSampler;
        const char *what = wantSampler ? "sampler" : "texture";
        uint32_t slot = plan->slot;
        NSUInteger ownerIndex = plan->ownerIndex;
        NSUInteger fieldOffset = plan->fieldOffset;

        NVMTLBuffer *owner = ownerIndex < NVMTL_NBUFAT ? bufAt[ownerIndex] : nil;
        if (!owner) {
            nvlog("embedded %s slot %u: buffer(%lu) is not bound on this encoder — NOT BOUND",
                  what, slot, (unsigned long)ownerIndex);
            nvmtl_clear_embedded_slot(cb, set, slot, wantSampler); continue;
        }
        NSUInteger base = offAt[ownerIndex];
        size_t msize = owner->_b.size;
        // See above: a Managed buffer's CPU copy lives in _shadow, so _b.map is null and the slot was
        // refused although the handle was readable.
        const uint8_t *ocpu = (const uint8_t *)(nvmtl_embedded_managed_on() ? nvmtl_buf_cpu(owner) : owner->_b.map);
        if (!ocpu || base > msize || fieldOffset > msize - base ||
            sizeof(uint64_t) > msize - base - fieldOffset) {
            nvlog("embedded %s slot %u: buffer(%lu) offset %lu+%lu does not fit its %zu-byte mapping — REFUSED",
                  what, slot, (unsigned long)ownerIndex, (unsigned long)base,
                  (unsigned long)fieldOffset, owner->_b.size);
            nvmtl_clear_embedded_slot(cb, set, slot, wantSampler); continue;
        }
        uint64_t handle = 0;
        memcpy(&handle, ocpu + base + fieldOffset, sizeof handle);
        if (!handle) {
            if (nvmtl_embedded_info_due(&nvmtl_embedded_empty_count))
                nvlog("embedded %s slot %u: buffer(%lu)+%lu holds a zero handle — binding cleared",
                      what, slot, (unsigned long)ownerIndex, (unsigned long)fieldOffset);
            nvmtl_clear_embedded_slot(cb, set, slot, wantSampler); continue;
        }
        id resource = nvmtl_resid_lookup(handle);
        if (!resource) {
            nvlog("embedded %s slot %u: handle 0x%llx resolves to nothing — released, or never ours; REFUSED",
                  what, slot, (unsigned long long)handle);
            nvmtl_clear_embedded_slot(cb, set, slot, wantSampler); continue;
        }
        if (wantSampler != ((handle & NVMTL_RESID_SAMPLER) != 0)) {
            nvlog("embedded slot %u: the field wants a %s but handle 0x%llx is the other kind — REFUSED",
                  slot, what, (unsigned long long)handle);
            nvmtl_clear_embedded_slot(cb, set, slot, wantSampler); continue;
        }
        if (nvmtl_embedded_info_due(&nvmtl_embedded_bound_count)) {
            const char *bindStr = plan->bindingText.UTF8String;
            nvlog("embedded %s slot %u -> module binding %s (buffer(%lu)+%lu, handle 0x%llx) BOUND",
                  what, slot, bindStr,
                  (unsigned long)ownerIndex, (unsigned long)fieldOffset, (unsigned long long)handle);
        }
        if (wantSampler) {
            NVMTLSamplerState *s = resource;
            nvmtl_retain_resource(cb, s);
            if (nvmtl_vk_bind_sampler(&cb->_c, set, slot, &s->_s))
                nvlog("embedded sampler slot %u: bind FAILED", slot);
        } else {
            NVMTLTexture *t = resource;
            nvmtl_retain_resource(cb, t);
            nvmtl_surface_in_for_cb(cb, t);
            { NVMTLTexture *sr = t->_parent ? t->_parent : t; if (sr->_surf) embSurf = YES; }
            if (nvmtl_vk_bind_texture_view(&cb->_c, set, slot, [t nvsampleview]))
                nvlog("embedded texture slot %u: bind FAILED", slot);
            void *sv = nvmtl_storage_view_for(cb, t, plan->storage);
            if (sv && !t->_stex) embSurf = YES;   // a twin is copied in and out per encoder: never skip this binding
            nvmtl_vk_bind_storage_view(&cb->_c, set, slot, sv);
        }
    }
    nvmtl_vk_emb_note(&cb->_c, set, (embKeyed && !embSurf) ? (__bridge void *)fn : NULL, embKey, embN);
}
// the compute encoder keeps its bindings as index -> (buffer, offset, ...) arrays; the tables are built only for a
// kernel that has embedded arguments
void nvmtl_bind_embedded_enc(NVMTLCommandBuffer *cb, uint32_t set, NVMTLFunction *fn, NVMTLComputeCommandEncoder *e)
{
    __unsafe_unretained NVMTLBuffer *bufs[NVMTL_NBUFAT] = { nil }; NSUInteger offs[NVMTL_NBUFAT] = { 0 };   // held by the encoder's table
    if (e && fn && nvmtl_embedded_plan(fn).count)
        for (NSUInteger i = 0; i < NVMTL_NBUFAT; i++)
            if (e->_baN[i] && e->_baObj[i]) { bufs[i] = e->_baObj[i]; offs[i] = e->_baOff[i]; }
    nvmtl_bind_embedded(cb, set, fn, bufs, offs);
}
