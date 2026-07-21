# ACPI API reference audit

NVIDIA 367.134 directly traverses `struct acpi_device.children` and list member
`node`, and maps handles with `acpi_bus_get_device()`.  Linux 6.1/6.12 no longer
expose those internals.  The newer helper direction seen in later proprietary
branches and Debian legacy ports must be filtered for external-module usability:
`acpi_fetch_acpi_dev()`, `acpi_get_acpi_dev()`, `acpi_dev_for_each_child()` and
`device_for_each_child()` are not selected here because the current Debian target
kernels do not provide them as unrestricted proprietary-module dependencies.
ELRepo's exact 367.134 port remains a negative baseline where it does not supply
an export-safe fix for this API family.

The selected 367-specific design uses existing unrestricted ACPI handle APIs.
When a compile probe proves the old `struct acpi_device.children` and `node`
fields are available, the legacy direct-list code remains for old kernels.  On
modern kernels the code walks direct child ACPI handles with `acpi_walk_namespace()`
at depth 1, stores only `acpi_handle` values, and preserves the 367.134 `_ADR`
acceptance set, display ordering, `NV_MAXNUM_DISPLAY_DEVICES` limit and
`default_display_mask` early-stop behavior.

The NVIF notifier path is handled separately from child discovery.  Modern
kernels install and remove the notifier directly by `acpi_handle` using
`acpi_install_notify_handler()` / `acpi_remove_notify_handler()`, with a private
`nv_acpi_t` context retained only by the driver.  This avoids borrowed
`struct acpi_device *` lifetime assumptions and removes the invalid
`acpi_fetch_acpi_dev()` / `put_device(&adev->dev)` pairing.  The legacy
`struct acpi_device` notifier path remains only where the driver already owns a
device from ACPI driver callbacks or where old struct members are probed present.
