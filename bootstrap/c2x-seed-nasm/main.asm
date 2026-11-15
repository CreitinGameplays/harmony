; C2X Seed Compiler - Stage 0 (main entry point)
; Written in x86_64 NASM Assembly for Linux
; No external dependencies - only Linux syscalls
;
; Build: nasm -f elf64 -o build/main.o bootstrap/c2x-seed/main.asm
;        ld -o build/c2x-seed build/main.o build/syscalls.o build/memory.o build/types.o build/io.o build/compiler.o

; External function declarations
extern sys_exit, sys_read, sys_write, sys_open, sys_close, sys_brk, sys_mmap
extern heap_init, heap_alloc, heap_alloc_zero, frame_push, frame_pop, frame_alloc, mem_zero, mem_copy, mem_eq
extern type_size, type_align, type_is_integer, type_is_pointer, type_get_pointee
extern sign_extend_char, zero_extend_char, truncate_int_to_char
extern ptr_add, ptr_diff
extern deref_int, deref_char, deref_ptr, store_int, store_char, store_ptr
extern out_init, out_flush, out_write_char, out_write_string, out_write_string_len
extern out_write_newline, out_write_int, out_write_hex
extern in_init, in_fill, in_get_char, in_peek_char, in_skip_char
extern file_open_read, file_open_write, file_close, file_read_all
extern compiler_init, compiler_main, compiler_cleanup

; External data declarations
extern EXIT_SUCCESS, EXIT_FAILURE
extern STDIN, STDOUT, STDERR
extern O_RDONLY, O_WRONLY, O_RDWR, O_CREAT, O_TRUNC, O_APPEND

section .data
    ; Program metadata
    prog_name       db "c2x-seed", 0
    version         db "0.1.0", 0
    newline         db 10

section .bss
    ; Command line arguments
    global argc, argv, envp
    argc            resq 1
    argv            resq 1
    envp            resq 1

default rel

section .text
    global _start

; ------------------------------------------------------------
; Entry Point
; ------------------------------------------------------------
_start:
    ; Save argc/argv/envp from stack (Linux x86_64 calling convention)
    pop rax                 ; argc
    mov [argc], rax
    mov [argv], rsp         ; argv pointer
    ; envp = rsp + argc*8 + 8 (skip argv array + NULL terminator)
    lea rbx, [rsp + rax*8 + 8]
    mov [envp], rbx
    
    ; Initialize and run compiler
    call compiler_init
    call compiler_main
    mov r15, rax               ; save return value
    call compiler_cleanup
    
    ; Exit with compiler's return value
    mov rdi, r15
    call sys_exit

; ------------------------------------------------------------
; Main Compiler Logic (now in compiler.asm)
; ------------------------------------------------------------
; compiler_init, compiler_main, compiler_cleanup are defined in compiler.asm
; but we keep stubs here for reference

; compiler_init:
;     call heap_init
;     call out_init
;     ; Print startup message
;     mov rsi, prog_name
;     call print_string
;     mov dil, 10
;     call out_write_char
;     ret

; compiler_main:
;     ; TODO: Full compiler pipeline
;     ; 1. Parse command line args for source file
;     ; 2. Open source file
;     ; 3. Initialize lexer with source
;     ; 4. Parse program
;     ; 5. Generate assembly output
;     ; 6. Write output to file or stdout
;     
;     mov rsi, msg_not_implemented
;     call print_string
;     ret

; compiler_cleanup:
;     call out_flush
;     ret

; ------------------------------------------------------------
; Utility Functions
; ------------------------------------------------------------

; print_string: Print null-terminated string at RSI to STDOUT via output buffer
; Clobbers: rax
print_string:
    push rsi
    call strlen
    mov rdx, rax
    pop rsi
    call out_write_string_len
    ret

; strlen: Calculate length of null-terminated string at RSI
; Returns: rax = length
; Clobbers: rax, rcx
strlen:
    xor rax, rax
    xor rcx, rcx
.loop:
    cmp byte [rsi + rcx], 0
    je .done
    inc rcx
    jmp .loop
.done:
    mov rax, rcx
    ret

; ------------------------------------------------------------
; Data: Messages
; ------------------------------------------------------------
msg_not_implemented db "Compiler logic not yet implemented", 10, 0