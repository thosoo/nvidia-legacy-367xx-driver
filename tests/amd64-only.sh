#!/bin/sh
set -eu
files=""
for f in debian/control debian/control.in debian/rules.defs debian/gbp.conf debian/tests/control debian/tests/control.in; do
    if [ -e "$f" ]; then
        files="$files $f"
    else
        echo "expected file missing: $f" >&2
        exit 2
    fi
done
set +e
# The 367.134 Debian fork is intentionally amd64-only. Permit historical
# comments and maintainer-script cleanup lists, but fail package stanzas,
# generated control, autopkgtest dependencies, and active architecture variables
# that would publish unsupported binaries.
rg -n '^(Architecture:|Tests:|Depends:|Build-Depends:).*\b(i386|armhf|arm64|ppc64el)\b|component=.*(i386|armhf|arm64|ppc64el)|^(ARCH_LIST|DRIVER_ARCH_LIST|AUTOPKGTEST_ARCH_LIST|NO_DRIVER_ARCH_LIST).*\b(i386|armhf|arm64|ppc64el)\b' $files
status=$?
set -e
case "$status" in
    0) echo 'forbidden unsupported architecture metadata found' >&2; exit 1 ;;
    1) exit 0 ;;
    *) echo "ripgrep failed with status $status" >&2; exit "$status" ;;
esac
