# Toplexy-Builder

CI that builds the Toplexy kernel for Xiaomi **sky / parrot** (android12-5.10 GKI)
and ships flashable AnyKernel3 zips. The build mirrors the device tree's AOSP
kernel build (`kernel/xiaomi/sky`, `vendor/xiaomi/sky`) so the produced kernel
behaves like an in-ROM build — that's what keeps it bootable.

## Variants

- `VNL` — vanilla, no root solution
- `KWS` — KowSU (manual-su: off, no SUSFS)
- `KSUN` — KernelSU-Next + SUSFS (susfs4ksu)

## What the workflow needs (repos/inputs)

| Piece | Repo | Branch |
|---|---|---|
| Kernel source | `TopexGuy/kernel_xiaomi_sky` | `17` |
| Vendor modules | `TopexGuy/kernel_xiaomi_sm8450-modules` | `17` |
| Device tree (prebuilts) | `TopexGuy/device_xiaomi_sky` | `17` |
| Toolchain | AOSP clang (r416183b / r536225) | — |
| Installer | `anonytry/AnyKernel3` (AK3 fork) | `master` |
| KernelSU (KWS) | `KOWX712/KernelSU` | `master` |
| KernelSU-Next (KSUN) | `pershoot/KernelSU-Next` | `dev-susfs` |
| SUSFS (KSUN) | `simonpunk/susfs4ksu` | `gki-android12-5.10` |

All four repo/branch defaults are runtime inputs on `workflow_dispatch`; you can
point any of them elsewhere without editing the workflow.

## Secrets (Settings → Secrets and variables → Actions)

- `GIT_TOKEN` — GitHub token, Contents:Read, only for **private** kernel/device repos
- `TELEGRAM_BOT_TOKEN` — BotFather token
- `TELEGRAM_CHAT_ID` — your chat id

(`TELEGRAM_*` are optional — notifications just stop if unset.)

## What the build does (and why)

1. **Merge configs exactly like the device tree**
   `TARGET_KERNEL_CONFIG := gki_defconfig vendor/sky_GKI.config vendor/parrot_GKI.config`
   — nothing added, nothing forced. No Polly, no `-fno-semantic-interposition`,
   no LTO-mode override, no source patches. The tree's own Full-LTO + KMI stay
   untouched so module CRCs/vermagic match what the tree expects.
2. **Keep `CONFIG_LOCALVERSION="-android12-9"`** (from `parrot_GKI.config`).
   Do **not** override it: the device's *stock* `vendor_boot` ramdisk holds the
   first-stage modules and modprobe refuses modules whose vermagic differs from
   the running kernel. A custom LOCALVERSION silently breaks first-stage module
   loading → boot loop with no logs.
3. **Prebuilt dtbs + dtbo.img** are copied from the device tree
   (`prebuilts/dtbs/`, `prebuilts/dtbo.img`) — the device is
   `BOARD_INCLUDE_DTB_IN_BOOTIMG` style, so boot/dt matches the ROM exactly.
4. **Vendor modules** are built from the same external list as
   `TARGET_KERNEL_EXT_MODULES` (sm8450-modules), then all modules (in-tree +
   external) are staged via `modules_install`. **`perf_helper.ko` is dropped**
   and never ships in the zip.
5. **KernelSU / KernelSU-Next** are applied per variant; NTSYNC SELinux rules are
   injected by `selinux.sh` for KWS/KSUN.
6. **AK3 packaging**: `Image` + `dtbs/` + `dtbo.img` + staged modules →
   flashable zip. Branding is carried in the zip name + AK3 banner.

## Known boot-loop root causes (fixed in this rewrite)

The previous builder forced `CONFIG_LTO_CLANG_THIN` + Polly-style flags on a
Full-LTO tree and overrode `LOCALVERSION`/branded the kernel string. Both change
module CRCs/vermagic against the stock `vendor_boot`/`vendor_dlkm` modules and
the early-boot dtb expectations → silent boot loop (no logs: crash before
console/pstore). This rewrite removes all of that noise and builds what the ROM
itself would build.