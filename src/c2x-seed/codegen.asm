; C2X Seed - Code Generator
; Walks AST and emits x86_64 NASM assembly

; ------------------------------------------------------------
; External Dependencies
; ------------------------------------------------------------
extern out_write_string, out_write_string_len, out_write_char
extern out_write_newline, out_write_int
extern heap_alloc_zero, mem_copy
extern emit_result_flag
extern emit_returns_flag
extern warn_simple, warn_at_current, warn_at, warn_unused_var
extern lexer_state
extern msg_warn_uninit_var, msg_warn_uninit_ptr
extern msg_warn_missing_return, msg_warn_unused_var
extern msg_warn_dead_code, msg_warn_implicit_cast
extern msg_warn_dead_code, msg_warn_implicit_cast
extern msg_warn_empty_body, msg_warn_constant_cond
extern msg_assign_const
extern msg_undeclared
extern msg_no_field
extern WARN_UNINIT_VAR, WARN_UNINIT_PTR
extern WARN_MISSING_RETURN, WARN_UNUSED_VAR
extern WARN_DEAD_CODE, WARN_IMPLICIT_CAST
extern WARN_EMPTY_BODY, WARN_CONSTANT_COND
extern current_func_return_type
extern current_func_return_fields
extern mem_eq_str
extern STDERR
extern out_fd, out_flush, out_set_fd
extern error_count
extern source_path
extern prog_func_source_array
extern prog_global_source_array


; ------------------------------------------------------------
; Exported Functions
; ------------------------------------------------------------
global codegen_init, codegen_generate, codegen_cleanup, symbol_tables_init

; ------------------------------------------------------------
; AST Node Types (matching parser.asm)
; ------------------------------------------------------------
%define AST_PROGRAM     1
%define AST_FUNCTION    2
%define AST_BLOCK       3
%define AST_RETURN      4
%define AST_IF          5
%define AST_WHILE       6
%define AST_BINARY_OP   10
%define AST_UNARY_OP    11
%define AST_CALL        12
%define AST_VAR_DECL    13
%define AST_ASSIGN      14
%define AST_ARRAY_DECL  15
%define AST_INDEX       16
%define AST_STRUCT_DEF  17
%define AST_MEMBER      18
%define AST_INIT_LIST   19
%define AST_IDENT       20
%define AST_NUMBER      21
%define AST_STRING      22
%define AST_CHAR        23
%define AST_POST_INCR   24
%define AST_POST_DECR   25
%define AST_BREAK       30
%define AST_CONTINUE    31
%define AST_DESIGNATED_INIT 32
%define AST_LOGICAL_AND   33
%define AST_LOGICAL_OR    34
%define AST_FOR           35
%define AST_CAST          36

; Token types for operators inside AST
%define TOK_PLUS        10
%define TOK_MINUS       11
%define TOK_STAR        12
%define TOK_SLASH       13
%define TOK_PERCENT     14
%define TOK_LSHIFT      15
%define TOK_RSHIFT      16
%define TOK_EQ          20
%define TOK_EQEQ        21
%define TOK_NEQ         22
%define TOK_LT          23
%define TOK_LE          24
%define TOK_GT          25
%define TOK_GE          26
%define TOK_KW_INT      50
%define TOK_KW_CHAR     51
%define TOK_KW_VOID     56
%define TOK_KW_STRUCT   57
%define TOK_KW_FOR      59
%define TOK_AMPERSAND   44
%define TOK_DOT         45
%define TOK_PIPE        47
%define TOK_XOR         48
%define TOK_TILDE       49
%define TOK_AND         82
%define TOK_OR          83
%define TOK_INCR        80
%define TOK_DECR        81

; Pointer type encoding: PTR_TYPE_FLAG + base_token_type, plus one more
; PTR_TYPE_FLAG per extra pointer level (e.g. int* = 10050, int** = 20050).
; Must stay identical to the defines in parser.asm.
%define PTR_TYPE_FLAG   10000
; Array field encoding: ARRAY_TYPE_FLAG + element_type.
; Must sit above every reachable pointer encoding so `type >= ARRAY_TYPE_FLAG`
; only matches arrays. The old value (20000) collided with depth-2 pointers
; like `struct N**` = 20057, which crashed `struct_total_size`. See parser.asm.
%define ARRAY_TYPE_FLAG  268435456
; Const struct field flag: a distinct high bit OR'd into the field type.
%define FIELD_CONST_FLAG 536870912

; ------------------------------------------------------------
; AST node struct (5 qwords = 40 bytes)
; ------------------------------------------------------------
struc ast_node_t
    .type       resq 1
    .data1      resq 1
    .data2      resq 1
    .data3      resq 1
    .data4      resq 1
    .data5      resq 1
    .line       resq 1
    .column     resq 1
endstruc

; ------------------------------------------------------------
; Var flags (matching parser.asm)
; ------------------------------------------------------------
%define VAR_CONST       2
%define VLA_FLAG        1       ; AST_ARRAY_DECL data5: runtime-sized (VLA)

; ------------------------------------------------------------
; Symbol entry (8 qwords = 64 bytes)
; ------------------------------------------------------------
struc symbol_t
    .name_ptr   resq 1      ; 0
    .name_len   resq 1      ; 8
    .offset     resq 1      ; 16 (negative offset from rbp)
    .type       resq 1      ; 24 (token type or special encoding)
    .extra      resq 1      ; 32 (array count, struct type id, or 0)
    .line       resq 1      ; 40 (source line of declaration)
    .column     resq 1      ; 48 (source column of declaration)
    .fields     resq 1      ; 56 (pointee field_array_ptr for arrays of
                            ;      struct pointers; 0 otherwise). `extra`
                            ;      stays the element count for those, so
                            ;      bounds checks keep working AND chained
                            ;      `arr[i]->field` can resolve the pointee.
endstruc

SYMBOL_TABLE_INITIAL_CAPACITY equ 256
STRING_POOL_INITIAL_CAPACITY equ 512
STRING_POOL_GROW_FACTOR equ 2

; ------------------------------------------------------------
; Data
; ------------------------------------------------------------
section .data
    asm_section_text    db "section .text", 10, 0
    asm_global          db "global ", 0
    asm_label_sep       db ":", 10, 0
    asm_newline         db 10, 0
    asm_prologue        db "    push rbp", 10, "    mov rbp, rsp", 10, 0
    asm_sub_rsp         db "    sub rsp, ", 0
    ; Save the hidden struct return pointer (in rdi) to the reserved stack
    ; slot at [rbp - 8]. This is set up in gen_function by adding 8 bytes
    ; to frame_size BEFORE collect_symbols when the function returns a struct.
    ; Using a stack slot instead of a global makes struct returns reentrant
    ; (works correctly with recursion and nested calls).
    asm_mov_rbp_ret_ptr db "    mov qword [rbp - 8], rdi", 10, 0
    ; Push the struct return slot address (in BSS) onto the stack so it gets
    ; popped as the hidden first argument (rdi) by the pop-args sequence.
    asm_push_struct_ret db "    push struct_ret_slot", 10, 0
    ; Load struct result address into rax (after call)
    asm_mov_rax_struct_ret db "    mov rax, struct_ret_slot", 10, 0
    ; Struct copy call sequence
    asm_mov_rdi_g_prefix db "    mov rdi, g_", 0
    asm_lea_rdi_rbp    db "    lea rdi, [rbp - ", 0
    asm_rbp_close      db "]", 10, 0
    asm_mov_rsi_rax    db "    mov rsi, rax", 10, 0
    asm_mov_rdx_imm    db "    mov rdx, ", 0
    asm_call_struct_copy db "    call __struct_copy", 10, 0
    asm_mov_rdi_rbp_ret db "    mov rdi, [rbp - 8]", 10, 0
    asm_label_struct_ret_slot db "struct_ret_slot", 0
    asm_label_current_ret_ptr db "current_ret_ptr", 0
    asm_epilogue        db "    mov rsp, rbp", 10, "    pop rbp", 10, "    ret", 10, 0
    asm_start_entry     db "global _start", 10, "_start:", 10, "    pop rax", 10, "    mov [rel g_argc], rax", 10, "    mov [rel g_argv], rsp", 10, "    mov rdi, rax", 10, "    mov rsi, rsp", 10, "    push rax", 10, "    call main", 10, "    mov rdi, rax", 10, "    mov rax, 60", 10, "    syscall", 10, 0
    asm_start_result    db "global _start", 10, "_start:", 10, "    pop rax", 10, "    mov [rel g_argc], rax", 10, "    mov [rel g_argv], rsp", 10, "    mov rdi, rax", 10, "    mov rsi, rsp", 10, "    push rax", 10, "    call main", 10, "    mov r15, rax", 10, "    sub rsp, 32", 10, "    mov rbx, 10", 10, "    lea rsi, [rsp+8]", 10, "    mov r8, rsi", 10, "    mov rax, r15", 10, ".div_loop:", 10, "    xor rdx, rdx", 10, "    div rbx", 10, "    add dl, '0'", 10, "    dec rsi", 10, "    mov [rsi], dl", 10, "    test rax, rax", 10, "    jnz .div_loop", 10, "    mov rdx, r8", 10, "    sub rdx, rsi", 10, "    mov rdi, 1", 10, "    mov rax, 1", 10, "    syscall", 10, "    add rsp, 32", 10, "    mov rdi, r15", 10, "    mov rax, 60", 10, "    syscall", 10, 0
    asm_argv_save       db "    pop rax", 10, "    mov [rel g_argc], rax", 10, "    mov [rel g_argv], rsp", 10, "    mov rdi, rax", 10, "    mov rsi, rsp", 10, "    push rax", 10, 0
    asm_argc_name       db "argc", 0
    asm_argv_name       db "argv", 0


    ; --- Syscall runtime stubs (emitted into generated binaries) ---
    ; All follow System V AMD64 ABI: args in rdi, rsi, rdx; return in rax
    asm_sys_read        db "global syscall_read", 10
                        db "syscall_read:", 10
                        db "    mov rax, 0", 10
                        db "    syscall", 10
                        db "    ret", 10, 0
    asm_sys_write       db "global syscall_write", 10
                        db "syscall_write:", 10
                        db "    mov rax, 1", 10
                        db "    syscall", 10
                        db "    ret", 10, 0
    asm_sys_open        db "global syscall_open", 10
                        db "syscall_open:", 10
                        db "    mov rax, 2", 10
                        db "    syscall", 10
                        db "    ret", 10, 0
    asm_sys_close       db "global syscall_close", 10
                        db "syscall_close:", 10
                        db "    mov rax, 3", 10
                        db "    syscall", 10
                        db "    ret", 10, 0
    asm_sys_dup2        db "global syscall_dup2", 10
                        db "syscall_dup2:", 10
                        db "    mov rax, 33", 10
                        db "    syscall", 10
                        db "    ret", 10, 0
    asm_sys_exit        db "global syscall_exit", 10
                        db "syscall_exit:", 10
                        db "    mov rax, 60", 10
                        db "    syscall", 10, 0

    ; --- Extended syscall runtime stubs (emitted into generated binaries) ---
    ; These let c2x-proto (and other generated compilers) fork/exec nasm+ld to
    ; produce binaries. Note the raw-syscall ABI: 4th arg in r10 (not rcx), and
    ; the `syscall` instruction clobbers rcx and r11.
    ; sys_fork() -> pid_t (rax = 0 in child, child PID in parent, negative on error)
    asm_sys_fork        db "global syscall_fork", 10
                        db "syscall_fork:", 10
                        db "    mov rax, 57", 10
                        db "    syscall", 10
                        db "    ret", 10, 0
    ; sys_execve(pathname, argv, envp) -> int (only returns on error)
    asm_sys_execve      db "global syscall_execve", 10
                        db "syscall_execve:", 10
                        db "    mov rax, 59", 10
                        db "    syscall", 10
                        db "    ret", 10, 0
    ; sys_wait4(pid, wstatus, options, rusage) -> pid_t
    ; NOTE: 4th arg (rusage) passed in r10 per Linux syscall ABI.
    asm_sys_wait4       db "global syscall_wait4", 10
                        db "syscall_wait4:", 10
                        db "    mov rax, 61", 10
                        db "    syscall", 10
                        db "    ret", 10, 0
    ; sys_unlink(pathname) -> int
    asm_sys_unlink      db "global syscall_unlink", 10
                        db "syscall_unlink:", 10
                        db "    mov rax, 87", 10
                        db "    syscall", 10
                        db "    ret", 10, 0
    ; sys_getpid() -> pid_t
    asm_sys_getpid      db "global syscall_getpid", 10
                        db "syscall_getpid:", 10
                        db "    mov rax, 39", 10
                        db "    syscall", 10
                        db "    ret", 10, 0
    ; sys_getdents64(fd, buf, count) -> int (bytes read, or negative on error)
    ; 3 args in rdi/rsi/rdx (same in both C and syscall ABIs).
    asm_sys_getdents64  db "global syscall_getdents64", 10
                        db "syscall_getdents64:", 10
                        db "    mov rax, 217", 10
                        db "    syscall", 10
                        db "    ret", 10, 0
    ; sys_clock_gettime(clk_id, timespec) -> int (0 on success)
    ; 2 args in rdi/rsi (same in both C and syscall ABIs).
    asm_sys_clock_gettime db "global syscall_clock_gettime", 10
                        db "syscall_clock_gettime:", 10
                        db "    mov rax, 228", 10
                        db "    syscall", 10
                        db "    ret", 10, 0
    ; sys_mkdir(pathname, mode) -> int (0 on success)
    ; 2 args in rdi/rsi (same in both C and syscall ABIs).
    asm_sys_mkdir       db "global syscall_mkdir", 10
                        db "syscall_mkdir:", 10
                        db "    mov rax, 83", 10
                        db "    syscall", 10
                        db "    ret", 10, 0
    ; sys_nanosleep(req, rem) -> int (0 on success). Used by the build-UI
    ; spinner child to pause between animation frames.
    ; 2 args in rdi/rsi (same in both C and syscall ABIs).
    asm_sys_nanosleep   db "global syscall_nanosleep", 10
                        db "syscall_nanosleep:", 10
                        db "    mov rax, 35", 10
                        db "    syscall", 10
                        db "    ret", 10, 0
    ; sys_kill(pid, sig) -> int (0 on success). Used to stop the spinner child.
    ; 2 args in rdi/rsi (same in both C and syscall ABIs).
    asm_sys_kill        db "global syscall_kill", 10
                        db "syscall_kill:", 10
                        db "    mov rax, 62", 10
                        db "    syscall", 10
                        db "    ret", 10, 0
    ; sys_ioctl(fd, request, arg) -> int. Used by isatty() to gate the spinner
    ; on an interactive terminal. 3 args in rdi/rsi/rdx (same in both ABIs).
    asm_sys_ioctl       db "global syscall_ioctl", 10
                        db "syscall_ioctl:", 10
                        db "    mov rax, 16", 10
                        db "    syscall", 10
                        db "    ret", 10, 0

    ; Struct copy helper: __struct_copy(rdi=dest, rsi=src, rdx=size)
    ; Copies `size` bytes from src to dest. Used for struct assignments
    ; and struct returns (System V AMD64 ABI for aggregate copies).
    asm_struct_copy     db "global __struct_copy", 10
                        db "__struct_copy:", 10
                        db "    push rbp", 10
                        db "    mov rbp, rsp", 10
                        db "    push rcx", 10
                        db "    xor rcx, rcx", 10
                        db ".sc_loop:", 10
                        db "    cmp rcx, rdx", 10
                        db "    jge .sc_done", 10
                        db "    mov al, [rsi + rcx]", 10
                        db "    mov [rdi + rcx], al", 10
                        db "    inc rcx", 10
                        db "    jmp .sc_loop", 10
                        db ".sc_done:", 10
                        db "    pop rcx", 10
                        db "    mov rsp, rbp", 10
                        db "    pop rbp", 10
                        db "    ret", 10, 0

    ; Load / store patterns
    asm_mov_rax_imm     db "    mov rax, ", 0
    asm_push_rax        db "    push rax", 10, 0
    asm_pop_rbx         db "    pop rbx", 10, 0

    asm_mov_qword_rbp   db "    mov qword [rbp-", 0
    asm_mov_byte_rbp    db "    mov byte [rbp-", 0
    asm_rbp_rax         db "], rax", 10, 0
    asm_rbp_al          db "], al", 10, 0
    asm_load_qword_rbp  db "    mov rax, [rbp-", 0
    asm_load_byte_rbp   db "    movsx rax, byte [rbp-", 0
    asm_close_bracket   db "]", 10, 0

    ; Arithmetic
    asm_add_rax_rbx     db "    add rax, rbx", 10, 0
    asm_sub_rbx_rax     db "    sub rbx, rax", 10, "    mov rax, rbx", 10, 0
    asm_imul_rax_rbx    db "    imul rax, rbx", 10, 0
    asm_div_setup       db "    xchg rax, rbx", 10, "    xor rdx, rdx", 10, "    div rbx", 10, 0
    asm_mod_result      db "    mov rax, rdx", 10, 0
    asm_neg_rax         db "    neg rax", 10, 0
    asm_not_rax         db "    not rax", 10, 0
    asm_mov_rax_from_rax db "    mov rax, [rax]", 10, 0
    asm_lea_rax_rbp     db "    lea rax, [rbp-", 0
    asm_mov_rbx_rax     db "    mov [rbx], rax", 10, 0
    asm_mov_rbx_al      db "    mov [rbx], al", 10, 0
    asm_shl_rax_3       db "    shl rax, 3", 10, 0
    asm_mov_rbx_imm     db "    mov rbx, ", 0
    asm_imul_rax_imm     db "    imul rax, ", 0
    asm_semi_comment     db "; ", 0
    asm_inline_asm_marker db "inline asm:", 0
    asm_rbp_prefix db "[rbp-", 0

    ; Pointer arithmetic
    asm_imul_rax_8      db "    imul rax, 8", 10, 0
    asm_imul_rbx_8      db "    imul rbx, 8", 10, 0
    asm_sar_rax_3       db "    sar rax, 3", 10, 0
    asm_movsx_byte_rax  db "    movsx rax, byte [rax]", 10, 0
    asm_movsx_byte_rbx  db "    movsx rax, byte [rbx]", 10, 0
    asm_inc_rax         db "    inc rax", 10, 0
    asm_dec_rax         db "    dec rax", 10, 0
    asm_mov_rax_rbx     db "    mov rax, rbx", 10, 0

    ; VLA runtime stack allocation
    asm_add_rax_15      db "    add rax, 15", 10, 0
    asm_and_rax_neg16   db "    and rax, -16", 10, 0
    asm_sub_rsp_rax     db "    sub rsp, rax", 10, 0
    asm_mov_qword_rbp_rsp db "    mov qword [rbp-", 0
    asm_rbp_rsp         db "], rsp", 10, 0
    ; VLA index helpers
    asm_mov_r9_rbp      db "    mov r9, qword [rbp-", 0
    asm_cmp_rax_r9      db "    cmp rax, r9", 10, 0
    asm_add_rbx_rax     db "    add rbx, rax", 10, 0
    asm_mov_rax_rbx_indirect db "    mov rax, [rbx]", 10, 0

    ; Bitwise operators
    asm_shl_rax_cl      db "    mov rcx, rax", 10, "    mov rax, rbx", 10, "    shl rax, cl", 10, 0
    asm_sar_rax_cl      db "    mov rcx, rax", 10, "    mov rax, rbx", 10, "    sar rax, cl", 10, 0
    asm_and_rax_rbx     db "    and rax, rbx", 10, 0
    asm_or_rax_rbx      db "    or rax, rbx", 10, 0
    asm_xor_rax_rbx     db "    xor rax, rbx", 10, 0

    ; Comparisons
    asm_cmp_rbx_rax     db "    cmp rbx, rax", 10, 0
    asm_cmp_rax_0       db "    cmp rax, 0", 10, 0
    asm_sete            db "    sete al", 10, "    movzx rax, al", 10, 0
    asm_setne           db "    setne al", 10, "    movzx rax, al", 10, 0
    asm_setl            db "    setl al", 10, "    movzx rax, al", 10, 0
    asm_setle           db "    setle al", 10, "    movzx rax, al", 10, 0
    asm_setg            db "    setg al", 10, "    movzx rax, al", 10, 0
    asm_setge           db "    setge al", 10, "    movzx rax, al", 10, 0
    asm_movsx_rax_al    db "    movsx rax, al", 10, 0

    ; Branching labels
    asm_je_else         db "    je .L_else_", 0
    asm_jmp_end         db "    jmp .L_end_", 0
    asm_label_else      db ".L_else_", 0
    asm_label_end       db ".L_end_", 0
    asm_label_start     db ".L_start_", 0
    asm_jmp_start       db "    jmp .L_start_", 0
    asm_je_end          db "    je .L_end_", 0

    asm_jmp_continue    db "    jmp .L_cont_", 0
    asm_label_continue  db ".L_cont_", 0
    asm_jmp_func_end    db "    jmp .L_func_end_", 0
    asm_label_func_end  db ".L_func_end_", 0

    ; Bounds check runtime labels and instructions
    asm_jl_bounds_fail  db "    jl .L_bounds_fail_", 0
    asm_jge_bounds_fail db "    jge .L_bounds_fail_", 0
    asm_jle_bounds_fail db "    jle .L_bounds_fail_", 0
    asm_jae_bounds_fail db "    jae .L_bounds_fail_", 0
    asm_jmp_bounds_ok   db "    jmp .L_bounds_ok_", 0
    asm_label_bounds_fail db ".L_bounds_fail_", 0
    asm_label_bounds_ok db ".L_bounds_ok_", 0
    ; Short-circuit logical operator labels
    asm_je_land_false    db "    je .L_land_false_", 0
    asm_jmp_land_done    db "    jmp .L_land_done_", 0
    asm_label_land_false db ".L_land_false_", 0
    asm_label_land_done  db ".L_land_done_", 0
    asm_jne_lor_true     db "    jne .L_lor_true_", 0
    asm_jmp_lor_done     db "    jmp .L_lor_done_", 0
    asm_label_lor_true   db ".L_lor_true_", 0
    asm_label_lor_done   db ".L_lor_done_", 0
    asm_mov_rax_1        db "    mov rax, 1", 10, 0
    asm_xor_rax_rax      db "    xor rax, rax", 10, 0

    asm_mov_rdi_1       db "    mov rdi, 1", 10, 0
    asm_mov_rax_60      db "    mov rax, 60", 10, 0
    asm_syscall         db "    syscall", 10, 0
    asm_cmp_rax_imm   db "    cmp rax, ", 0

    asm_call            db "    call ", 0
    asm_call_print_rax  db "    call __print_rax", 10, 0

    ; Global variable assembly patterns
    asm_section_data    db "section .data", 10, 0
    asm_section_bss     db "section .bss", 10, 0
    asm_dq_dir          db "    dq ", 0
    asm_db_dir          db "    db ", 0
    asm_resq            db "    resq ", 0
    asm_resb            db "    resb ", 0
    asm_label_g_prefix  db "g_", 0
    asm_mov_rax_g       db "    mov rax, [rel g_", 0
    asm_movsx_rax_byte_g db "    movsx rax, byte [rel g_", 0
    asm_lea_rax_g       db "    lea rax, [rel g_", 0
    asm_store_g_prefix  db "    mov [rel g_", 0
    asm_store_g_rax_sfx db "], rax", 10, 0
    asm_store_g_al_sfx  db "], al", 10, 0
    asm_extern          db "extern g_", 0
    asm_print_rax_helper db "__print_rax:", 10
        db "    push rbx", 10
        db "    push rcx", 10
        db "    push rdx", 10
        db "    push rsi", 10
        db "    push rdi", 10
        db "    push r8", 10
        db "    push r15", 10
        db "    mov r15, rax", 10
        db "    sub rsp, 32", 10
        db "    mov rbx, 10", 10
        db "    lea rsi, [rsp+8]", 10
        db "    mov r8, rsi", 10
        db ".div_loop:", 10
        db "    xor rdx, rdx", 10
        db "    div rbx", 10
        db "    add dl, '0'", 10
        db "    dec rsi", 10
        db "    mov [rsi], dl", 10
        db "    test rax, rax", 10
        db "    jnz .div_loop", 10
        db "    mov rdx, r8", 10
        db "    sub rdx, rsi", 10
        db "    mov byte [r8], 10", 10
        db "    inc rdx", 10
        db "    mov rdi, 1", 10
        db "    mov rax, 1", 10
        db "    syscall", 10
        db "    add rsp, 32", 10
        db "    mov rax, r15", 10
        db "    pop r15", 10
        db "    pop r8", 10
        db "    pop rdi", 10
        db "    pop rsi", 10
        db "    pop rdx", 10
        db "    pop rcx", 10
        db "    pop rbx", 10
        db "    ret", 10, 0

    ; Function parameter / argument patterns
    asm_pop_rdi         db "    pop rdi", 10, 0
    asm_pop_rsi         db "    pop rsi", 10, 0
    asm_pop_rdx         db "    pop rdx", 10, 0
    asm_pop_rcx         db "    pop rcx", 10, 0
    asm_pop_r8          db "    pop r8", 10, 0
    asm_pop_r9          db "    pop r9", 10, 0
    asm_add_rsp         db "    add rsp, ", 0
    asm_mov_rax_rbp_plus db "    mov rax, [rbp+", 0
    asm_rbp_rdi         db "], rdi", 10, 0
    asm_rbp_rsi         db "], rsi", 10, 0
    asm_rbp_rdx         db "], rdx", 10, 0
    asm_rbp_rcx         db "], rcx", 10, 0
    asm_rbp_r8          db "], r8", 10, 0
    asm_rbp_r9          db "], r9", 10, 0
    asm_rbp_dil         db "], dil", 10, 0
    asm_rbp_sil         db "], sil", 10, 0
    asm_rbp_dl          db "], dl", 10, 0
    asm_rbp_cl          db "], cl", 10, 0
    asm_rbp_r8b         db "], r8b", 10, 0
    asm_rbp_r9b         db "], r9b", 10, 0

    ; Register suffix tables for parameter copy (index by param reg 0-5)
    param_reg_suffixes:
        dq asm_rbp_rdi, asm_rbp_rsi, asm_rbp_rdx, asm_rbp_rcx, asm_rbp_r8, asm_rbp_r9
    param_reg_byte_suffixes:
        dq asm_rbp_dil, asm_rbp_sil, asm_rbp_dl, asm_rbp_cl, asm_rbp_r8b, asm_rbp_r9b

    ; Member access helper
    asm_add_rax_imm     db "    add rax, ", 0
    asm_add_rdi_imm     db "    add rdi, ", 0
    asm_mov_rdi_rax     db "    mov [rdi], rax", 10, 0
    asm_mov_rdi_al      db "    mov [rdi], al", 10, 0
    asm_mov_rdi_rbx     db "    mov rdi, rbx", 10, 0

    ; String literal patterns
    asm_section_rodata  db "section .rodata", 10, 0
    asm_lea_rax_rel_lc  db "    lea rax, [rel LC", 0
    asm_label_lc        db "LC", 0
    loop_start_label    dq 0       ; innermost loop's start label (condition check)
    loop_continue_label dq 0       ; innermost loop's continue target label
    loop_end_label      dq 0       ; innermost loop's end label (for break)

; ------------------------------------------------------------
; BSS
; ------------------------------------------------------------
section .bss
    label_counter   resq 1
    symbol_count    resq 1
    symbol_capacity resq 1
    symbols_ptr     resq 1
    symbol_initialized_ptr resq 1
    symbol_used_ptr resq 1
    symbol_const_ptr resq 1
    frame_size      resq 1
    gen_expr_type       resq 1
    gen_expr_struct_fields resq 1
    gen_expr_array_count resq 1
    gen_index_2d_dim2   resq 1          ; 2D array: dim2 (0 = 1D, nonzero = 2D second dim)
    find_field_is_const resq 1          ; set by find_field: 1 if the found field was declared const
    pending_symbol_fields resq 1        ; set by the caller of add_symbol /
                                        ; add_global_symbol: the pointee
                                        ; field_array_ptr for arrays of struct
                                        ; pointers (0 otherwise). Consumed and
                                        ; cleared by the add_* helpers.
    found_symbol_fields resq 1          ; set by find_symbol / find_global_symbol
                                        ; on a hit: the symbol's `.fields`
                                        ; slot, so index handlers can chain
                                        ; `arr[i]->field` without a second
                                        ; lookup.
    gen_index_elem_fields resq 1        ; pointee field array of the element
                                        ; being indexed (captured from
                                        ; found_symbol_fields by the ident
                                        ; fast paths; 0 for member/expression
                                        ; bases, which resolve fields through
                                        ; gen_expr_struct_fields instead).
    symbols_storage:        resb SYMBOL_TABLE_INITIAL_CAPACITY * symbol_t_size
    symbol_initialized_storage: resb SYMBOL_TABLE_INITIAL_CAPACITY  ; 1 byte per symbol: 0=uninit, 1=initialized
    symbol_used_storage:        resb SYMBOL_TABLE_INITIAL_CAPACITY  ; 1 byte per symbol: 0=unused, 1=used (read or written)
    symbol_const_storage:       resb SYMBOL_TABLE_INITIAL_CAPACITY  ; 1 byte per symbol: 0=mutable, 1=const

    global_symbol_count resq 1
    global_symbol_capacity resq 1
    global_symbols_ptr  resq 1
    global_symbol_initialized_ptr resq 1
    global_symbol_const_ptr resq 1
    global_symbols_storage:     resb SYMBOL_TABLE_INITIAL_CAPACITY * symbol_t_size
    global_symbol_initialized_storage: resb SYMBOL_TABLE_INITIAL_CAPACITY  ; for global symbols
    global_symbol_const_storage:       resb SYMBOL_TABLE_INITIAL_CAPACITY  ; for global symbols: 0=mutable, 1=const

    global_label_counter resq 1
    function_end_label  resq 1

    ; Slot for the struct return value address (BSS buffer).
    ; When a function returns a struct, the caller pushes the address of
    ; this slot as the hidden first argument. After the call returns, the
    ; struct result is here. The caller then copies it to the destination.
    ; NOTE: This is NOT reentrant for nested struct-returning calls, but
    ; the callee side is reentrant (uses [rbp-8] instead of a global).
    global struct_ret_slot
    struct_ret_slot resb 256

    ; Function return type registry — used for struct-returning function calls.
    ; Starts on a small static buffer and grows on demand like the symbol tables.
    ; Note: func_registry_count is defined in parser.asm (shared).
    FUNC_RETURN_REGISTRY_INITIAL_CAPACITY equ 64
    extern func_registry_count
    func_return_registry_capacity resq 1
    func_registry_names_ptr   resq 1
    func_registry_types_ptr   resq 1
    func_registry_fields_ptr  resq 1
    func_registry_names_storage   resb FUNC_RETURN_REGISTRY_INITIAL_CAPACITY * 8
    func_registry_types_storage   resb FUNC_RETURN_REGISTRY_INITIAL_CAPACITY * 8
    func_registry_fields_storage  resb FUNC_RETURN_REGISTRY_INITIAL_CAPACITY * 8

    string_count        resq 1
    string_pool_ptr    resq 1          ; pointer to dynamically-allocated pool (16 bytes per entry)
    string_pool_capacity resq 1         ; current capacity in entries
    function_has_return resq 1          ; 1 if current function emitted any return
    last_stmt_terminator resq 1         ; 1 if last stmt was return/break/continue (for dead-code detection)
    current_ast_node    resq 1          ; AST node pointer for current add_symbol call (line/col tracking)
    dbg_loop_count      resq 1

default rel

section .text

; ================================================================
; Macro: PROLOGUE regs... - push callee-saved registers in order
; ================================================================
%macro PROLOGUE 1-*
    %rep %0
        push %1
        %rotate 1
    %endrep
%endmacro

; ================================================================
; Macro: EPILOGUE regs... - pop in reverse order, then ret
; ================================================================
%macro EPILOGUE 1-*
    %rep %0
        %rotate -1
        pop %1
    %endrep
    ret
%endmacro

; ================================================================
; symbol_tables_init
; Initializes the local and global symbol table pointers/capacities.
; This keeps the first few hundred symbols in static storage and allows
; the tables to grow into heap-backed buffers when needed.
; ================================================================
symbol_tables_init:
    lea rax, [symbols_storage]
    mov [symbols_ptr], rax
    lea rax, [symbol_initialized_storage]
    mov [symbol_initialized_ptr], rax
    lea rax, [symbol_used_storage]
    mov [symbol_used_ptr], rax
    lea rax, [symbol_const_storage]
    mov [symbol_const_ptr], rax
    mov qword [symbol_capacity], SYMBOL_TABLE_INITIAL_CAPACITY

    lea rax, [global_symbols_storage]
    mov [global_symbols_ptr], rax
    lea rax, [global_symbol_initialized_storage]
    mov [global_symbol_initialized_ptr], rax
    lea rax, [global_symbol_const_storage]
    mov [global_symbol_const_ptr], rax
    mov qword [global_symbol_capacity], SYMBOL_TABLE_INITIAL_CAPACITY
    ret

; ================================================================
; ensure_symbol_capacity
; Grows the local symbol table if symbol_count has reached capacity.
; ================================================================
ensure_symbol_capacity:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rax, [symbol_count]
    mov rbx, [symbol_capacity]
    cmp rax, rbx
    jb .done

    mov r12, rbx                        ; old capacity
    mov r13, rbx                        ; new capacity
    shl r13, 1

    mov rdi, r13
    imul rdi, symbol_t_size
    call heap_alloc_zero
    test rax, rax
    jz .done
    mov r14, rax                        ; new symbol entries

    mov rdi, r13
    call heap_alloc_zero
    test rax, rax
    jz .done
    mov r15, rax                        ; new initialized bytes

    mov rdi, r13
    call heap_alloc_zero
    test rax, rax
    jz .done
    mov r11, rax                        ; new used bytes

    mov rdi, r13
    call heap_alloc_zero
    test rax, rax
    jz .done
    mov r10, rax                        ; new const bytes

    mov rdi, r14
    mov rsi, [symbols_ptr]
    mov rdx, r12
    imul rdx, symbol_t_size
    call mem_copy

    mov rdi, r15
    mov rsi, [symbol_initialized_ptr]
    mov rdx, r12
    call mem_copy

    mov rdi, r11
    mov rsi, [symbol_used_ptr]
    mov rdx, r12
    call mem_copy

    mov rdi, r10
    mov rsi, [symbol_const_ptr]
    mov rdx, r12
    call mem_copy

    mov [symbols_ptr], r14
    mov [symbol_initialized_ptr], r15
    mov [symbol_used_ptr], r11
    mov [symbol_const_ptr], r10
    mov [symbol_capacity], r13

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ================================================================
; ensure_global_symbol_capacity
; Grows the global symbol table if global_symbol_count has reached capacity.
; ================================================================
ensure_global_symbol_capacity:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rax, [global_symbol_count]
    mov rbx, [global_symbol_capacity]
    cmp rax, rbx
    jb .done

    mov r12, rbx
    mov r13, rbx
    shl r13, 1

    mov rdi, r13
    imul rdi, symbol_t_size
    call heap_alloc_zero
    test rax, rax
    jz .done
    mov r14, rax                        ; new entries

    mov rdi, r13
    call heap_alloc_zero
    test rax, rax
    jz .done
    mov r15, rax                        ; new initialized bytes

    mov rdi, r13
    call heap_alloc_zero
    test rax, rax
    jz .done
    mov r11, rax                        ; new const bytes

    mov rdi, r14
    mov rsi, [global_symbols_ptr]
    mov rdx, r12
    imul rdx, symbol_t_size
    call mem_copy

    mov rdi, r15
    mov rsi, [global_symbol_initialized_ptr]
    mov rdx, r12
    call mem_copy

    mov rdi, r11
    mov rsi, [global_symbol_const_ptr]
    mov rdx, r12
    call mem_copy

    mov [global_symbols_ptr], r14
    mov [global_symbol_initialized_ptr], r15
    mov [global_symbol_const_ptr], r11
    mov [global_symbol_capacity], r13

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ================================================================
; ensure_func_return_registry_capacity
; Grows the codegen function-return registry when full.
; ================================================================
ensure_func_return_registry_capacity:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rax, [func_registry_count]
    mov rbx, [func_return_registry_capacity]
    cmp rax, rbx
    jb .done

    mov r12, rbx
    mov r13, rbx
    shl r13, 1

    mov rdi, r13
    shl rdi, 3
    call heap_alloc_zero
    test rax, rax
    jz .done
    mov r14, rax

    mov rdi, r13
    shl rdi, 3
    call heap_alloc_zero
    test rax, rax
    jz .done
    mov r15, rax

    mov rdi, r13
    shl rdi, 3
    call heap_alloc_zero
    test rax, rax
    jz .done
    mov r11, rax

    mov rdi, r14
    mov rsi, [func_registry_names_ptr]
    mov rdx, r12
    shl rdx, 3
    call mem_copy

    mov rdi, r15
    mov rsi, [func_registry_types_ptr]
    mov rdx, r12
    shl rdx, 3
    call mem_copy

    mov rdi, r11
    mov rsi, [func_registry_fields_ptr]
    mov rdx, r12
    shl rdx, 3
    call mem_copy

    mov [func_registry_names_ptr], r14
    mov [func_registry_types_ptr], r15
    mov [func_registry_fields_ptr], r11
    mov [func_return_registry_capacity], r13

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ================================================================
; register_globals(rdi = global_count, rsi = global_array)
; Walks global var array and registers each in global_symbols
; ================================================================
register_globals:
    PROLOGUE r15, r14, r13, r12, rbx

    mov r14, rdi                 ; r14 = count
    mov r15, rsi                 ; r15 = array

    test r14, r14
    jz .done

    xor r12, r12                 ; index
.loop:
    cmp r12, r14
    jge .done

    mov rax, [prog_global_source_array]
    test rax, rax
    jz .global_source_ready
    mov rdx, [rax + 8 + r12 * 8]
    mov [source_path], rdx
.global_source_ready:

    mov r13, [r15 + 8 + r12 * 8] ; r13 = AST node
    test r13, r13
    jz .next

    mov rax, [r13 + ast_node_t.type]

    cmp rax, AST_VAR_DECL
    je .var
    cmp rax, AST_ARRAY_DECL
    je .array
    cmp rax, AST_STRUCT_DEF
    je .struct_def
    jmp .next

.var:
    ; name from data2
    mov rdi, [r13 + ast_node_t.data2]  ; name_ptr
    test rdi, rdi
    jz .next
    push rdi
    mov rsi, rdi
    call bounded_strlen_256
    mov rsi, rax                       ; name_len
    pop rdi
    mov rcx, [r13 + ast_node_t.data1]  ; type
    xor r8, r8                         ; extra = 0
    ; Check if struct pointer: set extra = field_array_ptr from data4.
    ; Use the depth-agnostic helper so `struct T**` (and deeper) globals
    ; carry the pointee field array too, matching collect_symbols.
    cmp rcx, PTR_TYPE_FLAG
    jb .rv_not_struct_ptr
    push rax
    push rdi
    mov rdi, rcx
    call type_base_is_struct
    pop rdi
    pop rax
    test rax, rax
    jz .rv_not_struct_ptr
    mov rax, [r13 + ast_node_t.data4]
    test rax, rax
    jz .rv_not_struct_ptr
    mov r8, rax
.rv_not_struct_ptr:
    mov rax, [global_symbol_count]    ; save index for new global symbol
    push rax
    call add_global_symbol
    pop rax                           ; rax = index of new global symbol
    mov rbx, [global_symbol_const_ptr] ; rbx = const-bytes base (preserve r15=array)
    ; Check const flag from AST node data4
    mov rcx, [r13 + ast_node_t.data4]
    test rcx, VAR_CONST
    jz .rv_not_const
    mov byte [rbx + rax], 1
    jmp .rv_const_done
.rv_not_const:
    mov byte [rbx + rax], 0
.rv_const_done:
    jmp .next

.array:
    mov rdi, [r13 + ast_node_t.data2]  ; name_ptr
    test rdi, rdi
    jz .next
    push rdi
    mov rsi, rdi
    call bounded_strlen_256
    mov rsi, rax                       ; name_len
    pop rdi
    mov rcx, [r13 + ast_node_t.data1]  ; type or struct total_size
    mov r8, [r13 + ast_node_t.data3]   ; element count
    ; Check if extern (data4 = 1)
    cmp qword [r13 + ast_node_t.data4], 1
    je .array_register   ; extern: register with type and element count as-is
    ; Check for pointer-type array (e.g., struct Name* arr[N] or char** arr[N])
    cmp rcx, PTR_TYPE_FLAG
    jae .array_ptr
    ; Check if struct array by type (data1 is not a standard type token)
    cmp rcx, TOK_KW_INT
    je .array_not_struct
    cmp rcx, TOK_KW_CHAR
    je .array_not_struct
    ; Struct array: set type=TOK_KW_STRUCT, extra = field_array_ptr (data4)
    mov r8, [r13 + ast_node_t.data4]   ; field_array_ptr as extra
    mov rcx, TOK_KW_STRUCT
    jmp .array_register
.array_ptr:
    ; Pointer-type array: each element is 8 bytes (pointer size).
    ; Register as TOK_KW_INT so that indexing uses pointer-size scaling.
    ; Keep r8 = element count (from data3) for bounds checking.
    mov rcx, TOK_KW_INT
    ; Keep the pointee's field array in the symbol's `.fields` slot so
    ; `arr[i]->field` can resolve the pointee's members (extra stays the
    ; element count, so bounds checks keep working). data4 holds it for
    ; struct-pointer arrays; 0 for char**/int**-style arrays.
    push rax
    mov rax, [r13 + ast_node_t.data4]
    mov [pending_symbol_fields], rax
    pop rax
    jmp .array_register
.array_not_struct:
    ; rcx and r8 already set from data1 and data3
.array_register:
    ; --- 2D array support: pack dim2 into extra for non-struct arrays ---
    ; data5 encoding: (dim2 << 2) | const_flag_bits
    ; Only pack for non-struct arrays (struct arrays use extra for field_array_ptr).
    ; Skip if extern (data4 = 1) — extern arrays don't store dim2.
    cmp qword [r13 + ast_node_t.data4], 1
    je .array_reg_dim2_done           ; extern: skip packing
    cmp rcx, TOK_KW_STRUCT
    je .array_reg_dim2_done           ; struct array: extra = field_array_ptr, don't pack
    ; Extract dim2 from data5
    mov rax, [r13 + ast_node_t.data5]
    shr rax, 2                       ; rax = dim2 (0 for 1D)
    test rax, rax
    jz .array_reg_dim2_done          ; 1D: no packing needed
    ; 2D: compute dim1 = total_count / dim2, pack extra = dim1 | (dim2 << 32)
    push rdx                         ; save (div clobbers rdx)
    push rax                         ; save dim2
    mov rax, r8                      ; rax = total_count
    xor rdx, rdx
    div qword [rsp]                  ; rax = dim1 = total_count / dim2
    mov r8, rax                      ; r8 = dim1 (low 32 bits)
    pop rax                          ; rax = dim2
    shl rax, 32                      ; rax = dim2 << 32
    or r8, rax                       ; r8 = dim1 | (dim2 << 32)
    pop rdx                          ; restore
.array_reg_dim2_done:
    ; --- end 2D array support ---

    mov rax, [global_symbol_count]    ; save index for new global symbol
    push rax
    call add_global_symbol
    pop rax                           ; rax = index of new global symbol
    mov rbx, [global_symbol_const_ptr] ; rbx = const-bytes base (preserve r15=array)
    ; Check const flag from AST node data5
    mov rcx, [r13 + ast_node_t.data5]
    test rcx, VAR_CONST
    jz .array_reg_not_const
    mov byte [rbx + rax], 1
    jmp .array_reg_const_done
.array_reg_not_const:
    mov byte [rbx + rax], 0
.array_reg_const_done:
    jmp .next

.struct_def:
    mov rdi, [r13 + ast_node_t.data3]  ; var name
    test rdi, rdi
    jz .next
    push rdi
    mov rsi, rdi
    call bounded_strlen_256
    mov rsi, rax
    pop rdi
    mov rcx, TOK_KW_STRUCT
    mov r8, [r13 + ast_node_t.data2]   ; field_array_ptr
    mov rax, [global_symbol_count]    ; save index for new global symbol
    push rax
    call add_global_symbol
    pop rax                           ; rax = index of new global symbol
    mov rbx, [global_symbol_const_ptr] ; rbx = const-bytes base (preserve r15=array)
    ; Check const flag from AST node data5
    mov rcx, [r13 + ast_node_t.data5]
    test rcx, VAR_CONST
    jz .struct_def_not_const
    mov byte [rbx + rax], 1
    jmp .struct_def_const_done
.struct_def_not_const:
    mov byte [rbx + rax], 0
.struct_def_const_done:
    jmp .next

.next:
    inc r12
    jmp .loop

.done:
    EPILOGUE r15, r14, r13, r12, rbx

; ================================================================
; get_ptr_scale(rdi = type) -> rax = element size (0 if not a pointer)
; For pointer types, returns the element size (1 for char*, 8 for others).
; For non-pointer types, returns 0.
; ================================================================
get_ptr_scale:
    xor rax, rax
    cmp rdi, PTR_TYPE_FLAG
    jb .done                             ; below PTR_TYPE_FLAG → not a pointer
    sub rdi, PTR_TYPE_FLAG
    cmp rdi, TOK_KW_CHAR
    mov rax, 1
    je .done                             ; rax = 1 for char*
    mov rax, 8
.done:
    ret

; type_is_struct_or_ptr(rdi = type) -> rax = 1 if the type is a struct by
; value OR a pointer to a struct at any depth. Used where an indexed element
; may be either (e.g. `struct T arr[i]` and `struct T* p[i]` both need the
; pointee/element field array in gen_expr_struct_fields).
; ================================================================
type_is_struct_or_ptr:
    cmp rdi, TOK_KW_STRUCT
    je .tsp_yes
    jmp type_base_is_struct             ; tail call: returns rax = 0/1
.tsp_yes:
    mov rax, 1
    ret

; ================================================================
; strip_g_prefix(rsi = name_ptr)
; If the string starts with "g_", advance rsi past the prefix.
; Used to prevent g_g_argc double-prefix when user writes
; extern int g_argc; or int g_val; (with explicit g_ prefix).
; ================================================================
strip_g_prefix:
    cmp byte [rsi], 'g'
    jne .sgp_done
    cmp byte [rsi + 1], '_'
    jne .sgp_done
    add rsi, 2
.sgp_done:
    ret

; ================================================================
; codegen_init()
; ================================================================
codegen_init:
    xor rax, rax
    mov [label_counter], rax
    mov [symbol_count], rax
    mov [frame_size], rax
    mov [string_count], rax
    lea rax, [func_registry_names_storage]
    mov [func_registry_names_ptr], rax
    lea rax, [func_registry_types_storage]
    mov [func_registry_types_ptr], rax
    lea rax, [func_registry_fields_storage]
    mov [func_registry_fields_ptr], rax
    mov qword [func_return_registry_capacity], FUNC_RETURN_REGISTRY_INITIAL_CAPACITY
    call string_pool_init
    ret

; ================================================================
; string_pool_init() — allocate the initial string pool from the heap.
; Each entry is 16 bytes (8-byte ptr + 8-byte len).
; Uses heap_alloc_zero; no cleanup needed (bump allocator has no free).
; Clobbers: rax, rdi
; ================================================================
string_pool_init:
    mov rdi, STRING_POOL_INITIAL_CAPACITY * 16
    call heap_alloc_zero
    mov [string_pool_ptr], rax
    mov qword [string_pool_capacity], STRING_POOL_INITIAL_CAPACITY
    ret

; ================================================================
; string_pool_grow() — double the pool capacity when full.
; Allocates a new buffer, copies old data, updates pointer+capacity.
; Clobbers: rax, rdi, rsi, rdx
; ================================================================
string_pool_grow:
    ; new_capacity = old_capacity * 2
    mov rax, [string_pool_capacity]
    shl rax, 1
    mov rdx, rax                ; rdx = new_capacity

    ; Allocate new buffer: new_capacity * 16 bytes
    mov rdi, rax
    shl rdi, 4                   ; rdi = new_capacity * 16
    push rdx                     ; save new_capacity
    call heap_alloc_zero
    pop rdx                      ; rdx = new_capacity

    ; Copy old data to new buffer
    mov rsi, [string_pool_ptr]   ; src = old pool
    mov rdi, rax                 ; dst = new pool
    mov rdx, [string_pool_capacity]
    shl rdx, 4                   ; rdx = old_capacity * 16 (mem_copy takes size in rdx)
    push rax                     ; save new pool ptr
    call mem_copy
    pop rax                      ; rax = new pool ptr

    ; Update pool pointer and capacity
    mov [string_pool_ptr], rax
    mov [string_pool_capacity], rdx
    ret

; ================================================================
; codegen_generate(rdi = AST_PROGRAM*)
; ================================================================
codegen_generate:
    PROLOGUE r15, r14, r13, r12, rbx

    mov r15, rdi
    mov qword [label_counter], 0

    mov rsi, asm_section_text
    call emit_string

    ; Emit _start trampoline that saves argv/argc, calls main, and exits
    ; The argv/argc globals allow C2X code to access command-line args
    ; via `extern int argc; extern char** argv;`
    ; The argv_save code is now embedded inside asm_start_entry/asm_start_result
    ; (right after the _start: label) so it actually executes.

    ; If --emit-result is active, emit version that writes return value to stdout
    cmp qword [emit_result_flag], 0
    je .std_start
    mov rsi, asm_start_result
    call emit_string
    jmp .after_start
.std_start:
    mov rsi, asm_start_entry
    call emit_string
.after_start:

    ; Emit syscall runtime stubs (available for user code to call)
    mov rsi, asm_sys_read
    call emit_string
    mov rsi, asm_sys_write
    call emit_string
    mov rsi, asm_sys_open
    call emit_string
    mov rsi, asm_sys_close
    call emit_string
    mov rsi, asm_sys_dup2
    call emit_string
    mov rsi, asm_sys_exit
    call emit_string
    mov rsi, asm_sys_fork
    call emit_string
    mov rsi, asm_sys_execve
    call emit_string
    mov rsi, asm_sys_wait4
    call emit_string
    mov rsi, asm_sys_unlink
    call emit_string
    mov rsi, asm_sys_getpid
    call emit_string
    mov rsi, asm_sys_getdents64
    call emit_string
    mov rsi, asm_sys_clock_gettime
    call emit_string
    mov rsi, asm_sys_mkdir
    call emit_string
    mov rsi, asm_sys_nanosleep
    call emit_string
    mov rsi, asm_sys_kill
    call emit_string
    mov rsi, asm_sys_ioctl
    call emit_string

    ; Emit struct copy helper
    mov rsi, asm_struct_copy
    call emit_string

    ; Register global variables BEFORE generating functions
    mov rdi, [r15 + ast_node_t.data3]   ; global var count
    mov rsi, [r15 + ast_node_t.data4]   ; global var array
    call register_globals

    mov r12, [r15 + ast_node_t.data1]   ; function count
    mov r13, [r15 + ast_node_t.data2]   ; function array
    xor r14, r14

.func_loop:
    cmp r14, r12
    jge .func_done
    mov rax, [prog_func_source_array]
    test rax, rax
    jz .func_source_ready
    mov rbx, [rax + 8 + r14 * 8]
    mov [source_path], rbx
.func_source_ready:
    mov rdi, [r13 + 8 + r14 * 8]
    call gen_function
    inc r14
    jmp .func_loop
.func_done:
    ; DEBUG: check loop count - if > 1, abort with exit code 99
    push rax
    mov rax, [dbg_loop_count]
    inc rax
    mov [dbg_loop_count], rax
    cmp rax, 1
    je .dbg_after_inc
    ; Loop ran more than once - abort with exit code 99
    mov rax, 60         ; sys_exit
    mov rdi, 99
    syscall
.dbg_after_inc:
    pop rax
    cmp qword [emit_returns_flag], 0
    je .no_print_helper
    mov rsi, asm_print_rax_helper
    call emit_string
.no_print_helper:

    ; Emit BSS declarations for global variables
    mov rdi, [r15 + ast_node_t.data3]
    mov rsi, [r15 + ast_node_t.data4]
    call emit_global_vars

    ; Emit fixed runtime globals (g_argc, g_argv) in BSS section
    mov rsi, asm_section_bss
    call emit_string
    mov rsi, asm_label_g_prefix
    call emit_string
    mov rsi, asm_argc_name
    call emit_string
    mov rsi, asm_label_sep
    call emit_string
    mov rsi, asm_resq
    call emit_string
    mov rdi, 1
    call emit_int
    mov rsi, asm_newline
    call emit_string

    mov rsi, asm_label_g_prefix
    call emit_string
    mov rsi, asm_argv_name
    call emit_string
    mov rsi, asm_label_sep
    call emit_string
    mov rsi, asm_resq
    call emit_string
    mov rdi, 1
    call emit_int
    mov rsi, asm_newline
    call emit_string

    ; Emit struct_ret_slot global (for struct return values)
    mov rsi, asm_label_struct_ret_slot
    call emit_string
    mov rsi, asm_label_sep
    call emit_string
    mov rsi, asm_resb
    call emit_string
    mov rdi, 256
    call emit_int
    mov rsi, asm_newline
    call emit_string

    ; Emit .rodata section with string literals
    cmp qword [string_count], 0
    je .no_rodata
    mov rsi, asm_section_rodata
    call emit_string
    xor r12, r12                     ; index
.rodata_loop:
    cmp r12, [string_count]
    jge .no_rodata
    ; Emit .LC{index}:
    mov rsi, asm_label_lc
    call emit_string
    mov rdi, r12
    call emit_int
    mov rsi, asm_label_sep
    call emit_string
    ; Emit db byte1, byte2, ..., 0
    mov rsi, asm_db_dir
    call emit_string
    ; Get string ptr and length
    mov rax, r12
    shl rax, 4
    add rax, [string_pool_ptr]      ; r13 = pool entry (dynamic)
    mov r14, [rax]                   ; r14 = string ptr
    mov r15, [rax + 8]              ; r15 = string length
    xor rbx, rbx                     ; byte index
.rodata_bytes:
    cmp rbx, r15
    jae .rodata_null
    ; Emit byte value
    movzx rdi, byte [r14 + rbx]
    call emit_int
    ; Emit ", " separator
    mov dil, ','
    call out_write_char
    mov dil, ' '
    call out_write_char
    inc rbx
    jmp .rodata_bytes
.rodata_null:
    ; Emit null terminator
    mov rdi, 0
    call emit_int
    mov rsi, asm_newline
    call emit_string
    inc r12
    jmp .rodata_loop

.no_rodata:
    EPILOGUE r15, r14, r13, r12, rbx

; ================================================================
; gen_function(rdi = AST_FUNCTION*)
; ================================================================
gen_function:
    PROLOGUE r15, r14, r13, r12, rbx

    mov r15, rdi
    mov r12, [r15 + ast_node_t.data2]  ; name_ptr
    mov r13, [r15 + ast_node_t.data3]  ; body (AST_BLOCK) — 0 = forward declaration

    ; Skip forward declarations (no body)
    test r13, r13
    jz .gf_skip

    ; Reset return tracking
    xor rax, rax
    mov [function_has_return], rax
    mov [last_stmt_terminator], rax

    ; Set current_func_return_type for THIS function. This global is used
    ; by gen_return to emit the struct copy logic. It must be set here (not
    ; just during parsing) because by the time codegen runs, the parser has
    ; finished and this global reflects the last parsed function.
    mov rax, [r15 + ast_node_t.data1]  ; return type from AST
    mov [current_func_return_type], rax

    ; Read field_array_ptr from AST node data5 (set during parsing).
    ; This is the correct value for THIS function, unlike the global
    ; current_func_return_fields which gets overwritten by later functions.
    mov rax, [r15 + ast_node_t.data5]
    mov [current_func_return_fields], rax

    ; Register this function's return type so gen_call can detect
    ; struct-returning callees and emit the hidden return-pointer argument.
    ; rdi = name_ptr, rsi = return_type, rdx = field_array_ptr (for struct)
    mov rdi, r12
    mov rsi, [r15 + ast_node_t.data1]
    mov rdx, rax                     ; field_array_ptr from AST
    push r15
    push r12
    push rsi
    call register_func_return
    pop rsi
    pop r12
    pop r15
    ; Re-read return type after call (may have been clobbered)
    mov rsi, [r15 + ast_node_t.data1]

    ; global <name>
    mov rdi, r12
    mov rsi, asm_global
    call emit_string
    mov rsi, r12
    call emit_string
    mov rsi, asm_newline
    call emit_string

    ; <name>:
    mov rsi, r12
    call emit_string
    mov rsi, asm_label_sep
    call emit_string

    ; Prologue
    mov rsi, asm_prologue
    call emit_string

    ; Collect symbols & calculate frame size
    xor rax, rax
    mov [symbol_count], rax
    mov [frame_size], rax

    ; If this function returns a struct, reserve [rbp - 8] for the hidden
    ; return pointer BEFORE collect_symbols so variables start at [rbp - 16+].
    xor r14, r14                     ; r14 = struct_ret flag (0 or 1)
    mov rax, [r15 + ast_node_t.data1]
    cmp rax, TOK_KW_STRUCT
    jne .no_ret_reserve
    mov r14, 1
    add qword [frame_size], 8        ; reserve [rbp - 8] for hidden return pointer
.no_ret_reserve:

    mov rdi, r13
    call collect_symbols

    ; Register parameters in symbol table, update frame_size
    mov rdi, [r15 + ast_node_t.data4]  ; param array (0 if none)
    test rdi, rdi
    jz .no_params
    mov rdi, [r15 + ast_node_t.data4]
    call register_params
.no_params:

    ; sub rsp, frame_size
    mov rax, [frame_size]
    test rax, rax
    jz .no_sub_rsp
    mov rsi, asm_sub_rsp
    call emit_string
    mov rdi, [frame_size]
    call emit_int
    mov rsi, asm_newline
    call emit_string
.no_sub_rsp:

    ; If struct return, save rdi (hidden return ptr) to [rbp - 8].
    ; This slot was reserved by adding 8 to frame_size before collect_symbols,
    ; so no local variable or parameter will overlap with it.
    test r14, r14
    jz .no_save_ret_ptr
    mov rsi, asm_mov_rbp_ret_ptr
    call emit_string
.no_save_ret_ptr:

    ; Emit param copy code (from ABI regs/stack to frame slots)
    mov rdi, [r15 + ast_node_t.data4]  ; param array (0 if none)
    test rdi, rdi
    jz .no_param_copy
    mov rdi, [r15 + ast_node_t.data4]
    call emit_param_copy
.no_param_copy:

.emit_body:
    ; Assign a unique function-end label for early returns to jump to
    mov rax, [label_counter]
    inc qword [label_counter]
    mov [function_end_label], rax

    ; Generate body code
    mov rdi, r13
    call gen_block

    ; Function end label (target for early return jumps)
    mov rsi, asm_label_func_end
    call emit_string
    mov rdi, [function_end_label]
    call emit_int
    mov rsi, asm_label_sep
    call emit_string

    ; Epilogue
    mov rsi, asm_epilogue
    call emit_string

    ; Check for unused variables (post-codegen pass)
    ; Always run when there's a body (before missing-return check)
    call check_symbol_unused_post_codegen

    ; Warning: missing return statement
    ; Check if function return type is non-void and no return was emitted
    mov rax, [r15 + ast_node_t.data1]  ; return type
    cmp rax, TOK_KW_VOID
    je .gf_skip
    cmp qword [function_has_return], 0
    jne .gf_skip
    push r12
    push r15
    mov r8, [r15 + ast_node_t.line]
    mov r9, [r15 + ast_node_t.column]
    mov rdi, WARN_MISSING_RETURN
    mov rsi, r8
    mov rdx, r9
    mov rcx, msg_warn_missing_return
    call warn_at
    pop r15
    pop r12

.gf_skip:
    EPILOGUE r15, r14, r13, r12, rbx

; ================================================================
; collect_symbols(rdi = AST_BLOCK*)
; Walk block, register all VAR_DECL symbols
; ================================================================
collect_symbols:
    PROLOGUE r15, r14, r13, r12, rbx

    mov r12, rdi
    mov r14, [r12 + ast_node_t.data1]   ; stmt count
    mov r13, [r12 + ast_node_t.data2]   ; stmt array

    xor rbx, rbx
.loop:
    cmp rbx, r14
    jge .done

    mov rdi, [r13 + 8 + rbx * 8]
    test rdi, rdi
    jz .next

    mov rax, [rdi + ast_node_t.type]

    cmp rax, AST_VAR_DECL
    je .var

    cmp rax, AST_BLOCK
    je .subblock

    cmp rax, AST_IF
    je .if_stmt

    cmp rax, AST_WHILE
    je .while_stmt

    cmp rax, AST_FOR
    je .for_stmt

    cmp rax, AST_ARRAY_DECL
    je .array

    cmp rax, AST_STRUCT_DEF
    je .struct_def

.next:
    inc rbx
    jmp .loop

.var:
    push rbx
    push rdi

    mov rbx, rdi                    ; rbx = VAR_DECL node

    ; name_ptr
    mov rdi, [rbx + ast_node_t.data2]
    push rdi                        ; save name_ptr

    ; strlen of name
    mov rsi, rdi
    call strlen
    mov rsi, rax                    ; rsi = name_len

    ; type
    mov rcx, [rbx + ast_node_t.data1]  ; rcx = type token

    ; Compute offset = -(new_frame_size) where new = old + size
    mov rdx, [frame_size]
    cmp rcx, TOK_KW_CHAR
    je .char_size
    add qword [frame_size], 8
    mov rdx, 8
    jmp .got_size
.char_size:
    inc qword [frame_size]
    mov rdx, 1
.got_size:
    ; offset = -frame_size
    mov rdx, [frame_size]
    neg rdx                         ; rdx = negative offset from rbp

    ; add_symbol(name_ptr, name_len, offset, type)
    pop rdi                         ; rdi = name_ptr
    ; rsi = name_len (already set)
    ; rdx = offset (already set)
    ; rcx = type (already set)
    ; Check if struct pointer: set extra = field_array_ptr from data4
    xor r8, r8                      ; default extra = 0
    ; A pointer to a struct at any depth (struct T*, struct T**, ...) carries
    ; the pointee's field array in data4. Use the depth-agnostic helper so
    ; `struct T** p; p[i]->field` can resolve fields. rdi holds name_ptr for
    ; add_symbol, so save it across the helper call.
    cmp rcx, PTR_TYPE_FLAG
    jb .not_struct_ptr               ; below the pointer band → not a pointer
    push rdi
    push rcx
    mov rdi, rcx
    call type_base_is_struct
    pop rcx
    pop rdi                          ; restore name_ptr
    test rax, rax
    jz .not_struct_ptr
    ; Struct pointer — get field_array_ptr from data4
    mov rax, [rbx + ast_node_t.data4]
    test rax, rax
    jz .not_struct_ptr
    mov r8, rax
.not_struct_ptr:
    mov rax, [symbol_count]          ; save index for new symbol
    push rax                         ; save index on stack
    mov [current_ast_node], rbx
    call add_symbol
    pop rax                          ; rax = index of new symbol
    mov r15, [symbol_const_ptr]      ; r15 = const-bytes base (loaded after call)
    ; Check const flag from AST node data4
    mov rcx, [rbx + ast_node_t.data4]
    test rcx, VAR_CONST
    jz .var_not_const
    mov byte [r15 + rax], 1
    jmp .var_const_done
.var_not_const:
    mov byte [r15 + rax], 0
.var_const_done:

    pop rdi
    pop rbx
    jmp .next

.array:
    push rbx
    push rdi

    mov rbx, rdi                    ; rbx = ARRAY_DECL node

    ; name_ptr
    mov rdi, [rbx + ast_node_t.data2]
    push rdi                        ; save name_ptr

    ; strlen of name
    mov rsi, rdi
    call strlen
    mov rsi, rax                    ; rsi = name_len

    ; type
    mov rcx, [rbx + ast_node_t.data1]  ; rcx = type token
    mov r8, [rbx + ast_node_t.data3]   ; r8 = element count (or size expr for VLA)

    ; VLA check: if data5 has VLA_FLAG set, reserve a 16-byte frame slot
    ; {base_ptr, count} and set extra = -1 so indexing loads the base pointer.
    mov rax, [rbx + ast_node_t.data5]
    test rax, VLA_FLAG
    jnz .array_vla

    ; Check if struct array by type (data1 is not a standard type token)
    cmp rcx, TOK_KW_INT
    je .array_not_struct
    cmp rcx, TOK_KW_CHAR
    je .array_not_struct

    ; Check for pointer-to-struct: type >= PTR_TYPE_FLAG means it's a pointer;
    ; each element is 8 bytes regardless of the pointed-to type.
    cmp rcx, PTR_TYPE_FLAG
    jae .array_ptr_type

    ; Struct array: elem_size = struct total_size (data1)
    mov rax, [rbx + ast_node_t.data1]  ; struct total_size
    imul rax, r8                       ; total = struct_size * count
    mov rcx, TOK_KW_STRUCT
    ; Register the field-array pointer as extra (NOT the element count), so the
    ; index handler can compute the struct stride. Bounds checks are skipped for
    ; struct elements, so the count is not needed here.
    mov r8, [rbx + ast_node_t.data4]   ; field_array_ptr
    jmp .array_do_size

.array_ptr_type:
    ; Pointer type (e.g., struct Name* arr[N] or char** arr[N]): each element is 8 bytes.
    mov rax, r8
    shl rax, 3                         ; count * 8
    ; Store type as TOK_KW_INT (8-byte elements) so indexing uses pointer-size scaling
    mov rcx, TOK_KW_INT
    ; Keep the pointee's field array in the symbol's `.fields` slot so
    ; `arr[i]->field` can resolve the pointee's members (extra stays the
    ; element count, so bounds checks keep working). data4 holds it for
    ; struct-pointer arrays; 0 for char**/int**-style arrays.
    push rax
    mov rax, [rbx + ast_node_t.data4]
    mov [pending_symbol_fields], rax
    pop rax
    jmp .array_do_size
.array_not_struct:
    ; Compute frame size addition = elem_size * count
    cmp rcx, TOK_KW_CHAR
    je .array_char_size
    mov rax, r8
    shl rax, 3                       ; int: count * 8
    jmp .array_do_size
.array_char_size:
    mov rax, r8                      ; char: count * 1
.array_do_size:
    add [frame_size], rax
    mov rdx, [frame_size]
    neg rdx                          ; rdx = negative offset

    pop rdi                          ; rdi = name_ptr
    ; rsi = name_len
    ; rdx = offset
    ; rcx = type
    ; r8 = extra (element count / total for 2D)

    ; --- 2D array support: extract dim2 from data5, pack into extra ---
    ; data5 encoding: (dim2 << 2) | const_flag_bits
    ; If dim2 > 0: pack extra = dim1 | (dim2 << 32), where dim1 = total_count / dim2.
    ; This lets the index handler compute stride = dim2 * elem_size for arr[i].
    push rdx                         ; save offset (div clobbers rdx)
    push rcx                         ; save type
    mov rax, [rbx + ast_node_t.data5]
    shr rax, 2                       ; rax = dim2 (0 for 1D)
    test rax, rax
    jz .array_dim2_done
    ; 2D: compute dim1 = total_count / dim2
    push rax                         ; save dim2
    mov rax, r8                      ; rax = total_count
    xor rdx, rdx
    div qword [rsp]                  ; rax = dim1 = total_count / dim2
    mov r8, rax                      ; r8 = dim1 (low 32 bits of extra)
    pop rax                          ; rax = dim2
    shl rax, 32                      ; rax = dim2 << 32
    or r8, rax                       ; r8 = dim1 | (dim2 << 32)
.array_dim2_done:
    pop rcx                          ; restore type
    pop rdx                          ; restore offset
    ; --- end 2D array support ---
    jmp .array_add_symbol

.array_vla:
    ; VLA: reserve a 16-byte frame slot [rbp-off] = base ptr, [rbp-off-8] = count.
    ; extra = -1 signals VLA to the index/load/store handlers. The actual
    ; array region is allocated at runtime in gen_array_decl (sub rsp, ...).
    add qword [frame_size], 16
    mov rdx, [frame_size]
    neg rdx                          ; rdx = negative offset (base ptr slot)
    pop rdi                          ; rdi = name_ptr
    ; rsi = name_len (still set from strlen above)
    ; rcx = element type (still set)
    mov r8, -1                       ; extra = -1 (VLA marker)
    ; Fall through to add_symbol (skip 2D packing — VLAs are 1D).

.array_add_symbol:

    mov rax, [symbol_count]          ; save index for new symbol
    push rax
    mov [current_ast_node], rbx
    call add_symbol
    pop rax                          ; rax = index of new symbol
    mov r15, [symbol_const_ptr]      ; r15 = const-bytes base
    ; Check const flag from AST node data5
    mov rcx, [rbx + ast_node_t.data5]
    test rcx, VAR_CONST
    jz .array_not_const
    mov byte [r15 + rax], 1
    jmp .array_const_done
.array_not_const:
    mov byte [r15 + rax], 0
.array_const_done:

    pop rdi
    pop rbx
    jmp .next

.struct_def:
    push rbx
    push rdi

    mov rbx, rdi                    ; rbx = STRUCT_DEF node

    ; name_ptr from data3 (var name)
    mov rdi, [rbx + ast_node_t.data3]
    push rdi                        ; save name_ptr

    ; strlen of name
    mov rsi, rdi
    call strlen
    mov rsi, rax                    ; rsi = name_len

    ; type = TOK_KW_STRUCT
    mov rcx, TOK_KW_STRUCT
    ; extra = field array ptr (from data2)
    mov r8, [rbx + ast_node_t.data2]

    ; total_size from data1
    mov rdx, [rbx + ast_node_t.data1]
    add [frame_size], rdx
    mov rdx, [frame_size]
    neg rdx                          ; rdx = negative offset

    pop rdi                          ; rdi = name_ptr
    ; rsi = name_len
    ; rdx = offset
    ; rcx = type (TOK_KW_STRUCT)
    ; r8 = extra (field_array_ptr)
    mov [current_ast_node], rbx
    call add_symbol

    mov r15, [symbol_const_ptr]      ; r15 = const-bytes base
    ; Check const flag from AST node data5
    mov rax, [symbol_count]
    dec rax
    mov rcx, [rbx + ast_node_t.data5]
    test rcx, VAR_CONST
    jz .struct_def_not_const
    mov byte [r15 + rax], 1
    jmp .struct_def_const_done
.struct_def_not_const:
    mov byte [r15 + rax], 0
.struct_def_const_done:

    pop rdi
    pop rbx
    jmp .next

.subblock:
    push rbx
    call collect_symbols
    pop rbx
    jmp .next

.if_stmt:
    push rbx                         ; save index
    push rdi                         ; save if node
    mov rdi, [rdi + ast_node_t.data2] ; then block
    test rdi, rdi
    jz .if_skip_then
    call collect_symbols
.if_skip_then:
    pop rdi                          ; restore if node
    mov rdi, [rdi + ast_node_t.data3] ; else block
    test rdi, rdi
    jz .if_skip_else
    call collect_symbols
.if_skip_else:
    pop rbx                          ; restore index
    jmp .next

.while_stmt:
    push rbx
    mov rdi, [rdi + ast_node_t.data2]  ; body
    call collect_symbols
    pop rbx
    jmp .next

.for_stmt:
    push rbx
    push rdi                         ; save for node
    ; Collect symbols from the body
    mov rdi, [rdi + ast_node_t.data4]
    test rdi, rdi
    jz .for_skip_body
    call collect_symbols
.for_skip_body:
    pop rdi                          ; restore for node
    ; Init may contain a var decl; register it directly
    mov rdi, [rdi + ast_node_t.data1]
    test rdi, rdi
    jz .for_skip_init
    mov rax, [rdi + ast_node_t.type]
    cmp rax, AST_VAR_DECL
    jne .for_skip_init
    ; Register var decl from for-init manually
    push rdi                         ; save var_decl node
    mov rdi, [rdi + ast_node_t.data2]  ; name_ptr
    mov rsi, rdi                     ; rsi = name_ptr for strlen
    push rdi
    call strlen
    mov rsi, rax                     ; rsi = name_len
    pop rdi                          ; rdi = name_ptr
    pop rcx                          ; rcx = var_decl node
    push rcx                         ; re-save var_decl
    push rdi                         ; save name_ptr
    mov rbx, [rcx + ast_node_t.data1] ; rbx = type
    mov rdx, [frame_size]
    cmp rbx, TOK_KW_CHAR
    je .for_var_char
    add qword [frame_size], 8
    jmp .for_var_size_done
.for_var_char:
    inc qword [frame_size]
.for_var_size_done:
    mov rdx, [frame_size]
    neg rdx                          ; rdx = offset
    xor r8, r8                       ; extra = 0
    pop rdi                          ; rdi = name_ptr
    ; rsi = name_len, rdx = offset, rcx = type, r8 = extra
    mov rcx, rbx                     ; rcx = type
    mov rax, [rsp]
    mov [current_ast_node], rax
    call add_symbol                  ; rax = symbol index
    mov rbx, rax                     ; save index
    mov r15, [symbol_const_ptr]      ; r15 = const-bytes base
    pop rcx                          ; rcx = var_decl node
    ; Set const flag
    mov rcx, [rcx + ast_node_t.data4]
    test rcx, 2
    jz .for_var_not_const
    mov byte [r15 + rbx], 1
    jmp .for_skip_init
.for_var_not_const:
    mov byte [r15 + rbx], 0
.for_skip_init:
    pop rbx
    jmp .next

.done:
    EPILOGUE r15, r14, r13, r12, rbx

; ================================================================
; register_params(rdi = param_array*) — registers all params as local symbols
; array[0] = count, array[1..N] = AST_VAR_DECL nodes
; Updates frame_size. Clobbers rax, rcx, rdx, rsi.
; ================================================================
register_params:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r14, rdi                    ; r14 = param array
    mov r15, [r14]                  ; r15 = param count
    test r15, r15
    jz .rp_done

    xor r12, r12                    ; index
.rp_loop:
    cmp r12, r15
    jge .rp_done

    mov r13, [r14 + 8 + r12 * 8]    ; r13 = AST_VAR_DECL node
    test r13, r13
    jz .rp_next

    ; Get param name_ptr
    mov rdi, [r13 + ast_node_t.data2]
    push rdi                        ; save name_ptr

    ; strlen of name
    mov rsi, rdi
    call strlen
    mov rsi, rax                    ; rsi = name_len

    ; Get param type
    mov rcx, [r13 + ast_node_t.data1]

    ; Compute size: 8 for int/pointer, 1 for char
    cmp rcx, PTR_TYPE_FLAG
    jge .rp_size_8
    cmp rcx, TOK_KW_CHAR
    je .rp_size_1
.rp_size_8:
    add qword [frame_size], 8
    jmp .rp_got_size
.rp_size_1:
    inc qword [frame_size]
.rp_got_size:
    ; offset = -frame_size
    mov rdx, [frame_size]
    neg rdx

    ; add_symbol(name_ptr, name_len, offset, type, extra)
    pop rdi                         ; rdi = name_ptr
    ; Check if struct pointer param: set extra = field_array_ptr from data4
    xor r8, r8
    cmp rcx, PTR_TYPE_FLAG
    jb .rp_not_struct_ptr
    push rax
    mov rax, rcx
    sub rax, PTR_TYPE_FLAG
    cmp rax, TOK_KW_STRUCT
    pop rax
    jne .rp_not_struct_ptr
    mov rax, [r13 + ast_node_t.data4]
    test rax, rax
    jz .rp_not_struct_ptr
    mov r8, rax
.rp_not_struct_ptr:
     ; Save name_ptr across add_symbol (which clobbers rdi)
     push rdi
     mov [current_ast_node], r13
     call add_symbol
     pop rdi                         ; rdi = name_ptr (for mark_symbol_used)
     mov rbx, [symbol_const_ptr]     ; rbx = const-bytes base
     ; Check const flag from AST node data4
     mov rax, [symbol_count]
     dec rax
      mov rcx, [r13 + ast_node_t.data4]
      test rcx, VAR_CONST
      jz .rp_not_const
      mov byte [rbx + rax], 1
      jmp .rp_const_done
.rp_not_const:
      mov byte [rbx + rax], 0
.rp_const_done:
     ; Mark parameter as used — parameters are inherently used by the caller,
     ; so they should never trigger the "unused variable" warning even if the
     ; function body never reads them.
     call mark_symbol_used

.rp_next:
    inc r12
    jmp .rp_loop

.rp_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ================================================================
; emit_param_copy(rdi = param_array*) — emits code to copy ABI params to frame
; ================================================================
emit_param_copy:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r14, rdi                    ; r14 = param array
    mov r15, [r14]                  ; r15 = param count
    test r15, r15
    jz .epc_done_no_offset          ; no params → skip reg_offset push

    ; If function returns a struct, skip rdi (it's the hidden return pointer)
    ; and start user params from rsi (register index 1).
    mov rax, [current_func_return_type]
    cmp rax, TOK_KW_STRUCT
    jne .epc_no_skip
    push 1                          ; reg_offset = 1 (skip rdi)
    jmp .epc_loop_start
.epc_no_skip:
    push 0                          ; reg_offset = 0
.epc_loop_start:

    xor r12, r12                    ; param index
.epc_loop:
    cmp r12, r15
    jge .epc_done

    mov r13, [r14 + 8 + r12 * 8]    ; r13 = AST_VAR_DECL node
    test r13, r13
    jz .epc_next

    ; Look up param in symbol table for its frame offset
    mov rdi, [r13 + ast_node_t.data2]  ; name_ptr
    call find_symbol
    test rax, rax
    jz .epc_next                      ; not found (shouldn't happen)

    ; rax = negative offset from rbp
    mov rdi, rax
    neg rdi                           ; rdi = positive offset for emit

    ; Compute register index = param_index + reg_offset
    mov rax, r12
    add rax, [rsp]                    ; rax = reg_index
    cmp rax, 6
    jl .epc_reg                       ; params 0-5 come from registers
    jmp .epc_stack_arg                ; params 6+ come from stack

.epc_reg:
    ; Emit: mov [rbp-offset], REGn
    ; rdi = positive frame offset, rax = register index (0-5)
    mov rbx, [r13 + ast_node_t.data1]   ; param type
    cmp rbx, PTR_TYPE_FLAG
    jge .epc_reg_qword
    cmp rbx, TOK_KW_CHAR
    je .epc_reg_char
.epc_reg_qword:
    push rdi                          ; save offset BEFORE emit_string (clobbers dil)
    push rax                          ; save reg_index
    mov rsi, asm_mov_qword_rbp
    call emit_string
    pop rax                           ; restore reg_index
    pop rdi                           ; restore offset
    push rax                          ; save reg_index before emit_int clobbers it
    call emit_int                     ; emit correct offset
    pop rax                           ; restore reg_index
    mov rsi, [param_reg_suffixes + rax * 8]
    call emit_string
    ; Mark parameter as initialized
    push r12
    push r13
    push rdi
    mov rdi, [r13 + ast_node_t.data2]   ; name_ptr
    call mark_symbol_initialized
    pop rdi
    pop r13
    pop r12
    jmp .epc_next
.epc_reg_char:
    push rdi                          ; save offset BEFORE emit_string
    push rax                          ; save reg_index
    mov rsi, asm_mov_byte_rbp
    call emit_string
    pop rax                           ; restore reg_index
    pop rdi                           ; restore offset
    push rax                          ; save reg_index before emit_int clobbers it
    call emit_int
    pop rax                           ; restore reg_index
    mov rsi, [param_reg_byte_suffixes + rax * 8]
    call emit_string
    ; Mark parameter as initialized
    push r12
    push r13
    push rdi
    mov rdi, [r13 + ast_node_t.data2]   ; name_ptr
    call mark_symbol_initialized
    pop rdi
    pop r13
    pop r12
    jmp .epc_next

.epc_stack_arg:
    ; rdi = positive frame offset, r12 = param index (>= 5 for struct, >= 6 for non-struct)
    ; Stack offset = 16 + (param_index - num_reg_params) * 8
    ; num_reg_params = 6 for non-struct, 5 for struct (since rdi is hidden return ptr)
    ; NOTE: save frame offset on the stack — r15 holds the param count and must
    ; not be clobbered, or the loop reads past the param array (segfault on
    ; functions with 7+ params / stack arguments).
    push rdi                         ; save frame offset (above reg_offset)

    mov rax, r12                      ; param index
    sub rax, 5                        ; subtract num_reg_params (5 for struct, but we'll add 1 for non-struct below)
    mov rbx, [rsp + 8]               ; reg_offset (1 for struct, 0 for non-struct) — below saved frame_off
    test rbx, rbx
    jnz .epc_stack_struct
    ; Non-struct: num_reg_params = 6, so subtract 1 more
    dec rax
.epc_stack_struct:
    shl rax, 3
    add rax, 16

    ; Emit: mov rax, [rbp+stack_off]
    mov rdi, rax
    push rdi                          ; save stack offset BEFORE emit_string
    mov rsi, asm_mov_rax_rbp_plus
    call emit_string
    pop rdi                           ; restore stack offset
    call emit_int                     ; emit correct offset
    mov rsi, asm_close_bracket
    call emit_string

    ; Emit: mov [rbp-frame_off], rax
    pop rdi                           ; restore frame offset (was pushed at .epc_stack_arg entry)
    mov rbx, [r13 + ast_node_t.data1] ; param type
    cmp rbx, PTR_TYPE_FLAG
    jge .epc_stack_qword
    cmp rbx, TOK_KW_CHAR
    je .epc_stack_char
.epc_stack_qword:
    push rdi                          ; save frame offset BEFORE emit_string
    mov rsi, asm_mov_qword_rbp
    call emit_string
    pop rdi
    call emit_int
    mov rsi, asm_rbp_rax
    call emit_string
    ; Mark parameter as initialized
    push r12
    push r13
    push rdi
    mov rdi, [r13 + ast_node_t.data2]   ; name_ptr
    call mark_symbol_initialized
    pop rdi
    pop r13
    pop r12
    jmp .epc_next
.epc_stack_char:
    push rdi                          ; save frame offset BEFORE emit_string
    mov rsi, asm_mov_byte_rbp
    call emit_string
    pop rdi
    call emit_int
    mov rsi, asm_rbp_al
    call emit_string
    ; Mark parameter as initialized
    push r12
    push r13
    push rdi
    mov rdi, [r13 + ast_node_t.data2]   ; name_ptr
    call mark_symbol_initialized
    pop rdi
    pop r13
    pop r12
    jmp .epc_next

.epc_next:
    inc r12
    jmp .epc_loop

.epc_done:
    add rsp, 8                        ; pop reg_offset
.epc_done_no_offset:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ================================================================
; report_const_error(name_ptr)
; Print "Cannot assign to const variable 'NAME'\n" to stderr.
; Increments error_count.
; rdi = name_ptr (null-terminated string)
; ================================================================
report_const_error:
    push rbx
    push r12

    mov r12, rdi                    ; r12 = name_ptr (save across calls)

    inc qword [error_count]

    ; Save current out_fd, flush, switch to stderr
    mov rbx, [out_fd]
    push rbx
    call out_flush
    mov rdi, STDERR
    call out_set_fd

    ; Print message prefix
    mov rsi, msg_assign_const
    call out_write_string

    ; Print " 'NAME'"
    mov dil, ' '
    call out_write_char
    mov dil, 39                      ; single quote
    call out_write_char
    mov rsi, r12                     ; name_ptr
    call out_write_string
    mov dil, 39                      ; single quote
    call out_write_char
    mov dil, 10                      ; newline
    call out_write_char
    call out_flush

    ; Restore out_fd
    pop rdi                          ; rdi = saved out_fd
    call out_set_fd
    pop r12
    pop rbx
    ret

; ================================================================
; report_undeclared(name_ptr)
; Print "error: undeclared identifier 'NAME'\n" to stderr and count the
; error, so an undeclared identifier used as a value is a hard compile
; error instead of silent zero-value codegen (the C2X grammar resolves
; names in one pass, so codegen is the first place the name is known
; missing). rdi = name_ptr.
; ================================================================
report_undeclared:
    push rbx
    push r12

    mov r12, rdi                    ; r12 = name_ptr (save across calls)

    inc qword [error_count]

    ; Save current out_fd, flush, switch to stderr
    mov rbx, [out_fd]
    push rbx
    call out_flush
    mov rdi, STDERR
    call out_set_fd

    mov rsi, msg_undeclared
    call out_write_string

    mov dil, 32                      ; space
    call out_write_char
    mov dil, 39                      ; single quote
    call out_write_char
    mov rsi, r12                     ; name_ptr
    call out_write_string
    mov dil, 39                      ; single quote
    call out_write_char
    mov dil, 10                      ; newline
    call out_write_char
    call out_flush

    ; Restore out_fd
    pop rdi                          ; rdi = saved out_fd
    call out_set_fd
    pop r12
    pop rbx
    ret

; ================================================================
; report_no_field(name_ptr)
; Print "error: no field named 'NAME'\n" to stderr and count the error, so
; a member access on a struct that has no such field is a hard compile
; error instead of silent zero-value codegen. rdi = name_ptr.
; ================================================================
report_no_field:
    push rbx
    push r12

    mov r12, rdi                    ; r12 = name_ptr (save across calls)

    inc qword [error_count]

    ; Save current out_fd, flush, switch to stderr
    mov rbx, [out_fd]
    push rbx
    call out_flush
    mov rdi, STDERR
    call out_set_fd

    mov rsi, msg_no_field
    call out_write_string

    mov dil, 32                      ; space
    call out_write_char
    mov dil, 39                      ; single quote
    call out_write_char
    mov rsi, r12                     ; name_ptr
    call out_write_string
    mov dil, 39                      ; single quote
    call out_write_char
    mov dil, 10                      ; newline
    call out_write_char
    call out_flush

    ; Restore out_fd
    pop rdi                          ; rdi = saved out_fd
    call out_set_fd
    pop r12
    pop rbx
    ret

; ================================================================
; add_symbol(name_ptr, name_len, offset, type, extra)
; rdi=name_ptr, rsi=name_len, rdx=offset, rcx=type, r8=extra (0 default)
; ================================================================
add_symbol:
    push rdi
    push rsi
    push rdx
    push rcx
    push r8
    push rbx

    call ensure_symbol_capacity
    ; ensure_symbol_capacity calls heap_alloc_zero and mem_copy, which clobber
    ; caller-saved registers. Restore our inputs from the stack.
    ; Stack: [rsp]=rbx [rsp+8]=r8 [rsp+16]=rcx [rsp+24]=rdx [rsp+32]=rsi [rsp+40]=rdi
    mov rdi, [rsp + 40]    ; name_ptr
    mov rsi, [rsp + 32]    ; name_len
    mov rdx, [rsp + 24]    ; offset
    mov rcx, [rsp + 16]    ; type
    mov r8,  [rsp + 8]     ; extra

    mov rax, [symbol_count]
    mov r9, [symbols_ptr]

    imul rbx, rax, symbol_t_size
    lea rbx, [r9 + rbx]
    mov [rbx + symbol_t.name_ptr], rdi
    mov [rbx + symbol_t.name_len], rsi
    mov [rbx + symbol_t.offset], rdx
    mov [rbx + symbol_t.type], rcx
    mov [rbx + symbol_t.extra], r8
    ; Pointee field array for arrays of struct pointers (0 otherwise).
    mov r9, [pending_symbol_fields]
    mov [rbx + symbol_t.fields], r9
    mov qword [pending_symbol_fields], 0

    ; Store source location from current_ast_node
    mov rax, [current_ast_node]
    test rax, rax
    jz .skip_loc
    mov r9, [rax + ast_node_t.line]
    mov [rbx + symbol_t.line], r9
    mov r9, [rax + ast_node_t.column]
    mov [rbx + symbol_t.column], r9
.skip_loc:

    ; New symbols start uninitialized (symbol_initialized[idx] = 0)
    mov rax, [symbol_count]
    mov r9, [symbol_initialized_ptr]
    mov byte [r9 + rax], 0
    mov r9, [symbol_used_ptr]
    mov byte [r9 + rax], 0

    inc qword [symbol_count]

.done:
    pop rbx
    pop r8
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    ret

; ================================================================
; mark_symbol_initialized(name_ptr)
; Set symbol_initialized[index] = 1 for the matching local symbol.
; ================================================================
mark_symbol_initialized:
    push rax
    push rdi
    call find_symbol_index
    cmp rax, 0
    jl .msi_done
    mov rbx, [symbol_initialized_ptr]
    mov byte [rbx + rax], 1
.msi_done:
    pop rdi
    pop rax
    ret

; ================================================================
; mark_global_symbol_initialized(name_ptr)
; Set global_symbol_initialized[index] = 1 for the matching global symbol.
; ================================================================
mark_global_symbol_initialized:
    push rax
    push rdi
    call find_global_symbol_index
    cmp rax, 0
    jl .mgsi_done
    mov rbx, [global_symbol_initialized_ptr]
    mov byte [rbx + rax], 1
.mgsi_done:
    pop rdi
    pop rax
    ret

; ================================================================
; check_symbol_initialized(name_ptr) -> rax = 0/1
; Returns 1 if local symbol is initialized, 0 otherwise.
; ================================================================
check_symbol_initialized:
    push rdi
    call find_symbol_index
    cmp rax, 0
    jl .csi_not_found
    mov rdx, [symbol_initialized_ptr]
    movzx rax, byte [rdx + rax]
    pop rdi
    ret
.csi_not_found:
    xor rax, rax
    pop rdi
    ret

; ================================================================
; mark_symbol_used(name_ptr)
; Set symbol_used[index] = 1 for the matching local symbol.
; ================================================================
mark_symbol_used:
    push rax
    push rdi
    call find_symbol_index
    cmp rax, 0
    jl .msu_done
    mov rbx, [symbol_used_ptr]
    mov byte [rbx + rax], 1
.msu_done:
    pop rdi
    pop rax
    ret

; ================================================================
; check_symbol_unused_post_codegen
; Iterate over symbol table and warn for any symbol that was declared
; but never used (read or written). Skips uninitialized symbols
; (those get a separate WARN_UNINIT_VAR warning).
; ================================================================
check_symbol_unused_post_codegen:
    push rbx
    push rcx
    push r12
    push r13
    push r14
    push r15

    mov rcx, [symbol_count]
    test rcx, rcx
    jz .csu_done
    mov r15, [symbol_used_ptr]
    mov r14, [symbol_initialized_ptr]
    mov r13, [symbols_ptr]

    xor r12, r12                       ; r12 = index
.csu_loop:
    cmp r12, rcx
    jge .csu_done

    ; Check if used
    movzx rax, byte [r15 + r12]
    test rax, rax
    jnz .csu_next                      ; skip if used

    ; Check if initialized (if not, it's an uninitialized warning, not unused)
    movzx rax, byte [r14 + r12]
    test rax, rax
    jz .csu_next                       ; skip if uninitialized (warned separately)

    ; Get symbol name for warning message
    imul rax, r12, symbol_t_size
    lea rax, [r13 + rax]
    mov r10, [rax + symbol_t.name_ptr] ; name pointer (use r10, preserve r14)
    mov r11, [rax + symbol_t.name_len] ; name length (use r11, preserve r15)

    ; Emit warning using dedicated function
    push rcx
    push r12
    mov rdi, r10
    mov rsi, r11
    mov rdx, [rax + symbol_t.line]     ; source line
    mov rcx, [rax + symbol_t.column]   ; source column
    call warn_unused_var
    pop r12
    pop rcx

.csu_next:
    inc r12
    jmp .csu_loop

.csu_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rcx
    pop rbx
    ret

; ================================================================
; check_global_symbol_initialized(name_ptr) -> rax = 0/1
; Returns 1 if global symbol is initialized, 0 otherwise.
; ================================================================
check_global_symbol_initialized:
    push rdi
    call find_global_symbol_index
    cmp rax, 0
    jl .cgsi_not_found
    mov rdx, [global_symbol_initialized_ptr]
    movzx rax, byte [rdx + rax]
    pop rdi
    ret
.cgsi_not_found:
    xor rax, rax
    pop rdi
    ret

; ================================================================
; find_symbol(name_ptr) -> rax=offset, rbx=type, rcx=extra
; rdi = name_ptr (null-terminated)
; ================================================================
find_symbol:
    push rsi
    push rdi
    push r8
    push r9
    push r10

    ; Get length of target name
    mov rsi, rdi
    call strlen
    mov r9, rax                  ; r9 = target length
    mov r8, rdi                  ; r8 = target pointer
    mov r10, [symbols_ptr]

    mov rcx, [symbol_count]
    test rcx, rcx
    jz .not_found

    xor rdi, rdi                  ; index
.loop:
    cmp rdi, rcx
    jge .not_found

    push rcx
    imul rcx, rdi, symbol_t_size
    lea rsi, [r10 + rcx]     ; rsi = symbol entry
    pop rcx

    ; Compare lengths first
    mov rax, [rsi + symbol_t.name_len]
    cmp rax, r9
    jne .next

    ; Compare strings byte-by-byte
    push rdi
    push rdx
    push rcx
    mov rsi, [rsi + symbol_t.name_ptr]  ; symbol name
    mov rdi, r8                         ; target name
    mov rdx, r9                         ; length
    call mem_eq
    pop rcx
    pop rdx
    pop rdi
    test rax, rax
    jnz .next                           ; not equal

    ; Found!
    imul rcx, rdi, symbol_t_size
    lea rsi, [r10 + rcx]
    mov rax, [rsi + symbol_t.offset]
    mov rbx, [rsi + symbol_t.type]
    mov rcx, [rsi + symbol_t.extra]
    ; Expose the pointee field array (arrays of struct pointers) so index
    ; handlers can chain `arr[i]->field` without a second lookup.
    push rax
    mov rax, [rsi + symbol_t.fields]
    mov [found_symbol_fields], rax
    pop rax

    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    ret

.next:
    inc rdi
    jmp .loop

.not_found:
    xor rax, rax
    xor rbx, rbx
    xor rcx, rcx
    mov qword [found_symbol_fields], 0
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    ret

; ================================================================
; add_global_symbol(name_ptr, name_len, type, extra)
; rdi=name_ptr, rsi=name_len, rcx=type, r8=extra
; ================================================================
add_global_symbol:
    push rdi
    push rsi
    push rcx
    push r8
    push rbx

    call ensure_global_symbol_capacity
    ; ensure_global_symbol_capacity calls heap_alloc_zero and mem_copy, which
    ; clobber caller-saved registers (rdi, rsi, rcx). Restore our inputs from
    ; the stack so the stored symbol data is not garbage.
    ; Stack layout after the 5 pushes above: [rsp]=rbx [rsp+8]=r8 [rsp+16]=rcx [rsp+24]=rsi [rsp+32]=rdi
    mov rdi, [rsp + 32]    ; name_ptr
    mov rsi, [rsp + 24]    ; name_len
    mov rcx, [rsp + 16]    ; type
    mov r8,  [rsp + 8]     ; extra

    mov rax, [global_symbol_count]
    mov r9, [global_symbols_ptr]

    imul rbx, rax, symbol_t_size
    lea rbx, [r9 + rbx]
    mov [rbx + symbol_t.name_ptr], rdi
    mov [rbx + symbol_t.name_len], rsi
    mov qword [rbx + symbol_t.offset], 0       ; offset not used for globals
    mov [rbx + symbol_t.type], rcx
    mov [rbx + symbol_t.extra], r8
    ; Pointee field array for arrays of struct pointers (0 otherwise).
    mov r9, [pending_symbol_fields]
    mov [rbx + symbol_t.fields], r9
    mov qword [pending_symbol_fields], 0

    inc qword [global_symbol_count]

.done:
    pop rbx
    pop r8
    pop rcx
    pop rsi
    pop rdi
    ret

; ================================================================
; find_global_symbol(name_ptr) -> rax=name_ptr, rbx=type, rcx=extra
; Returns rax=name_ptr (nonzero) if found, rax=0 if not found
; rdi = name_ptr (null-terminated)
; ================================================================
find_global_symbol:
    push rsi
    push rdi
    push r8
    push r9
    push r10

    mov rsi, rdi
    call strlen
    mov r9, rax                  ; r9 = target length
    mov r8, rdi                  ; r8 = target pointer
    mov r10, [global_symbols_ptr]

    mov rcx, [global_symbol_count]
    test rcx, rcx
    jz .not_found

    xor rdi, rdi                 ; index
.loop:
    cmp rdi, rcx
    jge .not_found

    push rcx
    imul rcx, rdi, symbol_t_size
    lea rsi, [r10 + rcx]
    pop rcx

    mov rax, [rsi + symbol_t.name_len]
    cmp rax, r9
    jne .next

    push rdi
    push rdx
    push rcx
    mov rsi, [rsi + symbol_t.name_ptr]
    mov rdi, r8
    mov rdx, r9
    call mem_eq
    pop rcx
    pop rdx
    pop rdi
    test rax, rax
    jnz .next

    ; Found!
    imul rcx, rdi, symbol_t_size
    lea rsi, [r10 + rcx]
    mov rax, [rsi + symbol_t.name_ptr]   ; rax = name_ptr
    mov rbx, [rsi + symbol_t.type]
    mov rcx, [rsi + symbol_t.extra]
    ; Expose the pointee field array (arrays of struct pointers) so index
    ; handlers can chain `arr[i]->field` without a second lookup.
    mov rax, [rsi + symbol_t.fields]
    mov [found_symbol_fields], rax
    mov rax, [rsi + symbol_t.name_ptr]   ; rax = name_ptr (restore)
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    ret

.next:
    inc rdi
    jmp .loop

.not_found:
    xor rax, rax
    xor rbx, rbx
    xor rcx, rcx
    mov qword [found_symbol_fields], 0
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    ret

; ================================================================
; register_func_return(name_ptr, return_type, field_array_ptr)
; Registers a function's return type info. If the function is already
; registered, updates its entry. Used to track struct-returning functions
; so gen_call can emit the hidden return-pointer argument.
; rdi = name_ptr (null-terminated)
; rsi = return_type (token like TOK_KW_STRUCT, TOK_KW_INT, etc.)
; rdx = field_array_ptr (for struct returns; 0 otherwise)
; ================================================================
register_func_return:
    push rbx
    push rcx
    push rdi
    push rsi
    push rdx

    call ensure_func_return_registry_capacity

    mov rdi, [rsp + 16]
    mov rsi, [rsp + 8]
    mov rdx, [rsp]

    ; Find next available slot (search for null entry)
    xor rbx, rbx
.rfr_find:
    cmp rbx, [func_return_registry_capacity]
    jae .rfr_done
    mov rcx, [func_registry_names_ptr]
    mov rax, [rcx + rbx * 8]
    test rax, rax
    jz .rfr_add
    inc rbx
    jmp .rfr_find

.rfr_add:
    mov rcx, [func_registry_names_ptr]
    mov [rcx + rbx * 8], rdi
    mov rcx, [func_registry_types_ptr]
    mov [rcx + rbx * 8], rsi
    mov rcx, [func_registry_fields_ptr]
    mov [rcx + rbx * 8], rdx

.rfr_done:
    pop rdx
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    ret

; ================================================================
; find_func_return(name_ptr) -> rax=return_type, rdx=field_array_ptr
; Returns rax=0 if function not found.
; rdi = name_ptr (null-terminated)
; ================================================================
find_func_return:
    push rbx
    push rcx
    push rsi
    push rdi

    ; Search until null entry or end of array (current registry capacity).
    ; Don't use func_registry_count because it's shared with the parser's
    ; register_func_name, which increments it without populating
    ; func_registry_names. Search until null to find valid entries.
    xor rbx, rbx
.ffr_loop:
    cmp rbx, [func_return_registry_capacity]
    jge .ffr_not_found
    mov rcx, [func_registry_names_ptr]
    mov rax, [rcx + rbx * 8]
    test rax, rax
    jz .ffr_not_found
    ; Inline string comparison (avoid mem_eq_str issues)
    push rcx
    push rdi
    push rbx
    mov rsi, rax
    xor r8, r8
.ffr_cmp:
    mov al, [rdi + r8]
    mov r9b, [rsi + r8]
    cmp al, r9b
    jne .ffr_nomatch
    test al, al
    jz .ffr_match
    inc r8
    jmp .ffr_cmp
.ffr_match:
    pop rbx
    pop rdi
    pop rcx
    xor rax, rax                   ; set ZF=1 for match
    jmp .ffr_check
.ffr_nomatch:
    pop rbx
    pop rdi
    pop rcx
    ; rax is non-zero (from cmp), so ZF=0
.ffr_check:
    test rax, rax
    jz .ffr_found
    inc rbx
    jmp .ffr_loop

.ffr_found:
    mov rcx, [func_registry_types_ptr]
    mov rax, [rcx + rbx * 8]
    mov rcx, [func_registry_fields_ptr]
    mov rdx, [rcx + rbx * 8]
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

.ffr_not_found:
    xor rax, rax
    xor rdx, rdx
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; ================================================================
; find_func_field_array_ptr(name_ptr) -> rax = field_array_ptr (or 0)
; Looks up a function in the parser's func_name_registry and returns its
; field_array_ptr from func_field_array_ptrs. Used by gen_function to
; set current_func_return_fields for struct-returning functions.
; rdi = name_ptr (null-terminated)
; ================================================================
extern func_name_registry
extern func_field_array_ptrs
find_func_field_array_ptr:
    push rbx
    push rcx
    push rsi
    push rdi

    mov rcx, [func_registry_count]
    test rcx, rcx
    jz .ffap_not_found
    xor rbx, rbx
.ffap_loop:
    cmp rbx, rcx
    jge .ffap_not_found
    mov rdx, [func_name_registry]
    mov rax, [rdx + rbx * 8]
    test rax, rax
    jz .ffap_next
    push rcx
    push rdi
    push rbx
    mov rsi, rax
    call mem_eq_str
    pop rbx
    pop rdi
    pop rcx
    test rax, rax
    jz .ffap_found
.ffap_next:
    inc rbx
    jmp .ffap_loop

.ffap_found:
    mov rdx, [func_field_array_ptrs]
    mov rax, [rdx + rbx * 8]
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

.ffap_not_found:
    xor rax, rax
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; ================================================================
; find_symbol_index(name_ptr) -> rax = index (or -1 if not found)
; Returns just the symbol table index, without touching other fields.
; Used by the warning system for initialized-tracking.
; ================================================================
find_symbol_index:
    push rsi
    push rdi
    push r8
    push r9
    push rcx
    push r10

    mov rsi, rdi
    call strlen
    mov r9, rax
    mov r8, rdi
    mov r10, [symbols_ptr]

    mov rcx, [symbol_count]
    test rcx, rcx
    jz .fsi_not_found

    xor rdi, rdi
.fsi_loop:
    cmp rdi, rcx
    jge .fsi_not_found

    push rcx
    imul rcx, rdi, symbol_t_size
    lea rsi, [r10 + rcx]
    pop rcx

    mov rax, [rsi + symbol_t.name_len]
    cmp rax, r9
    jne .fsi_next

    push rdi
    push rdx
    push rcx
    mov rsi, [rsi + symbol_t.name_ptr]
    mov rdi, r8
    mov rdx, r9
    call mem_eq
    pop rcx
    pop rdx
    pop rdi
    test rax, rax
    jnz .fsi_next

    ; Found — return index in rax
    mov rax, rdi
    pop r10
    pop rcx
    pop r9
    pop r8
    pop rdi
    pop rsi
    ret
.fsi_next:
    inc rdi
    jmp .fsi_loop
.fsi_not_found:
    mov rax, -1
    pop r10
    pop rcx
    pop r9
    pop r8
    pop rdi
    pop rsi
    ret

; ================================================================
; find_global_symbol_index(name_ptr) -> rax = index (or -1 if not found)
; Same as find_symbol_index but searches global_symbols.
; ================================================================
find_global_symbol_index:
    push rsi
    push rdi
    push r8
    push r9
    push rcx
    push r10

    mov rsi, rdi
    call strlen
    mov r9, rax
    mov r8, rdi
    mov r10, [global_symbols_ptr]

    mov rcx, [global_symbol_count]
    test rcx, rcx
    jz .fgsi_not_found

    xor rdi, rdi
.fgsi_loop:
    cmp rdi, rcx
    jge .fgsi_not_found

    push rcx
    imul rcx, rdi, symbol_t_size
    lea rsi, [r10 + rcx]
    pop rcx

    mov rax, [rsi + symbol_t.name_len]
    cmp rax, r9
    jne .fgsi_next

    push rdi
    push rdx
    push rcx
    mov rsi, [rsi + symbol_t.name_ptr]
    mov rdi, r8
    mov rdx, r9
    call mem_eq
    pop rcx
    pop rdx
    pop rdi
    test rax, rax
    jnz .fgsi_next

    mov rax, rdi
    pop r10
    pop rcx
    pop r9
    pop r8
    pop rdi
    pop rsi
    ret
.fgsi_next:
    inc rdi
    jmp .fgsi_loop
.fgsi_not_found:
    mov rax, -1
    pop r10
    pop rcx
    pop r9
    pop r8
    pop rdi
    pop rsi
    ret

; ================================================================
; emit_global_vars(rdi = global_var_count, rsi = global_var_array)
; Emits BSS section with global variable labels
; ================================================================
emit_global_vars:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r14, rdi                 ; r14 = count
    mov r15, rsi                 ; r15 = array

    test r14, r14
    jz .ev_done

    ; Reset global symbol count
    xor rax, rax
    mov [global_symbol_count], rax

    ; ---- Pass 1: Emit initialized globals in .data ----
    ; For each global, emit initialized vars in .data, uninitialized in .bss.
    ; Since a given var is either .data or .bss, we must track section state.
    xor r12, r12
    xor rbx, rbx                 ; rbx = 0: no section emitted yet; 1: .data emitted; 2: .bss emitted
.data_loop:
    cmp r12, r14
    jge .ev_done
    mov rax, [prog_global_source_array]
    test rax, rax
    jz .data_source_ready
    mov rdx, [rax + 8 + r12 * 8]
    mov [source_path], rdx
.data_source_ready:
    mov r13, [r15 + 8 + r12 * 8]
    test r13, r13
    jz .data_next
    mov rax, [r13 + ast_node_t.type]

     cmp rax, AST_VAR_DECL
     je .data_var
     cmp rax, AST_ARRAY_DECL
     je .data_array_decl_node
     cmp rax, AST_STRUCT_DEF
     jne .data_next
     ; AST_STRUCT_DEF — check if it has an initializer
     cmp qword [r13 + ast_node_t.data4], 0
     je .data_struct_no_init           ; no init → .bss
     ; Has init — emit in .data section
     cmp rbx, 1
     je .data_struct_init
     cmp rbx, 2
     je .data_struct_switch_data
     ; rbx=0: no section yet, emit .data
     mov rsi, asm_section_data
     call emit_string
     mov rbx, 1
     jmp .data_struct_init
.data_struct_switch_data:
     ; .bss was emitted — need to switch to .data
     mov rsi, asm_section_data
     call emit_string
     mov rbx, 1
.data_struct_init:
     jmp .data_struct_init_node
.data_struct_no_init:
     ; Non-VAR_DECL (struct) — emit in .bss
     cmp rbx, 2
     je .data_bss_known
     cmp rbx, 1
     jne .data_emit_bss
     ; rbx=1: .data was emitted but .bss was not — switch now
     mov rsi, asm_section_bss
     call emit_string
     mov rbx, 2
     jmp .data_emit_bss_node
.data_bss_known:
    ; Already emitted .bss, just emit the node
    jmp .data_emit_bss_node
.data_emit_bss:
    mov rsi, asm_section_bss
    call emit_string
    mov rbx, 2
    jmp .data_emit_bss_node

.data_var:
    ; Check if struct pointer type (data4 holds field_array_ptr, data3 holds init)
    mov rax, [r13 + ast_node_t.data1]
    cmp rax, PTR_TYPE_FLAG
    jb .data_var_check_init                ; not a pointer type → normal init check
    push rax
    sub rax, PTR_TYPE_FLAG
    cmp rax, TOK_KW_STRUCT
    pop rax
    jne .data_var_check_init               ; non-struct pointer → normal init check
    ; Struct pointer — check if init is present (data3)
    cmp qword [r13 + ast_node_t.data3], 0
    je .data_var_bss                       ; no init → BSS
    jmp .data_var_check_init                ; has init → generate init code
.data_var_check_init:
    cmp qword [r13 + ast_node_t.data4], 1
    je .data_extern                 ; emit extern declaration
    cmp qword [r13 + ast_node_t.data3], 0
    je .data_var_bss

    ; Initialized var — emit in .data section
    cmp rbx, 1
    je .data_emit_init
    ; Need to emit .data header first
    mov rsi, asm_section_data
    call emit_string
    mov rbx, 1
.data_emit_init:
    call .emit_data_var
    jmp .data_next

.data_extern:
    ; Emit "extern g_<name>" for extern declarations
    ; Strip "g_" prefix if name starts with it (prevents g_g_argc)
    mov rsi, asm_extern
    call emit_string
    mov rsi, [r13 + ast_node_t.data2]
    call emit_global_name
    mov rsi, asm_newline
    call emit_string
    jmp .data_next

.data_var_bss:
    ; Uninitialized var — emit in .bss
    cmp rbx, 2
    je .data_emit_bss_node
    cmp rbx, 1
    jne .data_emit_bss
    ; .data was emitted before — need to switch to .bss now
    mov rsi, asm_section_bss
    call emit_string
    mov rbx, 2
.data_emit_bss_node:
    ; Emit uninitialized var/array/struct in .bss
    mov rax, [r13 + ast_node_t.type]
    cmp rax, AST_VAR_DECL
    je .data_var_bss_node
    cmp rax, AST_ARRAY_DECL
    je .data_array_bss_node
    cmp rax, AST_STRUCT_DEF
    je .data_struct_bss_node
    jmp .data_next

.data_var_bss_node:
    ; Uninitialized scalar in .bss
    mov rsi, asm_label_g_prefix
    call emit_string
    mov rsi, [r13 + ast_node_t.data2]
    call emit_global_name
    mov rsi, asm_label_sep
    call emit_string
    mov rax, [r13 + ast_node_t.data1]
    cmp rax, TOK_KW_CHAR
    je .data_var_bss_char
    mov rsi, asm_resq
    call emit_string
    mov rdi, 1
    call emit_int
    mov rsi, asm_newline
    call emit_string
    jmp .data_reg_var

.data_var_bss_char:
    mov rsi, asm_resb
    call emit_string
    mov rdi, 1
    call emit_int
    mov rsi, asm_newline
    call emit_string
    jmp .data_reg_var

.data_reg_var:
    mov rdi, [r13 + ast_node_t.data2]
    push rdi
    mov rsi, rdi
    call strlen
    mov rsi, rax
    pop rdi
    mov rcx, [r13 + ast_node_t.data1]
    ; Check if struct pointer: set extra = field_array_ptr from data4
    xor r8, r8
    cmp rcx, PTR_TYPE_FLAG
    jb .drv_no_fields
    mov rax, rcx
    sub rax, PTR_TYPE_FLAG
    cmp rax, TOK_KW_STRUCT
    jne .drv_no_fields
    mov rax, [r13 + ast_node_t.data4]
    test rax, rax
    jz .drv_no_fields
    mov r8, rax
.drv_no_fields:
    call add_global_symbol
    jmp .data_next

.data_array_decl_node:
    ; Check if array has init list (data4 != 0) and is non-struct (type is INT or CHAR)
    mov rax, [r13 + ast_node_t.data1]  ; rax = type
    cmp rax, TOK_KW_INT
    je .dadi_check_init
    cmp rax, TOK_KW_CHAR
    je .dadi_check_init
    ; Struct array — emit in .bss
    cmp rbx, 2
    je .data_bss_known
    cmp rbx, 1
    jne .dadi_emit_bss
    mov rsi, asm_section_bss
    call emit_string
    mov rbx, 2
    jmp .data_array_bss_node
.dadi_emit_bss:
    mov rsi, asm_section_bss
    call emit_string
    mov rbx, 2
    jmp .data_array_bss_node
.dadi_check_init:
    cmp qword [r13 + ast_node_t.data4], 0
    je .dadi_go_bss                    ; no init → .bss
    cmp qword [r13 + ast_node_t.data4], 1
    je .dadi_extern                    ; extern array → emit extern
    ; Has init — ensure .data section is active
    cmp rbx, 1
    je .dadi_emit_init                 ; already in .data
    cmp rbx, 0
    jne .dadi_switch_data              ; in .bss, need to switch
    ; rbx=0: no section yet, emit .data
    mov rsi, asm_section_data
    call emit_string
    mov rbx, 1
.dadi_switch_data:
.dadi_emit_init:
    jmp .data_array_init
.dadi_extern:
    ; Emit "extern g_<name>" for extern arrays
    ; Strip "g_" prefix if name starts with it (prevents g_g_argc)
    mov rsi, asm_extern
    call emit_string
    mov rsi, [r13 + ast_node_t.data2]
    call emit_global_name
    mov rsi, asm_newline
    call emit_string
    jmp .data_next
.dadi_go_bss:
    cmp rbx, 2
    je .data_array_bss_node
    cmp rbx, 1
    jne .dadi_go_bss_first
    mov rsi, asm_section_bss
    call emit_string
    mov rbx, 2
    jmp .data_array_bss_node
.dadi_go_bss_first:
    mov rsi, asm_section_bss
    call emit_string
    mov rbx, 2
    jmp .data_array_bss_node

.data_array_bss_node:
    cmp qword [r13 + ast_node_t.data4], 1
    je .data_next                   ; skip extern arrays (no storage)
    mov rsi, asm_label_g_prefix
    call emit_string
    mov rsi, [r13 + ast_node_t.data2]
    call emit_global_name
    mov rsi, asm_label_sep
    call emit_string
    mov rax, [r13 + ast_node_t.data1]
    mov r8, [r13 + ast_node_t.data3]
    xor r9, r9
    ; Pointer-type array (char* arr[N], struct Name* arr[N], char** arr[N]):
    ; each element is an 8-byte pointer. Normalize to TOK_KW_INT so the
    ; existing resq/count path and INT symbol registration handle it
    ; (matches register_globals' .array_ptr handling). Without this, a
    ; pointer-typed array (type = TOK_KW_CHAR + PTR_TYPE_FLAG, etc.) is
    ; neither TOK_KW_INT nor TOK_KW_CHAR and falls through to the struct
    ; path, emitting resb (type_encoding * count) — a wildly wrong size.
    cmp rax, PTR_TYPE_FLAG
    jb .dabn_check_struct_kind
    mov rdx, rax
    sub rdx, PTR_TYPE_FLAG
    cmp rdx, TOK_KW_STRUCT
    jne .dabn_normalize_ptr_array
    ; For struct-pointer arrays, data4 is the field metadata pointer, not
    ; an initializer list. Remember that before normalizing the element type.
    mov r9, 1
.dabn_normalize_ptr_array:
    mov rax, TOK_KW_INT
    jmp .array_not_struct
.dabn_check_struct_kind:
    ; Check if struct array by type (data1 is not a standard type token)
    cmp rax, TOK_KW_INT
    je .array_not_struct
    cmp rax, TOK_KW_CHAR
    je .array_not_struct
    jmp .dabn_struct
.array_not_struct:
    ; Check if has init list
    test r9, r9
    jnz .array_bss_no_init
    cmp qword [r13 + ast_node_t.data4], 0
    jne .data_array_init
.array_bss_no_init:
    cmp rax, TOK_KW_CHAR
    je .data_array_bss_char
    mov rsi, asm_resq
    call emit_string
    mov rdi, r8
    call emit_int
    mov rsi, asm_newline
    call emit_string
    mov rdi, [r13 + ast_node_t.data2]
    push rdi
    mov rsi, rdi
    call strlen
    mov rsi, rax
    pop rdi
    mov rcx, TOK_KW_INT
    ; --- 2D array: pack dim2 into extra before add_global_symbol ---
    call pack_2d_extra                ; r8 = packed extra (dim1 | dim2<<32)
    ; --- end 2D array ---
    call add_global_symbol
    jmp .data_next
.data_array_bss_char:
    mov rsi, asm_resb
    call emit_string
    mov rdi, r8
    call emit_int
    mov rsi, asm_newline
    call emit_string
    mov rdi, [r13 + ast_node_t.data2]
    push rdi
    mov rsi, rdi
    call strlen
    mov rsi, rax
    pop rdi
    mov rcx, TOK_KW_CHAR
    ; --- 2D array: pack dim2 into extra before add_global_symbol ---
    call pack_2d_extra                ; r8 = packed extra (dim1 | dim2<<32)
    ; --- end 2D array ---
    call add_global_symbol
    jmp .data_next
.data_array_init:
    ; Global array with init list — emit .data with initial values
    push r12
    push r14
    push r15
    ; Emit label
    mov rsi, asm_label_g_prefix
    call emit_string
    mov rsi, [r13 + ast_node_t.data2]
    call emit_global_name
    mov rsi, asm_label_sep
    call emit_string
    mov r15, [r13 + ast_node_t.data4]  ; r15 = init list (AST_INIT_LIST*)
    mov r14, [r13 + ast_node_t.data1]  ; r14 = element type (TOK_KW_INT or TOK_KW_CHAR)
    mov r12, [r13 + ast_node_t.data3]  ; r12 = element count
    ; Pointer-type array with init list: normalize element type to TOK_KW_INT
    ; so the dq emission (8 bytes/elem) and INT registration stay consistent
    ; with register_globals and the .bss path above.
    cmp r14, PTR_TYPE_FLAG
    jb .dai_type_set
    mov r14, TOK_KW_INT
.dai_type_set:
    mov r11, [r15 + ast_node_t.data1]  ; r11 = init count
    mov r10, [r15 + ast_node_t.data2]  ; r10 = init array ptr
    xor r9, r9                          ; r9 = current index
.dai_emit_loop:
    cmp r9, r12
    jge .dai_emit_done
    cmp r9, r11
    jge .dai_emit_zero
    ; Emit init value from init list
    mov rdi, [r10 + 8 + r9 * 8]            ; rdi = init expression node (skip 8-byte header)
    test rdi, rdi
    jz .dai_emit_zero
    mov rax, [rdi + ast_node_t.type]
    cmp rax, AST_NUMBER
    je .dai_number
    cmp rax, AST_CHAR
    je .dai_char
    jmp .dai_emit_zero
.dai_number:
    mov rdi, [rdi + ast_node_t.data1]  ; rdi = number value
    jmp .dai_emit_value
.dai_char:
    mov rdi, [rdi + ast_node_t.data1]  ; rdi = char value
    jmp .dai_emit_value
.dai_emit_zero:
    xor rdi, rdi
.dai_emit_value:
    ; Emit dq/db directive with value
    push rdi                        ; save number value (emit_string clobbers rdi)
    push r9
    push r10
    push r11
    push r12
    push r14
    push r15
    cmp r14, TOK_KW_CHAR
    je .dai_emit_byte
    mov rsi, asm_dq_dir
    call emit_string
    jmp .dai_emit_int2
.dai_emit_byte:
    mov rsi, asm_db_dir
    call emit_string
.dai_emit_int2:
    pop r15
    pop r14
    pop r12
    pop r11
    pop r10
    pop r9
    pop rdi                         ; restore number value
    call emit_int
    mov rsi, asm_newline
    call emit_string
.dai_emit_continue:
    inc r9
    jmp .dai_emit_loop
.dai_emit_done:
    ; Register as global symbol
    mov rdi, [r13 + ast_node_t.data2]
    push rdi
    mov rsi, rdi
    call strlen
    mov rsi, rax
    pop rdi
    mov rcx, r14
    call add_global_symbol
    pop r15
    pop r14
    pop r12
    jmp .data_next

; ================================================================
; .data_struct_init_node: Global struct with init list — emit .data with
; initial values. Handles both sequential init ({a, b}) and designated
; init ({.x = 10, .y = 20}).
; r13 = AST_STRUCT_DEF node
; ================================================================
.data_struct_init_node:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8                            ; local slot for init count

    ; Emit label "g_name:"
    mov rsi, asm_label_g_prefix
    call emit_string
    mov rsi, [r13 + ast_node_t.data3]  ; var name
    call emit_global_name
    mov rsi, asm_label_sep
    call emit_string

    mov r14, [r13 + ast_node_t.data2]  ; r14 = field_array_ptr
    mov r12, [r14]                      ; r12 = field count
    mov r15, [r13 + ast_node_t.data4]  ; r15 = init list (AST_INIT_LIST*)
    test r15, r15
    jz .dsin_emit_zero_pad
    mov rax, [r15 + ast_node_t.data1]
    mov [rsp], rax                      ; save init count to local slot
    mov r15, [r15 + ast_node_t.data2]  ; r15 = init_array ptr

    ; Iterate over all init entries
    xor r9, r9                          ; r9 = init index
.dsin_init_loop:
    cmp r9, [rsp]                       ; compare with init count
    jge .dsin_emit_done
    mov rax, [r15 + r9 * 8]            ; rax = init node
    test rax, rax
    jz .dsin_init_next

    cmp qword [rax], AST_DESIGNATED_INIT
    jne .dsin_sequential_init

    ; --- Designated init: emit at stored byte offset ---
    mov r8, [rax + ast_node_t.data1]   ; r8 = byte offset
    mov rdi, [rax + ast_node_t.data2]  ; rdi = value expr
    jmp .dsin_emit_val

.dsin_sequential_init:
    ; --- Sequential init: find field at this index ---
    cmp r9, r12
    jge .dsin_init_next                 ; no field at this index, skip
    imul r10, r9, 32
    lea r10, [r14 + 8 + r10]            ; r10 = field descriptor
    mov r8, [r10 + 8]                    ; r8 = field byte offset
    mov rcx, [r10 + 16]                  ; rcx = field type (may include FIELD_CONST_FLAG)
    test rcx, FIELD_CONST_FLAG
    jz .dsin_type_clean
    sub rcx, FIELD_CONST_FLAG
.dsin_type_clean:
    mov rdi, rax                        ; rdi = value expr

.dsin_emit_val:
    ; Check expression type
    mov rax, [rdi + ast_node_t.type]
    cmp rax, AST_NUMBER
    je .dsin_number
    cmp rax, AST_CHAR
    je .dsin_char
    jmp .dsin_emit_zero

.dsin_number:
    mov rdi, [rdi + ast_node_t.data1]   ; rdi = number value
    jmp .dsin_emit_dq

.dsin_char:
    mov rdi, [rdi + ast_node_t.data1]   ; rdi = char value
    cmp rcx, TOK_KW_CHAR
    je .dsin_emit_db
    jmp .dsin_emit_dq

.dsin_emit_zero:
    xor rdi, rdi

.dsin_emit_dq:
    push rdi
    push r9
    mov rsi, asm_dq_dir
    call emit_string
    pop r9
    pop rdi
    call emit_int
    mov rsi, asm_newline
    call emit_string
    jmp .dsin_init_next

.dsin_emit_db:
    push rdi
    push r9
    mov rsi, asm_db_dir
    call emit_string
    pop r9
    pop rdi
    call emit_int
    mov rsi, asm_newline
    call emit_string

.dsin_init_next:
    inc r9
    jmp .dsin_init_loop

.dsin_emit_zero_pad:
    ; No init at all — emit zeros for all fields
    xor r9, r9
    mov rdi, 0
.dsin_pad_loop:
    cmp r9, r12
    jge .dsin_emit_done
    mov rsi, asm_dq_dir
    call emit_string
    call emit_int
    mov rsi, asm_newline
    call emit_string
    inc r9
    jmp .dsin_pad_loop

.dsin_emit_done:
    ; Register as global symbol
    mov rdi, [r13 + ast_node_t.data3]
    push rdi
    mov rsi, rdi
    call strlen
    mov rsi, rax
    pop rdi
    mov rcx, TOK_KW_STRUCT
    mov r8, [r13 + ast_node_t.data2]   ; field_array_ptr
    call add_global_symbol
    add rsp, 8                          ; pop local slot
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    jmp .data_next

.dabn_struct:
    ; Struct array: resb (struct_size * element_count)
    ; rax = struct_size (from data1), r8 = element_count (from data3)
    ; Compute total_size = struct_size * element_count
    push rax
    push r8
    push rdx
    push rcx
    mov rdx, rax              ; rdx = struct_size
    mov rcx, r8               ; rcx = element_count
    xor rdi, rdi              ; rdi = 0 (accumulator)
.dabn_mul_loop:
    test rcx, rcx
    jz .dabn_mul_done
    add rdi, rdx
    dec rcx
    jmp .dabn_mul_loop
.dabn_mul_done:
    ; rdi = total_size
    mov rsi, asm_resb
    push rdi                  ; save total_size (emit_string clobbers rdi)
    call emit_string
    pop rdi                   ; restore total_size
    call emit_int             ; emit total_size
    mov rsi, asm_newline
    call emit_string
    pop rcx
    pop rdx
    pop r8
    pop rax
    ; Register with type=TOK_KW_STRUCT, extra = field_array_ptr (data4)
    mov rdi, [r13 + ast_node_t.data2]
    push rdi
    mov rsi, rdi
    call strlen
    mov rsi, rax
    pop rdi
    mov rcx, TOK_KW_STRUCT
    mov r8, [r13 + ast_node_t.data4]   ; field_array_ptr as extra
    call add_global_symbol
    jmp .data_next

.data_struct_bss_node:
    mov rsi, asm_label_g_prefix
    call emit_string
    mov rsi, [r13 + ast_node_t.data3]
    call emit_global_name
    mov rsi, asm_label_sep
    call emit_string
    mov rdi, [r13 + ast_node_t.data1]
    mov rsi, asm_resb
    call emit_string
    mov rdi, [r13 + ast_node_t.data1]
    call emit_int
    mov rsi, asm_newline
    call emit_string
    mov rdi, [r13 + ast_node_t.data3]
    push rdi
    mov rsi, rdi
    call strlen
    mov rsi, rax
    pop rdi
    mov rcx, TOK_KW_STRUCT
    mov r8, [r13 + ast_node_t.data2]
    call add_global_symbol
    jmp .data_next

.data_next:
    inc r12
    jmp .data_loop

.ev_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; --------------- Helper: emit a .data initialized var ---------------
.emit_data_var:
    push rbx
    push r12
    push r13

    mov rbx, r13                    ; rbx = AST_VAR_DECL node (saved across calls)

    ; Emit "g_name:"
    mov rsi, asm_label_g_prefix
    call emit_string
    mov rsi, [rbx + ast_node_t.data2]
    call emit_global_name
    mov rsi, asm_label_sep
    call emit_string

    ; Get init expression
    mov r12, [rbx + ast_node_t.data3]  ; r12 = init AST node
    test r12, r12
    jz .edv_done

    mov rax, [r12 + ast_node_t.type]
    cmp rax, AST_NUMBER
    je .edv_number
    cmp rax, AST_CHAR
    je .edv_char
    cmp rax, AST_STRING
    je .edv_string
    ; Unknown init type — emit zero
    mov rsi, asm_dq_dir
    call emit_string
    mov rdi, 0
    call emit_int
    mov rsi, asm_newline
    call emit_string
    jmp .edv_register

.edv_string:
    ; String-literal initializer for a char* global: add the string to the
    ; string pool (so gen_rodata emits LC<N>: db ...), then emit
    ; `dq LC<N>` here — the address of the string in .rodata. Mirrors the
    ; .string handler in gen_expr but writes a dq directive instead of a
    ; lea. r14/r15 are the data-emission loop's count/array registers, so
    ; they MUST be preserved across this block; we save them here and
    ; restore before jumping to .edv_register. r12 (init AST node) is
    ; callee-saved and survives all calls below.
    push r14
    push r15
    ; Defensive: a string literal always carries a non-null pointer.
    mov rdi, [r12 + ast_node_t.data1]
    test rdi, rdi
    jz .edv_string_zero
    ; Pool index = string_count (pre-increment). Grow the pool if full.
    mov r14, [string_count]
    cmp r14, [string_pool_capacity]
    jb .edv_string_store
    call string_pool_grow
.edv_string_store:
    ; Reload ptr/len from the AST node (string_pool_grow clobbers caller-saved
    ; regs; r12 is intact and r14 survives as callee-saved).
    mov rdi, [r12 + ast_node_t.data1]
    mov r15, [r12 + ast_node_t.data2]
    ; string_pool_ptr[r14] = {ptr, len}
    mov rax, r14
    shl rax, 4
    add rax, [string_pool_ptr]
    mov [rax], rdi
    mov [rax + 8], r15
    inc qword [string_count]
    ; emit "    dq LC" + r14 + newline
    mov rsi, asm_dq_dir
    call emit_string
    mov rsi, asm_label_lc
    call emit_string
    mov rdi, r14
    call emit_int
    mov rsi, asm_newline
    call emit_string
    pop r15
    pop r14
    jmp .edv_register
.edv_string_zero:
    ; null string pointer — emit dq 0
    mov rsi, asm_dq_dir
    call emit_string
    mov rdi, 0
    call emit_int
    mov rsi, asm_newline
    call emit_string
    pop r15
    pop r14
    jmp .edv_register

.edv_number:
    mov rax, [rbx + ast_node_t.data1]   ; type
    cmp rax, TOK_KW_CHAR
    je .edv_number_char
    mov rsi, asm_dq_dir
    call emit_string
    mov rdi, [r12 + ast_node_t.data1]   ; value
    call emit_int
    mov rsi, asm_newline
    call emit_string
    jmp .edv_register

.edv_number_char:
    mov rsi, asm_db_dir
    call emit_string
    mov rdi, [r12 + ast_node_t.data1]
    call emit_int
    mov rsi, asm_newline
    call emit_string
    jmp .edv_register

.edv_char:
    mov rsi, asm_db_dir
    call emit_string
    mov rdi, [r12 + ast_node_t.data1]
    call emit_int
    mov rsi, asm_newline
    call emit_string

.edv_register:
    ; Register as global symbol
    mov rdi, [rbx + ast_node_t.data2]
    push rdi
    mov rsi, rdi
    call strlen
    mov rsi, rax
    pop rdi
    mov rcx, [rbx + ast_node_t.data1]
    ; Check if struct pointer: set extra = field_array_ptr from data4
    xor r8, r8
    cmp rcx, PTR_TYPE_FLAG
    jb .edvr_not_struct_ptr
    mov rax, rcx
    sub rax, PTR_TYPE_FLAG
    cmp rax, TOK_KW_STRUCT
    jne .edvr_not_struct_ptr
    mov rax, [rbx + ast_node_t.data4]
    test rax, rax
    jz .edvr_not_struct_ptr
    mov r8, rax
.edvr_not_struct_ptr:
    mov rax, [global_symbol_count]    ; save index for new global symbol
    push rax
    call add_global_symbol
    pop rax                           ; rax = index of new global symbol
    mov r10, [global_symbol_const_ptr] ; r10 = const-bytes base (volatile, safe here)
    ; Check const flag from AST node data4
    mov rcx, [rbx + ast_node_t.data4]
    test rcx, VAR_CONST
    jz .edvr_not_const
    mov byte [r10 + rax], 1
    jmp .edv_done
.edvr_not_const:
    mov byte [r10 + rax], 0
.edv_done:
    pop r13
    pop r12
    pop rbx
    ret

; ================================================================
; mem_eq: compare two byte sequences
; rsi=ptr1, rdi=ptr2, rcx=length
; returns: rax=0 if equal, 1 if different
; ================================================================
mem_eq:
    mov rcx, rdx            ; length is passed in rdx (ABI convention)
    test rcx, rcx
    jz .equal
.loop:
    mov al, [rsi]
    mov bl, [rdi]
    cmp al, bl
    jne .diff
    inc rsi
    inc rdi
    dec rcx
    jnz .loop
.equal:
    xor rax, rax
    ret
.diff:
    mov rax, 1
    ret

; ================================================================
; gen_block(rdi = AST_BLOCK*)
; ================================================================
gen_block:
    PROLOGUE r14, r13, r12, rbx

    mov r12, rdi
    mov r14, [r12 + ast_node_t.data1]   ; stmt count
    mov r13, [r12 + ast_node_t.data2]   ; stmt array

    xor rbx, rbx
.loop:
    cmp rbx, r14
    jge .done
    mov rdi, [r13 + 8 + rbx * 8]
    test rdi, rdi
    jz .next
    call gen_stmt
.next:
    inc rbx
    jmp .loop
.done:
    ; Reset terminator flag (block may or may not always terminate)
    mov qword [last_stmt_terminator], 0
    EPILOGUE r14, r13, r12, rbx

; ================================================================
; gen_stmt(rdi = AST node*)
; ================================================================
gen_stmt:
    PROLOGUE r13, r12

    mov r12, rdi
    mov rax, [r12 + ast_node_t.type]

    ; Warning: dead code (unreachable statement after terminator)
    ; Skip the check for AST_RETURN/AST_BREAK/AST_CONTINUE themselves — those are terminators
    cmp rax, AST_RETURN
    je .skip_dead_code
    cmp rax, AST_BREAK
    je .skip_dead_code
    cmp rax, AST_CONTINUE
    je .skip_dead_code
    cmp qword [last_stmt_terminator], 0
    je .skip_dead_code
    ; Reset the flag so we only warn once per dead block
    mov qword [last_stmt_terminator], 0
    push rax
    mov r8, [r12 + ast_node_t.line]
    mov r9, [r12 + ast_node_t.column]
    mov rdi, WARN_DEAD_CODE
    mov rsi, r8
    mov rdx, r9
    mov rcx, msg_warn_dead_code
    call warn_at
    pop rax
    ; Skip codegen for dead code to avoid crashes from invalid references
    EPILOGUE r13, r12
    ret
.skip_dead_code:

    cmp rax, AST_VAR_DECL
    je .var_decl
    cmp rax, AST_RETURN
    je .ret_stmt
    cmp rax, AST_IF
    je .if_stmt
    cmp rax, AST_WHILE
    je .while_stmt
    cmp rax, AST_FOR
    je .for_stmt
    cmp rax, AST_BLOCK
    je .block
    cmp rax, AST_ASSIGN
    je .assign
    cmp rax, AST_CALL
    je .call
    cmp rax, AST_ARRAY_DECL
    je .array_decl
    cmp rax, AST_BREAK
    je .break_stmt
    cmp rax, AST_CONTINUE
    je .continue_stmt
    cmp rax, AST_STRUCT_DEF
    je .struct_def_stmt
    ; Expression statement (evaluate, discard)
    jmp .expr

.var_decl:
    call gen_var_decl
    jmp .done
.array_decl:
    ; VLA: data5 has VLA_FLAG → data3 is a size expression AST*.
    ; Emit runtime stack allocation: evaluate size, store count, sub rsp,
    ; store base pointer into the frame slot reserved by collect_symbols.
    mov rax, [r12 + ast_node_t.data5]
    test rax, VLA_FLAG
    jz .array_fixed
    push rbx
    push r14
    push r15
    ; Look up the symbol to get the frame offset (base ptr slot).
    mov rdi, [r12 + ast_node_t.data2]  ; name_ptr
    call find_symbol
    test rax, rax
    jz .array_vla_done
    ; rax = negative offset of base-ptr slot; rbx = type, rcx = extra (-1)
    mov r14, rax                      ; r14 = base-ptr negative offset
    ; Evaluate the size expression → rax = element count.
    mov rdi, [r12 + ast_node_t.data3]  ; size expression AST*
    call gen_expr
    ; Store element count into [rbp + r14 + 8] (less-negative half of the slot;
    ; base ptr is at the more-negative end [rbp + r14]). r14 is negative.
    mov rsi, asm_mov_qword_rbp
    call emit_string
    ; Emit the positive offset of the count slot = |base_off| - 8.
    mov rdi, r14
    add rdi, 8                        ; r14 is negative; +8 → less negative
    neg rdi                           ; positive offset for emit_int
    call emit_int
    mov rsi, asm_rbp_rax
    call emit_string
    ; bytes = count * elem_size (1 for char, 8 for int/ptr).
    mov rbx, [r12 + ast_node_t.data1]  ; element type
    cmp rbx, TOK_KW_CHAR
    je .array_vla_no_scale
    ; imul rax, 8
    mov rsi, asm_imul_rax_8
    call emit_string
.array_vla_no_scale:
    ; Align up to 16: add rax, 15; and rax, -16
    mov rsi, asm_add_rax_15
    call emit_string
    mov rsi, asm_and_rax_neg16
    call emit_string
    ; sub rsp, rax
    mov rsi, asm_sub_rsp_rax
    call emit_string
    ; Store rsp as base pointer: mov qword [rbp+base_off], rsp
    mov rsi, asm_mov_qword_rbp_rsp
    call emit_string
    mov rdi, r14
    neg rdi
    call emit_int
    mov rsi, asm_rbp_rsp
    call emit_string
.array_vla_done:
    pop r15
    pop r14
    pop rbx
    jmp .nop_stmt

.array_fixed:
    ; Check for array initializer list
    mov rax, [r12 + ast_node_t.data4]  ; rax = init list (or 0/1 for struct/extern)
    test rax, rax
    jz .nop_stmt
    cmp rax, 1
    je .nop_stmt                        ; extern arrays (data4=1) have no init
    ; Check if struct array (data4 is field_array_ptr, not init list)
    mov rax, [r12 + ast_node_t.data1]  ; rax = type
    cmp rax, TOK_KW_INT
    je .array_has_init
    cmp rax, TOK_KW_CHAR
    je .array_has_init
    jmp .nop_stmt                      ; struct array, no inline init
.array_has_init:
    ; Local array with init list — find symbol and emit init code
    push rbx
    push r14
    push r15
    mov rdi, [r12 + ast_node_t.data2]  ; name_ptr
    call find_symbol
    ; rax = negative offset, rbx = type, rcx = extra (element count)
    test rax, rax
    jz .array_decl_done
    mov r14, [r12 + ast_node_t.data1]  ; r14 = element type
    mov r15, [r12 + ast_node_t.data3]  ; r15 = element count
    mov rcx, [r12 + ast_node_t.data4]  ; rcx = init list (AST_INIT_LIST*)
    mov rdi, rax
    neg rdi                            ; rdi = positive base offset
    mov rsi, r15                       ; rsi = element count
    mov rdx, r14                       ; rdx = element type
    call gen_array_init
.array_decl_done:
    pop r15
    pop r14
    pop rbx
.nop_stmt:
    jmp .done
.struct_def_stmt:
    call gen_struct_def_stmt
    jmp .done
.break_stmt:
    call gen_break
    jmp .done
.continue_stmt:
    call gen_continue
    jmp .done
.ret_stmt:
    call gen_return
    jmp .done
.if_stmt:
    call gen_if
    jmp .done
.while_stmt:
    call gen_while
    jmp .done
.for_stmt:
    call gen_for
    jmp .done
.block:
    call gen_block
    jmp .done
.assign:
    call gen_assign
    jmp .done
.call:
    call gen_call
    jmp .done
.expr:
    call gen_expr
    ; result in rax, discarded
    jmp .done

.done:
    EPILOGUE r13, r12

; ================================================================
; gen_var_decl(rdi = AST_VAR_DECL*)
; type=data1, name=data2, init=data3
; ================================================================
gen_var_decl:
    push rbx
    push r12
    push r13

    mov r12, rdi
    mov r13, [r12 + ast_node_t.data3]  ; init ptr (may be 0)

    ; Find symbol to get offset
    mov rdi, [r12 + ast_node_t.data2]  ; name_ptr
    push rdi
    call find_symbol
    ; rax = offset (negative), rbx = type
    mov rdi, rax                        ; rdi = offset
    neg rdi                             ; rdi = positive offset
    mov rbx, rax                        ; rbx = negative offset (for store)

    ; If init is present, evaluate it
    pop rax                             ; rax = name_ptr (discarded, already have offset)
    test r13, r13
    jz .done
    ; Check if struct pointer — data3 holds init expression (field_array_ptr is in data4)
    mov rcx, [r12 + ast_node_t.data1]   ; type
    cmp rcx, PTR_TYPE_FLAG
    jb .gvd_has_init
    push rcx
    sub rcx, PTR_TYPE_FLAG
    cmp rcx, TOK_KW_STRUCT
    pop rcx
    jne .gvd_has_init
    ; Struct pointer with possible init — data3 is init expr (or 0 if none)
    test r13, r13
    jz .done                           ; no init → skip
.gvd_has_init:
    mov rdi, r13
    call gen_expr                       ; rax = value

    ; Warning: implicit cast — assigning int literal to char variable
    push rax                            ; save value
    push rbx                            ; save offset (mark_symbol_initialized clobbers rbx)
    push rdi
    ; Check if RHS is a numeric literal
    mov rdi, r13
    mov rax, [rdi + ast_node_t.type]
    cmp rax, AST_NUMBER
    jne .skip_gvd_cast
    ; Check if LHS is char
    mov rax, [r12 + ast_node_t.data1]  ; type
    cmp rax, TOK_KW_CHAR
    jne .skip_gvd_cast
    ; Warn: implicit cast from int to char
    push rbx
    mov r8, [rdi + ast_node_t.line]
    mov r9, [rdi + ast_node_t.column]
    mov rdi, WARN_IMPLICIT_CAST
    mov rsi, r8
    mov rdx, r9
    mov rcx, msg_warn_implicit_cast
    call warn_at
    pop rbx
.skip_gvd_cast:
    pop rdi
    pop rbx
    pop rax

    ; Mark symbol as initialized
    push rax                            ; save value (mark_symbol_initialized clobbers rax, rbx)
    push rbx                            ; save negative offset
    push rdi
    mov rdi, [r12 + ast_node_t.data2]  ; name_ptr
    call mark_symbol_initialized
    pop rdi
    pop rbx                             ; restore negative offset
    pop rax                             ; restore value

    ; Store: mov qword/byte [rbp-offset], rax/al
    ; rbx = negative offset
    push rbx
    mov rdi, rbx
    neg rdi
    ; rdi = positive offset now

    ; Find type for store size
    push rdi
    mov rdi, [r12 + ast_node_t.data2]
    call find_symbol
    ; rax = offset, rbx = type
    pop rdi                             ; rdi = positive offset
    pop rbx                             ; rbx = negative offset (discard)
    ; Actually we already know the type. Let me just check from the node.
    mov rcx, [r12 + ast_node_t.data1]   ; type token

    cmp rcx, TOK_KW_CHAR
    je .store_char

    ; Store qword
    push rdi                            ; save positive offset BEFORE emit_string
    mov rsi, asm_mov_qword_rbp
    call emit_string                    ; clobbers dil
    pop rdi                             ; restore positive offset
    push rdi
    call emit_int
    mov rsi, asm_rbp_rax                ; "], rax\n"
    call emit_string
    pop rdi
    jmp .done

.store_char:
    push rdi                            ; save positive offset BEFORE emit_string
    mov rsi, asm_mov_byte_rbp
    call emit_string                    ; clobbers dil
    pop rdi                             ; restore positive offset
    push rdi
    call emit_int
    mov rsi, asm_rbp_al                 ; "], al\n"
    call emit_string
    pop rdi

.done:
    pop r13
    pop r12
    pop rbx
    ret

; ================================================================
; gen_struct_def_stmt(rdi = AST_STRUCT_DEF*)
; Emits initialization code for a struct variable with init list.
; ================================================================
gen_struct_def_stmt:
    push rbx
    push r12
    push r13
    push r14

    mov r12, rdi                     ; r12 = AST_STRUCT_DEF node

    mov r13, [r12 + ast_node_t.data4] ; r13 = init (0 if none, or AST_INIT_LIST*, or expression)
    test r13, r13
    jz .gsds_done

    ; Check if init is an init list (AST_INIT_LIST) or an expression
    mov rax, [r13 + ast_node_t.type]
    cmp rax, AST_INIT_LIST
    je .gsds_init_list
    ; Expression initializer (e.g., function call returning struct)
    jmp .gsds_init_expr

.gsds_init_list:
    ; Find the struct variable's symbol
    mov rdi, [r12 + ast_node_t.data3] ; var name
    call find_symbol
    test rax, rax
    jnz .gsds_local

    ; Try global
    mov rdi, [r12 + ast_node_t.data3]
    call find_global_symbol
    test rax, rax
    jz .gsds_done
    ; Global struct with init — skip for now (handled in emit_global_vars)
    jmp .gsds_done

.gsds_local:
    neg rax                          ; rax = positive offset from rbp
    mov rdi, rax                     ; rdi = base_rbp_offset
    mov rsi, [r12 + ast_node_t.data2] ; rsi = field_array_ptr
    mov rdx, r13                     ; rdx = init_list
    call gen_struct_init
    jmp .gsds_done

.gsds_init_expr:
    ; Expression initializer: evaluate expr, then copy struct result to var
    ; Find the struct variable's symbol first
    mov rdi, [r12 + ast_node_t.data3] ; var name
    call find_symbol
    test rax, rax
    jnz .gsds_expr_local

    ; Try global
    mov rdi, [r12 + ast_node_t.data3]
    call find_global_symbol
    test rax, rax
    jz .gsds_done
    ; Global struct with expr init — emit: call expr, copy from struct_ret_slot to g_name
    push r13                         ; save init expr
    push rdi                         ; save var name
    mov rdi, r13                     ; rdi = init expression
    call gen_expr                    ; rax = struct_ret_slot address
    pop rdi                          ; restore var name
    pop r13                          ; restore init expr
    ; Strip "g_" prefix if present
    mov rsi, rdi
    call strip_g_prefix
    mov rdi, rsi
    ; Emit: mov rdi, g_name
    push rax                         ; save struct_ret_slot addr
    push rdi                         ; save var name (stripped)
    mov rsi, asm_mov_rdi_g_prefix
    call emit_string
    pop rdi
    call emit_string
    mov rsi, asm_newline
    call emit_string
    ; Emit: mov rsi, rax (struct_ret_slot addr)
    pop rax
    push rax
    mov rsi, asm_mov_rsi_rax
    call emit_string
    ; Emit: mov rdx, struct_size
    mov rsi, asm_mov_rdx_imm
    call emit_string
    mov rdi, [r12 + ast_node_t.data1] ; total_size
    call emit_int
    mov rsi, asm_newline
    call emit_string
    ; Emit: call __struct_copy
    mov rsi, asm_call_struct_copy
    call emit_string
    pop rax                          ; clean stack
    jmp .gsds_done

.gsds_expr_local:
    ; Local struct with expr init — emit: call expr, copy from struct_ret_slot to [rbp-offset]
    push r13                         ; save init expr
    push rax                         ; save negative offset
    mov rdi, r13                     ; rdi = init expression
    call gen_expr                    ; rax = struct_ret_slot address
    pop rax                          ; restore negative offset
    pop r13                          ; restore init expr
    ; rax = struct_ret_slot addr (from gen_expr)
    ; Emit: lea rdi, [rbp - offset]
    push rax
    mov rdi, rax
    neg rdi
    push rdi
    mov rsi, asm_lea_rdi_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_rbp_close
    call emit_string
    mov rsi, asm_newline
    call emit_string
    pop rdi                          ; discard positive offset
    pop rax                          ; rax = struct_ret_slot addr
    ; Emit: mov rsi, rax
    push rax
    mov rsi, asm_mov_rsi_rax
    call emit_string
    ; Emit: mov rdx, struct_size
    mov rsi, asm_mov_rdx_imm
    call emit_string
    mov rdi, [r12 + ast_node_t.data1] ; total_size
    call emit_int
    mov rsi, asm_newline
    call emit_string
    ; Emit: call __struct_copy
    mov rsi, asm_call_struct_copy
    call emit_string
    pop rax                          ; clean stack

.gsds_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ================================================================
; gen_struct_init(rdi = base_rbp_offset, rsi = field_array_ptr, rdx = init_list)
; Recursively emits stores for struct initialization.
; base_rbp_offset = positive offset from rbp to this struct.
; ================================================================
gen_struct_init:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push qword 0                     ; [rsp] = init counter (separate from field index)

    mov r12, rdi                     ; r12 = base_rbp_offset (positive)
    mov r13, rsi                     ; r13 = field_array_ptr
    mov r14, rdx                     ; r14 = init_list

    test r14, r14
    jz .gsi_done_pop

    mov r15, [r13]                   ; r15 = field count
    mov rax, [r14 + ast_node_t.data1] ; rax = init count (may differ from field count)
    mov r9, [r14 + ast_node_t.data2]  ; r9 = init array ptr

    xor r10, r10                     ; r10 = field index

.gsi_loop:
    cmp r10, r15
    jge .gsi_done_pop
    mov rax, [rsp]                   ; rax = init counter
    cmp rax, [r14 + ast_node_t.data1]
    jae .gsi_done_pop                 ; no more init values

    ; Get field descriptor
    imul r11, r10, 32
    lea r11, [r13 + 8 + r11]        ; r11 = field descriptor ptr
    mov r8, [r11 + 16]               ; r8 = field type (may include FIELD_CONST_FLAG)
    mov rbx, [r11 + 8]               ; rbx = field offset
    ; Strip FIELD_CONST_FLAG so type comparisons (ARRAY/STRUCT/CHAR) work
    test r8, FIELD_CONST_FLAG
    jz .gsi_type_clean
    sub r8, FIELD_CONST_FLAG
.gsi_type_clean:

    mov rax, [rsp]                   ; rax = init counter
    mov rcx, [r9 + rax * 8]          ; rcx = init value node

    ; Check for designated initializer (.field = value) — always treat as
    ; direct store at the stored byte offset, regardless of field type.
    cmp qword [rcx], AST_DESIGNATED_INIT
    jne .gsi_not_desig
    ; Use the designated init's stored byte offset instead of the field's offset
    mov rbx, [rcx + ast_node_t.data1] ; rbx = designated byte offset
    mov rcx, [rcx + ast_node_t.data2] ; rcx = value expression
    mov r8, TOK_KW_INT                ; treat as int for codegen purposes
    jmp .gsi_simple_field
.gsi_not_desig:

    cmp r8, ARRAY_TYPE_FLAG
    jae .gsi_array_field

    cmp r8, TOK_KW_STRUCT
    je .gsi_struct

    ; --- Simple field (int/char) ---
.gsi_simple_field:
    push r9
    push r10
    push rbx
    push rcx

    mov rdi, rcx
    call gen_expr                    ; rax = value

    pop rcx                          ; discard
    pop rbx                          ; rbx = field offset
    pop r10
    pop r9

    ; Compute total offset = base - field_offset
    mov rdi, r12
    sub rdi, rbx                     ; rdi = total offset (positive)

    push r9
    push r10

    cmp r8, TOK_KW_CHAR
    je .gsi_store_char

    ; Store qword: mov [rbp - offset], rax
    push rdi
    mov rsi, asm_mov_qword_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_rbp_rax
    call emit_string
    pop rdi
    pop r10
    pop r9
    jmp .gsi_next

.gsi_store_char:
    ; Store char: mov [rbp - offset], al
    push rdi
    mov rsi, asm_mov_byte_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_rbp_al
    call emit_string
    pop rdi
    pop r10
    pop r9
    jmp .gsi_next

.gsi_array_field:
    ; --- Array field initialization ---
    ; r8 = field type (with ARRAY_TYPE_FLAG), r11 = field descriptor ptr
    ; rbx = field offset, r12 = base_rbp_offset
    ; r9 = init array ptr, r10 = field index
    ; Stack after 5 pushes (descending):
    ;   [rsp+32] = init array ptr (r9, 1st push)
    ;   [rsp+24] = field index (r10, 2nd push)
    ;   [rsp+16] = field offset (rbx, 3rd push)
    ;   [rsp+8]  = field count (r15, 4th push)
    ;   [rsp+0]  = element count (5th push, will fill)
    push r9                          ; save init array ptr
    push r10                         ; save field index
    push rbx                         ; save field offset
    push r15                         ; save field count (outer)
    push qword 0                     ; allocate element count slot

    ; Get element info
    mov r15, [r11 + 24]              ; r15 = element count
    mov [rsp], r15                   ; save element count at top slot
    mov r10, r8                      ; r10 = field type
    sub r10, ARRAY_TYPE_FLAG          ; r10 = element type (stripped)

    ; Determine element size (r9)
    mov r9, 8
    cmp r10, TOK_KW_CHAR
    jne .gsi_array_have_size
    mov r9, 1
.gsi_array_have_size:

    xor r8, r8                       ; r8 = element index
.gsi_array_elem_loop:
    cmp r8, r15
    jae .gsi_array_done

    ; Get init value expression for this element
    mov rax, r8
    shl rax, 3                       ; rax = index * 8
    add rax, [rsp + 32]              ; rax = init_array_ptr + index*8
    mov rdi, [rax]                   ; rdi = init value node
    test rdi, rdi
    jz .gsi_array_elem_next

    ; Evaluate init expression
    push r8
    push r9
    push r10
    push r15
    push rdi
    call gen_expr                    ; rax = value
    pop rdi
    pop r15
    pop r10
    pop r9
    pop r8

    ; Compute total offset = base - (field_offset + index * elem_size)
    mov rdi, r12
    mov rax, r8
    imul rax, r9                     ; rax = index * elem_size
    sub rdi, [rsp + 16]              ; rdi = base - field_offset
    sub rdi, rax                     ; rdi = base - field_offset - index*elem_size

    ; Store value at [rbp - rdi]
    push r8
    push r9
    push r10
    push r15
    cmp r10, TOK_KW_CHAR
    je .gsi_array_store_char

    ; Store qword: mov qword [rbp - offset], rax
    push rdi
    mov rsi, asm_mov_qword_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_rbp_rax
    call emit_string
    pop rdi
    jmp .gsi_array_store_done

.gsi_array_store_char:
    ; Store byte: mov byte [rbp - offset], al
    push rdi
    mov rsi, asm_mov_byte_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_rbp_al
    call emit_string
    pop rdi

.gsi_array_store_done:
    pop r15
    pop r10
    pop r9
    pop r8

.gsi_array_elem_next:
    inc r8
    jmp .gsi_array_elem_loop

.gsi_array_done:
    ; Restore outer state, advancing init counter by element_count
    ; Stack layout: [rsp+32]=init_ptr, [rsp+24]=fld_idx, [rsp+16]=fld_off, [rsp+8]=cnt, [rsp]=elem_cnt
    pop rbx                          ; rbx = element count (consumed)
    pop r15                          ; discard outer field count
    pop rcx                          ; discard field offset
    pop r10                          ; r10 = field index (unchanged)
    pop r9                           ; r9 = init array ptr (unchanged)
    ; [rsp] = init counter; advance it by element_count
    add [rsp], rbx                   ; init counter += element_count
    inc r10                          ; advance field index
    jmp .gsi_loop

.gsi_struct:
    ; --- Nested struct field ---
    push r9
    push r10
    push rbx
    push rcx

    mov rdi, r12
    sub rdi, rbx                     ; rdi = base - field_offset
    mov rsi, [r11 + 24]              ; rsi = sub_array_ptr
    mov rdx, rcx                     ; rdx = nested init list
    call gen_struct_init

    pop rcx
    pop rbx
    pop r10
    pop r9
    jmp .gsi_next

.gsi_next:
    inc qword [rsp]                  ; advance init counter
    inc r10                          ; advance field index
    jmp .gsi_loop

.gsi_done_pop:
    pop rdi                          ; discard init counter
.gsi_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ================================================================
; gen_array_init(rdi = base_rbp_offset, rsi = elem_count, rdx = elem_type, rcx = init_list)
; Emits initialization code for a local array.
; ================================================================
gen_array_init:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12, rdi                     ; r12 = base rbp offset (positive)
    mov r13, rsi                     ; r13 = element count
    mov r14, rdx                     ; r14 = element type (TOK_KW_INT or TOK_KW_CHAR)
    mov r15, rcx                     ; r15 = init list (AST_INIT_LIST*)

    test r15, r15
    jz .gai_done

    mov r9, [r15 + ast_node_t.data1]  ; r9 = init count
    mov r10, [r15 + ast_node_t.data2] ; r10 = init array ptr

    xor r8, r8                       ; r8 = current index

.gai_loop:
    cmp r8, r9
    jge .gai_done
    cmp r8, r13
    jge .gai_done                     ; don't exceed array size

    ; Evaluate init expression
    mov rdi, [r10 + 8 + r8 * 8]
    test rdi, rdi
    jz .gai_next
    push r8
    push r10
    push r9
    call gen_expr                     ; rax = value
    pop r9
    pop r10
    pop r8

    ; Compute offset from base
    mov rdi, r12
    cmp r14, TOK_KW_CHAR
    je .gai_char_offset
    ; int array: offset = index * 8
    mov rax, r8
    shl rax, 3                        ; rax = index * 8
    sub rdi, rax                      ; rdi = base_offset - (index * 8)
    jmp .gai_store
.gai_char_offset:
    ; char array: offset = index
    sub rdi, r8

.gai_store:
    ; rdi now holds the positive rbp offset for this element
    push rdi
    push r8
    push r10
    push r9

    cmp r14, TOK_KW_CHAR
    je .gai_store_char

    ; Store qword: mov qword [rbp - offset], rax
    push rdi
    mov rsi, asm_mov_qword_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_rbp_rax
    call emit_string
    pop rdi
    jmp .gai_store_done

.gai_store_char:
    ; Store byte: mov byte [rbp - offset], al
    push rdi
    mov rsi, asm_mov_byte_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_rbp_al
    call emit_string
    pop rdi

.gai_store_done:
    pop r9
    pop r10
    pop r8
    pop rdi

.gai_next:
    inc r8
    jmp .gai_loop

.gai_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ================================================================
; gen_return(rdi = AST_RETURN*)
; expr = data1 (0 = void return)
; ================================================================
gen_return:
    push r12
    push r13
    push r14
    push r15

    ; Mark that this function has a return statement
    mov qword [function_has_return], 1

    ; Mark that last stmt is a terminator (for dead-code detection)
    mov qword [last_stmt_terminator], 1

    mov r12, [rdi + ast_node_t.data1]
    test r12, r12
    jz .void_ret

    mov rdi, r12
    call gen_expr                       ; value in rax

    ; C2X char is signed. A char-returning function must normalize the
    ; low byte into a signed 64-bit value so callers observe char semantics.
    push rax
    mov rax, [current_func_return_type]
    cmp rax, TOK_KW_CHAR
    pop rax
    jne .ret_not_char
    mov rsi, asm_movsx_rax_al
    call emit_string
.ret_not_char:

    ; Check if this function returns a struct (current_func_return_type)
    ; If so, rax holds the address of the struct to return.
    ; We need to copy the struct to the hidden return pointer at [rbp - 8].
    push rax
    mov rax, [current_func_return_type]
    cmp rax, TOK_KW_STRUCT
    pop rax
    jne .not_struct_ret

    ; Struct return: copy from [rax] to the address stored at [rbp - 8]
    ; rax = source address of struct
    ; Get struct size from current_func_return_fields
    push rax
    mov rdi, [current_func_return_fields]
    test rdi, rdi
    jz .struct_ret_done
    push rdi
    call struct_total_size
    pop rdi
    mov r15, rax                    ; r15 = struct size
    pop rax                         ; rax = source address
    test r15, r15
    jz .struct_ret_done

    ; Call __struct_copy(dest, src, size)
    ; rdi = dest = current_ret_ptr (the hidden return pointer)
    ; rsi = src = rax (source address)
    ; rdx = size = r15
    push rax
    push r15
    ; Emit: "mov rdi, [rbp - 8]"
    mov rsi, asm_mov_rdi_rbp_ret
    call emit_string
    ; Emit: "mov rsi, rax" (source)
    pop r15
    pop rax
    push rax
    push r15
    mov rsi, asm_mov_rsi_rax
    call emit_string
    pop r15
    pop rax
    ; Emit: "mov rdx, size"
    push rax
    push r15
    mov rsi, asm_mov_rdx_imm
    call emit_string
    mov rdi, r15
    call emit_int
    mov rsi, asm_newline
    call emit_string
    pop r15
    pop rax
    ; Emit: "call __struct_copy"
    mov rsi, asm_call_struct_copy
    call emit_string
.struct_ret_done:
    jmp .void_ret

.not_struct_ret:
    ; If --emit-returns, emit call to print the return value
    cmp qword [emit_returns_flag], 0
    je .void_ret
    mov rsi, asm_call_print_rax
    call emit_string

.void_ret:
    ; Jump to function end label to avoid executing trailing code
    mov rsi, asm_jmp_func_end
    call emit_string
    mov rdi, [function_end_label]
    call emit_int
    mov rsi, asm_newline
    call emit_string

    pop r15
    pop r14
    pop r13
    pop r12
    ret

; ================================================================
; gen_if(rdi = AST_IF*)
; cond=data1, then=data2, else=data3
; ================================================================
gen_if:
    PROLOGUE r15, r14, r13, r12

    mov r12, rdi
    mov r13, [r12 + ast_node_t.data2]  ; then block
    mov r15, [r12 + ast_node_t.data3]  ; else block (0 = none)
    mov r14, [last_stmt_terminator]     ; preserve outer dead-code state

    ; Condition
    mov rdi, [r12 + ast_node_t.data1]
    push rdi
    call gen_expr
    pop rdi
    push rdi

    ; Warning: constant condition
    mov rax, [rdi + ast_node_t.type]
    cmp rax, AST_NUMBER
    jne .gi_not_const_cond
    mov r8, [rdi + ast_node_t.line]
    mov r9, [rdi + ast_node_t.column]
    push r12
    push r15
    mov rdi, WARN_CONSTANT_COND
    mov rsi, r8
    mov rdx, r9
    mov rcx, msg_warn_constant_cond
    call warn_at
    pop r15
    pop r12
.gi_not_const_cond:

    pop rdi
    mov rsi, asm_cmp_rax_0
    call emit_string

    mov rax, [label_counter]
    inc qword [label_counter]
    push rax

    ; je .L_else_N
    mov rsi, asm_je_else
    call emit_string
    pop rax
    push rax
    mov rdi, rax
    call emit_int
    mov rsi, asm_newline
    call emit_string

    ; Warning: empty body
    mov rax, [r13 + ast_node_t.data1]  ; stmt count of then block
    test rax, rax
    jnz .gi_then_not_empty
    push r12
    push r15
    mov r8, [r12 + ast_node_t.line]
    mov r9, [r12 + ast_node_t.column]
    mov rdi, WARN_EMPTY_BODY
    mov rsi, r8
    mov rdx, r9
    mov rcx, msg_warn_empty_body
    call warn_at
    pop r15
    pop r12
.gi_then_not_empty:

    ; Then block
    mov rdi, r13
    call gen_block

    ; jmp .L_end_N (if else exists)
    test r15, r15
    jz .else_label

    mov rsi, asm_jmp_end
    call emit_string
    pop rax
    push rax
    mov rdi, rax
    call emit_int
    mov rsi, asm_newline
    call emit_string

.else_label:
    ; .L_else_N:
    mov rsi, asm_label_else
    call emit_string
    pop rax
    push rax
    mov rdi, rax
    call emit_int
    mov rsi, asm_label_sep
    call emit_string

    ; Else block
    test r15, r15
    jz .end_label
    mov rdi, r15
    call gen_block

.end_label:
    ; .L_end_N:
    mov rsi, asm_label_end
    call emit_string
    pop rax
    mov rdi, rax
    call emit_int
    mov rsi, asm_label_sep
    call emit_string

    ; Branch-local returns/breaks/continues must not make following statements
    ; unreachable: a non-constant if may take the other path at runtime.
    mov [last_stmt_terminator], r14

    EPILOGUE r15, r14, r13, r12

; ================================================================
; gen_while(rdi = AST_WHILE*)
; cond=data1, body=data2
; ================================================================
gen_while:
    PROLOGUE r13, r12

    mov r12, rdi
    mov r13, [r12 + ast_node_t.data2]  ; body

    ; Save previous loop labels (for nested loops)
    push qword [loop_start_label]
    push qword [loop_continue_label]
    push qword [loop_end_label]

    ; Allocate label numbers for start and end
    mov rax, [label_counter]
    inc qword [label_counter]
    push rax                           ; start label on stack
    push rax
    pop qword [loop_start_label]       ; set for condition check
    push rax
    pop qword [loop_continue_label]    ; for while: continue = condition check

    mov rax, [label_counter]
    inc qword [label_counter]
    push rax                           ; end label on stack
    push rax
    pop qword [loop_end_label]         ; set for break

    ; .L_start_N:
    mov rsi, asm_label_start
    call emit_string
    mov rax, [rsp + 8]                 ; start label
    mov rdi, rax
    call emit_int
    mov rsi, asm_label_sep
    call emit_string

    ; .L_cont_N: (same label number as start — continue jumps to condition check)
    mov rsi, asm_label_continue
    call emit_string
    mov rax, [rsp + 8]                 ; continue label (same as start in while)
    mov rdi, rax
    call emit_int
    mov rsi, asm_label_sep
    call emit_string

    ; Condition
    mov rdi, [r12 + ast_node_t.data1]
    push rdi
    call gen_expr
    pop rdi
    push rdi

    ; Warning: constant condition
    mov rax, [rdi + ast_node_t.type]
    cmp rax, AST_NUMBER
    jne .gw_not_const_cond
    mov r8, [rdi + ast_node_t.line]
    mov r9, [rdi + ast_node_t.column]
    mov rax, [rdi + ast_node_t.data1]   ; constant value
    test rax, rax                        ; 0 = dead loop, non-zero = intentional infinite loop
    jnz .gw_not_const_cond
    push r12
    mov rdi, WARN_CONSTANT_COND
    mov rsi, r8
    mov rdx, r9
    mov rcx, msg_warn_constant_cond
    call warn_at
    pop r12
.gw_not_const_cond:

    pop rdi
    mov rsi, asm_cmp_rax_0
    call emit_string

    ; je .L_end_N
    mov rsi, asm_je_end
    call emit_string
    mov rax, [rsp]                     ; end label
    mov rdi, rax
    call emit_int
    mov rsi, asm_newline
    call emit_string

    ; Warning: empty body
    mov rax, [r13 + ast_node_t.data1]  ; stmt count
    test rax, rax
    jnz .gw_body_not_empty
    push r12
    mov r8, [r12 + ast_node_t.line]
    mov r9, [r12 + ast_node_t.column]
    mov rdi, WARN_EMPTY_BODY
    mov rsi, r8
    mov rdx, r9
    mov rcx, msg_warn_empty_body
    call warn_at
    pop r12
.gw_body_not_empty:

    ; Body
    mov rdi, r13
    call gen_block

    ; jmp .L_start_N
    mov rsi, asm_jmp_start
    call emit_string
    mov rax, [rsp + 8]                 ; start label
    mov rdi, rax
    call emit_int
    mov rsi, asm_newline
    call emit_string

    ; .L_end_N:
    mov rsi, asm_label_end
    call emit_string
    mov rax, [rsp]                     ; end label
    mov rdi, rax
    call emit_int
    mov rsi, asm_label_sep
    call emit_string

    ; Pop labels and restore previous loop labels
    add rsp, 16                       ; discard end and start labels
    pop qword [loop_end_label]
    pop qword [loop_continue_label]
    pop qword [loop_start_label]

    ; Reset terminator flag (compound statement may or may not always terminate)
    mov qword [last_stmt_terminator], 0

    EPILOGUE r13, r12

; ================================================================
; gen_for(rdi = AST_FOR*)
; for (init; cond; incr) body
; AST_FOR layout: data1=init, data2=cond, data3=incr, data4=body
; Generated code:
;   init
; .L_start_N:
;   cond
;   je .L_end_N
;   body
; .L_cont_N:
;   incr
;   jmp .L_start_N
; .L_end_N:
; ================================================================
gen_for:
    PROLOGUE r15, r14, r13, r12

    mov r12, rdi
    mov r13, [r12 + ast_node_t.data4]  ; body

    ; Save previous loop labels (for nested loops)
    push qword [loop_start_label]
    push qword [loop_continue_label]
    push qword [loop_end_label]

    ; Allocate label numbers
    mov rax, [label_counter]
    inc qword [label_counter]
    push rax                           ; start label (for break to jump to end)

    mov rax, [label_counter]
    inc qword [label_counter]
    push rax                           ; continue label

    mov rax, [label_counter]
    inc qword [label_counter]
    push rax                           ; end label

    ; Set loop labels
    mov rax, [rsp + 16]                ; start label
    mov [loop_start_label], rax
    mov rax, [rsp + 8]                 ; continue label
    mov [loop_continue_label], rax
    mov rax, [rsp]                     ; end label
    mov [loop_end_label], rax

    ; --- Init ---
    mov rdi, [r12 + ast_node_t.data1]
    test rdi, rdi
    jz .gf_no_init
    call gen_stmt                       ; init
.gf_no_init:

    ; .L_start_N:
    mov rsi, asm_label_start
    call emit_string
    mov rdi, [rsp + 16]                ; start label
    call emit_int
    mov rsi, asm_label_sep
    call emit_string

    ; Condition
    mov rdi, [r12 + ast_node_t.data2]
    push rdi
    call gen_expr
    pop rdi

    ; Warning: constant condition
    mov rax, [rdi + ast_node_t.type]
    cmp rax, AST_NUMBER
    jne .gf_not_const_cond
    mov r8, [rdi + ast_node_t.line]
    mov r9, [rdi + ast_node_t.column]
    mov rax, [rdi + ast_node_t.data1]   ; constant value
    test rax, rax                        ; 0 = dead loop, non-zero = intentional infinite loop
    jnz .gf_not_const_cond
    push r12
    mov rdi, WARN_CONSTANT_COND
    mov rsi, r8
    mov rdx, r9
    mov rcx, msg_warn_constant_cond
    call warn_at
    pop r12
.gf_not_const_cond:

    mov rsi, asm_cmp_rax_0
    call emit_string

    ; je .L_end_N
    mov rsi, asm_je_end
    call emit_string
    mov rdi, [rsp]                     ; end label
    call emit_int
    mov rsi, asm_newline
    call emit_string

    ; Warning: empty body
    mov rax, [r13 + ast_node_t.data1]  ; stmt count
    test rax, rax
    jnz .gf_body_not_empty
    push r12
    mov rdi, WARN_EMPTY_BODY
    mov rsi, msg_warn_empty_body
    call warn_simple
    pop r12
.gf_body_not_empty:

    ; Body
    mov rdi, r13
    call gen_block

    ; .L_cont_N:
    mov rsi, asm_label_continue
    call emit_string
    mov rdi, [rsp + 8]                 ; continue label
    call emit_int
    mov rsi, asm_label_sep
    call emit_string

    ; Incr
    mov rdi, [r12 + ast_node_t.data3]
    test rdi, rdi
    jz .gf_no_incr
    call gen_stmt                       ; incr
.gf_no_incr:

    ; jmp .L_start_N
    mov rsi, asm_jmp_start
    call emit_string
    mov rdi, [rsp + 16]                ; start label
    call emit_int
    mov rsi, asm_newline
    call emit_string

    ; .L_end_N:
    mov rsi, asm_label_end
    call emit_string
    mov rdi, [rsp]                     ; end label
    call emit_int
    mov rsi, asm_label_sep
    call emit_string

    ; Pop labels and restore previous loop labels
    add rsp, 24                        ; discard start, continue, end labels
    pop qword [loop_end_label]
    pop qword [loop_continue_label]
    pop qword [loop_start_label]

    ; Reset terminator flag
    mov qword [last_stmt_terminator], 0

    EPILOGUE r15, r14, r13, r12

; ================================================================
; gen_break(rdi = AST_BREAK*)
; Emit: jmp .L_end_N  (where N is the innermost loop's end label)
; ================================================================
gen_break:
    mov rax, [loop_end_label]
    test rax, rax
    jz .brk_done                     ; not in a loop — nothing to do
    push rax                         ; save label number
    mov rsi, asm_jmp_end
    call emit_string                 ; emit "    jmp .L_end_" (clobbers rax, rdi, rsi)
    pop rdi                          ; restore label number
    call emit_int                    ; emit N
    mov rsi, asm_newline
    call emit_string
    mov qword [last_stmt_terminator], 1
.brk_done:
    ret

; ================================================================
; gen_continue(rdi = AST_CONTINUE*)
; Emit: jmp .L_cont_N  (where N is the innermost loop's continue label)
; For while loops, this is the condition check; for for loops, the increment.
; ================================================================
gen_continue:
    mov rax, [loop_continue_label]
    test rax, rax
    jz .cont_done                    ; not in a loop — nothing to do
    push rax                         ; save label number
    mov rsi, asm_jmp_continue
    call emit_string                 ; emit "    jmp .L_cont_" (clobbers rax, rdi, rsi)
    pop rdi                          ; restore label number
    call emit_int                    ; emit N
    mov rsi, asm_newline
    call emit_string
    mov qword [last_stmt_terminator], 1
.cont_done:
    ret

; ================================================================
; gen_assign(rdi = AST_ASSIGN*)
; left=data1 (AST_IDENT), right=data2
; ================================================================
gen_assign:
    PROLOGUE r15, r14, r13, r12, rbx

    mov r12, rdi

    ; Check LHS type: AST_IDENT or AST_UNARY_OP (dereference)
    mov rdi, [r12 + ast_node_t.data1]   ; LHS expression
    mov rax, [rdi + ast_node_t.type]

    cmp rax, AST_UNARY_OP
    je .assign_deref

    cmp rax, AST_INDEX
    je .assign_index

    cmp rax, AST_MEMBER
    je .assign_member

    ; --- LHS is AST_IDENT ---
    mov r15, rdi                         ; r15 = AST_IDENT node
    mov rdi, [rdi + ast_node_t.data1]    ; name_ptr

    ; Mark local symbol as initialized
    push rdi
    call mark_symbol_initialized
    pop rdi

    ; Mark symbol as used (for unused-variable detection)
    push rdi
    call mark_symbol_used
    pop rdi

    ; Evaluate RHS first (result in rax)
    push rdi                             ; save name_ptr
    mov rdi, [r12 + ast_node_t.data2]
    call gen_expr                        ; rax = value (or struct addr)

    ; Check if RHS is a struct — if so, need memcpy instead of simple store
    ; Save rax and rbx, check gen_expr_type, then restore
    push rax
    push rbx
    mov rax, [gen_expr_type]
    cmp rax, TOK_KW_STRUCT
    jne .ga_no_struct_copy
    ; RHS evaluated with struct-value semantics. memcpy is only correct when
    ; the LHS itself is a struct-typed *variable*: assignment to a pointer
    ; variable (g_p = g_arr; p = &s;) must store the address as a plain
    ; qword. Deciding on the RHS alone made `g_p = g_arr` memcpy over the
    ; pointer variable itself (n bytes starting at &g_p).
    mov r10, [rsp + 16]                  ; r10 = LHS name_ptr (under rax, rbx)
    mov rdi, r10
    call find_symbol                     ; local: rax = offset(neg), rbx = type
    test rax, rax
    jnz .ga_lhs_classified
    mov rdi, r10
    call find_global_symbol              ; global: rax = name_ptr, rbx = type
.ga_lhs_classified:
    test rax, rax
    jz .ga_lhs_unresolved                ; undeclared LHS: plain path reports
    cmp rbx, PTR_TYPE_FLAG
    jae .ga_lhs_is_pointer
    ; LHS is a struct variable: memcpy path is correct.
    pop rbx
    pop rax
    pop r10                              ; r10 = LHS name_ptr
    jmp .assign_struct_rhs
.ga_lhs_is_pointer:
    ; Re-classify the RHS as a plain address value.
    mov qword [gen_expr_type], 0
.ga_lhs_unresolved:
.ga_no_struct_copy:
    pop rbx
    pop rax
.not_struct_assign:

    ; Warning: implicit cast — assigning int literal to char variable
    push rax                             ; save value
    push rbx                             ; save rbx (find_symbol clobbers)
    ; Get name_ptr from stack (pushed before gen_expr)
    mov r10, [rsp + 16]                  ; r10 = name_ptr (skip rax, rbx, and the push rdi)
    ; Check if RHS is a numeric literal
    mov rdi, [r12 + ast_node_t.data2]
    mov rax, [rdi + ast_node_t.type]
    cmp rax, AST_NUMBER
    jne .skip_implicit_cast
    ; Save RHS location before clobbering rdi
    mov r8, [rdi + ast_node_t.line]
    mov r9, [rdi + ast_node_t.column]
    ; Get LHS type
    mov rdi, r10
    call find_symbol
    cmp rbx, TOK_KW_CHAR
    jne .skip_implicit_cast
    ; Warn: implicit cast from int to char
    push r10
    mov rdi, WARN_IMPLICIT_CAST
    mov rsi, r8
    mov rdx, r9
    mov rcx, msg_warn_implicit_cast
    call warn_at
    pop r10
.skip_implicit_cast:
    pop rbx
    pop rax

    ; Now look up the variable
    pop r10                              ; r10 = name_ptr (scratch, don't overwrite r15)
    mov r14, rax                         ; r14 = value (callee-saved)

    ; Try local first
    mov rdi, r10
    call find_symbol
    ; rax = offset (negative), rbx = type
    test rax, rax
    jnz .ident_local

    ; Try global
    mov rdi, r10
    call find_global_symbol
    ; rax = name_ptr (nonzero), rbx = type
    test rax, rax
    jz .done                             ; not found

    ; Check if global const variable
    push rdi
    push rbx
    push rcx
     mov rdi, r10
     call find_global_symbol_index
     cmp rax, 0
     jl .global_not_const
     mov r11, [global_symbol_const_ptr]
     cmp byte [r11 + rax], 0
     je .global_not_const
     ; Error: assignment to const variable 'NAME'
     mov rdi, r10
     call report_const_error
     pop rcx
     pop rbx
     pop rdi
     jmp .done
.global_not_const:
     pop rcx
     pop rbx
     pop rdi

     ; Global variable store
    ; r10 = name_ptr, r14 = value, rbx = type
    mov rax, r14                         ; rax = value
    ; Strip "g_" prefix from name if present (prevents g_g_argc double prefix)
    mov rsi, r10
    call strip_g_prefix
    mov r10, rsi
    cmp rbx, TOK_KW_CHAR
    je .ga_global_char

    mov rsi, asm_store_g_prefix
    call emit_string
    mov rsi, r10
    call emit_string
    mov rsi, asm_store_g_rax_sfx
    call emit_string
    jmp .done

.ga_global_char:
    mov rsi, asm_store_g_prefix
    call emit_string
    mov rsi, r10
    call emit_string
    mov rsi, asm_store_g_al_sfx
    call emit_string
    jmp .done

.ident_local:
    ; rax = offset (negative), rbx = type
    ; Check if const variable
    push rax
    push rbx
     push rcx
     mov rdi, r10
     call find_symbol_index
     cmp rax, 0
     jl .ident_local_ok
     mov r11, [symbol_const_ptr]
     cmp byte [r11 + rax], 0
     je .ident_local_ok
     ; Error: assignment to const variable 'NAME'
     mov rdi, r10
     call report_const_error
     pop rcx
     pop rbx
     pop rax
     jmp .done

.ident_local_ok:
    pop rcx
    pop rbx
    pop rax
    ; rax = offset (negative), rbx = type
    mov r13, rax                         ; r13 = negative offset

    mov rax, r14                         ; rax = value (restore from r14)

    test r13, r13
    jz .done

    ; Store: mov [rbp-offset], rax/al
    mov rdi, r13
    neg rdi                              ; rdi = positive offset

    cmp rbx, TOK_KW_CHAR
    je .ga_store_char

    push rdi
    mov rsi, asm_mov_qword_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_rbp_rax
    call emit_string
    pop rdi
    jmp .done

.ga_store_char:
    push rdi
    mov rsi, asm_mov_byte_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_rbp_al
    call emit_string
    pop rdi
    jmp .done

.assign_struct_rhs:
    ; RHS is a struct — need to memcpy from [rax] (struct source addr)
    ; to the LHS variable. We call __struct_copy(dest, src, size).
    ; rax = source address of struct
    ; r10 = name_ptr of LHS

    ; Get struct size from gen_expr_struct_fields
    push rax
    push r10
    mov rdi, [gen_expr_struct_fields]
    test rdi, rdi
    jz .assign_struct_done
    push rdi
    call struct_total_size
    pop rdi
    pop r10
    mov rbx, rax                    ; rbx = struct size
    pop rax                         ; rax = source address
    test rbx, rbx
    jz .assign_struct_done

    ; Save source (rax) and size (rbx)
    push rax
    push rbx
    push r10

    ; Find LHS symbol — try local first, then global
    mov rdi, r10
    call find_symbol
    test rax, rax
    jnz .asr_local_found
    ; Try global
    mov rdi, r10
    call find_global_symbol
    test rax, rax
    jz .asr_restore
    ; Global: get address of global into rdi
    pop r10
    pop rbx
    pop rax                         ; rax = source
    ; Strip g_ prefix
    push rax
    push rbx
    push r10
    mov rsi, r10
    call strip_g_prefix
    ; rsi = stripped name (save in r13, not r10, to avoid pop conflict)
    mov r13, rsi
    pop rax
    pop rbx
    pop r10                         ; restore r10 (original name, unused)
    ; Emit: "mov rdi, g_name"
    push rax
    push rbx
    mov rsi, asm_mov_rdi_g_prefix
    call emit_string
    mov rsi, r13
    call emit_string
    mov rsi, asm_newline
    call emit_string
    pop rbx
    pop rax
    ; rax = source, rbx = size, rdi = dest (global addr)
    jmp .asr_emit_call

.asr_local_found:
    ; Local: rax = negative offset from find_symbol
    pop r10
    pop rbx
    pop rdx                         ; rdx = source address (was rax)
    ; rdx = source, rbx = size, rax = negative offset
    mov r13, rax                    ; save offset in r13
    neg r13                         ; r13 = positive offset
    ; Emit: "lea rdi, [rbp - offset]"
    push rdx
    push rbx
    push r13
    mov rsi, asm_lea_rdi_rbp
    call emit_string
    mov rdi, r13
    call emit_int
    mov rsi, asm_rbp_close
    call emit_string
    mov rsi, asm_newline
    call emit_string
    pop r13
    pop rbx
    pop rdx
    ; rdx = source, rbx = size, rdi = dest (rbp - offset)
    jmp .asr_emit_call

.asr_restore:
    pop r10
    pop rbx
    pop rax
    jmp .assign_struct_done

.asr_emit_call:
    ; rax = source, rbx = size, rdi = dest
    ; Emit: "mov rsi, rax" (source)
    push rax
    push rbx
    mov rsi, asm_mov_rsi_rax
    call emit_string
    pop rbx
    pop rax
    ; Emit: "mov rdx, size" (size)
    push rax
    push rbx
    mov rsi, asm_mov_rdx_imm
    call emit_string
    mov rdi, rbx
    call emit_int
    mov rsi, asm_newline
    call emit_string
    pop rbx
    pop rax
    ; Emit: "call __struct_copy"
    mov rsi, asm_call_struct_copy
    call emit_string

.assign_struct_done:
    jmp .done

.assign_deref:
    ; *expr = val: evaluate operand (gives address), then RHS, then store
    mov rdi, [rdi + ast_node_t.data2]    ; operand of dereference
    call gen_expr                        ; rax = pointer address

    ; Emit "push rax" to save address on runtime stack
    mov rsi, asm_push_rax
    call emit_string

    mov rdi, [r12 + ast_node_t.data2]    ; RHS expression
    call gen_expr                        ; rax = value

    ; Emit "pop rbx" to restore address into rbx
    mov rsi, asm_pop_rbx
    call emit_string

    ; Store value at address
    mov rsi, asm_mov_rbx_rax
    call emit_string
    jmp .done

.assign_index:
    ; arr[i] = val — rdi = AST_INDEX node (LHS)
    mov r15, rdi                         ; r15 = AST_INDEX node

    ; Check if base is an identifier or an expression (e.g., struct field)
    mov rdi, [rdi + ast_node_t.data1]    ; base expression node
    mov rax, [rdi + ast_node_t.type]
    cmp rax, AST_IDENT
    jne .ai_general                      ; not an ident — use general eval

    ; Base is AST_IDENT
    mov r14, rdi                         ; r14 = AST_IDENT node
    mov rdi, [rdi + ast_node_t.data1]    ; name_ptr
    push rdi
    call find_symbol
    ; rax = offset, rbx = type, rcx = extra (count)
    test rax, rax
    jnz .ai_local
    ; Try global
    pop rdi
    push rdi
    call find_global_symbol
    ; rax = name_ptr (nonzero), rbx = type, rcx = extra
    test rax, rax
    jz .ai_no_base
    ; Global array
    pop rdi                              ; rdi = name_ptr
    mov r13, rdi                         ; save name_ptr in callee-saved reg
     ; Check if global const array
     push rdi
     push rbx
     push rcx
     call find_global_symbol_index
     cmp rax, 0
     jl .ai_global_not_const
     mov r11, [global_symbol_const_ptr]
     cmp byte [r11 + rax], 0
     je .ai_global_not_const
     ; Error: assignment to const array element 'NAME'
     pop rcx
     pop rbx
     pop rdi
     call report_const_error
     jmp .done
.ai_global_not_const:
    pop rcx
    pop rbx
    pop rdi
    ; Strip "g_" prefix if present (prevents g_g_arr double prefix)
    mov rsi, r13
    call strip_g_prefix
    mov r13, rsi
    mov r14, rbx                         ; r14 = type
    mov rbx, rcx                         ; rbx = element count (for bounds check)
    ; Check if pointer variable — load value instead of lea
    cmp r14, PTR_TYPE_FLAG
    jae .ai_global_ptr
    ; Array: emit lea rax, g_name (address)
    mov rsi, asm_lea_rax_g
    call emit_string
    mov rsi, r13
    call emit_string
    mov rsi, asm_close_bracket
    call emit_string
    mov rsi, asm_push_rax               ; push base address
    call emit_string
    jmp .ai_common

.ai_general:
    ; General expression base (e.g., s.cells[i] or t.arr[i] for const field):
    ; If base is AST_MEMBER of a const field, reject assignment.
    push r15                             ; save AST_INDEX node
    mov rdi, [r15 + ast_node_t.data1]    ; base expression
    mov rax, [rdi + ast_node_t.type]
    cmp rax, AST_MEMBER
    jne .ai_gen_eval
    ; Resolve member field and check FIELD_CONST_FLAG via find_field_is_const.
    ; data1 of member may be string (flat) or expression.
    push rdi
    mov rax, [rdi + ast_node_t.data1]
    cmp rax, 60                          ; AST type ids are < 60
    jb .ai_gen_member_expr
    ; Flat: data1 is struct name string
    mov rdi, rax
    call find_symbol
    test rax, rax
    jnz .ai_gen_member_have_fields
    pop rdi
    push rdi
    mov rdi, [rdi + ast_node_t.data1]
    call find_global_symbol
    test rax, rax
    jz .ai_gen_member_skip
.ai_gen_member_have_fields:
    ; rcx = field_array_ptr
    test rcx, rcx
    jz .ai_gen_member_skip
    pop rdi                              ; restore AST_MEMBER
    push rdi
    mov rsi, [rdi + ast_node_t.data2]    ; field name
    mov rdi, rcx
    call find_field
    cmp qword [find_field_is_const], 0
    je .ai_gen_member_skip
    pop rdi
    mov rdi, [rdi + ast_node_t.data2]    ; field name for error
    call report_const_error
    pop r15
    jmp .done
.ai_gen_member_expr:
    ; Expression base member — rely on gen_expr_struct_fields after gen_expr.
    ; Defer const check after base evaluation below.
.ai_gen_member_skip:
    pop rdi
.ai_gen_eval:
    mov rdi, [r15 + ast_node_t.data1]    ; base expression
    call gen_expr                         ; rax = base address
    ; After evaluating a member base, check const via find_field_is_const if
    ; the base was a member access that set the flag during gen_expr.
    cmp qword [find_field_is_const], 0
    je .ai_gen_not_const_field
    mov rdi, [r15 + ast_node_t.data1]
    mov rax, [rdi + ast_node_t.type]
    cmp rax, AST_MEMBER
    jne .ai_gen_not_const_field
    mov rdi, [rdi + ast_node_t.data2]
    call report_const_error
    pop r15
    jmp .done
.ai_gen_not_const_field:
    ; Save element type in r14 (callee-saved, preserved by subsequent gen_expr)
    mov r14, [gen_expr_type]
    ; gen_index_elem_fields != 0 means the base was an array whose elements
    ; are pointers to structs (s.ptrs[i] = ...): the element type IS a
    ; pointer, so keep it (8-byte stride) instead of stripping the flag,
    ; which would treat the element as a by-value struct and skip scaling.
    mov rax, [gen_index_elem_fields]
    test rax, rax
    jnz .ai_gen_ptr_elem
    ; rax = address of array field
    mov rsi, asm_push_rax
    call emit_string                     ; push base address
    pop r15                              ; r15 = AST_INDEX node
    ; Evaluate index
    mov rdi, [r15 + ast_node_t.data2]
    call gen_expr                         ; rax = index
    ; Bounds check for array field accesses
    mov rdi, [gen_expr_array_count]
    test rdi, rdi
    jz .ai_gen_skip_bounds
    call emit_bounds_check
    mov qword [gen_expr_array_count], 0
.ai_gen_skip_bounds:
    ; Pop base into rbx
    mov rsi, asm_pop_rbx
    call emit_string
    ; rbx = base, rax = index
    ; Strip one pointer level (if present) to get the element type. For a
    ; pointer-to-pointer base (`struct T** p; p[i]`), r14 becomes the inner
    ; pointer type (e.g. struct T*), which is still an 8-byte element.
    cmp r14, PTR_TYPE_FLAG
    jb .ai_gen_not_ptr
    sub r14, PTR_TYPE_FLAG
.ai_gen_not_ptr:
    ; Scale index by element size. char = 1, struct-by-value is handled by the
    ; struct path, everything else (int, pointer elements) is 8 bytes.
    cmp r14, TOK_KW_CHAR
    je .ai_gen_no_scale
    cmp r14, TOK_KW_STRUCT
    je .ai_gen_no_scale
    mov rsi, asm_shl_rax_3
    call emit_string
.ai_gen_no_scale:
    ; Compute element address
    mov rsi, asm_add_rax_rbx
    call emit_string                     ; rax = base + scaled_index
    ; Push target address
    mov rsi, asm_push_rax
    call emit_string
    ; Evaluate RHS
    mov rdi, [r12 + ast_node_t.data2]
    call gen_expr                         ; rax = value
    ; Pop target address into rbx
    mov rsi, asm_pop_rbx
    call emit_string
    ; Store
    cmp r14, TOK_KW_CHAR
    je .ai_gen_store_char
    mov rsi, asm_mov_rbx_rax
    call emit_string
    jmp .done
.ai_gen_ptr_elem:
    ; Array-of-pointer base: keep the pointer element type, push the base
    ; address, evaluate the index (bounds-checked against the packed count),
    ; and scale by 8.
    mov rsi, asm_push_rax
    call emit_string                     ; push base address
    pop r15                              ; r15 = AST_INDEX node
    mov rdi, [r15 + ast_node_t.data2]
    call gen_expr                         ; rax = index
    mov rdi, [gen_expr_array_count]
    test rdi, rdi
    jz .ai_gen_ptr_nobounds
    call emit_bounds_check
    mov qword [gen_expr_array_count], 0
.ai_gen_ptr_nobounds:
    mov rsi, asm_pop_rbx
    call emit_string
    mov rsi, asm_shl_rax_3
    call emit_string                     ; 8-byte pointer elements
    jmp .ai_gen_no_scale
.ai_gen_store_char:
    mov rsi, asm_mov_rbx_al
    call emit_string
    jmp .done

    ; Strip "g_" prefix if present (prevents g_g_arr double prefix)
    mov rsi, r13
    call strip_g_prefix
    mov r13, rsi
    mov r14, rbx                         ; r14 = type
    mov rbx, rcx                         ; rbx = element count (for bounds check)
    ; Check if pointer variable — load value instead of lea
    cmp r14, PTR_TYPE_FLAG
    jae .ai_global_ptr
    ; Array: emit lea rax, g_name (address)
    mov rsi, asm_lea_rax_g
    call emit_string
    mov rsi, r13
    call emit_string
    mov rsi, asm_close_bracket
    call emit_string
    mov rsi, asm_push_rax               ; push base address
    call emit_string
    jmp .ai_common

.ai_global_ptr:
    ; Pointer variable: mov rax, [g_name] (load the pointer value)
    sub r14, PTR_TYPE_FLAG               ; strip flag for type-based scaling
    mov rsi, asm_mov_rax_g
    call emit_string
    mov rsi, r13
    call strip_g_prefix                   ; user globals may already spell g_name
    call emit_string
    mov rsi, asm_close_bracket
    call emit_string
    mov rsi, asm_push_rax               ; push base pointer value
    call emit_string
    jmp .ai_common

.ai_local:
    mov r13, rax                         ; r13 = negative offset of array
    mov r14, rbx                         ; r14 = type (for elem size)
    mov rbx, rcx                         ; rbx = element count (for bounds check)
    pop rdi                              ; discard
    test r13, r13
    jz .done

     ; Check if local const array
     push rdi
     push rbx
     push rcx
     mov rdi, r14
     mov rdi, r15                         ; r15 = AST_INDEX node
     mov rdi, [r15 + ast_node_t.data1]    ; AST_IDENT node
     mov rsi, [rdi + ast_node_t.data1]    ; rsi = name_ptr (save for error)
     mov rdi, rsi                         ; rdi = name_ptr (for find_symbol_index)
     push rsi                             ; save name_ptr
     call find_symbol_index
     pop rsi                              ; rsi = saved name_ptr (for error)
     cmp rax, 0
     jl .ai_local_not_const
     mov r11, [symbol_const_ptr]
     cmp byte [r11 + rax], 0
     je .ai_local_not_const
     ; Error: assignment to const array element 'NAME'
     pop rcx
     pop rbx
     pop rdi
     mov rdi, rsi
     call report_const_error
     jmp .done
.ai_local_not_const:
    pop rcx
    pop rbx
    pop rdi

    ; VLA: extra == -1 → load base pointer from frame slot, runtime bounds
    ; check against the count stored at [rbp-|offset|+8].
    cmp rbx, -1
    je .ai_local_vla

    ; Check if pointer variable — load value instead of lea
    cmp r14, PTR_TYPE_FLAG
    jae .ai_local_ptr

    ; Array base: lea rax, [rbp - |offset|]
    mov rdi, r13
    neg rdi
    push rdi
    mov rsi, asm_lea_rax_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    pop rdi

    mov rsi, asm_push_rax               ; push base address
    call emit_string
    jmp .ai_common

.ai_local_vla:
    ; r13 = negative offset of base-ptr slot (callee-saved, preserved by emit).
    ; Load base pointer: mov rax, [rbp-|offset|]
    mov rdi, r13
    neg rdi
    push rdi
    mov rsi, asm_load_qword_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    pop rdi
    ; Push base pointer value for .ai_common-style flow.
    mov rsi, asm_push_rax
    call emit_string
    ; Load runtime count into r9: mov r9, [rbp-|offset-8|] (less-negative slot)
    mov rsi, asm_mov_r9_rbp
    call emit_string
    mov rdi, r13
    neg rdi
    sub rdi, 8                        ; count slot = base_offset - 8 (less negative)
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    ; Evaluate index
    mov rdi, [r15 + ast_node_t.data2]
    call gen_expr                        ; rax = index
    ; Runtime bounds check: index >= 0 and index < r9.
    test rax, rax
    jl .ai_vla_skip_bounds
    mov rsi, asm_cmp_rax_r9
    call emit_string
    mov r13, [label_counter]
    inc qword [label_counter]
    mov rsi, asm_jae_bounds_fail
    call emit_string
    mov rdi, r13
    call emit_int
    mov rsi, asm_newline
    call emit_string
    mov rsi, asm_jmp_bounds_ok
    call emit_string
    mov rdi, r13
    call emit_int
    mov rsi, asm_newline
    call emit_string
    mov rsi, asm_label_bounds_fail
    call emit_string
    mov rdi, r13
    call emit_int
    mov rsi, asm_label_sep
    call emit_string
    mov rsi, asm_mov_rdi_1
    call emit_string
    mov rsi, asm_mov_rax_60
    call emit_string
    mov rsi, asm_syscall
    call emit_string
    mov rsi, asm_label_bounds_ok
    call emit_string
    mov rdi, r13
    call emit_int
    mov rsi, asm_label_sep
    call emit_string
.ai_vla_skip_bounds:
    mov rsi, asm_pop_rbx                 ; rbx = base pointer
    call emit_string
    ; Scale index by element size
    cmp r14, TOK_KW_CHAR
    je .ai_vla_no_scale
    mov rsi, asm_shl_rax_3
    call emit_string
.ai_vla_no_scale:
    mov rsi, asm_add_rax_rbx             ; rax = base + scaled_index
    call emit_string
    mov rsi, asm_push_rax                ; push target address
    call emit_string
    ; Evaluate RHS
    mov rdi, [r12 + ast_node_t.data2]
    call gen_expr                        ; rax = value
    mov rsi, asm_pop_rbx                 ; rbx = target address
    call emit_string
    cmp r14, TOK_KW_CHAR
    je .ai_vla_store_char
    mov rsi, asm_mov_rbx_rax
    call emit_string
    jmp .done
.ai_vla_store_char:
    mov rsi, asm_mov_rbx_al
    call emit_string
    jmp .done

.ai_local_ptr:
    ; Pointer variable: mov rax, [rbp - |offset|] (load the pointer value)
    mov rdi, r13
    neg rdi
    push rdi
    mov rsi, asm_load_qword_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    pop rdi
    ; Strip PTR_TYPE_FLAG to get base type for scaling
    sub r14, PTR_TYPE_FLAG

    mov rsi, asm_push_rax               ; push base pointer value
    call emit_string

.ai_common:

    ; Evaluate index
    mov rdi, [r15 + ast_node_t.data2]    ; index expr
    call gen_expr                        ; rax = index

    ; Bounds check for non-struct arrays
    cmp r14, TOK_KW_CHAR
    je .ai_do_bounds
    cmp r14, TOK_KW_INT
    jne .ai_no_bounds
.ai_do_bounds:
    cmp rbx, 0
    jle .ai_no_bounds
    push rdi
    mov rdi, rbx
    call emit_bounds_check
    pop rdi
.ai_no_bounds:

    mov rsi, asm_pop_rbx                ; rbx = base address
    call emit_string

    ; Scale index by element size
    cmp r14, TOK_KW_CHAR
    je .ai_no_scale
    mov rsi, asm_shl_rax_3
    call emit_string
.ai_no_scale:
    ; Compute element address
    mov rsi, asm_add_rax_rbx            ; rax = base + scaled_index
    call emit_string

    ; Push target address
    mov rsi, asm_push_rax
    call emit_string

    ; Evaluate RHS
    mov rdi, [r12 + ast_node_t.data2]
    call gen_expr                        ; rax = value

    ; Pop target address into rbx
    mov rsi, asm_pop_rbx
    call emit_string

    ; Store
    cmp r14, TOK_KW_CHAR
    je .ai_store_char
    mov rsi, asm_mov_rbx_rax
    call emit_string
    jmp .done
.ai_store_char:
    mov rsi, asm_mov_rbx_al
    call emit_string
    jmp .done

.assign_member:
    ; s.field = val — rdi = AST_MEMBER node (LHS)
    mov r15, rdi                         ; r15 = AST_MEMBER node

    ; Check if chained member access (data1 is AST_MEMBER node)
    ; or expression-based (*ptr).field
    mov rdi, [r15 + ast_node_t.data1]
    mov rax, [rdi]
    cmp rax, AST_MEMBER
    je .am_via_gen_addr
    cmp rax, AST_INDEX
    je .am_via_gen_addr
    cmp rax, AST_UNARY_OP
    je .am_via_gen_addr
    cmp rax, 60                         ; below 60 = AST type = expression base
    jb .am_via_gen_addr

    ; Flat member access: data1 = struct name_ptr (string)
    push rdi
    call find_symbol
    ; rax = offset, rbx = type, rcx = extra (field_array_ptr)
    test rax, rax
    jnz .am_local
    ; Try global
    pop rdi
    push rdi
     call find_global_symbol
     ; rax = name_ptr, rbx = type, rcx = extra (field_array_ptr)
     test rax, rax
     jz .am_not_found_global
     ; Check if global const struct
     push rax                         ; save name_ptr (clobbered by find_global_symbol_index)
     push rdi
     push rbx
     push rcx
     call find_global_symbol_index
     cmp rax, 0
     jl .am_global_not_const
     mov r11, [global_symbol_const_ptr]
     cmp byte [r11 + rax], 0
     je .am_global_not_const
     ; Error: assignment to const struct field 'NAME'
     pop rcx
     pop rbx
     pop rdi
     pop rdi                          ; rdi = saved name_ptr
     call report_const_error
     jmp .done
.am_global_not_const:
    pop rcx
    pop rbx
    pop rdi
    pop rax                         ; restore name_ptr
    mov r13, rax                         ; r13 = name_ptr (for emit)
    mov r14, rcx                         ; r14 = field_array_ptr
    pop rdi                              ; discard
    jmp .am_find_field

.am_not_found_global:
    pop rdi                              ; discard name_ptr
    jmp .am_done

.am_local:
    mov r13, rax                         ; r13 = negative offset
    mov r14, rcx                         ; r14 = field_array_ptr
    pop rdi                              ; discard
    test r13, r13
    jz .am_done
    test r14, r14
    jz .am_done

     ; Check if local const struct
     push rdi
     push rbx
     push rcx
     mov rdi, r15                         ; r15 = AST_MEMBER node
     mov rsi, [r15 + ast_node_t.data1]    ; rsi = struct name_ptr (save for error)
     mov rdi, rsi                         ; rdi = struct name_ptr (for find_symbol_index)
     push rsi                             ; save name_ptr
     call find_symbol_index
     pop rsi                              ; rsi = saved name_ptr (for error)
     cmp rax, 0
     jl .am_local_not_const
     mov r11, [symbol_const_ptr]
     cmp byte [r11 + rax], 0
     je .am_local_not_const
     ; Error: assignment to const struct field 'NAME'
     pop rcx
     pop rbx
     pop rdi
     mov rdi, rsi
     call report_const_error
     jmp .done
.am_local_not_const:
    pop rcx
    pop rbx
    pop rdi

    ; Search for field
.am_find_field:
    mov rdi, r14
    mov rsi, [r15 + ast_node_t.data2]    ; field name_ptr
    call find_field
    ; rax = field_offset, rbx = field_type (both 0 if not found)
    ; find_field_is_const = 1 if the field was declared const
    test rbx, rbx
    jz .am_no_such_field                 ; not found: hard error, not silence
    ; Check if the field was declared const
    cmp qword [find_field_is_const], 0
    je .am_field_ok
    mov rdi, [r15 + ast_node_t.data2]    ; field name for error msg
    call report_const_error
    jmp .am_done
.am_field_ok:
    mov r14, rbx                         ; r14 = field_type (const flag already stripped)
    mov rbx, rax                         ; rbx = field_offset

    ; Check if local or global struct
    ; r13 < 0 → local (negative offset), r13 > 0 → global (name_ptr)
    test r13, r13
    js .am_local_addr

    ; Global struct — emit: lea rax, [g_name + field_offset]
    mov rsi, r13
    call strip_g_prefix
    mov r13, rsi
    mov rsi, asm_lea_rax_g
    call emit_string
    mov rsi, r13                         ; name_ptr
    call emit_string
    test rbx, rbx
    jz .am_global_no_offset
    ; Emit "+offset]"
    push rdi
    push rsi
    mov dil, '+'
    call out_write_char
    mov rdi, rbx
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    pop rsi
    pop rdi
    jmp .am_global_push

.am_global_no_offset:
    mov rsi, asm_close_bracket
    call emit_string
    jmp .am_global_push

.am_local_addr:
    ; Local struct — compute: rbp - |struct_offset| + field_offset
    mov rdi, r13
    neg rdi                              ; rdi = struct offset (positive)
    sub rdi, rbx                         ; rdi = struct_offset - field_offset

    push rdi
    mov rsi, asm_lea_rax_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    pop rdi

.am_global_push:
    ; Push address
    mov rsi, asm_push_rax
    call emit_string

    ; Evaluate RHS
    mov rdi, [r12 + ast_node_t.data2]
    call gen_expr                        ; rax = value

    ; Pop address
    mov rsi, asm_pop_rbx
    call emit_string

    ; Store
    cmp r14, TOK_KW_CHAR
    je .am_store_char
    mov rsi, asm_mov_rbx_rax
    call emit_string
    jmp .am_done
.am_store_char:
    mov rsi, asm_mov_rbx_al
    call emit_string
    jmp .am_done

; ------------------------------------------------------------
; Chained / expression-based member assignment via gen_addr.
; Handles s.inner.a = v, o[i].field = v, (*p).field = v, etc.
; ------------------------------------------------------------
.am_via_gen_addr:
    ; r15 = outer AST_MEMBER node; compute address of the whole lvalue.
    push r12
    mov rdi, r15
    call gen_addr
    pop r12
    test rax, rax
    jz .am_done
    ; rax = target address (runtime); gen_expr_type = field type
    mov r14, [gen_expr_type]

    ; Push target address (runtime)
    mov rsi, asm_push_rax
    call emit_string

    ; Evaluate RHS
    push r14
    mov rdi, [r12 + ast_node_t.data2]
    call gen_expr                        ; rax = value
    pop r14

    ; Struct-typed assignment: byte copy instead of scalar store.
    cmp r14, TOK_KW_STRUCT
    je .am_gen_struct_store

    ; Pop target address into rbx
    mov rsi, asm_pop_rbx
    call emit_string
    cmp r14, TOK_KW_CHAR
    je .am_gen_store_char
    mov rsi, asm_mov_rbx_rax
    call emit_string
    jmp .am_done
.am_gen_store_char:
    mov rsi, asm_mov_rbx_al
    call emit_string
    jmp .am_done

.am_gen_struct_store:
    ; rax = source struct address, target address on the stack.
    mov rsi, asm_pop_rbx
    call emit_string                     ; rbx = dest
    mov rsi, asm_mov_rsi_rax
    call emit_string                     ; rsi = src
    mov rsi, asm_mov_rdi_rbx
    call emit_string                     ; rdi = dest
    mov rdi, [gen_expr_struct_fields]
    test rdi, rdi
    jz .am_gen_struct_done
    call struct_total_size               ; rax = size
    mov rdi, rax
    test rdi, rdi
    jz .am_gen_struct_done
    mov rsi, asm_mov_rdx_imm
    call emit_string
    call emit_int
    mov rsi, asm_newline
    call emit_string
    mov rsi, asm_call_struct_copy
    call emit_string
.am_gen_struct_done:
    jmp .am_done

.am_no_such_field:
    mov rdi, [r15 + ast_node_t.data2]    ; field name
    call report_no_field
    jmp .am_done

.am_done:
    jmp .done                            ; keep the _no_base handler off the fall-through path

.ai_no_base:
    ; Base name of `x[i] = ...` is neither local nor global (undeclared
    ; identifier). Discard the name_ptr pushed before find_global_symbol so
    ; the stack stays balanced; emit nothing (the write is dropped). The
    ; resolver reports the missing name; codegen must not crash on it.
    pop rdi
    jmp .done

.done:
    EPILOGUE r15, r14, r13, r12, rbx

; ================================================================
; gen_call(rdi = AST_CALL*)
; name=data1
; ================================================================
gen_call:
    PROLOGUE r15, r14, r13, r12, rbx

    mov r15, rdi                          ; r15 = AST_CALL node
    mov r12, [r15 + ast_node_t.data1]     ; name_ptr
    mov r13, [r15 + ast_node_t.data2]     ; arg array (0 if no args)

    ; Check for built-in asm()
    cmp byte [r12], 'a'
    jne .not_asm
    cmp byte [r12+1], 's'
    jne .not_asm
    cmp byte [r12+2], 'm'
    jne .not_asm
    cmp byte [r12+3], 0
    jne .not_asm
    jmp .gen_asm
.not_asm:

    ; --- Struct return detection ---
    ; If the callee returns a struct, we allocate a buffer on the caller's
    ; stack and pass its address as the hidden first argument (in rdi).
    ; The buffer is allocated below the pushed user arguments and its address
    ; is recomputed from rsp after the call returns.
    push r12
    push r13
    mov rdi, r12
    call find_func_return
    pop r13
    pop r12
    cmp rax, TOK_KW_STRUCT
    jne .gc_no_struct_ret

    ; Struct return: use BSS buffer (no stack allocation needed)
    ; Set r14 = -1 as flag indicating struct return
    mov r14, -1
    jmp .gc_args_start

.gc_no_struct_ret:
    xor r14, r14                          ; r14 = 0 (no struct return)
.gc_args_start:

    ; Determine the explicit argument count.
    ; For struct-return calls we still evaluate all user args first, then
    ; append the hidden return pointer as an extra stack value.
    xor rbx, rbx
    test r13, r13
    jz .gc_eval_done
    mov rbx, [r13]                        ; rbx = arg count
    test rbx, rbx
    jz .gc_eval_done                      ; no explicit args

    ; Evaluate args RIGHT-TO-LEFT, pushing each result onto the runtime stack.
    ; After this loop, the stack has: top = arg0, arg1, ..., bottom = argN-1.
    mov rcx, rbx                          ; rcx = counter going down
.gc_eval_loop:
    dec rcx
    mov rdi, [r13 + 8 + rcx * 8]          ; arg AST node
    push rcx
    push rbx
    call gen_expr                          ; rax = value
    pop rbx
    pop rcx
    push rcx                               ; emit_string may clobber rcx
    mov rsi, asm_push_rax
    call emit_string                       ; emit "push rax"
    pop rcx
    test rcx, rcx
    jnz .gc_eval_loop

.gc_eval_done:
    cmp r14, -1
    jne .gc_maybe_skip_pops
    ; Struct return: push the BSS struct_ret_slot address as the hidden
    ; first argument (System V AMD64 ABI). Increment rbx so the pop
    ; sequence below pops it into rdi.
    mov rsi, asm_push_struct_ret
    call emit_string
    inc rbx
    jmp .gc_pop_args

.gc_maybe_skip_pops:
    test rbx, rbx
    jz .gc_no_args

.gc_pop_args:
    ; Pop first 6 values into registers (rdi, rsi, rdx, rcx, r8, r9).
    ; Remaining args (7+) stay on the stack for the callee (SysV ABI).
    mov rsi, asm_pop_rdi
    call emit_string
    cmp rbx, 1
    jle .gc_cleanup

    mov rsi, asm_pop_rsi
    call emit_string
    cmp rbx, 2
    jle .gc_cleanup

    mov rsi, asm_pop_rdx
    call emit_string
    cmp rbx, 3
    jle .gc_cleanup

    mov rsi, asm_pop_rcx
    call emit_string
    cmp rbx, 4
    jle .gc_cleanup

    mov rsi, asm_pop_r8
    call emit_string
    cmp rbx, 5
    jle .gc_cleanup

    mov rsi, asm_pop_r9
    call emit_string

.gc_cleanup:
    ; Compute stack-arg cleanup size now (bytes to remove AFTER the call).
    ; SysV: stack args must remain on the stack during the call; the caller
    ; only cleans them up after return.  Stash cleanup bytes in a stack slot
    ; so emit_* helpers cannot clobber it via rax.
    push qword 0                      ; [rsp] = post-call cleanup bytes
    cmp rbx, 6
    jle .gc_emit_call
    mov rax, rbx
    sub rax, 6
    shl rax, 3                        ; (n - 6) * 8
    mov [rsp], rax
    jmp .gc_emit_call

.gc_no_args:
    push qword 0                      ; no stack-arg cleanup

.gc_emit_call:
    ; Emit the call instruction
    mov rsi, asm_call
    call emit_string
    mov rsi, r12
    call emit_string
    mov rsi, asm_newline
    call emit_string

    ; Post-call: remove stack-passed arguments (if any).
    mov rax, [rsp]
    add rsp, 8                        ; pop cleanup-bytes slot
    test rax, rax
    jz .gc_after_stack_cleanup
    push rax
    mov rsi, asm_add_rsp
    call emit_string
    pop rdi
    call emit_int
    mov rsi, asm_newline
    call emit_string

.gc_after_stack_cleanup:
    ; --- Struct return result ---
    ; After the call, the struct result is in struct_ret_slot (BSS buffer).
    ; Load its address into rax (the gen_expr return value).
    cmp r14, -1
    jne .gc_set_ret_type

    ; Load struct_ret_slot address into rax
    mov rsi, asm_mov_rax_struct_ret
    call emit_string

.gc_set_ret_type:
    ; Record the callee's return type so member access on the call result
    ; (e.g. p_cur()->kind, f().x) can resolve the field array. Without this,
    ; `gen_expr_struct_fields` held whatever a previous expression left
    ; there (often 0) and `.member_expr_base` silently returned the raw
    ; struct address instead of loading the field.
    push r12
    mov rdi, r12                         ; callee name
    call find_func_return                 ; rax = return type, rdx = field_array_ptr
    pop r12
    mov [gen_expr_type], rax
    ; Struct-valued returns: the result is an address (struct value
    ; semantics); struct-pointer returns keep the pointee field array for
    ; chained access.
    cmp rax, TOK_KW_STRUCT
    jne .gc_ret_type_ptr_check
    mov [gen_expr_struct_fields], rdx
    jmp .asm_done
.gc_ret_type_ptr_check:
    ; Any pointer-to-struct return (PTR_TYPE_FLAG + TOK_KW_STRUCT + depth)
    ; also carries the pointee's field array.
    push rax
    push rdx
    mov rdi, rax
    call type_base_is_struct
    pop rdx
    pop rcx                              ; rcx = return type
    test rax, rax
    jz .gc_ret_type_plain
    mov [gen_expr_struct_fields], rdx
    jmp .asm_done
.gc_ret_type_plain:
    ; Non-struct returns have no field array.
    mov qword [gen_expr_struct_fields], 0
    jmp .asm_done

.asm_done:
    EPILOGUE r15, r14, r13, r12, rbx

; ------------------------------------------------------------
; .gen_asm: Handle built-in asm("template" [, var[, var...]])
; Positional operand substitution: %0, %1, etc. are replaced
; with [rbp-offset] for the corresponding variable argument.
; %% emits a literal %. Backward compatible with no operands.
; ------------------------------------------------------------
.gen_asm:
    test r13, r13
    jz .asm_done
    mov r14, [r13]                    ; r14 = arg count
    test r14, r14
    jz .asm_done

    ; Get first argument AST node
    mov rdi, [r13 + 8]               ; first arg AST node
    test rdi, rdi
    jz .asm_done

    ; Verify it's a string literal
    mov rax, [rdi + ast_node_t.type]
    cmp rax, AST_STRING
    jne .asm_done

    mov r12, [rdi + ast_node_t.data1]  ; r12 = template string ptr
    test r12, r12
    jz .asm_done

    ; Compute operand count = total_args - 1 (excluding template)
    mov r15, r14
    sub r15, 1                         ; r15 = operand count
    jle .ga_no_operands                ; 0 or negative => simple path

    ; Allocate stack space for operand offsets + global name ptrs
    ; Layout: [offsets: r15*8 bytes] [global_name_ptrs: r15*8 bytes]
    mov rax, r15
    shl rax, 4                          ; rax = r15 * 16 (two arrays of qwords)
    sub rsp, rax                        ; rsp = offset buffer (first r15*8 = offsets, next r15*8 = global names)

    ; Precompute base address of global names section
    mov rax, r15
    shl rax, 3
    lea r14, [rsp + rax]                ; r14 = rsp + r15*8 (base of global names array)

    ; Resolve each operand variable and store its offset or global name
    xor rbx, rbx                        ; rbx = index
.ga_op_loop:
    cmp rbx, r15
    jge .ga_op_done

    ; Get AST node for operand rbx (args[rbx+1])
    mov rdi, [r13 + 8 + (rbx+1)*8]
    test rdi, rdi
    jz .ga_op_store_zero

    mov rax, [rdi + ast_node_t.type]
    cmp rax, AST_IDENT
    jne .ga_op_store_zero

    mov rdi, [rdi + ast_node_t.data1]  ; name_ptr
    test rdi, rdi
    jz .ga_op_store_zero

    ; Try local symbol table first
    push rbx
    push r15
    push r13
    push r14
    call find_symbol
    ; rax = offset (negative) or 0 if not found
    mov r8, rax                         ; r8 = offset result
    mov r9, rbx                         ; r9 = type (save)
    pop r14
    pop r13
    pop r15
    pop rbx

    test r8, r8
    jnz .ga_op_store_local             ; found locally

    ; Not local — try global symbol table
    push rbx
    push r15
    push r13
    push r14
    call find_global_symbol
    ; rax = name_ptr (nonzero) if found, rbx = type, rcx = extra
    mov r8, rax                         ; r8 = name_ptr or 0
    pop r14
    pop r13
    pop r15
    pop rbx

    test r8, r8
    jz .ga_op_store_zero               ; not found anywhere

    ; Global variable found — store name_ptr in the global names array
    mov [r14 + rbx*8], r8              ; store name_ptr in global names section
    mov qword [rsp + rbx*8], 0         ; clear offset (not local)
    inc rbx
    jmp .ga_op_loop

.ga_op_store_local:
    neg r8                              ; r8 = positive offset
    mov [rsp + rbx*8], r8              ; store offset in offsets section
    mov qword [r14 + rbx*8], 0         ; clear global name
    inc rbx
    jmp .ga_op_loop

.ga_op_store_zero:
    xor rax, rax
    mov [rsp + rbx*8], rax             ; clear offset
    mov [r14 + rbx*8], rax             ; clear global name
    inc rbx
    jmp .ga_op_loop

.ga_op_done:
    ; Emit comment marker
    mov rsi, asm_semi_comment
    call emit_string
    mov rsi, asm_inline_asm_marker
    call emit_string
    mov rsi, asm_newline
    call emit_string

    ; Process template char by char
    ; r12 = template ptr, r15 = operand count
    ; offset buffer at [rsp]
.ga_process:
    mov al, [r12]
    test al, al
    jz .ga_cleanup

    cmp al, '%'
    je .ga_pct

    ; Emit literal char
    mov dil, al
    call out_write_char
    inc r12
    jmp .ga_process

.ga_pct:
    inc r12
    mov al, [r12]
    test al, al
    jz .ga_cleanup

    cmp al, '%'
    je .ga_emit_pct

    cmp al, '0'
    jb .ga_raw_char
    cmp al, '9'
    ja .ga_raw_char

    ; Operand reference %N
    sub al, '0'
    movzx rcx, al

    cmp rcx, r15
    jae .ga_next_char

    ; Check if this operand is a global variable (name_ptr stored in global section)
    ; Global names array is at [rsp + r15*8] (after the offsets array)
    mov rax, r15
    shl rax, 3
    add rax, rsp                        ; rax = rsp + r15*8 (global names base)
    mov r8, [rax + rcx*8]              ; r8 = global name_ptr (0 = local/unresolved)
    test r8, r8
    jnz .ga_op_global

    ; Local variable — emit "[rbp-"
    mov rsi, asm_rbp_prefix
    call emit_string

    ; Emit offset value
    mov rdi, [rsp + rcx*8]
    call emit_int

    ; Emit "]"
    mov dil, ']'
    call out_write_char
    inc r12
    jmp .ga_process

.ga_op_global:
    ; Global variable — emit "g_name"
    mov rsi, asm_label_g_prefix         ; "g_"
    call emit_string
    mov rsi, r8                         ; name_ptr
    call emit_string
    inc r12
    jmp .ga_process

.ga_emit_pct:
    mov dil, '%'
    call out_write_char
    inc r12
    jmp .ga_process

.ga_raw_char:
    mov dil, al
    call out_write_char
    inc r12
    jmp .ga_process

.ga_next_char:
    inc r12
    jmp .ga_process

.ga_no_operands:
    ; Simple path: emit template string directly (backward compatible)
    mov rsi, asm_semi_comment
    call emit_string
    mov rsi, asm_inline_asm_marker
    call emit_string
    mov rsi, asm_newline
    call emit_string

    mov rsi, r12
    call emit_string
    mov rsi, asm_newline
    call emit_string
    jmp .asm_done

.ga_cleanup:
    ; Emit trailing newline
    mov rsi, asm_newline
    call emit_string

    ; Restore stack if we allocated operand buffer (r15 * 16 bytes)
    test r15, r15
    jle .asm_done

    mov rax, r15
    shl rax, 4                          ; rax = r15 * 16
    add rsp, rax
    jmp .asm_done

; ================================================================
; gen_expr(rdi = AST node*) → result in rax
; ================================================================
gen_expr:
    PROLOGUE r15, r14, r13, r12, rbx

    mov r12, rdi
    mov rax, [r12 + ast_node_t.type]

    cmp rax, AST_NUMBER
    je .number
    cmp rax, AST_CHAR
    je .char
    cmp rax, AST_STRING
    je .string
    cmp rax, AST_IDENT
    je .ident
    cmp rax, AST_BINARY_OP
    je .binary
    cmp rax, AST_UNARY_OP
    je .unary
    cmp rax, AST_INDEX
    je .index
    cmp rax, AST_MEMBER
    je .member
    cmp rax, AST_POST_INCR
    je .post_incr
    cmp rax, AST_POST_DECR
    je .post_decr
    cmp rax, AST_CALL
    je .call_expr
    cmp rax, AST_LOGICAL_AND
    je .logical_and
    cmp rax, AST_LOGICAL_OR
    je .logical_or
    cmp rax, AST_CAST
    je .cast
    ; Unknown: rax = 0
    xor rax, rax
    jmp .done

.number:
    mov rsi, asm_mov_rax_imm
    call emit_string
    mov rdi, [r12 + ast_node_t.data1]
    call emit_int
    mov rsi, asm_newline
    call emit_string
    mov qword [gen_expr_type], 0
    jmp .done

.char:
    mov rsi, asm_mov_rax_imm
    call emit_string
    mov rdi, [r12 + ast_node_t.data1]
    call emit_int
    mov rsi, asm_newline
    call emit_string
    mov qword [gen_expr_type], TOK_KW_CHAR
    jmp .done

.string:
    ; data1 = string ptr, data2 = string length (from lexer, includes embedded nulls)
    mov rdi, [r12 + ast_node_t.data1]
    test rdi, rdi
    jz .string_done

    ; Get string length from AST node (preserves embedded nulls)
    mov r15, [r12 + ast_node_t.data2]  ; r15 = length

    ; Keep string ptr on stack for later pop
    push rdi

    ; Get current string count as pool index
    mov r14, [string_count]          ; r14 = index (pre-increment, callee-saved)
    cmp r14, [string_pool_capacity]
    jb .string_store                 ; capacity available, store directly
    ; Pool is full — grow it
    call string_pool_grow
    ; string_pool_grow clobbers caller-saved regs, restore string ptr
    pop rdi
    push rdi

.string_store:
    ; Store: string_pool_ptr[r14] = {ptr, len}
    mov rax, r14
    shl rax, 4
    add rax, [string_pool_ptr]       ; rax = pool base + index*16
    mov [rax], rdi                   ; store ptr
    mov [rax + 8], r15               ; store len
    inc qword [string_count]

.string_emit:
    ; Emit: lea rax, [rel .LC_N] (N = r14)
    mov rsi, asm_lea_rax_rel_lc
    call emit_string
    mov rdi, r14
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string

    pop rdi                          ; discard saved string ptr
    mov qword [gen_expr_type], TOK_KW_CHAR
    add qword [gen_expr_type], PTR_TYPE_FLAG   ; char* type

.string_done:
    jmp .done

.ident:
    mov rdi, [r12 + ast_node_t.data1]   ; name_ptr
    push rdi                              ; save name_ptr
    call find_symbol
    ; rax = offset, rbx = type
    test rax, rax
    jnz .found_local
    pop rdi                              ; restore name_ptr
    push rdi                             ; re-save
    call find_global_symbol
    ; rax = name_ptr (nonzero), rbx = type
    test rax, rax
    jnz .found_global
    pop rdi                              ; discard name_ptr
    ; Undeclared identifier used as a value: a hard compile error, not
    ; silent zero-value codegen.
    call report_undeclared
    xor rax, rax
    jmp .done

.found_global:
    mov [gen_expr_type], rbx             ; save type
    ; rcx = extra (0 for scalar, element_count for array, field_array_ptr for struct)
    mov [gen_expr_struct_fields], rcx    ; save for member access on expression bases

    ; Check if non-struct array: extra>0, type<PTR_TYPE_FLAG, type!=TOK_KW_STRUCT
    test rcx, rcx
    jz .glob_not_array
    cmp rbx, PTR_TYPE_FLAG
    jae .glob_not_array
    cmp rbx, TOK_KW_STRUCT
    je .glob_not_array

    ; Array — emit lea rax, [g_name]
    pop rdi                              ; rdi = name_ptr
    ; Strip "g_" prefix if present (prevents g_g_argc double prefix)
    mov rsi, rdi
    call strip_g_prefix
    mov rdi, rsi
    push rdi                             ; re-save for emit
    mov rsi, asm_lea_rax_g
    call emit_string
    pop rsi
    call emit_string
    mov rsi, asm_close_bracket
    call emit_string
    jmp .done

.glob_not_array:
    pop rdi                              ; rdi = name_ptr
    ; Strip "g_" prefix if present (prevents g_g_argc double prefix)
    mov rsi, rdi
    call strip_g_prefix
    mov rdi, rsi
    push rdi                             ; re-save for emit
    cmp rbx, TOK_KW_CHAR
    pop rdi                              ; rdi = name_ptr
    push rdi                             ; re-save for emit
    cmp rbx, TOK_KW_CHAR
    je .load_global_char
    cmp rbx, TOK_KW_STRUCT
    je .load_global_struct
    mov rsi, asm_mov_rax_g
    call emit_string
    pop rsi
    call emit_string
    mov rsi, asm_close_bracket
    call emit_string
    jmp .done

.load_global_char:
    mov rsi, asm_movsx_rax_byte_g
    call emit_string
    pop rsi
    call emit_string
    mov rsi, asm_close_bracket
    call emit_string
    jmp .done

.load_global_struct:
    ; Emit lea rax, [g_name] — return address of struct, not value
    mov rsi, asm_lea_rax_g
    call emit_string
    pop rsi
    call emit_string
    mov rsi, asm_close_bracket
    call emit_string
    jmp .done

.found_local:
    ; rax = offset (negative), rbx = type, rcx = extra
    push rax                         ; save offset (warning check clobbers rax)
    push rbx                         ; save type (mark_symbol_used clobbers rbx)
    push rcx                         ; save extra (mark_symbol_used clobbers rcx)
    mov [gen_expr_type], rbx          ; save type for pointer arithmetic
    mov [gen_expr_struct_fields], rcx ; save extra (field_array_ptr, may be 0)

    ; Mark symbol as used (for unused-variable detection)
    mov rdi, [r12 + ast_node_t.data1] ; name_ptr
    call mark_symbol_used

    pop rcx                          ; restore extra
    pop rbx                          ; restore type
    ; rax still has the offset (mark_symbol_used preserves rax)

    ; Warning: uninitialized variable use (scalar only — pointers handled in .unary)
    ; Skip if it's an array (handled separately) or pointer
    cmp rbx, PTR_TYPE_FLAG
    jae .fl_no_uninit_warn
    test rcx, rcx
    jnz .fl_no_uninit_warn            ; skip arrays
    ; Scalar local: check init status
    push r12
    push r15
    push rdi
    mov r8, [r12 + ast_node_t.line]
    mov r9, [r12 + ast_node_t.column]
    mov rdi, [r12 + ast_node_t.data1] ; name_ptr (from AST_IDENT)
    call check_symbol_initialized
    test rax, rax
    jnz .fl_warn_done
    push r15
    mov rdi, WARN_UNINIT_VAR
    mov rsi, r8
    mov rdx, r9
    mov rcx, msg_warn_uninit_var
    call warn_at
    pop r15
.fl_warn_done:
    pop rdi
    pop r15
    pop r12
.fl_no_uninit_warn:
    pop rax                          ; restore offset
    ; Reload rcx and rbx (were clobbered by check_symbol_initialized)
    mov rcx, [gen_expr_struct_fields]
    mov rbx, [gen_expr_type]

    ; Check if non-struct array: extra>0, type<PTR_TYPE_FLAG, type!=TOK_KW_STRUCT
    test rcx, rcx
    jnz .local_check_array
    jmp .local_not_array
.local_check_array:
    cmp rbx, PTR_TYPE_FLAG
    jae .local_not_array
    cmp rbx, TOK_KW_STRUCT
    je .local_not_array

    ; Array — emit lea rax, [rbp-offset]
    mov r15, rax               ; save offset
    pop rdi                    ; discard name_ptr
    mov rdi, r15
    neg rdi                    ; rdi = positive offset
    push rdi
    mov rsi, asm_lea_rax_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    pop rdi
    jmp .done

.local_not_array:
    ; Non-array: load value
    mov r15, rax               ; save offset in r15 (callee-saved)
    pop rdi                    ; discard name_ptr
    mov rdi, r15               ; rdi = offset
    neg rdi                    ; rdi = positive offset
    cmp rbx, TOK_KW_CHAR
    je .load_char
    cmp rbx, TOK_KW_STRUCT
    je .load_local_struct

    push rdi
    mov rsi, asm_load_qword_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    pop rdi
    jmp .done

.load_char:
    push rdi
    mov rsi, asm_load_byte_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    pop rdi
    jmp .done

.load_local_struct:
    ; Emit lea rax, [rbp-offset] — return address of struct, not value
    push rdi
    mov rsi, asm_lea_rax_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    pop rdi
    jmp .done

.binary:
    ; Left
    mov rdi, [r12 + ast_node_t.data2]
    call gen_expr
    mov r13, [gen_expr_type]             ; save left type
    mov rsi, asm_push_rax
    call emit_string

    ; Right
    mov rdi, [r12 + ast_node_t.data3]
    call gen_expr
    mov r14, [gen_expr_type]             ; save right type

    ; Pop left into rbx
    mov rsi, asm_pop_rbx
    call emit_string

    ; rbx=left, rax=right, r13=left_type, r14=right_type
    mov rdi, [r12 + ast_node_t.data1]   ; operator

    cmp rdi, TOK_PLUS
    je .op_add
    cmp rdi, TOK_MINUS
    je .op_sub
    cmp rdi, TOK_STAR
    je .op_mul
    cmp rdi, TOK_SLASH
    je .op_div
    cmp rdi, TOK_PERCENT
    je .op_mod
    cmp rdi, TOK_EQEQ
    je .op_eq
    cmp rdi, TOK_NEQ
    je .op_ne
    cmp rdi, TOK_LT
    je .op_lt
    cmp rdi, TOK_LE
    je .op_le
    cmp rdi, TOK_GT
    je .op_gt
    cmp rdi, TOK_GE
    je .op_ge
    cmp rdi, TOK_LSHIFT
    je .op_lshift
    cmp rdi, TOK_RSHIFT
    je .op_rshift
    cmp rdi, TOK_AMPERSAND
    je .op_bitand
    cmp rdi, TOK_PIPE
    je .op_bitor
    cmp rdi, TOK_XOR
    je .op_xor
    cmp rdi, TOK_AND
    je .op_logical_and
    cmp rdi, TOK_OR
    je .op_logical_or
    jmp .done

.op_add:
    ; Check for pointer arithmetic
    mov rdi, r13
    call get_ptr_scale                    ; rdi = left type, rax = scale (0 if not ptr)
    test rax, rax
    jnz .add_left_ptr
    mov rdi, r14
    call get_ptr_scale
    test rax, rax
    jnz .add_right_ptr
    ; Normal add
    mov rsi, asm_add_rax_rbx
    call emit_string
    mov qword [gen_expr_type], 0
    jmp .done

.add_left_ptr:
    ; ptr + int: runtime rbx = ptr, rax = n
    ; scale n by element size, then add to ptr
    mov r15, rax                           ; r15 = scale
    cmp r15, 1
    je .add_left_ptr_done
    mov rsi, asm_imul_rax_8
    call emit_string                        ; rax = n * 8
.add_left_ptr_done:
    mov rsi, asm_add_rax_rbx
    call emit_string                        ; rax = ptr + n*8
    mov qword [gen_expr_type], TOK_KW_INT
    jmp .done

.add_right_ptr:
    ; int + ptr: runtime rbx = n, rax = ptr
    ; scale n (in rbx) by element size, then add to ptr
    mov r15, rax                           ; r15 = scale
    cmp r15, 1
    je .add_right_ptr_done
    mov rsi, asm_imul_rbx_8
    call emit_string                        ; rbx = n * 8
.add_right_ptr_done:
    mov rsi, asm_add_rax_rbx
    call emit_string                        ; rax = ptr + n*8
    mov qword [gen_expr_type], TOK_KW_INT
    jmp .done

.op_sub:
    ; Check for pointer arithmetic
    mov rdi, r13
    call get_ptr_scale
    test rax, rax
    jnz .sub_left_ptr                     ; left is ptr
    ; Normal sub (both ints)
    mov rsi, asm_sub_rbx_rax
    call emit_string
    mov qword [gen_expr_type], 0
    jmp .done

.sub_left_ptr:
    ; left is ptr, check if right is also ptr
    mov r15, rax                          ; r15 = scale from left pointer
    mov rdi, r14
    call get_ptr_scale
    test rax, rax
    jnz .sub_ptr_ptr                      ; both are pointers

    ; ptr - int: runtime rbx = ptr, rax = n
    ; scale n by element size, subtract from ptr
    cmp r15, 1
    je .sub_ptr_int_done
    mov rsi, asm_imul_rax_8
    call emit_string                       ; rax = n * 8
.sub_ptr_int_done:
    mov rsi, asm_sub_rbx_rax               ; sub rbx, rax; mov rax, rbx
    call emit_string                       ; rax = ptr - n*8
    mov qword [gen_expr_type], TOK_KW_INT
    jmp .done

.sub_ptr_ptr:
    ; ptr1 - ptr2: runtime rbx = ptr1, rax = ptr2
    ; (ptr1 - ptr2) / scale
    mov rsi, asm_sub_rbx_rax               ; sub rbx, rax; mov rax, rbx
    call emit_string                       ; rax = byte difference
    cmp r15, 1
    je .sub_ptr_ptr_done
    mov rsi, asm_sar_rax_3
    call emit_string                       ; rax = element offset
.sub_ptr_ptr_done:
    mov qword [gen_expr_type], TOK_KW_INT
    jmp .done

.op_mul:
    mov rsi, asm_imul_rax_rbx
    call emit_string
    jmp .done

.op_div:
    mov rsi, asm_div_setup
    call emit_string
    jmp .done

.op_mod:
    mov rsi, asm_div_setup
    call emit_string
    mov rsi, asm_mod_result
    call emit_string
    jmp .done

.op_eq:
    mov rsi, asm_cmp_rbx_rax
    call emit_string
    mov rsi, asm_sete
    call emit_string
    jmp .done

.op_ne:
    mov rsi, asm_cmp_rbx_rax
    call emit_string
    mov rsi, asm_setne
    call emit_string
    jmp .done

.op_lt:
    mov rsi, asm_cmp_rbx_rax
    call emit_string
    mov rsi, asm_setl
    call emit_string
    jmp .done

.op_le:
    mov rsi, asm_cmp_rbx_rax
    call emit_string
    mov rsi, asm_setle
    call emit_string
    jmp .done

.op_gt:
    mov rsi, asm_cmp_rbx_rax
    call emit_string
    mov rsi, asm_setg
    call emit_string
    jmp .done

.op_ge:
    mov rsi, asm_cmp_rbx_rax
    call emit_string
    mov rsi, asm_setge
    call emit_string
    jmp .done

.op_lshift:
    mov rsi, asm_shl_rax_cl
    call emit_string
    jmp .done

.op_rshift:
    mov rsi, asm_sar_rax_cl
    call emit_string
    jmp .done

.op_bitand:
    mov rsi, asm_and_rax_rbx
    call emit_string
    jmp .done

.op_bitor:
    mov rsi, asm_or_rax_rbx
    call emit_string
    jmp .done

.op_xor:
    mov rsi, asm_xor_rax_rbx
    call emit_string
    jmp .done

; Logical AND (&&) and OR (||) are now handled by AST_LOGICAL_AND / AST_LOGICAL_OR
; in gen_expr with full short-circuit evaluation. These old dispatch entries
; are no longer reachable for &&/|| but remain for safety.
.op_logical_and:
    mov rsi, asm_and_rax_rbx
    call emit_string
    jmp .done

.op_logical_or:
    mov rsi, asm_or_rax_rbx
    call emit_string
    jmp .done

.unary:
    mov rdi, [r12 + ast_node_t.data1]   ; operator
    mov r15, rdi                         ; save operator in callee-saved reg

    ; Handle & (address-of) before evaluating operand
    cmp rdi, TOK_AMPERSAND
    je .unary_addr

    ; Warning check: *ident where ident may be uninitialized
    cmp r15, TOK_STAR
    jne .unary_skip_warn
    mov rdi, [r12 + ast_node_t.data2]   ; operand expr
    mov rax, [rdi + ast_node_t.type]
    cmp rax, AST_IDENT
    jne .unary_skip_warn
    mov r8, [rdi + ast_node_t.line]
    mov r9, [rdi + ast_node_t.column]
    push r12
    push r15
    mov rdi, [rdi + ast_node_t.data1]   ; name_ptr
    call check_symbol_initialized
    pop r15
    test rax, rax
    jnz .unary_warn_done
    push r15
    mov rdi, WARN_UNINIT_PTR
    mov rsi, r8
    mov rdx, r9
    mov rcx, msg_warn_uninit_ptr
    call warn_at
    pop r15
.unary_warn_done:
    pop r12
.unary_skip_warn:

    ; For all other unary ops, evaluate operand first
    push r15
    mov rdi, [r12 + ast_node_t.data2]   ; operand
    call gen_expr
    pop r15
    mov rdi, r15                         ; restore operator

    cmp rdi, TOK_MINUS
    je .unary_neg
    cmp rdi, TOK_STAR
    je .unary_deref
    cmp rdi, TOK_NEQ                     ; logical NOT
    je .unary_not
    cmp rdi, TOK_TILDE
    jne .done

    ; ~expr → not rax
    mov rsi, asm_not_rax
    call emit_string
    jmp .done

.unary_not:
    ; !expr → cmp rax, 0; sete al; movzx rax, al
    mov rsi, asm_cmp_rax_0
    call emit_string
    mov rsi, asm_sete
    call emit_string
    jmp .done

.unary_neg:
    mov rsi, asm_neg_rax
    call emit_string
    jmp .done

.unary_deref:
    ; *expr → load from pointer in rax (size depends on pointee type)
    ; gen_expr_type should be PTR_TYPE_FLAG + base_type
    push rax                             ; save pointer value
    mov rax, [gen_expr_type]
    cmp rax, PTR_TYPE_FLAG
    jb .deref_qword                      ; below PTR_TYPE_FLAG → not a pointer, load qword
    sub rax, PTR_TYPE_FLAG
    cmp rax, TOK_KW_CHAR
    je .deref_byte
.deref_qword:
    pop rax                              ; restore pointer value
    mov rsi, asm_mov_rax_from_rax
    call emit_string
    mov qword [gen_expr_type], TOK_KW_INT
    jmp .done
.deref_byte:
    pop rax                              ; restore pointer value
    mov rsi, asm_movsx_byte_rax
    call emit_string
    mov qword [gen_expr_type], TOK_KW_CHAR
    jmp .done

.unary_addr:
    ; &expr → address of expr
    mov rdi, [r12 + ast_node_t.data2]   ; operand
    mov rax, [rdi + ast_node_t.type]

    cmp rax, AST_IDENT
    je .addr_ident
    cmp rax, AST_INDEX
    je .addr_index
    jmp .done                           ; unsupported operand

.addr_index:
    ; &arr[i] — compute address of arr[i]
    ; operand is AST_INDEX{ data1=base_expr, data2=index_expr }
    mov r15, rdi                        ; r15 = AST_INDEX node
    mov rdi, [rdi + ast_node_t.data1]   ; base expression node
    mov rax, [rdi + ast_node_t.type]
    cmp rax, AST_IDENT
    jne .addr_index_general             ; member/other base — general eval
    mov r13, rdi                        ; r13 = AST_IDENT node
    mov rdi, [rdi + ast_node_t.data1]   ; name_ptr
    push rdi
    call find_symbol
    ; rax = negative offset, rbx = element type, rcx = extra
    test rax, rax
    jnz .addr_index_local

    ; Try global
    pop rdi
    push rdi
    call find_global_symbol
    ; rax = name_ptr, rbx = element type, rcx = extra
    test rax, rax
    jz .addr_index_no_base
    pop rdi                             ; rdi = name_ptr (discard)
    mov r14, rax                        ; r14 = name_ptr for emit
    mov r13, rbx                        ; r13 = element type
    mov [gen_expr_struct_fields], rcx    ; struct-array field descriptor, if any
    ; Strip "g_" prefix if present (prevents g_g_arr double prefix)
    mov rsi, r14
    call strip_g_prefix
    mov r14, rsi

    ; Check if pointer variable — load value instead of lea
    cmp r13, PTR_TYPE_FLAG
    jae .addr_global_ptr
    ; Array: emit lea rax, g_name (address)
    mov rsi, asm_lea_rax_g
    call emit_string
    mov rsi, r14
    call emit_string
    mov rsi, asm_close_bracket
    call emit_string
    jmp .addr_index_compute

.addr_global_ptr:
    ; Pointer variable: mov rax, [g_name] (load the pointer value)
    sub r13, PTR_TYPE_FLAG               ; strip flag for type-based scaling
    mov rsi, asm_mov_rax_g
    call emit_string
    mov rsi, r14
    call strip_g_prefix                  ; user globals may already spell g_name
    call emit_string
    mov rsi, asm_close_bracket
    call emit_string
    jmp .addr_index_compute

.addr_index_local:
    pop rdi                             ; discard name_ptr
    mov r13, rbx                        ; r13 = element type
    ; VLA: extra == -1 → load base pointer from frame slot (like a pointer).
    cmp rcx, -1
    je .addr_index_local_ptr
    mov [gen_expr_struct_fields], rcx    ; struct-array field descriptor, if any

    ; Check if pointer variable — load value instead of lea
    cmp r13, PTR_TYPE_FLAG
    jae .addr_index_local_ptr

    ; Array base: lea rax, [rbp-offset]
    mov rdi, rax
    neg rdi
    push rdi
    mov rsi, asm_lea_rax_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    pop rdi
    jmp .addr_index_compute

.addr_index_local_ptr:
    ; Pointer variable: mov rax, [rbp - |offset|] (load the pointer value)
    mov rdi, rax
    neg rdi
    push rdi
    mov rsi, asm_load_qword_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    pop rdi
    ; Strip PTR_TYPE_FLAG to get base type for scaling
    sub r13, PTR_TYPE_FLAG

.addr_index_general:
    ; Base is a member access or other expression (e.g., &r->spans[0]).
    ; Evaluate the base to obtain the array address and element type.
    push r15                             ; save AST_INDEX node
    mov rdi, [r15 + ast_node_t.data1]    ; base expression
    call gen_expr                        ; rax = base address
    mov r13, [gen_expr_type]
    cmp r13, PTR_TYPE_FLAG
    jb .addr_index_gen_noptr
    sub r13, PTR_TYPE_FLAG
.addr_index_gen_noptr:
    pop r15                              ; restore AST_INDEX node
    jmp .addr_index_compute

.addr_index_compute:
    ; rax = base address (compile-time value, also emitted as runtime)
    ; Emit push rax (runtime push of base address)
    push rax                            ; save compile-time base address
    mov rax, [gen_expr_struct_fields]
    push rax                            ; save metadata across index expression
    mov rsi, asm_push_rax
    call emit_string

    ; Evaluate index expression
    mov rdi, r15                        ; AST_INDEX node
    mov rdi, [rdi + ast_node_t.data2]   ; index AST node
    call gen_expr                       ; emits code, rax = compile-time index
    pop rdx
    mov [gen_expr_struct_fields], rdx

    ; Emit pop rbx (runtime pop base address into rbx)
    mov rsi, asm_pop_rbx
    call emit_string                    ; runtime: rbx = base, rax = index

    ; Scale index by element size
    cmp r13, TOK_KW_CHAR
    je .addr_index_noscale
    cmp r13, TOK_KW_STRUCT
    je .addr_index_scale_struct
    mov rsi, asm_shl_rax_3
    call emit_string                    ; rax = index * 8
    jmp .addr_index_scaled
.addr_index_scale_struct:
    mov rdi, [gen_expr_struct_fields]
    test rdi, rdi
    jz .addr_index_scaled
    call struct_total_size              ; rax = struct size; clobbers caller-saved regs
    test rax, rax
    jz .addr_index_scaled
    mov rdi, rax
    mov rsi, asm_imul_rax_imm
    push rdi
    call emit_string
    pop rdi
    call emit_int
    mov rsi, asm_newline
    call emit_string
    jmp .addr_index_scaled
.addr_index_noscale:
    jmp .addr_index_scaled
.addr_index_scaled:
    ; Set gen_expr_type = pointer-to-element after index evaluation, since
    ; gen_expr(index) updates the global expression metadata.
    mov [gen_expr_type], r13
    add qword [gen_expr_type], PTR_TYPE_FLAG

    ; Add base: rax = base + scaled_index
    mov rsi, asm_add_rax_rbx
    call emit_string

    pop rbx                             ; discard saved compile-time base
    jmp .done

.addr_ident:
    ; &ident — look up symbol to get offset
    mov rdi, [r12 + ast_node_t.data2]   ; operand (AST_IDENT)
    mov rdi, [rdi + ast_node_t.data1]   ; name_ptr
    push rdi
    call find_symbol
    ; rax = negative offset, rbx = type
    test rax, rax
    jnz .addr_local

    ; Try global
    pop rdi
    push rdi
    call find_global_symbol
    ; rax = name_ptr, rbx = type
    test rax, rax
    jz .addr_no_base
    ; rbx = type, set gen_expr_type to pointer-to-type
    mov [gen_expr_type], rbx
    add qword [gen_expr_type], PTR_TYPE_FLAG
    ; Emit: mov rax, g_name (address)
    pop rdi                              ; rdi = name_ptr
    ; Strip "g_" prefix if present (prevents g_g_arr double prefix)
    mov rsi, rdi
    call strip_g_prefix
    mov rdi, rsi
    push rdi                             ; save for later
    mov rsi, asm_lea_rax_g
    call emit_string
    pop rsi                              ; rsi = name_ptr (emit_string clobbers rdi)
    call emit_string
    mov rsi, asm_close_bracket
    call emit_string
    jmp .done

.addr_local:
    ; rbx = type, set gen_expr_type to pointer-to-type
    mov [gen_expr_type], rbx
    add qword [gen_expr_type], PTR_TYPE_FLAG
    mov rdi, rax
    neg rdi                             ; rdi = positive offset
    pop rax                             ; discard name_ptr

    ; Emit: lea rax, [rbp-offset]
    push rdi
    mov rsi, asm_lea_rax_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    pop rdi
    jmp .done

.index:
    ; base[index] — data1 = base expr, data2 = index expr
    ; Fast path: if base is AST_IDENT (simple array variable), use lea
    mov qword [gen_index_elem_fields], 0   ; reset: only the ident fast paths
                                           ; below set it (from the symbol's
                                           ; `.fields` slot).
    mov rdi, [r12 + ast_node_t.data1]   ; base expression
    mov rax, [rdi + ast_node_t.type]
    cmp rax, AST_IDENT
    jne .index_general
    mov r15, rdi                         ; r15 = AST_IDENT node
    mov rdi, [rdi + ast_node_t.data1]   ; name_ptr
    push rdi
    call find_symbol
    ; rax = negative offset, rbx = type, rcx = extra (element count / struct info)
    ; Capture the pointee field array (arrays of struct pointers) before any
    ; later lookup can overwrite found_symbol_fields.
    push rax
    mov rax, [found_symbol_fields]
    mov [gen_index_elem_fields], rax
    pop rax
    test rax, rax
    jnz .index_local
    ; Try global
    pop rdi
    push rdi
    call find_global_symbol
    ; rax = name_ptr (nonzero), rbx = type, rcx = extra
    ; Capture again for the global path (the local lookup missed).
    push rax
    mov rax, [found_symbol_fields]
    mov [gen_index_elem_fields], rax
    pop rax
    test rax, rax
    jz .index_no_base
    ; Global array
    pop rdi                              ; rdi = name_ptr
    mov r15, rdi                         ; r15 = name_ptr (for emit)
    ; Strip "g_" prefix if present (prevents g_g_arr double prefix)
    mov rsi, r15
    call strip_g_prefix
    mov r15, rsi
    mov r14, rbx                         ; r14 = type
    mov rbx, rcx                         ; rbx = extra/element count (callee-saved)
    mov r13, rcx                         ; r13 = extra (struct info)
    ; Check if pointer variable — load value instead of lea
    cmp r14, PTR_TYPE_FLAG
    jae .index_global_ptr
    ; Array: emit lea rax, g_name (address)
    mov rsi, asm_lea_rax_g
    call emit_string
    mov rsi, r15
    call emit_string
    mov rsi, asm_close_bracket          ; "]\n"
    call emit_string
    jmp .index_common

.index_general:
    ; General expression base (e.g., s.cells[i], t->temp[0]):
    ; Evaluate base (emits code that puts base pointer in rax)
    push r12
    mov rdi, [r12 + ast_node_t.data1]
    call gen_expr
    ; gen_index_elem_fields != 0 means the base was an array whose elements
    ; are pointers to structs (s.ptrs[i], g_arr[i]): the element type IS a
    ; pointer, so keep it instead of stripping the flag (which would make the
    ; code treat the element as a by-value struct and scale by struct size).
    mov rax, [gen_index_elem_fields]
    test rax, rax
    jnz .index_gen_ptr_elem
    ; Save element type: strip PTR_TYPE_FLAG if present
    mov r14, [gen_expr_type]
    cmp r14, PTR_TYPE_FLAG
    jb .index_gen_not_ptr
    sub r14, PTR_TYPE_FLAG               ; strip pointer flag to get element type
    jmp .index_gen_have_type
.index_gen_ptr_elem:
    mov r14, [gen_expr_type]             ; element type = the pointer type
.index_gen_not_ptr:
    ; Not a pointer type — keep as-is (e.g., TOK_KW_CHAR from *ptr deref)
.index_gen_have_type:
    ; rax = base pointer value — push it for later
    mov rsi, asm_push_rax
    call emit_string
    pop r12                              ; r12 = AST_INDEX node
    ; Save metadata around index eval (index expr may clobber them)
    mov rax, [gen_expr_struct_fields]
    push rax
    mov rax, [gen_expr_array_count]
    push rax
    ; Evaluate index expression
    push r12
    mov rdi, [r12 + ast_node_t.data2]
    call gen_expr
    pop r12
    ; Restore metadata after index eval
    pop rax
    mov [gen_expr_array_count], rax
    pop rax
    mov [gen_expr_struct_fields], rax
    ; rax = index value
    ; Bounds check: index >= 0 (runtime)
    test rax, rax
    jl .index_general_neg
    ; Runtime bounds check for array field accesses
    mov rdi, [gen_expr_array_count]
    test rdi, rdi
    jz .index_gen_skip_bounds
    call emit_bounds_check
    mov qword [gen_expr_array_count], 0
.index_gen_skip_bounds:
    ; Pop base into rbx
    mov rsi, asm_pop_rbx
    call emit_string
    ; rbx = base, rax = index
    ; Scale index by element size
    cmp r14, TOK_KW_CHAR
    je .index_gen_noscale
    cmp r14, TOK_KW_INT
    je .index_gen_scale8
    ; Pointer element (struct T*, int*, ...) or struct: pointers and most
    ; scalar element types are 8 bytes.
    cmp r14, TOK_KW_STRUCT
    je .index_gen_check_struct
    jmp .index_gen_scale8
.index_gen_scale8:
    mov rsi, asm_shl_rax_3
    call emit_string                    ; rax = index * 8
    jmp .index_gen_noscale
.index_gen_check_struct:
    cmp r14, TOK_KW_STRUCT
    jne .index_gen_noscale               ; unknown type — no scaling
    ; Struct element type: scale by struct size using field_array_ptr
    mov rdi, [gen_expr_struct_fields]
    test rdi, rdi
    jz .index_gen_noscale
    mov r8, rdi                          ; r8 = field_array_ptr (save before emit calls)
    push r8                              ; struct_total_size clobbers r8
    push r14
    call struct_total_size               ; rax = struct_size; clobbers rdi, r8, r9, rcx
    mov rdi, rax
    pop r14
    pop r8
    test rdi, rdi
    jz .index_gen_noscale
    push rdi                             ; save struct_size (emit_string clobbers rdi)
    mov rsi, asm_imul_rax_imm
    call emit_string                     ; clobbers dil, rax
    pop rdi                              ; restore struct_size for emit_int
    push r14
    push r8
    call emit_int                        ; emits struct_size
    pop r8
    pop r14
    mov [gen_expr_struct_fields], r8     ; preserve field_array_ptr for chaining
    mov [gen_expr_type], r14             ; TOK_KW_STRUCT
    mov rsi, asm_newline
    call emit_string
    ; Add base address: rax = base + scaled_index
    mov rsi, asm_add_rax_rbx
    call emit_string
    ; For struct elements, keep address in rax (do not load value)
    jmp .index_general_loaded
.index_gen_noscale:
    ; Add base: rax = base + scaled_index
    mov rsi, asm_add_rax_rbx
    call emit_string
    ; Load value (type-aware)
    cmp r14, TOK_KW_CHAR
    je .index_gen_load_char
    cmp r14, TOK_KW_STRUCT
    je .index_general_loaded              ; struct — keep address, already handled above
    ; Default: qword load (for int, struct ptr, etc.)
    mov rsi, asm_mov_rax_from_rax
    call emit_string
    mov [gen_expr_type], r14
    jmp .index_general_loaded
.index_gen_load_char:
    mov rsi, asm_movsx_byte_rax
    call emit_string
    mov qword [gen_expr_type], TOK_KW_CHAR
    jmp .index_general_loaded
.index_general_neg:
    ; Pop the pushed base (discard)
    mov rsi, asm_pop_rbx
    call emit_string
    xor rax, rax
.index_general_loaded:
    ; Pointer-element arrays: chain the pointee's field array so a following
    ; `->field` resolves (gen_index_elem_fields is 0 for every other case).
    mov rax, [gen_index_elem_fields]
    test rax, rax
    jz .index_general_done
    mov [gen_expr_struct_fields], rax
.index_general_done:
    jmp .done

.index_global_ptr:
    ; Pointer variable: mov rax, [g_name] (load the pointer value)
    ; Strip PTR_TYPE_FLAG to get base type for scaling
    sub r14, PTR_TYPE_FLAG
    mov rsi, asm_mov_rax_g
    call emit_string
    mov rsi, r15
    call strip_g_prefix              ; user globals may already spell g_name
    call emit_string
    mov rsi, asm_close_bracket
    call emit_string
    ; A pointer to a struct carries the pointee's field array in `extra`
    ; (rbx here). Set it so the struct-element stride resolves instead of
    ; depending on a stale gen_expr_struct_fields from an earlier expression.
    push rax
    push rdi
    mov rdi, r14
    call type_is_struct_or_ptr
    pop rdi
    test rax, rax
    jz .index_global_ptr_nofield
    mov [gen_expr_struct_fields], rbx
.index_global_ptr_nofield:
    pop rax
    jmp .index_common

.index_local:
    mov r13, rax                         ; r13 = negative offset
    mov r14, rbx                         ; r14 = type (for size)
    mov rbx, rcx                         ; rbx = extra/element count (callee-saved)
    pop rdi                              ; discard
    test r13, r13
    jz .done

    ; VLA: extra == -1 → base pointer lives in [rbp-|offset|], count in
    ; [rbp-|offset|+8] (i.e. slot-8). Load the base pointer value and treat
    ; the access like a pointer index for scaling, but bounds-check against
    ; the runtime count stored in the slot.
    cmp rbx, -1
    je .index_local_vla

    ; Check if pointer variable — load value instead of lea
    cmp r14, PTR_TYPE_FLAG
    jae .index_local_ptr

    ; Array base: lea rax, [rbp - |offset|]
    mov rdi, r13
    neg rdi                              ; rdi = positive offset
    push rdi
    mov rsi, asm_lea_rax_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    pop rdi
    jmp .index_common

.index_local_vla:
    ; r13 = negative offset of base-ptr slot (callee-saved, preserved by emit).
    ; Load base pointer: mov rax, [rbp-|offset|]
    mov rdi, r13
    neg rdi                              ; rdi = positive offset
    push rdi
    mov rsi, asm_load_qword_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    pop rdi
    ; VLA count is at [rbp - (offset - 8)] (less-negative half of the 16-byte
    ; slot; base ptr is at the more-negative end [rbp - |offset|]).
    ; Emit: mov r9, qword [rbp-|offset-8|]  (count for bounds check)
    mov rsi, asm_mov_r9_rbp              ; "    mov r9, qword [rbp-"
    call emit_string
    mov rdi, r13
    neg rdi
    sub rdi, 8                          ; count slot = base_offset - 8 (less negative)
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    ; r14 = element type (int/char). Push base, eval index, bounds check vs r9.
    mov rsi, asm_push_rax
    call emit_string
    ; Save metadata around index eval.
    mov rax, [gen_expr_struct_fields]
    push rax
    mov rax, [gen_expr_array_count]
    push rax
    mov rdi, [r12 + ast_node_t.data2]
    call gen_expr                        ; rax = index
    pop rax
    mov [gen_expr_array_count], rax
    pop rax
    mov [gen_expr_struct_fields], rax
    ; Bounds check: index >= 0 and index < r9 (runtime count).
    test rax, rax
    jl .index_vla_neg
    ; cmp rax, r9; jae .L_bounds_fail_N  (index >= count → fail)
    mov rsi, asm_cmp_rax_r9
    call emit_string
    mov r13, [label_counter]
    inc qword [label_counter]
    mov rsi, asm_jae_bounds_fail
    call emit_string
    mov rdi, r13
    call emit_int
    mov rsi, asm_newline
    call emit_string
    ; jmp .L_bounds_ok_N
    mov rsi, asm_jmp_bounds_ok
    call emit_string
    mov rdi, r13
    call emit_int
    mov rsi, asm_newline
    call emit_string
    ; .L_bounds_fail_N:
    mov rsi, asm_label_bounds_fail
    call emit_string
    mov rdi, r13
    call emit_int
    mov rsi, asm_label_sep
    call emit_string
    mov rsi, asm_mov_rdi_1
    call emit_string
    mov rsi, asm_mov_rax_60
    call emit_string
    mov rsi, asm_syscall
    call emit_string
    ; .L_bounds_ok_N:
    mov rsi, asm_label_bounds_ok
    call emit_string
    mov rdi, r13
    call emit_int
    mov rsi, asm_label_sep
    call emit_string
.index_vla_neg:
    ; Pop base into rbx, scale index, load element.
    mov rsi, asm_pop_rbx
    call emit_string
    ; rbx = base, rax = index. Scale by element size.
    cmp r14, TOK_KW_CHAR
    je .index_vla_load
    mov rsi, asm_shl_rax_3
    call emit_string
.index_vla_load:
    ; add rbx, rax
    mov rsi, asm_add_rbx_rax
    call emit_string
    ; Load element: char → movsx rax, byte [rbx]; else → mov rax, [rbx]
    cmp r14, TOK_KW_CHAR
    je .index_vla_char
    mov rsi, asm_mov_rax_rbx_indirect
    call emit_string
    jmp .done
.index_vla_char:
    mov rsi, asm_movsx_byte_rbx
    call emit_string
    jmp .done

.index_local_ptr:
    ; Pointer variable: mov rax, [rbp - |offset|] (load the pointer value)
    mov rdi, r13
    neg rdi                              ; rdi = positive offset
    push rdi
    mov rsi, asm_load_qword_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    pop rdi
    ; Strip PTR_TYPE_FLAG to get base type for scaling
    sub r14, PTR_TYPE_FLAG
    ; A pointer to a struct carries the pointee's field array in `extra`
    ; (rbx here). Set it so the struct-element stride resolves instead of
    ; depending on a stale gen_expr_struct_fields from an earlier expression.
    push rax
    push rdi
    mov rdi, r14
    call type_is_struct_or_ptr
    pop rdi
    test rax, rax
    jz .index_local_ptr_nofield
    mov [gen_expr_struct_fields], rbx
.index_local_ptr_nofield:
    pop rax

.index_common:
    ; r13 = extra (0 for non-struct, or field_array_ptr for struct array)
    ; r14 = type (TOK_KW_INT, TOK_KW_CHAR, or TOK_KW_STRUCT for struct array)
    ; rbx = extra (element count, or packed dim1|dim2<<32 for 2D arrays)
    ; rax = base address

    ; --- 2D array support: extract dim2 from extra into a BSS variable ---
    ; For 2D arrays, extra = dim1 | (dim2 << 32). Extract dim2 and save it.
    ; For 1D arrays, dim2 = 0 (upper 32 bits of extra are 0 since count < 2^32).
    mov rax, rbx
    shr rax, 32                      ; rax = dim2 (0 for 1D)
    mov [gen_index_2d_dim2], rax      ; save dim2 for bounds/scale/load steps

    ; Push base address
    mov rsi, asm_push_rax
    call emit_string

    ; Evaluate index expression
    ; The index expression can itself touch struct/array metadata globals, so
    ; save the base expression's metadata first and restore it immediately after.
    mov rax, [gen_expr_struct_fields]
    push rax
    mov rax, [gen_expr_array_count]
    push rax
    mov rdi, [r12 + ast_node_t.data2]
    call gen_expr                        ; rax = index
    pop rax
    mov [gen_expr_array_count], rax
    pop rax
    mov [gen_expr_struct_fields], rax
    ; rax = index value

    ; --- 2D bounds check: use dim1 (low 32 bits) for 2D arrays ---
    mov r9, [gen_index_2d_dim2]          ; r9 = dim2
    test r9, r9
    jz .index_bounds_1d
    ; 2D: bounds check against dim1 = extra & 0xFFFFFFFF
    mov ecx, ebx                     ; ecx = low 32 bits of rbx (dim1), zero-extends to rcx
    cmp rcx, 0
    jle .index_no_bounds
    push rdi
    mov rdi, rcx
    call emit_bounds_check
    pop rdi
    jmp .index_no_bounds
.index_bounds_1d:
    ; --- end 2D bounds ---

    ; Bounds check for non-struct 1D arrays
    cmp r14, TOK_KW_CHAR
    je .index_do_bounds
    cmp r14, TOK_KW_INT
    jne .index_no_bounds
.index_do_bounds:
    cmp rbx, 0
    jle .index_no_bounds
    push rdi
    mov rdi, rbx
    call emit_bounds_check
    pop rdi
.index_no_bounds:

    ; Pop base address into rbx
    mov rsi, asm_pop_rbx
    call emit_string
    ; rbx = base address, rax = index

    ; --- 2D array scaling: stride = dim2 * elem_size ---
    mov r9, [gen_index_2d_dim2]          ; r9 = dim2 (0 for 1D)
    test r9, r9
    jnz .index_scale_2d
    ; 1D: fall through to normal scaling

    ; Scale index by element size
    cmp r14, TOK_KW_CHAR
    je .index_no_scale
    cmp r14, TOK_KW_STRUCT
    je .index_scale_struct
    mov rsi, asm_shl_rax_3
    call emit_string                    ; rax = index * 8
    jmp .index_add_base
.index_scale_2d:
    ; 2D array: stride = dim2 * elem_size
    ; For int: stride = dim2 * 8 = dim2 << 3
    ; For char: stride = dim2 * 1 = dim2
    cmp r14, TOK_KW_CHAR
    je .index_scale_2d_char
    ; int: stride = dim2 * 8
    shl r9, 3                           ; r9 = dim2 * 8
    push r9
    mov rsi, asm_imul_rax_imm
    call emit_string
    pop rdi
    call emit_int
    mov rsi, asm_newline
    call emit_string
    jmp .index_add_base
.index_scale_2d_char:
    ; char: stride = dim2
    push r9
    mov rsi, asm_imul_rax_imm
    call emit_string
    pop rdi
    call emit_int
    mov rsi, asm_newline
    call emit_string
    jmp .index_add_base
.index_scale_struct:
    ; Struct array: extra = field_array_ptr (held in rbx on every path).
    ; Save field_array_ptr for member access
    mov [gen_expr_struct_fields], rbx
    ; Compute struct_size from field array
    mov rdi, rbx
    test rdi, rdi
    jz .index_add_base
    ; struct_total_size clobbers rdi, r8, r9, rcx, rax
    push rdi                   ; save field_array_ptr
    call struct_total_size     ; rax = struct_size
    mov rdi, rax               ; rdi = struct_size
    pop r8                     ; r8 = field_array_ptr
    test rdi, rdi
    jz .index_add_base
    ; rax = index * struct_size
    push rdi                   ; save struct_size (emit_string clobbers rdi)
    mov rsi, asm_imul_rax_imm
    call emit_string
    pop rdi                    ; restore struct_size
    call emit_int
    mov rsi, asm_newline
    call emit_string
    jmp .index_add_base
.index_no_scale:
.index_add_base:
    ; rax = index * elem_size
    ; Add base address: rax = base + offset
    mov rsi, asm_add_rax_rbx
    call emit_string
    ; rax = address of element

    ; --- 2D array: don't load, return address for outer [j] ---
    mov r9, [gen_index_2d_dim2]          ; r9 = dim2
    test r9, r9
    jz .index_load_1d
    ; 2D: keep address, set gen_expr_type to element type for outer index
    mov [gen_expr_type], r14
    mov qword [gen_index_2d_dim2], 0     ; reset flag
    jmp .done
.index_load_1d:
    ; --- end 2D array support ---

    ; Load value (type-aware: byte for char, qword otherwise)
    ; For struct arrays, keep the address (don't load)
    cmp r14, TOK_KW_STRUCT
    je .index_loaded_struct
    cmp r14, TOK_KW_CHAR
    je .index_load_char
    mov rsi, asm_mov_rax_from_rax
    call emit_string
    jmp .index_loaded
.index_loaded_struct:
    ; For struct arrays, rax = address of element. Set type to struct.
    mov [gen_expr_type], r14
    jmp .done
.index_load_char:
    mov rsi, asm_movsx_byte_rax
    call emit_string
.index_loaded:
    mov [gen_expr_type], r14              ; element type
    ; If the element is a pointer to a struct (struct T*, struct T**, ...),
    ; remember the pointee's field array (the symbol's `extra`, held in rbx on
    ; every path through .index_common) so `p->field` and `p[i]->field` can
    ; resolve fields. rax holds the loaded value, so save it around the call.
    push rax
    push rbx
    mov rdi, r14
    call type_base_is_struct
    mov r8, rax
    pop rbx
    pop rax
    test r8, r8
    jz .index_loaded_nofield
    mov [gen_expr_struct_fields], rbx
    jmp .index_loaded_done
.index_loaded_nofield:
    ; Arrays of struct pointers register their element as TOK_KW_INT (8-byte
    ; elements), so the type alone cannot say the pointee is a struct. The
    ; pointee's field array rides in the symbol's `.fields` slot, captured
    ; from found_symbol_fields by the ident fast paths into
    ; gen_index_elem_fields.
    mov rax, [gen_index_elem_fields]
    test rax, rax
    jz .index_loaded_done
    mov [gen_expr_struct_fields], rax
.index_loaded_done:
    jmp .done

.call_expr:
    mov rdi, r12
    call gen_call

    ; Set gen_expr_type to the function's return type
    push r12
    mov rdi, [r12 + ast_node_t.data1]     ; function name
    call find_func_return
    ; rax = return type, rdx = field_array_ptr
    mov [gen_expr_type], rax
    mov [gen_expr_struct_fields], rdx
    pop r12
    jmp .done

.cast:
    ; Runtime no-op cast: evaluate the inner expression, then overwrite the
    ; compile-time type metadata so later deref/member/index code sees the
    ; target type instead of the source expression's default type.
    mov rdi, [r12 + ast_node_t.data2]
    call gen_expr
    mov rax, [r12 + ast_node_t.data1]      ; target type
    mov [gen_expr_type], rax
    cmp rax, TOK_KW_STRUCT
    je .cast_keep_fields
    cmp rax, PTR_TYPE_FLAG
    jb .cast_clear_fields
    mov rcx, rax
    sub rcx, PTR_TYPE_FLAG
    cmp rcx, TOK_KW_STRUCT
    je .cast_keep_fields
.cast_clear_fields:
    mov qword [gen_expr_struct_fields], 0
    mov qword [gen_expr_array_count], 0
    jmp .done
.cast_keep_fields:
    mov rax, [r12 + ast_node_t.data3]      ; field_array_ptr for struct casts
    mov [gen_expr_struct_fields], rax
    mov qword [gen_expr_array_count], 0
    jmp .done

; ------------------------------------------------------------
; .logical_and — short-circuit &&
; data2 = left, data3 = right
; ------------------------------------------------------------
.logical_and:
    ; Evaluate left operand
    mov rdi, [r12 + ast_node_t.data2]
    call gen_expr

    ; if left == 0, short-circuit to false (0)
    mov rsi, asm_cmp_rax_0
    call emit_string
    mov rax, [label_counter]
    inc qword [label_counter]
    push rax
    mov rsi, asm_je_land_false
    call emit_string
    pop rax
    push rax
    mov rdi, rax
    call emit_int
    mov rsi, asm_newline
    call emit_string

    ; Evaluate right operand
    mov rdi, [r12 + ast_node_t.data3]
    call gen_expr

    ; Convert right to boolean (0 or 1)
    mov rsi, asm_cmp_rax_0
    call emit_string
    mov rsi, asm_setne
    call emit_string

    ; Jump to done
    mov rsi, asm_jmp_land_done
    call emit_string
    pop rax
    push rax
    mov rdi, rax
    call emit_int
    mov rsi, asm_newline
    call emit_string

    ; .L_land_false_N:
    mov rsi, asm_label_land_false
    call emit_string
    pop rax
    push rax
    mov rdi, rax
    call emit_int
    mov rsi, asm_label_sep
    call emit_string

    ; xor rax, rax  (result = 0)
    mov rsi, asm_xor_rax_rax
    call emit_string

    ; .L_land_done_N:
    mov rsi, asm_label_land_done
    call emit_string
    pop rax
    mov rdi, rax
    call emit_int
    mov rsi, asm_label_sep
    call emit_string

    mov qword [gen_expr_type], TOK_KW_INT
    jmp .done

; ------------------------------------------------------------
; .logical_or — short-circuit ||
; data2 = left, data3 = right
; ------------------------------------------------------------
.logical_or:
    ; Evaluate left operand
    mov rdi, [r12 + ast_node_t.data2]
    call gen_expr

    ; if left != 0, short-circuit to true (1)
    mov rsi, asm_cmp_rax_0
    call emit_string
    mov rax, [label_counter]
    inc qword [label_counter]
    push rax
    mov rsi, asm_jne_lor_true
    call emit_string
    pop rax
    push rax
    mov rdi, rax
    call emit_int
    mov rsi, asm_newline
    call emit_string

    ; Evaluate right operand
    mov rdi, [r12 + ast_node_t.data3]
    call gen_expr

    ; Convert right to boolean (0 or 1)
    mov rsi, asm_cmp_rax_0
    call emit_string
    mov rsi, asm_setne
    call emit_string

    ; Jump to done
    mov rsi, asm_jmp_lor_done
    call emit_string
    pop rax
    push rax
    mov rdi, rax
    call emit_int
    mov rsi, asm_newline
    call emit_string

    ; .L_lor_true_N:
    mov rsi, asm_label_lor_true
    call emit_string
    pop rax
    push rax
    mov rdi, rax
    call emit_int
    mov rsi, asm_label_sep
    call emit_string

    ; mov rax, 1  (result = 1)
    mov rsi, asm_mov_rax_1
    call emit_string

    ; .L_lor_done_N:
    mov rsi, asm_label_lor_done
    call emit_string
    pop rax
    mov rdi, rax
    call emit_int
    mov rsi, asm_label_sep
    call emit_string

    mov qword [gen_expr_type], TOK_KW_INT
    jmp .done

; ------------------------------------------------------------
; post_incr / post_decr: returns old value, modifies variable
; AST_POST_INCR/DECR: data1 = lvalue (AST_IDENT, or AST_MEMBER for const reject)
; ------------------------------------------------------------
.post_incr:
    mov rdi, [r12 + ast_node_t.data1]       ; lvalue node
    mov rax, [rdi + ast_node_t.type]
    cmp rax, AST_MEMBER
    je .post_member_const_check
    mov rdi, [rdi + ast_node_t.data1]       ; name_ptr
    push rdi                                ; save name_ptr
    call find_symbol
    test rax, rax
    jnz .post_local
    pop rdi
    push rdi
    call find_global_symbol
    test rax, rax
    jnz .post_global
    pop rdi
    xor rax, rax
    jmp .done

.post_member_const_check:
    ; t.field++ / ++t.field: reject if field (or chain leaf) is const.
    ; Full member post-inc codegen is not implemented; only reject const.
    push rdi
    mov rax, [rdi + ast_node_t.data1]
    cmp rax, 60
    jb .post_member_expr_base
    ; Flat member: data1 is struct name string
    mov rdi, rax
    call find_symbol
    test rax, rax
    jnz .post_member_have_fields
    pop rdi
    push rdi
    mov rdi, [rdi + ast_node_t.data1]
    call find_global_symbol
    test rax, rax
    jz .post_member_no_fields
.post_member_have_fields:
    test rcx, rcx
    jz .post_member_no_fields
    pop rdi
    push rdi
    mov rsi, [rdi + ast_node_t.data2]
    mov rdi, rcx
    call find_field
    cmp qword [find_field_is_const], 0
    je .post_member_no_fields
    pop rdi
    mov rdi, [rdi + ast_node_t.data2]
    call report_const_error
    xor rax, rax
    jmp .done
.post_member_expr_base:
    ; Chained/expression member: walk via gen_expr_struct_fields is incomplete;
    ; try leaf field via find_field after resolving known fields.
.post_member_no_fields:
    pop rdi
    ; Also reject if base is const symbol (const struct var)
    mov rax, [rdi + ast_node_t.data1]
    cmp rax, 60
    jb .post_member_allow_partial
    mov rdi, rax
    push rdi
    call find_symbol_index
    cmp rax, 0
    jl .post_member_try_global
    mov r11, [symbol_const_ptr]
    cmp byte [r11 + rax], 0
    je .post_member_try_global
    pop rdi
    call report_const_error
    xor rax, rax
    jmp .done
.post_member_try_global:
    pop rdi
    push rdi
    call find_global_symbol_index
    cmp rax, 0
    jl .post_member_allow_partial_pop
    mov r11, [global_symbol_const_ptr]
    cmp byte [r11 + rax], 0
    je .post_member_allow_partial_pop
    pop rdi
    call report_const_error
    xor rax, rax
    jmp .done
.post_member_allow_partial_pop:
    pop rdi
.post_member_allow_partial:
    xor rax, rax
    jmp .done

.post_global:
    ; rax = name_ptr, rbx = type
    mov r14, rax                           ; r14 = name_ptr
    mov r13, rbx                           ; r13 = type
    pop rdi                                ; discard saved name_ptr

    ; Load old value from global
    cmp r13, TOK_KW_CHAR
    je .post_global_char
    mov rsi, asm_mov_rax_g
    call emit_string
    mov rsi, r14
    call strip_g_prefix                  ; user globals may already spell g_name
    call emit_string
    mov rsi, asm_close_bracket
    call emit_string
    jmp .post_modify

.post_global_char:
    mov rsi, asm_movsx_rax_byte_g
    call emit_string
    mov rsi, r14
    call emit_string
    mov rsi, asm_close_bracket
    call emit_string
    jmp .post_modify

.post_local:
    mov r13, rax                           ; r13 = negative offset
    mov r14, rbx                           ; r14 = type
    pop rdi                                ; discard name_ptr

    ; Load old value from local
    mov rdi, r13
    neg rdi                                ; rdi = positive offset
    cmp r14, TOK_KW_CHAR
    je .post_local_char
    push rdi
    mov rsi, asm_load_qword_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    pop rdi
    jmp .post_modify

.post_local_char:
    push rdi
    mov rsi, asm_load_byte_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    pop rdi

.post_modify:
    ; rax = old value at runtime. Push it.
    mov rsi, asm_push_rax
    call emit_string

    ; Increment: inc rax
    mov rsi, asm_inc_rax
    call emit_string

    ; Store new value back
    cmp r13, 0
    js .post_store_local                   ; r13 negative = local
    ; Global store
    cmp r14, TOK_KW_CHAR
    je .post_store_global_char
    mov rsi, asm_store_g_prefix
    call emit_string
    mov rsi, [r12 + ast_node_t.data1]      ; AST_IDENT node
    mov rsi, [rsi + ast_node_t.data1]      ; name_ptr
    call emit_string
    mov rsi, asm_store_g_rax_sfx
    call emit_string
    jmp .post_restore
.post_store_global_char:
    mov rsi, asm_store_g_prefix
    call emit_string
    mov rsi, [r12 + ast_node_t.data1]      ; AST_IDENT node
    mov rsi, [rsi + ast_node_t.data1]      ; name_ptr
    call emit_string
    mov rsi, asm_store_g_al_sfx
    call emit_string
    jmp .post_restore

.post_store_local:
    mov rdi, r13
    neg rdi
    cmp r14, TOK_KW_CHAR
    je .post_store_local_char
    push rdi
    mov rsi, asm_mov_qword_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_rbp_rax
    call emit_string
    pop rdi
    jmp .post_restore
.post_store_local_char:
    push rdi
    mov rsi, asm_mov_byte_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_rbp_al
    call emit_string
    pop rdi

.post_restore:
    ; Pop old value into rbx, then move to rax for return value
    mov rsi, asm_pop_rbx
    call emit_string
    mov rsi, asm_mov_rax_rbx
    call emit_string

    mov qword [gen_expr_type], r14
    jmp .done

; ------------------------------------------------------------
; post_decr: same as post_incr but decrements
; ------------------------------------------------------------
.post_decr:
    mov rdi, [r12 + ast_node_t.data1]       ; lvalue node
    mov rax, [rdi + ast_node_t.type]
    cmp rax, AST_MEMBER
    je .post_member_const_check
    mov rdi, [rdi + ast_node_t.data1]       ; name_ptr
    push rdi
    call find_symbol
    test rax, rax
    jnz .postd_local
    pop rdi
    push rdi
    call find_global_symbol
    test rax, rax
    jnz .postd_global
    pop rdi
    xor rax, rax
    jmp .done

.postd_global:
    mov r14, rax
    mov r13, rbx
    pop rdi
    cmp r13, TOK_KW_CHAR
    je .postd_global_char
    mov rsi, asm_mov_rax_g
    call emit_string
    mov rsi, r14
    call strip_g_prefix                  ; user globals may already spell g_name
    call emit_string
    mov rsi, asm_close_bracket
    call emit_string
    jmp .postd_modify
.postd_global_char:
    mov rsi, asm_movsx_rax_byte_g
    call emit_string
    mov rsi, r14
    call emit_string
    mov rsi, asm_close_bracket
    call emit_string
    jmp .postd_modify

.postd_local:
    mov r13, rax
    mov r14, rbx
    pop rdi
    mov rdi, r13
    neg rdi
    cmp r14, TOK_KW_CHAR
    je .postd_local_char
    push rdi
    mov rsi, asm_load_qword_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    pop rdi
    jmp .postd_modify
.postd_local_char:
    push rdi
    mov rsi, asm_load_byte_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    pop rdi

.postd_modify:
    mov rsi, asm_push_rax
    call emit_string

    ; Decrement: dec rax
    mov rsi, asm_dec_rax
    call emit_string

    ; Store new value back
    cmp r13, 0
    js .postd_store_local
    cmp r14, TOK_KW_CHAR
    je .postd_store_global_char
    mov rsi, asm_store_g_prefix
    call emit_string
    mov rsi, [r12 + ast_node_t.data1]
    mov rsi, [rsi + ast_node_t.data1]
    call emit_string
    mov rsi, asm_store_g_rax_sfx
    call emit_string
    jmp .postd_restore
.postd_store_global_char:
    mov rsi, asm_store_g_prefix
    call emit_string
    mov rsi, [r12 + ast_node_t.data1]
    mov rsi, [rsi + ast_node_t.data1]
    call emit_string
    mov rsi, asm_store_g_al_sfx
    call emit_string
    jmp .postd_restore

.postd_store_local:
    mov rdi, r13
    neg rdi
    cmp r14, TOK_KW_CHAR
    je .postd_store_local_char
    push rdi
    mov rsi, asm_mov_qword_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_rbp_rax
    call emit_string
    pop rdi
    jmp .postd_restore
.postd_store_local_char:
    push rdi
    mov rsi, asm_mov_byte_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_rbp_al
    call emit_string
    pop rdi

.postd_restore:
    mov rsi, asm_pop_rbx
    call emit_string
    mov rsi, asm_mov_rax_rbx
    call emit_string

    mov qword [gen_expr_type], r14
    jmp .done

.member:
    ; s.field — struct_name in data1, field_name in data2
    ; data1 may be a string (name_ptr) or an AST_MEMBER node (chained access)
    ; or an expression node (e.g., AST_UNARY_OP for *t in (*t).field)
    mov rdi, [r12 + ast_node_t.data1]
    mov rax, [rdi]                      ; peek first qword
    cmp rax, AST_MEMBER
    je .member_chained
    cmp rax, 60                         ; below 60 = AST type = expression base
    jb .member_expr_base

    ; --- Flat member access (data1 = struct name string) ---
    push rdi
    call find_symbol
    ; rax = negative offset, rbx = type, rcx = extra (field_array_ptr)
    mov r13, rax                         ; r13 = struct negative offset
    mov r14, rcx                         ; r14 = field_array_ptr
    pop rdi                              ; discard

    test r13, r13
    jnz .member_local

    ; Try global struct
    mov rdi, [r12 + ast_node_t.data1]   ; struct name_ptr
    push rdi
    call find_global_symbol
    ; rax = name_ptr, rbx = type, rcx = extra (field_array_ptr)
    mov r13, rax                         ; r13 = name_ptr (for emit)
    mov r14, rcx                         ; r14 = field_array_ptr
    pop rdi                              ; discard
    test r13, r13
    jz .done
    test r14, r14
    jz .done

    ; Global struct — search for field
    mov rdi, r14
    mov rsi, [r12 + ast_node_t.data2]    ; field_name_ptr
    call find_field
    ; rax = field_offset, rbx = field_type, rcx = sub_array_ptr
    test rbx, rbx
    jz .mem_no_such_field
    mov r15, rax                         ; r15 = field_offset
    mov r14, rbx                         ; r14 = field_type
    mov r9, rcx                          ; r9 = element count / sub_array_ptr

    ; Emit address: lea rax, [g_name + field_offset]
    mov rsi, r13
    call strip_g_prefix
    mov r13, rsi
    mov rsi, asm_lea_rax_g
    call emit_string
    mov rsi, r13                         ; name_ptr
    call emit_string
    ; Always emit the offset, even when it is zero, so the code path stays
    ; uniform for the first field in a struct.
    push rdi
    push rsi
    mov dil, '+'
    call out_write_char
    mov rdi, r15
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    pop rsi
    pop rdi
    ; Check if array field — return address instead of loading value
    push rax                             ; save computed address
    mov rax, r14
    cmp rax, ARRAY_TYPE_FLAG
    jae .member_global_array             ; anything >= ARRAY_TYPE_FLAG is an array field
    pop rax                              ; restore address — not an array field

    ; Load value from address (type-aware load)
    ; A struct field yields its address (struct value semantics).
    cmp r14, TOK_KW_STRUCT
    je .member_global_struct
    cmp r14, TOK_KW_CHAR
    je .member_global_load_char
    mov rsi, asm_mov_rax_from_rax
    call emit_string
    mov [gen_expr_type], r14
    ; struct T*..** field: preserve pointee field_array_ptr for later indexing
    ; (e.g. def.fields[i] where fields is struct Field*). Works at any depth.
    push r9
    mov rdi, r14
    call type_base_is_struct
    pop r9
    test rax, rax
    jz .member_global_loaded
    mov [gen_expr_struct_fields], r9
.member_global_loaded:
    jmp .done
.member_global_struct:
    ; Keep the address; remember the sub field array for chained access.
    mov [gen_expr_type], r14
    mov [gen_expr_struct_fields], r9
    jmp .done
.member_global_load_char:
    mov rsi, asm_movsx_byte_rax
    call emit_string
    mov qword [gen_expr_type], TOK_KW_CHAR
    jmp .done

.member_global_array:
    ; Array field — rax (on stack) holds address, set type to pointer
    ; r9 = sub_array_ptr (element count or info struct ptr for struct arrays)
    mov rax, r14
    sub rax, ARRAY_TYPE_FLAG
    cmp rax, TOK_KW_STRUCT
    jne .mga_scalar
    ; Struct array field: r9 is pointer to [element_count, field_array_ptr]
    mov rax, [r9]
    mov [gen_expr_array_count], rax
    mov rax, [r9 + 8]
    mov [gen_expr_struct_fields], rax
    jmp .mga_type_done
.mga_scalar:
    ; Pointer-element array fields pack [count, pointee_field_array] into an
    ; info struct; scalar array fields keep a bare count.
    mov rax, r14
    sub rax, ARRAY_TYPE_FLAG
    cmp rax, PTR_TYPE_FLAG
    jb .mga_scalar_count
    push rax
    mov rax, [r9]
    mov [gen_expr_array_count], rax
    mov rax, [r9 + 8]
    mov [gen_index_elem_fields], rax
    pop rax
    jmp .mga_type_done
.mga_scalar_count:
    mov [gen_expr_array_count], r9       ; save element count for bounds checking
.mga_type_done:
    sub r14, ARRAY_TYPE_FLAG             ; r14 = element type
    cmp r14, PTR_TYPE_FLAG
    jae .mga_ptr_done                    ; element type already has pointer flag — use as-is
    add r14, PTR_TYPE_FLAG               ; make it pointer type
.mga_ptr_done:
    mov [gen_expr_type], r14
    pop rax                              ; restore address (result)
    jmp .done

.member_chained:
    ; base (data1) is an expression: AST_MEMBER (nested struct) or AST_INDEX
    ; (o[i].field) or similar. Compute the base's address with gen_addr, then
    ; apply the current field.
    mov rdi, [r12 + ast_node_t.data1]
    push r12
    call gen_addr
    pop r12
    test rax, rax
    jz .mem_bad
    ; rax = base address (runtime); gen_expr_struct_fields = base field array
    mov rdi, [gen_expr_struct_fields]
    test rdi, rdi
    jz .mem_bad
    push rax                            ; save base address
    mov rsi, [r12 + ast_node_t.data2]   ; field name
    call find_field
    test rbx, rbx
    jz .mc_no_such_field
    ; rax = field_offset, rbx = field type, rcx = sub_array_ptr
    mov r13, rbx                        ; r13 = field type
    mov r9, rcx                         ; r9 = element count / sub_array_ptr
    mov r15, rax                        ; r15 = field offset
    pop rax                             ; restore base address

    ; Emit: add rax, current_field_offset (always, including offset 0)
    push r13
    push r9
    mov rsi, asm_add_rax_imm
    call emit_string
    mov rdi, r15
    call emit_int
    mov rsi, asm_newline
    call emit_string
    pop r9
    pop r13

    ; Check if array field — return address instead of loading value
    push rax                             ; save computed address
    mov rax, r13
    cmp rax, ARRAY_TYPE_FLAG
    jae .mc_load_array                    ; anything >= ARRAY_TYPE_FLAG is an array field
    pop rax                              ; restore address — not an array field

    ; Struct field: keep the address (struct value semantics)
    cmp r13, TOK_KW_STRUCT
    je .mc_keep_addr

    cmp r13, TOK_KW_CHAR
    je .mc_load_char
    mov rsi, asm_mov_rax_from_rax
    call emit_string
    mov [gen_expr_type], r13
    ; struct T*..** field: preserve pointee field_array_ptr for later indexing.
    push r9
    mov rdi, r13
    call type_base_is_struct
    pop r9
    test rax, rax
    jz .mc_loaded
    mov [gen_expr_struct_fields], r9
.mc_loaded:
    jmp .done
.mc_keep_addr:
    mov [gen_expr_type], r13
    mov [gen_expr_struct_fields], r9
    jmp .done
.mc_no_such_field:
    pop rax
    mov rdi, [r12 + ast_node_t.data2]    ; field name
    call report_no_field
    jmp .mem_bad
.mc_load_char:
    mov rsi, asm_movsx_byte_rax
    call emit_string
    mov qword [gen_expr_type], TOK_KW_CHAR
    jmp .done

.mc_load_array:
    ; Array field — rax (on stack) holds address, set type to pointer
    ; r9 = sub_array_ptr, r13 = field type (with ARRAY_TYPE_FLAG)
    mov rax, r13
    sub rax, ARRAY_TYPE_FLAG
    cmp rax, TOK_KW_STRUCT
    jne .mcla_scalar
    ; Struct array field: r9 is pointer to [element_count, field_array_ptr]
    mov rax, [r9]
    mov [gen_expr_array_count], rax
    mov rax, [r9 + 8]
    mov [gen_expr_struct_fields], rax
    jmp .mcla_type_done
.mcla_scalar:
    ; Pointer-element array fields pack [count, pointee_field_array] into an
    ; info struct; scalar array fields keep a bare count.
    mov rax, r13
    sub rax, ARRAY_TYPE_FLAG
    cmp rax, PTR_TYPE_FLAG
    jb .mcla_scalar_count
    push rax
    mov rax, [r9]
    mov [gen_expr_array_count], rax
    mov rax, [r9 + 8]
    mov [gen_index_elem_fields], rax
    pop rax
    jmp .mcla_type_done
.mcla_scalar_count:
    mov [gen_expr_array_count], r9       ; save element count for bounds checking
.mcla_type_done:
    sub r13, ARRAY_TYPE_FLAG             ; r13 = element type
    cmp r13, PTR_TYPE_FLAG
    jae .mcla_ptr_done                   ; element type already has pointer flag — use as-is
    add r13, PTR_TYPE_FLAG               ; make it pointer type
.mcla_ptr_done:
    mov [gen_expr_type], r13
    pop rax                              ; restore address (result)
    jmp .done

.member_local:
    test r14, r14
    jz .done

    ; Search for field
    mov rdi, r14                         ; field_array_ptr
    mov rsi, [r12 + ast_node_t.data2]    ; field_name_ptr
    call find_field
    ; rax = field_offset, rbx = field_type, rcx = sub_array_ptr
    test rbx, rbx
    jz .mem_no_such_field                ; field not found: hard error
    mov r15, rax                         ; r15 = field_offset
    mov r14, rbx                         ; r14 = field_type
    mov r9, rcx                          ; r9 = element count / sub_array_ptr

    ; Compute address: rbp - |struct_offset| + field_offset
    mov rdi, r13
    neg rdi                              ; rdi = positive struct offset
    sub rdi, r15                         ; rdi = struct_offset - field_offset

    push rdi
    mov rsi, asm_lea_rax_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    pop rdi

    ; Check if array field — return address instead of loading value
    push rax                             ; save computed address
    mov rax, r14
    cmp rax, ARRAY_TYPE_FLAG
    jae .member_local_array              ; anything >= ARRAY_TYPE_FLAG is an array field
    pop rax                              ; restore address — not an array field

    ; Load value from address (type-aware load)
    ; A struct field yields its address (struct value semantics).
    cmp r14, TOK_KW_STRUCT
    je .member_local_struct
    cmp r14, TOK_KW_CHAR
    je .member_local_load_char
    mov rsi, asm_mov_rax_from_rax
    call emit_string
    mov [gen_expr_type], r14
    ; struct T*..** field: preserve pointee field_array_ptr for later indexing.
    push r9
    mov rdi, r14
    call type_base_is_struct
    pop r9
    test rax, rax
    jz .member_local_loaded
    mov [gen_expr_struct_fields], r9
.member_local_loaded:
    jmp .done
.member_local_struct:
    ; Keep the address; remember the sub field array for chained access.
    mov [gen_expr_type], r14
    mov [gen_expr_struct_fields], r9
    jmp .done
.member_local_load_char:
    mov rsi, asm_movsx_byte_rax
    call emit_string
    mov qword [gen_expr_type], TOK_KW_CHAR
    jmp .done

.member_local_array:
    ; Array field — rax (on stack) holds address, set type to pointer
    ; r9 = sub_array_ptr (element count or info struct ptr for struct arrays)
    mov rax, r14
    sub rax, ARRAY_TYPE_FLAG
    cmp rax, TOK_KW_STRUCT
    jne .mla_scalar
    ; Struct array field: r9 is pointer to [element_count, field_array_ptr]
    mov rax, [r9]
    mov [gen_expr_array_count], rax
    mov rax, [r9 + 8]
    mov [gen_expr_struct_fields], rax
    jmp .mla_type_done
.mla_scalar:
    ; Pointer-element array fields pack [count, pointee_field_array] into an
    ; info struct (see parser .ns_no_struct_info); scalar array fields keep a
    ; bare count. The stripped element type tells them apart.
    mov rax, r14
    sub rax, ARRAY_TYPE_FLAG
    cmp rax, PTR_TYPE_FLAG
    jb .mla_scalar_count
    push rax
    mov rax, [r9]                        ; info[0] = element count
    mov [gen_expr_array_count], rax
    mov rax, [r9 + 8]                    ; info[8] = pointee field_array_ptr
    mov [gen_index_elem_fields], rax
    pop rax
    jmp .mla_type_done
.mla_scalar_count:
    mov [gen_expr_array_count], r9       ; save element count for bounds checking
.mla_type_done:
    sub r14, ARRAY_TYPE_FLAG             ; r14 = element type
    cmp r14, PTR_TYPE_FLAG
    jae .mla_ptr_done                    ; element type already has pointer flag — use as-is
    add r14, PTR_TYPE_FLAG               ; make it pointer type
.mla_ptr_done:
    mov [gen_expr_type], r14
    pop rax                              ; restore address (result)
    jmp .done

.mem_no_such_field:
    mov rdi, [r12 + ast_node_t.data2]    ; field name
    call report_no_field
.mem_bad:
    xor rax, rax
    jmp .done

; ------------------------------------------------------------
; Expression-based member access: (*expr).field
; data1 = expression node (typically AST_UNARY_OP with STAR)
; data2 = field name
; ------------------------------------------------------------
.member_expr_base:
    ; rdi = data1 (expression node for *t, etc.)
    push rdi
    mov rax, [rdi + ast_node_t.type]
    cmp rax, AST_UNARY_OP
    jne .member_expr_eval
    mov rax, [rdi + ast_node_t.data1]    ; operator
    cmp rax, TOK_STAR
    jne .member_expr_eval

    ; (*expr).field — special-case dereference:
    ; evaluate expr (NOT the STAR), get pointer value = struct address
    mov rdi, [rdi + ast_node_t.data2]    ; deref operand
    call gen_expr                         ; rax = pointer value (struct address)
    jmp .member_expr_have_addr

.member_expr_eval:
    ; General expression base — try to compute an address directly.
    pop rdi
    push rdi
    call gen_addr
    test rax, rax
    jz .member_expr_value
    mov rax, [gen_expr_struct_fields]
    test rax, rax
    jz .member_expr_value
    ; rax = base address; gen_expr_struct_fields holds the base field array.
    pop rdi                              ; discard data1 (matches .member_expr_have_addr)
    jmp .member_expr_have_addr2

.member_expr_value:
    ; Fall back to evaluating the expression as-is.
    pop rdi
    push rdi
    call gen_expr                         ; rax = value

.member_expr_have_addr:
    pop rbx                              ; rbx = data1 (discard)
    ; rax = struct address/pointer (at RUNTIME)
.member_expr_have_addr2:

    ; Get field_array_ptr from gen_expr_struct_fields
    mov rdi, [gen_expr_struct_fields]
    test rdi, rdi
    jz .done                             ; no field array — can't resolve

    ; Found field array — save struct address
    push rax                             ; save struct address on compiler stack

    ; Find field offset
    mov rsi, [r12 + ast_node_t.data2]    ; field name ptr
    call find_field
    ; rax = field_offset, rbx = field_type, rcx = sub_array_ptr
    test rbx, rbx
    jz .member_expr_no_such_field
    mov r15, rax                         ; r15 = field_offset
    mov r14, rbx                         ; r14 = field_type
    mov r9, rcx                          ; r9 = element count / sub_array_ptr

    pop rax                              ; rax = saved struct address (restore)
    ; Emit: add rax, <field_offset> for every field, including offset 0.
    push r15
    mov rsi, asm_add_rax_imm
    call emit_string
    pop rdi
    call emit_int
    mov rsi, asm_newline
    call emit_string
    ; rax = struct_address + field_offset (at RUNTIME)

    ; Check if array field — return address instead of loading value
    push rax                             ; save computed address
    mov rax, r14
    cmp rax, ARRAY_TYPE_FLAG
    jae .member_expr_array               ; anything >= ARRAY_TYPE_FLAG is an array field
    pop rax                              ; restore address — not an array field

    ; Load from computed address
    ; A struct field yields its address (struct value semantics).
    cmp r14, TOK_KW_STRUCT
    je .member_expr_keep_addr
    cmp r14, TOK_KW_CHAR
    je .member_expr_load_char

    ; Qword load
    mov rsi, asm_mov_rax_from_rax
    call emit_string
    jmp .member_expr_loaded

.member_expr_keep_addr:
    mov [gen_expr_type], r14
    mov [gen_expr_struct_fields], r9
    jmp .done

.member_expr_load_char:
    mov rsi, asm_movsx_byte_rax
    call emit_string

.member_expr_loaded:
    mov [gen_expr_type], r14
    ; struct T*..** field: preserve pointee field_array_ptr for later indexing.
    push r9
    mov rdi, r14
    call type_base_is_struct
    pop r9
    test rax, rax
    jz .member_expr_loaded_done
    mov [gen_expr_struct_fields], r9
.member_expr_loaded_done:
    jmp .done

.member_expr_array:
    ; Array field — rax (on stack) holds address, set type to pointer
    ; r9 = sub_array_ptr, r14 = field type (with ARRAY_TYPE_FLAG)
    mov rax, r14
    sub rax, ARRAY_TYPE_FLAG
    cmp rax, TOK_KW_STRUCT
    jne .mea_scalar
    ; Struct array field: r9 is pointer to [element_count, field_array_ptr]
    mov rax, [r9]
    mov [gen_expr_array_count], rax
    mov rax, [r9 + 8]
    mov [gen_expr_struct_fields], rax
    jmp .mea_type_done
.mea_scalar:
    mov [gen_expr_array_count], r9       ; save element count for bounds checking
.mea_type_done:
    sub r14, ARRAY_TYPE_FLAG             ; r14 = element type
    cmp r14, PTR_TYPE_FLAG
    jae .mea_ptr_done                    ; element type already has pointer flag — use as-is
    add r14, PTR_TYPE_FLAG               ; make it pointer type
.mea_ptr_done:
    mov [gen_expr_type], r14
    pop rax                              ; restore address (result)
    jmp .done

.member_expr_no_such_field:
    pop rax                              ; discard struct address
    mov rdi, [r12 + ast_node_t.data2]    ; field name
    call report_no_field
    jmp .done

.index_no_base:
    ; Base name of `x[i]` is neither a local nor a global (e.g. an
    ; undeclared identifier). The name_ptr pushed before find_global_symbol
    ; must be discarded or the stack grows on every such node and later
    ; codegen walks off the end. Report the undeclared name (hard error)
    ; and yield 0, matching .ident's not-found path.
    pop rdi
    call report_undeclared
    xor rax, rax
    jmp .done

.addr_index_no_base:
    ; Same imbalance as .index_no_base, on the &x[i] path.
    pop rdi
    xor rax, rax
    jmp .done

.addr_no_base:
    ; Same imbalance on the &x path for an undeclared name.
    pop rdi
    xor rax, rax
    jmp .done

.done:
    EPILOGUE r15, r14, r13, r12, rbx

; ================================================================
; type_base_is_struct(rdi = type) -> rax = 1 if the type is a pointer whose
; ultimate pointee is TOK_KW_STRUCT, else 0. Handles any pointer depth, since
; pointer depth is encoded additively (`base + depth*PTR_TYPE_FLAG`).
; Preserves rdi (uses rax as scratch); clobbers rax only.
; ================================================================
type_base_is_struct:
    mov rax, rdi
    cmp rax, PTR_TYPE_FLAG
    jb .tbs_no                        ; below the pointer band → not a pointer
    cmp rax, ARRAY_TYPE_FLAG
    jae .tbs_no                       ; array encoding, not a plain pointer
.tbs_loop:
    cmp rax, PTR_TYPE_FLAG
    jb .tbs_check
    sub rax, PTR_TYPE_FLAG
    jmp .tbs_loop
.tbs_check:
    cmp rax, TOK_KW_STRUCT
    jne .tbs_no
    mov rax, 1
    ret
.tbs_no:
    xor rax, rax
    ret

; ================================================================
; find_field(rdi=field_array_ptr, rsi=field_name_ptr)
; Returns: rax=offset, rbx=type (or 0 if not found)
; ================================================================
find_field:
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13

    mov r12, rdi                         ; r12 = field array base
    mov r13, rsi                         ; r13 = field name to find

    ; Get field count from array header
    mov r8, [r12]                        ; r8 = field count

    ; Get target field name length
    mov rsi, r13
    call strlen
    mov r9, rax                          ; r9 = target name length

    xor r10, r10                         ; r10 = index
.ff_loop:
    cmp r10, r8
    jge .ff_not_found

    ; Field descriptor address = base + 8 + index * 32 (32 bytes per field)
    imul r11, r10, 32
    lea r11, [r12 + 8 + r11]            ; r11 = field descriptor

    ; Compare name lengths
    mov rdi, [r11]                       ; field name_ptr
    push rsi
    push rcx
    mov rsi, rdi
    call strlen
    cmp rax, r9
    pop rcx
    pop rsi
    jne .ff_next

    ; Compare names
    mov rdi, [r11]                       ; field name_ptr
    mov rsi, r13                         ; target name
    mov rdx, r9                          ; length
    call mem_eq
    test rax, rax
    jnz .ff_next                         ; not equal

    ; Found!
    mov rax, [r11 + 8]                   ; offset
    mov rbx, [r11 + 16]                  ; type (may include FIELD_CONST_FLAG)
    mov rcx, [r11 + 24]                  ; sub_array_ptr (0 if not a struct field)
    ; Extract and strip FIELD_CONST_FLAG so callers get a clean type.
    test rbx, FIELD_CONST_FLAG
    jz .ff_not_const
    mov qword [find_field_is_const], 1
    sub rbx, FIELD_CONST_FLAG
    jmp .ff_done
.ff_not_const:
    mov qword [find_field_is_const], 0
    jmp .ff_done

.ff_next:
    inc r10
    jmp .ff_loop

.ff_not_found:
    xor rax, rax
    xor rbx, rbx
    xor rcx, rcx
    mov qword [find_field_is_const], 0
.ff_done:
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    ret

; ================================================================
; resolve_member_chain(rdi = AST_MEMBER*)
; Walks a chain of AST_MEMBER nodes to compute the total field offset.
; For s.inner.a: returns struct's rbp/name offset + inner_offset + a_offset.
; Returns: rax = base_offset (negative rbp offset for local, name_ptr for global)
;          rbx = final field type
;          rcx = final sub_array_ptr (0 if not struct-typed)
;          r8  = 1 if global, 0 if local
;          r9  = total_field_offset (sum of all field offsets)
; ================================================================
; ================================================================
; codegen_cleanup()
; ================================================================
codegen_cleanup:
    ret

; ================================================================
; gen_addr(rdi = AST node) -> rax = 1 on success, 0 on failure
; Emits code that computes the ADDRESS of the given lvalue expression.
;
; Supported forms:
;   IDENT           x            → address of variable x
;   INDEX           base[expr]   → address of element
;   MEMBER          base.field   → address of field (recursive)
; Sets:
;   gen_expr_type         = type of the element addressed (may include
;                           PTR_TYPE_FLAG; struct fields keep TOK_KW_STRUCT)
;   gen_expr_struct_fields = field_array_ptr when the result is a struct or a
;                           struct-array element (so chained access can resolve)
; Clobbers: caller-saved registers (caller must save what it needs).
; ================================================================
gen_addr:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov rax, [r12 + ast_node_t.type]

    cmp rax, AST_IDENT
    je .ga_ident
    cmp rax, AST_INDEX
    je .ga_index
    cmp rax, AST_MEMBER
    je .ga_member
    ; Unsupported form
    xor rax, rax
    jmp .ga_ret

; ----------------------------------------------------------------
.ga_ident:
    mov rdi, [r12 + ast_node_t.data1]   ; name_ptr
    push rdi
    call find_symbol
    ; rax = negative offset, rbx = type, rcx = extra
    test rax, rax
    jnz .ga_ident_local
    ; Global
    pop rdi
    push rdi
    call find_global_symbol
    ; rax = name_ptr, rbx = type, rcx = extra
    test rax, rax
    jz .ga_ident_undeclared
    pop rdi                             ; rdi = name_ptr
    mov [gen_expr_type], rbx
    mov [gen_expr_struct_fields], rcx
    ; Global arrays with ARRAY_TYPE_FLAG: element type = type - ARRAY_TYPE_FLAG
    mov rax, rbx
    cmp rax, ARRAY_TYPE_FLAG
    jb .ga_ident_global_not_arr
    sub rax, ARRAY_TYPE_FLAG
    mov [gen_expr_type], rax
.ga_ident_global_not_arr:
    ; Struct arrays use type == TOK_KW_STRUCT with extra = field_array_ptr.
    mov r9, rdi                         ; r9 = name_ptr
    mov rsi, r9
    call strip_g_prefix
    mov r9, rsi                         ; r9 = stripped name
    ; Emit: lea rax, [rel g_name]  — but if it's a pointer variable, load it.
    mov rax, rbx
    cmp rax, PTR_TYPE_FLAG
    jae .ga_ident_global_ptr
    mov rsi, asm_lea_rax_g
    call emit_string
    mov rsi, r9
    call emit_string
    mov rsi, asm_close_bracket
    call emit_string
    mov rax, 1
    jmp .ga_ret
.ga_ident_global_ptr:
    ; Pointer variable: the variable's value IS the address.
    mov rsi, asm_mov_rax_g
    call emit_string
    mov rsi, r9
    call strip_g_prefix                  ; user globals may already spell g_name
    call emit_string
    mov rsi, asm_close_bracket
    call emit_string
    mov rax, 1
    jmp .ga_ret

.ga_ident_local:
    ; rax = negative offset, rbx = type, rcx = extra
    mov r13, rax                        ; r13 = offset
    mov [gen_expr_type], rbx
    mov [gen_expr_struct_fields], rcx
    pop rdi                             ; discard name_ptr
    mov rax, rbx
    cmp rax, PTR_TYPE_FLAG
    jae .ga_ident_local_ptr
    ; Array or scalar: lea rax, [rbp-offset]
    mov rdi, r13
    neg rdi
    push rdi
    mov rsi, asm_lea_rax_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    pop rdi
    mov rax, 1
    jmp .ga_ret
.ga_ident_local_ptr:
    ; Pointer variable: mov rax, [rbp-offset]
    mov rdi, r13
    neg rdi
    push rdi
    mov rsi, asm_load_qword_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    pop rdi
    mov rax, 1
    jmp .ga_ret

; ----------------------------------------------------------------
.ga_member:
    ; base.field — base = data1, field = data2.
    ; data1 is either a struct name string (flat: s.field) or an AST node
    ; (expression base: s.inner.field, o[i].field, (*p).field).
    mov rdi, [r12 + ast_node_t.data1]
    mov rax, [rdi]                      ; peek first qword
    cmp rax, 60                         ; below 60 = AST node type
    jb .ga_member_expr_base

    ; --- Flat member: data1 is the struct variable name string ---
    push rdi
    call find_symbol
    test rax, rax
    jnz .ga_member_flat_local
    pop rdi
    push rdi
    call find_global_symbol
    test rax, rax
    jz .ga_fail
    ; Global struct: rax = name_ptr, rcx = field_array_ptr
    pop rdi                             ; rdi = name_ptr
    mov r15, rcx                        ; r15 = base field array
    mov r14, rdi                        ; r14 = name ptr
    push r14
    mov rsi, asm_lea_rax_g
    call emit_string
    pop rsi
    call emit_string
    mov rsi, asm_close_bracket
    call emit_string
    jmp .ga_member_flat_have_base
.ga_member_flat_local:
    mov r13, rax                        ; r13 = negative offset
    mov r15, rcx                        ; r15 = base field array
    pop rdi                             ; discard name ptr
    mov rdi, r13
    neg rdi
    push rdi
    mov rsi, asm_lea_rax_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    pop rdi
.ga_member_flat_have_base:
    ; r15 = base field array; rax = base struct address (runtime)
    mov rdi, r15
    test rdi, rdi
    jz .ga_fail
    push rax
    mov rsi, [r12 + ast_node_t.data2]   ; field name
    call find_field
    test rbx, rbx
    jz .ga_member_pop_fail
    mov r13, rax                        ; field offset
    mov r14, rbx                        ; field type
    mov r15, rcx                        ; sub_array_ptr
    pop rax
    jmp .ga_member_apply

.ga_member_expr_base:
    mov rax, [rdi + ast_node_t.type]
    cmp rax, AST_UNARY_OP
    je .ga_member_arrow
    ; Compute address of the base lvalue recursively.
    call gen_addr
    test rax, rax
    jz .ga_fail
    mov rdi, [gen_expr_struct_fields]
    test rdi, rdi
    jz .ga_fail
    push rax                            ; save base address
    mov rsi, [r12 + ast_node_t.data2]   ; field name
    call find_field
    test rbx, rbx
    jz .ga_member_pop_fail
    mov r13, rax                        ; r13 = field offset
    mov r14, rbx                        ; r14 = field type
    mov r15, rcx                        ; r15 = sub_array_ptr
    pop rax                             ; restore base address
    jmp .ga_member_apply

.ga_member_apply:
    ; rax = base address, r13 = field offset, r14 = field type, r15 = sub ptr
    ; Struct-array field: type = ARRAY_TYPE_FLAG + TOK_KW_STRUCT; r15 = info ptr
    mov r8, r14
    sub r8, ARRAY_TYPE_FLAG
    cmp r8, TOK_KW_STRUCT
    je .ga_member_struct_array
    ; Ordinary field (scalar / pointer / struct): element type = strip ARRAY flag
    mov rbx, r14
    cmp rbx, ARRAY_TYPE_FLAG
    jb .ga_member_type_ready
    sub r14, ARRAY_TYPE_FLAG
    ; Non-struct array field: r15 = element count → set array count metadata
    mov [gen_expr_array_count], r15
    jmp .ga_member_type_ready
.ga_member_struct_array:
    sub r14, ARRAY_TYPE_FLAG
    ; r15 = info ptr ([count, field_array_ptr])
    mov r8, [r15]
    mov [gen_expr_array_count], r8
    mov r8, [r15 + 8]
    mov [gen_expr_struct_fields], r8
    ; The element field array is already stored; don't overwrite it below.
    mov [gen_expr_type], r14
    jmp .ga_member_emit
.ga_member_type_ready:
    mov [gen_expr_type], r14
    ; Struct or pointer-to-struct fields: remember the sub field array so
    ; chained member/index access can resolve the pointee at any depth.
    cmp r14, TOK_KW_STRUCT
    je .ga_member_set_fields
    push rax
    push r15
    mov rdi, r14
    call type_base_is_struct
    pop r15
    mov r8, rax
    pop rax
    test r8, r8
    jz .ga_member_not_struct
.ga_member_set_fields:
    mov [gen_expr_struct_fields], r15
.ga_member_not_struct:
.ga_member_emit:
    ; Emit: add rax, field_offset
    push r13
    mov rsi, asm_add_rax_imm
    call emit_string
    pop rdi
    call emit_int
    mov rsi, asm_newline
    call emit_string
    mov rax, 1
    jmp .ga_ret
.ga_member_pop_fail:
    pop rax
    jmp .ga_fail

.ga_member_arrow:
    ; base = *ptr — evaluate ptr to get struct address, then add field offset
    mov rdi, [rdi + ast_node_t.data2]   ; deref operand (the pointer expr)
    call gen_expr                       ; rax = pointer value (= struct address)
    mov rdi, [gen_expr_struct_fields]
    test rdi, rdi
    jz .ga_fail
    push rax
    mov rsi, [r12 + ast_node_t.data2]   ; field name
    call find_field
    test rbx, rbx
    jz .ga_member_pop_fail
    mov r13, rax
    mov r14, rbx
    mov r15, rcx
    pop rax
    mov r8, r14
    sub r8, ARRAY_TYPE_FLAG
    cmp r8, TOK_KW_STRUCT
    je .ga_member_arrow_struct_array
    mov rax, r14
    cmp rax, ARRAY_TYPE_FLAG
    jb .ga_member_arrow_type_ready
    sub r14, ARRAY_TYPE_FLAG
    mov [gen_expr_array_count], r15
    jmp .ga_member_arrow_type_ready
.ga_member_arrow_struct_array:
    sub r14, ARRAY_TYPE_FLAG
    mov r8, [r15]
    mov [gen_expr_array_count], r8
    mov r8, [r15 + 8]
    mov [gen_expr_struct_fields], r8
    mov [gen_expr_type], r14
    jmp .ga_member_arrow_emit
.ga_member_arrow_type_ready:
    mov [gen_expr_type], r14
    cmp r14, TOK_KW_STRUCT
    je .ga_member_arrow_set_fields
    push rax
    push r15
    mov rdi, r14
    call type_base_is_struct
    pop r15
    mov r8, rax
    pop rax
    test r8, r8
    jz .ga_member_arrow_not_struct
.ga_member_arrow_set_fields:
    mov [gen_expr_struct_fields], r15
.ga_member_arrow_not_struct:
.ga_member_arrow_emit:
    push r13
    mov rsi, asm_add_rax_imm
    call emit_string
    pop rdi
    call emit_int
    mov rsi, asm_newline
    call emit_string
    mov rax, 1
    jmp .ga_ret

; ----------------------------------------------------------------
.ga_index:
    ; base[expr] — data1 = base, data2 = index
    mov rdi, [r12 + ast_node_t.data1]
    mov rax, [rdi + ast_node_t.type]
    cmp rax, AST_IDENT
    je .ga_index_ident
    cmp rax, AST_MEMBER
    je .ga_index_member
    cmp rax, AST_INDEX
    je .ga_index_member               ; nested indexing — treat like general
    jmp .ga_fail

.ga_index_ident:
    ; Fast path for simple array variables.
    mov rdi, [rdi + ast_node_t.data1]   ; name_ptr
    push rdi
    call find_symbol
    test rax, rax
    jnz .ga_index_local
    pop rdi
    push rdi
    call find_global_symbol
    test rax, rax
    jz .ga_fail
    pop rdi
    mov r13, rbx                        ; element type
    mov r14, rcx                        ; extra
    ; Global array base
    mov rax, r13
    cmp rax, PTR_TYPE_FLAG
    jae .ga_index_global_ptr
    ; Struct array (TOK_KW_STRUCT) or scalar array
    mov rax, r13
    cmp rax, ARRAY_TYPE_FLAG
    jb .ga_index_global_not_flag
    sub rax, ARRAY_TYPE_FLAG
.ga_index_global_not_flag:
    mov r15, rax                        ; element type
    ; Set element metadata: struct arrays carry the field array in extra.
    cmp r15, TOK_KW_STRUCT
    jne .ga_index_global_scalar
    mov [gen_expr_struct_fields], r14
    jmp .ga_index_global_emit
.ga_index_global_scalar:
    mov [gen_expr_array_count], r14
.ga_index_global_emit:
    ; Strip any leading "g_" so we don't emit "g_g_name".
    mov rsi, rdi
    call strip_g_prefix
    mov r9, rsi
    ; Emit: lea rax, [rel g_name]   (emit_string clobbers rdi, so use r9)
    mov rsi, asm_lea_rax_g
    call emit_string
    mov rsi, r9
    call emit_string
    mov rsi, asm_close_bracket
    call emit_string
    jmp .ga_index_finish
.ga_index_global_ptr:
    ; Pointer variable used as array base
    mov r15, r13
    sub r15, PTR_TYPE_FLAG
    push rdi
    mov rsi, asm_mov_rax_g
    call emit_string
    pop rsi
    call strip_g_prefix              ; user globals may already spell g_name
    call emit_string
    mov rsi, asm_close_bracket
    call emit_string
    ; A pointer to a struct carries the pointee's field array in `extra`
    ; (r14 here). Set it so the struct-element stride resolves instead of
    ; depending on a stale gen_expr_struct_fields from an earlier expression.
    push rax
    push rdi
    mov rdi, r15
    call type_is_struct_or_ptr
    pop rdi
    test rax, rax
    jz .ga_index_global_ptr_nofield
    mov [gen_expr_struct_fields], r14
.ga_index_global_ptr_nofield:
    pop rax
    jmp .ga_index_finish

.ga_index_local:
    mov r13, rax                        ; offset
    mov r14, rcx                        ; extra
    pop rdi
    test r13, r13
    jz .ga_fail
    mov rax, r13
    ; For struct arrays, type is TOK_KW_STRUCT, extra = field_array_ptr
    ; For scalar arrays, type = TOK_KW_INT/CHAR, extra = count
    ; For pointer variables used as base, type has PTR_TYPE_FLAG.
    mov r15, rbx
    mov rax, rbx
    cmp rax, ARRAY_TYPE_FLAG
    jae .ga_index_local_strip_flag
    cmp rax, PTR_TYPE_FLAG
    jb .ga_index_local_arr
    ; pointer variable: load value
    mov r15, rbx
    sub r15, PTR_TYPE_FLAG
    mov rdi, r13
    neg rdi
    push rdi
    mov rsi, asm_load_qword_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    pop rdi
    ; A pointer to a struct carries the pointee's field array in `extra`
    ; (r14 here). Set it so the struct-element stride resolves instead of
    ; depending on a stale gen_expr_struct_fields from an earlier expression.
    push rax
    push rdi
    mov rdi, r15
    call type_is_struct_or_ptr
    pop rdi
    test rax, rax
    jz .ga_index_local_ptr_nofield
    mov [gen_expr_struct_fields], r14
.ga_index_local_ptr_nofield:
    pop rax
    jmp .ga_index_finish
.ga_index_local_strip_flag:
    mov rax, rbx
    sub rax, ARRAY_TYPE_FLAG
    cmp rax, PTR_TYPE_FLAG
    jb .ga_index_local_flag_arr
    mov r15, rax
    sub r15, PTR_TYPE_FLAG
    mov rdi, r13
    neg rdi
    push rdi
    mov rsi, asm_load_qword_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    pop rdi
    ; A pointer to a struct carries the pointee's field array in `extra`
    ; (r14 here). Set it so the struct-element stride resolves instead of
    ; depending on a stale gen_expr_struct_fields from an earlier expression.
    push rax
    push rdi
    mov rdi, r15
    call type_is_struct_or_ptr
    pop rdi
    test rax, rax
    jz .ga_index_local_strip_nofield
    mov [gen_expr_struct_fields], r14
.ga_index_local_strip_nofield:
    pop rax
    jmp .ga_index_finish
.ga_index_local_flag_arr:
    mov r15, rax                        ; element type
.ga_index_local_arr:
    ; Set element metadata.
    cmp r15, TOK_KW_STRUCT
    jne .ga_index_local_scalar
    mov [gen_expr_struct_fields], r14
    jmp .ga_index_local_emit
.ga_index_local_scalar:
    mov [gen_expr_array_count], r14
.ga_index_local_emit:
    mov rdi, r13
    neg rdi
    push rdi
    mov rsi, asm_lea_rax_rbp
    call emit_string
    pop rdi
    push rdi
    call emit_int
    mov rsi, asm_close_bracket
    call emit_string
    pop rdi
    jmp .ga_index_finish

.ga_index_member:
    ; General base: compute address of the base lvalue.
    mov rdi, [r12 + ast_node_t.data1]
    call gen_addr
    test rax, rax
    jz .ga_fail
    ; gen_expr_type holds the base element type (or pointer type)
    mov r15, [gen_expr_type]
    mov r14, [gen_expr_struct_fields]
    mov rax, r15
    cmp rax, PTR_TYPE_FLAG
    jb .ga_index_member_structchk
    sub r15, PTR_TYPE_FLAG
.ga_index_member_structchk:
    ; Keep struct metadata already set by gen_addr.
.ga_index_finish:
    ; rax = base address (compile-time hint), r15 = element type.
    ; Emit a runtime push of the base address.
    mov rsi, asm_push_rax
    call emit_string
    ; Save metadata around index eval (index expr may clobber the globals)
    mov rax, [gen_expr_struct_fields]
    push rax
    mov rax, [gen_expr_array_count]
    push rax
    push r15
    mov rdi, [r12 + ast_node_t.data2]   ; index expr
    call gen_expr
    pop r15
    pop rax
    mov [gen_expr_array_count], rax
    pop rax
    mov [gen_expr_struct_fields], rax
    ; rax = index; runtime base is on the stack
    mov rsi, asm_pop_rbx
    call emit_string                    ; pop rbx → rbx = base
    ; rbx = base, rax = index
    cmp r15, TOK_KW_CHAR
    je .ga_index_noscale
    cmp r15, TOK_KW_INT
    jne .ga_index_struct_chk
    mov rsi, asm_shl_rax_3
    call emit_string
    jmp .ga_index_noscale
.ga_index_struct_chk:
    cmp r15, TOK_KW_STRUCT
    jne .ga_index_noscale
    mov rdi, [gen_expr_struct_fields]
    test rdi, rdi
    jz .ga_index_noscale
    push rdi
    call struct_total_size
    mov rdi, rax
    pop r8
    test rdi, rdi
    jz .ga_index_noscale
    push rdi
    mov rsi, asm_imul_rax_imm
    call emit_string
    pop rdi
    call emit_int
    mov rsi, asm_newline
    call emit_string
.ga_index_noscale:
    mov rsi, asm_add_rax_rbx
    call emit_string
    mov [gen_expr_type], r15
    mov rax, 1
    jmp .ga_ret

.ga_fail:
    xor rax, rax
.ga_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.ga_ident_undeclared:
    ; `&name` / gen_addr on a name that is neither local nor global:
    ; report it as a hard compile error (matches .ident's not-found path).
    pop rdi
    call report_undeclared
    jmp .ga_fail

; ================================================================
; struct_total_size(rdi = field_array_ptr) -> rax = total_size
; Walks the field descriptors and computes total size
; (last_offset + last_field_size, padded up to 8).
;
; Array and by-value struct fields are NOT 8 bytes: for `int n; int arr[3];`
; the last field contributes 24 bytes, so the struct is 32, not 16 (the old
; code assumed every non-char field was one qword, so a global array of such
; structs was indexed with too small a stride and reads/writes hit the wrong
; element). Scalar/pointer array fields carry the element count in
; sub_array_ptr; struct-array fields carry a pointer to an info struct
; [count, element_field_array_ptr]; a by-value struct field carries its field
; array directly. Struct element sizes are computed recursively.
;
; The base offset lives in rcx, which the recursive call preserves; rdi is
; clobbered by the recursion, so it must not hold the accumulator.
; ================================================================
struct_total_size:
    push rcx
    push r8
    push r9
    push rbx
    push r10
    mov r8, [rdi]                ; r8 = field count
    test r8, r8
    jz .sts_zero
    dec r8
    ; Last field descriptor at base + 8 + last_idx * 32
    mov rax, r8
    shl rax, 5                   ; rax = last_idx * 32
    lea r9, [rdi + 8 + rax]     ; r9 = last field descriptor
    mov rcx, [r9 + 8]           ; rcx = last field offset (survives recursion)
    mov rax, [r9 + 16]          ; rax = last field type
    mov rbx, [r9 + 24]          ; rbx = sub_array_ptr (count, info ptr, or fields)
    ; Strip FIELD_CONST_FLAG: `const int arr[3]` must be classified by its
    ; element type, not by the const bit.
    mov r10, FIELD_CONST_FLAG
    not r10
    and rax, r10
    cmp rax, ARRAY_TYPE_FLAG
    jae .sts_array
    cmp rax, PTR_TYPE_FLAG
    jae .sts_size8
    cmp rax, TOK_KW_CHAR
    je .sts_size1
    cmp rax, TOK_KW_STRUCT
    je .sts_struct
.sts_size8:
    mov rax, 8
    jmp .sts_add
.sts_size1:
    mov rax, 1
    jmp .sts_add
.sts_struct:
    ; By-value struct field: sub_array_ptr is its field array. The field size
    ; is that struct's total size, computed recursively.
    mov rdi, rbx
    test rdi, rdi
    jz .sts_size8               ; forward-ref placeholder — fall back
    call struct_total_size
    jmp .sts_add                ; rax = field size
.sts_array:
    ; rax = ARRAY_TYPE_FLAG + element_type, rbx = sub_array_ptr.
    cmp rbx, 0
    je .sts_size8               ; no count recorded — fall back
    mov r10, rax
    sub r10, ARRAY_TYPE_FLAG    ; r10 = element type
    cmp r10, TOK_KW_STRUCT
    je .sts_array_struct
    cmp r10, TOK_KW_CHAR
    je .sts_array_char
    mov r10, 8                  ; int/pointer elements are 8 bytes
    jmp .sts_array_mul
.sts_array_char:
    mov r10, 1
.sts_array_mul:
    imul r10, rbx               ; r10 = element_size * count
    mov rax, r10
    jmp .sts_add
.sts_array_struct:
    ; rbx = pointer to [count, element_field_array_ptr].
    mov rdi, [rbx + 8]
    test rdi, rdi
    jz .sts_size8               ; forward-ref placeholder — fall back
    push rbx
    call struct_total_size      ; rax = element struct size
    pop rbx
    imul rax, [rbx]             ; rax = element_size * count
    jmp .sts_add
.sts_add:
    add rax, rcx                ; rax = last_offset + last_field_size
    add rax, 7
    and rax, -8                 ; tail pad to 8 bytes
    pop r10
    pop rbx
    pop r9
    pop r8
    pop rcx
    ret
.sts_zero:
    xor rax, rax
    pop r10
    pop rbx
    pop r9
    pop r8
    pop rcx
    ret

; ================================================================
; emit_bounds_check(rdi = element_count)
; Emits inline bounds check for array index in rax.
; If rax < 0 or rax >= count, calls syscall_exit(1).
; Preserves: rax (index), rbx, r12-r15
; ================================================================
emit_bounds_check:
    push rax
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12, rdi               ; r12 = element count
    mov r13, [label_counter]
    inc qword [label_counter]    ; allocate a unique label number

    ; cmp rax, 0
    mov rsi, asm_cmp_rax_0
    call emit_string

    ; jl .L_bounds_fail_N
    mov rsi, asm_jl_bounds_fail
    call emit_string
    mov rdi, r13
    call emit_int
    mov rsi, asm_newline
    call emit_string

    ; mov rbx, count
    mov rsi, asm_mov_rbx_imm
    call emit_string
    mov rdi, r12
    call emit_int
    mov rsi, asm_newline
    call emit_string

    ; cmp rbx, rax
    mov rsi, asm_cmp_rbx_rax
    call emit_string

    ; jle .L_bounds_fail_N
    mov rsi, asm_jle_bounds_fail
    call emit_string
    mov rdi, r13
    call emit_int
    mov rsi, asm_newline
    call emit_string

    ; jmp .L_bounds_ok_N
    mov rsi, asm_jmp_bounds_ok
    call emit_string
    mov rdi, r13
    call emit_int
    mov rsi, asm_newline
    call emit_string

    ; .L_bounds_fail_N:
    mov rsi, asm_label_bounds_fail
    call emit_string
    mov rdi, r13
    call emit_int
    mov rsi, asm_label_sep
    call emit_string

    ; mov rdi, 1
    mov rsi, asm_mov_rdi_1
    call emit_string

    ; mov rax, 60
    mov rsi, asm_mov_rax_60
    call emit_string

    ; syscall
    mov rsi, asm_syscall
    call emit_string

    ; .L_bounds_ok_N:
    mov rsi, asm_label_bounds_ok
    call emit_string
    mov rdi, r13
    call emit_int
    mov rsi, asm_label_sep
    call emit_string

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rax
    ret

; ================================================================
; pack_2d_extra — pack dim2 into the extra field for 2D arrays.
;
; Input:  r8 = total_count (from data3)
;         r13 = AST_ARRAY_DECL node pointer
; Output: r8 = packed extra (dim1 | (dim2 << 32)) if 2D, else unchanged
; Clobbers: rax, rdx (caller-saved); preserves rdi, rsi, rcx, r13
; ================================================================
pack_2d_extra:
    ; Read dim2 from data5: (data5 >> 2) extracts dim2 (0 for 1D)
    mov rax, [r13 + ast_node_t.data5]
    shr rax, 2                       ; rax = dim2 (0 for 1D)
    test rax, rax
    jz .pack_2d_done                 ; 1D: leave r8 unchanged
    ; 2D: compute dim1 = total_count / dim2
    push rdi                         ; save rdi (name_ptr)
    push rcx                         ; save rcx (type)
    mov rcx, rax                     ; rcx = dim2
    mov rax, r8                      ; rax = total_count
    xor rdx, rdx
    div rcx                          ; rax = dim1 = total_count / dim2
    mov r8, rax                      ; r8 = dim1 (low 32 bits)
    pop rcx                          ; restore type
    pop rdi                          ; restore name_ptr
    ; Pack: r8 = dim1 | (dim2 << 32)
    shl rax, 32                      ; rax = dim1 << 32... no, we need dim2 << 32
    ; Actually rax = dim1. We need to shift dim2, not dim1.
    ; Redo: we saved dim2 in rcx but popped it. Use rax = dim2 again.
    mov rax, [r13 + ast_node_t.data5]
    shr rax, 2                       ; rax = dim2
    shl rax, 32                      ; rax = dim2 << 32
    or r8, rax                       ; r8 = dim1 | (dim2 << 32)
.pack_2d_done:
    ret

; ================================================================
; emit helpers
; ================================================================
emit_string:
    call out_write_string
    ret

emit_string_len:
    call out_write_string_len
    ret

emit_int:
    call out_write_int
    ret

; Safe strlen for global identifiers and other compiler-owned names.
; Stops at 256 bytes to avoid runaway reads if a pointer is corrupted.
bounded_strlen_256:
    xor rax, rax
.loop:
    cmp rax, 256
    jae .done
    cmp byte [rsi + rax], 0
    je .done
    inc rax
    jmp .loop
.done:
    ret

; Emit a name after stripping an optional "g_" prefix.
; Input: rsi = name pointer
emit_global_name:
    call strip_g_prefix
    push rsi
    call bounded_strlen_256
    mov rdx, rax
    pop rsi
    call emit_string_len
    ret

strlen:
    jmp bounded_strlen_256
