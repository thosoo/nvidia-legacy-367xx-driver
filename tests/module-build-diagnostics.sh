#!/bin/sh
set -eu
script=tools/build-in-debian.sh
rg -n 'nvidia-ko-created.txt' "$script" >/dev/null
rg -n 'nvidia-modeset-ko-created.txt' "$script" >/dev/null
rg -n 'nvidia-drm-ko-created.txt' "$script" >/dev/null
rg -n 'nvidia-uvm-ko-created.txt' "$script" >/dev/null
rg -n 'modules-order-created.txt' "$script" >/dev/null
rg -n 'module-symvers-created.txt' "$script" >/dev/null
rg -n 'kernel-module-build-complete.txt' "$script" >/dev/null
rg -n 'dh-install-reached.txt' "$script" >/dev/null
rg -n 'dh-install-complete.txt' "$script" >/dev/null
rg -n 'scripts/Makefile\\.modpost' "$script" >/dev/null
rg -n 'kernel-source-tree/.+\.ko|module_name}\.ko' "$script" >/dev/null
