// xemac_drm.c: libdrm's entry points used by Mesa (libdrm/xf86drm.h), as DRM ioctls through xemac_ioctl().
// Return conventions are libdrm's: most calls return the ioctl result (0, or -1 with errno), the waits -errno.
// SPDX-License-Identifier: MIT

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include "xemac.h"
#include "xf86drm.h"

int drmIoctl(int fd, unsigned long request, void *arg)
{
	int ret;
	do {
		ret = xemac_is_fd(fd) ? xemac_ioctl(fd, request, arg) : ioctl(fd, request, arg);
	} while (ret == -1 && (errno == EINTR || errno == EAGAIN));
	return ret;
}

int drmGetCap(int fd, uint64_t capability, uint64_t *value)
{
	struct drm_get_cap cap = {.capability = capability};
	int ret = drmIoctl(fd, DRM_IOCTL_GET_CAP, &cap);
	if (ret)
		return ret;
	*value = cap.value;
	return 0;
}

drmVersionPtr drmGetVersion(int fd)
{
	struct drm_version v = {0};
	if (drmIoctl(fd, DRM_IOCTL_VERSION, &v))
		return NULL;
	drmVersionPtr r = calloc(1, sizeof(*r));
	if (!r)
		return NULL;
	r->name = calloc(1, v.name_len + 1), r->date = calloc(1, v.date_len + 1), r->desc = calloc(1, v.desc_len + 1);
	v.name = r->name, v.date = r->date, v.desc = r->desc;
	if (!r->name || !r->date || !r->desc || drmIoctl(fd, DRM_IOCTL_VERSION, &v)) {
		drmFreeVersion(r);
		return NULL;
	}
	r->version_major = v.version_major, r->version_minor = v.version_minor;
	r->version_patchlevel = v.version_patchlevel;
	r->name_len = strlen(r->name), r->date_len = strlen(r->date), r->desc_len = strlen(r->desc);
	return r;
}

void drmFreeVersion(drmVersionPtr version)
{
	if (!version)
		return;
	free(version->name);
	free(version->date);
	free(version->desc);
	free(version);
}

// One allocation, like libdrm: the device, its node table and strings, and the PCI info.
static drmDevicePtr device_from_fd(int fd)
{
	struct xemac_pci_info pci;
	if (xemac_pci_info(fd, &pci))
		return NULL;
	struct block {
		drmDevice dev;
		char *nodes[DRM_NODE_MAX];
		char render[sizeof(XEMAC_RENDER_NODE)];
		char empty;
		drmPciBusInfo bus;
		drmPciDeviceInfo info;
	} *b = calloc(1, sizeof(*b));
	if (!b)
		return NULL;
	for (int i = 0; i < DRM_NODE_MAX; i++)
		b->nodes[i] = &b->empty;
	memcpy(b->render, XEMAC_RENDER_NODE, sizeof(XEMAC_RENDER_NODE));
	b->nodes[DRM_NODE_RENDER] = b->render;
	b->bus = (drmPciBusInfo){.domain = 0, .bus = pci.bus, .dev = pci.dev, .func = pci.func};
	b->info = (drmPciDeviceInfo){.vendor_id = pci.vendor, .device_id = pci.device, .subvendor_id = pci.subvendor,
				     .subdevice_id = pci.subdevice, .revision_id = pci.revision};
	b->dev = (drmDevice){.nodes = b->nodes, .available_nodes = 1 << DRM_NODE_RENDER, .bustype = DRM_BUS_PCI,
			     .businfo.pci = &b->bus, .deviceinfo.pci = &b->info};
	return &b->dev;
}

int drmGetDevice2(int fd, uint32_t flags, drmDevicePtr *device)
{
	(void)flags;
	if (!xemac_is_fd(fd))
		return -ENODEV;
	*device = device_from_fd(fd);
	return *device ? 0 : -errno;
}

int drmGetDevices2(uint32_t flags, drmDevicePtr devices[], int max_devices)
{
	(void)flags;
	int fd = xemac_open();
	if (fd < 0)
		return 0; // no IntelXe service: no devices
	int count = 0;
	if (devices && max_devices > 0) {
		devices[0] = device_from_fd(fd);
		count = devices[0] ? 1 : 0;
	} else {
		count = 1;
	}
	xemac_close(fd);
	return count;
}

void drmFreeDevice(drmDevicePtr *device)
{
	if (device) {
		free(*device);
		*device = NULL;
	}
}

void drmFreeDevices(drmDevicePtr devices[], int count)
{
	for (int i = 0; devices && i < count; i++)
		drmFreeDevice(&devices[i]);
}

int drmDevicesEqual(drmDevicePtr a, drmDevicePtr b)
{
	if (!a || !b || a->bustype != b->bustype)
		return 0;
	return a->bustype == DRM_BUS_PCI && !memcmp(a->businfo.pci, b->businfo.pci, sizeof(drmPciBusInfo));
}

int drmGetNodeTypeFromFd(int fd)
{
	if (!xemac_is_fd(fd)) {
		errno = ENODEV;
		return -1;
	}
	return DRM_NODE_RENDER;
}

char *drmGetDeviceNameFromFd2(int fd)
{
	return xemac_is_fd(fd) ? strdup(XEMAC_RENDER_NODE) : NULL;
}

char *drmGetRenderDeviceNameFromFd(int fd)
{
	return drmGetDeviceNameFromFd2(fd);
}

int drmPrimeHandleToFD(int fd, uint32_t handle, uint32_t flags, int *prime_fd)
{
	struct drm_prime_handle args = {.handle = handle, .flags = flags, .fd = -1};
	int ret = drmIoctl(fd, DRM_IOCTL_PRIME_HANDLE_TO_FD, &args);
	if (ret)
		return ret;
	*prime_fd = args.fd;
	return 0;
}

int drmPrimeFDToHandle(int fd, int prime_fd, uint32_t *handle)
{
	struct drm_prime_handle args = {.fd = prime_fd};
	int ret = drmIoctl(fd, DRM_IOCTL_PRIME_FD_TO_HANDLE, &args);
	if (ret)
		return ret;
	*handle = args.handle;
	return 0;
}

int drmSyncobjCreate(int fd, uint32_t flags, uint32_t *handle)
{
	struct drm_syncobj_create args = {.flags = flags};
	int ret = drmIoctl(fd, DRM_IOCTL_SYNCOBJ_CREATE, &args);
	if (ret)
		return ret;
	*handle = args.handle;
	return 0;
}

int drmSyncobjDestroy(int fd, uint32_t handle)
{
	struct drm_syncobj_destroy args = {.handle = handle};
	return drmIoctl(fd, DRM_IOCTL_SYNCOBJ_DESTROY, &args);
}

static int handle_to_fd(int fd, uint32_t handle, uint32_t flags, int *out)
{
	struct drm_syncobj_handle args = {.handle = handle, .flags = flags, .fd = -1};
	int ret = drmIoctl(fd, DRM_IOCTL_SYNCOBJ_HANDLE_TO_FD, &args);
	if (ret)
		return ret;
	*out = args.fd;
	return 0;
}

static int fd_to_handle(int fd, int obj_fd, uint32_t flags, uint32_t *handle)
{
	struct drm_syncobj_handle args = {.handle = handle ? *handle : 0, .flags = flags, .fd = obj_fd};
	int ret = drmIoctl(fd, DRM_IOCTL_SYNCOBJ_FD_TO_HANDLE, &args);
	if (ret)
		return ret;
	if (handle)
		*handle = args.handle;
	return 0;
}

int drmSyncobjHandleToFD(int fd, uint32_t handle, int *obj_fd)
{
	return handle_to_fd(fd, handle, 0, obj_fd);
}

int drmSyncobjFDToHandle(int fd, int obj_fd, uint32_t *handle)
{
	return fd_to_handle(fd, obj_fd, 0, handle);
}

int drmSyncobjImportSyncFile(int fd, uint32_t handle, int sync_file_fd)
{
	return fd_to_handle(fd, sync_file_fd, DRM_SYNCOBJ_FD_TO_HANDLE_FLAGS_IMPORT_SYNC_FILE, &handle);
}

int drmSyncobjExportSyncFile(int fd, uint32_t handle, int *sync_file_fd)
{
	return handle_to_fd(fd, handle, DRM_SYNCOBJ_HANDLE_TO_FD_FLAGS_EXPORT_SYNC_FILE, sync_file_fd);
}

int drmSyncobjWait(int fd, uint32_t *handles, unsigned num_handles, int64_t timeout_nsec, unsigned flags,
		   uint32_t *first_signaled)
{
	struct drm_syncobj_wait args = {.handles = (uintptr_t)handles, .timeout_nsec = timeout_nsec,
					.count_handles = num_handles, .flags = flags};
	int ret = drmIoctl(fd, DRM_IOCTL_SYNCOBJ_WAIT, &args);
	if (ret < 0)
		return -errno;
	if (first_signaled)
		*first_signaled = args.first_signaled;
	return ret;
}

int drmSyncobjReset(int fd, const uint32_t *handles, uint32_t handle_count)
{
	struct drm_syncobj_array args = {.handles = (uintptr_t)handles, .count_handles = handle_count};
	return drmIoctl(fd, DRM_IOCTL_SYNCOBJ_RESET, &args);
}

int drmSyncobjSignal(int fd, const uint32_t *handles, uint32_t handle_count)
{
	struct drm_syncobj_array args = {.handles = (uintptr_t)handles, .count_handles = handle_count};
	return drmIoctl(fd, DRM_IOCTL_SYNCOBJ_SIGNAL, &args);
}

int drmSyncobjTimelineSignal(int fd, const uint32_t *handles, uint64_t *points, uint32_t handle_count)
{
	struct drm_syncobj_timeline_array args = {.handles = (uintptr_t)handles, .points = (uintptr_t)points,
						  .count_handles = handle_count};
	return drmIoctl(fd, DRM_IOCTL_SYNCOBJ_TIMELINE_SIGNAL, &args);
}

int drmSyncobjTimelineWait(int fd, uint32_t *handles, uint64_t *points, unsigned num_handles, int64_t timeout_nsec,
			   unsigned flags, uint32_t *first_signaled)
{
	struct drm_syncobj_timeline_wait args = {.handles = (uintptr_t)handles, .points = (uintptr_t)points,
						 .timeout_nsec = timeout_nsec, .count_handles = num_handles,
						 .flags = flags};
	int ret = drmIoctl(fd, DRM_IOCTL_SYNCOBJ_TIMELINE_WAIT, &args);
	if (ret < 0)
		return -errno;
	if (first_signaled)
		*first_signaled = args.first_signaled;
	return ret;
}

int drmSyncobjQuery2(int fd, uint32_t *handles, uint64_t *points, uint32_t handle_count, uint32_t flags)
{
	struct drm_syncobj_timeline_array args = {.handles = (uintptr_t)handles, .points = (uintptr_t)points,
						  .count_handles = handle_count, .flags = flags};
	return drmIoctl(fd, DRM_IOCTL_SYNCOBJ_QUERY, &args);
}

int drmSyncobjQuery(int fd, uint32_t *handles, uint64_t *points, uint32_t handle_count)
{
	return drmSyncobjQuery2(fd, handles, points, handle_count, 0);
}

int drmSyncobjTransfer(int fd, uint32_t dst_handle, uint64_t dst_point, uint32_t src_handle, uint64_t src_point,
		       uint32_t flags)
{
	struct drm_syncobj_transfer args = {.src_handle = src_handle, .dst_handle = dst_handle,
					    .src_point = src_point, .dst_point = dst_point, .flags = flags};
	return drmIoctl(fd, DRM_IOCTL_SYNCOBJ_TRANSFER, &args);
}
