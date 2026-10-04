#!/usr/bin/env bash
set -Eeuo pipefail
# Called as container root with evaluated .SRCINFO, before kernel compilation.
info=${1:?usage: preflight.sh .SRCINFO input-cache output-repo}
cache=${2:?}
repo=${3:?}
mapfile -t deps < <(awk '$1 ~ /^(make)?depends$/ && $3 ~ /^nvidia-(utils|open-dkms)=/ {print $3}' "$info" | sort -u)
[[ ${#deps[@]} == 2 ]] || { echo 'NVIDIA: both exact driver dependencies are required' >&2; exit 1; }
if ! pacman -Sp --noconfirm --print-format '%n %v' "${deps[@]}"; then
    echo 'NVIDIA: pinned inputs unavailable; bootstrap through CI update mode, then use the updated recipe' >&2
    exit 1
fi
mkdir -p "$cache"
# Install and retain both signed official inputs now; later builds need no new download.
# pacman downloads as its unprivileged DownloadUser, which can't enter the private run
# directory under /work, so download into a container-local cache and copy from there.
fetch=/var/cache/gilgamesh-inputs
install -d -m 0755 "$fetch"
pacman -S --needed --noconfirm --cachedir "$fetch" "${deps[@]}"
pacman -Sw --noconfirm --cachedir "$fetch" "${deps[@]}"
cp -- "$fetch"/nvidia-*.pkg.tar.zst* "$cache"/
for name in nvidia-utils nvidia-open-dkms; do
    found=0
    for archive in "$cache/$name-"*.pkg.tar.zst; do
        [[ -f $archive ]] || continue
        actual=$(bsdtar -xOf "$archive" .PKGINFO | awk '$1 == "pkgname" {print $3}')
        [[ $actual == "$name" ]] || continue
        target=$repo/${archive##*/}
        if [[ -e $target ]]; then
            cmp -s "$archive" "$target" || { echo "NVIDIA: conflicting input archive: $target" >&2; exit 1; }
        else cp -- "$archive" "$target"; fi
        [[ ! -f $archive.sig ]] || cp -- "$archive.sig" "$target.sig"
        found=1
    done
    ((found)) || { echo "NVIDIA: missing retained $name archive" >&2; exit 1; }
done
