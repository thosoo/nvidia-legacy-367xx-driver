#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
expected=$repository_root/debian/nv-readme.ids.amd64
input=${1:-}
output=${2:-}

fail()
{
    echo "$*" >&2
    exit 1
}

validate_list()
{
    list=$1
    test -s "$list" || fail "PCI ID list is empty: $list"
    count=$(wc -l < "$list")
    test "$count" -ge 100 || fail "PCI ID list has implausibly few entries: $count"
    test "$count" -le 1000 || fail "PCI ID list has implausibly many entries: $count"
    if grep -Ev '^10DE[0-9A-F]{4}$' "$list"; then
        fail "invalid PCI ID syntax in $list"
    fi
    LC_ALL=C sort -c "$list" || fail "PCI ID list is not sorted: $list"
    if [ "$(wc -l < "$list")" -ne "$(sort -u "$list" | wc -l)" ]; then
        fail "PCI ID list is not unique: $list"
    fi
    grep -Fx 10DE0FF2 "$list" >/dev/null || fail "GRID K1 PCI ID 10DE0FF2 missing from $list"
}

test -f "$expected" || fail "checked-in PCI ID baseline missing: $expected"
validate_list "$expected"

test ! -e "$repository_root/debian/nv-readme.ids.common" || \
    fail "stale split PCI ID baseline remains: $repository_root/debian/nv-readme.ids.common"

if [ -n "$input" ]; then
    if [ -d "$input" ]; then
        readme=$input/README.txt
    else
        readme=$input
    fi
    test -f "$readme" || fail "NVIDIA README not found: $readme"
    generated=$(mktemp)
    trap 'rm -f "$generated"' EXIT
    sed -r \
        -e '0,/A. Supported|APPENDIX A: SUPPORTED/d' \
        -e '0,/Appendix A. Supported|APPENDIX A: SUPPORTED/d' \
        -e '0,/^Below|APPENDIX B/{/ 0x/s/.*  0x([0-9a-fA-F]{4}).*/10de\1/p; /^(.{41}|.{49}) [0-9a-fA-F]{4} /s/^(.{41}|.{49}) ([0-9a-fA-F]{4}) .*/10de\2/p};d' \
        "$readme" | tr a-f A-F | sort -u > "$generated"
    validate_list "$generated"
    if [ -n "$output" ]; then
        output_dir=$(dirname -- "$output")
        mkdir -p "$output_dir" || fail "could not create output directory: $output_dir"
        install -m 0644 "$generated" "$output" || fail "could not write generated inventory: $output"
    fi
    cmp -s "$expected" "$generated" || {
        diff -u "$expected" "$generated" || true
        fail "generated PCI IDs differ from checked-in NVIDIA 367.134 baseline"
    }
else
    test -z "$output" || fail "OUTPUT requires an extracted NVIDIA tree or README input"
fi
