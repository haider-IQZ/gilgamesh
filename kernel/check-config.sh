#!/usr/bin/env bash
set -Eeuo pipefail
config=${1:?usage: check-config.sh resolved.config}
[[ -s $config ]] || { echo 'kernel: missing resolved configuration' >&2; exit 1; }
# Check resolved values, not just the requested fragment.
required_y=(
    64BIT X86_64 MODULES BLK_DEV_INITRD DEVTMPFS PCI
    VIRTIO VIRTIO_PCI VIRTIO_BLK XFS_FS
    SCHED_BORE PREEMPT PREEMPT_DYNAMIC HZ_1000 NO_HZ_IDLE LRU_GEN NUMA
    TRANSPARENT_HUGEPAGE_MADVISE HALTPOLL_CPUIDLE
    BPF BPF_SYSCALL BPF_JIT BPF_EVENTS FTRACE SCHED_CLASS_EXT
    DEBUG_INFO DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT DEBUG_INFO_BTF DEBUG_INFO_BTF_MODULES
    SYSFS TMPFS SQUASHFS_XZ
)
required_driver=(
    BLK_DEV_LOOP SQUASHFS OVERLAY_FS ISO9660_FS VFAT_FS EXT4_FS BLK_DEV_SR BLK_DEV_NBD NFS_FS
    BLK_DEV_NVME ATA SATA_AHCI SCSI BLK_DEV_SD USB_STORAGE USB_XHCI_HCD VIRTIO_NET
)
required_n=(DEBUG_INFO_NONE DEBUG_INFO_DWARF4 DEBUG_INFO_DWARF5 DEBUG_INFO_REDUCED
            DEBUG_INFO_SPLIT ZSWAP_DEFAULT_ON WQ_POWER_EFFICIENT_DEFAULT)
failed=0
for symbol in "${required_y[@]}"; do
    grep -qx "CONFIG_$symbol=y" "$config" || { echo "kernel: require CONFIG_$symbol=y" >&2; failed=1; }
done
for symbol in "${required_driver[@]}"; do
    grep -Eq "^CONFIG_$symbol=[ym]$" "$config" || { echo "kernel: require CONFIG_$symbol=y/m" >&2; failed=1; }
done
for symbol in "${required_n[@]}"; do
    if grep -Eq "^CONFIG_$symbol=[ym]$" "$config"; then
        echo "kernel: CONFIG_$symbol must be disabled" >&2; failed=1
    fi
done
exit "$failed"
