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
run modules sh -c "lsmod | awk '/^(nvidia|nouveau)/ {print}'"
run pci-binding sh -c "for d in /sys/bus/pci/devices/*; do if [ -e \"$d/vendor\" ] && grep -qi '^0x10de' \"$d/vendor\"; then printf '%s ' \"${d##*/}\"; readlink \"$d/driver\" 2>/dev/null || true; fi; done"
run module-params sh -c "find /sys/module -maxdepth 2 -path '/sys/module/nvidia*/parameters/*' -type f -print -exec cat {} \; 2>/dev/null"
marker="codex-core-workqueue-runtime-$(date -u +%s)"
echo "$marker" > "$out/dmesg-marker.txt"
dmesg --console-off >/dev/null 2>&1 || true
dmesg > "$out/dmesg-before.txt" 2>&1 || true
sleep "$delay"
run nvidia-wq-state sh -c "for t in /proc/[0-9]*/comm; do if grep -qx nvidia-wq \"$t\"; then p=${t%/comm}; echo PID=${p##*/}; cat \"$p/status\"; fi; done"
run refcounts sh -c "for m in nvidia nvidia_modeset nvidia_drm nvidia_uvm nouveau; do [ -d /sys/module/$m ] && printf '%s %s\n' $m \"$(cat /sys/module/$m/refcnt 2>/dev/null || echo unknown)\"; done"
dmesg > "$out/dmesg-after.txt" 2>&1 || true
for pat in 'Flushing system-wide workqueues' 'bad frame pointer' 'unwind' 'Xid' 'adapter' 'hung task'; do
    grep -i "$pat" "$out/dmesg-after.txt" > "$out/dmesg-${pat%% *}.txt" 2>/dev/null || true
done
run final-pci-binding sh -c "for d in /sys/bus/pci/devices/*; do if [ -e \"$d/vendor\" ] && grep -qi '^0x10de' \"$d/vendor\"; then printf '%s ' \"${d##*/}\"; readlink \"$d/driver\" 2>/dev/null || true; fi; done"
cat > "$out/README.txt" <<README
This collection is diagnostic only. It did not change display-manager,
initramfs, bootloader, Secure Boot, blacklist, or package state. Review the
captured module bindings and dmesg warnings before attempting any unload/rebind.
README
printf '%s\n' "$out"
