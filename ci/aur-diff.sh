#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
[[ $# == 2 && $1 =~ ^[a-z0-9][a-z0-9@._+-]*$ && $2 =~ ^[a-z0-9][a-z0-9._+-]*$ ]] || {
    echo 'usage: ci/aur-diff.sh <aur-pkgbase> <our-package-directory>' >&2; exit 2;
}
[[ -f packages/$2/PKGBUILD ]]
review=$(mktemp)
trap 'rm -f -- "$review"' EXIT
curl --fail --silent --show-error --location --retry 3 \
    "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=$1" -o "$review"
# diff exit 1 means a reviewable difference, not a fetch failure.
status=0
diff -u --label "ours/$2/PKGBUILD" --label "AUR/$1/PKGBUILD" \
    "packages/$2/PKGBUILD" "$review" || status=$?
(( status <= 1 ))
