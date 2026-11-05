// SPDX-License-Identifier: MIT
// The VideoToolbox encoder plug-in ABI (not in the public SDK), as macOS 15 x86_64 builds lay it out: CoreMedia derived
// objects with a 32-bit class version and pack(4). Checked against Apple's x86_64 encoders on the B580 machine
// (/System/Library/Video/Plug-Ins/JPEGVideoEncoder.bundle, AppleGVAHEVCEncoder.bundle, 15.8.1): their vtables are
// { 0, &CMBaseClass, &VTVideoEncoderClass } and both use exactly the four encoder methods below (version 1 and 2).
//   startSession     (encoder, session, CMVideoDimensions in one register, encoder specification CFDictionary)
//   encodeFrame      (encoder, frame token, CVImageBuffer, CMTime pts and duration on the stack, frame properties,
//                     VTEncodeInfoFlags *): returns with kVTEncodeInfo_Asynchronous set and emits later
//   completeFrames   (encoder, CMTime complete-until, on the stack): emit everything up to it before returning
//   copySupportedPropertyDictionary (encoder, CFDictionaryRef *)
// Properties come and go through the CMBaseClass copyProperty/setProperty (one key at a time).
#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
typedef struct OpaqueCMBaseObject *CMBaseObjectRef;
typedef struct OpaqueVTVideoEncoder *VTVideoEncoderRef;
typedef struct OpaqueVTEncoderSession *VTEncoderSessionRef;
typedef struct OpaqueVTEncoderFrame *VTEncoderFrameRef;
typedef const struct OpaqueCMBaseClassID *CMBaseClassID;
#pragma pack(push, 4)
typedef struct {
	uint32_t version;
	size_t derivedStorageSize;
	Boolean (*equal)(CMBaseObjectRef, CMBaseObjectRef);
	OSStatus (*invalidate)(CMBaseObjectRef);
	void (*finalize)(CMBaseObjectRef);
	CFStringRef (*copyDebugDescription)(CMBaseObjectRef);
	OSStatus (*copyProperty)(CMBaseObjectRef, CFStringRef, CFAllocatorRef, void *);
	OSStatus (*setProperty)(CMBaseObjectRef, CFStringRef, CFTypeRef);
	OSStatus (*notificationBarrier)(CMBaseObjectRef);
	const void *protocolTable;
} CMBaseClass;
typedef struct {
	uint32_t version;
	OSStatus (*startSession)(VTVideoEncoderRef, VTEncoderSessionRef, CMVideoDimensions, CFDictionaryRef);
	OSStatus (*encodeFrame)(VTVideoEncoderRef, VTEncoderFrameRef, CVImageBufferRef, CMTime, CMTime, CFDictionaryRef, VTEncodeInfoFlags *);
	OSStatus (*completeFrames)(VTVideoEncoderRef, CMTime);
	OSStatus (*copySupportedPropertyDictionary)(VTVideoEncoderRef, CFDictionaryRef *);
	void *reserved[12];
} VTVideoEncoderClass;
#pragma pack(pop)
typedef struct { uintptr_t reserved; const CMBaseClass *baseClass; const VTVideoEncoderClass *derivedClass; } VTVideoEncoderVTable;
extern OSStatus CMDerivedObjectCreate(CFAllocatorRef, const void *vtable, CMBaseClassID, CMBaseObjectRef *);
extern void *CMBaseObjectGetDerivedStorage(CMBaseObjectRef);
extern CMBaseClassID VTVideoEncoderGetClassID(void);
extern CMBaseObjectRef VTVideoEncoderGetCMBaseObject(VTVideoEncoderRef);
extern OSStatus VTEncoderSessionSetPixelBufferAttributes(VTEncoderSessionRef, CFDictionaryRef);
extern OSStatus VTEncoderSessionEmitEncodedFrame(VTEncoderSessionRef, VTEncoderFrameRef, OSStatus, VTEncodeInfoFlags, CMSampleBufferRef);
extern OSStatus VTRegisterVideoEncoderWithInfo(FourCharCode, CFDictionaryRef, OSStatus (*)(FourCharCode, CFAllocatorRef, VTVideoEncoderRef *));
