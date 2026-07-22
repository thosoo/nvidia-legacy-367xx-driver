#!/bin/sh
set -eu
check_workflows()
{
python3 - <<'PY'
import pathlib, re
root=pathlib.Path('.github/workflows')
valid=re.compile(r'^[A-Za-z0-9_-]+$')
for path in sorted(root.glob('*.y*ml')):
    text=path.read_text()
    in_jobs=False
    for lineno,line in enumerate(text.splitlines(),1):
        if line == 'jobs:':
            in_jobs=True
            continue
        if in_jobs and line and not line.startswith(' ') and not line.startswith('#'):
            in_jobs=False
        if in_jobs:
            m=re.match(r'^  ([^\s:#][^:#]*):\s*$', line)
            if m and not valid.match(m.group(1)):
                raise SystemExit(f'{path}:{lineno}: invalid job id {m.group(1)}')
    uploads=text.count('uses: actions/upload-artifact@v4')
    guarded=text.count("steps.artifact_guard.outcome == 'success'")
    if uploads != guarded:
        raise SystemExit(f'{path}: upload guard mismatch uploads={uploads} guarded={guarded}')
PY
}
check_executable_modes()
{
    for script in tools/build-ubuntu-6.8-module.sh tools/audit-module-symbols.sh tools/collect-workqueue-runtime.sh tools/check-github-actions.sh; do
        if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            mode=$(git ls-files --stage -- "$script" | awk '{print $1}')
            test "$mode" = 100755 || { echo "$script has git index mode $mode" >&2; exit 1; }
            test -x "$script" || { echo "$script is not executable in checkout" >&2; exit 1; }
        else
            test -f "$script" || { echo "$script missing in archive" >&2; exit 1; }
            test -x "$script" || { echo "$script is not executable in archive" >&2; exit 1; }
        fi
    done
}
archive_regression()
{
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        return 0
    fi
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT HUP INT TERM
    git archive --format=tar HEAD > "$tmp/repo.tar"
    mkdir "$tmp/extract"
    tar -xf "$tmp/repo.tar" -C "$tmp/extract"
    (cd "$tmp/extract" && CI_WORKFLOW_ARCHIVE_REGRESSION=0 tests/ci-workflow-static.sh)
    chmod -x "$tmp/extract/tools/audit-module-symbols.sh"
    if (cd "$tmp/extract" && CI_WORKFLOW_ARCHIVE_REGRESSION=0 tests/ci-workflow-static.sh) >/dev/null 2>&1; then
        echo 'archive executable-mode regression did not fail after chmod -x' >&2
        exit 1
    fi
}
check_workflows
check_executable_modes
if [ "${CI_WORKFLOW_ARCHIVE_REGRESSION:-1}" = 1 ]; then
    archive_regression
fi
