# ACPI API reference audit

NVIDIA 367.134 directly traverses `struct acpi_device.children` and list member
`node`, and maps handles with `acpi_bus_get_device()`.  Linux 6.1/6.12 no longer
expose those internals.  Debian 390xx, Debian 340xx backports, and later NVIDIA
470+ code move this class of logic to public ACPI helpers.  ELRepo's exact
367.134 port is treated as a negative baseline where it does not modify this
API.

The selected design introduces local 367 wrappers: `nv_acpi_get_device()` uses
`acpi_fetch_acpi_dev()` when present and releases the reference with
`put_device(&adev->dev)` through `nv_acpi_put_device()`; legacy kernels retain
`acpi_bus_get_device()` without a synthetic reference release.  Child traversal
must use public child iteration (`acpi_dev_for_each_child`) when present rather
than recreating private `children` or `node` members.

Lifetime requirements: every `acpi_fetch_acpi_dev()` acquisition must be paired
with `nv_acpi_put_device()` on all success and failure paths.  Method init and
uninit must remain symmetric, and DDC traversal must not hold stale child
pointers after callback completion.
