#!/bin/sh
set -eu
root=${1:-.}
root=$(CDPATH= cd -- "$root" && pwd)

failures=$(mktemp)
tracked=$(mktemp)
trap 'rm -f "$failures" "$tracked"' EXIT

if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$root" ls-files > "$tracked"
else
    (cd "$root" && find . -type f -o -type d | sed 's#^./##') > "$tracked"
fi

append_matches()
{
    label=$1
    shift
    set +e
    "$@" >> "$failures"
    status=$?
    set -e
    case "$status" in
        0) ;;
        1) ;;
        *) echo "$label scan failed with status $status" >&2; exit "$status" ;;
    esac
}

# Machine-consumed package metadata must never name the 390xx source/packages.
metadata_files=$(mktemp)
trap 'rm -f "$failures" "$tracked" "$metadata_files"' EXIT
awk '
    /^debian\/(control|control\.in|rules|rules\.defs)$/ { print; next }
    /^debian\/templates(\/|$)/ { print; next }
    /^debian\/[^/]+\.(install|links|dirs|symbols|substvars)$/ { print; next }
    /^debian\/[^/]+\.(preinst|postinst|prerm|postrm|triggers|maintscript)(\.in)?$/ { print; next }
    /^debian\/module\/debian\/(control|.*\.install|.*\.links|.*\.dirs|.*\.substvars)$/ { print; next }
' "$tracked" > "$metadata_files"

if [ -s "$metadata_files" ]; then
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        set +e
        rg -n --no-heading '(^Source:[[:space:]]*.*legacy-390xx\b|^Package:[[:space:]]*.*390xx\b|nvidia-graphics-drivers-legacy-390xx|nvidia-legacy-390xx|legacy-390xx|NVIDIA_LEGACY[[:space:]]*[:?+]?=[[:space:]]*390\b|390xx/main|legacy-390xx/main)' "$root/$file" >> "$failures"
        status=$?
        set -e
        case "$status" in 0|1) ;; *) echo "metadata scan failed for $file with status $status" >&2; exit "$status" ;; esac
    done < "$metadata_files"
fi

# Generated control snapshots and package lists are also machine-consumed.
append_matches generated-control \
    find "$root" -type f \( -name 'control' -o -name 'control.in' -o -name '*.substvars' -o -name 'binary-package-list.txt' -o -name 'source-package-list.txt' \) \
    -path '*/debian/*' -exec rg -n --no-heading \
        '(^Source:[[:space:]]*.*legacy-390xx\b|^Package:[[:space:]]*.*390xx\b|nvidia-graphics-drivers-legacy-390xx|nvidia-legacy-390xx|legacy-390xx)' {} +

# Source/binary filenames and component paths must not carry 390xx package identity.
append_matches path-name awk '
    /(^|\/)(nvidia-graphics-drivers-legacy-390xx|nvidia-legacy-390xx|legacy-390xx)(\/|$)/ ||
    /(^|\/)390xx\/main(\/|$)/ ||
    /(^|\/)[^\/]*390xx[^\/]*\.(deb|dsc|changes|buildinfo|tar\.)/ { print FILENAME ":" FNR ":" $0 }
' "$tracked"

if [ -s "$failures" ]; then
    echo 'forbidden 390xx package leakage found' >&2
    cat "$failures" >&2
    exit 1
fi
