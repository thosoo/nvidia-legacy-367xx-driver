#!/bin/sh
set -eu
version=1.7.7
archive=actionlint_${version}_linux_amd64.tar.gz
url=https://github.com/rhysd/actionlint/releases/download/v${version}/${archive}
sha256=023070a287cd8cccd71515fedc843f1985bf96c436b7effaecce67290e7e0757
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$url" -o "$tmp/$archive"
printf '%s  %s\n' "$sha256" "$tmp/$archive" | sha256sum -c - >/dev/null
tar -xzf "$tmp/$archive" -C "$tmp" actionlint
find "$repo/.github/workflows" -type f \( -name '*.yml' -o -name '*.yaml' \) -print | sort > "$tmp/workflows.txt"
test -s "$tmp/workflows.txt"
"$tmp/actionlint" $(cat "$tmp/workflows.txt")
python3 - "$repo/.github/workflows" <<'PY'
import pathlib, re, sys
root=pathlib.Path(sys.argv[1])
valid=re.compile(r'^[A-Za-z0-9_-]+$')
for path in sorted(root.glob('*.y*ml')):
    lines=path.read_text().splitlines()
    in_jobs=False
    for lineno,line in enumerate(lines,1):
        if re.match(r'^jobs:\s*$', line):
            in_jobs=True
            continue
        if in_jobs:
            if line and not line.startswith(' ') and not line.startswith('#'):
                in_jobs=False
            m=re.match(r'^  ([^\s:#][^:#]*):\s*$', line)
            if m:
                job=m.group(1)
                if not valid.match(job):
                    raise SystemExit(f'{path}:{lineno}: invalid job id {job!r}')
PY
