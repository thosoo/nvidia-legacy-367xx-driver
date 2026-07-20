#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
patch=$repo/debian/module/debian/patches/backport-procfs-api-compat.patch
test -f "$patch"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cc=${CC:-cc}
cflags='-Wall -Werror -Werror=implicit-function-declaration -Werror=incompatible-pointer-types -Werror=return-type'

compile_ok()
{
    name=$1
    shift
    "$cc" $cflags "$@" -c "$work/$name.c" -o "$work/$name.o"
    test -f "$work/$name.o"
}

compile_fail()
{
    name=$1
    shift
    if "$cc" $cflags "$@" -c "$work/$name.c" -o "$work/$name.o" > "$work/$name.out" 2> "$work/$name.err"; then
        echo "expected fixture to fail: $name" >&2
        exit 1
    fi
    test ! -f "$work/$name.o"
}

cat > "$work/procfs_compat_common.h" <<'C'
typedef long ssize_t;
typedef long loff_t;
typedef unsigned long size_t;
#define __user
#define THIS_MODULE ((void *)0)
struct inode { int dummy; };
struct file { void *private_data; };
struct seq_file { void *private; };
struct proc_dir_entry { int dummy; };
static int single_open(struct file *file, int (*show)(struct seq_file *, void *), void *data)
{
    (void)file; (void)show; (void)data; return 0;
}
static ssize_t seq_read(struct file *file, char __user *buf, size_t size, loff_t *pos)
{
    (void)file; (void)buf; (void)size; (void)pos; return 0;
}
static loff_t seq_lseek(struct file *file, loff_t off, int whence)
{
    (void)file; (void)off; (void)whence; return 0;
}
static int single_release(struct inode *inode, struct file *file)
{
    (void)inode; (void)file; return 0;
}
static int sample_show(struct seq_file *s, void *v)
{
    (void)s; (void)v; return 0;
}
#define NV_DEFINE_SAMPLE_FILE                                                \
    static int sample_open(struct inode *inode, struct file *filep)          \
    {                                                                        \
        return single_open(filep, sample_show, NV_PDE_DATA(inode));          \
    }                                                                        \
    static const nv_proc_ops_t sample_fops = {                               \
        NV_PROC_OPS_OWNER                                                    \
        NV_PROC_OPS_OPEN = sample_open,                                      \
        NV_PROC_OPS_READ = seq_read,                                         \
        NV_PROC_OPS_LSEEK = seq_lseek,                                       \
        NV_PROC_OPS_RELEASE = single_release,                                \
    };
C

cat > "$work/modern.c" <<'C'
#include "procfs_compat_common.h"
struct proc_ops {
    int (*proc_open)(struct inode *, struct file *);
    ssize_t (*proc_read)(struct file *, char __user *, size_t, loff_t *);
    loff_t (*proc_lseek)(struct file *, loff_t, int);
    int (*proc_release)(struct inode *, struct file *);
    ssize_t (*proc_write)(struct file *, const char __user *, size_t, loff_t *);
};
static void *pde_data(const struct inode *inode) { return (void *)inode; }
#define NV_PROC_OPS_PRESENT
#define NV_PDE_DATA_LOWER_CASE_PRESENT
#if defined(NV_PROC_OPS_PRESENT)
typedef struct proc_ops nv_proc_ops_t;
# define NV_PROC_OPS_OWNER
# define NV_PROC_OPS_OPEN .proc_open
# define NV_PROC_OPS_READ .proc_read
# define NV_PROC_OPS_LSEEK .proc_lseek
# define NV_PROC_OPS_RELEASE .proc_release
# define NV_PROC_OPS_GET_WRITE(fops) ((fops)->proc_write)
#else
#error wrong branch
#endif
#if defined(NV_PDE_DATA_LOWER_CASE_PRESENT)
# define NV_PDE_DATA(inode) pde_data(inode)
#else
#error wrong pde branch
#endif
NV_DEFINE_SAMPLE_FILE
static struct proc_dir_entry *proc_create_data(const char *name, int mode, struct proc_dir_entry *parent, const struct proc_ops *ops, void *data)
{
    (void)name; (void)mode; (void)parent; (void)ops; (void)data; return 0;
}
int main(void) { struct inode i; struct file f; (void)sample_open(&i, &f); proc_create_data("x", 0, 0, &sample_fops, 0); return NV_PROC_OPS_GET_WRITE(&sample_fops) != 0; }
C
compile_ok modern

cat > "$work/intermediate.c" <<'C'
#include "procfs_compat_common.h"
struct file_operations {
    void *owner;
    int (*open)(struct inode *, struct file *);
    ssize_t (*read)(struct file *, char __user *, size_t, loff_t *);
    loff_t (*llseek)(struct file *, loff_t, int);
    int (*release)(struct inode *, struct file *);
    ssize_t (*write)(struct file *, const char __user *, size_t, loff_t *);
};
static void *PDE_DATA(const struct inode *inode) { return (void *)inode; }
typedef struct file_operations nv_proc_ops_t;
# define NV_PROC_OPS_OWNER .owner = THIS_MODULE,
# define NV_PROC_OPS_OPEN .open
# define NV_PROC_OPS_READ .read
# define NV_PROC_OPS_LSEEK .llseek
# define NV_PROC_OPS_RELEASE .release
# define NV_PROC_OPS_GET_WRITE(fops) ((fops)->write)
# define NV_PDE_DATA(inode) PDE_DATA(inode)
NV_DEFINE_SAMPLE_FILE
int main(void) { struct inode i; struct file f; (void)sample_fops; return sample_open(&i, &f); }
C
compile_ok intermediate

cat > "$work/ancient.c" <<'C'
#include "procfs_compat_common.h"
struct file_operations {
    void *owner;
    int (*open)(struct inode *, struct file *);
    ssize_t (*read)(struct file *, char __user *, size_t, loff_t *);
    loff_t (*llseek)(struct file *, loff_t, int);
    int (*release)(struct inode *, struct file *);
    ssize_t (*write)(struct file *, const char __user *, size_t, loff_t *);
};
struct proc_dir_entry_private { void *data; };
static struct proc_dir_entry_private direct_entry;
static struct proc_dir_entry_private *PDE(const struct inode *inode) { (void)inode; return &direct_entry; }
typedef struct file_operations nv_proc_ops_t;
# define NV_PROC_OPS_OWNER .owner = THIS_MODULE,
# define NV_PROC_OPS_OPEN .open
# define NV_PROC_OPS_READ .read
# define NV_PROC_OPS_LSEEK .llseek
# define NV_PROC_OPS_RELEASE .release
# define NV_PROC_OPS_GET_WRITE(fops) ((fops)->write)
# define NV_PDE_DATA(inode) PDE(inode)->data
NV_DEFINE_SAMPLE_FILE
int main(void) { struct inode i; struct file f; (void)sample_fops; return sample_open(&i, &f); }
C
compile_ok ancient

cat > "$work/negative_file_ops_to_proc_ops.c" <<'C'
#include "procfs_compat_common.h"
struct file_operations { int (*open)(struct inode *, struct file *); };
struct proc_ops { int (*proc_open)(struct inode *, struct file *); };
static struct proc_dir_entry *proc_create_data(const char *name, int mode, struct proc_dir_entry *parent, const struct proc_ops *ops, void *data)
{ (void)name; (void)mode; (void)parent; (void)ops; (void)data; return 0; }
static const struct file_operations fops = { 0 };
int main(void) { proc_create_data("x", 0, 0, &fops, 0); return 0; }
C
compile_fail negative_file_ops_to_proc_ops

cat > "$work/negative_pde_direct.c" <<'C'
#include "procfs_compat_common.h"
#define NV_PDE_DATA(inode) PDE(inode)->data
int main(void) { struct inode i; return NV_PDE_DATA(&i) != 0; }
C
compile_fail negative_pde_direct

cat > "$work/negative_pde_lower.c" <<'C'
#include "procfs_compat_common.h"
#define NV_PDE_DATA(inode) pde_data(inode)
int main(void) { struct inode i; return NV_PDE_DATA(&i) != 0; }
C
compile_fail negative_pde_lower

cat > "$work/negative_owner_proc_ops.c" <<'C'
#include "procfs_compat_common.h"
struct proc_ops { int (*proc_open)(struct inode *, struct file *); };
static const struct proc_ops ops = { .owner = THIS_MODULE, };
int main(void) { (void)ops; return 0; }
C
compile_fail negative_owner_proc_ops

# Ensure the patch contains the concrete producers and centralized consumers.
for token in NV_PROC_OPS_PRESENT NV_PDE_DATA_LOWER_CASE_PRESENT NV_PDE_DATA_UPPER_CASE_PRESENT NV_PDE_STRUCT_ACCESS_PRESENT NV_PROC_OPS_OPEN NV_PROC_OPS_GET_WRITE; do
    grep -F "$token" "$patch" >/dev/null
 done

# The modern branch must not emit a proc_ops owner initializer.
if awk '/NV_PROC_OPS_PRESENT/{modern=1} modern && /#else/{exit} modern && /owner[[:space:]]*=/{found=1} END{exit found ? 0 : 1}' "$patch" >/dev/null; then
    echo 'modern proc_ops branch contains .owner initializer' >&2
    exit 1
fi

printf '%s\n' 'procfs compatibility fixtures passed'
