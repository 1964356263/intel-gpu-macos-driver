# The Khronos Vulkan loader for the B580 (notes)

So that ordinary Vulkan applications (linked against `libvulkan.1.dylib`, no driver path of their own) find the B580,
the Khronos loader is installed where the LunarG Vulkan SDK puts it on macOS, with an ICD manifest for our ANV. The
Metal plugin does not use it: it loads ANV by its own path.

- **Loader:** [Vulkan-Loader](https://github.com/KhronosGroup/Vulkan-Loader) tag `vulkan-sdk-1.4.363.0`, **Apache-2.0**,
  built unmodified: CMake `Release`, `CMAKE_OSX_ARCHITECTURES=x86_64`, `CMAKE_OSX_DEPLOYMENT_TARGET=15.0`,
  `CMAKE_INSTALL_PREFIX=/usr/local`, `BUILD_TESTS=OFF`, `APPLE_STATIC_LOADER=OFF`, against Vulkan-Headers of the same tag.
- **vulkaninfo:** Vulkan-Tools, same tag (Apache-2.0), same settings.
- **ICD manifest:** `intel_icd.x86_64.json` -> `/Library/GPUBundles/nvmtl/libvulkan_intel.dylib` (not a portability
  driver, so no `VK_KHR_portability_enumeration` is needed).

Installed by `install.sh` (`sudo ./install.sh`, `--undo` restores what was there) from a package directory with
`lib/libvulkan.1.4.363.dylib`, `icd.d/intel_icd.x86_64.json` and `bin/vulkaninfo`:

| File | Installed as |
|---|---|
| loader | `/usr/local/lib/libvulkan.1.4.363.dylib` (+ `libvulkan.1.dylib`, `libvulkan.dylib` symlinks) |
| ICD manifest | `/usr/local/share/vulkan/icd.d/intel_icd.x86_64.json` |
| vulkaninfo | `/usr/local/bin/vulkaninfo` |

`vk_compute.c` is the check: an app with no driver path, a compute dispatch on the first discrete GPU the loader reports.

The binaries are not in this repository. Whoever passes them on must include the Apache-2.0 licence text and the
loader's NOTICE.
