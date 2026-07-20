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
! grep -F 'nv_acpi_add_one_child_handle, NULL, &child_data, NULL' "$patch" >/dev/null
! grep -F 'nv_acpi_find_lcd_child_handle, NULL, &child_data, NULL' "$patch" >/dev/null

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

text = '\n'.join(lines)
for callback in ('nv_acpi_add_one_child_handle', 'nv_acpi_find_lcd_child_handle'):
    idx = text.find('NV_ACPI_WALK_NAMESPACE(ACPI_TYPE_DEVICE')
    found = False
    while idx != -1:
        end = text.find(';', idx)
        call = text[idx:end]
        if callback in call:
            found = True
            if 'NULL, &child_data, NULL' in call:
                raise SystemExit(f'{callback} uses raw seven-argument call shape')
            if '&child_data, NULL' not in call:
                raise SystemExit(f'{callback} does not pass normalized context/return arguments')
        idx = text.find('NV_ACPI_WALK_NAMESPACE(ACPI_TYPE_DEVICE', idx + 1)
    if not found:
        raise SystemExit(f'missing NV_ACPI_WALK_NAMESPACE call for {callback}')
PY

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/acpi-walk-wrapper.c" <<'CEOF'
typedef unsigned int u32;
typedef int acpi_status;
typedef int acpi_object_type;
typedef void *acpi_handle;
typedef acpi_status (*acpi_walk_callback)(acpi_handle, u32, void *, void **);
#define ACPI_TYPE_DEVICE 1
static acpi_status callback(acpi_handle handle, u32 nesting_level, void *context, void **return_value)
{
    (void)handle;
    (void)nesting_level;
    (void)context;
    (void)return_value;
    return 0;
}
struct context { int value; };
#if NV_ACPI_WALK_NAMESPACE_ARGUMENT_COUNT == 6
acpi_status acpi_walk_namespace(acpi_object_type type, acpi_handle start_object,
                                u32 max_depth, acpi_walk_callback user_function,
                                void *context, void **return_value)
{
    return user_function(start_object, max_depth, context, return_value) + type;
}
#define NV_ACPI_WALK_NAMESPACE(type, args...) acpi_walk_namespace(type, args)
#elif NV_ACPI_WALK_NAMESPACE_ARGUMENT_COUNT == 7
acpi_status acpi_walk_namespace(acpi_object_type type, acpi_handle start_object,
                                u32 max_depth, acpi_walk_callback user_function,
                                acpi_walk_callback ascending_callback,
                                void *context, void **return_value)
{
    (void)ascending_callback;
    return user_function(start_object, max_depth, context, return_value) + type;
}
#define NV_ACPI_WALK_NAMESPACE(type, start_object, max_depth, user_function, args...) \
    acpi_walk_namespace(type, start_object, max_depth, user_function, 0, args)
#else
#error unsupported argument count
#endif
int main(void)
{
    struct context child_data = { 0 };
    return NV_ACPI_WALK_NAMESPACE(ACPI_TYPE_DEVICE, (acpi_handle)0, 1,
                                  callback, &child_data, (void **)0);
}
CEOF
${CC:-cc} -Wall -Werror -DNV_ACPI_WALK_NAMESPACE_ARGUMENT_COUNT=6 -c "$tmp/acpi-walk-wrapper.c" -o "$tmp/acpi-walk-wrapper-6.o"
${CC:-cc} -Wall -Werror -DNV_ACPI_WALK_NAMESPACE_ARGUMENT_COUNT=7 -c "$tmp/acpi-walk-wrapper.c" -o "$tmp/acpi-walk-wrapper-7.o"
cat > "$tmp/acpi-walk-wrapper-bad.c" <<'CEOF'
typedef unsigned int u32;
typedef int acpi_status;
typedef int acpi_object_type;
typedef void *acpi_handle;
typedef acpi_status (*acpi_walk_callback)(acpi_handle, u32, void *, void **);
#define ACPI_TYPE_DEVICE 1
static acpi_status callback(acpi_handle handle, u32 nesting_level, void *context, void **return_value)
{
    (void)handle; (void)nesting_level; (void)context; (void)return_value; return 0;
}
struct context { int value; };
acpi_status acpi_walk_namespace(acpi_object_type type, acpi_handle start_object,
                                u32 max_depth, acpi_walk_callback user_function,
                                acpi_walk_callback ascending_callback,
                                void *context, void **return_value)
{
    (void)type; (void)start_object; (void)max_depth; (void)user_function;
    (void)ascending_callback; (void)context; (void)return_value; return 0;
}
#define NV_ACPI_WALK_NAMESPACE(type, start_object, max_depth, user_function, args...) \
    acpi_walk_namespace(type, start_object, max_depth, user_function, 0, args)
int main(void)
{
    struct context child_data = { 0 };
    return NV_ACPI_WALK_NAMESPACE(ACPI_TYPE_DEVICE, (acpi_handle)0, 1,
                                  callback, 0, &child_data, (void **)0);
}
CEOF
if ${CC:-cc} -Wall -Werror -c "$tmp/acpi-walk-wrapper-bad.c" -o "$tmp/acpi-walk-wrapper-bad.o" 2> "$tmp/bad.err"; then
    echo 'bad raw seven-argument ACPI walk call unexpectedly compiled' >&2
    exit 1
fi
