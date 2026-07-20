#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
patch=$repo/debian/module/debian/patches/backport-acpi-api-compat.patch

grep -F 'acpi_fetch_acpi_dev' "$patch" >/dev/null
grep -F 'acpi_dev_for_each_child' "$patch" >/dev/null
grep -F 'put_device(&device->dev)' "$patch" >/dev/null
test -f "$repo/debian/module/debian/patches/acpi-api-reference-audit.md"

# Modern ACPI traversal must use the ACPI child iterator callback API, not raw
# struct device internals or removed acpi_device child-list members.
! grep -F 'device->dev.children' "$patch" >/dev/null
! grep -F 'dev.parent' "$patch" >/dev/null
! grep -F 'list_for_each_entry(dev, &device->dev.children' "$patch" >/dev/null

grep -F 'static int nv_acpi_add_one_child(struct acpi_device *dev, void *data)' "$patch" >/dev/null
grep -F 'static int nv_acpi_find_lcd_child(struct acpi_device *dev, void *data)' "$patch" >/dev/null
grep -F 'acpi_dev_for_each_child(device, nv_acpi_add_one_child, &child_data)' "$patch" >/dev/null
grep -F 'acpi_dev_for_each_child(device, nv_acpi_find_lcd_child, &child_data)' "$patch" >/dev/null

# The public-helper port should remove the now-unused acpi_bus_get_device status
# variable from nv_acpi_methods_init(), and uninit must acquire a device before
# notifier teardown.
! grep -F '+    int retVal = -1;' "$patch" >/dev/null
grep -F '+    device = nv_acpi_get_device(nvif_parent_gpu_handle);' "$patch" >/dev/null
grep -F '+    if (device)' "$patch" >/dev/null
grep -F '+        nv_uninstall_notifier(device, nv_acpi_event);' "$patch" >/dev/null
