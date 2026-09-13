#!/bin/bash
#
# Toplexy Kernel Build Script (android12-5.10, Xiaomi sky / parrot)
#
# Mirrors the device tree's AOSP kernel build exactly:
#   TARGET_KERNEL_CONFIG     := gki_defconfig vendor/sky_GKI.config vendor/parrot_GKI.config
#   TARGET_KERNEL_EXT_MODULES := sm8450-modules (see list below)
#   BOARD_PREBUILT_DTBIMAGE_DIR / BOARD_PREBUILT_DTBOIMAGE (device tree prebuilts)
#
# Deliberately NO custom codegen flags (no Polly, no -fno-semantic-interposition,
# no LTO mode flip) and NO source patches: android12-5.10 GKI kernels boot
# reliably only when built with the same toolchain/config the tree ships with.
# A Full-LTO stock gki_defconfig stays Full-LTO; extra flags here were the
# typical cause of silent boot loops (modules CRCs/vermagic + early codegen).
#
# Must be run from inside the kernel source (msm-kernel), like the ACK build.
#
# Variants: VNL (no root) / KWS (KowSU) / KSUN (KernelSU-Next + SUSFS)
# Platform: gki (gki_defconfig only) or sky/parrot (merged fragments, default)

set -e

trap 'echo "Build failed at line $LINENO. Exit code: $?" >&2' ERR

# ── Environment ─────────────────────────────────────────────────────────────
export ARCH=arm64
export LLVM=1
export LLVM_IAS=1
export KBUILD_BUILD_USER="GrayRavens-Team"
export KBUILD_BUILD_HOST="GrayRavens-Toplexy"

# ── Clang toolchain ─────────────────────────────────────────────────────────
if [ -z "$CLANG_PATH" ]; then
    echo "ERROR: CLANG_PATH is not set. Did you run this from the workflow?" >&2
    exit 1
fi
if [ -z "$CLANG_VARIANT" ]; then
    CLANG_VARIANT="CLANG-19"
fi

export PATH="${CLANG_PATH}/bin:${PATH}"

echo "CLANG_VARIANT : '${CLANG_VARIANT}'"
echo "Toolchain path : ${CLANG_PATH}"
echo "Clang version  : $("${CLANG_PATH}/bin/clang" --version | head -n1)"

# ── Platform / config fragments ─────────────────────────────────────────────
PLATFORM="${PLATFORM:-sky/parrot}"
case "$PLATFORM" in
    gki)
        FRAGMENTS="arch/arm64/configs/gki_defconfig"
        ;;
    sky/parrot)
        FRAGMENTS="arch/arm64/configs/gki_defconfig \
            arch/arm64/configs/vendor/sky_GKI.config \
            arch/arm64/configs/vendor/parrot_GKI.config"
        ;;
    *)
        echo "ERROR: PLATFORM must be 'gki' or 'sky/parrot' (got '${PLATFORM}')" >&2
        exit 1
        ;;
esac
for f in ${FRAGMENTS}; do
    if [ ! -f "$f" ]; then
        echo "ERROR: config fragment '${f}' not found" >&2
        exit 1
    fi
done

echo ""
echo "Platform / config : ${PLATFORM}"
echo "Fragments         : ${FRAGMENTS}"

# ── SELinux policy injection (KernelSU: VNL has none, KWS/KSUN do) ──────────
# Sourced from $PWD (kernel src); gracefully skips when KernelSU is absent.
if [ -f "selinux.sh" ]; then
    source ./selinux.sh
else
    echo "No selinux.sh found — skipping NTSYNC SELinux injection."
fi

# ── Kernel config (merge gki_defconfig + platform fragments, AOSP-style) ────
# NOTE: LOCALVERSION stays whatever the fragments define (parrot fragment ships
# CONFIG_LOCALVERSION="-android12-9"). Do NOT override it: the first-stage
# vendor_boot ramdisk modules are the stock ones and must keep a matching
# vermagic (UTS_RELEASE) or modprobe refuses to load them → silent boot loop.
echo "Merging config fragments: ${FRAGMENTS}"
mkdir -p out
scripts/kconfig/merge_config.sh -m -r -y -O out ${FRAGMENTS}

echo "Refining merged config (olddefconfig)..."
make O=out HOSTCC=gcc CROSS_COMPILE=aarch64-linux-gnu- olddefconfig

# ── Build kernel Image + in-tree modules ────────────────────────────────────
# BOARD_KERNEL_IMAGE_NAME := Image (uncompressed; CONFIG_BUILD_ARM64_UNCOMPRESSED_KERNEL=y)
echo "Building kernel Image + modules..."
make -j"$(nproc --all)" O=out HOSTCC=gcc CROSS_COMPILE=aarch64-linux-gnu- Image modules

# ── Device prebuilt dtbs / dtbo.img ─────────────────────────────────────────
# AOSP: BOARD_PREBUILT_DTBIMAGE_DIR := <device>/prebuilts/dtbs,
#       BOARD_PREBUILT_DTBOIMAGE    := <device>/prebuilts/dtbo.img
DEVICE_DIR="${DEVICE_DIR:-$(pwd)/../device_xiaomi_sky}"
if [ -d "$DEVICE_DIR/prebuilts/dtbs" ] && [ -f "$DEVICE_DIR/prebuilts/dtbo.img" ]; then
    echo "Copying prebuilt dtbs + dtbo.img from device tree (${DEVICE_DIR})"
    mkdir -p out/arch/arm64/boot/dts/vendor/qcom
    cp "$DEVICE_DIR"/prebuilts/dtbs/*.dtb out/arch/arm64/boot/dts/vendor/qcom/
    cp "$DEVICE_DIR/prebuilts/dtbo.img" out/arch/arm64/boot/dtbo.img
else
    echo "WARNING: device prebuilt dtbs/dtbo.img not found — building dtbs via kbuild"
    make -j"$(nproc --all)" O=out HOSTCC=gcc CROSS_COMPILE=aarch64-linux-gnu- dtbs
fi

# ── External vendor modules (sm8450-modules) ────────────────────────────────
# Same list as device tree TARGET_KERNEL_EXT_MODULES.
# The wrapper Makefiles reference the modules tree as "sm8450-modules" in two
# complementary ways:
#   cvp/camera/display/eva/video  KBUILD_EXTRA_SYMBOLS=$(OUT_DIR)/../sm8450-modules/... (#1)
#   dataipa Kbuild                include $(srctree)/../sm8450-modules/...          (#2)
# #1 is relative to OUT_DIR (needs the objtree output dir <kernel>/modules),
# #2 is relative to the source tree (needs the source clone). Provide both.
MODULES_DIR="${MODULES_DIR:-$(pwd)/../kernel_xiaomi_sm8450-modules}"
MODULES_STAGE="$(pwd)/out/modules_stage"
mkdir -p "$MODULES_STAGE"

if [ ! -d "$MODULES_DIR" ]; then
    echo "WARNING: MODULES_DIR '${MODULES_DIR}' not found — skipping external modules"
else
    DEFAULT_EXT_MODULES="qcom/opensource/mmrm-driver \
qcom/opensource/audio-kernel \
qcom/opensource/camera-kernel \
qcom/opensource/cvp-kernel \
qcom/opensource/dataipa/drivers/platform/msm \
qcom/opensource/datarmnet/core \
qcom/opensource/datarmnet-ext/aps \
qcom/opensource/datarmnet-ext/offload \
qcom/opensource/datarmnet-ext/shs \
qcom/opensource/datarmnet-ext/perf \
qcom/opensource/datarmnet-ext/perf_tether \
qcom/opensource/datarmnet-ext/sch \
qcom/opensource/datarmnet-ext/wlan \
qcom/opensource/display-drivers/msm \
qcom/opensource/eva-kernel \
qcom/opensource/video-driver \
qcom/opensource/wlan/qcacld-3.0/.adrastea"
    EXT_MODULES="${EXT_MODULES:-$DEFAULT_EXT_MODULES}"
    EXT_MODULES="${EXT_MODULES//,/ }"

    echo ""
    echo "External modules root : ${MODULES_DIR}"
    echo "External modules      : ${EXT_MODULES}"
    echo "Staging dir           : ${MODULES_STAGE}"

    ln -sfn "$(pwd)/modules" "$(pwd)/sm8450-modules"
    mkdir -p "$(pwd)/modules"
    ln -sfn "$MODULES_DIR" "$(pwd)/../sm8450-modules"
    EXT_MOD_OUT_DIR="$(pwd)/out"
    export OUT_DIR="${EXT_MOD_OUT_DIR}"

    for EXT_MOD in ${EXT_MODULES}; do
        EXT_MOD_ABS="${MODULES_DIR}/${EXT_MOD}"
        if [ ! -d "$EXT_MOD_ABS" ]; then
            echo "WARNING: external module '${EXT_MOD}' not found — skipping"
            continue
        fi
        EXT_MOD_REL="$(python3 -c 'import os,sys;print(os.path.relpath(sys.argv[1].rstrip("/"),sys.argv[2]))' "$EXT_MOD_ABS" "$(pwd)")"
        if grep -qE '^[[:space:]]*modules([[:space:]]|:)' "$EXT_MOD_ABS/Makefile" \
            || grep -qE '^%:' "$EXT_MOD_ABS/Makefile"; then
            MOD_GOAL="modules"
        else
            MOD_GOAL="all"
        fi
        echo "Building external module: ${EXT_MOD} (goal=${MOD_GOAL})"
        make -C "$EXT_MOD_ABS" M="$EXT_MOD_REL" OUT_DIR="${EXT_MOD_OUT_DIR}" \
            KERNEL_SRC="$(pwd)" O="$(pwd)/out" \
            ARCH=arm64 LLVM=1 LLVM_IAS=1 "${MOD_GOAL}"
        make -C "$EXT_MOD_ABS" M="$EXT_MOD_REL" OUT_DIR="${EXT_MOD_OUT_DIR}" \
            KERNEL_SRC="$(pwd)" O="$(pwd)/out" \
            ARCH=arm64 LLVM=1 LLVM_IAS=1 INSTALL_MOD_STRIP=1 \
            INSTALL_MOD_PATH="$MODULES_STAGE" modules_install
    done
fi

# ── Stage ALL modules (in-tree + external) into one place ───────────────────
# AOSP installs in-tree modules alongside vendor modules; one flat stage keeps
# the AK3 packaging simple (the AGK3 zip's do_modules handles install).
echo ""
echo "Staging in-tree modules to ${MODULES_STAGE} ..."
make O=out HOSTCC=gcc CROSS_COMPILE=aarch64-linux-gnu- \
    INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH="$MODULES_STAGE" modules_install

# perf_helper.ko is explicitly dropped (kept out of the shipped zip).
find "$MODULES_STAGE" -name 'perf_helper.ko' -delete 2>/dev/null || true

# ── Post-build verification ─────────────────────────────────────────────────
echo ""
echo "=== Post-build verification ==="

echo "--- Kernel Image ---"
if [ -f "out/arch/arm64/boot/Image" ]; then
    ls -lah out/arch/arm64/boot/Image
else
    echo "FATAL: out/arch/arm64/boot/Image missing"
    exit 1
fi

echo "--- dtbo.img ---"
if [ -f "out/arch/arm64/boot/dtbo.img" ]; then
    ls -lah out/arch/arm64/boot/dtbo.img
else
    echo "WARNING: out/arch/arm64/boot/dtbo.img not found"
fi

echo "--- dtbs ---"
ls out/arch/arm64/boot/dts/vendor/qcom/*.dtb 2>/dev/null || echo "No vendor dtbs found"

echo "--- Kernel release (do NOT override LOCALVERSION - stock modules rely on vermagic) ---"
make -s O=out HOSTCC=gcc CROSS_COMPILE=aarch64-linux-gnu- kernelrelease
strings out/vmlinux 2>/dev/null | grep -m1 'Linux version' || true

echo "--- Compiler used (from vmlinux .comment) ---"
readelf -p .comment out/vmlinux 2>/dev/null \
    | grep -v "^$\|String dump" || echo "Could not read .comment"

echo "--- LTO / KSU / LOCALVERSION config check ---"
grep -E "CONFIG_LTO|CONFIG_THINLTO|CONFIG_KSU|CONFIG_LOCALVERSION" out/.config || echo "No matching configs found"

echo "--- Modules (staged, excl. perf_helper) ---"
MOD_COUNT=$(find "$MODULES_STAGE" -type f -name "*.ko" 2>/dev/null | wc -l)
echo "Staged .ko count    : ${MOD_COUNT}"
echo "-- perf_helper.ko present? (should be 0) --"
find "$MODULES_STAGE" -name 'perf_helper.ko' 2>/dev/null | wc -l
echo "Sample .ko (first 20):"
find "$MODULES_STAGE" -type f -name "*.ko" 2>/dev/null | head -20 || true

echo "--- Kernel compile.h ---"
cat out/include/generated/compile.h 2>/dev/null || echo "compile.h not found"
echo "=== Verification complete ==="

echo "Build completed successfully! Platform: ${PLATFORM} Toolchain: ${CLANG_VARIANT}"