format ELF64

; C2X Seed Compiler - Stage 0 (main entry point)
; Written in x86_64 assembly (flat assembler / FASM syntax) for Linux
; No external dependencies - only Linux syscalls
;
; Build: bash build.sh (fasm assembles each bootstrap/c2x-seed/*.asm)
;        ld -o build/c2x-seed build/main.o build/syscalls.o build/memory.o build/types.o build/io.o build/compiler.o

; External function declarations

; External data declarations

section '.data' writeable
    ; Program metadata
    prog_name:       db "c2x-seed", 0
    version:         db "0.1.0", 0
    newline:         db 10

section '.bss' writeable
    ; Command line arguments
    argc:            rq 1
    argv:            rq 1
    envp:            rq 1


section '.text' executable

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
msg_not_implemented: db "Compiler logic not yet implemented", 10, 0
extrn sys_exit
extrn sys_read
extrn sys_write
extrn sys_open
extrn sys_close
extrn sys_brk
extrn sys_mmap
extrn heap_init
extrn heap_alloc
extrn heap_alloc_zero
extrn frame_push
extrn frame_pop
extrn frame_alloc
extrn mem_zero
extrn mem_copy
extrn mem_eq
extrn type_size
extrn type_align
extrn type_is_integer
extrn type_is_pointer
extrn type_get_pointee
extrn sign_extend_char
extrn zero_extend_char
extrn truncate_int_to_char
extrn ptr_add
extrn ptr_diff
extrn deref_int
extrn deref_char
extrn deref_ptr
extrn store_int
extrn store_char
extrn store_ptr
extrn out_init
extrn out_flush
extrn out_write_char
extrn out_write_string
extrn out_write_string_len
extrn out_write_newline
extrn out_write_int
extrn out_write_hex
extrn in_init
extrn in_fill
extrn in_get_char
extrn in_peek_char
extrn in_skip_char
extrn file_open_read
extrn file_open_write
extrn file_close
extrn file_read_all
extrn compiler_init
extrn compiler_main
extrn compiler_cleanup
extrn EXIT_SUCCESS
extrn EXIT_FAILURE
extrn STDIN
extrn STDOUT
extrn STDERR
extrn O_RDONLY
extrn O_WRONLY
extrn O_RDWR
extrn O_CREAT
extrn O_TRUNC
extrn O_APPEND
public argc
public argv
public envp
public _start
