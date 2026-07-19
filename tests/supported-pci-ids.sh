#!/bin/sh
set -eu

input=${1:-}
output=${2:-}
expected=debian/nv-readme.ids.amd64

if [ -n "$input" ]; then
    if [ -d "$input" ]; then
        readme=$input/README.txt
    else
        readme=$input
    fi
    test -f "$readme"
    generated=$(mktemp)
    trap 'rm -f "$generated"' EXIT
    sed -r \
        -e '0,/A. Supported|APPENDIX A: SUPPORTED/d' \
        -e '0,/Appendix A. Supported|APPENDIX A: SUPPORTED/d' \
        -e '0,/^Below|APPENDIX B/{/ 0x/s/.*  0x([0-9a-fA-F]{4}).*/10de\1/p; /^(.{41}|.{49}) [0-9a-fA-F]{4} /s/^(.{41}|.{49}) ([0-9a-fA-F]{4}) .*/10de\2/p};d' \
        "$readme" | tr a-f A-F | sort -u > "$generated"
    if [ -n "$output" ]; then
        cp "$generated" "$output"
    fi
else
    generated=$expected
    test -z "$output"
fi

test -f "$expected"
test -s "$generated"
count=$(wc -l < "$generated")
test "$count" -ge 100
test "$count" -le 1000

if grep -Ev '^10DE[0-9A-F]{4}$' "$generated"; then
    echo "invalid PCI ID syntax" >&2
    exit 1
fi
if ! LC_ALL=C sort -c "$generated"; then
    echo "PCI ID list is not sorted" >&2
    exit 1
fi
if [ "$(wc -l < "$generated")" -ne "$(sort -u "$generated" | wc -l)" ]; then
    echo "PCI ID list is not unique" >&2
    exit 1
fi
grep -Fx 10DE0FF2 "$generated" >/dev/null

if [ -n "$input" ]; then
    cmp -s "$expected" "$generated" || {
        diff -u "$expected" "$generated" || true
        echo "generated PCI IDs differ from checked-in NVIDIA 367.134 baseline" >&2
        exit 1
    }
fi

# This fork is amd64-only; do not keep the old split baseline as active data.
test ! -e debian/nv-readme.ids.common
