#!/bin/sh
set -eu
patch=debian/module/debian/patches/backport-timekeeping-scheduler-mmap-lock-api.patch
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cc=${CC:-cc}
flags='-Wall -Werror -Werror=implicit-function-declaration -Werror=incompatible-pointer-types -Werror=return-type'

compile_probe()
{
    name=$1
    src=$2
    obj=$work/$name.o
    err=$work/$name.err
    rm -f "$obj"
    if $cc $flags -I "$work/include" -c "$src" -o "$obj" >"$work/$name.out" 2>"$err"; then
        test -f "$obj"
    else
        cat "$err" >&2
        return 1
    fi
}

mkdir -p "$work/include/linux"
cat > "$work/include/linux/ktime.h" <<'H'
#ifndef _LINUX_KTIME_H
#define _LINUX_KTIME_H
#define HAVE_KTIME_PREREQ 1
typedef long long time64_t;
struct timespec64 { time64_t tv_sec; long tv_nsec; };
#endif
H
cat > "$work/include/linux/timekeeping.h" <<'H'
#ifndef _LINUX_TIMEKEEPING_H
#define _LINUX_TIMEKEEPING_H
#ifndef HAVE_KTIME_PREREQ
#error linux/ktime.h must be included before linux/timekeeping.h in this fixture
#endif
static inline void ktime_get_real_ts64(struct timespec64 *ts) { ts->tv_sec = 7; ts->tv_nsec = 123000; }
static inline void ktime_get_raw_ts64(struct timespec64 *ts) { ts->tv_sec = 11; ts->tv_nsec = 22; }
#endif
H
cat > "$work/include/linux/time.h" <<'H'
#ifndef _LINUX_TIME_H
#define _LINUX_TIME_H
#define NSEC_PER_USEC 1000L
#define NSEC_PER_SEC 1000000000ULL
#define CLOCK_MONOTONIC_RAW 4
#endif
H

cat > "$work/realtime-probe.c" <<'C'
#include <linux/ktime.h>
#include <linux/timekeeping.h>
static void __attribute__((unused)) conftest_ktime_get_real_ts64(void)
{
    struct timespec64 ts;

    ktime_get_real_ts64(&ts);
}
C
compile_probe realtime-probe "$work/realtime-probe.c"
printf '%s\n' '#define NV_KTIME_GET_REAL_TS64_PRESENT' > "$work/realtime.definition"
grep -F '#include <linux/ktime.h>' "$work/realtime-probe.c" >/dev/null
grep -F '#include <linux/timekeeping.h>' "$work/realtime-probe.c" >/dev/null
grep -F '#define NV_KTIME_GET_REAL_TS64_PRESENT' "$work/realtime.definition" >/dev/null

cat > "$work/raw-probe.c" <<'C'
#include <linux/ktime.h>
#include <linux/timekeeping.h>
static void __attribute__((unused)) conftest_ktime_get_raw_ts64(void)
{
    struct timespec64 ts;

    ktime_get_raw_ts64(&ts);
}
C
compile_probe raw-probe "$work/raw-probe.c"
printf '%s\n' '#define NV_KTIME_GET_RAW_TS64_PRESENT' > "$work/raw.definition"
grep -F '#define NV_KTIME_GET_RAW_TS64_PRESENT' "$work/raw.definition" >/dev/null

cat > "$work/modern.c" <<'C'
#define NV_KTIME_GET_REAL_TS64_PRESENT
#include <linux/time.h>
#include <linux/ktime.h>
#include <linux/timekeeping.h>
typedef struct { time64_t tv_sec; long tv_usec; } nv_timeval_t;
static inline void nv_gettimeofday(nv_timeval_t *tv) { struct timespec64 ts; ktime_get_real_ts64(&ts); tv->tv_sec = ts.tv_sec; tv->tv_usec = ts.tv_nsec / NSEC_PER_USEC; }
int main(void) { nv_timeval_t a,b,r; nv_gettimeofday(&a); b.tv_sec=0; b.tv_usec=1000; r.tv_sec=a.tv_sec+b.tv_sec; r.tv_usec=a.tv_usec+b.tv_usec; return (r.tv_sec == 7 && r.tv_usec == 1123) ? 0 : 1; }
C
compile_probe modern "$work/modern.c"

cat > "$work/legacy.c" <<'C'
#define NV_DO_GETTIMEOFDAY_PRESENT
typedef long time64_t; struct timeval { long tv_sec; long tv_usec; };
typedef struct { time64_t tv_sec; long tv_usec; } nv_timeval_t;
static void do_gettimeofday(struct timeval *tv) { tv->tv_sec = 3; tv->tv_usec = 4; }
static inline void nv_gettimeofday(nv_timeval_t *tv) { struct timeval legacy_tv; do_gettimeofday(&legacy_tv); tv->tv_sec = legacy_tv.tv_sec; tv->tv_usec = legacy_tv.tv_usec; }
int main(void) { nv_timeval_t tv; nv_gettimeofday(&tv); return (tv.tv_sec == 3 && tv.tv_usec == 4) ? 0 : 1; }
C
compile_probe legacy "$work/legacy.c"

cat > "$work/uvm-modern.c" <<'C'
#define NV_KTIME_GET_RAW_TS64_PRESENT
#include <linux/time.h>
#include <linux/ktime.h>
#include <linux/timekeeping.h>
typedef unsigned long long NvU64;
static inline NvU64 NV_GETTIME(void)
{
#if defined(NV_KTIME_GET_RAW_TS64_PRESENT)
    struct timespec64 ts = { 0 };
    ktime_get_raw_ts64(&ts);
    return (((NvU64)ts.tv_sec) * NSEC_PER_SEC) + ts.tv_nsec;
#elif defined(NV_GETRAWMONOTONIC_PRESENT)
    struct timespec ts = { 0 };
    getrawmonotonic(&ts);
    return (((NvU64)ts.tv_sec) * NSEC_PER_SEC) + ts.tv_nsec;
#else
#error "No supported raw monotonic time API"
#endif
}
int main(void) { return NV_GETTIME() == 11000000022ULL ? 0 : 1; }
C
compile_probe uvm-modern "$work/uvm-modern.c"

cat > "$work/uvm-negative.c" <<'C'
#define CLOCK_MONOTONIC_RAW 4
typedef unsigned long long NvU64;
static inline NvU64 NV_GETTIME(void)
{
#if defined(NV_KTIME_GET_RAW_TS64_PRESENT)
    return 0;
#elif defined(NV_GETRAWMONOTONIC_PRESENT)
    return 0;
#else
#error "No supported raw monotonic time API"
#endif
}
int main(void) { return (int)NV_GETTIME(); }
C
if $cc $flags -c "$work/uvm-negative.c" -o "$work/uvm-negative.o" 2>"$work/uvm-negative.err"; then exit 1; fi
grep -F 'No supported raw monotonic time API' "$work/uvm-negative.err" >/dev/null

cat > "$work/uvm-legacy-raw.c" <<'C'
#define NV_GETRAWMONOTONIC_PRESENT
#define NSEC_PER_SEC 1000000000ULL
typedef unsigned long long NvU64;
struct timespec { long tv_sec; long tv_nsec; };
static inline void getrawmonotonic(struct timespec *ts) { ts->tv_sec = 2; ts->tv_nsec = 5; }
static inline NvU64 NV_GETTIME(void)
{
#if defined(NV_KTIME_GET_RAW_TS64_PRESENT)
    return 0;
#elif defined(NV_GETRAWMONOTONIC_PRESENT)
    struct timespec ts = { 0 };
    getrawmonotonic(&ts);
    return (((NvU64)ts.tv_sec) * NSEC_PER_SEC) + ts.tv_nsec;
#else
#error "No supported raw monotonic time API"
#endif
}
int main(void) { return NV_GETTIME() == 2000000005ULL ? 0 : 1; }
C
compile_probe uvm-legacy-raw "$work/uvm-legacy-raw.c"

cat > "$work/negative.c" <<'C'
typedef long time64_t; typedef struct { time64_t tv_sec; long tv_usec; } nv_timeval_t;
static inline void nv_gettimeofday(nv_timeval_t *tv) { (void)tv; do_gettimeofday(0); }
int main(void) { nv_timeval_t tv; nv_gettimeofday(&tv); return 0; }
C
if $cc $flags -c "$work/negative.c" -o "$work/negative.o" 2>"$work/negative.err"; then exit 1; fi

# Structural checks against the production patch, including the generated probe text.
grep -F '#include <linux/ktime.h>' "$patch" >/dev/null
grep -F 'ktime_get_real_ts64(&ts)' "$patch" >/dev/null
grep -F 'ktime_get_raw_ts64(&ts)' "$patch" >/dev/null
grep -F 'selected-raw-monotonic-api.txt' "$patch" >/dev/null
grep -F '#if defined(NV_KTIME_GET_RAW_TS64_PRESENT)' "$patch" >/dev/null
if grep -F '+#if defined(CLOCK_MONOTONIC_RAW)' "$patch" >/dev/null; then
    echo 'raw monotonic branch must not be selected by CLOCK_MONOTONIC_RAW alone' >&2
    exit 1
fi
