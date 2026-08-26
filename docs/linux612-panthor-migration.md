# RK3588 Linux 6.12 / Panthor migration plan

## Decision

Use `atk_dlrk3588_linux6.12_sdk_release_v1.0.0_20260820.tar.gz` as the
Vulkan test platform. Do not install its GPU userspace libraries into the
current Debian 11 / Linux 5.10 production system: the kernel, firmware and
userspace driver must be treated as one matched stack.

The first installation target must be separate removable media. The current
production system disk must remain untouched until every hardware and
application gate below passes.

The SDK archive contains Ubuntu 24.04 and 26.04 root filesystem tarballs, but
no prebuilt `.img` image. A vendor image build is therefore required.

The included Linux 6.12 `libmali` object store contains the AArch64
`libmali-valhall-g610-g29p1.so` payload. A binary-safe extraction was verified
as a 59,620,312-byte ELF with SHA-256
`C3CB5A400C97F8656A5012EB976FD0204F8CA22D7913669A68CCD764666C1A25`; it contains
`vk_icdGetInstanceProcAddr`, `vkGetInstanceProcAddr` and `vkCreateInstance`.
This confirms that the archive carries a real G610 Vulkan userspace payload,
not merely Vulkan headers or configuration placeholders.

## Required vendor correction

Before building the Ubuntu image, edit:

```text
device/rockchip/rk3588/06_atk_dlrk3588_ubuntu_panthor_auto2mipi_2hdmi_defconfig
```

Replace:

```text
RK_TARGET_BOARD="ATK-DLRK3588"
```

with:

```text
RK_TARGET_BOARD="ATK-DLRK3588-PANTHOR"
```

This correction comes from the v1.0.0 known-issues document shipped for the
2026-08-20 SDK. The same configuration already selects
`rk3588_panthor.config`, a Panthor device tree and Ubuntu 26.04.

## Host preparation gates

1. Keep the original SDK archive unchanged.
2. Provide a native Linux or WSL ext4 build filesystem with at least 150 GiB
   free. Avoid building the SDK under `/mnt/c` or `/mnt/d`.
3. Run `scripts/preflight-linux612-sdk.ps1` before full extraction.
4. Extract the SDK into the Linux filesystem and run `./repo.sh` to materialize
   its source tree from the included local Git object store.
5. Apply only the documented target-board correction, then record the diff.
6. Build the vendor Ubuntu 26.04 Panthor image according to the matching Linux
   6.12 SDK documentation.

## Non-destructive board validation order

Boot the image from separate removable media and validate in this order:

1. board identity, storage layout, networking and SSH;
2. `vulkaninfo` with the Mali-G610/Panthor device and no incompatible-driver
   error;
3. an isolated NCNN Vulkan compute smoke test;
4. the pre-trained `rife-ncnn-vulkan` interpolation path;
5. the existing RKNN2 Real-ESRGAN model and runtime;
6. MPP hardware decode/encode and MP4/AAC muxing;
7. RGA availability;
8. photo API and web service rehearsal without public traffic;
9. thermal, memory and stability soak tests.

Only after all gates pass should production data and services be migrated.
Keep a bootable copy of the current system and a documented rollback path.
