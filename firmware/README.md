# Firmware

IntelXe.kext builds two of Intel's firmware images into its binary:

| File | Version | sha256 |
|---|---|---|
| `bmg_guc_70.bin` | GuC 70.72.1 | `de81c75f46a127c33cd59f604d800e9ffc7ed3495967ba0d8767cd6985ab398b` |
| `bmg_huc.bin` | HuC 8.2.10 (GSC CPD layout) | `747452aa8c4ed7760c68a80f3d913eafde9304d6f4db481e3f2aebb0a818bf15` |

Both come from [linux-firmware](https://gitlab.com/kernel-firmware/linux-firmware) (`xe/`). They are redistributable under `LICENSE.xe`, which is copied here unmodified from linux-firmware's `LICENSES/LICENSE.xe`.

The blobs themselves are **not committed**. To get them, run:

```sh
firmware/fetch.sh                          # from linux-firmware main
LINUX_FIRMWARE_REF=<tag> firmware/fetch.sh # from a specific tag or commit
```

The script checks the sha256 values above, and `kernel/IntelXe/build.py` checks them again. If linux-firmware has moved to newer firmware, the check fails on purpose. Fetch from an older tag, or bring the kext up on the new version first.

The B580 has no GSC for HuC. The media GuC authenticates the HuC: HUC_KERNEL_LOAD_INFO reads `0x00500001` (running) after `AUTHENTICATE_HUC`.
