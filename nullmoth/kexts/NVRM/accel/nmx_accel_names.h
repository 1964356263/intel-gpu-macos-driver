// NMXAccel: class names for the accelerator built with -DNMX_ACCEL.
//
// Upstream includes this header from nvrm-accel.cpp but does not ship it. This reconstruction renames every
// OSMetaClass the file defines, so NMXAccel can be loaded next to NVAccel without a metaclass name clash. The names
// are the ones in the released NMXAccel.kext (nullmoth-nvidia-2.1.0, Library/NullMoth/kexts/15): its vtables are
// __ZTV8NMXAccel, __ZTV7NMXTask, __ZTV17IOAccelNMXCarrier, ... and the service names it looks up ("NVRM",
// "NVRMNVDAFramebuffer") are unchanged. The Metal plugin finds this accelerator by IOObjectConformsTo(.., "NMXAccel")
// (plugin/nvmtl_vk.c).
#pragma once

#define NVAccel            NMXAccel
#define NVEventMachine     NMXEventMachine
#define NVDisplayMachine   NMXDisplayMachine
#define NVDisplayPipe      NMXDisplayPipe
#define NVTask             NMXTask
#define NVMemoryMap        NMXMemoryMap
#define NVResource         NMXResource
#define NVSurface          NMXSurface
#define NVSysMemory        NMXSysMemory
#define NVVidMemory        NMXVidMemory
#define NVGLContext        NMXGLContext
#define NV2DContext        NMX2DContext
#define NVCLContext        NMXCLContext
#define NVVideoContext     NMXVideoContext
#define IOAccelNVRMCarrier IOAccelNMXCarrier
