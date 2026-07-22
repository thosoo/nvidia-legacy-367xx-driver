#!/bin/sh
set -eu
ack=no
delay=5
out=core-workqueue-runtime-$(date -u +%Y%m%dT%H%M%SZ)
while [ "$#" -gt 0 ]; do
    case "$1" in
        --acknowledge-module-load-risk) ack=yes ;;
        --delay) shift; delay=${1:?missing delay} ;;
        --output) shift; out=${1:?missing output directory} ;;
        *) echo "usage: $0 --acknowledge-module-load-risk [--delay SECONDS] [--output DIR]" >&2; exit 2 ;;
    esac
    shift
done
case "$delay" in
    ''|*[!0-9]*) echo "--delay must be a non-negative integer" >&2; exit 2 ;;
esac
if [ "$ack" != yes ]; then
    echo "refusing runtime collection without --acknowledge-module-load-risk" >&2
    exit 2
fi
mkdir -p "$out"
run() {
    name=$1; shift
    { echo "$ $*"; "$@"; } > "$out/$name.txt" 2>&1 || true
}
printf '%s\n' "$(date -u +%FT%TZ)" > "$out/timestamp-utc.txt"
run uname uname -a
run cmdline cat /proc/cmdline
run modules sh -c 'lsmod | awk '\''/^(nvidia|nouveau)/ {print}'\'''
# shellcheck disable=SC2016
run pci-binding sh -c '
for d in /sys/bus/pci/devices/*; do
    if [ -e "$d/vendor" ] && grep -qi "^0x10de" "$d/vendor"; then
        printf "%s " "${d##*/}"
        readlink "$d/driver" 2>/dev/null || true
    fi
done
'
run module-params sh -c '
find /sys/module -maxdepth 3 -path "/sys/module/nvidia*/parameters/*" -type f -print -exec cat {} \; 2>/dev/null
'
marker="codex-core-workqueue-runtime-$(date -u +%s)-$$"
printf '%s\n' "$marker" > "$out/dmesg-marker.txt"
printf '%s\n' "$(date +%s)" > "$out/baseline-epoch.txt"
if [ -w /dev/kmsg ] && printf '<5>%s\n' "$marker" > /dev/kmsg 2>/dev/null; then
    echo yes > "$out/dmesg-marker-written.txt"
else
    echo no > "$out/dmesg-marker-written.txt"
fi
dmesg > "$out/dmesg-baseline.txt" 2>&1 || true
sleep "$delay"
# shellcheck disable=SC2016
run nvidia-wq-state sh -c '
for t in /proc/[0-9]*/comm; do
    if grep -qx nvidia-wq "$t"; then
        p=${t%/comm}
        echo "PID=${p##*/}"
        cat "$p/status"
    fi
done
'
# shellcheck disable=SC2016
run refcounts sh -c '
for m in nvidia nvidia_modeset nvidia_drm nvidia_uvm nouveau; do
    if [ -d "/sys/module/$m" ]; then
        printf "%s %s\n" "$m" "$(cat "/sys/module/$m/refcnt" 2>/dev/null || echo unknown)"
    fi
done
'
dmesg > "$out/dmesg-after.txt" 2>&1 || true
awk -v marker="$marker" '
    index($0, marker) { seen=1; next }
    seen { print }
' "$out/dmesg-after.txt" > "$out/dmesg-since-baseline.txt" || true
if [ ! -s "$out/dmesg-since-baseline.txt" ]; then
    : > "$out/dmesg-since-baseline.txt"
fi
for pat in 'Flushing system-wide workqueues' 'bad frame pointer' 'unwind' 'Xid' 'adapter' 'hung task'; do
    safe=$(printf '%s\n' "$pat" | tr ' /' '__')
    grep -i "$pat" "$out/dmesg-since-baseline.txt" > "$out/dmesg-$safe.txt" 2>/dev/null || true
done
# shellcheck disable=SC2016
run final-pci-binding sh -c '
for d in /sys/bus/pci/devices/*; do
    if [ -e "$d/vendor" ] && grep -qi "^0x10de" "$d/vendor"; then
        printf "%s " "${d##*/}"
        readlink "$d/driver" 2>/dev/null || true
    fi
done
'
cat > "$out/README.txt" <<README
This collection is observational only. It does not unload modules, rebind PCI
devices, or change display-manager, initramfs, bootloader, Secure Boot,
blacklist, console log-level, or package state. Destructive unload/rebind testing
must be implemented as a separate acknowledged runner with an explicit GPU BDF
and recovery plan.
README
printf '%s\n' "$out"
