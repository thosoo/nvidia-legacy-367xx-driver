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
import csv, pathlib, shutil, subprocess, sys, tempfile, re

tree=pathlib.Path(sys.argv[1]); patchdir=pathlib.Path(sys.argv[2]); series=pathlib.Path(sys.argv[3]); report=pathlib.Path(sys.argv[4])
patches=[l.strip() for l in series.read_text().splitlines() if l.strip()]
rows=[]; touched=[]; rejects=[]; fuzz=[]; missing=[]

def run(cmd,cwd):
    return subprocess.run(cmd,cwd=cwd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)

def files_for_patch(p):
    files=[]
    for line in (patchdir/p).read_text(errors='replace').splitlines():
        if line.startswith('--- a/') or line.startswith('+++ b/'):
            f=line[6:].split('\t',1)[0].split(' ',1)[0]
            if f != '/dev/null' and f not in files:
                files.append(f)
    return files

cum=pathlib.Path(tempfile.mkdtemp(prefix='module-audit-cum.'))
shutil.copytree(tree, cum/'tree', symlinks=True)
first_strict_failure=''
for i,p in enumerate(patches,1):
    pf=patchdir/p
    fs=files_for_patch(p)
    touched.extend(f'{p}\t{f}' for f in fs)
    missing_targets=[f for f in fs if not (cum/'tree'/f).exists()]
    res=run(['patch','-p1','--fuzz=0','--dry-run','-i',str(pf)], cum/'tree')
    strict='ok' if res.returncode==0 else 'fail'
    if res.returncode!=0 and not first_strict_failure:
        first_strict_failure=p
    res_apply=run(['patch','-p1','--fuzz=0','-i',str(pf)], cum/'tree') if res.returncode==0 else res
    if '.rej' in res.stdout or 'FAILED' in res.stdout:
        rejects.append(f'cumulative\t{p}\n{res.stdout}')
    if 'fuzz' in res.stdout or 'offset' in res.stdout:
        fuzz.append(f'cumulative\t{p}\n{res.stdout}')
    # independent clean-tree dry run strict, then default to identify fuzz/offset
    ind=pathlib.Path(tempfile.mkdtemp(prefix='module-audit-ind.'))
    shutil.copytree(tree, ind/'tree', symlinks=True)
    ind_strict=run(['patch','-p1','--fuzz=0','--dry-run','-i',str(pf)], ind/'tree')
    ind_default=run(['patch','-p1','--dry-run','-i',str(pf)], ind/'tree')
    classification='clean'
    if missing_targets:
        classification='mechanical-rebase-required'
        missing.append(f'{p}\t' + ','.join(missing_targets))
    elif ind_strict.returncode==0 and res.returncode==0:
        classification='clean'
    elif ind_default.returncode==0 and ('fuzz' in ind_default.stdout):
        classification='applies-with-fuzz'
        fuzz.append(f'independent\t{p}\n{ind_default.stdout}')
    elif ind_default.returncode==0 and ('offset' in ind_default.stdout):
        classification='applies-with-offset'
        fuzz.append(f'independent\t{p}\n{ind_default.stdout}')
    else:
        classification='mechanical-rebase-required'
        if 'FAILED' in ind_default.stdout or '.rej' in ind_default.stdout:
            rejects.append(f'independent\t{p}\n{ind_default.stdout}')
    rows.append([i,p,'', ';'.join(fs), strict, 'ok' if ind_strict.returncode==0 else 'fail', 'yes' if ('fuzz' in ind_default.stdout or 'offset' in ind_default.stdout) else 'no', ind_default.stdout.count('FAILED'), ','.join(missing_targets), '', '', classification, 'rebase or audit if not clean'])
    shutil.rmtree(ind, ignore_errors=True)

with (report/'module-patch-audit.tsv').open('w', newline='') as f:
    w=csv.writer(f, delimiter='\t'); w.writerow(['order','patch filename','origin/version named in patch','files touched','strict sequential result','independent clean-tree result','fuzz or offset','reject count','missing target file','missing target symbol','prerequisite patches','classification','recommended action']); w.writerows(rows)
with (report/'module-patch-audit.md').open('w') as f:
    f.write('| order | patch | cumulative | independent | classification |\n|---:|---|---|---|---|\n')
    for r in rows: f.write(f'| {r[0]} | {r[1]} | {r[4]} | {r[5]} | {r[11]} |\n')
(report/'module-patch-touched-files.txt').write_text('\n'.join(touched)+'\n')
(report/'module-patch-rejects.txt').write_text('\n\n'.join(rejects)+'\n')
(report/'module-patch-fuzz-offsets.txt').write_text('\n\n'.join(fuzz)+'\n')
(report/'module-patch-missing-symbols.txt').write_text('\n'.join(missing)+'\n')
(report/'module-patch-first-strict-failure.txt').write_text(first_strict_failure+'\n')
shutil.rmtree(cum, ignore_errors=True)
PY
