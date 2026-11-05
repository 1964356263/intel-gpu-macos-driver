/*
 * NullMoth NVIDIA driver for macOS
 * Copyright (c) 2026 NullMoth Systems.
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once
#include "IOAccelResource2.h"
#include "IOAccelSysMemory.h"
#include "IOAccelVidMemory.h"
#include "IOAccelLegacySurface.h"
#include "IOAccelLegacyDisplayPipe.h"
#include "IOAccelGLContext2.h"
#include "IOAccel2DContext2.h"
#include "IOAccelCLContext2.h"
#include "IOAccelVideoContext2.h"
class NVResource : public IOAccelResource2 {
    OSDeclareDefaultStructors(NVResource)
    NM_TAHOE_FWD(NVResource)
public:
    unsigned int fPbLogged = 0;
    void rebuildPagingBuffer() APPLE_KEXT_OVERRIDE { if (fPbLogged < 4) { fPbLogged++; ALOG("NVResource::rebuildPagingBuffer -- nothing to rebuild until there are page tables (rung 5)"); } }
    uint64_t getLevelOffset(unsigned char a0, unsigned char a1, int* a2) APPLE_KEXT_OVERRIDE {
        const unsigned char *r = (const unsigned char *)this;
        if (a2) {
            unsigned long long pitch = *(const volatile unsigned long long *)(r + 0xb8);
            unsigned base = r[0xae];
            *a2 = (int)(pitch >> ((a1 >= base) ? (unsigned)(a1 - base) : 0u));
        }
        return (unsigned long long)a0 * *(const volatile unsigned long long *)(r + 0xd0);
    }
    uint64_t getBackingLevelOffset(unsigned char a0, unsigned char a1, int* a2) APPLE_KEXT_OVERRIDE {
        const unsigned char *r = (const unsigned char *)this;
        if (a2) {
            unsigned long long pitch = *(const volatile unsigned long long *)(r + 0xc0);
            unsigned base = r[0xae];
            *a2 = (int)(pitch >> ((a1 >= base) ? (unsigned)(a1 - base) : 0u));
        }
        return (unsigned long long)a0 * *(const volatile unsigned long long *)(r + 0xd0);
    }
    uint64_t calculateIOSurfaceDeviceCacheVRAMBytes(unsigned long long* a0, unsigned long long* a1) APPLE_KEXT_OVERRIDE {
        const unsigned char *r = (const unsigned char *)this;
        unsigned long long size = *(const volatile unsigned long long *)(r + 0xd0);
        if (a1) *a1 = 1;
        if (a0) *a0 = size;
        return size;
    }
    bool addToAperture() APPLE_KEXT_OVERRIDE;
    void removeFromAperture() APPLE_KEXT_OVERRIDE;
    void *getApertureMemoryDescriptor(unsigned long long *a0) APPLE_KEXT_OVERRIDE;
    void free() APPLE_KEXT_OVERRIDE;
    void pageoff(IOAccelEvent *, bool, bool *, unsigned long long) APPLE_KEXT_OVERRIDE;
    // B580 VRAM-shared IOSurfaces (gpuperf): a vidmem adopted from IntelXe.kext's registry (fIntelXe) has no CPU mapping, so the
    // family's own CPU page-on/off must never run on it; both go to B580's copy engine instead (nmxSVCopy).
    void pageon(IOAccelEvent *, bool) APPLE_KEXT_OVERRIDE;
    void pageon(IOAccelEvent *, bool, unsigned long long) APPLE_KEXT_OVERRIDE;
    unsigned int fApLogged = 0;
    IOMemoryDescriptor *fApDesc = nullptr;
    // Set by the plugin's surface-dirty escape: the allocation cookie of the VRAM the GPU wrote for this resource. The
    // family's own "VRAM newest" bit can be set on a VRAM copy nothing ever rendered into (freshly allocated,
    // zero-filled); a zero-copy flip of that copy, or a page-off from it, puts a black frame on the panel while the real
    // pixels sit in the surface's system memory. The display pipe compares this with the current allocation's cookie
    // before trusting the family bit, so VRAM re-allocated under the same resource counts as unwritten again (a parked
    // allocation that comes back keeps its cookie, and so its record). 0 = never written.
    unsigned long long fPluginWroteCookie = 0;
};
OSDefineMetaClassAndStructors(NVResource, IOAccelResource2)
class NVSysMemory : public IOAccelSysMemory {
    OSDeclareDefaultStructors(NVSysMemory)
    NM_TAHOE_FWD(NVSysMemory)
public:
};
OSDefineMetaClassAndStructors(NVSysMemory, IOAccelSysMemory)
class NVVidMemory : public IOAccelVidMemory {
    OSDeclareDefaultStructors(NVVidMemory)
    NM_TAHOE_FWD(NVVidMemory)
public:
    void              *fRmHandle = nullptr;
    unsigned long long fAllocationCookie = 0;
    void              *fKva      = nullptr;
    unsigned long long fPhys     = 0;
    unsigned long long fBytes    = 0;
    bool fScanout = false;
    // B580 VRAM-shared IOSurfaces (gpuperf): the IntelXe.kext registry entry this vidmem adopted (one reference), or null.
    // fRmHandle is the same pointer (so "backed" checks hold), fPhys and fKva stay 0: the VRAM has no CPU address.
    void *fIntelXe = nullptr;
    // VRAM kept across deallocPhysical/allocPhysical (debug.nvaccel_vm_sticky): see NVVidMemory::deallocPhysical
    void              *fParkHandle = nullptr;
    void              *fParkKva    = nullptr;
    unsigned long long fParkPhys = 0, fParkBytes = 0, fParkCookie = 0;
    void releaseVram(void *handle, void *kva, unsigned long long bytes, unsigned long long cookie);
    void releaseParked();

    bool allocPhysical() APPLE_KEXT_OVERRIDE;
    void deallocPhysical() APPLE_KEXT_OVERRIDE;
    void free() APPLE_KEXT_OVERRIDE;

    uint64_t getPhysicalSegment(unsigned long long a0, unsigned long long* a1) APPLE_KEXT_OVERRIDE {
        const unsigned long long total = *(const volatile unsigned long long *)((const unsigned char *)this + 0x40);
        if (!fPhys || fIntelXe || a0 >= total) { if (a1) *a1 = 0; return 0; }
        if (a1) *a1 = total - a0;
        return fPhys + a0;
    }
};
OSDefineMetaClassAndStructors(NVVidMemory, IOAccelVidMemory)
class NVSurface : public IOAccelLegacySurface {
    OSDeclareDefaultStructors(NVSurface)
    NM_TAHOE_FWD(NVSurface)
public:
    void setSyncCommand(unsigned int* a0, unsigned int& a1, unsigned int& a2, _AMDSurfaceSwapSyncOptions const& a3) const APPLE_KEXT_OVERRIDE { ALOG("NVSurface::setSyncCommand"); }
    void _pure335() APPLE_KEXT_OVERRIDE { ALOG("NVSurface::_pure335"); }
    bool copyFromBuffer(int a0, int a1, int a2, int a3, unsigned int a4, unsigned int a5, IOAccelEvent* a6, IOAccelResource2* a7, IOAccelSysMemory* a8, unsigned int a9, unsigned long long a10, unsigned int a11) APPLE_KEXT_OVERRIDE { ALOG("NVSurface::copyFromBuffer"); return false; }
    bool copyToBuffer(int a0, int a1, int a2, int a3, unsigned int a4, unsigned int a5, IOAccelEvent* a6, IOAccelResource2* a7, IOAccelSysMemory* a8, unsigned int a9, unsigned long long a10, unsigned int a11) APPLE_KEXT_OVERRIDE { ALOG("NVSurface::copyToBuffer"); return false; }
    void submitSwapCopy(IOAccelEvent* a0, IOAccelResource2* a1, IOAccelResource2* a2) APPLE_KEXT_OVERRIDE {
        (void)a0;
        nvAccelSwapProbe(a1, a2);
        IOAccelResource2 *src = nvAccelResHasContent(a2) ? a2
                              : nvAccelResHasContent(a1) ? a1 : nullptr;
        if (src && !nvAccelFlipTo(src)) nvAccelCopyToScanout(src);
    }
    void shapeSurface(unsigned int a0, unsigned short a1, unsigned short a2) APPLE_KEXT_OVERRIDE {
        const unsigned w = a1, h = a2;
        uint32_t smode = *(const volatile uint32_t *)((const uint8_t *)this + 0x11B0);
        unsigned bpp = ((smode >> 16) & 0xf) + 1;
        if (bpp < 4 || bpp > 16) bpp = 4;
        unsigned pitch = (unsigned)((w * bpp + 255u) & ~255u);
        unsigned size  = pitch * h;
        IOAccelResource2 **bufs = (IOAccelResource2 **)((uint8_t *)this + 0x11C0);
        unsigned present = 0, shaped = 0;
        for (unsigned i = 0; i < 32; i++) {
            if (!(a0 & (1u << i))) continue;
            IOAccelResource2 *r = OSDynamicCast(IOAccelResource2, bufs[i]);
            if (!r) continue;
            present++;
            if (r->initSurfaceBuffer(this, w, h, size, pitch, 0)) shaped++;
        }
        ALOG("NVSurface::shapeSurface(mode 0x%x, %u x %u) smode 0x%x bpp %u pitch %u size %u -> %u present, %u shaped",
             a0, w, h, smode, bpp, pitch, size, present, shaped);
        static int gShapeDumps = 0;
        if (gShapeDumps < 4) { gShapeDumps++;
            const volatile unsigned long long *qq = (const volatile unsigned long long *)((const unsigned char *)this + 0x1160);
            for (unsigned o = 0; o < 0x60; o += 16)
                ALOG("   surf+0x%04x: %016llx %016llx", 0x1160 + o, qq[o / 8], qq[o / 8 + 1]);
        }
    }
    uint32_t getDirtyBufferBitsFromPrivateModeBits(unsigned long long a0) APPLE_KEXT_OVERRIDE { ALOG("NVSurface::getDirtyBufferBitsFromPrivateModeBits(0x%llx)", (unsigned long long)a0); return 0; }
#ifdef NMX_ACCEL
    // Page-flip copy-forward: WindowServer carries the unchanged parts of the last frame into the buffer it is about to
    // draw. The family's own answer is Unsupported, and WindowServer then dropped every frame before its swap
    // ("copy_forward_region: copy forward failed (0xe00002c7) ... disabling", no swap ever reached submitSwapCopy).
    // IOAccelLegacySurface::copy_forward passes the surface's buffer 0 (the one it then prepares for drawing) first.
    IOReturn submitCopyForward(IOAccelEvent *ev, unsigned int flags, IOAccelResource2 *dst, IOAccelResource2 *src,
                               IOAccelBounds const *rects, unsigned int count) APPLE_KEXT_OVERRIDE {
        (void)ev; (void)flags;
        return nvAccelCopyRects(dst, src, rects, count) ? kIOReturnSuccess : kIOReturnUnsupported;
    }
    // B580: the family refuses most WindowServer shapes with "Bad frame buffer index" (the index must be below the
    // display machine's framebuffer count). Log what WindowServer asks for before the family decides.
    IOReturn set_shape_backing_length_ext(eIOAccelSurfaceShapeBits bits, unsigned int fbIndex, unsigned long long addr,
                                          unsigned int rowBytes, unsigned long long length, IOAccelDeviceRegion *rgn,
                                          unsigned long long rgnSize) APPLE_KEXT_OVERRIDE {
#ifdef NM_TAHOE   // macOS 26: IOAccelSurface::set_shape_backing_length_ext is private (and retyped); reach it via the base vtable
        IOReturn r = nmx_super_IOAccelLegacySurface_set_shape_backing_length_ext_7(IOReturn, this, bits, fbIndex, addr, rowBytes, length, rgn, rgnSize);
#else
        IOReturn r = IOAccelLegacySurface::set_shape_backing_length_ext(bits, fbIndex, addr, rowBytes, length, rgn, rgnSize);
#endif
        static volatile SInt32 n = 0, bad = 0;
        SInt32 k = OSIncrementAtomic(&n);
        SInt32 b = r ? OSIncrementAtomic(&bad) : -1;
        if (k < 6 || (b >= 0 && (b < 30 || (b % 1000) == 0)))
            ALOG("NVSurface::set_shape_backing_length_ext #%d: bits 0x%x fbIndex %u addr 0x%llx rowBytes %u length %llu rgnSize %llu -> 0x%x",
                 (int)k, (unsigned)bits, fbIndex, addr, rowBytes, length, rgnSize, (unsigned)r);
        return r;
    }
#endif
};
OSDefineMetaClassAndStructors(NVSurface, IOAccelLegacySurface)
class NVDisplayPipe : public IOAccelLegacyDisplayPipe {
    OSDeclareDefaultStructors(NVDisplayPipe)
    NM_TAHOE_FWD(NVDisplayPipe)
public:
    IOAccelMemory *initFramebufferResource(unsigned int index, IOAccelResource2 *res) APPLE_KEXT_OVERRIDE;
    IOReturn validateTransaction(IOAccelDisplayPipeTransaction2 *txn) APPLE_KEXT_OVERRIDE;
    IOReturn performTransaction(IOAccelDisplayPipeTransaction2 *txn) APPLE_KEXT_OVERRIDE;
    bool     isTransactionComplete(IOAccelDisplayPipeTransaction2 *txn) APPLE_KEXT_OVERRIDE;
    void     free() APPLE_KEXT_OVERRIDE;
    enum { kIopSrcSlots = 4 };
    struct NVIopSrc { unsigned id; IOMemoryDescriptor *md; IOMemoryMap *map; } fIopSrc[kIopSrcSlots];
    unsigned fIopNext;
    const void *iopMapSurface(unsigned id, IOMemoryDescriptor *md, unsigned long long need);
    void        iopDropSources();
};
OSDefineMetaClassAndStructors(NVDisplayPipe, IOAccelLegacyDisplayPipe)
class NVGLContext : public IOAccelGLContext2 {
    OSDeclareDefaultStructors(NVGLContext)
    NM_TAHOE_FWD(NVGLContext)
public:
    void _pure362() APPLE_KEXT_OVERRIDE { ALOG("NVGLContext::_pure362"); }
    void _pure363() APPLE_KEXT_OVERRIDE { ALOG("NVGLContext::_pure363"); }
    void _pure364() APPLE_KEXT_OVERRIDE { ALOG("NVGLContext::_pure364"); }
    void _pure367() APPLE_KEXT_OVERRIDE { ALOG("NVGLContext::_pure367"); }
};
OSDefineMetaClassAndStructors(NVGLContext, IOAccelGLContext2)
class NV2DContext : public IOAccel2DContext2 {
    OSDeclareDefaultStructors(NV2DContext)
    NM_TAHOE_FWD(NV2DContext)
public:
    void _pure362() APPLE_KEXT_OVERRIDE { ALOG("NV2DContext::_pure362"); }
    void _pure363() APPLE_KEXT_OVERRIDE { ALOG("NV2DContext::_pure363"); }
};
OSDefineMetaClassAndStructors(NV2DContext, IOAccel2DContext2)
class NVCLContext : public IOAccelCLContext2 {
    OSDeclareDefaultStructors(NVCLContext)
    NM_TAHOE_FWD(NVCLContext)
public:
};
OSDefineMetaClassAndStructors(NVCLContext, IOAccelCLContext2)
class NVVideoContext : public IOAccelVideoContext2 {
    OSDeclareDefaultStructors(NVVideoContext)
    NM_TAHOE_FWD(NVVideoContext)
public:
};
OSDefineMetaClassAndStructors(NVVideoContext, IOAccelVideoContext2)
