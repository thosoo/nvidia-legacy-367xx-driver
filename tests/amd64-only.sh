#!/bin/sh
set -eu
rg -n 'Architecture:.*\b(i386|armhf|arm64|ppc64el)\b|component=.*(i386|armhf|arm64|ppc64el)|ARCH_LIST.*(i386|armhf|arm64|ppc64el)' debian/control debian/control.in debian/rules.defs debian/gbp.conf && exit 1 || exit 0
