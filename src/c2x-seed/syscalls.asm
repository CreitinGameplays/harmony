; C2X Seed - System Call Definitions and Wrappers
; x86_64 Linux syscalls only, no libc

; ------------------------------------------------------------
; Exported Functions
; ------------------------------------------------------------
global sys_exit, sys_read, sys_write, sys_open, sys_close, sys_brk, sys_mmap
global sys_fork, sys_execve, sys_wait4, sys_unlink, sys_getpid

; ------------------------------------------------------------
; Exported Constants
; ------------------------------------------------------------
global SYS_READ, SYS_WRITE, SYS_OPEN, SYS_CLOSE, SYS_EXIT, SYS_BRK, SYS_MMAP, SYS_MUNMAP
global SYS_FORK, SYS_EXECVE, SYS_WAIT4, SYS_UNLINK, SYS_GETPID
global STDIN, STDOUT, STDERR
global O_RDONLY, O_WRONLY, O_RDWR, O_CREAT, O_TRUNC, O_APPEND
global EXIT_SUCCESS, EXIT_FAILURE

; ------------------------------------------------------------
; Syscall Numbers (x86_64 Linux)
; ------------------------------------------------------------
SYS_READ    equ 0
SYS_WRITE   equ 1
SYS_OPEN    equ 2
SYS_CLOSE   equ 3
SYS_EXIT    equ 60
SYS_BRK     equ 12
SYS_MMAP    equ 9
SYS_MUNMAP  equ 11
SYS_FORK    equ 57
SYS_EXECVE  equ 59
SYS_WAIT4   equ 61
SYS_UNLINK  equ 87
SYS_GETPID  equ 39

; ------------------------------------------------------------
; File Descriptors
; ------------------------------------------------------------
STDIN       equ 0
STDOUT      equ 1
STDERR      equ 2

; ------------------------------------------------------------
; File Open Flags
; ------------------------------------------------------------
O_RDONLY    equ 0
O_WRONLY    equ 1
O_RDWR      equ 2
O_CREAT     equ 64
O_TRUNC     equ 512
O_APPEND    equ 1024

; ------------------------------------------------------------
; Exit Codes
; ------------------------------------------------------------
; ------------------------------------------------------------
; Memory Protection Flags (for mmap)
; ------------------------------------------------------------
PROT_READ   equ 1
PROT_WRITE  equ 2
PROT_EXEC   equ 4

MAP_PRIVATE equ 2
MAP_ANONYMOUS equ 32
MAP_FIXED   equ 16

; ------------------------------------------------------------
; Syscall Wrapper Macros
; ------------------------------------------------------------

%macro syscall0 1
    mov rax, %1
    syscall
%endmacro

%macro syscall1 2
    mov rax, %1
    mov rdi, %2
    syscall
%endmacro

%macro syscall2 3
    mov rax, %1
    mov rdi, %2
    mov rsi, %3
    syscall
%endmacro

%macro syscall3 4
    mov rax, %1
    mov rdi, %2
    mov rsi, %3
    mov rdx, %4
    syscall
%endmacro

%macro syscall4 5
    mov rax, %1
    mov rdi, %2
    mov rsi, %3
    mov rdx, %4
    mov r10, %5
    syscall
%endmacro

%macro syscall5 6
    mov rax, %1
    mov rdi, %2
    mov rsi, %3
    mov rdx, %4
    mov r10, %5
    mov r8, %6
    syscall
%endmacro

%macro syscall6 7
    mov rax, %1
    mov rdi, %2
    mov rsi, %3
    mov rdx, %4
    mov r10, %5
    mov r8, %6
    mov r9, %7
    syscall
%endmacro

default rel

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
