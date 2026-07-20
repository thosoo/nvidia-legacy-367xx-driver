#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
series=$repo/debian/module/debian/patches/series.in
active=$(mktemp)
trap 'rm -f "$active"' EXIT
sed 's/#HAS_UVM#//g' "$series" | sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' > "$active"
for inactive in \
    0071-backport-nv_vma_start_write-changes-from-570.169.patch \
    0074-backport-drm_fb_create_takes_format_info-changes-fro.patch \
    0075-backport-drm_print.h-changes-from-570.211.01.patch \
    0076-backport-nv_in_hardirq-changes-from-580.119.02.patch \
    0077-backport-vma_flags_set_word-changes-from-580.126.09.patch \
    0078-backport-vma_flags_set_word-changes-from-580.126.09-.patch \
    0079-backport-dma_map_ops_has_map_phys-changes-from-580.1.patch \
    0080-backport-for_each_-_plane_in_state-changes-from-580..patch \
    0081-support-fallback-for-for_each_-_plane_in_state.patch \
    0082-backport-for_each_-_crtc_in_state-changes-from-580.1.patch \
    0083-support-fallback-for-for_each_-_crtc_in_state.patch
do
    if grep -Fx "$inactive" "$active" >/dev/null; then
        echo "$inactive is active but is outside the Linux 6.1/6.12 target matrix" >&2
        exit 1
    fi
    grep -F "$inactive" "$series" >/dev/null
done
for required in \
    0064-backport-drm_driver_has_date-from-570.124.04.patch \
    0065-backport-ccflags-y-changes-from-570.153.02.patch \
    0066-backport-nv_timer_delete_sync-changes-from-570.153.0.patch \
    0067-backport-drm_connector_helper_funcs_mode_valid_has_c.patch \
    conftest-verbose.patch \
    use-kbuild-compiler.patch \
    use-kbuild-flags.patch \
    nvidia-use-ARCH.o_binary.patch \
    nvidia-modeset-use-ARCH.o_binary.patch
do
    grep -Fx "$required" "$active" >/dev/null
done
