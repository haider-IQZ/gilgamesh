#!/usr/bin/env bash
# Sourced after the key identity has been checked; tools can be mocked offline.
validate_signing_identity() {
    local fingerprints
    fingerprints=$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1=="sec" {want=1; next} want && $1=="fpr" {print $10; want=0}')
    [[ $fingerprints == "$GILGAMESH_GPG_FINGERPRINT" ]] || {
        echo 'Signing key does not match the one pinned primary fingerprint' >&2
        return 1
    }
}

sign_repository() {
    mkdir "$GNUPGHOME/bin"
    ln -s /work/ci/gpg-loopback "$GNUPGHOME/bin/gpg"
    export PATH="$GNUPGHOME/bin:$PATH"
    cd "$1" || return
    local archive kind
    local -a archives
    while IFS= read -r archive; do
        [[ $archive =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*\.pkg\.tar\.zst$ ]] || return 1
        gpg --local-user "$GILGAMESH_GPG_FINGERPRINT" --detach-sign "$archive"
        gpg --verify "$archive.sig" "$archive"
    done < ../incoming.txt
    mapfile -t archives < ../current.txt
    (( ${#archives[@]} > 0 )) || return 1
    for archive in "${archives[@]}"; do
        [[ $archive =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*\.pkg\.tar\.zst$ ]] || return 1
        gpg --verify "$archive.sig" "$archive"
    done
    rm -f gilgamesh.files.tar.zst.sig
    repo-add --sign --verify --include-sigs --key "$GILGAMESH_GPG_FINGERPRINT" \
        gilgamesh.db.tar.zst "${archives[@]}"
    for kind in db files; do
        if [[ ! -f gilgamesh.$kind.tar.zst.sig ]]; then
            gpg --local-user "$GILGAMESH_GPG_FINGERPRINT" --detach-sign "gilgamesh.$kind.tar.zst"
        fi
        gpg --verify "gilgamesh.$kind.tar.zst.sig" "gilgamesh.$kind.tar.zst"
        rm -f "gilgamesh.$kind" "gilgamesh.$kind.sig"
        cp "gilgamesh.$kind.tar.zst" "gilgamesh.$kind"
        cp "gilgamesh.$kind.tar.zst.sig" "gilgamesh.$kind.sig"
    done
}
