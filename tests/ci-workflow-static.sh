#!/bin/sh
set -eu
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
for script in tools/build-ubuntu-6.8-module.sh tools/audit-module-symbols.sh tools/collect-workqueue-runtime.sh tools/check-github-actions.sh; do
    mode=$(git ls-files --stage -- "$script" | awk '{print $1}')
    test "$mode" = 100755 || { echo "$script has mode $mode" >&2; exit 1; }
done
