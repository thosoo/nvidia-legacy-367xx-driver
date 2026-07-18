#!/bin/sh
set -eu
patterns='(^|/)NVIDIA-Linux-.*\.run$|\.ko(\..*)?$|\.deb$|\.dsc$|\.changes$|\.buildinfo$|\.orig.*\.tar\.|(^|/)NVIDIA-Linux-.*/|(^|/)var/lib/dkms/|(^|/)usr/src/nvidia-'
if git ls-files | rg -n "$patterns"; then
    echo 'tracked proprietary/generated artifact found' >&2
    exit 1
fi
