#!/bin/sh
set -eu
script=tools/collect-workqueue-runtime.sh
sh -n "$script"
if rg -n 'dmesg --console-off|dmesg-after\.txt.*grep|run .*sh -c "' "$script"; then
    echo 'runtime collector contains forbidden console/log-history/unquoted shell pattern' >&2
    exit 1
fi
rg -n -- '--delay must be a non-negative integer|dmesg-marker-written|dmesg-since-baseline|observational only' "$script" >/dev/null
