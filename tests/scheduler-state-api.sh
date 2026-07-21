#!/bin/sh
set -eu
patch=debian/module/debian/patches/backport-timekeeping-scheduler-mmap-lock-api.patch
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cc=${CC:-cc}; flags='-Wall -Werror -Werror=implicit-function-declaration -Werror=incompatible-pointer-types -Werror=return-type'
cat > "$work/modern.c" <<'C'
#define TASK_INTERRUPTIBLE 1
struct task_struct { int __state; }; static struct task_struct task; struct task_struct *current = &task;
#define set_current_state(x) do { current->__state = (x); } while (0)
int main(void) { set_current_state(TASK_INTERRUPTIBLE); return current->__state == TASK_INTERRUPTIBLE ? 0 : 1; }
C
$cc $flags -c "$work/modern.c" -o "$work/modern.o"
cat > "$work/negative.c" <<'C'
#define TASK_INTERRUPTIBLE 1
struct task_struct { int __state; }; static struct task_struct task; struct task_struct *current = &task;
int main(void) { current->state = TASK_INTERRUPTIBLE; return 0; }
C
if $cc $flags -c "$work/negative.c" -o "$work/negative.o" 2>"$work/negative.err"; then exit 1; fi
! grep -F '+        current->state = TASK_INTERRUPTIBLE;' "$patch" >/dev/null
grep -F '+        set_current_state(TASK_INTERRUPTIBLE);' "$patch" >/dev/null
