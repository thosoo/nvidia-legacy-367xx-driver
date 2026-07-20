#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

make_tree()
{
    dir=$1
    mkdir -p "$dir/debian/module/debian/patches" "$dir/tests"
    cp "$repo/tests/no-390xx-leaks.sh" "$dir/tests/no-390xx-leaks.sh"
}

pass=$tmp/pass
make_tree "$pass"
cat > "$pass/debian/module/debian/patches/audit.md" <<'PASSEOF'
Compared against Debian legacy 390xx.
NVIDIA 390.157 uses the same feature probe.
PASSEOF
cat > "$pass/debian/module/debian/patches/audit.tsv" <<'PASSEOF'
family	390xx implementation
vmalloc	NVIDIA 390.157 uses a conftest
PASSEOF
cat > "$pass/debian/module/debian/patches/reference.patch" <<'PASSEOF'
Description: compatibility patch
Origin: backport, Debian 340xx and 390xx implementations
+# comment explaining a 390xx implementation
PASSEOF
cat > "$pass/README.md" <<'PASSEOF'
README provenance text: ELRepo has no corresponding 367xx fix; compared with 390xx.
PASSEOF
sh "$pass/tests/no-390xx-leaks.sh" "$pass"

fail=$tmp/fail
make_tree "$fail"
mkdir -p "$fail/debian/templates" "$fail/debian/legacy-390xx/main"
cat > "$fail/debian/control" <<'FAILEOF'
Source: nvidia-graphics-drivers-legacy-390xx
Package: nvidia-legacy-390xx-kernel-dkms
FAILEOF
cat > "$fail/debian/rules.defs" <<'FAILEOF'
NVIDIA_LEGACY := 390
FAILEOF
cat > "$fail/debian/templates/control.generated" <<'FAILEOF'
Package: nvidia-legacy-390xx-driver
FAILEOF
if sh "$fail/tests/no-390xx-leaks.sh" "$fail" >/tmp/no-390xx-regression.out 2>/tmp/no-390xx-regression.err; then
    echo "real 390xx package leakage fixture unexpectedly passed" >&2
    cat /tmp/no-390xx-regression.out /tmp/no-390xx-regression.err >&2
    exit 1
fi
