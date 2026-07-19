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
reject_root=report/'module-patch-rejects'; reject_root.mkdir(exist_ok=True)

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
    fr=run(['patch','-p1','--forward','-i',str(pf)],forcedtree)
    forced_result='applied' if fr.returncode==0 else 'rejected'
    if fr.returncode!=0:
        contaminated=True; rejects.append(f'forced\t{p}\n{fr.stdout}')
        safe=re.sub(r'[^A-Za-z0-9_.-]+','_',p)
        pdir=reject_root/safe; pdir.mkdir(parents=True, exist_ok=True)
        (pdir/'application.log').write_text(fr.stdout)
        for rej in forcedtree.rglob('*.rej'):
            rel=str(rej.relative_to(forcedtree)).replace('/','__')
            shutil.copy2(rej, pdir/rel)
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

# Emit a lightweight per-hunk applicability report. The patch-oriented summary
# must not classify a whole patch as absent merely because one target file is
# missing from NVIDIA 367.134.
python3 - "$tree" "$patchdir" "$series" "$report" <<'PY'
import csv, pathlib, re, shutil, subprocess, sys, tempfile

tree=pathlib.Path(sys.argv[1]); patchdir=pathlib.Path(sys.argv[2]); series=pathlib.Path(sys.argv[3]); report=pathlib.Path(sys.argv[4])
patches=[l.strip() for l in series.read_text().splitlines() if l.strip()]
headers=['patch','file','hunk number','target file exists','strict application result','default application result','fuzz','offset','symbol/context targeted','probable semantic purpose','classification','recommended action']
rows=[]

def run(cmd,cwd):
    return subprocess.run(cmd,cwd=cwd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)

def split_hunks(text):
    current_file=None; file_header=[]; hunk=[]; hno=0
    for line in text.splitlines(True):
        if line.startswith('diff --git '):
            if hunk and current_file:
                yield current_file,hno,file_header,hunk
            current_file=None; file_header=[]; hunk=[]; hno=0
        elif line.startswith('--- a/'):
            if hunk and current_file:
                yield current_file,hno,file_header,hunk
                hunk=[]
            file_header=[line]
        elif line.startswith('+++ b/') and file_header:
            file_header.append(line)
            current_file=line[6:].strip().split('\t',1)[0].split(' ',1)[0]
        elif line.startswith('@@ '):
            if hunk and current_file:
                yield current_file,hno,file_header,hunk
            hno += 1; hunk=[line]
        elif hunk:
            hunk.append(line)
    if hunk and current_file:
        yield current_file,hno,file_header,hunk

def purpose(patch, ctx):
    name=patch.lower()
    if 'conftest' in name or 'conftest' in ctx: return 'kernel feature-probe compatibility'
    if 'drm' in name or 'drm' in ctx: return 'DRM API compatibility'
    if 'get_user_pages' in name: return 'get_user_pages API compatibility'
    if 'vma' in name or 'vm_' in name: return 'vm_area_struct API compatibility'
    return 'mechanical kernel compatibility backport'

for p in patches:
    pt=(patchdir/p).read_text(errors='replace')
    for f,hno,fh,hunk in split_hunks(pt):
        exists=(tree/f).exists()
        patch_text=''.join(fh+hunk)
        tmp=tempfile.mkdtemp(prefix='module-hunk.')
        tmpdir=pathlib.Path(tmp); hpatch=tmpdir/'h.patch'; hpatch.write_text(patch_text)
        work=tmpdir/'tree'; shutil.copytree(tree,work,symlinks=True)
        strict=run(['patch','-p1','--fuzz=0','--dry-run','-i',str(hpatch)],work) if exists else None
        default=run(['patch','-p1','--dry-run','-i',str(hpatch)],work) if exists else None
        dout=default.stdout if default else 'target file absent'
        fuzz='yes' if 'fuzz' in dout else 'no'
        mo=re.search(r'offset ([+-]?[0-9]+)', dout)
        offset=mo.group(1) if mo else ('yes' if 'offset' in dout else 'no')
        ctx=hunk[0].strip().split('@@',2)[-1].strip()
        if not exists:
            cls='file-absent'; action='drop this hunk only if no 367.134 equivalent exists'
        elif strict and strict.returncode==0 and 'offset' not in (strict.stdout or ''):
            cls='clean'; action='none'
        elif strict and strict.returncode==0:
            cls='refresh-offset'; action='refresh context/line numbers'
        elif default and default.returncode==0 and fuzz=='no':
            cls='refresh-offset'; action='refresh context/line numbers'
        elif default and default.returncode==0:
            cls='refresh-fuzz'; action='refresh context to remove fuzz'
        else:
            cls='rebase-context'; action='inspect target symbol and rebase or classify as absent'
        rows.append([p,f,hno,'yes' if exists else 'no','clean' if strict and strict.returncode==0 else 'fail','clean' if default and default.returncode==0 else 'fail',fuzz,offset,ctx or 'none',purpose(p,ctx),cls,action])
        shutil.rmtree(tmp,ignore_errors=True)
with (report/'module-patch-hunks.tsv').open('w',newline='') as fp:
    csv.writer(fp,delimiter='\t').writerows([headers,*rows])
with (report/'module-patch-hunks.md').open('w') as fp:
    fp.write('| patch | file | hunk | strict | default | fuzz | offset | classification | action |\n|---|---|---:|---|---|---|---|---|---|\n')
    for r in rows:
        fp.write(f'| {r[0]} | {r[1]} | {r[2]} | {r[4]} | {r[5]} | {r[6]} | {r[7]} | {r[10]} | {r[11]} |\n')
PY
