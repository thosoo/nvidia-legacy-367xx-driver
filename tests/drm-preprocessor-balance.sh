#!/bin/sh
set -eu
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

cat > "$work/check_pp.py" <<'PY'
import re, sys
ok = True
for path in sys.argv[1:]:
    stack = []
    with open(path, encoding='utf-8', errors='ignore') as f:
        for nr, line in enumerate(f, 1):
            m = re.match(r'\s*#\s*(if|ifdef|ifndef|elif|else|endif)\b(.*)', line)
            if not m:
                continue
            directive, expr = m.group(1), m.group(2).strip()
            if directive in ('if', 'ifdef', 'ifndef'):
                stack.append((directive, expr, nr))
            elif directive in ('elif', 'else'):
                if not stack:
                    print(f'{path}:{nr}: invalid #{directive} without opening conditional')
                    ok = False
            elif directive == 'endif':
                if not stack:
                    print(f'{path}:{nr}: unmatched #endif')
                    ok = False
                else:
                    stack.pop()
    for directive, expr, nr in stack:
        print(f'{path}:{nr}: unmatched #{directive} {expr}')
        ok = False
sys.exit(0 if ok else 1)
PY

cat > "$work/positive.c" <<'C'
#if defined(A)
#if defined(B)
int b;
#else
int c;
#endif
#endif
C
python3 "$work/check_pp.py" "$work/positive.c"

cat > "$work/missing-endif.c" <<'C'
#if defined(A)
#if defined(B)
int b;
#endif
C
if python3 "$work/check_pp.py" "$work/missing-endif.c" > "$work/missing-endif.out" 2>&1; then exit 1; fi
rg -n 'unmatched #if' "$work/missing-endif.out" >/dev/null

cat > "$work/extra-endif.c" <<'C'
#if defined(A)
#endif
#endif
C
if python3 "$work/check_pp.py" "$work/extra-endif.c" > "$work/extra-endif.out" 2>&1; then exit 1; fi
rg -n 'unmatched #endif' "$work/extra-endif.out" >/dev/null

cat > "$work/bad-else.c" <<'C'
#else
int x;
#endif
C
if python3 "$work/check_pp.py" "$work/bad-else.c" > "$work/bad-else.out" 2>&1; then exit 1; fi
rg -n 'invalid #else' "$work/bad-else.out" >/dev/null

if [ "$#" -gt 1 ]; then
    echo "usage: $0 [PREPARED_367_KERNEL_TREE]" >&2
    exit 2
fi

if [ "$#" -eq 1 ]; then
    pristine=$(readlink -f "$1")
    patchdir=$repo/debian/module/debian/patches
    series=$work/series
    sed 's/#HAS_UVM#//g' "$patchdir/series.in" | sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d' > "$series"

    apply_until()
    {
        target=$1
        tree=$2
        while IFS= read -r patch_name; do
            test -n "$patch_name" || continue
            fuzz=--fuzz=0
            case "$patch_name" in
                0047-backport-drm_output_poll_changed-changes-from-535.21.patch) fuzz=--fuzz=0 ;;
                *) fuzz= ;;
            esac
            patch -d "$tree" -p1 $fuzz < "$patchdir/$patch_name" > "$work/$target-$patch_name.log" 2>&1 || {
                echo "$patch_name" >&2
                cat "$work/$target-$patch_name.log" >&2
                exit 1
            }
            if [ "$patch_name" = "$target" ]; then
                break
            fi
        done < "$series"
    }

    check_drm_tree()
    {
        tree=$1
        label=$2
        drm=$tree/nvidia-drm/nvidia-drm-drv.c
        python3 "$work/check_pp.py" "$drm"
        callback_line=$(rg -n '^static void nvidia_drm_output_poll_changed' "$drm" | cut -d: -f1)
        callback_endif=$(rg -n '^#endif /\* NV_DRM_OUTPUT_POLL_CHANGED_PRESENT \*/' "$drm" | cut -d: -f1)
        funcs_line=$(rg -n '^static const struct drm_mode_config_funcs' "$drm" | cut -d: -f1)
        test -n "$callback_line" && test -n "$callback_endif" && test -n "$funcs_line"
        if [ "$callback_line" -ge "$callback_endif" ] || [ "$callback_endif" -ge "$funcs_line" ]; then
            echo "$label: output_poll_changed guard does not close before mode-config funcs" >&2
            exit 1
        fi
        if [ "$(rg -c '^#if defined\(NV_DRM_OUTPUT_POLL_CHANGED_PRESENT\)' "$drm")" -ne 2 ]; then
            echo "$label: expected exactly two output-poll feature guards" >&2
            exit 1
        fi
        if [ "$(rg -c 'output_poll_changed = nvidia_drm_output_poll_changed' "$drm")" -ne 1 ]; then
            echo "$label: expected one guarded output_poll_changed initializer" >&2
            exit 1
        fi
    }

    cp -a "$pristine/." "$work/target-tree"
    apply_until 0047-backport-drm_output_poll_changed-changes-from-535.21.patch "$work/target-tree"
    check_drm_tree "$work/target-tree" target-position

    cp -a "$pristine/." "$work/full-tree"
    while IFS= read -r patch_name; do
        test -n "$patch_name" || continue
        patch -d "$work/full-tree" -p1 < "$patchdir/$patch_name" > "$work/full-$patch_name.log" 2>&1 || {
            echo "$patch_name" >&2
            cat "$work/full-$patch_name.log" >&2
            exit 1
        }
    done < "$series"
    check_drm_tree "$work/full-tree" complete-series
    sh -n "$work/full-tree/conftest.sh"
    for case_name in drm_output_poll_changed file_operations_fop_unsigned_offset_present drm_driver_has_date; do
        if [ "$(rg -c "^[[:space:]]*$case_name\\)" "$work/full-tree/conftest.sh")" -ne 1 ]; then
            echo "complete-series: conftest case $case_name is not unique" >&2
            exit 1
        fi
        if [ "$(rg -c "NV_CONFTEST_.*$case_name" "$work/full-tree/nvidia-drm/nvidia-drm.Kbuild")" -ne 1 ]; then
            echo "complete-series: Kbuild registration $case_name is not unique" >&2
            exit 1
        fi
    done
fi
