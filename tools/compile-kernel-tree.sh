#!/bin/sh
set -eu
if [ "$#" -ne 2 ]; then
    echo "usage: $0 KERNEL_TREE KERNEL_HEADERS_OR_VERSION" >&2
    exit 2
fi
tree=$(readlink -f "$1")
input=$2
if [ -d "$input" ]; then
    header_dir=$(readlink -f "$input")
    case "$header_dir" in
        /lib/modules/*/build) kernel=${header_dir#/lib/modules/}; kernel=${kernel%/build} ;;
        /usr/src/linux-headers-*) kernel=${header_dir#/usr/src/linux-headers-} ;;
        *) echo "cannot infer kernel release from header path: $input" >&2; exit 1 ;;
    esac
else
    kernel=$input
    if [ -e "/lib/modules/$kernel/build" ]; then
        header_dir=$(readlink -f "/lib/modules/$kernel/build")
    elif [ -d "/usr/src/linux-headers-$kernel" ]; then
        header_dir=$(readlink -f "/usr/src/linux-headers-$kernel")
    else
        echo "kernel headers not found for: $kernel" >&2
        exit 1
    fi
fi
compiler=$(${CC:-cc} --version | sed -n '1p')
cat <<INFO
kernel=$kernel
header_dir=$header_dir
compiler=$compiler
make_command=make -C $tree NV_VERBOSE=1 KERNEL_UNAME=$kernel
module_targets=nvidia nvidia-modeset nvidia-drm nvidia-uvm
INFO
make -C "$tree" NV_VERBOSE=1 KERNEL_UNAME="$kernel"
