#!/bin/bash

# Toplexy Kernel Build Script (android12-5.10 LineageOS vendor kernel)
# Platform/config: gki (gki_defconfig) or sky/parrot (gki + sky + parrot merged).
# Variants: VNL / KWS / KSUN (KernelSU / KernelSU-Next+SUSFS)
# Must be run from inside the kernel source (msm-kernel), like the ACK build system.

set -e

# Error handler
trap 'echo "Build failed at line $LINENO. Exit code: $?" >&2' ERR

# ── Environment setup ────────────────────────────────────────────────────────
export ARCH=arm64
export LLVM=1
export LLVM_IAS=1
export KBUILD_BUILD_USER="GrayRavens-Team"
export KBUILD_BUILD_HOST="GrayRavens-Toplexy"

# ── Clang toolchain ──────────────────────────────────────────────────────────
if [ -z "$CLANG_PATH" ]; then
    echo "ERROR: CLANG_PATH is not set. Did you run this from the workflow?" >&2
    exit 1
fi
if [ -z "$CLANG_VARIANT" ]; then
    CLANG_VARIANT="CLANG-12"
fi

export PATH="${CLANG_PATH}/bin:${PATH}"

echo "CLANG_VARIANT : '${CLANG_VARIANT}'"
echo "Toolchain path : $CLANG_PATH"
echo "Clang version  : $("$CLANG_PATH/bin/clang" --version | head -n1)"

# ── Platform / config selection ──────────────────────────────────────────────
# gki          = plain gki_defconfig
# sky/parrot   = merged gki_defconfig + sky_GKI.config + parrot_GKI.config
#                (TARGET_KERNEL_CONFIG := gki_defconfig vendor/sky_GKI.config
#                                         vendor/parrot_GKI.config)
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

# ── Polly availability check ─────────────────────────────────────────────────
POLLY_FLAGS=""
if "$CLANG_PATH/bin/clang" -mllvm -polly -x c /dev/null -o /dev/null 2>/dev/null; then
    echo "Polly : available — enabling loop optimizations"
    POLLY_FLAGS="-mllvm -polly \
 -mllvm -polly-run-dce \
 -mllvm -polly-run-inliner \
 -mllvm -polly-reschedule=1 \
 -mllvm -polly-loopfusion-greedy=1 \
 -mllvm -polly-vectorizer=stripmine \
 -mllvm -polly-detect-keep-going"
else
    echo "Polly : not available in this toolchain — skipping"
fi

# ── KCFLAGS ──────────────────────────────────────────────────────────────────
export KCFLAGS="-w -fno-semantic-interposition \
  ${POLLY_FLAGS}"

# ── SELinux policy injection ─────────────────────────────────────────────────
if [ -f "selinux.sh" ]; then
    source ./selinux.sh
else
    echo "No selinux.sh found — skipping NTSYNC SELinux injection."
fi

# ── Generate kernel config (merge gki_defconfig + platform fragments) ───────
# Mirrors the device tree TARGET_KERNEL_CONFIG := gki_defconfig
# vendor/sky_GKI.config vendor/parrot_GKI.config (or plain gki_defconfig).
echo "Merging config fragments: ${FRAGMENTS}"
mkdir -p out
scripts/kconfig/merge_config.sh -m -r -y -O out ${FRAGMENTS}

echo "Refining merged config (olddefconfig)..."
make O=out HOSTCC=gcc CROSS_COMPILE=aarch64-linux-gnu- olddefconfig

# ── Configure ThinLTO ────────────────────────────────────────────────────────
echo "Configuring ThinLTO..."
scripts/config --file out/.config \
    -e LTO_CLANG \
    -d LTO_NONE \
    -e LTO_CLANG_THIN \
    -d LTO_CLANG_FULL \
    -e THINLTO
make O=out HOSTCC=gcc CROSS_COMPILE=aarch64-linux-gnu- olddefconfig

# ── Build kernel + in-tree modules ───────────────────────────────────────────
echo "Building kernel Image + modules..."
make -j$(nproc --all) O=out HOSTCC=gcc CROSS_COMPILE=aarch64-linux-gnu- Image modules

# ── Device prebuilt dtbs / dtbo.img ─────────────────────────────────────────
# dtbs/dtbo.img are NOT kbuild targets in this tree.  The device tree ships
# prebuilts (BOARD_PREBUILT_DTBIMAGE_DIR := prebuilts/dtbs,
# BOARD_PREBUILT_DTBOIMAGE := prebuilts/dtbo.img) which we copy instead.
DEVICE_DIR="${DEVICE_DIR:-$(pwd)/../device_xiaomi_sky}"
if [ -d "$DEVICE_DIR/prebuilts/dtbs" ] && [ -f "$DEVICE_DIR/prebuilts/dtbo.img" ]; then
    echo "Copying prebuilt dtbs + dtbo.img from device tree (${DEVICE_DIR})"
    mkdir -p out/arch/arm64/boot/dts/vendor/qcom
    cp "$DEVICE_DIR"/prebuilts/dtbs/*.dtb out/arch/arm64/boot/dts/vendor/qcom/
    cp "$DEVICE_DIR/prebuilts/dtbo.img" out/arch/arm64/boot/dtbo.img
else
    echo "WARNING: device prebuilt dtbs/dtbo.img not found — building dtbs via kbuild"
    make -j$(nproc --all) O=out HOSTCC=gcc CROSS_COMPILE=aarch64-linux-gnu- dtbs
fi

# ── Build external vendor modules ────────────────────────────────────────────
# EXT_MODULES: space/comma separated paths relative to MODULES_DIR (the cloned
# sm8450-modules repo). Mirrors the Lineage device tree TARGET_KERNEL_EXT_MODULES.
MODULES_DIR="${MODULES_DIR:-$(pwd)/../kernel_xiaomi_sm8450-modules}"
MODULES_STAGE="$(pwd)/out/modules_stage"
mkdir -p "$MODULES_STAGE"
if [ ! -d "$MODULES_DIR" ]; then
    echo "WARNING: MODULES_DIR '$MODULES_DIR' not found — skipping external modules"
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

    for EXT_MOD in ${EXT_MODULES}; do
        EXT_MOD_ABS="${MODULES_DIR}/${EXT_MOD}"
        if [ ! -d "$EXT_MOD_ABS" ]; then
            echo "WARNING: external module '$EXT_MOD' not found — skipping"
            continue
        fi
        EXT_MOD_REL="$(realpath --relative-to="$(pwd)" "$EXT_MOD_ABS")"
        echo "Building external module: ${EXT_MOD}"
        make -C "$EXT_MOD_ABS" M="$EXT_MOD_REL" KERNEL_SRC="$(pwd)" O="$(pwd)/out" \
            ARCH=arm64 LLVM=1 LLVM_IAS=1 modules
        make -C "$EXT_MOD_ABS" M="$EXT_MOD_REL" KERNEL_SRC="$(pwd)" O="$(pwd)/out" \
            ARCH=arm64 LLVM=1 LLVM_IAS=1 INSTALL_MOD_STRIP=1 \
            INSTALL_MOD_PATH="$MODULES_STAGE" modules_install
    done
fi

# ── Post-build verification ──────────────────────────────────────────────────
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

echo "--- Compiler used (from vmlinux .comment) ---"
readelf -p .comment out/vmlinux 2>/dev/null \
    | grep -v "^$\|String dump" || echo "Could not read .comment"

echo "--- LTO config check ---"
grep -E "CONFIG_LTO|CONFIG_THINLTO" out/.config || echo "No LTO configs found"

echo "--- Kernel release ---"
make -s O=out HOSTCC=gcc CROSS_COMPILE=aarch64-linux-gnu- kernelrelease
strings out/vmlinux 2>/dev/null | grep -m1 'Linux version' || true

echo "--- Modules ---"
MOD_COUNT=$(find out -type f -name "*.ko" 2>/dev/null | wc -l)
echo "Built .ko count: ${MOD_COUNT}"
find out -type f -name "*.ko" 2>/dev/null | head -20 || true

echo "--- Kernel compile.h ---"
cat out/include/generated/compile.h 2>/dev/null || echo "compile.h not found"
echo "=== Verification complete ==="

echo "Build completed successfully! Platform: ${PLATFORM} Toolchain: ${CLANG_VARIANT}"