# Sıradaki işler / Next work

Üretildi / generated: `tools/parity/next.py` (`tools/parity/build.sh`). Kaynaklar / sources: `docs/devices/b580.md`, `data/video.json`, `data/cts/runs.json` (newest run), `data/uapi.json`. Her satır kanıtını taşır; tahmin yok. Sıra hedefe göre (docs/devices/b580.md): 1 ekran, 2 3B, 3 video, 4 kararlılık; sonra çekirdek arayüzü ve gelecek hedefler.

Every line carries its evidence; nothing is estimated. Ordered by the target in docs/devices/b580.md.

## 1. Ekran / Display

Test edilmedi / not tested yet: Hot-plug; HDR, DP ses, HDCP.

## 2. 3B / 3D

| # | İş / item | Durum / status | Kanıt / evidence |
|---|---|---|---|
| 1 | Minecraft 1.21.1, OpenGL (Apple GL) | %34–36 | 160–163 fps, prod7, surfvram=2 (prod7'nin genel adres tablosu → push constant dönüşümü öncesi 144) [R prod7-20261101]; Windows aynı nokta/ayarlar 450–479 fps. Darboğaz CPU: oyun iş parçacığı örneklerinin ~%41'i Apple OpenGL, %25'i Metal eklentisi, %18'i Mesa ANV; GPU kare başına 3,25 ms [R applegl-cpu-20261101]. Oyunda kazanç vermeyen dört CPU adayı kurulmadı [R applegl-contract-audit-20261102]. Bench: seed intelxebench, 2560×1440 tam ekran, RD16, vsync kapalı. |
| 2 | OpenCL | %77,6 | Apple OpenCL 1.2 (Metal üzerinden); Geekbench 7 OpenCL 84235 [G 29.10 akşam, eski yığın]; Windows GB7 OpenCL 108544 (iş yükü dökümü: [R geekbench7-windows-20261101]; Windows GB6 OpenCL 103763). İş yükü bazında macOS ölçümü yok. Ölçüm testindeki 3,18 TFLOPS bir test artefaktı (tek bağımlı zincir, ısınmasız; tepe 13,67 TFLOPS); açığın nedeni ölçülmedi, adaylar: GPU saati/gecikme, hesaplamada adres tablosu sistem belleğinde, dispatch başına tam bariyer [R compute-gap-20261103]. |
| 3 | CTS `dEQP-VK.wsi.metal.surface.query_presentation_support` | Fail | koşu / run 2026-10-30-results3 |

Test edilmedi / not tested yet: Level Zero / oneAPI.

## 3. Video

| # | İş / item | Durum / status | Kanıt / evidence |
|---|---|---|---|
| 4 | H.264 kodlama / encode 8-bit 2160p | hedefin altında / below target | speed medium 140.3 fps / veryfast 140.3 fps / veryslow 140.2 fps; VBR bitrate deviation -0.3% .. +3.6% over 6 streams; BD-rate vs QSV same settings (PSNR-Y/VMAF) aerial -0.6%/+0.0%, drive +1.4%/+1.2%; more bits than QSV for the same PSNR; measured with the installed stack 935ef655 c7e58dba 714e989a c1178ccd (`data/video.json`) |
| 5 | HEVC çözme / decode 10-bit 4320p | hedefin altında / below target | bit-exact, dec_hevc10_4320p60 91.1 fps (md5 120/120) vs Windows 100.4 fps; slower than Windows; measured with the test stack ~/b580/codecs-dec4 (libintelxeav1dec=80732b8d) over installed 935ef655 c7e58dba 714e989a c1178ccd (`data/video.json`) |
| 6 | AV1 çözme / decode 8-bit 4320p | hedefin altında / below target | bit-exact, dec_av1_8_4320p60 125.9 fps (md5 60/60) vs Windows 155.0 fps; slower than Windows; measured with the test stack ~/b580/codecs-dec4 (libintelxeav1dec=80732b8d) over installed 935ef655 c7e58dba 714e989a c1178ccd (`data/video.json`) |
| 7 | AV1 çözme / decode 10-bit 4320p | hedefin altında / below target | bit-exact, dec_av1_10_4320p60 116.2 fps (md5 60/60) vs Windows 121.7 fps; slower than Windows; measured with the test stack ~/b580/codecs-dec4 (libintelxeav1dec=80732b8d) over installed 935ef655 c7e58dba 714e989a c1178ccd (`data/video.json`) |

## 5. Çekirdek arayüzü / Kernel interface (xe uAPI)

Bugün çalışan yazılımın kullandığı, çekirdeğimizde olmayan ögeler (ayrıntı ve tüketici satırları: [TODO.md](TODO.md)):

| # | Öge / item | Neden / why |
|---|---|---|
| 8 | `DRM_XE_QUERY_CONFIG_FLAG_HAS_PURGING_SUPPORT` | used by Mesa ANV / intel common (as run on macOS); our kernel: absent |
| 9 | `DRM_XE_GEM_CREATE_EXTENSION_SET_PROPERTY` | used by Mesa ANV / intel common (as run on macOS); our kernel: unverified |

## 6. Desteklenmeyen Vulkan özellikleri / Vulkan features reported as not supported

CTS koşusu / run 2026-10-30-results3: grup başına NotSupported sayısı (bir özelliğin eksik olduğunu gösterir, hata değildir).

| Grup / group | NotSupported |
|---|---|
| `dEQP-VK.api` | 1632 |
| `dEQP-VK.robustness` | 1395 |
| `dEQP-VK.pipeline` | 1358 |
| `dEQP-VK.renderpasses` | 695 |
| `dEQP-VK.transform_feedback` | 675 |
| `dEQP-VK.image` | 554 |
| `dEQP-VK.rasterization` | 330 |
| `dEQP-VK.wsi` | 286 |
| `dEQP-VK.synchronization` | 103 |
| `dEQP-VK.draw` | 34 |
| `dEQP-VK.conditional_rendering` | 12 |
| `dEQP-VK.descriptor_indexing` | 8 |
| `dEQP-VK.synchronization2` | 6 |

## 7. Gelecek hedefler / Future targets (xe uAPI, turuncu / orange)

| Özellik / feature | Öge sayısı / items |
|---|---|
| OpenCL / oneAPI (Intel compute-runtime) | 35 |
| GPU profiler (OA metrics, VK_KHR_performance_query) | 32 |
| native OpenGL via iris | 4 |
