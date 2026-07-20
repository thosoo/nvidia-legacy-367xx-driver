#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
patch=$repo/debian/module/debian/patches/backport-acpi-api-compat.patch

grep -F 'NV_ACPI_DEVICE_HAS_CHILDREN_AND_NODE' "$patch" >/dev/null
grep -F 'NV_ACPI_WALK_NAMESPACE(ACPI_TYPE_DEVICE' "$patch" >/dev/null
grep -F 'nv_acpi_add_one_child_handle' "$patch" >/dev/null
grep -F 'nv_acpi_find_lcd_child_handle' "$patch" >/dev/null
grep -F 'nv_install_notifier_handle' "$patch" >/dev/null
grep -F 'nv_uninstall_notifier_handle' "$patch" >/dev/null
test -f "$repo/debian/module/debian/patches/acpi-api-reference-audit.md"

# Modern ACPI must not depend on GPL-only helpers or raw struct device child
# internals. Legacy acpi_device list traversal may remain only behind the field
# existence probe.
! grep -F 'acpi_fetch_acpi_dev' "$patch" >/dev/null
! grep -F 'acpi_dev_for_each_child' "$patch" >/dev/null
! grep -F 'put_device(&device->dev)' "$patch" >/dev/null
! grep -F 'device->dev.children' "$patch" >/dev/null
! grep -F 'dev.parent' "$patch" >/dev/null

python3 - "$patch" <<'PY'
import pathlib, sys
lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
for i, line in enumerate(lines):
    if not line.startswith('+'):
        continue
    if not any(needle in line for needle in ('device->children', 'struct acpi_device, node', 'acpi_bus_get_device')):
        continue
    if 'struct list_head *children = &device->children' in line:
        continue
    window = '\n'.join(lines[max(0, i-40):i+1])
    if 'NV_ACPI_DEVICE_HAS_CHILDREN_AND_NODE' not in window:
        raise SystemExit(f'{line.strip()} is not guarded by NV_ACPI_DEVICE_HAS_CHILDREN_AND_NODE')
PY
