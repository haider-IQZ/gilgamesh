# Same remote-source requirements as ci/check-sources.py, using base-devel's awk.
$2 == "=" {
    key=$1
    if (key ~ /^source(_.*)?$/) {
        suffix=substr(key, 7)
        source[suffix, ++sources[suffix]]=$3
    }
    if (key ~ /^(md5|sha1|sha224|sha256|sha384|sha512|b2)sums(_.*)?$/) {
        suffix=key; sub(/^[^_]+/, "", suffix)
        hashes[key, ++counts[key]]=$3
        endings[key]=suffix
    }
}
END {
    for (key in counts) if (counts[key] != sources[endings[key]]) {
        print "source policy: checksum count mismatch" > "/dev/stderr"; failed=1
    }
    for (suffix in sources) for (i=1; i<=sources[suffix]; i++) {
        url=source[suffix, i]; sub(/^.*::/, "", url)
        if (url !~ /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\// || url ~ /^(git|svn|hg|bzr|fossil)(\+[^:]+)?:\/\//) continue
        strong=0
        for (key in counts) if (endings[key] == suffix) {
            hash=hashes[key, i]
            if (hash == "SKIP") failed=1
            if (hash ~ /^[0-9a-fA-F]+$/ && length(hash) >= 64 && length(hash) <= 128) strong=1
        }
        if (!strong) failed=1
    }
    if (failed) print "source policy: remote sources require SHA-256 or stronger, without SKIP" > "/dev/stderr"
    exit failed
}
