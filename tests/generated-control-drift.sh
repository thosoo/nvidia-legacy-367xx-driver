#!/bin/sh
set -eu
control_before=$(mktemp)
md5_before=$(mktemp)
trap 'rm -f "$control_before" "$md5_before"' EXIT
cp debian/control "$control_before"
cp debian/control.md5sum "$md5_before"
make -f debian/rules debian/control
cmp "$control_before" debian/control
cmp "$md5_before" debian/control.md5sum
