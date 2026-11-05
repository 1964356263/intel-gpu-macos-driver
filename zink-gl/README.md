# zink-gl: OpenGL on the Intel Arc B580 through Mesa's zink

An optional component. Applications that open their OpenGL context through GLFW/EGL (LWJGL 3 Java games such as
Minecraft Java 1.13 and later) render through Mesa's zink straight to Vulkan (the driver's ANV) instead of Apple's
OpenGL → Metal → plugin → Vulkan. Apple's OpenGL, ANV and the kexts are not touched; no process loads these libraries
unless it asks for them. It needs the driver installed and `intelxe_surfvram=2` (without it every frame is copied).

Measured on the test machine (macOS 26.7.1, Minecraft 1.21.1 with Sodium and Iris, windowed, the same spot, 6 November
2026): with the BSL shader pack (HIGH) **zink 197–205 fps**, the same card on Windows (Intel's OpenGL) 214–218 fps;
without a shader pack zink 1400–1500 fps, Windows 700–1000. An earlier measurement without Sodium (2560×1440 full
screen, render distance 16): zink 741 fps, Apple's OpenGL 160 fps, Windows 450–479 fps.

| Command | What it does |
|---|---|
| `sudo ./install.sh` | `/Library/IntelXe/GL`, the Vulkan loader (`/usr/local/lib`) and the ICD manifest; backs up what it replaces to `./previous/` |
| `./install.sh --test` | offscreen self-test: a GL core context through zink on the B580 |
| `sudo ./install.sh --global on` | every LWJGL 3 application uses zink (`JAVA_TOOL_OPTIONS`, set by a LaunchAgent at login) |
| `sudo ./install.sh --global off` | those applications go back to Apple's OpenGL |
| `./zink-gl-version.sh 1.21.1 --write` | one Minecraft version only: a separate `1.21.1-zink` version |
| `sudo ./install.sh --undo` | the state before the install |
| `sudo ./install.sh --status` | what is installed and switched on |

`--global on` affects applications started afterwards; running ones must be restarted. Java prints "Picked up
JAVA_TOOL_OPTIONS" at each start; that is expected. To keep one application on Apple's OpenGL, start it with
`JAVA_TOOL_OPTIONS` empty.

## Limits

- Native macOS applications that use CGL/NSOpenGL directly still go through Apple's OpenGL.
- Opaque windows rely on Core Animation's private `contentsOpaque`; a macOS update can break it.
- Tested on macOS 26.7.1 only: in the game at the spot above, windowed and full screen, with a shader pack through
  Iris. Not tested: scaled (HiDPI) display modes, screen recording while it runs, several windows, Minecraft 26.3,
  macOS 15.
- `--global on` survives restarts (the LaunchAgent sets `JAVA_TOOL_OPTIONS` at each login), but an application that
  macOS reopens by itself at login ("Reopen windows when logging back in") can start a few seconds before the
  LaunchAgent and then runs on Apple's OpenGL. Quit it and start it again; Java prints "Picked up JAVA_TOOL_OPTIONS"
  when zink is on.

## Contents and sources

| File in the package | What | Source |
|---|---|---|
| `lib/libEGL.1.dylib` | Mesa EGL with a macOS platform (window = CALayer, kopper + `VK_EXT_metal_surface`) | Mesa `f01e9b07a91` + `src/mesa-zink.diff` |
| `lib/libgallium-27.0.0-devel.dylib` | zink; Vulkan through `/usr/local/lib/libvulkan.1.dylib` | same tree |
| `lib/libGLzink.dylib` | LWJGL's OpenGL library (`OSMesaGetProcAddress` → `eglGetProcAddress`) | `src/glshim.c` |
| `lib/libglfw.3.dylib` | GLFW 3.4: desktop OpenGL contexts through EGL | GLFW 3.4 + `src/glfw-3.4-0001-*.patch` |
| `vulkan/libvulkan.1.4.363.dylib` | Khronos Vulkan loader, unmodified | Vulkan-Loader `vulkan-sdk-1.4.363.0`, as in `user/vulkan-loader/README.md` |
| `vulkan/icd.d/intel_icd.x86_64.json` | ICD manifest → `/Library/GPUBundles/nvmtl/libvulkan_intel.dylib` | `user/vulkan-loader/` |
| `bin/zink-gl-selftest` | the `--test` program | `src/egltri.c` |

`src/mesa-zink.diff` is the whole difference of the built tree from upstream. Its patches are in `mesa/patches`
(`0071`, `0072`, `0073` are the zink part). zink talks to ANV only through the Vulkan API, so it does not have to come
from the same Mesa commit as the installed ANV.

Building: Mesa with `mesa/darwin-x86_64.ini` and
`-Dbuildtype=release -Db_ndebug=true '-Dc_args=-Xclang -fno-split-cold-code' '-Dcpp_args=-Xclang -fno-split-cold-code'
-Dplatforms=macos -Dvulkan-drivers= -Dgallium-drivers=zink -Dvulkan-layers= -Dtools= -Dopengl=true -Dgles1=disabled
-Dgles2=disabled -Dglx=disabled -Degl=enabled -Dgbm=disabled -Dllvm=disabled -Dzstd=disabled -Dvalgrind=disabled
-Dlibunwind=disabled -Dlmsensors=disabled -Dperfetto=false -Dbuild-tests=false -Dxmlconfig=disabled -Dexpat=disabled
-Dspirv-tools=disabled -Dvideo-codecs= -Dgallium-va=disabled -Dvulkan-loader-rpath=/usr/local/lib`; GLFW as its patch's
message says. Everything is x86_64 and ad-hoc signed.

Licences: Mesa MIT, GLFW zlib (`src/GLFW-LICENSE.md`), Vulkan-Loader Apache-2.0 (`src/Vulkan-Loader-LICENSE.txt`), our
scripts and `src/glshim.c`, `src/egltri.c` MIT.

---

**Türkçe özet:** İsteğe bağlı bir bileşen. Bağlamını GLFW/EGL ile açan uygulamalar (Minecraft gibi LWJGL 3 oyunları),
Apple'ın OpenGL'i yerine Mesa'nın zink'iyle doğrudan Vulkan'a gidiyor; Minecraft 1.21.1'de BSL shader paketiyle zink'te
197–205 fps, aynı kartla Windows'ta 214–218 fps; shader paketi olmadan zink'te 1400–1500, Windows'ta 700–1000 fps.
`sudo ./install.sh` kurar, `sudo ./install.sh --global on` bütün LWJGL 3 uygulamaları için açar, `--global off`
kapatır, `--undo` kaldırır. Sürücünün kurulu ve `intelxe_surfvram=2` ayarının açık olması gerekiyor. CGL/NSOpenGL'i
doğrudan kullanan yerel uygulamalar yine Apple'ın OpenGL'ini kullanır. macOS'un girişte kendiliğinden yeniden açtığı
bir uygulama ayardan önce başlayıp Apple'ın OpenGL'inde kalabilir: kapatıp yeniden açın.
