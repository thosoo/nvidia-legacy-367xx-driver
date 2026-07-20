#!/bin/sh
set -eu
patch=debian/module/debian/patches/backport-timekeeping-scheduler-mmap-lock-api.patch
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cc=${CC:-cc}; flags='-Wall -Werror -Werror=implicit-function-declaration -Werror=incompatible-pointer-types -Werror=return-type'
cat > "$work/modern.c" <<'C'
#define NV_KTIME_GET_REAL_TS64_PRESENT
#define NSEC_PER_USEC 1000L
typedef long time64_t; struct timespec64 { time64_t tv_sec; long tv_nsec; };
typedef struct { time64_t tv_sec; long tv_usec; } nv_timeval_t;
static void ktime_get_real_ts64(struct timespec64 *ts) { ts->tv_sec = 7; ts->tv_nsec = 123000; }
static inline void nv_gettimeofday(nv_timeval_t *tv) { struct timespec64 ts; ktime_get_real_ts64(&ts); tv->tv_sec = ts.tv_sec; tv->tv_usec = ts.tv_nsec / NSEC_PER_USEC; }
int main(void) { nv_timeval_t a,b,r; nv_gettimeofday(&a); b.tv_sec=0; b.tv_usec=1000; r.tv_sec=a.tv_sec+b.tv_sec; r.tv_usec=a.tv_usec+b.tv_usec; return (r.tv_sec == 7 && r.tv_usec == 1123) ? 0 : 1; }
C
$cc $flags -c "$work/modern.c" -o "$work/modern.o"
cat > "$work/legacy.c" <<'C'
#define NV_DO_GETTIMEOFDAY_PRESENT
typedef long time64_t; struct timeval { long tv_sec; long tv_usec; };
typedef struct { time64_t tv_sec; long tv_usec; } nv_timeval_t;
static void do_gettimeofday(struct timeval *tv) { tv->tv_sec = 3; tv->tv_usec = 4; }
static inline void nv_gettimeofday(nv_timeval_t *tv) { struct timeval legacy_tv; do_gettimeofday(&legacy_tv); tv->tv_sec = legacy_tv.tv_sec; tv->tv_usec = legacy_tv.tv_usec; }
int main(void) { nv_timeval_t tv; nv_gettimeofday(&tv); return (tv.tv_sec == 3 && tv.tv_usec == 4) ? 0 : 1; }
C
$cc $flags -c "$work/legacy.c" -o "$work/legacy.o"
cat > "$work/negative.c" <<'C'
typedef long time64_t; typedef struct { time64_t tv_sec; long tv_usec; } nv_timeval_t;
static inline void nv_gettimeofday(nv_timeval_t *tv) { (void)tv; do_gettimeofday(0); }
int main(void) { nv_timeval_t tv; nv_gettimeofday(&tv); return 0; }
C
if $cc $flags -c "$work/negative.c" -o "$work/negative.o" 2>"$work/negative.err"; then exit 1; fi
grep -F 'ktime_get_real_ts64(&ts)' "$patch" >/dev/null
grep -F 'nv_gettimeofday(&tm_aux)' "$patch" >/dev/null
