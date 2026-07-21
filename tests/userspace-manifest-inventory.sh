#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

cat > "$work/check.py" <<'PY'
import os, re, sys
from pathlib import Path
repo=Path(sys.argv[1]); payload=Path(sys.argv[2]) if len(sys.argv)>2 else None
version='367.134'; libdir='usr/lib/x86_64-linux-gnu'; private='nvidia/legacy-367xx'
stale={'libGL.so.1.7.0','libEGL.so.1.1.0','libEGL.so.367.134','libGLESv1_CM.so.1.2.0','libGLESv2.so.2.1.0'}
errors=[]
def subst(s): return s.replace('#VERSION#',version).replace('#LIBDIR#',libdir).replace('#PRIVATE#',private)
# Negative fixture checks
fixtures=Path(os.environ.get('WORKDIR','/tmp'))
# Active source templates: exclude templates for deliberately disabled absent non-GLVND EGL package.
active_install=[]
for p in sorted((repo/'debian').glob('*.install.in')):
    if p.name.startswith('libegl1-nvidia'):
        continue
    active_install.append(p)
# Include checked-in generated files if present, otherwise use source templates with substitutions.
active_sources={}
for p in active_install:
    pkg=p.name[:-len('.install.in')]
    for raw in p.read_text().splitlines():
        raw=raw.strip()
        if not raw or raw.startswith('#'): continue
        src=subst(raw.split()[0])
        base=Path(src).name
        if '.so' not in base:
            continue
        active_sources.setdefault(src,[]).append(pkg)
        if base in stale: errors.append(f'stale source active: {src} in {p.name}')
        if payload and not (payload/base).exists() and not (payload/src).exists(): errors.append(f'missing source: {src} requested by {p.name}')
for src, owners in active_sources.items():
    if len(owners)>1:
        errors.append(f'duplicate source ownership: {src}: {",".join(owners)}')
# Link targets: source side must be installed by same package or be produced by another active package.
installed_basenames={Path(s).name for s in active_sources}
for p in sorted((repo/'debian').glob('*.links.in')):
    if p.name.startswith('libegl1-nvidia'):
        continue
    for raw in p.read_text().splitlines():
        raw=raw.strip()
        if not raw or raw.startswith('#'): continue
        parts=raw.split()
        if len(parts)<2: continue
        src,dst=map(subst,parts[:2])
        if Path(src).name in stale or Path(dst).name in stale:
            errors.append(f'stale link active: {src} -> {dst} in {p.name}')
        if '.so' in Path(src).name and Path(src).name not in installed_basenames:
            errors.append(f'dangling link source: {src} in {p.name}')
# Disabled non-GLVND EGL package must not appear in generated control.
control=(repo/'debian/control').read_text()
if re.search(r'^Package: libegl1-nvidia-legacy-367xx$', control, re.M):
    errors.append('disabled absent package still active: libegl1-nvidia-legacy-367xx')
# Symbols files for disabled package are allowed only as inactive templates, not active generated package names.
for p in sorted((repo/'debian').glob('*.symbols')):
    if p.name.startswith('libegl1-nvidia-legacy-367xx'):
        errors.append(f'active symbols for disabled package: {p.name}')
# Relevant top-level libraries must be installed or documented in not-installed.
if payload:
    documented=(repo/'debian/not-installed.in').read_text()
    relevant=[x.name for x in payload.iterdir() if x.is_file() and '.so' in x.name and x.name.startswith(('libGL','libEGL','libGLES','libOpenGL'))]
    for name in relevant:
        if name not in installed_basenames and name not in documented:
            errors.append(f'unclassified relevant library: {name}')
# SONAME sanity for changed loader mappings.
sonames={'libGL.so.1.0.0':'libGL.so.1','libEGL.so.1':'libEGL.so.1','libGLESv1_CM.so.1':'libGLESv1_CM.so.1','libGLESv2.so.2':'libGLESv2.so.2'}
if payload:
    import subprocess
    for name,want in sonames.items():
        if name in installed_basenames:
            out=subprocess.run(['readelf','-d',str(payload/name)], text=True, capture_output=True).stdout
            if f'[{want}]' not in out:
                errors.append(f'SONAME mismatch: {name} expected {want}')
if errors:
    print('\n'.join(errors), file=sys.stderr); sys.exit(1)
PY

# Fixture: stale/missing names must be rejected.
mkdir -p "$work/fixture/debian" "$work/payload"
printf 'Package: fixture\n' > "$work/fixture/debian/control"
printf 'libGL.so.1.7.0 usr/lib/x\n' > "$work/fixture/debian/libgl1-glvnd-nvidia-glx.install.in"
printf '' > "$work/fixture/debian/not-installed.in"
if WORKDIR="$work" python3 "$work/check.py" "$work/fixture" "$work/payload" > "$work/negative.out" 2>&1; then
    echo 'negative fixture unexpectedly passed' >&2; exit 1
fi
rg -n 'stale source active|missing source' "$work/negative.out" >/dev/null

if [ "$#" -gt 1 ]; then
    echo "usage: $0 [EXTRACTED_NVIDIA_367.134_DIR]" >&2; exit 2
fi
if [ "$#" -eq 1 ]; then
    python3 "$work/check.py" "$repo" "$(readlink -f "$1")"
else
    python3 "$work/check.py" "$repo"
fi
