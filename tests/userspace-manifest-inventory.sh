#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

cat > "$work/check.py" <<'PY'
import fnmatch, os, re, stat, subprocess, sys
from pathlib import Path

VERSION='367.134'
LIBDIR='usr/lib/x86_64-linux-gnu'
PRIVATE='nvidia/legacy-367xx'
CURRENT='current'
STALE={'libGL.so.1.7.0','libEGL.so.1.1.0','libEGL.so.367.134','libGLESv1_CM.so.1.2.0','libGLESv2.so.2.1.0','libnvidia-egl-wayland.so.1.*.*','nvidia_icd.json.template'}

repo=Path(sys.argv[1])
payload=Path(sys.argv[2]) if len(sys.argv)>2 else None
errors=[]

def subst(text):
    return (text.replace('#VERSION#',VERSION).replace('#LIBDIR#',LIBDIR)
                .replace('#PRIVATE#',PRIVATE).replace('#CURRENT#',CURRENT)
                .replace('#tls#','').replace('#!armhf#',''))

def parse_control(path):
    packages=[]
    if not path.exists(): return packages
    for line in path.read_text().splitlines():
        m=re.match(r'^Package:\s*(\S+)', line)
        if m: packages.append(m.group(1))
    return packages

def control_packages():
    pkgs=parse_control(repo/'debian/control')
    return set(pkgs)

def manifest_candidates(suffix):
    deb=repo/'debian'
    active=control_packages()
    out=[]
    exact=set()
    for pkg in active:
        for ext in (suffix, suffix+'.in'):
            p=deb/f'{pkg}{ext}'
            if p.exists():
                out.append((pkg,p)); exact.add(p)
    # Source templates can be generic nvidia names that generate active legacy names.
    for p in sorted(deb.glob(f'*{suffix}.in')):
        if p in exact: continue
        stem=p.name[:-len(suffix+'.in')]
        legacy=stem.replace('nvidia-', 'nvidia-legacy-367xx-').replace('-nvidia', '-nvidia-legacy-367xx')
        candidates={stem, legacy, stem.replace('nvidia', 'nvidia-legacy-367xx')}
        # Keep templates whose package stem appears in control.in or whose generated legacy name is active.
        control_in=(repo/'debian/control.in').read_text() if (repo/'debian/control.in').exists() else ''
        payload_has_source=False
        if payload:
            for raw in p.read_text().splitlines():
                line=raw.strip()
                if not line or line.startswith('#'): continue
                src=subst(line.split()[0])
                if any((payload / rel).exists() for rel in (src, Path(src).name)):
                    payload_has_source=True
                    break
        if candidates & active or any(f'Package: {c}' in control_in for c in candidates) or payload_has_source:
            if not (stem.startswith('libegl1-nvidia') and 'Package: libegl1-${nvidia}' not in control_in):
                out.append((next(iter((candidates & active) or {stem})), p))
    return out

def iter_manifest_sources():
    owners={}
    for pkg,p in manifest_candidates('.install'):
        for lineno, raw in enumerate(p.read_text().splitlines(),1):
            line=raw.strip()
            if not line or line.startswith('#'): continue
            src=subst(line.split()[0])
            owners.setdefault(src,[]).append((pkg,p.name,lineno))
            base=Path(src).name
            if base in STALE:
                errors.append(f'stale source active: {src} in {p.name}:{lineno}')
    return owners

def iter_links():
    links=[]
    for pkg,p in manifest_candidates('.links'):
        for lineno, raw in enumerate(p.read_text().splitlines(),1):
            line=raw.strip()
            if not line or line.startswith('#'): continue
            parts=line.split()
            if len(parts) < 2: continue
            src,dst=map(subst,parts[:2])
            links.append((pkg,p.name,lineno,src,dst))
            if Path(src).name in STALE or Path(dst).name in STALE:
                errors.append(f'stale link active: {src} -> {dst} in {p.name}:{lineno}')
    return links

def not_installed_patterns():
    p=repo/'debian/not-installed.in'
    patterns=[]; comments=[]
    if not p.exists(): return patterns
    for lineno, raw in enumerate(p.read_text().splitlines(),1):
        stripped=raw.strip()
        if not stripped:
            comments=[]; continue
        if stripped.startswith('#'):
            comments.append(stripped[1:].strip()); continue
        pat=subst(stripped)
        reason=' '.join(c for c in comments if c)
        patterns.append((pat,lineno,reason))
        if not reason:
            errors.append(f'not-installed pattern lacks adjacent reason: {pat} at {lineno}')
        # Keep the nearest comment as the reason for grouped exclusions.
    return patterns

def match_pattern(path, pat):
    s=str(path)
    name=path.name
    return fnmatch.fnmatch(s, pat) or fnmatch.fnmatch(name, pat)

def payload_items():
    if not payload: return []
    items=[]
    for p in payload.rglob('*'):
        if p.is_dir(): continue
        rel=p.relative_to(payload)
        if any(part in {'.manifest'} for part in rel.parts): continue
        items.append(rel)
    return items

def is_relevant(rel):
    name=rel.name
    if '.run' in name: return False
    if rel.parts and (rel.parts[0] in {'32','html','libglvnd_install_checker','tls'} or 'libglvnd_install_checker' in rel.parts): return False
    if name == 'libnvidia-tls.so.367.134': return False
    if name.endswith(('.so',)) or '.so.' in name: return True
    if name.endswith(('.json','.conf','.icd','.desktop','.png','.la')): return True
    if name in {'LICENSE','NVIDIA_Changelog','pkg-history.txt','nvidia.icd','10_nvidia.json','10_nvidia_wayland.json'}: return True
    if rel.parts and rel.parts[0] in {'kernel'}: return True
    try:
        mode=(payload/rel).stat().st_mode
        if mode & (stat.S_IXUSR|stat.S_IXGRP|stat.S_IXOTH): return True
    except OSError: pass
    return False

def handled_by_helper(rel):
    name=rel.name
    if name == 'NVIDIA_Changelog': return 'dh_installchangelogs'
    if name.endswith(('.1','.man')) or '/man/' in str(rel): return 'dh_installman'
    return None

def generated_replacement(rel):
    if rel.name == 'nvidia_icd.json':
        if (repo/'debian/nvidia_icd.json.template').exists():
            return 'glvnd/nvidia_icd.json and nonglvnd/nvidia_icd.json generated from debian/nvidia_icd.json.template'
    return None

owners=iter_manifest_sources()
links=iter_links()
patterns=not_installed_patterns()
active=control_packages()
if os.environ.get('EXPECT_ACTIVE_OMITTED_CHECK'):
    manifest_pkgs={pkg for pkg,_ in manifest_candidates('.install')}
    for pkg in active:
        if pkg.startswith('lib') and pkg not in manifest_pkgs:
            errors.append(f'generated active package omitted from manifest audit: {pkg}')
if re.search(r'^Package: libegl1-nvidia-legacy-367xx$', (repo/'debian/control').read_text(), re.M):
    errors.append('disabled absent package still active: libegl1-nvidia-legacy-367xx')

for src, srcowners in owners.items():
    if len(srcowners) > 1 and '*' not in src:
        errors.append(f'duplicate payload ownership: {src}: '+','.join(f'{o[0]}:{o[1]}:{o[2]}' for o in srcowners))

installed_basenames={Path(s).name for s in owners}
for pkg,file,lineno,src,dst in links:
    if ('.so' in Path(src).name or Path(src).name.endswith('.json')) and Path(src).name not in installed_basenames:
        # Allow links to libraries provided by explicit external dependencies only when documented in control.
        if Path(src).name not in {'libGL.so.1','libEGL.so.1','libGLESv1_CM.so.1','libGLESv2.so.2'}:
            errors.append(f'dangling package link source: {src} in {file}:{lineno}')

# Active generated packages should have matching generated or source manifests when they are library payload packages.
for stale in STALE:
    if stale in {Path(s).name for s in owners}:
        errors.append(f'stale run-93 filename active: {stale}')

if payload:
    source_matches={}
    for src in owners:
        matches=[rel for rel in payload_items() if match_pattern(rel, src) or rel.name == Path(src).name]
        source_matches[src]=matches
        if not matches and Path(src).name not in {'nvidia.ids'} and not src.startswith(('debian/','glvnd/','nonglvnd/')):
            errors.append(f'active manifest source missing from inventory: {src}')
    exclusion_matches={}
    for pat,lineno,reason in patterns:
        matches=[rel for rel in payload_items() if match_pattern(rel, pat)]
        exclusion_matches[(pat,lineno,reason)]=matches
        if not matches and (Path(pat).name in STALE or pat in STALE) and 'does not ship' not in reason.lower():
            errors.append(f'stale unmatched not-installed pattern: {pat} at {lineno}')
    for rel in payload_items():
        if not is_relevant(rel):
            continue
        installed=[src for src,matches in source_matches.items() if rel in matches or rel.name == Path(src).name]
        excluded=[pat for (pat,lineno,reason),matches in exclusion_matches.items() if rel in matches]
        if str(rel) in {'glvnd/nvidia_icd.json','nonglvnd/nvidia_icd.json'} and excluded:
            errors.append(f'generated ICD variant incorrectly excluded: {rel}: {excluded}')
        helper=handled_by_helper(rel)
        generated=generated_replacement(rel)
        classifications=sum(bool(x) for x in (installed, excluded, [helper] if helper else [], [generated] if generated else []))
        if len(installed) > 1:
            errors.append(f'payload file claimed by multiple packages: {rel}: {installed}')
        if installed and excluded and rel.name not in {'libGLdispatch.so.0','libOpenGL.so.0','libGLX.so.0'}:
            errors.append(f'payload file both installed and excluded: {rel}: {installed} / {excluded}')
        if classifications == 0:
            errors.append(f'unclassified copied payload file: {rel}')
    # Required explicit dispositions.
    for required in ('libnvidia-egl-wayland.so.367.134','nvidia_icd.json'):
        rels=[r for r in payload_items() if r.name == required]
        if rels and not any(any(r in matches for r in rels) for matches in exclusion_matches.values()):
            errors.append(f'required payload not excluded with generated not-installed pattern: {required}')

# SONAME sanity for corrected loader mappings.
if payload:
    sonames={'libGL.so.1.0.0':'libGL.so.1','libEGL.so.1':'libEGL.so.1','libGLESv1_CM.so.1':'libGLESv1_CM.so.1','libGLESv2.so.2':'libGLESv2.so.2'}
    for name,want in sonames.items():
        if name in installed_basenames and (payload/name).exists():
            out=subprocess.run(['readelf','-d',str(payload/name)], text=True, capture_output=True).stdout
            if f'[{want}]' not in out:
                errors.append(f'SONAME mismatch: {name} expected {want}')

if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print(f'active packages: {len(active)}')
print(f'active manifest sources: {len(owners)}')
if payload:
    print(f'payload items audited: {len(payload_items())}')
PY

make_fixture() { mkdir -p "$work/$1/debian" "$work/$1/payload"; printf 'Package: active\n' > "$work/$1/debian/control"; printf 'Source: s\n\nPackage: active\n' > "$work/$1/debian/control.in"; : > "$work/$1/debian/not-installed.in"; }
expect_fail() { name=$1; shift; if EXPECT_ACTIVE_OMITTED_CHECK="${EXPECT_ACTIVE_OMITTED_CHECK:-}" python3 "$work/check.py" "$work/$name" "$work/$name/payload" > "$work/$name.out" 2>&1; then echo "$name unexpectedly passed" >&2; exit 1; fi; "$@" "$work/$name.out" >/dev/null; }

# Negative fixtures for complete payload closure and matching semantics.
make_fixture unclassified-lib; : > "$work/unclassified-lib/payload/libnvidia-extra.so.367.134"; expect_fail unclassified-lib rg -n 'unclassified copied payload file'
make_fixture unclassified-json; : > "$work/unclassified-json/payload/extra.json"; expect_fail unclassified-json rg -n 'unclassified copied payload file'
make_fixture stale-version; printf '# stale\nlibnvidia-egl-wayland.so.1.*.*\n' > "$work/stale-version/debian/not-installed.in"; : > "$work/stale-version/payload/libnvidia-egl-wayland.so.367.134"; expect_fail stale-version rg -n 'stale unmatched not-installed pattern|unclassified copied payload file'
make_fixture substring; printf '# similar\nfoo-nvidia_icd.json.bak\n' > "$work/substring/debian/not-installed.in"; : > "$work/substring/payload/nvidia_icd.json"; expect_fail substring rg -n 'unclassified copied payload file|required payload not excluded'
make_fixture inactive-template; printf 'libmissing.so usr/lib\n' > "$work/inactive-template/debian/inactive.install.in"; python3 "$work/check.py" "$work/inactive-template" "$work/inactive-template/payload" >/dev/null
make_fixture active-omitted; printf 'Package: active\nPackage: libpkg\n' > "$work/active-omitted/debian/control"; : > "$work/active-omitted/payload/libpkg.so.1"; export EXPECT_ACTIVE_OMITTED_CHECK=1; expect_fail active-omitted rg -n 'generated active package omitted|unclassified copied payload file'; unset EXPECT_ACTIVE_OMITTED_CHECK
make_fixture installed-excluded; printf 'libdup.so usr/lib\n' > "$work/installed-excluded/debian/active.install.in"; printf '# excluded\nlibdup.so\n' > "$work/installed-excluded/debian/not-installed.in"; : > "$work/installed-excluded/payload/libdup.so"; expect_fail installed-excluded rg -n 'both installed and excluded'
make_fixture duplicate-owner; printf 'libdup.so usr/lib\n' > "$work/duplicate-owner/debian/active.install.in"; printf 'Package: other\n' >> "$work/duplicate-owner/debian/control"; printf 'libdup.so usr/lib\n' > "$work/duplicate-owner/debian/other.install.in"; : > "$work/duplicate-owner/payload/libdup.so"; expect_fail duplicate-owner rg -n 'duplicate payload ownership|multiple packages'
make_fixture no-reason; printf 'libskip.so\n' > "$work/no-reason/debian/not-installed.in"; : > "$work/no-reason/payload/libskip.so"; expect_fail no-reason rg -n 'lacks adjacent reason'
make_fixture generated-icd-excluded; mkdir -p "$work/generated-icd-excluded/payload/glvnd"; printf '# bad\nglvnd/nvidia_icd.json\n' > "$work/generated-icd-excluded/debian/not-installed.in"; : > "$work/generated-icd-excluded/payload/glvnd/nvidia_icd.json"; expect_fail generated-icd-excluded rg -n 'generated ICD variant incorrectly excluded|unclassified copied payload file|stale unmatched|lacks adjacent'

# Positive fixtures.
make_fixture version-subst; printf '# exact version\nlibnvidia-egl-wayland.so.#VERSION#\n' > "$work/version-subst/debian/not-installed.in"; : > "$work/version-subst/payload/libnvidia-egl-wayland.so.367.134"; python3 "$work/check.py" "$work/version-subst" "$work/version-subst/payload" >/dev/null
make_fixture glob-match; printf '# glob\nlibfoo.so.*\n' > "$work/glob-match/debian/not-installed.in"; : > "$work/glob-match/payload/libfoo.so.1"; python3 "$work/check.py" "$work/glob-match" "$work/glob-match/payload" >/dev/null
make_fixture changelog; : > "$work/changelog/payload/NVIDIA_Changelog"; python3 "$work/check.py" "$work/changelog" "$work/changelog/payload" >/dev/null
make_fixture manpage; : > "$work/manpage/payload/nvidia-installer.1"; python3 "$work/check.py" "$work/manpage" "$work/manpage/payload" >/dev/null
make_fixture icd-replaced; mkdir -p "$work/icd-replaced/debian"; : > "$work/icd-replaced/debian/nvidia_icd.json.template"; printf '# original metadata replaced\nnvidia_icd.json\n' > "$work/icd-replaced/debian/not-installed.in"; : > "$work/icd-replaced/payload/nvidia_icd.json"; python3 "$work/check.py" "$work/icd-replaced" "$work/icd-replaced/payload" >/dev/null

if [ "$#" -gt 1 ]; then
    echo "usage: $0 [EXTRACTED_NVIDIA_367.134_DIR]" >&2; exit 2
fi
if [ "$#" -eq 1 ]; then
    python3 "$work/check.py" "$repo" "$(readlink -f "$1")"
else
    python3 "$work/check.py" "$repo"
fi
