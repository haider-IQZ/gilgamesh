#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=lib.sh
source /work/build/lib.sh
work=${GILGAMESH_ISO_WORK:?}
mapfile -d '' -t images < <(find "$work" -type f -name initramfs-linux.img -print0)
mapfile -d '' -t kernels < <(find "$work" -type f -name vmlinuz-linux -print0)
((${#images[@]} && ${#kernels[@]})) || die 'stock linux boot files missing before live filesystem packaging'
for image in "${images[@]}"; do
    contents=$(lsinitcpio "$image")
    for hook in archiso archiso_loop_mnt archiso_pxe_common archiso_pxe_nbd archiso_pxe_http archiso_pxe_nfs; do
        grep -Eq "(^|/)hooks/$hook$" <<< "$contents" || die "live initramfs is missing $hook"
    done
done
exec "${GILGAMESH_MKSQUASHFS:?}" "$@"
