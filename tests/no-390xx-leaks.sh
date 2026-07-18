#!/bin/sh
set -eu
files=""
for f in debian README.md CONTRIBUTING.md tests; do
    if [ -e "$f" ]; then
        files="$files $f"
    else
        echo "expected path missing: $f" >&2
        exit 2
    fi
done
set +e
# Provenance files may mention the Debian 390xx baseline; generated packaging must not keep 390xx names.
rg -n '390xx|390\.157|legacy-390|nvidia-legacy-390xx|NVIDIA_LEGACY[[:space:]]*[:?+]?=[[:space:]]*390|390xx/main' \
  --glob '!debian/README.backports' \
  --glob '!debian/README.367xx-differences' \
  --glob '!debian/changelog' \
  --glob '!debian/patches/debian-changes' \
  --glob '!README.md' \
  --glob '!tests/no-390xx-leaks.sh' \
  $files
status=$?
set -e
case "$status" in
    0) echo 'forbidden 390xx leakage found' >&2; exit 1 ;;
    1) exit 0 ;;
    *) echo "ripgrep failed with status $status" >&2; exit "$status" ;;
esac
