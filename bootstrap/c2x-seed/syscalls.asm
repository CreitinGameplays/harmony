format ELF64

section '.text' executable

; C2X Seed - System Call Definitions and Wrappers
; x86_64 Linux syscalls only, no libc

; ------------------------------------------------------------
; Exported Functions
; ------------------------------------------------------------

; ------------------------------------------------------------
; Exported Constants
; ------------------------------------------------------------

; ------------------------------------------------------------
; Syscall Numbers (x86_64 Linux)
; ------------------------------------------------------------
SYS_READ = 0
SYS_WRITE = 1
SYS_OPEN = 2
SYS_CLOSE = 3
SYS_EXIT = 60
SYS_BRK = 12
SYS_MMAP = 9
SYS_MUNMAP = 11
SYS_FORK = 57
SYS_EXECVE = 59
SYS_WAIT4 = 61
SYS_UNLINK = 87
SYS_GETPID = 39
SYS_DUP2 = 33

; ------------------------------------------------------------
; File Descriptors
; ------------------------------------------------------------
STDIN = 0
STDOUT = 1
STDERR = 2

; Process exit codes. `equ` constants are absolute symbols; `global` makes
; them linkable, so `extern EXIT_SUCCESS/FAILURE` resolves across objects.
EXIT_SUCCESS = 0
EXIT_FAILURE = 1

; ------------------------------------------------------------
; File Open Flags
; ------------------------------------------------------------
O_RDONLY = 0
O_WRONLY = 1
O_RDWR = 2
O_CREAT = 64
O_TRUNC = 512
O_APPEND = 1024

; ------------------------------------------------------------
; Exit Codes
; ------------------------------------------------------------
; ------------------------------------------------------------
; Memory Protection Flags (for mmap)
; ------------------------------------------------------------
PROT_READ = 1
PROT_WRITE = 2
PROT_EXEC = 4

MAP_PRIVATE = 2
MAP_ANONYMOUS = 32
MAP_FIXED = 16

; ------------------------------------------------------------
; Syscall Wrapper Macros
; ------------------------------------------------------------

macro syscall0 nr {
    mov rax, nr
    syscall
}

macro syscall1 nr, a {
    mov rax, nr
    mov rdi, a
    syscall
}

macro syscall2 nr, a, b {
    mov rax, nr
    mov rdi, a
    mov rsi, b
    syscall
}

macro syscall3 nr, a, b, c {
    mov rax, nr
    mov rdi, a
    mov rsi, b
    mov rdx, c
    syscall
}

macro syscall4 nr, a, b, c, d {
    mov rax, nr
    mov rdi, a
    mov rsi, b
    mov rdx, c
    mov r10, d
    syscall
}

macro syscall5 nr, a, b, c, d, e {
    mov rax, nr
    mov rdi, a
    mov rsi, b
    mov rdx, c
    mov r10, d
    mov r8, e
    syscall
}

macro syscall6 nr, a, b, c, d, e, f {
    mov rax, nr
    mov rdi, a
    mov rsi, b
    mov rdx, c
    mov r10, d
    mov r8, e
    mov r9, f
    syscall
}


; ------------------------------------------------------------
; Syscall Wrapper Functions
; ------------------------------------------------------------

; sys_exit(int code) - never returns
; Input: rdi = exit code
sys_exit:
    mov rax, SYS_EXIT
    syscall
    ; unreachable
    ret

; sys_read(int fd, void* buf, size_t count) -> ssize_t
; Input: rdi = fd, rsi = buf, rdx = count
; Output: rax = bytes read or negative error
sys_read:
    mov rax, SYS_READ
    syscall
    ret

; sys_write(int fd, const void* buf, size_t count) -> ssize_t
; Input: rdi = fd, rsi = buf, rdx = count
; Output: rax = bytes written or negative error
sys_write:
    mov rax, SYS_WRITE
    syscall
    ret

; sys_open(const char* pathname, int flags, mode_t mode) -> int
; Input: rdi = pathname, rsi = flags, rdx = mode
; Output: rax = fd or negative error
sys_open:
    mov rax, SYS_OPEN
    syscall
    ret

; sys_close(int fd) -> int
; Input: rdi = fd
; Output: rax = 0 on success, negative error
sys_close:
    mov rax, SYS_CLOSE
    syscall
    ret

; sys_brk(void* addr) -> void*
; Input: rdi = new brk address (0 to query current)
; Output: rax = new brk address
sys_brk:
    mov rax, SYS_BRK
    syscall
    ret

; sys_mmap(void* addr, size_t length, int prot, int flags, int fd, off_t offset) -> void*
; Input: rdi = addr, rsi = length, rdx = prot, r10 = flags, r8 = fd, r9 = offset
; Output: rax = mapped address or negative error
sys_mmap:
    mov rax, SYS_MMAP
    syscall
    ret

; sys_fork() -> pid_t
; Output: rax = 0 in child, child PID in parent, negative on error
sys_fork:
    mov rax, SYS_FORK
    syscall
    ret

; sys_getpid() -> pid_t
; Output: rax = current process id
sys_getpid:
    mov rax, SYS_GETPID
    syscall
    ret

; sys_dup2(int oldfd, int newfd) -> int
; Input: rdi = oldfd, rsi = newfd
; Output: rax = newfd on success, negative error
sys_dup2:
    mov rax, SYS_DUP2
    syscall
    ret

; sys_execve(const char* pathname, char* const argv[], char* const envp[]) -> int
; Input: rdi = pathname, rsi = argv, rdx = envp
; Output: rax = 0 on success, negative on error (only returns on error)
sys_execve:
    mov rax, SYS_EXECVE
    syscall
    ret

; sys_wait4(pid_t pid, int* wstatus, int options, struct rusage* rusage) -> pid_t
; Input: rdi = pid, rsi = wstatus, rdx = options, r10 = rusage
; Output: rax = pid of child or negative error
sys_wait4:
    mov rax, SYS_WAIT4
    syscall
    ret

; sys_unlink(const char* pathname) -> int
; Input: rdi = pathname
; Output: rax = 0 on success, negative on error
sys_unlink:
    mov rax, SYS_UNLINK
    syscall
    ret
public sys_exit
public sys_read
public sys_write
public sys_open
public sys_close
public sys_brk
public sys_mmap
public sys_fork
public sys_execve
public sys_wait4
public sys_unlink
public sys_getpid
public sys_dup2
public SYS_READ
public SYS_WRITE
public SYS_OPEN
public SYS_CLOSE
public SYS_EXIT
public SYS_BRK
public SYS_MMAP
public SYS_MUNMAP
public SYS_FORK
public SYS_EXECVE
public SYS_WAIT4
public SYS_UNLINK
public SYS_GETPID
public SYS_DUP2
public STDIN
public STDOUT
public STDERR
public O_RDONLY
public O_WRONLY
public O_RDWR
public O_CREAT
public O_TRUNC
public O_APPEND
public EXIT_SUCCESS
public EXIT_FAILURE
