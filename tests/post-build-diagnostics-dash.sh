#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
script=$repo/tools/build-in-debian.sh
grep -F "PS4='+diagnostics: '" "$script" >/dev/null
if grep -F 'PS4=' "$script" | grep -F 'LINENO' >/dev/null; then
    echo 'diagnostics PS4 must not reference non-POSIX LINENO under dash' >&2
    exit 1
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/check.sh" <<'CHECKEOF'
#!/bin/dash
set -eu
binary_status=7
mkdir -p logs
: > logs/post-build-diagnostics-failures.txt
{
    PS4='+diagnostics: '
    set -x
    printf '%s\n' none > logs/module-quilt-failed-patch.txt
    printf '%s\n' 0 > logs/post-build-diagnostics.exit
    set +x
} > logs/post-build-diagnostics.trace.txt 2>&1
diagnostics_status=$?
printf '%s\n' "$diagnostics_status" > logs/post-build-diagnostics.exit
exit "$binary_status"
CHECKEOF
chmod +x "$tmp/check.sh"
set +e
( cd "$tmp" && /bin/dash ./check.sh ) > "$tmp/stdout" 2> "$tmp/stderr"
status=$?
set -e
test "$status" -eq 7
if grep -R 'LINENO: parameter not set' "$tmp" >/dev/null; then
    echo 'dash diagnostics emitted LINENO nounset noise' >&2
    exit 1
fi
grep -Fx none "$tmp/logs/module-quilt-failed-patch.txt" >/dev/null
grep -Fx 0 "$tmp/logs/post-build-diagnostics.exit" >/dev/null
grep -F '+diagnostics: printf' "$tmp/logs/post-build-diagnostics.trace.txt" >/dev/null
