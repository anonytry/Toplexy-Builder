#!/usr/bin/env bash
# selinux.sh
# SELinux rule injections for NTSYNC
# Sourced by build.sh — must be called from inside $KSRC
# Author: GrayRavens Team

SELINUX_RULES_C="drivers/kernelsu/selinux/rules.c"

# Sanity check — gracefully skip if KernelSU isn't installed
if [[ ! -f "$SELINUX_RULES_C" ]]; then
    echo "selinux.sh: $SELINUX_RULES_C not found — KernelSU not installed, skipping SELinux injection."
    return 0
fi

inject_selinux() {
    local label="$1"
    local rules="$2"
    echo "Injecting ${label} SELinux rules..."
    sed -i "/rcu_assign_pointer(selinux_state.policy, pol);/i ${rules}" \
        "$SELINUX_RULES_C"
}

# ---------------------------------------------------------------------------
# NTSYNC — Allow kernel worker to chmod and relabel /dev/ntsync
#         Allow Winlator (untrusted_app) to use /dev/ntsync
# ---------------------------------------------------------------------------
inject_selinux "NTSYNC" \
' ksu_allow(db, "kernel", "device", "chr_file", "setattr");\
ksu_allow(db, "kernel", "device", "chr_file", "relabelfrom");\
ksu_allow(db, "kernel", "gpu_device", "chr_file", "relabelto");\
ksu_allow(db, "kernel", "gpu_device", "chr_file", "setattr");\
ksu_allow(db, "untrusted_app", "gpu_device", "chr_file", "read");\
ksu_allow(db, "untrusted_app", "gpu_device", "chr_file", "write");\
ksu_allow(db, "untrusted_app", "gpu_device", "chr_file", "open");\
ksu_allow(db, "untrusted_app", "gpu_device", "chr_file", "ioctl");\
ksu_allow(db, "untrusted_app", "gpu_device", "chr_file", "map");\
'
