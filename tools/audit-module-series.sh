#!/bin/sh
set -eu
if [ "$#" -ne 2 ]; then
    echo "usage: $0 KERNEL_TREE REPORT_DIRECTORY" >&2
    exit 2
fi
tree=$(readlink -f "$1")
report=$(readlink -m "$2")
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
patchdir=$repo/debian/module/debian/patches
series=$report/active-series.txt
mkdir -p "$report"
sed 's/#HAS_UVM#//g' "$patchdir/series.in" | sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' > "$series"
python3 - "$tree" "$patchdir" "$series" "$report" <<'PY'
import csv, pathlib, re, shutil, subprocess, sys, tempfile

tree=pathlib.Path(sys.argv[1]); patchdir=pathlib.Path(sys.argv[2]); series=pathlib.Path(sys.argv[3]); report=pathlib.Path(sys.argv[4])
patches=[l.strip() for l in series.read_text().splitlines() if l.strip()]
headers=['order','patch filename','origin/version','files touched','strict cumulative result','independent strict result','default fuzz/offset result','forced discovery result','reject count','missing target files','missing target symbols','consumed conftest macros','introduced conftest macros','probable prerequisites','classification','recommended action','contamination status']
rows=[]; touched=[]; rejects=[]; fuzz=[]; missing_files=[]; missing_symbols=[]; producers=[]; consumers=[]; contamination=[]

def run(cmd,cwd): return subprocess.run(cmd,cwd=cwd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
def text(p): return (patchdir/p).read_text(errors='replace')
def origin(t):
    vals=[]
    for line in t.splitlines():
        if line.startswith(('Origin:','Subject:','Description:')) or 'changes from' in line or 'from NVIDIA' in line:
            vals.append(line.strip())
    return ' | '.join(vals[:3]) or 'not-declared'
def files(t):
    out=[]
    for line in t.splitlines():
        if line.startswith(('--- a/','+++ b/')):
            f=line[6:].split('\t',1)[0].split(' ',1)[0]
            if f != '/dev/null' and f not in out: out.append(f)
    return out
def macros(t):
    introduced=sorted(set(re.findall(r'NV_[A-Z0-9_]+', '\n'.join(l[1:] for l in t.splitlines() if l.startswith('+') and not l.startswith('+++')))))
    consumed=sorted(set(re.findall(r'NV_[A-Z0-9_]+', '\n'.join(l[1:] for l in t.splitlines() if l.startswith('-') and not l.startswith('---')))))
    return consumed,introduced

cum=tempfile.mkdtemp(prefix='module-audit-cum.'); cumtree=pathlib.Path(cum)/'tree'; shutil.copytree(tree,cumtree,symlinks=True)
forced=tempfile.mkdtemp(prefix='module-audit-forced.'); forcedtree=pathlib.Path(forced)/'tree'; shutil.copytree(tree,forcedtree,symlinks=True)
blocked=False; contaminated=False; first_failure=''
for idx,p in enumerate(patches,1):
    pf=patchdir/p; pt=text(p); fs=files(pt); cons,intro=macros(pt)
    touched += [f'{p}\t{f}' for f in fs]
    miss=[f for f in fs if not (tree/f).exists()]
    if miss: missing_files.append(f'{p}\t' + ','.join(miss))
    strict_result='dependency-blocked' if blocked else 'unknown'
    if not blocked:
        r=run(['patch','-p1','--fuzz=0','--dry-run','-i',str(pf)],cumtree)
        if r.returncode==0:
            strict_result='clean'
            run(['patch','-p1','--fuzz=0','-i',str(pf)],cumtree)
        else:
            strict_result='fail'
            blocked=True; first_failure=p
            rejects.append(f'cumulative\t{p}\n{r.stdout}')
    ind=tempfile.mkdtemp(prefix='module-audit-ind.'); indtree=pathlib.Path(ind)/'tree'; shutil.copytree(tree,indtree,symlinks=True)
    ir=run(['patch','-p1','--fuzz=0','--dry-run','-i',str(pf)],indtree)
    dr=run(['patch','-p1','--dry-run','-i',str(pf)],indtree)
    shutil.rmtree(ind, ignore_errors=True)
    independent='clean' if ir.returncode==0 else 'fail'
    default='clean' if dr.returncode==0 and 'fuzz' not in dr.stdout and 'offset' not in dr.stdout else ('fuzz-or-offset' if dr.returncode==0 else 'fail')
    if 'fuzz' in dr.stdout or 'offset' in dr.stdout: fuzz.append(f'independent\t{p}\n{dr.stdout}')
    fr=run(['patch','-p1','--forward','--reject-file=-','-i',str(pf)],forcedtree)
    forced_result='applied' if fr.returncode==0 else 'rejected'
    if fr.returncode!=0:
        contaminated=True; rejects.append(f'forced\t{p}\n{fr.stdout}')
    if contaminated: contamination.append(f'{p}\tpotentially-contaminated')
    reject_count=fr.stdout.count('FAILED') + fr.stdout.count('.rej')
    if p.startswith(('include-swiotlb','ignore_xen','arm-','nvidia-drm-arm','armhf-')):
        classification='architecture-irrelevant'
    elif miss:
        classification='subsystem-absent'
    elif strict_result=='dependency-blocked':
        classification='dependency-blocked'
    elif independent=='clean' and default=='clean' and strict_result=='clean':
        classification='clean'
    elif default=='fuzz-or-offset':
        classification='fuzz-required' if 'fuzz' in dr.stdout else 'offset-only'
    elif reject_count:
        classification='mechanical-rebase'
    else:
        classification='unknown'
    if cons: consumers.append(f'{p}\t' + ','.join(cons))
    if intro: producers.append(f'{p}\t' + ','.join(intro))
    rows.append([idx,p,origin(pt),';'.join(fs) or 'none',strict_result,independent,default,forced_result,reject_count,','.join(miss) or 'none','not-scanned',','.join(cons) or 'none',','.join(intro) or 'none','see prior producers' if strict_result=='dependency-blocked' else 'none',classification,'refresh/rebase or remove only with documented absent subsystem' if classification!='clean' else 'none','potentially-contaminated' if contaminated else 'clean'])

with (report/'module-patch-audit.tsv').open('w',newline='') as f: csv.writer(f,delimiter='\t').writerows([headers,*rows])
with (report/'module-patch-audit.md').open('w') as f:
    f.write('| order | patch | cumulative | independent | default | forced | classification | contamination |\n|---:|---|---|---|---|---|---|---|\n')
    for r in rows: f.write(f'| {r[0]} | {r[1]} | {r[4]} | {r[5]} | {r[6]} | {r[7]} | {r[14]} | {r[16]} |\n')
(report/'module-patch-first-strict-failure.txt').write_text(first_failure+'\n')
(report/'module-patch-touched-files.txt').write_text('\n'.join(touched)+'\n')
(report/'module-patch-rejects.txt').write_text('\n\n'.join(rejects)+'\n')
(report/'module-patch-fuzz-offsets.txt').write_text('\n\n'.join(fuzz)+'\n')
(report/'module-patch-missing-files.txt').write_text('\n'.join(missing_files)+'\n')
(report/'module-patch-missing-symbols.txt').write_text('\n'.join(missing_symbols)+'\n')
(report/'module-patch-conftest-producers.txt').write_text('\n'.join(producers)+'\n')
(report/'module-patch-conftest-consumers.txt').write_text('\n'.join(consumers)+'\n')
(report/'module-patch-contamination.txt').write_text('\n'.join(contamination)+'\n')
shutil.rmtree(cum, ignore_errors=True); shutil.rmtree(forced, ignore_errors=True)
PY
