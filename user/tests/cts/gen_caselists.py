#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Generate deqp-vk case-list shards from the mustpass lists (deterministic stride sampling)."""
import os, re, sys, glob
MP = os.path.join(os.environ.get("VK_CTS_SRC", os.path.expanduser("~/VK-GL-CTS")),
                  "external/vulkancts/mustpass/main/vk-default")   # VK_CTS_SRC: a VK-GL-CTS checkout
OUT = sys.argv[1]
SHARD = 400
EXCL = re.compile(r"(external|win32|_fd\b|_fd_|sync_fd|opaque_fd|dma_buf|dma_heap|android|ahb|drm|ray_tracing|ray_query|video|device_group|protected|cross_instance|keyed_mutex)")

allc = []
for f in sorted(glob.glob(MP + "/**/*.txt", recursive=True)):
    allc += [l.strip() for l in open(f) if l.strip()]
allc = sorted(set(allc))

def pick(regex, maxn, excl=True):
    r = re.compile(regex)
    c = [x for x in allc if r.search(x) and not (excl and EXCL.search(x))]
    if maxn and len(c) > maxn:
        step = len(c) / maxn
        c = [c[int(i * step)] for i in range(maxn)]
    return c

P = r"^dEQP-VK\."
GROUPS = [
 ("g1_basic", [(P+r"info\.", 0), (P+r"api\.info\.", 0), (P+r"api\.smoke\.", 0),
               (P+r"api\.version_check\.", 0), (P+r"api\.device_init\.", 0)]),
 ("g2_memory", [(P+r"memory\.allocation\.basic\.", 0), (P+r"memory\.mapping\.", 1200),
                (P+r"memory\.requirements\.", 0), (P+r"memory\.binding\.", 0),
                (P+r"memory\.map_placed\.", 0), (P+r"memory\.zero_initialize_device_memory\.", 150),
                (P+r"memory\.pipeline_barrier\.", 60)]),
 ("g3_sync", [(P+r"synchronization\.(basic|smoke)\.", 0), (P+r"synchronization\.timeline_semaphore\.", 700),
              (P+r"synchronization\.op\.single_queue\.", 800), (P+r"synchronization\.op\.multi_queue\.", 300),
              (P+r"synchronization\.signal_order\.", 200), (P+r"synchronization\.implicit\.", 150),
              (P+r"synchronization\.internally_synchronized", 0),
              (P+r"synchronization2\.(basic|smoke|layout_transition)\.", 0), (P+r"synchronization2\.timeline_semaphore\.", 400),
              (P+r"synchronization2\.op\.single_queue\.", 500), (P+r"synchronization2\.none_stage\.", 100)]),
 ("g4_render", [(P+r"pipeline\.monolithic\.blend\.", 1200), (P+r"pipeline\.monolithic\.depth\.", 700),
                (P+r"pipeline\.monolithic\.stencil\.", 700), (P+r"pipeline\.monolithic\.vertex_input\.", 700),
                (P+r"draw\.renderpass\.", 1500), (P+r"draw\.dynamic_rendering\.", 600),
                (P+r"renderpasses\.renderpass1\.", 1200), (P+r"renderpasses\.renderpass2\.", 800),
                (P+r"renderpasses\.dynamic_rendering\.", 800)]),
 ("g5_image", [(P+r"image\.format_reinterpret\.", 500), (P+r"image\.mutable\.", 500),
               (P+r"image\.extended_usage_bit\.", 300), (P+r"api\.copy_and_blit\.", 2000),
               (P+r"api\.image_clearing\.", 1200)]),
 ("g7_dxvk", [(P+r"transform_feedback\.simple\.", 700), (P+r"transform_feedback\.primitives_generated_query\.", 300),
              (P+r"transform_feedback\.fuzz\.", 100),
              (P+r"robustness\.robustness2\.", 1200), (P+r"robustness\.image_robustness\.", 400),
              (P+r"robustness\.buffer_access\.", 200),
              (P+r"conditional_rendering\.", 0), (P+r"query_pool\.(occlusion_query|discard|concurrent_queries)\.", 0),
              (P+r"query_pool\.statistics_query\.", 600),
              (P+r"draw\.renderpass\.indirect_draw\.", 0),
              (P+r"pipeline\.monolithic\.extended_dynamic_state\.", 1200),
              (P+r"pipeline\.monolithic\.sampler\..*custom", 400),
              (P+r"draw\.renderpass\.vertex_attribute_divisor\.", 0),
              (P+r"rasterization\.(primitives|primitives_multisample_4_bit)\.", 0),
              (P+r"descriptor_indexing\.", 0), (P+r"multiview\.", 400),
              (P+r"(depth_clip|depth_clamp)", 500)]),
 ("g6_wsi", [(P+r"wsi\.metal\.", 300)]),
 ("g2b_memory_risky", [(P+r"memory\.allocation\.random\.", 0), (P+r"memory\.pageable_allocation\.basic\.", 0)]),
]

groups_out = []
for name, pats in GROUPS:
    cases, seen = [], set()
    for rx, n in pats:
        for c in pick(rx, n):
            if c not in seen:
                seen.add(c); cases.append(c)
    shard = 150 if name == "g2b_memory_risky" else SHARD
    if name == "g2b_memory_risky": shard = 20
    d = os.path.join(OUT, name); os.makedirs(d, exist_ok=True)
    for i in range(0, len(cases), shard):
        with open(os.path.join(d, "s%03d.txt" % (i // shard)), "w") as f:
            f.write("\n".join(cases[i:i+shard]) + "\n")
    print(name, len(cases), "cases", (len(cases)+shard-1)//shard, "shards")
