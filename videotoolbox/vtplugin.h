// The VideoToolbox decoder plug-in ABI (not in the public SDK): CoreMedia's derived-object classes as laid out in
// macOS x86_64 builds (pack 4, a 32-bit class version), checked against Apple's and nullmoth's decoder binaries.
#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
typedef struct OpaqueCMBaseObject *CMBaseObjectRef;
typedef struct OpaqueVTVideoDecoder *VTVideoDecoderRef;
typedef struct OpaqueVTVideoDecoderSession *VTVideoDecoderSession;
typedef struct OpaqueVTVideoDecoderFrame *VTVideoDecoderFrame;
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
	OSStatus (*startSession)(VTVideoDecoderRef, VTVideoDecoderSession, CMVideoFormatDescriptionRef);
	OSStatus (*decodeFrame)(VTVideoDecoderRef, VTVideoDecoderFrame, CMSampleBufferRef, VTDecodeFrameFlags, VTDecodeInfoFlags *);
	OSStatus (*copySupportedPropertyDictionary)(VTVideoDecoderRef, CFDictionaryRef *);
	OSStatus (*setProperties)(VTVideoDecoderRef, CFDictionaryRef);
	OSStatus (*copySerializableProperties)(VTVideoDecoderRef, CFAllocatorRef, CFDictionaryRef *);
	Boolean (*canAcceptFormatDescription)(VTVideoDecoderRef, CMFormatDescriptionRef);
	OSStatus (*finishDelayedFrames)(VTVideoDecoderRef);
	void *reserved[8];
} VTVideoDecoderClass;
#pragma pack(pop)
typedef struct { uintptr_t reserved; const CMBaseClass *baseClass; const VTVideoDecoderClass *derivedClass; } VTVideoDecoderVTable;
extern OSStatus CMDerivedObjectCreate(CFAllocatorRef, const void *vtable, CMBaseClassID, CMBaseObjectRef *);
extern void *CMBaseObjectGetDerivedStorage(CMBaseObjectRef);
extern CMBaseClassID VTVideoDecoderGetClassID(void);
extern CMBaseObjectRef VTVideoDecoderGetCMBaseObject(VTVideoDecoderRef);
extern OSStatus VTDecoderSessionSetPixelBufferAttributes(VTVideoDecoderSession, CFDictionaryRef);
extern CVPixelBufferPoolRef VTDecoderSessionGetPixelBufferPool(VTVideoDecoderSession);
extern OSStatus VTDecoderSessionEmitDecodedFrame(VTVideoDecoderSession, VTVideoDecoderFrame, OSStatus, VTDecodeInfoFlags, CVImageBufferRef);
extern OSStatus VTRegisterVideoDecoderWithInfo(FourCharCode, CFDictionaryRef, OSStatus (*)(FourCharCode, CFAllocatorRef, VTVideoDecoderRef *));
