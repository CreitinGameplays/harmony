// Harmony runtime (docs/harmony.md §14, §19.4).
//
// This is LIBRARY code, not compiler code (the split rule, §19.8.4): the
// compiler only emits calls to these hooks. It is freestanding — no libc —
// so it works with `-nostdlib -static`. The same C source compiles to `rt.o`
// for the LLVM path (clang) and is the template for the future C backend's
// `rt.h`.
//
// What lives here:
//   _start            the real entry point; calls the program's `main` and
//                     turns its i32 into the process exit code.
//   lc_trap           print a trap message to stderr and exit 70 (§14.3).
//   lc_check_index    bounds check for `a[i]` (T-INDEX).
//   lc_check_slice    bounds check for `&a[lo..hi]` (T-SLICE).
//   lc_alloc          bump/heap allocation that traps on OOM (T-OOM).
//   stack guard       a SIGSEGV handler on an alternate stack that turns
//                     stack exhaustion into a T-STACK trap (§14.2).
//   lc_put_*          formatting hooks for print/println/eprintln (§15.1).
//   lc_trap_msg/      prelude traps: trap/assert/unreachable/exit (§15.1).
//   lc_thread_*       threads via clone(2) + futex, joined or detached
//                     (§20.3 item 4); no libc or pthread needed.
//   memset/memcpy/    the standard freestanding memory builtins clang's
//   memmove/memcmp    optimizer may emit for a large aggregate init/copy.
//
// Everything is deterministic and allocation-free on the hot path.

typedef unsigned long usize_t;
typedef long          isize_t;

// Linux x86-64 syscall numbers (the only platform the seed targets today).
#define SYS_read   0
#define SYS_write  1
#define SYS_mmap   9
#define SYS_munmap 11
#define SYS_rt_sigaction 13
#define SYS_clone  56
#define SYS_exit   60
#define SYS_exit_group 231
#define SYS_sigaltstack 131
#define SYS_futex  202
#define SYS_sched_yield 24

// The signal we guard against, and the flag bits it needs.
#define SIGSEGV    11
#define SA_ONSTACK 0x08000000
#define SA_SIGINFO 0x00000004
#define SA_RESTORER 0x04000000
// SA_RESETHAND installs SIG_DFL again just before the handler runs, so
// returning from the handler lets the faulting instruction re-execute and die
// with a genuine SIGSEGV (the non-guard-page path below relies on this).
#define SA_RESETHAND 0x80000000
#define ALT_STACK_SIZE (64 * 1024)

static long sys(long n, long a, long b, long c) {
    long ret;
    __asm__ volatile("syscall"
                     : "=a"(ret)
                     : "a"(n), "D"(a), "S"(b), "d"(c)
                     : "rcx", "r11", "memory");
    return ret;
}

// ---------------------------------------------------------------------------
// Freestanding memory builtins.
//
// clang's optimizer is free to lower a large aggregate initialization or copy
// into a `memset`/`memcpy`/`memmove` libcall, and under `-ffreestanding
// -nostdlib` there is no libc to resolve them. Providing them here keeps the
// runtime self-contained (docs/harmony.md §19.8.4): the compiler emits the
// stores, clang may fold them into a call, and this is the body.
//
// The names are the standard ones so clang recognizes them as the builtins it
// wants to call (a `#define memset ...` would stop the recognition). They are
// defined only if not already provided, so linking a real libc later still
// works.
// ---------------------------------------------------------------------------
void *memset(void *dst, int c, usize_t n) {
    unsigned char *p = (unsigned char *) dst;
    unsigned char b = (unsigned char) c;
    usize_t i;
    for (i = 0; i < n; i++) { p[i] = b; }
    return dst;
}

void *memcpy(void *dst, const void *src, usize_t n) {
    unsigned char *d = (unsigned char *) dst;
    const unsigned char *s = (const unsigned char *) src;
    usize_t i;
    for (i = 0; i < n; i++) { d[i] = s[i]; }
    return dst;
}

void *memmove(void *dst, const void *src, usize_t n) {
    unsigned char *d = (unsigned char *) dst;
    const unsigned char *s = (const unsigned char *) src;
    if (d == s || n == 0) { return dst; }
    if (d < s) {
        usize_t i;
        for (i = 0; i < n; i++) { d[i] = s[i]; }
    } else {
        usize_t i = n;
        while (i > 0) { i--; d[i] = s[i]; }
    }
    return dst;
}

int memcmp(const void *a, const void *b, usize_t n) {
    const unsigned char *x = (const unsigned char *) a;
    const unsigned char *y = (const unsigned char *) b;
    usize_t i;
    for (i = 0; i < n; i++) {
        if (x[i] != y[i]) { return (int) x[i] - (int) y[i]; }
    }
    return 0;
}

// `__bzero` is an older spelling some clang releases still emit.
void __bzero(void *dst, usize_t n) { (void) memset(dst, 0, n); }

// The kernel's rt_sigaction ABI on x86-64: handler, flags, restorer, mask.
//
// With SA_SIGINFO the kernel calls `handler(sig, siginfo_t*, ucontext_t*)`,
// so the handler field is the three-argument form. We use it to read the
// faulting address (`si_addr`) and tell a stack overflow from any other bad
// memory access — both arrive as SIGSEGV, but only one is `T-STACK`.
struct ksigaction {
    void (*handler)(int, void *, void *);
    unsigned long flags;
    void (*restorer)(void);
    unsigned long mask;
};
// The kernel's stack_t for sigaltstack.
struct kstack {
    void *ss_sp;
    int   ss_flags;
    unsigned long ss_size;
};

// siginfo_t's leading three words: si_signo, si_errno, si_code; then the
// union `_sifields`, whose first member for SIGSEGV/SIGBUS is `si_addr`.
// The pointer lives at byte offset 16 in the x86-64 siginfo layout.
#define SI_ADDR_OFFSET 16


// mmap(NULL, len, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0) —
// six arguments, so the 4th/5th/6th go in r10/r8/r9.
static long sys_mmap(long len) {
    long ret;
    register long r10 __asm__("r10") = 0x22;   // MAP_PRIVATE | MAP_ANONYMOUS
    register long r8  __asm__("r8") = -1;      // fd
    register long r9  __asm__("r9") = 0;       // offset
    __asm__ volatile("syscall"
                     : "=a"(ret)
                     : "a"(9), "D"(0), "S"(len), "d"(3), "r"(r10), "r"(r8), "r"(r9)
                     : "rcx", "r11", "memory");
    return ret;
}

// A four-argument syscall (rt_sigaction needs the mask size in r10).
static long sys4(long n, long a, long b, long c, long d) {
    long ret;
    register long r10 __asm__("r10") = d;
    __asm__ volatile("syscall"
                     : "=a"(ret)
                     : "a"(n), "D"(a), "S"(b), "d"(c), "r"(r10)
                     : "rcx", "r11", "memory");
    return ret;
}

// ---------------------------------------------------------------------------
// Output. Buffered so a sequence of writes costs one syscall. The target fd
// is switchable so `println` (stdout, fd 1) and `eprintln` / trap messages
// (stderr, fd 2) share the same buffer (§15.1).
// ---------------------------------------------------------------------------
static char out_buf[4096];
static usize_t out_len;
static int out_fd = 2;      // traps and diagnostics default to stderr

static void out_flush(void) {
    if (out_len > 0) {
        sys(SYS_write, out_fd, (long) out_buf, (long) out_len);
        out_len = 0;
    }
}

static void out_char(char c) {
    if (out_len == sizeof(out_buf)) { out_flush(); }
    out_buf[out_len++] = c;
}

static void out_str(const char *s) {
    while (*s) { out_char(*s++); }
}

static void out_uint(unsigned long v) {
    char tmp[24];
    int n = 0;
    if (v == 0) { out_char('0'); return; }
    while (v > 0) { tmp[n++] = (char)('0' + (v % 10)); v /= 10; }
    while (n > 0) { out_char(tmp[--n]); }
}

static void out_int(long v) {
    if (v < 0) { out_char('-'); out_uint((unsigned long)(-v)); return; }
    out_uint((unsigned long) v);
}

// Hexadecimal (lowercase), used by `{:x}`.
static void out_hex(unsigned long v) {
    char tmp[16];
    int n = 0;
    if (v == 0) { out_char('0'); return; }
    while (v > 0) {
        int d = (int)(v & 0xF);
        tmp[n++] = (char)(d < 10 ? '0' + d : 'a' + (d - 10));
        v >>= 4;
    }
    while (n > 0) { out_char(tmp[--n]); }
}

// ---------------------------------------------------------------------------
// Formatting hooks (§15.1, §19.8.6). The compiler lowers `print`/`println`/
// `eprintln`/`format` to a sequence of these calls; the format-string *parsing*
// is the compiler's job (FMT-01) because there are no variadics. Width,
// zero-padding, precision, and the `{?}`/`{:x}` forms are all passed as plain
// arguments, so the runtime never re-parses the format.
// ---------------------------------------------------------------------------
void lc_set_fd(long fd) { out_flush(); out_fd = (int) fd; }
void lc_flush(void) { out_flush(); }

void lc_put_str(const char *p, long n) {
    long i;
    for (i = 0; i < n; i++) { out_char(p[i]); }
}

// Renders `body` (length `len`) right-aligned to `width`, padding with
// `padchar` (0 -> space).
static void out_pad(const char *body, int len, int width, int padchar) {
    int i;
    if (padchar == 0) { padchar = ' '; }
    for (i = len; i < width; i++) { out_char((char) padchar); }
    for (i = 0; i < len; i++) { out_char(body[i]); }
}

// Signed 64-bit decimal with optional width and zero padding.
void lc_put_i64(long v, long width, long zero) {
    char tmp[24];
    int n = 0;
    int neg = 0;
    unsigned long u;
    if (v < 0) { neg = 1; u = (unsigned long)(-v); } else { u = (unsigned long) v; }
    if (u == 0) { tmp[n++] = '0'; }
    while (u > 0) { tmp[n++] = (char)('0' + (u % 10)); u /= 10; }
    {
        char buf[24];
        int k = 0;
        if (neg) { buf[k++] = '-'; }
        while (n > 0) { buf[k++] = tmp[--n]; }
        // Zero padding goes after the sign.
        if (zero && (int) width > k) {
            int pad = (int) width - k;
            int j;
            if (neg) { out_char('-'); }
            for (j = 0; j < pad; j++) { out_char('0'); }
            for (j = 0; j < k; j++) { if (!(neg && j == 0)) { out_char(buf[j]); } }
            return;
        }
        out_pad(buf, k, (int) width, 0);
    }
}

void lc_put_u64(unsigned long v, long width, long zero) {
    char tmp[24];
    int n = 0;
    if (v == 0) { tmp[n++] = '0'; }
    while (v > 0) { tmp[n++] = (char)('0' + (v % 10)); v /= 10; }
    {
        char buf[24];
        int k = 0;
        while (n > 0) { buf[k++] = tmp[--n]; }
        out_pad(buf, k, (int) width, zero ? '0' : 0);
    }
}

void lc_put_hex(long v, long width, long zero) {
    char tmp[20];
    int n = 0;
    unsigned long u = (unsigned long) v;
    if (u == 0) { tmp[n++] = '0'; }
    while (u > 0) {
        int d = (int)(u & 0xF);
        tmp[n++] = (char)(d < 10 ? '0' + d : 'a' + (d - 10));
        u >>= 4;
    }
    {
        char buf[20];
        int k = 0;
        while (n > 0) { buf[k++] = tmp[--n]; }
        out_pad(buf, k, (int) width, zero ? '0' : 0);
    }
}

void lc_put_bool(long v, long width, long zero) {
    const char *s = v ? "true" : "false";
    int len = v ? 4 : 5;
    out_pad(s, len, (int) width, zero ? '0' : 0);
}

// A Unicode scalar value as UTF-8.
void lc_put_char(long v) {
    unsigned long c = (unsigned long) v;
    if (c < 0x80) {
        out_char((char) c);
    } else if (c < 0x800) {
        out_char((char)(0xC0 | (c >> 6)));
        out_char((char)(0x80 | (c & 0x3F)));
    } else if (c < 0x10000) {
        out_char((char)(0xE0 | (c >> 12)));
        out_char((char)(0x80 | ((c >> 6) & 0x3F)));
        out_char((char)(0x80 | (c & 0x3F)));
    } else {
        out_char((char)(0xF0 | (c >> 18)));
        out_char((char)(0x80 | ((c >> 12) & 0x3F)));
        out_char((char)(0x80 | ((c >> 6) & 0x3F)));
        out_char((char)(0x80 | (c & 0x3F)));
    }
}

// A decimal for f64. With a precision, exactly `prec` fractional digits;
// otherwise up to six, trailing zeros trimmed. Enough for the M1 surface
// (the shortest round-trip algorithm is library work per §19.8.6).
void lc_put_f64(double d, long width, long prec, long has_prec) {
    char buf[64];
    int k = 0;
    long ip;
    unsigned long frac;
    int i;
    int digits;
    if (d != d) { out_pad("NaN", 3, (int) width, 0); return; }
    if (d < 0) { buf[k++] = '-'; d = -d; }
    ip = (long) d;
    // Integer part, in reverse then flipped.
    {
        char tmp[24];
        int n = 0;
        unsigned long u = (unsigned long) ip;
        if (u == 0) { tmp[n++] = '0'; }
        while (u > 0) { tmp[n++] = (char)('0' + (u % 10)); u /= 10; }
        while (n > 0) { buf[k++] = tmp[--n]; }
    }
    if (has_prec) { digits = (int) prec; } else { digits = 6; }
    if (digits > 0 && k < 60) {
        frac = (unsigned long)((d - (double) ip) * 1000000.0 + 0.5);
        {
            char tmp[6];
            int last;
            for (i = 5; i >= 0; i--) { tmp[i] = (char)('0' + (frac % 10)); frac /= 10; }
            if (has_prec) {
                buf[k++] = '.';
                for (i = 0; i < digits && i < 6; i++) { buf[k++] = tmp[i]; }
            } else {
                // Default `{}`: trim trailing zeros; an integral float keeps
                // one so it still reads as a float ("3.0").
                last = 5;
                while (last >= 0 && tmp[last] == '0') { last = last - 1; }
                buf[k++] = '.';
                if (last < 0) {
                    buf[k++] = '0';
                } else {
                    for (i = 0; i <= last; i++) { buf[k++] = tmp[i]; }
                }
            }
        }
    } else if (!has_prec && k < 60) {
        buf[k++] = '.';
        buf[k++] = '0';
    } else if (has_prec && k < 60) {
        buf[k++] = '.';
    }
    out_pad(buf, k, (int) width, 0);
}

// ---------------------------------------------------------------------------
// Traps (§14.1). The compiler passes a numeric trap code and the source
// location (file index + line + col), packed as small integers so no string
// formatting is needed in the emitted code.
// ---------------------------------------------------------------------------
// Trap codes, mirrored from docs/harmony.md §14.1.
#define T_INDEX      1
#define T_SLICE      2
#define T_OVERFLOW   3
#define T_DIV0       4
#define T_SHIFT      5
#define T_OOM        6
#define T_STACK      7
#define T_ASSERT     8
#define T_EXPECT     9
#define T_USER      10
#define T_UNREACHABLE 11

static const char *trap_name(long code) {
    switch (code) {
        case T_INDEX:       return "T-INDEX";
        case T_SLICE:       return "T-SLICE";
        case T_OVERFLOW:    return "T-OVERFLOW";
        case T_DIV0:        return "T-DIV0";
        case T_SHIFT:       return "T-SHIFT";
        case T_OOM:         return "T-OOM";
        case T_STACK:       return "T-STACK";
        case T_ASSERT:      return "T-ASSERT";
        case T_EXPECT:      return "T-EXPECT";
        case T_USER:        return "T-USER";
        case T_UNREACHABLE: return "T-UNREACHABLE";
        default:            return "T-?";
    }
}

static const char *trap_msg(long code) {
    switch (code) {
        case T_INDEX:       return "index out of range";
        case T_SLICE:       return "invalid slice range";
        case T_OVERFLOW:    return "integer overflow";
        case T_DIV0:        return "division by zero";
        case T_SHIFT:       return "shift amount out of range";
        case T_OOM:         return "allocation failed";
        case T_STACK:       return "stack exhausted";
        case T_ASSERT:      return "assertion failed";
        case T_EXPECT:      return "unexpected Empty / Bad";
        case T_USER:        return "trap";
        case T_UNREACHABLE: return "reached unreachable()";
        default:            return "trap";
    }
}

// lc_trap(code, line, col, detail) — noreturn.
void lc_trap(long code, long line, long col, long detail) {
    // A trap always reports on stderr, whatever fd a prior `print` left set.
    out_flush();
    out_fd = 2;
    out_str("TRAP  ");
    out_str(trap_name(code));
    out_str("  ");
    out_str(trap_msg(code));
    if (detail != 0) {
        out_str(" (");
        out_int(detail);
        out_str(")");
    }
    if (line > 0) {
        out_str("  at line ");
        out_int(line);
        out_str(":");
        out_int(col);
    }
    out_char('\n');
    out_flush();
    sys(SYS_exit_group, 70, 0, 0);   // §14.3: trap exit status, process-wide
    for (;;) { }
}

// lc_check_index(i, n, line, col) — trap if i is out of [0, n).
void lc_check_index(long i, long n, long line, long col) {
    if (i < 0 || i >= n) {
        lc_trap(T_INDEX, line, col, i);
    }
}

// ---------------------------------------------------------------------------
// Prelude traps (§15.1): trap(msg), assert(cond[, msg]), unreachable(), exit().
// These are the compiler-recognized builtins the self-hosted rewrite needs to
// report compiler errors and stop. A user message (when present) replaces the
// generic trap text; the code and location still print (§14.2).
// ---------------------------------------------------------------------------
static void out_user_msg(const char *p, long n) {
    long i;
    out_fd = 2;
    for (i = 0; i < n; i++) { out_char(p[i]); }
}

// lc_trap_msg(ptr, len, line, col) — T-USER with the user's message.
void lc_trap_msg(const char *p, long n, long line, long col) {
    out_flush();
    out_fd = 2;
    out_str("TRAP  T-USER  ");
    out_user_msg(p, n);
    if (line > 0) {
        out_str("  at line ");
        out_int(line);
        out_str(":");
        out_int(col);
    }
    out_char('\n');
    out_flush();
    sys(SYS_exit_group, 70, 0, 0);
    for (;;) { }
}

// lc_assert(cond, ptr, len, line, col) — T-ASSERT when cond is false. A zero
// length means the one-argument `assert(cond)` form (generic message).
void lc_assert(long cond, const char *p, long n, long line, long col) {
    if (cond) { return; }
    out_flush();
    out_fd = 2;
    out_str("TRAP  T-ASSERT  ");
    if (n > 0) { out_user_msg(p, n); } else { out_str("assertion failed"); }
    if (line > 0) {
        out_str("  at line ");
        out_int(line);
        out_str(":");
        out_int(col);
    }
    out_char('\n');
    out_flush();
    sys(SYS_exit_group, 70, 0, 0);
    for (;;) { }
}

// lc_unreachable(line, col) — T-UNREACHABLE, the `unreachable()` builtin.
void lc_unreachable(long line, long col) {
    lc_trap(T_UNREACHABLE, line, col, 0);
}

// lc_exit(code) — flush and stop with the given status (§14.3). No hooks run.
void lc_exit(long code) {
    out_flush();
    sys(SYS_exit_group, code & 0xff, 0, 0);
    for (;;) { }
}

// lc_check_slice(lo, hi, len, line, col) — trap unless the half-open range
// [lo, hi) fits inside [0, len). Guards `&a[1..3]` (§5.2, T-SLICE).
void lc_check_slice(long lo, long hi, long len, long line, long col) {
    if (lo < 0 || hi < lo || hi > len) {
        lc_trap(T_SLICE, line, col, lo);
    }
}

// lc_check_boundary(ptr, len, idx, line, col) — trap unless `idx` sits on a
// UTF-8 character boundary of the `&str` at (ptr, len) (§5.2: a `&s[lo..hi]`
// slice must not split a code point). `idx == len` is the end and is valid;
// otherwise the byte at `idx` must not be a continuation byte (`10xxxxxx`).
void lc_check_boundary(const char *ptr, long len, long idx, long line, long col) {
    if (idx < 0 || idx > len) {
        lc_trap(T_SLICE, line, col, idx);
    }
    if (idx == len) { return; }
    if ((((unsigned char) ptr[idx]) & 0xC0) == 0x80) {
        lc_trap(T_SLICE, line, col, idx);
    }
}

// lc_slice_eq(a_ptr, a_len, b_ptr, b_len) — element-wise byte equality of two
// (pointer, length) pairs (§7.4: `==` on slices/`&str` compares the contents,
// not the pair addresses). Returns 1 when equal, 0 otherwise.
long lc_slice_eq(const void *a_ptr, long a_len, const void *b_ptr, long b_len) {
    long i;
    const unsigned char *a;
    const unsigned char *b;
    if (a_len != b_len) { return 0; }
    a = (const unsigned char *) a_ptr;
    b = (const unsigned char *) b_ptr;
    for (i = 0; i < a_len; i++) {
        if (a[i] != b[i]) { return 0; }
    }
    return 1;
}

// ---------------------------------------------------------------------------
// Allocation (§12, §19.8.4). A bump allocator over mmap'd pages: fast, and
// enough for M1. A real `dealloc` arrives with the std module (v1 frees
// through drop glue; the OS reclaims the rest).
// ---------------------------------------------------------------------------
static char *heap_base;
static usize_t heap_used;
static usize_t heap_cap;

// The bump allocator's cursor is process-wide, so spawned threads need a
// lock (§20.3 item 4). A tiny atomic spinlock keeps the runtime freestanding;
// the only thing it protects is the three words above. `lc_trap` on OOM is
// safe under the lock: it flushes output and exits the whole process.
static volatile char heap_lock = 0;

void *lc_alloc(usize_t n) {
    while (__atomic_test_and_set(&heap_lock, __ATOMIC_ACQUIRE)) { }
    // 16-byte alignment keeps every Harmony aggregate naturally aligned.
    n = (n + 15) & ~(usize_t) 15;
    if (heap_base == 0 || heap_used + n > heap_cap) {
        usize_t want = 1024 * 1024;
        if (n > want) { want = (n + 4095) & ~(usize_t) 4095; }
        long p = sys_mmap((long) want);
        if (p < 0) { lc_trap(T_OOM, 0, 0, (long) n); }
        heap_base = (char *) p;
        heap_used = 0;
        heap_cap = want;
    }
    char *p = heap_base + heap_used;
    heap_used += n;
    __atomic_clear(&heap_lock, __ATOMIC_RELEASE);
    return p;
}

// lc_dealloc(p, n) — release `n` bytes at `p` (§13.5). The M1 allocator is a
// bump allocator, so this is a no-op (the OS reclaims everything at exit). It
// exists so `dealloc<T>(p, n)` lowers and links; a real free arrives with the
// std allocator (§19.8.4), where `drop` calls through this hook.
void lc_dealloc(void *p, usize_t n) {
    (void) p;
    (void) n;
}

// ---------------------------------------------------------------------------
// Threads (§20.3 item 4). Still library code (§19.8.8): the compiler emits
// ordinary calls to these hooks. A thread is a CLONE_THREAD task with its own
// mmap'd stack, so no libc or pthread is needed and the freestanding `-nostdlib
// -static` link keeps working. A handle is the address of a control block:
//
//   refs   one for the join handle, one while the thread is running
//   done   futex word: 0 while running, 1 after the entry returns
//   ret    the entry's i64 result, published by `done` (acquire/release)
//
// Whichever side drops the last reference frees the control block; a peer
// also frees the stack. A thread dropping its own last reference leaves its
// stack mapped (the kernel reclaims it at exit), so both joined and detached
// threads clean up without a reaper thread.
// ---------------------------------------------------------------------------
struct lc_thread_ctl {
    long (*entry)(void *);
    void *arg;
    long ret;
    long refs;
    int done;
    void *stack;
    long stack_size;
};

// A three-argument syscall; the 4th (r10) is pinned to zero for FUTEX_WAIT.
static long sys_wait_futex(volatile int *addr) {
    long ret;
    register long r10 __asm__("r10") = 0;
    __asm__ volatile("syscall"
                     : "=a"(ret)
                     : "a"(SYS_futex), "D"(addr), "S"(0), "d"(0), "r"(r10)
                     : "rcx", "r11", "memory");
    return ret;
}

// `on_own_stack` is true when the exiting thread drops the last reference.
// It must not unmap the stack it is still executing on; the mapping is left
// for the kernel to reclaim at process exit, just like the bump allocator's
// pages (§19.8.4). Joined and detached-by-a-peer threads free both blocks.
static void lc_thread_free(struct lc_thread_ctl *t, int on_own_stack) {
    if (!on_own_stack) {
        sys(SYS_munmap, (long) t->stack, t->stack_size, 0);
    }
    sys(SYS_munmap, (long) t, (long) sizeof(*t), 0);
}

// The child runs this on its own stack. It never returns: SYS_exit (60) ends
// only this thread, while the process-level paths below use SYS_exit_group.
// `used` matters: the reference lives in inline asm, so the C front end would
// otherwise drop this function as unreferenced.
__attribute__((used, noreturn)) static void lc_thread_child(struct lc_thread_ctl *t) {
    t->ret = t->entry(t->arg);
    __atomic_fetch_add(&t->done, 1, __ATOMIC_RELEASE);
    sys(SYS_futex, (long) &t->done, 1, 1);       // FUTEX_WAKE(1)
    if (__atomic_fetch_sub(&t->refs, 1, __ATOMIC_ACQ_REL) == 1) {
        lc_thread_free(t, 1);
    }
    sys(SYS_exit, 0, 0, 0);
    for (;;) { }
}

// clone(2) returns twice. In the child the kernel sets rsp to `child_sp`,
// where the parent parked the control-block pointer; a naked stub pops it
// into the first argument register and calls the C child. In the parent (or
// on error) it simply returns the syscall result. Keeping the post-clone path
// in assembly matters: C locals live on the old stack, not the child's.
__attribute__((naked)) static long lc_clone_child(long flags, long child_sp,
                                                  void *unused __attribute__((unused))) {
    __asm__ volatile(
        "mov $56, %eax\n"          // SYS_clone
        "xor %edx, %edx\n"         // parent_tid = NULL
        "xor %r10d, %r10d\n"       // child_tid  = NULL
        "xor %r8d, %r8d\n"         // tls        = NULL
        "syscall\n"
        "test %rax, %rax\n"
        "jne 1f\n"                 // parent: tid, or -errno
        "pop %rdi\n"               // child: control block from the new stack
        "xor %ebp, %ebp\n"
        "and $-16, %rsp\n"
        "call lc_thread_child\n"
        "ud2\n"
        "1: ret\n"
    );
}

// CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND | CLONE_THREAD | CLONE_SYSVSEM.
#define CLONE_THREAD_FLAGS 0x50f00L
#define LC_THREAD_STACK_SIZE (1024L * 1024L)

long lc_thread_spawn(long (*entry)(void *), void *arg) {
    struct lc_thread_ctl *t = (struct lc_thread_ctl *) sys_mmap((long) sizeof(*t));
    if ((long) t < 0) { return (long) t; }
    void *stack = (void *) sys_mmap(LC_THREAD_STACK_SIZE);
    if ((long) stack < 0) {
        sys(SYS_munmap, (long) t, (long) sizeof(*t), 0);
        return (long) stack;
    }
    t->entry = entry;
    t->arg = arg;
    t->ret = 0;
    t->refs = 2;                   // join handle + running thread
    t->done = 0;
    t->stack = stack;
    t->stack_size = LC_THREAD_STACK_SIZE;
    // Top of stack, 16-byte aligned, with the block pointer just below it.
    long top = ((long) stack + LC_THREAD_STACK_SIZE) & ~15L;
    long *slot = (long *) (top - 16);
    *slot = (long) t;
    long tid = lc_clone_child(CLONE_THREAD_FLAGS, (long) slot, t);
    if (tid < 0) {
        sys(SYS_munmap, (long) stack, LC_THREAD_STACK_SIZE, 0);
        sys(SYS_munmap, (long) t, (long) sizeof(*t), 0);
        return tid;
    }
    return (long) t;               // the handle, not the TID
}

long lc_thread_join(long handle) {
    struct lc_thread_ctl *t = (struct lc_thread_ctl *) handle;
    if (handle == 0) { return 0; }
    while (__atomic_load_n(&t->done, __ATOMIC_ACQUIRE) == 0) {
        sys_wait_futex(&t->done);
    }
    long ret = t->ret;
    if (__atomic_fetch_sub(&t->refs, 1, __ATOMIC_ACQ_REL) == 1) {
        lc_thread_free(t, 0);
    }
    return ret;
}

void lc_thread_detach(long handle) {
    struct lc_thread_ctl *t = (struct lc_thread_ctl *) handle;
    if (handle == 0) { return; }
    if (__atomic_fetch_sub(&t->refs, 1, __ATOMIC_ACQ_REL) == 1) {
        lc_thread_free(t, 0);
    }
}

void lc_thread_yield(void) {
    sys(SYS_sched_yield, 0, 0, 0);
}

// ---------------------------------------------------------------------------
// FFI hook (library code): a raw three-argument Linux syscall. The future
// `sys` module is built on this; `extern fn` programs can reach the kernel
// without a libc.
// ---------------------------------------------------------------------------
long lc_syscall3(long n, long a, long b, long c) {
    return sys(n, a, b, c);
}

// Four-argument hook for wait4/execve-style syscalls whose fourth argument
// lives in r10. Passing an uninitialised rusage pointer through syscall3 made
// waitpid write to a garbage address (caught by valgrind).
long lc_syscall4(long n, long a, long b, long c, long d) {
    return sys4(n, a, b, c, d);
}

// ---------------------------------------------------------------------------
// Fault handler (§14.2, T-STACK). Both a runaway recursion and a bad raw
// pointer arrive as SIGSEGV, but only the first is `T-STACK`. Reporting
// "stack exhausted" for a null dereference hid real `unchecked` bugs (a
// probe showed `*null = 5` printing a stack-overflow trap), so the handler
// inspects the kernel's `siginfo_t`:
//
//   * `si_addr` (offset 16) is the faulting address.
//   * The interrupted `rsp` is in the ucontext's mcontext (offset 160).
//     A stack overflow faults in the guard page the kernel keeps just under
//     the stack: at or below `rsp` and within a short distance of it.
//
// A wild access is a violated `unchecked` contract, so it is **not** dressed
// up as a trap: the handler returns with SIG_DFL already restored
// (SA_RESETHAND), so the faulting instruction re-executes and the process
// dies with an honest SIGSEGV. The driver then reports "the compiled program
// was killed by signal 11". Inventing a trap code would claim a language
// guarantee that does not exist here.
// ---------------------------------------------------------------------------
static char alt_stack[ALT_STACK_SIZE];

// Byte offsets inside the x86-64 ucontext_t the kernel hands the handler:
// uc_flags(8) + uc_link(8) + uc_stack(24) = 40, then mcontext.gregs[], where
// REG_RSP is index 15 (40 + 15*8 = 160).
#define UCTX_RSP_OFFSET 160
// A guard-page hit lands within one page below the stack pointer that caused
// it. GUARD_WINDOW is generous (16 pages) so deep frames and kernel page
// rounding still classify correctly, while a wild pointer almost never lands
// that close to the live stack.
#define GUARD_WINDOW (16 * 4096)

// The restorer the kernel expects for SA_RESTORER on x86-64: invoke
// `rt_sigreturn` (syscall 15).
static void sigrestorer(void) {
    __asm__ volatile("mov $15, %rax\n\tsyscall");
}

static void segv_handler(int sig, void *info, void *uctx) {
    unsigned long fault;
    unsigned long rsp;
    (void) sig;
    fault = *(unsigned long *) ((char *) info + SI_ADDR_OFFSET);
    rsp = *(unsigned long *) ((char *) uctx + UCTX_RSP_OFFSET);
    // A stack overflow faults in the unmapped guard page under the stack:
    // the address is at or below rsp and within a short distance of it.
    // (Test fault <= rsp first, then the distance — both subtractions are
    // then safe.)
    if (fault >= 4096 && fault <= rsp && (rsp - fault) < GUARD_WINDOW) {
        // Report on stderr whatever fd a prior `print` left selected, and
        // flush: a trap exits immediately, so a buffered message would be
        // lost (this was a real bug — the handler used to buffer and exit).
        out_fd = 2;
        out_str("TRAP  T-STACK  stack exhausted\n");
        out_flush();
        sys(SYS_exit_group, 70, 0, 0);
        for (;;) { }
    }
    // Not the guard page: a bad access that violates an `unchecked` contract.
    // It must *not* be dressed up as a trap (a trap code would claim a
    // guarantee the language does not make here). The handler is installed
    // with SA_RESETHAND, so simply returning resumes the faulting instruction
    // with SIG_DFL in place: it faults again and the process dies with a real
    // SIGSEGV, which the driver reports truthfully. (Sending the signal from
    // inside the handler would not work: SIGSEGV stays blocked until the
    // handler returns, so the signal would be pending forever and the process
    // would hang — verified with strace.)
    out_flush();
    return;
}

// Installs the handler. Returns 0 on success.
static int install_stack_guard(void) {
    struct kstack ss;
    struct ksigaction sa;
    long r;

    ss.ss_sp = alt_stack;
    ss.ss_flags = 0;
    ss.ss_size = ALT_STACK_SIZE;
    r = sys(SYS_sigaltstack, (long) &ss, 0, 0);
    if (r < 0) { return -1; }

    // SA_ONSTACK so the handler runs on alt_stack, never on the exhausted
    // main stack; SA_SIGINFO so it receives siginfo_t (the faulting address)
    // and the ucontext (the interrupted rsp); SA_RESTORER names the sigreturn
    // trampoline (required for a hand-built sigaction on x86-64).
    sa.handler = segv_handler;
    sa.flags = SA_ONSTACK | SA_SIGINFO | SA_RESTORER | SA_RESETHAND;
    sa.restorer = sigrestorer;
    sa.mask = 0;
    // rt_sigaction(sig, &sa, old, sigset_size): the kernel requires the last
    // argument to be 8 on x86-64.
    r = sys4(SYS_rt_sigaction, SIGSEGV, (long) &sa, 0, 8);
    if (r < 0) { return -1; }
    return 0;
}

// ---------------------------------------------------------------------------
// Process arguments (§15.6). The kernel enters `_start` with
// `[argc][argv0..argvN-1][NULL][envp...]` and `%rsp` pointing at `argc`.
// `_start` captures the pair before it realigns the stack; `lc_args()` then
// builds a safe `&[&str]` view (an array of (data pointer, length) pairs,
// each element 16 bytes like every `&str`) and returns the address of the
// slice value. Generated code only ever sees that safe view — never `argv`.
// ---------------------------------------------------------------------------
static long g_argc;
static char **g_argv;

// Host-linked builds use the C runtime's `main` instead of the freestanding
// `_start`; the wrapper calls this before `harmony_main` so `args()` works.
void lc_host_init(int argc, char **argv) {
    g_argc = argc;
    g_argv = argv;
}

#define LC_MAX_ARGS 4096
static struct { const char *p; long n; } g_arg_pairs[LC_MAX_ARGS];
static struct { const void *p; long n; } g_args_slice;
static int g_args_built;

// Returns a pointer to a static `&[&str]` describing the arguments (argv[0]
// is the program path). Built once. The address of the slice value is returned
// so a caller can copy the 16-byte pair out.
void *lc_args(void) {
    long i;
    long n;
    if (!g_args_built) {
        n = g_argc;
        if (n < 0) { n = 0; }
        if (n > LC_MAX_ARGS) { n = LC_MAX_ARGS; }
        i = 0;
        while (i < n) {
            const char *p = g_argv[i];
            long l = 0;
            if (p == 0) { break; }
            while (p[l] != 0) { l = l + 1; }
            g_arg_pairs[i].p = p;
            g_arg_pairs[i].n = l;
            i = i + 1;
        }
        g_args_slice.p = g_arg_pairs;
        g_args_slice.n = i;
        g_args_built = 1;
    }
    return &g_args_slice;
}

// ---------------------------------------------------------------------------
// Entry point. The program's `main` is emitted by the compiler as
// `harmony_main` (an i32 return); `_start` calls it and exits with the low
// byte as the status, matching §6.3.
// ---------------------------------------------------------------------------
extern int harmony_main(void);

// Real entry, called by the naked `_start` with `%rdi` = the initial stack
// pointer (pointing at `argc`). Doing the capture here — in a normal C
// function that receives the pointer as an argument — avoids the prologue of
// a C `_start` moving `%rsp` before we could read it.
__attribute__((noreturn)) void lc_start(long *sp);
__attribute__((noreturn)) void lc_start(long *sp) {
    int code;
    g_argc = sp[0];
    g_argv = (char **) &sp[1];
    install_stack_guard();
    code = harmony_main();
    out_flush();
    sys(SYS_exit_group, code & 0xff, 0, 0);
    for (;;) { }
}

// The kernel enters `_start` 16-byte aligned with `%rsp` pointing at `argc`.
// A naked prologue-free entry hands `%rsp` to `lc_start` (as the first
// argument), then realigns `%rsp` for the SysV ABI and calls it. The argv
// strings live above the initial `%rsp`, so realignment never disturbs them.
__attribute__((naked, noreturn)) void _start(void) {
    __asm__ volatile(
        "xor %rbp, %rbp\n"
        "mov %rsp, %rdi\n"
        "and $-16, %rsp\n"
        "call lc_start\n"
        "hlt\n");
}
