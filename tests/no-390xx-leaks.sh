#!/bin/sh
set -eu
# Provenance files may mention the Debian 390xx baseline; generated packaging must not keep 390xx names.
rg -n '390xx|390\.157|390xx/main' \
  --glob '!debian/README.backports' \
  --glob '!debian/changelog' \
  --glob '!debian/patches/debian-changes' \
  --glob '!README.md' \
  --glob '!tests/no-390xx-leaks.sh' \
  debian README.md CONTRIBUTING.md tests && exit 1 || exit 0
