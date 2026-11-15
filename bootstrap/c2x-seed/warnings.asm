; ================================================================
; warnings.asm — Centralized Warning System
;
; All warning categories, messages, and emission functions.
; Warnings are advisory only — they never abort compilation.
; All warnings are ON by default; pass --no-warnings to disable.
; ================================================================

; ------------------------------------------------------------
; Warning Categories
; ------------------------------------------------------------
; Semantic warnings (1-99)
    global WARN_UNINIT_VAR
WARN_UNINIT_VAR      equ 1
    global WARN_UNINIT_PTR
WARN_UNINIT_PTR      equ 2
    global WARN_MISSING_RETURN
WARN_MISSING_RETURN  equ 3
    global WARN_UNUSED_VAR
WARN_UNUSED_VAR      equ 4
    global WARN_DEAD_CODE
WARN_DEAD_CODE       equ 5
    global WARN_IMPLICIT_CAST
WARN_IMPLICIT_CAST   equ 6
    global WARN_EMPTY_BODY
WARN_EMPTY_BODY      equ 7
    global WARN_CONSTANT_COND
WARN_CONSTANT_COND   equ 8

NUM_WARNINGS equ 8

; ------------------------------------------------------------
; External dependencies
; ------------------------------------------------------------
extern out_write_string
extern out_write_string_len
extern out_write_int
extern out_write_char
extern out_write_newline
extern out_set_fd
extern out_flush
extern out_fd
extern source_path
extern lexer_state
extern STDERR

; ------------------------------------------------------------
; Initialized Data — Warning Messages
; ------------------------------------------------------------
section .data

msg_warn_prefix      db ": warning: ", 0

; Specific warning messages
msg_warn_uninit_var      db "uninitialized variable", 0
msg_warn_uninit_ptr      db "uninitialized pointer dereferenced", 0
msg_warn_missing_return  db "non-void function should return a value", 0
msg_warn_unused_var      db "unused variable", 0
msg_warn_dead_code       db "unreachable code after return/break/continue", 0
msg_warn_implicit_cast   db "implicit cast", 0
msg_warn_empty_body      db "empty body for control flow statement", 0
msg_warn_constant_cond   db "condition is always true", 0

; Summary message
msg_warn_summary_fmt    db " warning(s) generated", 10, 0

; Export message strings for use by other modules
    global msg_warn_uninit_var
    global msg_warn_uninit_ptr
    global msg_warn_missing_return
    global msg_warn_unused_var
    global msg_warn_dead_code
    global msg_warn_implicit_cast
    global msg_warn_empty_body
    global msg_warn_constant_cond

; ------------------------------------------------------------
; Uninitialized Data — Warning State
; ------------------------------------------------------------
section .bss
    global warning_count
    warning_count     resq 1          ; total warnings emitted

    global warnings_enabled
    warnings_enabled  resq 1          ; 1 = emit warnings (default), 0 = suppressed

    global warning_mask
    warning_mask      resb NUM_WARNINGS  ; bitmask: bit N set = warning N disabled

default rel

section .text

; ------------------------------------------------------------
; warn_init() — Initialize warning system (call once at startup)
; Sets warnings_enabled = 1 (default ON) and clears mask
; ------------------------------------------------------------
    global warn_init
warn_init:
    push rax
    push rcx
    push rdi
    mov rax, 1
    mov [warnings_enabled], rax
    ; Zero the mask (all warnings enabled)
    mov rdi, warning_mask
    xor rcx, rcx
    mov cl, NUM_WARNINGS
    xor al, al
    rep stosb
    pop rdi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------
; warn_disable_all() — Disable all warnings
; Used by --no-warnings flag
; ------------------------------------------------------------
    global warn_disable_all
warn_disable_all:
    push rax
    xor rax, rax
    mov [warnings_enabled], rax
    pop rax
    ret

; ------------------------------------------------------------
; warn_at(category, line, col, msg)
; Emit a warning with file:line:col prefix.
; rdi = warning category (1..NUM_WARNINGS)
; rsi = line number
; rdx = column
; rcx = message string pointer
; Honors warnings_enabled and warning_mask.
; ------------------------------------------------------------
    global warn_at
warn_at:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12, rdi                ; r12 = category
    mov r13, rsi                ; r13 = line
    mov r14, rdx                ; r14 = col
    mov r15, rcx                ; r15 = message

    ; Check if warnings are globally enabled
    cmp qword [warnings_enabled], 0
    je .warn_at_skip

    ; Check if this specific category is masked
    cmp r12, 0
    jle .warn_at_skip
    cmp r12, NUM_WARNINGS
    jg .warn_at_skip
    mov rax, r12
    bt [warning_mask], rax
    jc .warn_at_skip

    ; Emit warning
    inc qword [warning_count]

    ; Save current out_fd (might be temp file, not stdout)
    mov rax, [out_fd]
    push rax                    ; save original fd

    ; Flush current buffer first (so assembly in progress is written cleanly)
    call out_flush

    ; Switch to stderr for warning output
    mov rdi, STDERR
    call out_set_fd

    ; Print source_path:
    mov rsi, [source_path]
    test rsi, rsi
    jz .warn_at_no_path
    call out_write_string
    mov dil, ':'
    call out_write_char
.warn_at_no_path:

    ; Print line:
    mov rdi, r13
    call out_write_int
    mov dil, ':'
    call out_write_char

    ; Print col:
    mov rdi, r14
    call out_write_int

    ; Print ": warning: "
    mov rsi, msg_warn_prefix
    call out_write_string

    ; Print message
    mov rsi, r15
    call out_write_string
    mov dil, 10
    call out_write_char

    ; Flush stderr and restore original fd
    call out_flush
    pop rdi                     ; restore original fd
    call out_set_fd

.warn_at_skip:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ------------------------------------------------------------
; warn_simple(category, msg)
; Emit warning with line=0 col=0 (no location info available).
; rdi = warning category
; rsi = message string pointer
; ------------------------------------------------------------
    global warn_simple
warn_simple:
    push rbx
    push r12
    push r13

    mov r12, rdi                ; r12 = category
    mov r13, rsi                ; r13 = message

    cmp qword [warnings_enabled], 0
    je .warn_simple_skip

    cmp r12, 0
    jle .warn_simple_skip
    cmp r12, NUM_WARNINGS
    jg .warn_simple_skip
    mov rax, r12
    bt [warning_mask], rax
    jc .warn_simple_skip

    inc qword [warning_count]

    ; Save current out_fd
    mov rax, [out_fd]
    push rax

    ; Flush current buffer, switch to stderr
    call out_flush
    mov rdi, STDERR
    call out_set_fd

    ; Print path
    mov rsi, [source_path]
    test rsi, rsi
    jz .warn_simple_no_path
    call out_write_string
    mov dil, ':'
    call out_write_char
.warn_simple_no_path:

    ; Use line=0 col=0
    xor rdi, rdi
    call out_write_int
    mov dil, ':'
    call out_write_char
    xor rdi, rdi
    call out_write_int
    mov dil, ':'
    call out_write_char

    ; Print "warning: "
    mov rsi, msg_warn_prefix
    call out_write_string

    ; Print message
    mov rsi, r13
    call out_write_string
    mov dil, 10
    call out_write_char

    ; Flush stderr, restore original fd
    call out_flush
    pop rdi
    call out_set_fd

.warn_simple_skip:
    pop r13
    pop r12
    pop rbx
    ret

; ------------------------------------------------------------
; warn_at_current(category, msg)
; Emit warning at current lexer token position.
; rdi = warning category
; rsi = message string pointer
; ------------------------------------------------------------
    global warn_at_current
warn_at_current:
    push rbx
    push rcx
    mov rbx, rdi                ; rbx = category
    mov rcx, rsi                ; rcx = message

    ; Pull position from lexer_state
    mov rsi, [lexer_state + 296]    ; tok_line
    mov rdx, [lexer_state + 304]    ; tok_col
    mov rdi, rbx                    ; rdi = category
    call warn_at

    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; warn_unused_var(name_ptr, name_len, line, col)
; Emit warning for unused variable, including the variable name.
; rdi = variable name pointer
; rsi = variable name length
; rdx = source line
; rcx = source column
; Uses WARN_UNUSED_VAR category.
; ------------------------------------------------------------
    global warn_unused_var
warn_unused_var:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12, rdi                ; r12 = name_ptr
    mov r13, rsi                ; r13 = name_len
    mov r14, rdx                ; r14 = line
    mov r15, rcx                ; r15 = column

    cmp qword [warnings_enabled], 0
    je .warn_unused_skip

    mov rax, WARN_UNUSED_VAR
    bt [warning_mask], rax
    jc .warn_unused_skip

    inc qword [warning_count]

    ; Save current out_fd
    mov rax, [out_fd]
    push rax

    ; Flush current buffer, switch to stderr
    call out_flush
    mov rdi, STDERR
    call out_set_fd

    ; Print path
    mov rsi, [source_path]
    test rsi, rsi
    jz .warn_unused_no_path
    call out_write_string
    mov dil, ':'
    call out_write_char
.warn_unused_no_path:

    ; Print line:
    mov rdi, r14
    call out_write_int
    mov dil, ':'
    call out_write_char

    ; Print col:
    mov rdi, r15
    call out_write_int

    ; Print ": warning: "
    mov rsi, msg_warn_prefix
    call out_write_string

    ; Print message: "unused variable 'NAME'"
    mov rsi, msg_warn_unused_var
    call out_write_string

    mov dil, ' '
    call out_write_char
    mov dil, 39                  ; single quote
    call out_write_char

    mov rsi, r12
    mov rdx, r13
    call out_write_string_len    ; write rdx bytes from rsi

    mov dil, 39                  ; single quote
    call out_write_char
    mov dil, 10                  ; newline
    call out_write_char

    ; Flush stderr, restore original fd
    call out_flush
    pop rdi
    call out_set_fd

.warn_unused_skip:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ------------------------------------------------------------
; print_warning_summary()
; Print total warning count at end of compilation.
; Format: "N warning(s) generated\n"
; ------------------------------------------------------------
    global print_warning_summary
print_warning_summary:
    push rax
    push rsi
    push rdi

    cmp qword [warnings_enabled], 0
    je .pws_skip

    cmp qword [warning_count], 0
    je .pws_skip

    ; Save current out_fd
    mov rax, [out_fd]
    push rax

    ; Flush current buffer, switch to stderr
    call out_flush
    mov rdi, STDERR
    call out_set_fd

    mov rdi, [warning_count]
    call out_write_int
    mov rsi, msg_warn_summary_fmt
    call out_write_string

    ; Flush stderr, restore original fd
    call out_flush
    pop rdi
    call out_set_fd

.pws_skip:
    pop rdi
    pop rsi
    pop rax
    ret
