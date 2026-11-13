; C2X Seed - Compiler Pipeline
; Main compiler logic: initialization, main loop, cleanup

; Token type constants (must match lexer.asm)
%define TOK_EOF         0
%define TOK_IDENT       1
%define TOK_NUMBER      2
%define TOK_STRING      3
%define TOK_CHAR        4

%define TOK_PLUS        10
%define TOK_MINUS       11
%define TOK_STAR        12
%define TOK_SLASH       13
%define TOK_PERCENT     14

%define TOK_EQ          20
%define TOK_EQEQ        21
%define TOK_NEQ         22
%define TOK_LT          23
%define TOK_LE          24
%define TOK_GT          25
%define TOK_GE          26

%define TOK_LPAREN      30
%define TOK_RPAREN      31
%define TOK_LBRACE      32
%define TOK_RBRACE      33
%define TOK_LBRACKET    34
%define TOK_RBRACKET    35

%define TOK_SEMI        40
%define TOK_COMMA       41
%define TOK_COLON       42
%define TOK_ARROW       43
%define TOK_AMPERSAND   44

%define TOK_KW_INT      50
%define TOK_KW_CHAR     51
%define TOK_KW_IF       52
%define TOK_KW_ELSE     53
%define TOK_KW_WHILE    54
%define TOK_KW_RETURN   55
%define TOK_KW_VOID     56
%define TOK_KW_EXTERN   58
%define TOK_KW_FOR      59
%define TOK_KW_BREAK    60
%define TOK_KW_CONTINUE 61

%define OUT_ASM_LIMIT  33554432    ; 32 MiB safety cap for generated asm output

; Lexer state offsets (must match lexer.asm)
struc lexer_state_t
    .current_char   resb 1
    .pad            resb 7
    .line           resq 1
    .column         resq 1
    .tok_type       resq 1
    .tok_buf        resb 256
    .tok_len        resq 1
    .tok_line       resq 1
    .tok_col        resq 1
endstruc

; ------------------------------------------------------------
; External Dependencies
; ------------------------------------------------------------
extern heap_init, out_init, out_flush, out_write_char
extern out_write_string, out_write_string_len
extern out_write_newline
extern out_write_int
extern out_set_fd, out_set_limit
extern out_limit_hit
extern out_fd
extern file_open_read, file_open_write, file_close, in_init
extern lexer_init, lexer_next_token, lexer_cleanup
extern lexer_state
extern error_at_code, error_code
extern msg_asm_fail, msg_ld_fail, msg_build_fail, msg_open_fail
extern parser_init, parser_parse_program, parser_cleanup, parser_reinit, parser_reset
extern codegen_init, codegen_generate, codegen_cleanup, symbol_tables_init
extern error_count
extern argc, argv, envp
extern warn_init, warn_disable_all, print_warning_summary
extern sys_open, sys_read, sys_close
extern sys_fork, sys_execve, sys_wait4, sys_unlink, sys_exit, sys_getpid, sys_dup2
extern STDOUT
extern STDERR

; ------------------------------------------------------------
; Exported Functions and Data
; ------------------------------------------------------------
global compiler_init, compiler_main, compiler_cleanup
global verbose_flag, verbose_print, verbose_print_int
global verbose_print_char, verbose_newline

section .data
    msg_init        db "c2x-seed v0.1.0 - C2X Stage 0 Compiler", 10, 0
    msg_colon       db ": ", 0
    msg_newl        db 10, 0
    msg_verbose_on  db "[VERBOSE] Verbose mode enabled", 10, 0
    msg_verbose_    db "[VERBOSE] ", 0
    msg_v_file_open db "Opening source file: ", 0
    msg_v_file_ok   db " (fd=", 0
    msg_v_close     db ")", 10, 0
    msg_v_init_io   db "Initializing I/O subsystem", 10, 0
    msg_v_init_lex  db "Initializing lexer", 10, 0
    msg_v_start     db "Starting tokenization loop", 10, 0
    msg_v_done      db "Tokenization complete", 10, 0
    msg_v_cleanup   db "Cleaning up", 10, 0
    msg_v_file_cl   db "Closing source file", 10, 0

section .bss
    global verbose_flag
    verbose_flag    resq 1
    global emit_result_flag
    emit_result_flag resq 1
    global emit_returns_flag
    emit_returns_flag resq 1
    global keep_asm_flag
    keep_asm_flag    resq 1

default rel

section .text

; ------------------------------------------------------------
; Compiler Initialization
; ------------------------------------------------------------
compiler_init:
    call heap_init
    call out_init
    call symbol_tables_init
    call init_temp_paths

    ; Banner goes to stderr: stdout carries emitted artifacts, and with `-S`
    ; the assembly stream must stay clean (nasm parses stdout as input).
    mov rax, [out_fd]
    push rax                    ; save original fd (STDOUT right after out_init)
    mov rdi, STDERR
    call out_set_fd
    mov rsi, msg_init
    call print_string
    call out_flush
    pop rdi                     ; restore original fd
    call out_set_fd
    ret

; ------------------------------------------------------------
; Main Compiler Pipeline
; ------------------------------------------------------------
compiler_main:
    push rbx
    push r12
    push r13
    push r14
    push r15

    xor rax, rax
    mov [verbose_flag], rax      ; default: not verbose
    mov [emit_result_flag], rax  ; default: no result printing
    mov [emit_returns_flag], rax ; default: no per-return printing
    mov [keep_asm_flag], rax     ; default: don't keep .asm files
    call warn_init               ; initialize warning system (warnings ON by default)

    ; Parse arguments
    mov r13, 1                   ; current argv index
    xor rax, rax
    mov [source_first_idx], rax  ; init to 0 (no source)
    mov [source_count], rax      ; no sources yet
    mov [output_path], rax       ; default: no -o flag
    mov qword [assemble_flag], 1 ; default: produce binary

.arg_loop:
    mov rax, [argc]
    cmp r13, rax
    jge .arg_done

    mov rax, [argv]
    mov rsi, [rax + r13 * 8]    ; argv[r13]

    ; Check for --verbose
    lea rdi, [str_verbose_long]
    call str_eq_cstr
    test rax, rax
    jnz .set_verbose

    ; Check for -v
    lea rdi, [str_verbose_short]
    call str_eq_cstr
    test rax, rax
    jnz .set_verbose

    ; Check for -o
    lea rdi, [str_o_flag]
    call str_eq_cstr
    test rax, rax
    jnz .set_output

    ; Check for -S
    lea rdi, [str_S_flag]
    call str_eq_cstr
    test rax, rax
    jnz .set_asm_only

    ; Check for --emit-result
    lea rdi, [str_emit_result_long]
    call str_eq_cstr
    test rax, rax
    jnz .set_emit_result

    ; Check for -r
    lea rdi, [str_emit_result_short]
    call str_eq_cstr
    test rax, rax
    jnz .set_emit_result

    ; Check for --emit-returns
    lea rdi, [str_emit_returns_long]
    call str_eq_cstr
    test rax, rax
    jnz .set_emit_returns

    ; Check for -e
    lea rdi, [str_emit_returns_short]
    call str_eq_cstr
    test rax, rax
    jnz .set_emit_returns

    ; Check for --no-warnings
    lea rdi, [str_no_warnings_long]
    call str_eq_cstr
    test rax, rax
    jnz .set_no_warnings

    ; Check for -Wno-all
    lea rdi, [str_no_warnings_short]
    call str_eq_cstr
    test rax, rax
    jnz .set_no_warnings

    ; Check for --keep-asm
    lea rdi, [str_keep_asm]
    call str_eq_cstr
    test rax, rax
    jnz .set_keep_asm

    ; Not a flag – treat as source filename
    cmp qword [source_count], 0
    jne .track_source
    mov [source_first_idx], r13     ; save first source argv index
.track_source:
    inc qword [source_count]        ; increment source file count
    inc r13
    jmp .arg_loop

.set_verbose:
    mov qword [verbose_flag], 1
    inc r13
    jmp .arg_loop

.set_output:
    inc r13
    mov rax, [argc]
    cmp r13, rax
    jge .usage_exit               ; -o at end, no filename given
    mov rax, [argv]
    mov rsi, [rax + r13 * 8]
    mov [output_path], rsi
    inc r13
    jmp .arg_loop

.set_asm_only:
    mov qword [assemble_flag], 0  ; 0 = assembly only, no binary
    inc r13
    jmp .arg_loop

.set_emit_result:
    mov qword [emit_result_flag], 1
    inc r13
    jmp .arg_loop

.set_emit_returns:
    mov qword [emit_returns_flag], 1
    inc r13
    jmp .arg_loop

.set_no_warnings:
    call warn_disable_all
    inc r13
    jmp .arg_loop

.set_keep_asm:
    mov qword [keep_asm_flag], 1
    inc r13
    jmp .arg_loop

.arg_done:
    cmp qword [source_count], 0
    je .no_source

    ; If -S mode, ignore any -o flag and keep assembly to stdout
    cmp qword [assemble_flag], 0
    jne .maybe_default_binary
    xor rax, rax
    mov [output_path], rax

.maybe_default_binary:
    ; If -S mode, no binary — keep output_path = 0 (stdout)
    cmp qword [assemble_flag], 0
    je .init_source_loop
    ; If assembling to binary and no -o given, default to "a.out"
    cmp qword [output_path], 0
    jne .init_source_loop
    lea rax, [str_a_out]
    mov [output_path], rax

    ; Announce verbose mode
    cmp qword [verbose_flag], 0
    je .init_source_loop
    mov rsi, msg_verbose_on
    call print_string

.init_source_loop:
    ; Loop through all source files, accumulating declarations
    xor r15, r15                     ; r15 = file index (0-based)
    ; r13 will hold the final AST root (set on first parse call)

.source_loop:
    ; Compute argv index for this file
    mov r14, [source_first_idx]
    add r14, r15                     ; r14 = argv index of current source file

    ; Get source filename
    mov rax, [argv]
    mov r14, [rax + r14 * 8]
    mov [source_path], r14           ; save for error reporting

    ; Verbose: print opening file info
    mov rsi, msg_v_file_open
    call verbose_print
    mov rsi, r14
    call verbose_print_string
    call out_flush

    ; Open source file
    mov rdi, r14
    call file_open_read
    test rax, rax
    js .file_error
    mov r12, rax                     ; save fd

    ; Verbose: print fd
    mov rsi, msg_v_file_ok
    call verbose_print
    mov rdi, r12
    call verbose_print_int
    mov rsi, msg_v_close
    call verbose_print

    ; Initialize input buffer
    mov rdi, r12
    call in_init
    call verbose_init_io

    ; Initialize or re-initialize lexer/parser
    test r15, r15                    ; is this the first file?
    jnz .source_reinit
    ; First file: full parser initialization (creates registries)
    call parser_init
    call verbose_init_lex
    jmp .source_parse

.source_reinit:
    ; Subsequent files: reinit lexer without resetting registries
    call parser_reinit

.source_parse:
    ; Start parsing
    mov rsi, msg_v_start
    call verbose_print

    ; Parse program into AST (accumulates into persistent registries)
    call parser_parse_program
    mov r13, rax                     ; save/update AST root

    mov rsi, msg_v_done
    call verbose_print

    ; Close source file
    mov rsi, msg_v_file_cl
    call verbose_print
    mov rdi, r12
    call file_close

    ; Move to next source file
    inc r15
    cmp r15, [source_count]
    jl .source_loop

    ; All source files parsed — check for errors
    cmp qword [error_count], 0
    jne .failed

    ; Initialize code generator
    call codegen_init

    ; If -o was given, flush pending output and redirect to temp .asm file
    cmp qword [output_path], 0
    je .gen_and_flush
    call out_flush                       ; flush any pending output to stdout first
    lea rdi, [tmp_asm_path]
    call file_open_write
    test rax, rax
    js .file_error
    mov [tmp_asm_fd], rax
    mov rdi, rax
    call out_set_fd
    mov rdi, OUT_ASM_LIMIT
    call out_set_limit

.gen_and_flush:
    ; Generate code from AST
    mov rdi, r13
    call codegen_generate
    call out_flush

    cmp qword [out_limit_hit], 0
    je .continue_build

    ; The temp assembly file hit the asm safety cap. Abort before invoking nasm,
    ; but keep the partial .asm around so we can inspect it directly.
    mov rdi, [tmp_asm_fd]
    call file_close
    mov rdi, STDOUT
    call out_set_fd
    xor rdi, rdi
    call out_set_limit
    mov rsi, msg_output_limit
    call print_string
    mov qword [error_count], 1
    lea rdi, [tmp_obj_path]
    call sys_unlink
    jmp .cleanup_only

.continue_build:

    ; If -o was given, close temp file and run nasm+ld
    cmp qword [output_path], 0
    je .cleanup_only
    mov rdi, [tmp_asm_fd]
    call file_close
    mov rdi, STDOUT
    call out_set_fd
    xor rdi, rdi
    call out_set_limit
    call assemble_and_link

.cleanup_only:
    ; Cleanup (files already closed in source loop)
    call parser_cleanup
    mov rsi, msg_v_cleanup
    call verbose_print

    call out_flush

    ; Return 0 on success, 1 on errors
    xor rax, rax
    cmp qword [error_count], 0
    je .ret_ok
    mov rax, 1
.ret_ok:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.no_source:
.usage_exit:
    ; Print usage
    mov rsi, msg_usage
    call print_string
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.failed:
    ; Compilation errors detected — print failure, skip codegen
    mov rsi, msg_build_fail
    call print_string
    jmp .cleanup_only

.file_error:
    mov rsi, msg_open_fail
    call print_string
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ------------------------------------------------------------
; Compiler Cleanup
; ------------------------------------------------------------
compiler_cleanup:
    call out_flush
    ret

; ------------------------------------------------------------
; assemble_and_link()
; Build final binary by running nasm + ld as subprocesses.
; Uses output_path (final binary) and tmp_asm_path / tmp_obj_path (temp files).
; Clobbers: rax, rbx, rcx, rdx, rsi, rdi, r8, r9, r10, r11
; ------------------------------------------------------------
assemble_and_link:
    push r12
    push r13
    push r14
    push r15

    ; --- NASM: assemble .asm -> .o ---
    ; The assembly is fed to nasm on stdin (input argument "/dev/stdin"),
    ; NOT through its PID-unique temp path. nasm records the *input path* in
    ; the object's FILE symbol, and `ld` copies that into the final
    ; executable's .strtab; a temp path containing the PID would make the
    ; output binary differ on every build. "/dev/stdin" is stable, so the
    ; build is reproducible (docs/harmony.md §25.6). The temp .asm is still
    ; written to disk so --keep-asm can show it after a failure.
    mov rsi, msg_assemble
    call verbose_print

    ; Build nasm argv
    lea r15, [nasm_argv]
    mov rax, str_nasm_path
    mov [r15], rax          ; argv[0] = nasm path
    mov rax, str_f
    mov [r15 + 8], rax      ; argv[1] = "-f"
    mov rax, str_elf64
    mov [r15 + 16], rax     ; argv[2] = "elf64"
    mov rax, str_o_flag
    mov [r15 + 24], rax     ; argv[3] = "-o"
    lea rax, [tmp_obj_path]
    mov [r15 + 32], rax     ; argv[4] = tmp .o file
    mov rax, str_dev_stdin
    mov [r15 + 40], rax     ; argv[5] = "/dev/stdin" (stable FILE symbol)
    mov qword [r15 + 48], 0 ; argv[6] = NULL

    ; Open the temp .asm read-only; its fd is dup2'd onto the child's stdin.
    lea rdi, [tmp_asm_path]
    xor rsi, rsi            ; O_RDONLY
    xor rdx, rdx
    call sys_open
    test rax, rax
    js .asm_fail            ; unreadable temp .asm -> assembler cannot run
    mov [nasm_asm_fd], rax

    mov rdi, str_nasm_path
    lea rsi, [nasm_argv]
    mov rdx, [envp]
    mov rcx, [nasm_asm_fd]  ; rcx = fd to dup onto the child's stdin
    call run_and_wait
    mov rbx, rax            ; save status; always close our stdin copy
    mov rdi, [nasm_asm_fd]
    call sys_close
    test rbx, rbx
    jnz .asm_fail

    ; --- LD: link .o -> final binary ---
    mov rsi, msg_linking
    call verbose_print

    ; Build ld argv
    lea r15, [ld_argv]
    mov rax, str_ld_path
    mov [r15], rax          ; argv[0] = ld path
    mov rax, str_o_flag
    mov [r15 + 8], rax      ; argv[1] = "-o"
    mov rax, [output_path]
    mov [r15 + 16], rax     ; argv[2] = output binary path
    lea rax, [tmp_obj_path]
    mov [r15 + 24], rax     ; argv[3] = tmp .o file
    mov qword [r15 + 32], 0 ; argv[4] = NULL

    mov rdi, str_ld_path
    lea rsi, [ld_argv]
    mov rdx, [envp]
    mov rcx, -1             ; no stdin redirection for ld
    call run_and_wait
    test rax, rax
    jnz .ld_fail

    ; Print success
    mov rsi, msg_build_ok
    call print_string
    mov rsi, [output_path]
    call print_string
    mov dil, 10
    call out_write_char

    ; Print warning summary
    call print_warning_summary

    ; Clean up temp files (unless --keep-asm)
    cmp qword [keep_asm_flag], 0
    je .do_unlink_asm
    ; Keep .asm: print its path for the user
    mov rsi, msg_keep_asm
    call print_string
    lea rsi, [tmp_asm_path]
    call print_string
    mov dil, 10
    call out_write_char
    jmp .skip_unlink_asm
.do_unlink_asm:
    lea rdi, [tmp_asm_path]
    call sys_unlink
.skip_unlink_asm:
    lea rdi, [tmp_obj_path]
    call sys_unlink

    pop r15
    pop r14
    pop r13
    pop r12
    ret

.asm_fail:
    mov rsi, msg_asm_fail
    call print_string
    jmp .fail_exit

.ld_fail:
    mov rsi, msg_ld_fail
    call print_string
    ; fall through

.fail_exit:
    ; Clean up temp files on failure too (unless --keep-asm)
    cmp qword [keep_asm_flag], 0
    jne .skip_asm_unlink_fail
    lea rdi, [tmp_asm_path]
    call sys_unlink
.skip_asm_unlink_fail:
    lea rdi, [tmp_obj_path]
    call sys_unlink
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; ------------------------------------------------------------
; run_and_wait(rdi = path, rsi = argv, rdx = envp, rcx = stdin_fd)
; Fork, execve, wait for child. Returns 0 on success, 1 on failure.
; When rcx >= 0 the child's stdin (fd 0) is dup2'd from that fd before
; execve, so a tool like nasm can read its input from stdin. Pass -1 to leave
; the child's stdin untouched. rcx is clobbered by the syscall wrapper, so it
; is preserved in a callee-saved register across the fork.
; ------------------------------------------------------------
run_and_wait:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi            ; path
    mov r13, rsi            ; argv
    mov r14, rcx            ; stdin fd (-1 = inherit)

    call sys_fork
    test rax, rax
    js .fork_fail           ; fork failed
    test rax, rax
    jz .child               ; child process

    ; Parent: wait for child
    mov rdi, rax            ; pid
    lea rsi, [child_status]
    mov rdx, 0              ; options = 0
    xor r10, r10            ; rusage = NULL
    call sys_wait4

    ; Check child exit status
    mov rax, [child_status]
    test rax, rax
    jnz .child_fail

    pop r14
    pop r13
    pop r12
    pop rbx
    xor rax, rax            ; success
    ret

.child:
    ; Redirect stdin if a source fd was provided.
    cmp r14, 0
    jl .child_exec
    mov rdi, r14            ; oldfd
    xor rsi, rsi            ; newfd = 0 (stdin)
    call sys_dup2
.child_exec:
    mov rdi, r12            ; path
    mov rsi, r13            ; argv
    mov rdx, [envp]
    call sys_execve
    ; execve only returns on error
    mov rdi, 1
    call sys_exit

.fork_fail:
    mov rax, 1
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.child_fail:
    mov rax, 1
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ------------------------------------------------------------
; print_token_name(rdi = token_type)
; ------------------------------------------------------------
print_token_name:
    cmp rdi, TOK_EOF
    je .eof
    cmp rdi, TOK_IDENT
    je .ident
    cmp rdi, TOK_NUMBER
    je .number
    cmp rdi, TOK_STRING
    je .string
    cmp rdi, TOK_CHAR
    je .char

    cmp rdi, TOK_PLUS
    je .plus
    cmp rdi, TOK_MINUS
    je .minus
    cmp rdi, TOK_STAR
    je .star
    cmp rdi, TOK_SLASH
    je .slash
    cmp rdi, TOK_PERCENT
    je .percent

    cmp rdi, TOK_EQ
    je .eq
    cmp rdi, TOK_EQEQ
    je .eqeq
    cmp rdi, TOK_NEQ
    je .neq
    cmp rdi, TOK_LT
    je .lt
    cmp rdi, TOK_LE
    je .le
    cmp rdi, TOK_GT
    je .gt
    cmp rdi, TOK_GE
    je .ge

    cmp rdi, TOK_LPAREN
    je .lparen
    cmp rdi, TOK_RPAREN
    je .rparen
    cmp rdi, TOK_LBRACE
    je .lbrace
    cmp rdi, TOK_RBRACE
    je .rbrace
    cmp rdi, TOK_LBRACKET
    je .lbracket
    cmp rdi, TOK_RBRACKET
    je .rbracket

    cmp rdi, TOK_SEMI
    je .semi
    cmp rdi, TOK_COMMA
    je .comma
    cmp rdi, TOK_COLON
    je .colon
    cmp rdi, TOK_ARROW
    je .arrow
    cmp rdi, TOK_AMPERSAND
    je .ampersand

    cmp rdi, TOK_KW_INT
    je .kw_int
    cmp rdi, TOK_KW_CHAR
    je .kw_char
    cmp rdi, TOK_KW_IF
    je .kw_if
    cmp rdi, TOK_KW_ELSE
    je .kw_else
    cmp rdi, TOK_KW_WHILE
    je .kw_while
    cmp rdi, TOK_KW_RETURN
    je .kw_return
    cmp rdi, TOK_KW_VOID
    je .kw_void
    cmp rdi, TOK_KW_EXTERN
    je .kw_extern
    cmp rdi, TOK_KW_FOR
    je .kw_for
    cmp rdi, TOK_KW_BREAK
    je .kw_break
    cmp rdi, TOK_KW_CONTINUE
    je .kw_continue

    ; fallback: print numeric
    call out_write_int
    ret

.eof:       mov rsi, .s_eof
            call out_write_string
            ret
.ident:     mov rsi, .s_ident
            call out_write_string
            ret
.number:    mov rsi, .s_number
            call out_write_string
            ret
.string:    mov rsi, .s_string
            call out_write_string
            ret
.char:      mov rsi, .s_char
            call out_write_string
            ret
.plus:      mov rsi, .s_plus
            call out_write_string
            ret
.minus:     mov rsi, .s_minus
            call out_write_string
            ret
.star:      mov rsi, .s_star
            call out_write_string
            ret
.slash:     mov rsi, .s_slash
            call out_write_string
            ret
.percent:   mov rsi, .s_percent
            call out_write_string
            ret
.eq:        mov rsi, .s_eq
            call out_write_string
            ret
.eqeq:      mov rsi, .s_eqeq
            call out_write_string
            ret
.neq:       mov rsi, .s_neq
            call out_write_string
            ret
.lt:        mov rsi, .s_lt
            call out_write_string
            ret
.le:        mov rsi, .s_le
            call out_write_string
            ret
.gt:        mov rsi, .s_gt
            call out_write_string
            ret
.ge:        mov rsi, .s_ge
            call out_write_string
            ret
.lparen:    mov rsi, .s_lparen
            call out_write_string
            ret
.rparen:    mov rsi, .s_rparen
            call out_write_string
            ret
.lbrace:    mov rsi, .s_lbrace
            call out_write_string
            ret
.rbrace:    mov rsi, .s_rbrace
            call out_write_string
            ret
.lbracket:  mov rsi, .s_lbracket
            call out_write_string
            ret
.rbracket:  mov rsi, .s_rbracket
            call out_write_string
            ret
.semi:      mov rsi, .s_semi
            call out_write_string
            ret
.comma:     mov rsi, .s_comma
            call out_write_string
            ret
.colon:     mov rsi, .s_colon
            call out_write_string
            ret
.arrow:     mov rsi, .s_arrow
            call out_write_string
            ret
.ampersand: mov rsi, .s_ampersand
            call out_write_string
            ret
.kw_int:    mov rsi, .s_kw_int
            call out_write_string
            ret
.kw_char:   mov rsi, .s_kw_char
            call out_write_string
            ret
.kw_if:     mov rsi, .s_kw_if
            call out_write_string
            ret
.kw_else:   mov rsi, .s_kw_else
            call out_write_string
            ret
.kw_while:  mov rsi, .s_kw_while
            call out_write_string
            ret
.kw_return: mov rsi, .s_kw_return
            call out_write_string
            ret
.kw_void:   mov rsi, .s_kw_void
            call out_write_string
            ret
.kw_extern: mov rsi, .s_kw_extern
            call out_write_string
            ret
.kw_for:    mov rsi, .s_kw_for
            call out_write_string
            ret
.kw_break:  mov rsi, .s_kw_break
            call out_write_string
            ret
.kw_continue: mov rsi, .s_kw_continue
            call out_write_string
            ret

section .data
.s_eof:       db "EOF", 0
.s_ident:     db "IDENT", 0
.s_number:    db "NUMBER", 0
.s_string:    db "STRING", 0
.s_char:      db "CHAR", 0
.s_plus:      db "+", 0
.s_minus:     db "-", 0
.s_star:      db "*", 0
.s_slash:     db "/", 0
.s_percent:   db "%", 0
.s_eq:        db "=", 0
.s_eqeq:      db "==", 0
.s_neq:       db "!=", 0
.s_lt:        db "<", 0
.s_le:        db "<=", 0
.s_gt:        db ">", 0
.s_ge:        db ">=", 0
.s_lparen:    db "(", 0
.s_rparen:    db ")", 0
.s_lbrace:    db "{", 0
.s_rbrace:    db "}", 0
.s_lbracket:  db "[", 0
.s_rbracket:  db "]", 0
.s_semi:      db ";", 0
.s_comma:     db ",", 0
.s_colon:     db ":", 0
.s_arrow:     db "->", 0
.s_ampersand: db "&", 0
.s_kw_int:    db "int", 0
.s_kw_char:   db "char", 0
.s_kw_if:     db "if", 0
.s_kw_else:   db "else", 0
.s_kw_while:  db "while", 0
.s_kw_return: db "return", 0
.s_kw_void:   db "void", 0
.s_kw_extern: db "extern", 0
.s_kw_for:    db "for", 0
.s_kw_break:  db "break", 0
.s_kw_continue: db "continue", 0

section .text

; ------------------------------------------------------------
; Verbose Output Helpers
; ------------------------------------------------------------

; verbose_print(rsi = string)
; Print string only if verbose_flag is set
verbose_print:
    cmp qword [verbose_flag], 0
    jz .skip
    jmp print_string
.skip:
    ret

; verbose_print_int(rdi = value)
; Print integer only if verbose_flag is set
verbose_print_int:
    cmp qword [verbose_flag], 0
    jz .skip
    jmp out_write_int
.skip:
    ret

; verbose_print_char(dil = char)
; Print char only if verbose_flag is set
verbose_print_char:
    cmp qword [verbose_flag], 0
    jz .skip
    jmp out_write_char
.skip:
    ret

; verbose_newline()
; Print newline only if verbose_flag is set
verbose_newline:
    cmp qword [verbose_flag], 0
    jz .skip
    jmp out_write_newline
.skip:
    ret

; verbose_print_string(rsi = string)
; Print null-terminated string only if verbose_flag is set
verbose_print_string:
    cmp qword [verbose_flag], 0
    jz .skip
    jmp out_write_string
.skip:
    ret

; verbose_init_io()
verbose_init_io:
    mov rsi, msg_v_init_io
    jmp verbose_print

; verbose_init_lex()
verbose_init_lex:
    mov rsi, msg_v_init_lex
    jmp verbose_print

; ------------------------------------------------------------
; str_eq_cstr(rsi = str1, rdi = str2)
; Compare two null-terminated strings for equality.
; Returns: rax = 1 if equal, 0 otherwise
; ------------------------------------------------------------
str_eq_cstr:
    push rsi
    push rdi
.loop:
    mov al, [rsi]
    mov bl, [rdi]
    cmp al, bl
    jne .neq
    test al, al
    jz .eq
    inc rsi
    inc rdi
    jmp .loop
.eq:
    pop rdi
    pop rsi
    mov rax, 1
    ret
.neq:
    pop rdi
    pop rsi
    xor rax, rax
    ret

; ------------------------------------------------------------
; String constants for argument parsing and subprocess execution
; ------------------------------------------------------------
section .data
str_verbose_long    db "--verbose", 0
str_verbose_short   db "-v", 0
str_o_flag          db "-o", 0
str_S_flag          db "-S", 0
str_emit_result_long db "--emit-result", 0
str_emit_result_short db "-r", 0
str_emit_returns_long db "--emit-returns", 0
str_emit_returns_short db "-e", 0
str_no_warnings_long db "--no-warnings", 0
str_no_warnings_short db "-Wno-all", 0
str_keep_asm         db "--keep-asm", 0
str_a_out         db "a.out", 0
msg_usage         db "Usage: c2x-seed [--verbose|-v] [--emit-result|-r] [--emit-returns|-e] [--keep-asm] [-S] [-o <output>] <source.c2>", 10, 0
tmp_path_prefix   db "/tmp/c2x_build_", 0
tmp_path_asm_sfx  db ".asm", 0
tmp_path_obj_sfx  db ".o", 0
str_nasm_path     db "/usr/bin/nasm", 0
str_ld_path       db "/usr/bin/ld", 0
str_f             db "-f", 0
str_elf64         db "elf64", 0
str_dev_stdin     db "/dev/stdin", 0     ; stable nasm input name (see assemble_and_link)
msg_assemble      db "Assembling...", 10, 0
msg_linking       db "Linking...", 10, 0
msg_build_ok      db "Build complete: ", 0
msg_keep_asm      db "Kept assembly: ", 0
msg_output_limit  db "Error: generated assembly exceeded the asm safety limit", 10, 0

msg_error_sep     db ": error: ", 0   ; separator for error_at output
msg_fatal_abort   db "C2X: too many errors, aborting", 0

section .bss
    global output_path
    output_path     resq 1          ; output binary path (0 = no binary)
    global source_path
    source_path     resq 1          ; source file path (for error reporting)
    source_first_idx resq 1         ; argv index of first source file
    source_count    resq 1          ; number of source files
    assemble_flag   resq 1          ; 1 = produce binary (default), 0 = assembly only (-S)
    tmp_asm_fd      resq 1
    nasm_asm_fd     resq 1          ; read-only fd of the temp .asm, dup2'd to nasm's stdin
    tmp_path_pid    resq 1
    tmp_asm_path    resb 64
    tmp_obj_path    resb 64
    child_status    resq 1
    last_err_line   resq 1          ; dedup: last error's line (0 = no prior error)
    last_err_col    resq 1          ; dedup: last error's column
    last_err_msg    resq 1          ; dedup: last error's message pointer
    ; argv arrays (built at runtime)
    nasm_argv       resq 7          ; nasm, -f, elf64, -o, tmp.o, tmp.asm, NULL
    ld_argv         resq 5          ; ld, -o, output, tmp.o, NULL

section .text

; ------------------------------------------------------------
; Utility Functions
; ------------------------------------------------------------
print_string:
    push rsi
    call strlen
    mov rdx, rax
    pop rsi
    call out_write_string_len
    ret

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
; copy_cstr(rdi = dst_ptr, rsi = src_ptr) -> rax = dst_ptr after copy
; Copies bytes up to but not including the source null terminator.
; ------------------------------------------------------------
copy_cstr:
    push rbx
.copy_loop:
    mov bl, [rsi]
    cmp bl, 0
    je .copy_done
    mov [rdi], bl
    inc rdi
    inc rsi
    jmp .copy_loop
.copy_done:
    mov rax, rdi
    pop rbx
    ret

; ------------------------------------------------------------
; append_hex16(rdi = dst_ptr, rax = value) -> rax = dst_ptr after write
; Writes 16 lowercase hex digits.
; ------------------------------------------------------------
append_hex16:
    push rcx
    push rdx

    mov rcx, 16
.hex_loop:
    mov rdx, rax
    shr rdx, 60
    cmp dl, 9
    jbe .digit
    add dl, 'a' - 10
    jmp .store
.digit:
    add dl, '0'
.store:
    mov [rdi], dl
    inc rdi
    shl rax, 4
    dec rcx
    jnz .hex_loop

    mov rax, rdi
    pop rdx
    pop rcx
    ret

; ------------------------------------------------------------
; init_temp_paths()
; Builds per-process temp paths for the asm/object intermediates.
; ------------------------------------------------------------
init_temp_paths:
    call sys_getpid
    mov [tmp_path_pid], rax

    lea rdi, [tmp_asm_path]
    lea rsi, [tmp_path_prefix]
    call copy_cstr
    mov rdi, rax
    mov rax, [tmp_path_pid]
    call append_hex16
    mov rdi, rax
    lea rsi, [tmp_path_asm_sfx]
    call copy_cstr
    mov byte [rax], 0

    lea rdi, [tmp_obj_path]
    lea rsi, [tmp_path_prefix]
    call copy_cstr
    mov rdi, rax
    mov rax, [tmp_path_pid]
    call append_hex16
    mov rdi, rax
    lea rsi, [tmp_path_obj_sfx]
    call copy_cstr
    mov byte [rax], 0
    ret

; ------------------------------------------------------------
; error_at(int line, int col, const char* msg)
; Print file:line:col: error: msg + source line + caret
; rdi = line, rsi = col, rdx = msg
; ------------------------------------------------------------
    global error_at
error_at:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12, rdi                ; line
    mov r13, rsi                ; col
    mov r14, rdx                ; msg

    ; Dedup: skip if same line, col, and message as last error
    cmp qword [last_err_line], 0
    je .record_error
    cmp r12, [last_err_line]
    jne .record_error
    cmp r13, [last_err_col]
    jne .record_error
    cmp r14, [last_err_msg]
    jne .record_error
    ; Same error repeated — skip printing, don't count
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.record_error:
    mov [last_err_line], r12
    mov [last_err_col], r13
    mov [last_err_msg], r14

    inc qword [error_count]

    ; Safety threshold: abort if too many distinct errors
    cmp qword [error_count], 100
    jg .fatal_abort

    ; Print source_path:
    mov rsi, [source_path]
    test rsi, rsi
    jz .no_path
    call print_string
    mov dil, ':'
    call out_write_char
.no_path:

    ; Print line:
    mov rdi, r12
    call out_write_int
    mov dil, ':'
    call out_write_char

    ; Print col:
    mov rdi, r13
    call out_write_int

    ; Print ": error: "
    mov rsi, msg_error_sep
    call print_string

    ; Print error message
    mov rsi, r14
    call print_string
    mov dil, 10
    call out_write_char

    ; Print the failing source line with caret indicator
    mov rdi, r12                ; line
    mov rsi, r13                ; col
    call print_source_line

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.fatal_abort:
    ; Too many errors — abort immediately
    mov rsi, msg_fatal_abort
    call print_string
    mov dil, 10
    call out_write_char
    call out_flush
    mov rdi, 1
    mov rax, 60
    syscall

; ------------------------------------------------------------
; print_source_line(int line, int col)
; Opens source_path, reads to line, prints that line and a caret
; rdi = line, rsi = col
; ------------------------------------------------------------
print_source_line:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 4096                   ; 4KB read buffer

    mov r12, rdi                   ; target line
    mov r13, rsi                   ; target col

    ; Open source file
    mov rdi, [source_path]
    test rdi, rdi
    jz .done
    xor rsi, rsi                   ; O_RDONLY = 0
    xor rdx, rdx                   ; mode = 0
    call sys_open
    test rax, rax
    js .done                       ; can't open
    mov r15, rax                   ; fd

    ; Skip to target line (read chunks, scan for newlines)
    mov r14, 1                     ; current line counter (1-based)
    jmp .read_chunk

.skip_line:
    cmp r14, r12
    je .print_line
    jmp .scan_loop                   ; continue scanning current chunk

.read_chunk:
    mov rdi, r15                   ; fd
    lea rsi, [rsp]                 ; buffer
    mov rdx, 4096                  ; read up to 4KB
    call sys_read
    test rax, rax
    jle .close                     ; EOF or error
    mov rbx, rax                   ; rbx = bytes read
    xor rcx, rcx                   ; rcx = offset in buffer

.scan_loop:
    cmp rcx, rbx
    jae .read_chunk                ; exhausted buffer, refill
    movzx rax, byte [rsp + rcx]
    inc rcx
    cmp al, 10                     ; newline?
    jne .scan_loop
    inc r14                        ; next line
    jmp .skip_line

.print_line:
    ; We've landed at or past the target line start.
    ; Need to re-read from beginning of the line since we over-scanned.
    ; Close and reopen to reset file position.
    mov rdi, r15
    call sys_close
    mov rdi, [source_path]
    xor rsi, rsi
    xor rdx, rdx
    call sys_open
    test rax, rax
    js .done
    mov r15, rax

    ; Skip to target line (same chunked scan)
    mov r14, 1
    mov rbx, 0                     ; bytes in current chunk
    xor rcx, rcx                   ; offset in chunk

.skip_line2:
    cmp r14, r12
    je .print_line2
    jmp .scan_loop2

.refill2:
    mov rdi, r15
    lea rsi, [rsp]
    mov rdx, 4096
    call sys_read
    test rax, rax
    jle .close
    mov rbx, rax
    xor rcx, rcx

.scan_loop2:
    cmp rcx, rbx
    jae .refill2
    movzx rax, byte [rsp + rcx]
    inc rcx
    cmp al, 10
    jne .scan_loop2
    inc r14
    jmp .skip_line2

.print_line2:
    ; rcx now points to first byte AFTER the newline on the previous line.
    ; Print remaining bytes in current chunk until newline or EOF.
    jmp .print_chunk_rest

.print_chunk_rest:
    cmp rcx, rbx
    jb .print_from_chunk
    ; Refill
    mov rdi, r15
    lea rsi, [rsp]
    mov rdx, 4096
    call sys_read
    test rax, rax
    jle .after_line2               ; EOF after target line? still acceptable
    mov rbx, rax
    xor rcx, rcx

.print_from_chunk:
    movzx rax, byte [rsp + rcx]
    inc rcx
    cmp al, 10
    je .after_line2
    cmp al, 13
    je .print_chunk_rest
    mov dil, al
    call out_write_char
    jmp .print_chunk_rest

.after_line2:
    ; Print newline after the source line
    mov dil, 10
    call out_write_char

    ; Print caret: indent by r13 spaces, then '^'
    xor rcx, rcx
.caret_loop:
    cmp rcx, r13
    jge .print_caret
    mov dil, ' '
    call out_write_char
    inc rcx
    jmp .caret_loop
.print_caret:
    mov dil, '^'
    call out_write_char
    mov dil, 10
    call out_write_char

.close:
    ; Close source file
    mov rdi, r15
    call sys_close

.done:
    add rsp, 4096
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
