#!/bin/sh
set -eu
patch=debian/module/debian/patches/backport-uvm-core-api-compat.patch
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cc=${CC:-cc}
flags='-Wall -Werror -Werror=implicit-function-declaration -Werror=incompatible-pointer-types -Werror=return-type'
cat > "$work/modern.c" <<'C'
typedef unsigned int vm_fault_t;
struct vm_fault { int dummy; }; struct vm_area_struct { int dummy; };
#define VM_FAULT_SIGBUS ((vm_fault_t)2)
static vm_fault_t uvm_vm_fault_sigbus(struct vm_area_struct *vma, struct vm_fault *vmf) { (void)vma; (void)vmf; return VM_FAULT_SIGBUS; }
static vm_fault_t uvm_vm_fault_sigbus_wrapper(struct vm_fault *vmf) { return uvm_vm_fault_sigbus(0, vmf); }
struct vm_operations_struct { vm_fault_t (*fault)(struct vm_fault *); };
static struct vm_operations_struct ops = { .fault = uvm_vm_fault_sigbus_wrapper };
int main(void) { struct vm_fault f; return ops.fault(&f) == VM_FAULT_SIGBUS ? 0 : 1; }
C
$cc $flags -c "$work/modern.c" -o "$work/modern.o"
cat > "$work/legacy.c" <<'C'
typedef int vm_fault_t;
struct vm_fault { int dummy; }; struct vm_area_struct { int dummy; };
#define VM_FAULT_SIGBUS 2
static vm_fault_t uvm_vm_fault(struct vm_area_struct *vma, struct vm_fault *vmf) { (void)vma; (void)vmf; return VM_FAULT_SIGBUS; }
struct vm_operations_struct { vm_fault_t (*fault)(struct vm_area_struct *, struct vm_fault *); };
static struct vm_operations_struct ops = { .fault = uvm_vm_fault };
int main(void) { struct vm_fault f; return ops.fault(0, &f) == VM_FAULT_SIGBUS ? 0 : 1; }
C
$cc $flags -c "$work/legacy.c" -o "$work/legacy.o"
grep -F 'static vm_fault_t uvm_vm_fault_sigbus' "$patch" >/dev/null
grep -F 'static vm_fault_t uvm_vm_fault_wrapper' "$patch" >/dev/null
if grep -F '+static int uvm_vm_fault' "$patch" >/dev/null; then exit 1; fi
