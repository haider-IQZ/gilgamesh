// Return existing files in preference order. Paths stay positional arguments and NUL-delimited
// output, including when the shell directory is a symlink or contains URL punctuation.
function scanCommand(dir, request) {
    return ["sh", "-c", `
        export LC_ALL=C
        existing() { case "$1" in /*) [ -f "$1" ] ;; *) return 1 ;; esac; }
        images() {
            find "$1" -maxdepth 1 -type f \\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \\) -print0 2>/dev/null | sort -z
        }
        if [ "$5" = keep ] && existing "$3"; then printf '%s\\0' "$3"; exit 0; fi
        if existing "$4"; then printf '%s\\0' "$4"; exit 0; fi
        images "$2"
        # A theme without images keeps a valid selection on a live switch.
        if existing "$3"; then printf '%s\\0' "$3"; fi
        for folder in "$1"/*/backgrounds; do images "$folder"; done
    `, "sh", dir, request.folder, request.current, request.remembered, request.keepCurrent ? "keep" : "switch"]
}

function isCurrent(request, name, revision, id, pending, current, remembered) {
    return request && request.name === name && request.revision === revision
        && request.id === id && !pending && request.current === current
        && request.remembered === remembered
}

function firstFile(text) { return text.split("\0").find(f => f !== "") || "" }
