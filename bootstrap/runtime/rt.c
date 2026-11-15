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
//
// Everything is deterministic and allocation-free on the hot path.

typedef unsigned long usize_t;
typedef long          isize_t;

// Linux x86-64 syscall numbers (the only platform the seed targets today).
#define SYS_read   0
#define SYS_write  1
#define SYS_mmap   9
#define SYS_rt_sigaction 13
#define SYS_exit   60
#define SYS_sigaltstack 131

// The signal we guard against, and the flag bits it needs.
#define SIGSEGV    11
#define SA_ONSTACK 0x08000000
#define SA_RESTORER 0x04000000
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
struct ksigaction {
    void (*handler)(int);
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
    sys(SYS_exit, 70, 0, 0);
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
    sys(SYS_exit, 70, 0, 0);
    for (;;) { }
}

// lc_unreachable(line, col) — T-UNREACHABLE, the `unreachable()` builtin.
void lc_unreachable(long line, long col) {
    lc_trap(T_UNREACHABLE, line, col, 0);
}

// lc_exit(code) — flush and stop with the given status (§14.3). No hooks run.
void lc_exit(long code) {
    out_flush();
    sys(SYS_exit, code & 0xff, 0, 0);
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
// Stack-overflow guard (§14.2, T-STACK). A recursive runaway would otherwise
// hit the guard page and die with SIGSEGV. We install a handler on an
// alternate signal stack, and where the kernel's SA_RESTORER needs a
// `sigreturn` trampoline we provide the canonical `mov rax, 15; syscall`
// sequence. The handler then turns the fault into a normal `T-STACK` trap
// (exit 70), which is what the language promises.
//
// A thread that never returns runs out of stack where the kernel placed the
// guard; the handler only prints a fixed message and exits, so it needs no
// ucontext decoding.
// ---------------------------------------------------------------------------
static char alt_stack[ALT_STACK_SIZE];

// The restorer the kernel expects for SA_RESTORER on x86-64: invoke
// `rt_sigreturn` (syscall 15).
static void sigrestorer(void) {
    __asm__ volatile("mov $15, %rax\n\tsyscall");
}

static void segv_handler(int sig) {
    (void) sig;
    // The main stack is gone; write through the trap formatting used by
    // lc_trap's message, then exit 70 (§14.3).
    out_flush();
    sys(SYS_write, 2, (long) "TRAP  T-STACK  stack exhausted\n", 31);
    sys(SYS_exit, 70, 0, 0);
    for (;;) { }
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
    // main stack; SA_RESTORER names the sigreturn trampoline (required for a
    // hand-built sigaction on x86-64).
    sa.handler = segv_handler;
    sa.flags = SA_ONSTACK | SA_RESTORER;
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
    sys(SYS_exit, code & 0xff, 0, 0);
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
