# Sıradaki işler / Next work

Üretildi / generated: `tools/parity/next.py` (`tools/parity/build.sh`). Kaynaklar / sources: `docs/devices/b580.md`, `data/video.json`, `data/cts/runs.json` (newest run), `data/uapi.json`. Her satır kanıtını taşır; tahmin yok. Sıra hedefe göre (docs/devices/b580.md): 1 ekran, 2 3B, 3 video, 4 kararlılık; sonra çekirdek arayüzü ve gelecek hedefler.

Every line carries its evidence; nothing is estimated. Ordered by the target in docs/devices/b580.md.

## 1. Ekran / Display

Test edilmedi / not tested yet: Hot-plug; HDR, DP ses, HDCP.

## 2. 3B / 3D

| # | İş / item | Durum / status | Kanıt / evidence |
|---|---|---|---|
| 1 | Minecraft 1.21.1, OpenGL (Apple GL) | %35–38 | **4 Kasım (prod8 / glub1 test, aynı nokta):** kurulu prod8 162,8 fps / GPU 3,02 ms; glub1 (uniform okumaları tek blok, prod9'da varsayılan açık) 167,7 fps / **GPU 2,66 ms (−%13)**; oturum içinde fps ~%6 kaydığı için fps farkları çözünürlük altında, GPU süresi kararlı [R hackintosh-session-20261104, applegl-ubo-20261103]. Önceki: 160–163 fps, prod7, surfvram=2 (prod7'nin genel adres tablosu → push constant dönüşümü öncesi 144) [R prod7-20261101]; Windows aynı nokta/ayarlar 450–479 fps. Darboğaz CPU: oyun iş parçacığı örneklerinin ~%41'i Apple OpenGL, %25'i Metal eklentisi, %18'i Mesa ANV; GPU kare başına 3,25 ms [R applegl-cpu-20261101]. Oyunda kazanç vermeyen dört CPU adayı kurulmadı [R applegl-contract-audit-20261102]. Bench: seed b580bench, 2560×1440 tam ekran, RD16, vsync kapalı. |
| 2 | OpenCL | %79–80 | Apple OpenCL 1.2 (Metal üzerinden); Geekbench 7 OpenCL macOS 26.7.1'de IntelXe ile 85.719 / 86.920 (iki koşu, 5 Kasım), 29.10'da eski yığınla 84235; Windows GB7 OpenCL 108544 (iş yükü dökümü: [R geekbench7-windows-20261101]; Windows GB6 OpenCL 103763). İş yükü bazında macOS ölçümü yok. Ölçüm testindeki 3,18 TFLOPS bir test artefaktı (tek bağımlı zincir, ısınmasız; tepe 13,67 TFLOPS); açığın nedeni ölçülmedi, adaylar: GPU saati/gecikme, hesaplamada adres tablosu sistem belleğinde, dispatch başına tam bariyer [R compute-gap-20261103]. |
| 3 | CTS `dEQP-VK.api.driver_properties.conformance_version` | Fail | koşu / run 2026-11-04-prod9t |
| 4 | CTS `dEQP-VK.dgc.ext.graphics.misc.robust_vbo` | Fail | koşu / run 2026-11-04-prod9t |
| 5 | CTS `dEQP-VK.dgc.ext.graphics.misc.robust_vbo_preprocess` | Fail | koşu / run 2026-11-04-prod9t |
| 6 | CTS `dEQP-VK.dgc.ext.graphics.misc.robust_vbo_shader_objects` | Fail | koşu / run 2026-11-04-prod9t |
| 7 | CTS `dEQP-VK.dgc.ext.graphics.misc.robust_vbo_shader_objects_preprocess` | Fail | koşu / run 2026-11-04-prod9t |
| 8 | CTS `dEQP-VK.pipeline.fast_linked_library.multisample.conservative_with_full_coverage.overestimate.samples_2_mask_all_on` | Fail | koşu / run 2026-11-04-prod9t |
| 9 | CTS `dEQP-VK.pipeline.fast_linked_library.multisample.conservative_with_full_coverage.overestimate.samples_2_mask_half_on` | Fail | koşu / run 2026-11-04-prod9t |
| 10 | CTS `dEQP-VK.pipeline.fast_linked_library.multisample.conservative_with_full_coverage.overestimate.samples_2_plain_conservative` | Fail | koşu / run 2026-11-04-prod9t |
| 11 | CTS `dEQP-VK.pipeline.fast_linked_library.multisample.conservative_with_full_coverage.overestimate.samples_2_post_depth_coverage` | Fail | koşu / run 2026-11-04-prod9t |
| 12 | CTS `dEQP-VK.pipeline.fast_linked_library.multisample.conservative_with_full_coverage.overestimate.samples_4_mask_all_on` | Fail | koşu / run 2026-11-04-prod9t |
| 13 | CTS `dEQP-VK.pipeline.fast_linked_library.multisample.conservative_with_full_coverage.overestimate.samples_4_mask_half_on` | Fail | koşu / run 2026-11-04-prod9t |
| 14 | CTS `dEQP-VK.pipeline.fast_linked_library.multisample.conservative_with_full_coverage.overestimate.samples_4_plain_conservative` | Fail | koşu / run 2026-11-04-prod9t |
| 15 | CTS `dEQP-VK.pipeline.fast_linked_library.multisample.conservative_with_full_coverage.overestimate.samples_4_post_depth_coverage` | Fail | koşu / run 2026-11-04-prod9t |
| 16 | CTS `dEQP-VK.pipeline.fast_linked_library.multisample.conservative_with_full_coverage.overestimate.samples_8_mask_all_on` | Fail | koşu / run 2026-11-04-prod9t |
| 17 | CTS `dEQP-VK.pipeline.fast_linked_library.multisample.conservative_with_full_coverage.overestimate.samples_8_mask_half_on` | Fail | koşu / run 2026-11-04-prod9t |
| 18 | CTS `dEQP-VK.pipeline.fast_linked_library.multisample.conservative_with_full_coverage.overestimate.samples_8_plain_conservative` | Fail | koşu / run 2026-11-04-prod9t |
| 19 | CTS `dEQP-VK.pipeline.fast_linked_library.multisample.conservative_with_full_coverage.overestimate.samples_8_post_depth_coverage` | Fail | koşu / run 2026-11-04-prod9t |
| 20 | CTS `dEQP-VK.pipeline.fast_linked_library.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_2_mask_all_on` | Fail | koşu / run 2026-11-04-prod9t |
| 21 | CTS `dEQP-VK.pipeline.fast_linked_library.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_2_mask_half_on` | Fail | koşu / run 2026-11-04-prod9t |
| 22 | CTS `dEQP-VK.pipeline.fast_linked_library.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_2_plain_conservative` | Fail | koşu / run 2026-11-04-prod9t |
| 23 | CTS `dEQP-VK.pipeline.fast_linked_library.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_2_post_depth_coverage` | Fail | koşu / run 2026-11-04-prod9t |
| 24 | CTS `dEQP-VK.pipeline.fast_linked_library.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_4_mask_all_on` | Fail | koşu / run 2026-11-04-prod9t |
| 25 | CTS `dEQP-VK.pipeline.fast_linked_library.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_4_mask_half_on` | Fail | koşu / run 2026-11-04-prod9t |
| 26 | CTS `dEQP-VK.pipeline.fast_linked_library.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_4_min_0_1_0` | Fail | koşu / run 2026-11-04-prod9t |
| 27 | CTS `dEQP-VK.pipeline.fast_linked_library.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_4_min_0_25` | Fail | koşu / run 2026-11-04-prod9t |
| 28 | CTS `dEQP-VK.pipeline.fast_linked_library.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_4_min_0_75` | Fail | koşu / run 2026-11-04-prod9t |
| 29 | CTS `dEQP-VK.pipeline.fast_linked_library.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_4_plain_conservative` | Fail | koşu / run 2026-11-04-prod9t |
| 30 | CTS `dEQP-VK.pipeline.fast_linked_library.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_4_post_depth_coverage` | Fail | koşu / run 2026-11-04-prod9t |
| 31 | CTS `dEQP-VK.pipeline.monolithic.multisample.conservative_with_full_coverage.overestimate.samples_2_mask_all_on` | Fail | koşu / run 2026-11-04-prod9t |
| 32 | CTS `dEQP-VK.pipeline.monolithic.multisample.conservative_with_full_coverage.overestimate.samples_2_mask_half_on` | Fail | koşu / run 2026-11-04-prod9t |
| 33 | CTS `dEQP-VK.pipeline.monolithic.multisample.conservative_with_full_coverage.overestimate.samples_2_plain_conservative` | Fail | koşu / run 2026-11-04-prod9t |
| 34 | CTS `dEQP-VK.pipeline.monolithic.multisample.conservative_with_full_coverage.overestimate.samples_2_post_depth_coverage` | Fail | koşu / run 2026-11-04-prod9t |
| 35 | CTS `dEQP-VK.pipeline.monolithic.multisample.conservative_with_full_coverage.overestimate.samples_4_mask_all_on` | Fail | koşu / run 2026-11-04-prod9t |
| 36 | CTS `dEQP-VK.pipeline.monolithic.multisample.conservative_with_full_coverage.overestimate.samples_4_mask_half_on` | Fail | koşu / run 2026-11-04-prod9t |
| 37 | CTS `dEQP-VK.pipeline.monolithic.multisample.conservative_with_full_coverage.overestimate.samples_4_plain_conservative` | Fail | koşu / run 2026-11-04-prod9t |
| 38 | CTS `dEQP-VK.pipeline.monolithic.multisample.conservative_with_full_coverage.overestimate.samples_4_post_depth_coverage` | Fail | koşu / run 2026-11-04-prod9t |
| 39 | CTS `dEQP-VK.pipeline.monolithic.multisample.conservative_with_full_coverage.overestimate.samples_8_mask_all_on` | Fail | koşu / run 2026-11-04-prod9t |
| 40 | CTS `dEQP-VK.pipeline.monolithic.multisample.conservative_with_full_coverage.overestimate.samples_8_mask_half_on` | Fail | koşu / run 2026-11-04-prod9t |
| 41 | CTS `dEQP-VK.pipeline.monolithic.multisample.conservative_with_full_coverage.overestimate.samples_8_plain_conservative` | Fail | koşu / run 2026-11-04-prod9t |
| 42 | CTS `dEQP-VK.pipeline.monolithic.multisample.conservative_with_full_coverage.overestimate.samples_8_post_depth_coverage` | Fail | koşu / run 2026-11-04-prod9t |
| 43 | CTS `dEQP-VK.pipeline.monolithic.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_2_mask_all_on` | Fail | koşu / run 2026-11-04-prod9t |
| 44 | CTS `dEQP-VK.pipeline.monolithic.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_2_mask_half_on` | Fail | koşu / run 2026-11-04-prod9t |
| 45 | CTS `dEQP-VK.pipeline.monolithic.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_2_plain_conservative` | Fail | koşu / run 2026-11-04-prod9t |
| 46 | CTS `dEQP-VK.pipeline.monolithic.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_2_post_depth_coverage` | Fail | koşu / run 2026-11-04-prod9t |
| 47 | CTS `dEQP-VK.pipeline.monolithic.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_4_mask_all_on` | Fail | koşu / run 2026-11-04-prod9t |
| 48 | CTS `dEQP-VK.pipeline.monolithic.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_4_mask_half_on` | Fail | koşu / run 2026-11-04-prod9t |
| 49 | CTS `dEQP-VK.pipeline.monolithic.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_4_min_0_1_0` | Fail | koşu / run 2026-11-04-prod9t |
| 50 | CTS `dEQP-VK.pipeline.monolithic.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_4_min_0_25` | Fail | koşu / run 2026-11-04-prod9t |
| 51 | CTS `dEQP-VK.pipeline.monolithic.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_4_min_0_75` | Fail | koşu / run 2026-11-04-prod9t |
| 52 | CTS `dEQP-VK.pipeline.monolithic.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_4_plain_conservative` | Fail | koşu / run 2026-11-04-prod9t |
| 53 | CTS `dEQP-VK.pipeline.monolithic.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_4_post_depth_coverage` | Fail | koşu / run 2026-11-04-prod9t |
| 54 | CTS `dEQP-VK.pipeline.pipeline_library.multisample.conservative_with_full_coverage.overestimate.samples_2_mask_all_on` | Fail | koşu / run 2026-11-04-prod9t |
| 55 | CTS `dEQP-VK.pipeline.pipeline_library.multisample.conservative_with_full_coverage.overestimate.samples_2_mask_half_on` | Fail | koşu / run 2026-11-04-prod9t |
| 56 | CTS `dEQP-VK.pipeline.pipeline_library.multisample.conservative_with_full_coverage.overestimate.samples_2_plain_conservative` | Fail | koşu / run 2026-11-04-prod9t |
| 57 | CTS `dEQP-VK.pipeline.pipeline_library.multisample.conservative_with_full_coverage.overestimate.samples_2_post_depth_coverage` | Fail | koşu / run 2026-11-04-prod9t |
| 58 | CTS `dEQP-VK.pipeline.pipeline_library.multisample.conservative_with_full_coverage.overestimate.samples_4_mask_all_on` | Fail | koşu / run 2026-11-04-prod9t |
| 59 | CTS `dEQP-VK.pipeline.pipeline_library.multisample.conservative_with_full_coverage.overestimate.samples_4_mask_half_on` | Fail | koşu / run 2026-11-04-prod9t |
| 60 | CTS `dEQP-VK.pipeline.pipeline_library.multisample.conservative_with_full_coverage.overestimate.samples_4_plain_conservative` | Fail | koşu / run 2026-11-04-prod9t |
| 61 | CTS `dEQP-VK.pipeline.pipeline_library.multisample.conservative_with_full_coverage.overestimate.samples_4_post_depth_coverage` | Fail | koşu / run 2026-11-04-prod9t |
| 62 | CTS `dEQP-VK.pipeline.pipeline_library.multisample.conservative_with_full_coverage.overestimate.samples_8_mask_all_on` | Fail | koşu / run 2026-11-04-prod9t |
| 63 | CTS `dEQP-VK.pipeline.pipeline_library.multisample.conservative_with_full_coverage.overestimate.samples_8_mask_half_on` | Fail | koşu / run 2026-11-04-prod9t |
| 64 | CTS `dEQP-VK.pipeline.pipeline_library.multisample.conservative_with_full_coverage.overestimate.samples_8_plain_conservative` | Fail | koşu / run 2026-11-04-prod9t |
| 65 | CTS `dEQP-VK.pipeline.pipeline_library.multisample.conservative_with_full_coverage.overestimate.samples_8_post_depth_coverage` | Fail | koşu / run 2026-11-04-prod9t |
| 66 | CTS `dEQP-VK.pipeline.pipeline_library.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_2_mask_all_on` | Fail | koşu / run 2026-11-04-prod9t |
| 67 | CTS `dEQP-VK.pipeline.pipeline_library.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_2_mask_half_on` | Fail | koşu / run 2026-11-04-prod9t |
| 68 | CTS `dEQP-VK.pipeline.pipeline_library.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_2_plain_conservative` | Fail | koşu / run 2026-11-04-prod9t |
| 69 | CTS `dEQP-VK.pipeline.pipeline_library.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_2_post_depth_coverage` | Fail | koşu / run 2026-11-04-prod9t |
| 70 | CTS `dEQP-VK.pipeline.pipeline_library.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_4_mask_all_on` | Fail | koşu / run 2026-11-04-prod9t |
| 71 | CTS `dEQP-VK.pipeline.pipeline_library.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_4_mask_half_on` | Fail | koşu / run 2026-11-04-prod9t |
| 72 | CTS `dEQP-VK.pipeline.pipeline_library.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_4_min_0_1_0` | Fail | koşu / run 2026-11-04-prod9t |
| 73 | CTS `dEQP-VK.pipeline.pipeline_library.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_4_min_0_25` | Fail | koşu / run 2026-11-04-prod9t |
| 74 | CTS `dEQP-VK.pipeline.pipeline_library.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_4_min_0_75` | Fail | koşu / run 2026-11-04-prod9t |
| 75 | CTS `dEQP-VK.pipeline.pipeline_library.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_4_plain_conservative` | Fail | koşu / run 2026-11-04-prod9t |
| 76 | CTS `dEQP-VK.pipeline.pipeline_library.multisample_with_fragment_shading_rate.conservative_with_full_coverage.overestimate.samples_4_post_depth_coverage` | Fail | koşu / run 2026-11-04-prod9t |
| 77 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_1_count_262128_comp` | Timeout | koşu / run 2026-11-04-prod9t |
| 78 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_1_count_262128_encode_decoration_comp` | Timeout | koşu / run 2026-11-04-prod9t |
| 79 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_1_count_262128_encode_decoration_force_spec_count_comp` | Timeout | koşu / run 2026-11-04-prod9t |
| 80 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_1_count_262128_encode_decoration_force_spec_count_force_spec_data_comp` | Timeout | koşu / run 2026-11-04-prod9t |
| 81 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_1_count_262128_encode_decoration_force_spec_count_force_spec_data_frag` | Timeout | koşu / run 2026-11-04-prod9t |
| 82 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_1_count_262128_encode_decoration_force_spec_count_frag` | Timeout | koşu / run 2026-11-04-prod9t |
| 83 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_1_count_262128_encode_decoration_force_spec_data_comp` | Timeout | koşu / run 2026-11-04-prod9t |
| 84 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_1_count_262128_encode_decoration_force_spec_data_frag` | Timeout | koşu / run 2026-11-04-prod9t |
| 85 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_1_count_262128_encode_decoration_frag` | Timeout | koşu / run 2026-11-04-prod9t |
| 86 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_1_count_262128_force_spec_count_comp` | Timeout | koşu / run 2026-11-04-prod9t |
| 87 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_1_count_262128_force_spec_count_force_spec_data_comp` | Timeout | koşu / run 2026-11-04-prod9t |
| 88 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_1_count_262128_force_spec_count_force_spec_data_frag` | Timeout | koşu / run 2026-11-04-prod9t |
| 89 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_1_count_262128_force_spec_count_frag` | Timeout | koşu / run 2026-11-04-prod9t |
| 90 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_1_count_262128_force_spec_data_comp` | Timeout | koşu / run 2026-11-04-prod9t |
| 91 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_1_count_262128_force_spec_data_frag` | Timeout | koşu / run 2026-11-04-prod9t |
| 92 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_1_count_262128_frag` | Timeout | koşu / run 2026-11-04-prod9t |
| 93 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_2_count_131064_comp` | Timeout | koşu / run 2026-11-04-prod9t |
| 94 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_2_count_131064_force_spec_count_comp` | Timeout | koşu / run 2026-11-04-prod9t |
| 95 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_2_count_131064_force_spec_count_force_spec_data_comp` | Timeout | koşu / run 2026-11-04-prod9t |
| 96 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_2_count_131064_force_spec_count_force_spec_data_frag` | Timeout | koşu / run 2026-11-04-prod9t |
| 97 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_2_count_131064_force_spec_count_frag` | Timeout | koşu / run 2026-11-04-prod9t |
| 98 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_2_count_131064_force_spec_data_comp` | Timeout | koşu / run 2026-11-04-prod9t |
| 99 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_2_count_131064_force_spec_data_frag` | Timeout | koşu / run 2026-11-04-prod9t |
| 100 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_2_count_131064_frag` | Timeout | koşu / run 2026-11-04-prod9t |
| 101 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_4_count_65532_comp` | Timeout | koşu / run 2026-11-04-prod9t |
| 102 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_4_count_65532_force_spec_count_comp` | Timeout | koşu / run 2026-11-04-prod9t |
| 103 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_4_count_65532_force_spec_count_force_spec_data_comp` | Timeout | koşu / run 2026-11-04-prod9t |
| 104 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_4_count_65532_force_spec_count_force_spec_data_frag` | Timeout | koşu / run 2026-11-04-prod9t |
| 105 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_4_count_65532_force_spec_count_frag` | Timeout | koşu / run 2026-11-04-prod9t |
| 106 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_4_count_65532_force_spec_data_comp` | Timeout | koşu / run 2026-11-04-prod9t |
| 107 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_4_count_65532_force_spec_data_frag` | Timeout | koşu / run 2026-11-04-prod9t |
| 108 | CTS `dEQP-VK.spirv_assembly.constant_data.basic.width_4_count_65532_frag` | Timeout | koşu / run 2026-11-04-prod9t |
| 109 | CTS `dEQP-VK.spirv_assembly.constant_data.specialization.count_and_data.width_1_decl_127_actual_262128_comp` | Timeout | koşu / run 2026-11-04-prod9t |
| 110 | CTS `dEQP-VK.spirv_assembly.constant_data.specialization.count_and_data.width_1_decl_127_actual_262128_frag` | Timeout | koşu / run 2026-11-04-prod9t |
| 111 | CTS `dEQP-VK.spirv_assembly.constant_data.specialization.count_and_data.width_1_decl_128_actual_262128_comp` | Timeout | koşu / run 2026-11-04-prod9t |
| 112 | CTS `dEQP-VK.spirv_assembly.constant_data.specialization.count_and_data.width_1_decl_128_actual_262128_frag` | Timeout | koşu / run 2026-11-04-prod9t |
| 113 | CTS `dEQP-VK.spirv_assembly.constant_data.specialization.count_and_data.width_1_decl_129_actual_262128_comp` | Timeout | koşu / run 2026-11-04-prod9t |
| 114 | CTS `dEQP-VK.spirv_assembly.constant_data.specialization.count_and_data.width_1_decl_129_actual_262128_frag` | Timeout | koşu / run 2026-11-04-prod9t |
| 115 | CTS `dEQP-VK.spirv_assembly.constant_data.specialization.count_and_data.width_1_decl_130_actual_262128_comp` | Timeout | koşu / run 2026-11-04-prod9t |
| 116 | CTS `dEQP-VK.spirv_assembly.constant_data.specialization.count_and_data.width_1_decl_130_actual_262128_frag` | Timeout | koşu / run 2026-11-04-prod9t |
| 117 | CTS `dEQP-VK.spirv_assembly.constant_data.specialization.count_and_data.width_1_decl_1_actual_262128_comp` | Timeout | koşu / run 2026-11-04-prod9t |
| 118 | CTS `dEQP-VK.spirv_assembly.constant_data.specialization.count_and_data.width_1_decl_1_actual_262128_frag` | Timeout | koşu / run 2026-11-04-prod9t |
| 119 | CTS `dEQP-VK.spirv_assembly.constant_data.specialization.count_and_data.width_1_decl_262128_actual_262128_comp` | Timeout | koşu / run 2026-11-04-prod9t |
| 120 | CTS `dEQP-VK.spirv_assembly.constant_data.specialization.count_and_data.width_1_decl_262128_actual_262128_frag` | Timeout | koşu / run 2026-11-04-prod9t |
| 121 | CTS `dEQP-VK.spirv_assembly.constant_data.specialization.count_and_data.width_1_decl_2_actual_262128_comp` | Timeout | koşu / run 2026-11-04-prod9t |
| 122 | CTS `dEQP-VK.spirv_assembly.constant_data.specialization.count_and_data.width_1_decl_2_actual_262128_frag` | Timeout | koşu / run 2026-11-04-prod9t |
| 123 | CTS `dEQP-VK.spirv_assembly.constant_data.specialization.count_and_data.width_1_decl_32_actual_262128_comp` | Timeout | koşu / run 2026-11-04-prod9t |
| 124 | CTS `dEQP-VK.spirv_assembly.constant_data.specialization.count_and_data.width_1_decl_32_actual_262128_frag` | Timeout | koşu / run 2026-11-04-prod9t |
| 125 | CTS `dEQP-VK.spirv_assembly.constant_data.specialization.count_and_data.width_1_decl_33_actual_262128_comp` | Timeout | koşu / run 2026-11-04-prod9t |
| 126 | CTS `dEQP-VK.spirv_assembly.constant_data.specialization.count_and_data.width_1_decl_33_actual_262128_frag` | Timeout | koşu / run 2026-11-04-prod9t |
| 127 | CTS `dEQP-VK.synchronization.timeline_semaphore.wait.all_signal_from_device` | Fail | koşu / run 2026-11-04-prod9t |
| 128 | CTS `dEQP-VK.synchronization.timeline_semaphore.wait.all_signal_from_host` | Fail | koşu / run 2026-11-04-prod9t |
| 129 | CTS `dEQP-VK.synchronization.timeline_semaphore.wait.one_signal_from_device` | Fail | koşu / run 2026-11-04-prod9t |
| 130 | CTS `dEQP-VK.synchronization.timeline_semaphore.wait.one_signal_from_host` | Fail | koşu / run 2026-11-04-prod9t |
| 131 | CTS `dEQP-VK.synchronization2.timeline_semaphore.wait.all_signal_from_device` | Fail | koşu / run 2026-11-04-prod9t |
| 132 | CTS `dEQP-VK.synchronization2.timeline_semaphore.wait.all_signal_from_host` | Fail | koşu / run 2026-11-04-prod9t |
| 133 | CTS `dEQP-VK.synchronization2.timeline_semaphore.wait.one_signal_from_device` | Fail | koşu / run 2026-11-04-prod9t |
| 134 | CTS `dEQP-VK.synchronization2.timeline_semaphore.wait.one_signal_from_host` | Fail | koşu / run 2026-11-04-prod9t |
| 135 | CTS `dEQP-VK.wsi.headless.surface.query_presentation_support` | Fail | koşu / run 2026-11-04-prod9t |
| 136 | CTS `dEQP-VK.wsi.metal.surface.query_presentation_support` | Fail | koşu / run 2026-11-04-prod9t |

Test edilmedi / not tested yet: Level Zero / oneAPI.

## 3. Video

| # | İş / item | Durum / status | Kanıt / evidence |
|---|---|---|---|
| 137 | H.264 kodlama / encode 8-bit 2160p | hedefin altında / below target | speed medium 140.6 fps / veryfast 190.5 fps / veryslow 48.4 fps; VBR bitrate deviation -0.3% .. +3.6% over 6 streams; BD-rate vs QSV same settings (PSNR-Y/VMAF) aerial -0.6%/+0.0%, drive +1.4%/+1.2%; more bits than QSV for the same PSNR; measured with the installed stack a7021b7e ecf35ee7 714e989a 80732b8d (`data/video.json`) |
| 138 | HEVC çözme / decode 10-bit 4320p | hedefin altında / below target | bit-exact, dec_hevc10_4320p60 91.2 fps (md5 120/120) vs Windows 100.4 fps; slower than Windows; measured with the installed stack a7021b7e ecf35ee7 714e989a 80732b8d (`data/video.json`) |
| 139 | AV1 çözme / decode 8-bit 4320p | hedefin altında / below target | bit-exact, dec_av1_8_4320p60 126.6 fps (md5 60/60) vs Windows 155.0 fps; slower than Windows; measured with the installed stack a7021b7e ecf35ee7 714e989a 80732b8d (`data/video.json`) |
| 140 | AV1 çözme / decode 10-bit 4320p | hedefin altında / below target | bit-exact, dec_av1_10_4320p60 116.4 fps (md5 60/60) vs Windows 121.7 fps; slower than Windows; measured with the installed stack a7021b7e ecf35ee7 714e989a 80732b8d (`data/video.json`) |

## 5. Çekirdek arayüzü / Kernel interface (xe uAPI)

Bugün çalışan yazılımın kullandığı, çekirdeğimizde olmayan ögeler (ayrıntı ve tüketici satırları: [TODO.md](TODO.md)):

| # | Öge / item | Neden / why |
|---|---|---|
| 141 | `DRM_XE_QUERY_CONFIG_FLAG_HAS_PURGING_SUPPORT` | used by Mesa ANV / intel common (as run on macOS); our kernel: absent |
| 142 | `DRM_XE_GEM_CREATE_EXTENSION_SET_PROPERTY` | used by Mesa ANV / intel common (as run on macOS); our kernel: unverified |

## 6. Desteklenmeyen Vulkan özellikleri / Vulkan features reported as not supported

CTS koşusu / run 2026-11-04-prod9t: grup başına NotSupported sayısı (bir özelliğin eksik olduğunu gösterir, hata değildir).

| Grup / group | NotSupported |
|---|---|
| `dEQP-VK.pipeline` | 420891 |
| `dEQP-VK.shader_object` | 170186 |
| `dEQP-VK.api` | 140533 |
| `dEQP-VK.transform_feedback` | 81426 |
| `dEQP-VK.image` | 57129 |
| `dEQP-VK.fragment_shading_rate` | 56357 |
| `dEQP-VK.cooperative_vector` | 53562 |
| `dEQP-VK.ycbcr` | 51828 |
| `dEQP-VK.compute` | 50211 |
| `dEQP-VK.synchronization2` | 36745 |
| `dEQP-VK.wsi` | 36505 |
| `dEQP-VK.synchronization` | 31810 |
| `dEQP-VK.ray_query` | 26779 |
| `dEQP-VK.renderpasses` | 24497 |
| `dEQP-VK.subgroups` | 21865 |

## 7. Gelecek hedefler / Future targets (xe uAPI, turuncu / orange)

| Özellik / feature | Öge sayısı / items |
|---|---|
| OpenCL / oneAPI (Intel compute-runtime) | 35 |
| GPU profiler (OA metrics, VK_KHR_performance_query) | 32 |
| native OpenGL via iris | 4 |
