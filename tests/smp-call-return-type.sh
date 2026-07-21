#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
patch=$repo/debian/module/debian/patches/backport-smp-call-return-types.patch
test -f "$patch"
grep -F 'NV_ON_EACH_CPU_RETURNS_INT' "$patch" >/dev/null
grep -F 'NV_SMP_CALL_FUNCTION_RETURNS_INT' "$patch" >/dev/null
! grep -F 'LINUX_VERSION_CODE' "$patch" >/dev/null
awk '
    /^\+# *define NV_(SMP_CALL_FUNCTION|ON_EACH_CPU)/ { in_macro=1; next }
    in_macro && /^\+/ && /\\$/ && /#(if|else|endif)/ { bad=1 }
    in_macro && /^\+/ && !/\\$/ { in_macro=0 }
    END { exit bad }
' "$patch"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for args in 3 4; do
    for ret in 0 1; do
        c=$tmp/$args-$ret.c
        {
            echo '#define NULL ((void *)0)'
            echo 'static void callback(void *info) { (void)info; }'
            if [ "$args" = 4 ]; then
                if [ "$ret" = 1 ]; then
                    echo 'int smp_call_function(void (*func)(void *), void *info, int retry, int wait) { func(info); return retry + wait; }'
                    echo 'int on_each_cpu(void (*func)(void *), void *info, int retry, int wait) { func(info); return retry + wait; }'
                else
                    echo 'void smp_call_function(void (*func)(void *), void *info, int retry, int wait) { func(info); (void)retry; (void)wait; }'
                    echo 'void on_each_cpu(void (*func)(void *), void *info, int retry, int wait) { func(info); (void)retry; (void)wait; }'
                fi
            else
                if [ "$ret" = 1 ]; then
                    echo 'int smp_call_function(void (*func)(void *), void *info, int wait) { func(info); return wait; }'
                    echo 'int on_each_cpu(void (*func)(void *), void *info, int wait) { func(info); return wait; }'
                else
                    echo 'void smp_call_function(void (*func)(void *), void *info, int wait) { func(info); (void)wait; }'
                    echo 'void on_each_cpu(void (*func)(void *), void *info, int wait) { func(info); (void)wait; }'
                fi
            fi
            if [ "$args" = 4 ]; then
                if [ "$ret" = 1 ]; then
                    echo '#define NV_SMP_CALL_FUNCTION(func, info, wait) ({ int __ret = smp_call_function(func, info, 1, wait); __ret; })'
                    echo '#define NV_ON_EACH_CPU(func, info, wait) ({ int __ret = on_each_cpu(func, info, 1, wait); __ret; })'
                else
                    echo '#define NV_SMP_CALL_FUNCTION(func, info, wait) ({ smp_call_function(func, info, 1, wait); 0; })'
                    echo '#define NV_ON_EACH_CPU(func, info, wait) ({ on_each_cpu(func, info, 1, wait); 0; })'
                fi
            else
                if [ "$ret" = 1 ]; then
                    echo '#define NV_SMP_CALL_FUNCTION(func, info, wait) ({ int __ret = smp_call_function(func, info, wait); __ret; })'
                    echo '#define NV_ON_EACH_CPU(func, info, wait) ({ int __ret = on_each_cpu(func, info, wait); __ret; })'
                else
                    echo '#define NV_SMP_CALL_FUNCTION(func, info, wait) ({ smp_call_function(func, info, wait); 0; })'
                    echo '#define NV_ON_EACH_CPU(func, info, wait) ({ on_each_cpu(func, info, wait); 0; })'
                fi
            fi
            echo 'int main(void) { return NV_SMP_CALL_FUNCTION(callback, NULL, 1) + NV_ON_EACH_CPU(callback, NULL, 1); }'
        } > "$c"
        ${CC:-cc} -Wall -Werror -c "$c" -o "$tmp/$args-$ret.o"
    done
done
