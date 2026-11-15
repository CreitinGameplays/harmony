; C2X Seed - I/O Utilities
; String handling, file I/O, buffered output for code generation

; ------------------------------------------------------------
; External Dependencies (from syscalls.asm)
; ------------------------------------------------------------
extern sys_exit, sys_read, sys_write, sys_open, sys_close, sys_brk
extern STDIN, STDOUT, STDERR

; Local constant definitions (matching syscalls.asm)
O_RDONLY    equ 0
O_WRONLY    equ 1
O_RDWR      equ 2
O_CREAT     equ 64
O_TRUNC     equ 512
O_APPEND    equ 1024

; ------------------------------------------------------------
; Exported Functions and Data
; ------------------------------------------------------------
global out_init, out_flush, out_write_char, out_write_string, out_write_string_len
global out_write_newline, out_write_int, out_write_hex
global out_set_fd, out_set_limit
global in_init, in_fill, in_get_char, in_peek_char, in_skip_char
global file_open_read, file_open_write, file_close, file_read_all
global out_buffer, out_ptr, out_end, out_fd
global out_limit_enabled, out_limit_remaining, out_limit_hit
global in_buffer, in_ptr, in_end, src_fd
global OUT_BUF_SIZE, IN_BUF_SIZE

section .data
    ; Output buffer for generated assembly
    OUT_BUF_SIZE    equ 65536
    out_buffer:     times OUT_BUF_SIZE db 0
    out_ptr:        dq out_buffer
    out_end:        dq out_buffer + OUT_BUF_SIZE
    
    ; Input buffer for source reading
    IN_BUF_SIZE     equ 8192
    in_buffer:      times IN_BUF_SIZE db 0
    in_ptr:         dq in_buffer
    in_end:         dq in_buffer
    src_fd:         dq 0

section .bss
    out_fd:         resq 1          ; output file descriptor (defaults to STDOUT)
    out_limit_enabled:  resq 1      ; 1 when output limiting is active
    out_limit_remaining: resq 1     ; bytes left before the debug limit is hit
    out_limit_hit:   resq 1         ; 1 once the limit has been exceeded

default rel

section .text

; ------------------------------------------------------------
; Output Buffer Management
; ------------------------------------------------------------

; out_init() - Initialize output buffer
out_init:
    mov rax, out_buffer
    mov [out_ptr], rax
    mov rax, out_buffer + OUT_BUF_SIZE
    mov [out_end], rax
    mov qword [out_fd], STDOUT
    mov qword [out_limit_enabled], 0
    mov qword [out_limit_remaining], 0
    mov qword [out_limit_hit], 0
    ret

; out_set_fd(int fd) - Set output file descriptor
; Input: rdi = new fd
out_set_fd:
    mov [out_fd], rdi
    ret

; out_set_limit(size_t limit) - Enable or disable the debug output cap
; Input: rdi = byte limit (0 disables the cap)
; Clobbers: rax
out_set_limit:
    test rdi, rdi
    jz .disable
    mov qword [out_limit_enabled], 1
    mov [out_limit_remaining], rdi
    mov qword [out_limit_hit], 0
    ret
.disable:
    mov qword [out_limit_enabled], 0
    mov qword [out_limit_remaining], 0
    mov qword [out_limit_hit], 0
    ret

; out_flush() - Write output buffer to out_fd
; Clobbers: rax, rdi, rsi, rdx
out_flush:
    mov rax, [out_ptr]
    sub rax, out_buffer          ; rax = bytes in buffer
    test rax, rax
    jz .done                     ; Nothing to flush

    mov rdx, rax
    cmp qword [out_limit_enabled], 0
    je .write

    mov rcx, [out_limit_remaining]
    test rcx, rcx
    jz .limit_reached

    cmp rdx, rcx
    jbe .within_limit

    ; Buffer is larger than the remaining allowance: write only the cap.
    mov rdx, rcx
    mov qword [out_limit_remaining], 0
    mov qword [out_limit_hit], 1
    jmp .write

.within_limit:
    sub rcx, rdx
    mov [out_limit_remaining], rcx
    test rcx, rcx
    jnz .write
    mov qword [out_limit_hit], 1
    jmp .write

.limit_reached:
    mov qword [out_limit_hit], 1
    mov rax, out_buffer
    mov [out_ptr], rax
    ret

.write:
    mov rdi, [out_fd]
    mov rsi, out_buffer
    call sys_write
    
    ; Reset pointer
    mov rax, out_buffer
    mov [out_ptr], rax
    
.done:
    ret

; out_write_char(char c) - Write single character to output buffer
; Input: dil = character
; Clobbers: rax
; Preserves: rsi (callers like out_write_string rely on this)
out_write_char:
    cmp qword [out_limit_hit], 0
    jne .skip
    mov rax, [out_ptr]
    cmp rax, [out_end]
    jb .write
    ; Buffer full — flush first.  Save rsi (clobbered by out_flush) and
    ; the character (in rdi).  Two pushes + sub 8 for 16-byte alignment.
    push rsi                     ; rsp = 0 mod 16
    push rdi                     ; rsp = 8 mod 16
    sub rsp, 8                   ; rsp = 0 mod 16 (aligned for call)
    call out_flush
    add rsp, 8
    pop rdi                      ; restore character
    pop rsi                      ; restore source pointer
    mov rax, [out_ptr]           ; reload after flush reset
.write:
    mov [rax], dil
    inc qword [out_ptr]
.skip:
    ret

; out_write_string(const char* str) - Write null-terminated string
; Input: rsi = string pointer
; Clobbers: rax, rsi
out_write_string:
    push rsi
.loop:
    mov al, [rsi]
    test al, al
    jz .done
    mov dil, al
    call out_write_char
    inc rsi
    jmp .loop
.done:
    pop rsi
    ret

; out_write_string_len(const char* str, size_t len) - Write string with length
; Input: rsi = string pointer, rdx = length
; Clobbers: rax, rdx, rcx, rsi
out_write_string_len:
    cmp qword [out_limit_hit], 0
    jne .done
    mov rcx, rdx
    test rcx, rcx
    jz .done
.loop:
    cmp qword [out_limit_hit], 0
    jne .done
    mov rax, [out_ptr]
    cmp rax, [out_end]
    jb .write
    push rsi                      ; out_flush clobbers the source pointer too
    push rcx                      ; sys_write inside out_flush clobbers rcx
    call out_flush
    pop rcx
    pop rsi
    mov rax, [out_ptr]
.write:
    
    mov dl, [rsi]
    mov [rax], dl
    inc qword [out_ptr]
    inc rsi
    dec rcx
    jnz .loop
.done:
    ret

; out_write_newline() - Write newline character
out_write_newline:
    mov dil, 10
    call out_write_char
    ret

; out_write_int(int64 val) - Write signed integer as decimal string
; Input: rdi = value
; Clobbers: rax, rdx, rcx, rsi
out_write_int:
    test rdi, rdi
    jns .positive
    ; Negative number
    mov dil, '-'
    call out_write_char
    neg rdi
.positive:
    sub rsp, 64                    ; allocate scratch space (max 20 digits)
    mov rcx, 10
    lea rsi, [rsp + 48]            ; buffer top within allocated space
    mov rax, rdi
    mov r8, rsi                    ; Save initial position
.divide_loop:
    xor rdx, rdx
    div rcx                      ; rdx = remainder, rax = quotient
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test rax, rax
    jnz .divide_loop
    
    ; Write digits (r8 - rsi = number of digits)
    mov rdx, r8
    sub rdx, rsi
    call out_write_string_len
    add rsp, 64
    ret

; out_write_hex(uint64 val) - Write unsigned integer as hex string
; Input: rdi = value
; Clobbers: rax, rcx, rsi
out_write_hex:
    mov dil, '0'
    call out_write_char
    mov dil, 'x'
    call out_write_char
    
    sub rsp, 32                    ; allocate scratch space (16 hex digits)
    mov rcx, 16
    lea rsi, [rsp + 16]            ; buffer top within allocated space
    mov rax, rdi
.hex_loop:
    dec rsi
    mov rdx, rax
    and rdx, 15
    cmp dl, 10
    jl .hex_digit
    add dl, 'a' - 10
    jmp .hex_store
.hex_digit:
    add dl, '0'
.hex_store:
    mov [rsi], dl
    shr rax, 4
    dec rcx
    jnz .hex_loop
    
    mov rdx, 16
    call out_write_string_len
    add rsp, 32
    ret

; ------------------------------------------------------------
; Input Buffer Management
; ------------------------------------------------------------

; in_init(int fd) - Initialize input buffer with file descriptor
; Input: rdi = file descriptor
in_init:
    mov [src_fd], rdi
    mov rax, in_buffer
    mov [in_ptr], rax
    mov [in_end], rax
    ret

; in_fill() - Fill input buffer from source file
; Returns: rax = bytes read (0 = EOF, negative = error)
; Clobbers: rax, rdi, rsi, rdx, rcx
in_fill:
    push rbx
    mov rdi, [src_fd]
    mov rsi, in_buffer
    mov rdx, IN_BUF_SIZE
    call sys_read
    
    cmp rax, 0
    jle .done                  ; EOF or error
    
    mov rbx, rax               ; Save bytes read in callee-saved rbx
    mov rax, in_buffer
    mov [in_ptr], rax
    add rax, rbx               ; in_buffer + bytes_read
    mov [in_end], rax
.done:
    pop rbx
    ret

; in_get_char() -> char (in al), sets ZF on EOF
; Returns next character from input buffer, refills if needed
; Clobbers: rax, rdi, rsi, rdx
in_get_char:
    mov rax, [in_ptr]
    cmp rax, [in_end]
    jae .refill
    
    mov al, [rax]
    inc qword [in_ptr]
    test al, al
    ret

.refill:
    call in_fill
    test rax, rax
    jle .eof
    
    mov rax, [in_ptr]
    mov al, [rax]
    inc qword [in_ptr]
    test al, al
    ret

.eof:
    xor al, al
    ret

; in_peek_char() -> char (in al), sets ZF on EOF
; Returns next character without consuming it
; Clobbers: rax
in_peek_char:
    mov rax, [in_ptr]
    cmp rax, [in_end]
    jae .refill
    
    mov al, [rax]
    test al, al
    ret

.refill:
    call in_fill
    test rax, rax
    jle .eof
    
    mov rax, [in_ptr]
    mov al, [rax]
    test al, al
    ret

.eof:
    xor al, al
    ret

; in_skip_char() - Consume current character
; Clobbers: rax
in_skip_char:
    mov rax, [in_ptr]
    cmp rax, [in_end]
    jae .refill
    inc qword [in_ptr]
    ret

.refill:
    call in_fill
    test rax, rax
    jle .done
    inc qword [in_ptr]
.done:
    ret

; ------------------------------------------------------------
; File Operations
; ------------------------------------------------------------

; file_open_read(const char* path) -> int fd
; Opens file for reading
; Input: rdi = path
; Output: rax = fd or negative error
file_open_read:
    mov rsi, O_RDONLY
    mov rdx, 0
    call sys_open
    ret

; file_open_write(const char* path) -> int fd
; Opens file for writing (create/truncate)
; Input: rdi = path
; Output: rax = fd or negative error
file_open_write:
    mov rsi, O_WRONLY | O_CREAT | O_TRUNC
    mov rdx, 0644o
    call sys_open
    ret

; file_close(int fd)
; Input: rdi = fd
file_close:
    call sys_close
    ret

; file_read_all(int fd, void** out_buf, size_t* out_size) -> int
; Reads entire file into heap-allocated buffer
; Input: rdi = fd, rsi = out_buf_ptr, rdx = out_size_ptr
; Output: rax = 0 on success, negative error
; Clobbers: rax, rbx, rcx, rdi, rsi, rdx
file_read_all:
    push rsi
    push rdx
    push rbx
    
    mov rbx, rdi               ; Save fd
    mov rdi, 0
    call sys_brk               ; Get current brk
    mov rbx, rax               ; Save current brk
    
    ; TODO: Implement proper file reading with dynamic allocation
    ; For now, use fixed buffer
    pop rbx
    pop rdx
    pop rsi
    xor rax, rax
    ret
