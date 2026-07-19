#!/bin/sh
set -eu
if [ "$#" -ne 2 ]; then
    echo "usage: $0 KERNEL_TREE KERNEL_HEADERS_OR_VERSION" >&2
    exit 2
fi
tree=$1
headers=$2
if [ -d "$headers" ]; then
    kernel=$(basename "$(dirname "$headers")")
else
    kernel=$headers
fi
make -C "$tree" NV_VERBOSE=1 KERNEL_UNAME="$kernel"
