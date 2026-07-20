#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
copyright=$repository_root/debian/copyright

if grep -F '6.3  Specific Use.' "$copyright"; then
    echo "debian/copyright contains license text absent from NVIDIA 367.134" >&2
    exit 1
fi
if grep -F "Customer's use of NVIDIA products with any other firmware" "$copyright"; then
    echo "debian/copyright contains license text absent from NVIDIA 367.134" >&2
    exit 1
fi
