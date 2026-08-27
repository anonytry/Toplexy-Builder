#!/bin/bash

# GrayRavens GKI Kernel Build Script (android12-5.10 / android13-5.15)

set -e

# Error handler
trap 'echo "Build failed at line $LINENO. Exit code: $?" >&2' ERR

# ── Environment setup ────────────────────────────────────────────────────────
export ARCH=arm64
export LLVM=1
export LLVM_IAS=1
export KBUILD_BUILD_USER="GrayRavens-Team"
export KBUILD_BUILD_HOST="GrayRavens-Zenithed"

# ── Clang toolchain ──────────────────────────────────────────────────────────
if [ -z "$CLANG_PATH" ]; then
    echo "ERROR: CLANG_PATH is not set. Did you run this from the workflow?" >&2
    exit 1
fi

export PATH="${CLANG_PATH}/bin:${PATH}"

echo "CLANG_VARIANT : '${CLANG_VARIANT}'"
echo "Toolchain path : $CLANG_PATH"
echo "Clang version  : $("$CLANG_PATH/bin/clang" --version | head -n1)"

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
export KCFLAGS="-w -march=armv8.2-a+crypto+fp16+dotprod -mtune=cortex-a55 \
  -fno-semantic-interposition \
  ${POLLY_FLAGS}"

# ── SELinux policy injection ─────────────────────────────────────────────────
if [ -f "selinux.sh" ]; then
    source ./selinux.sh
else
    echo "No selinux.sh found — skipping SELinux injection."
fi

# ── Generate kernel config ───────────────────────────────────────────────────
# CROSS_COMPILE=aarch64-linux-gnu- → kernel Makefile sets --target=aarch64-linux-gnu
# Requires gcc-aarch64-linux-gnu installed for the sysroot at /usr/aarch64-linux-gnu/
echo "Generating GKI defconfig..."
make O=out HOSTCC=gcc CROSS_COMPILE=aarch64-linux-gnu- gki_defconfig

# ── Configure ThinLTO ────────────────────────────────────────────────────────
echo "Configuring ThinLTO..."
scripts/config --file out/.config \
    -e LTO_CLANG \
    -d LTO_NONE \
    -e LTO_CLANG_THIN \
    -d LTO_CLANG_FULL \
    -e THINLTO

# ── Build kernel image ───────────────────────────────────────────────────────
echo "Building kernel image..."
make -j$(nproc --all) O=out HOSTCC=gcc CROSS_COMPILE=aarch64-linux-gnu- Image

# ── Post-build vmlinux verification ─────────────────────────────────────────
echo ""
echo "=== Post-build verification ==="

echo "--- Compiler used (from vmlinux .comment) ---"
readelf -p .comment out/vmlinux 2>/dev/null \
    | grep -v "^$\|String dump" || echo "Could not read .comment"

echo "--- LTO config check ---"
grep -E "CONFIG_LTO|CONFIG_THINLTO" out/.config || echo "No LTO configs found"

echo "--- ThinLTO cache ---"
if [ -d out/.thinlto-cache ] && [ "$(ls -A out/.thinlto-cache)" ]; then
    echo "ThinLTO cache present — ThinLTO ran successfully"
    ls -lah out/.thinlto-cache/ | head -5
else
    echo "No ThinLTO cache found"
fi

echo "--- Polly flags used ---"
echo "KCFLAGS: $KCFLAGS"

echo "--- Kernel compile.h ---"
cat out/include/generated/compile.h 2>/dev/null || echo "compile.h not found"

echo "=== Verification complete ==="

# ── KMI validation ───────────────────────────────────────────────────────────
if [ "${KMI_SYMBOL_CHECK:-true}" = "true" ]; then
    echo "Running KMI validation..."
    python3 KMI_function_symbols_test.py
else
    echo "KMI symbol check disabled — skipping."
fi

echo "Build completed successfully! Toolchain: ${CLANG_VARIANT}"
