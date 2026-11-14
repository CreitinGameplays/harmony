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
//   lc_alloc          bump/heap allocation that traps on OOM (T-OOM).
//
// Everything is deterministic and allocation-free on the hot path.

typedef unsigned long usize_t;
typedef long          isize_t;

// Linux x86-64 syscall numbers (the only platform the seed targets today).
#define SYS_read   0
#define SYS_write  1
#define SYS_mmap   9
#define SYS_exit   60

static long sys(long n, long a, long b, long c) {
    long ret;
    __asm__ volatile("syscall"
                     : "=a"(ret)
                     : "a"(n), "D"(a), "S"(b), "d"(c)
                     : "rcx", "r11", "memory");
    return ret;
}

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

// ---------------------------------------------------------------------------
// Output. Buffered so a sequence of writes costs one syscall.
// ---------------------------------------------------------------------------
static char out_buf[4096];
static usize_t out_len;

static void out_flush(void) {
    if (out_len > 0) {
        sys(SYS_write, 2, (long) out_buf, (long) out_len);
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
    sys(SYS_exit, 70, 0, 0);   // §14.3: trap exit status
    for (;;) { }
}

// lc_check_index(i, n, line, col) — trap if i is out of [0, n).
void lc_check_index(long i, long n, long line, long col) {
    if (i < 0 || i >= n) {
        lc_trap(T_INDEX, line, col, i);
    }
}

// ---------------------------------------------------------------------------
// Allocation (§12, §19.8.4). A bump allocator over mmap'd pages: fast, and
// enough for M1. A real `dealloc` arrives with the std module (v1 frees
// through drop glue; the OS reclaims the rest).
// ---------------------------------------------------------------------------
static char *heap_base;
static usize_t heap_used;
static usize_t heap_cap;

void *lc_alloc(usize_t n) {
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
    {
        char *p = heap_base + heap_used;
        heap_used += n;
        return p;
    }
}

// ---------------------------------------------------------------------------
// FFI hook (library code): a raw three-argument Linux syscall. The future
// `sys` module is built on this; `extern fn` programs can reach the kernel
// without a libc.
// ---------------------------------------------------------------------------
long lc_syscall3(long n, long a, long b, long c) {
    return sys(n, a, b, c);
}

// ---------------------------------------------------------------------------
// Entry point. The program's `main` is emitted by the compiler as
// `harmony_main` (an i32 return); `_start` calls it and exits with the low
// byte as the status, matching §6.3.
// ---------------------------------------------------------------------------
extern int harmony_main(void);

__attribute__((noreturn)) void _start(void) {
    int code = harmony_main();
    out_flush();
    sys(SYS_exit, code & 0xff, 0, 0);
    for (;;) { }
}
