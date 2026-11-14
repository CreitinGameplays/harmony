; C2X Seed - Recursive Descent Parser
; Builds an AST from the token stream produced by the lexer.

; ------------------------------------------------------------
; External Dependencies
; ------------------------------------------------------------
extern heap_alloc, heap_alloc_zero
extern lexer_init, lexer_next_token, lexer_cleanup
extern lexer_state
extern prev_tok_line, prev_tok_col
extern out_write_string_len, out_write_newline, out_write_int, out_write_char
extern error_at
extern error_at_code, error_code
extern msg_syntax, msg_expect_semi, msg_expect_rparen, msg_expect_rbrace, msg_void_return_val, msg_undeclared_func
extern msg_expect_type, msg_expect_ident, msg_expect_lbrace, msg_expect_rbracket
extern msg_unexpected, msg_expected_primary, msg_expect_lparen
extern msg_expect_dot, msg_expect_eq
extern msg_infinite_struct
extern mem_eq
extern mem_copy
extern source_path

; ------------------------------------------------------------
; Exported Functions and Data
; ------------------------------------------------------------
global parser_init, parser_parse_program, parser_cleanup
global parser_reinit, parser_reset
global parser_state

; ------------------------------------------------------------
; Token Type Constants (matching lexer.asm)
; ------------------------------------------------------------
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
%define TOK_LSHIFT      15
%define TOK_RSHIFT      16
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
%define TOK_DOT         45
    %define TOK_NOT         46
    %define TOK_AND         82
    %define TOK_OR          83
%define TOK_PIPE        47
%define TOK_XOR         48
%define TOK_TILDE       49

; Compound assignment
%define TOK_ADDEQ       70
%define TOK_SUBEQ       71
%define TOK_MULEQ       72
%define TOK_DIVEQ       73
%define TOK_MODEQ       74
%define TOK_LSHIFT_EQ   75
%define TOK_RSHIFT_EQ   76
%define TOK_ANDEQ       77
%define TOK_OREQ        78
%define TOK_XOREQ       79
%define TOK_INCR        80
%define TOK_DECR        81

%define TOK_KW_INT      50
%define TOK_KW_CHAR     51
%define TOK_KW_IF       52
%define TOK_KW_ELSE     53
%define TOK_KW_WHILE    54
%define TOK_KW_RETURN   55
%define TOK_KW_VOID     56
%define TOK_KW_STRUCT   57
%define TOK_KW_EXTERN   58
%define TOK_KW_FOR      59
%define TOK_KW_BREAK    60
%define TOK_KW_CONTINUE 61
%define TOK_KW_CONST    62

; Const/extern flags for AST_VAR_DECL data4
%define VAR_EXTERN      1
%define VAR_CONST       2
; VLA flag for AST_ARRAY_DECL data5 (bit 0). When set, data3 holds a size
; expression AST* instead of a compile-time element count, and codegen
; allocates the array on the stack at runtime (base+count frame slot).
%define VLA_FLAG        1

; Pointer type encoding: PTR_TYPE_FLAG + base_token_type, plus one more
; PTR_TYPE_FLAG per extra pointer level (e.g. int* = 10050, int** = 20050).
%define PTR_TYPE_FLAG   10000
; Array field encoding: ARRAY_TYPE_FLAG + element_type (element_type may itself
; be a pointer encoding, e.g. struct Field*[N] = ARRAY_TYPE_FLAG + 10057).
;
; IMPORTANT: pointer depth is additive, so a depth-`d` pointer is
; `base + d*PTR_TYPE_FLAG`. ARRAY_TYPE_FLAG must therefore sit ABOVE every
; pointer encoding we can produce, so that `type >= ARRAY_TYPE_FLAG` only ever
; matches an array. The old value 20000 collided with depth-2 pointers
; (struct N** = 57 + 2*10000 = 20057 = 20000 + 57), which made a double
; pointer look like a struct array and crashed `struct_total_size`.
; 1<<28 leaves room for ~26000 pointer levels before a collision, and stays
; inside the signed 32-bit immediate range that `cmp reg, imm32` requires.
%define ARRAY_TYPE_FLAG  268435456
; Const struct field flag: a distinct high bit OR'd into the field-descriptor
; type. Kept above every pointer encoding and distinct from ARRAY_TYPE_FLAG so
; `test`/`or`/`sub` are unambiguous at any pointer depth.
%define FIELD_CONST_FLAG 536870912
; Const struct field flag: OR'd into the field type in the field descriptor
; so codegen can reject assignments to const fields.
; Value chosen to avoid overlapping with PTR_TYPE_FLAG (10000) or
; ARRAY_TYPE_FLAG (20000) bit patterns.
%define FIELD_CONST_FLAG 65536

; Error codes (matching errors.asm)
ERR_SYNTAX         equ 100
ERR_EXPECTED_SEMI  equ 101
ERR_EXPECTED_RPAREN equ 102
ERR_EXPECTED_RBRACE equ 103
ERR_EXPECTED_TYPE  equ 104
ERR_EXPECTED_IDENT equ 105
ERR_EXPECTED_LBRACE equ 106
ERR_EXPECTED_RBRACKET equ 107
ERR_UNEXPECTED     equ 108
ERR_EXPECTED_PRIMARY equ 109
ERR_EXPECTED_LPAREN equ 110

; ------------------------------------------------------------
; AST Node Types
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

; AST node struct (40 bytes = 5 qwords)
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

; Lexer state offsets (matching lexer.asm)
CURRENT_CHAR  equ 0
LEXER_LINE    equ 8
LEXER_COLUMN  equ 16
TOK_TYPE      equ 24
TOK_BUF       equ 32
TOK_LEN       equ 288
TOK_LINE      equ 296
TOK_COL       equ 304

; ------------------------------------------------------------
; Uninitialized Data
; ------------------------------------------------------------
section .bss
    global parser_state
    parser_state:
        .current_token  resq 1
        .token_value    resq 1
        .token_len      resq 1
        .error_count    resq 1

    ; Saved type/name for global var detection (set by parse_function on failure)
    parser_saved_type   resq 1
    parser_saved_name   resq 1
    parser_saved_const  resq 1          ; const flag for global vars (set by const handler)

    ; Const flag for the current struct field being parsed.
    ; Set to 1 when `const` appears before a field type, consumed by
    ; struct_add_field callers to OR FIELD_CONST_FLAG into the field type.
    parser_field_const  resq 1

    ; Shared error count — incremented by lexer and parser
    global error_count
    error_count         resq 1

    ; Named struct type registry
    ; Maps tag name → (total_size, field_array_ptr)
    MAX_NAMED_STRUCTS equ 16
    global named_struct_count
    named_struct_count  resq 1
    named_struct_names  resb MAX_NAMED_STRUCTS * 8
    named_struct_sizes  resb MAX_NAMED_STRUCTS * 8
    named_struct_fields resb MAX_NAMED_STRUCTS * 8

    ; Index of the currently-being-defined named struct (-1 if none).
    ; Used to update the struct's size after its body is parsed, enabling
    ; self-referential struct definitions like `struct Node { struct Node* next; }`.
    global struct_pre_reg_index
    struct_pre_reg_index resq 1

    ; Forward-reference back-patch table. A pointer field may reference a named
    ; struct that is defined later (`struct A { struct B* p; }` before B). We
    ; create a placeholder registry entry for B and record the address of the
    ; field descriptor's sub_array_ptr slot (offset 24) here; when B is finally
    ; defined we copy its field array pointer into every recorded slot.
    FWD_REF_MAX equ 128
    global fwd_ref_count
    fwd_ref_count resq 1
    fwd_ref_slot  resb FWD_REF_MAX * 8      ; named-struct registry index
    fwd_ref_desc  resb FWD_REF_MAX * 8      ; address of field_descriptor.sub_array_ptr

    ; Pending forward-reference state for the field currently being parsed.
    ; parser_fwd_index >= 0 means the field references a not-yet-defined struct;
    ; when its descriptor is stored we record the slot for back-patching.
    global parser_fwd_index
    parser_fwd_index resq 1

    ; Current function return type (set during parse_function for void-check)
    global current_func_return_type
    current_func_return_type resq 1

    ; Current function return struct's field_array_ptr (0 if return type is not
    ; a struct, or if it's an anonymous struct with no known fields).
    ; Used by codegen to set up the hidden return-pointer parameter for
    ; struct-returning functions (System V AMD64 ABI for aggregate returns).
    global current_func_return_fields
    current_func_return_fields resq 1

    ; Flag: when set, parse_function should skip the initial type consumption
    ; and use the pre-set current_func_return_type/current_func_return_fields.
    ; Set by parse_struct_def when it detects a function with struct return type
    ; (e.g., "struct Token next_token(void)" where 'struct' and 'Token' have
    ; already been consumed).
    global struct_ret_pre_consumed
    struct_ret_pre_consumed resq 1

    ; Flag: when set, parse_function should also skip the function name
    ; consumption (current token should be '('). Used when parse_struct_def
    ; detects a function definition after consuming the function name.
    global func_name_pre_consumed
    func_name_pre_consumed resq 1

    ; Pre-consumed function name (used when func_name_pre_consumed is set)
    global pre_consumed_func_name
    pre_consumed_func_name resq 1

    ; Function name registry for forward-declaration enforcement.
    ; Starts on a small static buffer and grows into heap-backed arrays.
    FUNC_REGISTRY_INITIAL_CAPACITY equ 64
    global func_name_registry
    global func_name_registry_capacity
    func_name_registry_capacity resq 1
    func_name_registry resq 1                ; pointer to array of string pointers
    global func_registry_count
    func_registry_count resq 1

    ; Parallel array storing field_array_ptr for each registered function.
    ; Populated by parse_function when the function has a struct return type.
    ; Read by gen_function in the codegen to set current_func_return_fields.
    global func_field_array_ptrs
    func_field_array_ptrs resq 1             ; pointer to array of qword field ptrs

    func_name_registry_storage resb FUNC_REGISTRY_INITIAL_CAPACITY * 8
    func_field_array_storage   resb FUNC_REGISTRY_INITIAL_CAPACITY * 8

    ; Persistent program state for multi-file accumulation
    global prog_func_count, prog_func_array, prog_func_capacity
    global prog_global_count, prog_global_array, prog_global_capacity
    global prog_func_source_array, prog_func_source_capacity
    global prog_global_source_array, prog_global_source_capacity
    prog_func_count    resq 1
    prog_func_array    resq 1
    prog_func_capacity  resq 1          ; current capacity of prog_func_array (slots)
    prog_func_source_array resq 1
    prog_func_source_capacity resq 1
    prog_global_count  resq 1
    prog_global_array  resq 1
    prog_global_capacity resq 1         ; current capacity of prog_global_array (slots)
    prog_global_source_array resq 1
    prog_global_source_capacity resq 1

; Type keyword list for parsing type declarations
section .data
    type_kw_count equ 3
    type_keywords: dq TOK_KW_INT, TOK_KW_CHAR, TOK_KW_VOID
    kw_asm_str db "asm", 0

default rel

section .rodata

section .text

; ================================================================
; Parser Initialization
; ================================================================
parser_init:
    ; Initialize lexer first
    call lexer_init

    ; Initialize parser state
    xor rax, rax
    mov [parser_state.current_token], rax
    mov [parser_state.token_value], rax
    mov [parser_state.token_len], rax
    mov [parser_state.error_count], rax
    mov [error_count], rax
    mov [func_registry_count], rax

    lea rax, [func_name_registry_storage]
    mov [func_name_registry], rax
    lea rax, [func_field_array_storage]
    mov [func_field_array_ptrs], rax
    mov qword [func_name_registry_capacity], FUNC_REGISTRY_INITIAL_CAPACITY
    xor rax, rax

    ; Reset persistent program state
    mov [prog_func_count], rax
    mov [prog_global_count], rax

    ; Allocate persistent arrays (if not already)
    cmp qword [prog_func_array], 0
    jne .skip_func_alloc
    push rdi
    mov rdi, 128
    call alloc_ptr_array
    mov [prog_func_array], rax
    mov qword [prog_func_capacity], 128
    pop rdi
.skip_func_alloc:
    cmp qword [prog_func_source_array], 0
    jne .skip_func_source_alloc
    push rdi
    mov rdi, 128
    call alloc_ptr_array
    mov [prog_func_source_array], rax
    mov qword [prog_func_source_capacity], 128
    pop rdi
.skip_func_source_alloc:
    cmp qword [prog_global_array], 0
    jne .skip_global_alloc
    push rdi
    mov rdi, 128
    call alloc_ptr_array
    mov [prog_global_array], rax
    mov qword [prog_global_capacity], 128
    pop rdi
.skip_global_alloc:
    cmp qword [prog_global_source_array], 0
    jne .skip_global_source_alloc
    push rdi
    mov rdi, 128
    call alloc_ptr_array
    mov [prog_global_source_array], rax
    mov qword [prog_global_source_capacity], 128
    pop rdi
.skip_global_source_alloc:

    ; Register built-in functions
    push rdi
    lea rdi, [kw_asm_str]
    call register_func_name
    pop rdi

    ; Get first token
    call lexer_next_token
    mov [parser_state.current_token], rax
    call save_token_info
    ret

; ================================================================
; parser_reinit()
; Reinitialize parser/lexer for a new input file, preserving
; registries (func, struct) and persistent program state.
; ================================================================
parser_reinit:
    call lexer_init
    xor rax, rax
    mov [parser_state.current_token], rax
    mov [parser_state.token_value], rax
    mov [parser_state.token_len], rax
    call lexer_next_token
    mov [parser_state.current_token], rax
    call save_token_info
    ret

; ================================================================
; parser_reset()
; Full reset of all parser state including registries.
; ================================================================
parser_reset:
    call lexer_init
    xor rax, rax
    mov [parser_state.current_token], rax
    mov [parser_state.token_value], rax
    mov [parser_state.token_len], rax
    mov [parser_state.error_count], rax
    mov [error_count], rax
    mov [func_registry_count], rax
    lea rax, [func_name_registry_storage]
    mov [func_name_registry], rax
    lea rax, [func_field_array_storage]
    mov [func_field_array_ptrs], rax
    mov qword [func_name_registry_capacity], FUNC_REGISTRY_INITIAL_CAPACITY
    xor rax, rax
    ; Reset persistent program state (preserve array pointers)
    mov [prog_func_count], rax
    mov [prog_global_count], rax
    ; Re-register built-in functions after reset
    push rdi
    lea rdi, [kw_asm_str]
    call register_func_name
    pop rdi
    call lexer_next_token
    mov [parser_state.current_token], rax
    call save_token_info
    ret

; ================================================================
; Save current token info from lexer state
; ================================================================
save_token_info:
    mov rax, lexer_state + TOK_BUF
    mov [parser_state.token_value], rax
    mov rax, [lexer_state + TOK_LEN]
    mov [parser_state.token_len], rax
    ret

; ================================================================
; Advance to next token
; ================================================================
advance:
    push rbx
    call lexer_next_token
    mov [parser_state.current_token], rax
    call save_token_info
    pop rbx
    ret

; ================================================================
; match(token_type) -> bool
; If current token matches, advance and return 1
; ================================================================
match:
    mov rax, [parser_state.current_token]
    cmp rax, rdi
    jne .no
    call advance
    mov rax, 1
    ret
.no:
    xor rax, rax
    ret

; ================================================================
; expect(token_type, error_message)
; If current token matches, advance; otherwise print error message
; rdi = expected token type, rsi = error message string
; ================================================================
expect:
    mov rax, [parser_state.current_token]
    cmp rax, rdi
    je advance       ; tail call — token matches
    ; Error — print detailed error with position
    push rsi                     ; save msg
    mov rdi, [lexer_state + 296] ; tok_line
    mov rsi, [lexer_state + 304] ; tok_col
    pop rdx                      ; rdx = msg
    call error_at
    jmp advance

; ================================================================
; Parser Error
; ================================================================
error:
    ; Report parser error with position from lexer_state
    push rsi                     ; save msg
    mov rdi, [lexer_state + 296] ; tok_line
    mov rsi, [lexer_state + 304] ; tok_col
    pop rdx                      ; rdx = msg
    call error_at
    ret

; ================================================================
; Allocate an AST node
; rdi = type
; returns: rax = pointer to 32-byte zeroed node
; ================================================================
alloc_node:
    push rdi
    mov rdi, ast_node_t_size
    call heap_alloc_zero
    pop rdi
    test rax, rax
    jz .oom
    mov [rax + ast_node_t.type], rdi
    mov rdi, [prev_tok_line]
    mov [rax + ast_node_t.line], rdi
    mov rdi, [prev_tok_col]
    mov [rax + ast_node_t.column], rdi
.oom:
    ret

; ================================================================
; Allocate an array of pointers
; rdi = count
; returns: rax = pointer to count qwords followed by count ptr slots
; ================================================================
alloc_ptr_array:
    push rdi
    lea rdi, [rdi * 8 + 8]    ; count + count * 8 bytes
    call heap_alloc_zero
    pop rdi
    test rax, rax
    jz .oom
    mov [rax], rdi             ; store count
.oom:
    ret

; ================================================================
; Copy string from lexer's tok_buf to heap
; Returns: rax = heap pointer to null-terminated copy
; ================================================================
copy_token_string:
    push rbx
    push rcx
    push rsi
    push rdi

    mov rsi, [parser_state.token_value]
    mov rcx, [parser_state.token_len]
    cmp rcx, 255
    jbe .len_ok
    mov rcx, 255
.len_ok:
    lea rdi, [rcx + 1]         ; +1 for null terminator
    call heap_alloc
    test rax, rax
    jz .done

    mov rdi, rax
    mov rsi, [parser_state.token_value]
    mov rcx, [parser_state.token_len]
    ; Copy bytes
.copy_loop:
    test rcx, rcx
    jz .null_term
    mov bl, [rsi]
    mov [rdi], bl
    inc rsi
    inc rdi
    dec rcx
    jmp .copy_loop
.null_term:
    mov byte [rdi], 0

.done:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; ================================================================
; Parse a number from token buffer -> int64 in rax
; ================================================================
parse_number_value:
    push rbx
    push rcx
    push rsi

    mov rsi, [parser_state.token_value]
    mov rcx, [parser_state.token_len]
    xor rax, rax
    xor rbx, rbx

    ; Check for hex prefix "0x" or "0X"
    cmp rcx, 2
    jb .dec_loop
    cmp word [rsi], 0x7830        ; "0x" in little-endian
    je .hex_start
    cmp word [rsi], 0x5830        ; "0X" in little-endian
    jne .dec_loop

.hex_start:
    add rsi, 2
    sub rcx, 2
.hex_loop:
    test rcx, rcx
    jz .done
    mov bl, [rsi]
    cmp bl, '0'
    jb .done
    cmp bl, '9'
    jbe .hex_digit
    cmp bl, 'a'
    jb .check_upper_hex
    cmp bl, 'f'
    jbe .hex_lower
.check_upper_hex:
    cmp bl, 'A'
    jb .done
    cmp bl, 'F'
    ja .done
.hex_upper:
    sub bl, 'A' - 10               ; 'A'=65 → 65-55=10
    jmp .hex_add
.hex_lower:
    sub bl, 'a' - 10               ; 'a'=97 → 97-87=10
    jmp .hex_add
.hex_digit:
    sub bl, '0'
.hex_add:
    shl rax, 4
    add rax, rbx
    inc rsi
    dec rcx
    jmp .hex_loop

.dec_loop:
    test rcx, rcx
    jz .done
    mov bl, [rsi]
    sub bl, '0'
    imul rax, 10
    add rax, rbx
    inc rsi
    dec rcx
    jmp .dec_loop
.done:
    pop rsi
    pop rcx
    pop rbx
    ret

; ================================================================
; Top-Level Parsing Entry Point
; ================================================================
parser_parse_program:
    push rbx
    push r12
    push r13
    push r14
    push r15

    ; Check if persistent arrays exist; if not, allocate them
    cmp qword [prog_func_array], 0
    jne .have_func_array

    ; Allocate array for 128 function pointers
    mov rdi, 128
    call alloc_ptr_array
    test rax, rax
    jz .ppp_oom
    mov [prog_func_array], rax
    mov qword [prog_func_capacity], 128
    xor rax, rax
    mov [prog_func_count], rax

.have_func_array:
    cmp qword [prog_func_source_array], 0
    jne .have_func_source_array

    ; Allocate parallel source-path array for function pointers
    mov rdi, 128
    call alloc_ptr_array
    test rax, rax
    jz .ppp_oom
    mov [prog_func_source_array], rax
    mov qword [prog_func_source_capacity], 128

.have_func_source_array:
    cmp qword [prog_global_array], 0
    jne .have_global_array

    ; Allocate array for 128 global variable declarations
    mov rdi, 128
    call alloc_ptr_array
    test rax, rax
    jz .ppp_oom
    mov [prog_global_array], rax
    mov qword [prog_global_capacity], 128
    xor rax, rax
    mov [prog_global_count], rax

.have_global_array:
    cmp qword [prog_global_source_array], 0
    jne .use_existing_arrays

    ; Allocate parallel source-path array for global declarations
    mov rdi, 128
    call alloc_ptr_array
    test rax, rax
    jz .ppp_oom
    mov [prog_global_source_array], rax
    mov qword [prog_global_source_capacity], 128

.use_existing_arrays:
    mov r12, [prog_func_count]
    mov r13, [prog_func_array]
    mov r14, [prog_global_count]
    mov r15, [prog_global_array]

.parse_toplevel:
    mov rax, [parser_state.current_token]
    cmp rax, TOK_EOF
    je .finish

    ; Check if it's a type keyword (start of function or global var)
    cmp rax, TOK_KW_INT
    je .type_kw
    cmp rax, TOK_KW_CHAR
    je .type_kw
    cmp rax, TOK_KW_VOID
    je .parse_void_func         ; void always means function
    cmp rax, TOK_KW_STRUCT
    je .global_struct
    cmp rax, TOK_KW_EXTERN
    je .extern_decl
    cmp rax, TOK_KW_CONST
    je .global_const
    ; Unexpected token at top level
    mov rsi, msg_unexpected
    call error
    call advance
    jmp .parse_toplevel

.global_const:
    mov qword [parser_saved_const], VAR_CONST
    call advance                     ; consume 'const'
    ; Re-dispatch based on next token
    mov rax, [parser_state.current_token]
    cmp rax, TOK_KW_INT
    je .type_kw
    cmp rax, TOK_KW_CHAR
    je .type_kw
    cmp rax, TOK_KW_STRUCT
    je .global_struct
    cmp rax, TOK_KW_EXTERN
    je .extern_decl
    ; Not supported: const void, etc.
    mov qword [parser_saved_const], 0
    mov rsi, msg_expect_type
    call error
    jmp .parse_toplevel

.ppp_oom:
    mov rdx, msg_syntax
    mov rdi, [lexer_state + 296] ; tok_line
    mov rsi, [lexer_state + 304] ; tok_col
    call error_at
    xor rax, rax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.extern_decl:
    call advance               ; consume 'extern'
    ; Next must be a type keyword
    mov rax, [parser_state.current_token]
    cmp rax, TOK_KW_INT
    je .ext_type_kw
    cmp rax, TOK_KW_CHAR
    je .ext_type_kw
    cmp rax, TOK_KW_VOID
    je .ext_type_kw
    mov rsi, msg_expect_type
    call error
    jmp .parse_toplevel

.ext_type_kw:
    ; Try parsing as function first — parse_function handles extern func
    ; (it will register the func name and return a forward-decl AST_FUNCTION)
    call parse_function
    test rax, rax
    jnz .store_func             ; was an extern function — store it

    ; Was not a function — parse as extern global var
    ; parser_saved_type and parser_saved_name are set by parse_function
    mov rbx, [parser_saved_type]
    push qword [parser_saved_name]      ; save name on stack (preserves r12)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_LBRACKET
    je .ext_global_array
    cmp rax, TOK_SEMI
    je .ext_global_scalar
    ; Unknown — skip
    add rsp, 8                          ; discard name
    call advance
    jmp .parse_toplevel

.ext_global_scalar:
    call advance                ; consume ';'
    pop rcx                     ; rcx = name (preserves r12 = func count)
    push rcx                    ; save name across alloc_node (heap_alloc_zero clobbers rcx)
    mov rdi, AST_VAR_DECL
    call alloc_node
    pop rcx                     ; restore name
    test rax, rax
    jz .ext_gs_drop
    mov [rax + ast_node_t.data1], rbx    ; type
    mov [rax + ast_node_t.data2], rcx    ; name
    mov qword [rax + ast_node_t.data3], 0 ; no init
    mov r8, [parser_saved_const]
    or r8, 1                               ; combine with extern flag
    mov [rax + ast_node_t.data4], r8      ; extern + const flags
    mov qword [parser_saved_const], 0
    jmp .store_global
.ext_gs_drop:
    ; alloc_node failed — name already popped and discarded
    jmp .parse_toplevel

.ext_global_array:
    call advance                ; consume '['
    ; Save name from stack
    pop r8                      ; r8 = name (preserves r12 = func count)
    ; Save const flag on stack (now stack is empty)
    push qword [parser_saved_const]     ; save const flag
    mov qword [parser_saved_const], 0   ; reset
    cmp qword [parser_state.current_token], TOK_NUMBER
    jne .ext_ga_skip
    call parse_number_value
    push rax                    ; save element count (dim1)
    call advance                ; consume number
    jmp .ext_ga_count_ok
.ext_ga_skip:
    push 0
.ext_ga_count_ok:
    mov rdi, TOK_RBRACKET
    mov rsi, msg_expect_rbracket
    call expect
    ; --- 2D array support: consume optional second dimension [M] ---
    mov rax, [parser_state.current_token]
    cmp rax, TOK_LBRACKET
    jne .ext_ga_check_semi
    call advance               ; consume '['
    cmp qword [parser_state.current_token], TOK_NUMBER
    jne .ext_ga_2d_err
    call parse_number_value
    push rax                    ; save dim2
    call advance               ; consume number
    mov rdi, TOK_RBRACKET
    mov rsi, msg_expect_rbracket
    call expect
    ; Compute total = dim1 * dim2
    pop rax                     ; rax = dim2
    pop rcx                     ; rcx = dim1
    imul rcx, rax              ; rcx = total
    push rcx                    ; save total count
    jmp .ext_ga_check_semi
.ext_ga_2d_err:
    mov rsi, msg_syntax
    call error
    pop rax                     ; discard element count
    pop rax                     ; discard const flag
    jmp .parse_toplevel
    ; --- end 2D array support ---
.ext_ga_check_semi:
    mov rdi, TOK_SEMI
    mov rsi, msg_expect_semi
    call expect
    mov rdi, AST_ARRAY_DECL
    call alloc_node
    test rax, rax
    jz .ext_ga_drop_with_const
    pop rcx                              ; rcx = element count
    mov [rax + ast_node_t.data1], rbx    ; type
    mov [rax + ast_node_t.data2], r8     ; name
    mov [rax + ast_node_t.data3], rcx    ; element count
    mov qword [rax + ast_node_t.data4], 1 ; extern flag
    pop rcx                              ; rcx = const flag
    mov [rax + ast_node_t.data5], rcx    ; store const flag in data5
    jmp .store_global
.ext_ga_drop:
    pop rcx                              ; discard element count
    jmp .parse_toplevel
.ext_ga_drop_with_const:
    pop rcx                              ; discard element count
    pop rcx                              ; discard const flag
    jmp .parse_toplevel

.parse_void_func:
    call parse_function
    test rax, rax
    jz .parse_toplevel
    jmp .store_func

.type_kw:
    ; Try parsing as function first — if it's a global var,
    ; parse_function returns null and sets parser_saved_type/name
    call parse_function
    test rax, rax
    jnz .store_func             ; was a function

    ; Was not a function — parse as global var/array
    ; parser_saved_type and parser_saved_name are set
    ; Use stack to hold name; DO NOT clobber r12 (function count)
    mov rbx, [parser_saved_type]
    push qword [parser_saved_name]      ; save name on stack
    mov rax, [parser_state.current_token]
    cmp rax, TOK_LBRACKET
    je .global_array
    cmp rax, TOK_SEMI
    je .global_scalar
    cmp rax, TOK_EQ
    je .global_init
    ; Unknown — skip
    mov qword [parser_saved_const], 0
    pop rcx                             ; discard name
    call advance
    jmp .parse_toplevel

.global_scalar:
    call advance                ; consume ';'
    mov rdi, AST_VAR_DECL
    call alloc_node
    test rax, rax
    jz .gs_drop
    pop rcx                              ; rcx = name_ptr
    mov [rax + ast_node_t.data1], rbx    ; type
    mov [rax + ast_node_t.data2], rcx    ; name
    mov qword [rax + ast_node_t.data3], 0 ; no init
    mov r8, [parser_saved_const]
    mov [rax + ast_node_t.data4], r8     ; const flag
    mov qword [parser_saved_const], 0
    jmp .store_global
.gs_drop:
    pop rcx                              ; discard name
    jmp .parse_toplevel

.global_init:
    call advance                ; consume '='
    call parse_expression
    push rax                     ; save init expression on stack
    ; Expect ';'
    mov rdi, TOK_SEMI
    mov rsi, msg_expect_semi
    call expect
    pop rcx                      ; rcx = init expression
    mov rdi, AST_VAR_DECL
    push rcx                     ; save init expression (alloc_node clobbers rcx)
    call alloc_node
    pop rcx                      ; restore init expression
    test rax, rax
    jz .gi_drop
    pop r8                       ; r8 = name_ptr (pushed by .type_kw section)
    mov [rax + ast_node_t.data1], rbx    ; type
    mov [rax + ast_node_t.data2], r8     ; name
    mov [rax + ast_node_t.data3], rcx    ; init expression
    mov r9, [parser_saved_const]
    mov [rax + ast_node_t.data4], r9     ; const flag
    mov qword [parser_saved_const], 0
    jmp .store_global
.gi_drop:
    pop r8                       ; discard name
    jmp .parse_toplevel

.global_array:
    call advance                ; consume '['
    ; Parse element count
    cmp qword [parser_state.current_token], TOK_NUMBER
    jne .global_array_skip
    mov rdi, [parser_state.token_value]
    call parse_number_value
    push rax                    ; save element count (dim1)
    call advance                ; consume number
    jmp .global_array_count_ok
.global_array_skip:
    push 0                      ; count = 0 (skip)
.global_array_count_ok:
    ; Expect ']'
    mov rdi, TOK_RBRACKET
    mov rsi, msg_expect_rbracket
    call expect

    ; --- 2D array support: check for a second dimension [M] ---
    ; If present, compute total = dim1 * dim2 and save dim2 for data5.
    xor r8, r8                  ; r8 = dim2 (0 = 1D)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_LBRACKET
    jne .global_array_check_init
    ; Parse second dimension [M]
    call advance               ; consume '['
    cmp qword [parser_state.current_token], TOK_NUMBER
    jne .global_array_2d_err
    call parse_number_value
    mov r8, rax                 ; r8 = dim2
    call advance               ; consume number
    mov rdi, TOK_RBRACKET
    mov rsi, msg_expect_rbracket
    call expect
    ; Compute total_count = dim1 * dim2
    pop rax                     ; rax = dim1
    imul rax, r8               ; rax = dim1 * dim2 (total)
    push rax                    ; save total count back on stack
    jmp .global_array_check_init
.global_array_2d_err:
    mov rsi, msg_syntax
    call error
    pop rax                     ; discard element count
    pop rax                     ; discard name
    jmp .parse_toplevel
    ; --- end 2D array support ---

.global_array_check_init:
    ; Check for '=' (array init)
    ; r8 = dim2 (0 for 1D, non-zero for 2D)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_EQ
    jne .global_array_no_init
    call advance               ; consume '='
    call parse_array_init_list
    push qword [parser_saved_const]     ; save const flag BEFORE init list
    mov qword [parser_saved_const], 0   ; reset
    push rax                   ; save init list on stack
    push r8                    ; save dim2
    jmp .global_array_have_init
.global_array_no_init:
    push qword [parser_saved_const]     ; save const flag BEFORE init list
    mov qword [parser_saved_const], 0   ; reset
    push 0                     ; no init
    push r8                    ; save dim2
.global_array_have_init:
    ; Expect ';'
    mov rdi, TOK_SEMI
    mov rsi, msg_expect_semi
    call expect
    ; Create AST_ARRAY_DECL
    mov rdi, AST_ARRAY_DECL
    call alloc_node
    test rax, rax
    jz .ga_drop_with_const
    ; Stack: name_ptr, element count, const flag, init list, dim2
    pop r9                               ; r9 = dim2 (0 for 1D)
    pop r10                              ; r10 = init list (or 0)
    pop rcx                              ; rcx = const flag
    pop r8                               ; r8 = element count (total for 2D)
    pop rdi                              ; rdi = name_ptr
    push rdi                             ; re-save name
    mov [rax + ast_node_t.data1], rbx    ; type
    mov [rax + ast_node_t.data2], rdi    ; name
    mov [rax + ast_node_t.data3], r8     ; element count (total for 2D)
    ; Encode dim2 into data5: (dim2 << 2) | const_flag
    ; Shifting by 2 avoids colliding with VAR_CONST (bit 1).
    mov rdx, r9                          ; rdx = dim2
    shl rdx, 2                           ; rdx = dim2 << 2
    or rcx, rdx                          ; rcx = const_flag | (dim2 << 2)
    mov [rax + ast_node_t.data5], rcx    ; const flag + optional dim2
    ; For non-struct arrays, store init list in data4
    cmp rbx, TOK_KW_STRUCT
    je .global_array_struct
    mov [rax + ast_node_t.data4], r10    ; init list (or 0)
    jmp .global_array_store
.global_array_struct:
    mov qword [rax + ast_node_t.data4], 0 ; no init for struct arrays
.global_array_store:
    pop rdx                              ; discard extra name copy
    jmp .store_global
.ga_drop:
    pop rcx                              ; discard element count
    pop rcx                              ; discard name
    jmp .parse_toplevel
.ga_drop_with_const:
    pop rcx                              ; discard dim2
    pop rcx                              ; discard init list
    pop rcx                              ; discard const flag
    pop rcx                              ; discard element count
    pop rcx                              ; discard name
    jmp .parse_toplevel

.global_struct:
    ; Distinguish struct definition from function with struct return type.
    ; struct Name { ... }   → struct definition
    ; struct Name func(...) → function with struct return type
    ;
    ; Strategy: call parse_struct_def first. If the next token after the
    ; tag name is '{', it will parse the struct definition successfully.
    ; If the next token is an identifier (function name), parse_struct_def
    ; will try to parse it as a variable and fail. We need to handle this.
    ;
    ; Better strategy: peek ahead by checking the token after the optional
    ; tag name. But we can't peek without consuming.
    ;
    ; Alternative: modify parse_struct_def to detect the function case
    ; (when the variable name is followed by '(' instead of ';' or '[')
    ; and handle it by calling parse_function with the right state.
    call parse_struct_def
    mov qword [parser_saved_const], 0   ; clear after const struct type def/use
    test rax, rax
    jz .parse_toplevel
    ; Check if the result is a function (AST_FUNCTION) or a struct/var
    mov rbx, [rax + ast_node_t.type]
    cmp rbx, AST_FUNCTION
    je .store_func
    jmp .store_global

.store_func:
    ; Store function pointer in array — grow if at capacity
    mov rbx, [prog_func_capacity]
    cmp r12, rbx
    jb .sf_have_room
    ; Need to grow: save rax (node), call grow_func_array, restore
    push rax
    call grow_func_array
    ; grow_func_array updates prog_func_array and prog_func_capacity,
    ; but r13 still holds the OLD pointer. Reload it.
    mov r13, [prog_func_array]
    pop rax
    ; If growth failed (capacity unchanged), fall through to error
    cmp r12, [prog_func_capacity]
    jae .too_many_funcs
.sf_have_room:
    mov rdi, rax
    mov [r13 + 8 + r12 * 8], rdi
    mov rbx, [prog_func_source_array]
    mov rax, [source_path]
    mov [rbx + 8 + r12 * 8], rax
    inc r12
    jmp .parse_toplevel

.store_global:
    ; Merge by name with any global already stored (C tentative-definition
    ; semantics): two `int x;` across two files denote the same object, so
    ; emitting the label twice would be a duplicate-definition error at
    ; assembly time. Keep the first; drop a later same-named definition.
    push rax                              ; save the new node
    mov rdi, [rax + ast_node_t.data2]     ; new name_ptr
    mov rsi, rdi
    call strlen
    push rdi                              ; [rsp] = new name_ptr
    push rax                              ; [rsp] = new name length
    xor rbx, rbx
.sg_scan:
    cmp rbx, r14
    jge .sg_scan_done
    mov rcx, [r15 + 8 + rbx * 8]          ; existing node
    test rcx, rcx
    jz .sg_scan_next
    mov rsi, [rcx + ast_node_t.data2]     ; existing name_ptr
    push rsi
    mov rdi, rsi
    call strlen
    pop rsi
    cmp rax, [rsp]                        ; same length?
    jne .sg_scan_next
    mov rdi, [rsp + 8]                    ; new name_ptr
    mov rdx, [rsp]                        ; new name length
    call mem_eq
    test rax, rax
    jnz .sg_scan_next
    jmp .sg_dup
.sg_scan_next:
    inc rbx
    jmp .sg_scan
.sg_dup:
    add rsp, 16                           ; discard saved name ptr/len
    pop rax                               ; discard the duplicate node
    jmp .parse_toplevel
.sg_scan_done:
    add rsp, 16                           ; discard saved name ptr/len
    pop rax                               ; restore the new node

    ; Store global var/array/struct in global array — grow if at capacity
    mov rbx, [prog_global_capacity]
    cmp r14, rbx
    jb .sg_have_room
    ; Need to grow: save rax (node), call grow_global_array, restore
    push rax
    call grow_global_array
    ; grow_global_array updates prog_global_array and prog_global_capacity,
    ; but r15 still holds the OLD pointer. Reload it.
    mov r15, [prog_global_array]
    pop rax
    ; If growth failed, report an error instead of silently dropping globals.
    cmp r14, [prog_global_capacity]
    jae .too_many_globals
.sg_have_room:
    mov [r15 + 8 + r14 * 8], rax
    mov rbx, [prog_global_source_array]
    mov rax, [source_path]
    mov [rbx + 8 + r14 * 8], rax
    inc r14
    jmp .parse_toplevel

.finish:
    ; Update counts in array headers
    mov [r13], r12
    mov rax, [prog_func_source_array]
    mov [rax], r12
    mov [r15], r14
    mov rax, [prog_global_source_array]
    mov [rax], r14

    ; Save counts back to persistent state
    mov [prog_func_count], r12
    mov [prog_global_count], r14

    ; Create AST_PROGRAM node
    mov rdi, AST_PROGRAM
    call alloc_node
    test rax, rax
    jz .done
    mov [rax + ast_node_t.data1], r12    ; function count
    mov [rax + ast_node_t.data2], r13    ; function array
    mov [rax + ast_node_t.data3], r14    ; global var count
    mov [rax + ast_node_t.data4], r15    ; global var array

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.too_many_funcs:
    mov rdx, msg_syntax
    mov rdi, [lexer_state + 296] ; tok_line
    mov rsi, [lexer_state + 304] ; tok_col
    call error_at
    xor rax, rax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.too_many_globals:
    mov rdx, msg_syntax
    mov rdi, [lexer_state + 296] ; tok_line
    mov rsi, [lexer_state + 304] ; tok_col
    call error_at
    xor rax, rax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ================================================================
; grow_global_array — double the capacity of prog_global_array and its
; parallel source-path array.
;
; Allocates new count-prefixed pointer arrays with double the current
; capacity, copies the old entries (including the count slot at [0]),
; and updates prog_global_array / prog_global_source_array and their
; capacities. On OOM the globals are left unchanged (capacity stays the
; same) so the caller can detect failure by re-checking capacity vs. count.
;
; Clobbers: rax, rcx, rdx, rdi, rsi (and r11 used as scratch).
; Preserves: rbx, r12-r15 (per System V ABI callee-saved set).
; ================================================================
grow_global_array:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, [prog_global_capacity]    ; old capacity
    mov r12, rbx
    shl r12, 1                         ; new capacity = old * 2

    ; Allocate new AST array: (new_capacity + 1) qwords
    mov rdi, r12
    call alloc_ptr_array
    test rax, rax
    jz .gga_done                       ; OOM → leave old array intact

    mov r14, rax                       ; r14 = new AST array

    ; Allocate new source-path array with matching capacity.
    mov rdi, r12
    call alloc_ptr_array
    test rax, rax
    jz .gga_done                       ; OOM → leave old arrays intact
    mov r13, rax                       ; r13 = new source array

    ; Copy old entries into new AST array.
    ; Old array layout: [0]=count, [1..old_cap]=pointers → (old_cap+1) qwords.
    ; New array's [0] is already set to new_capacity by alloc_ptr_array,
    ; but we want to preserve the real count, so copy everything from old.
    mov r15, [prog_global_array]       ; r15 = old array
    mov rdi, r14                       ; dst = new array
    mov rsi, r15                       ; src = old array
    mov rdx, rbx
    inc rdx                            ; copy (old_cap + 1) qwords
    shl rdx, 3                         ; bytes = qwords * 8
    call mem_copy

    ; Copy the parallel source-path entries when they exist.
    mov rax, [prog_global_source_array]
    test rax, rax
    jz .gga_restore_count
    mov rdi, r13
    mov rsi, rax
    mov rdx, rbx
    inc rdx
    shl rdx, 3
    call mem_copy

    ; Restore the real count in the new array's [0] slot (overwritten by
    ; alloc_ptr_array which set it to new_capacity; we need the actual
    ; count so codegen sees the right number).
.gga_restore_count:
    mov rax, [prog_global_count]
    mov [r14], rax
    mov [r13], rax

    mov [prog_global_array], r14
    mov [prog_global_source_array], r13
    mov [prog_global_capacity], r12
    mov [prog_global_source_capacity], r12

.gga_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ================================================================
; grow_func_array — double the capacity of prog_func_array and its
; parallel source-path array. Same algorithm as grow_global_array but
; for the function arrays.
;
; Clobbers: rax, rcx, rdx, rdi, rsi (and r11 used as scratch).
; Preserves: rbx, r12-r15.
; ================================================================
grow_func_array:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, [prog_func_capacity]      ; old capacity
    mov r12, rbx
    shl r12, 1                         ; new capacity = old * 2

    mov rdi, r12
    call alloc_ptr_array
    test rax, rax
    jz .gfa_done                       ; OOM → leave old array intact

    mov r14, rax                       ; r14 = new AST array

    mov rdi, r12
    call alloc_ptr_array
    test rax, rax
    jz .gfa_done                       ; OOM → leave old arrays intact
    mov r13, rax                       ; r13 = new source array

    mov r15, [prog_func_array]         ; r15 = old array
    mov rdi, r14                       ; dst = new array
    mov rsi, r15                       ; src = old array
    mov rdx, rbx
    inc rdx                            ; copy (old_cap + 1) qwords
    shl rdx, 3                         ; bytes = qwords * 8
    call mem_copy

    mov rax, [prog_func_source_array]
    test rax, rax
    jz .gfa_restore_count
    mov rdi, r13
    mov rsi, rax
    mov rdx, rbx
    inc rdx
    shl rdx, 3
    call mem_copy

    ; Restore the real count in the new array's [0] slot.
.gfa_restore_count:
    mov rax, [prog_func_count]
    mov [r14], rax
    mov [r13], rax

    mov [prog_func_array], r14
    mov [prog_func_source_array], r13
    mov [prog_func_capacity], r12
    mov [prog_func_source_capacity], r12

.gfa_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ================================================================
; ensure_func_registry_capacity — grow the parser's function-name
; registry and parallel field-array registry when full.
;
; On OOM, leaves the existing arrays/capacity unchanged.
; Preserves: rbx, r12-r15.
; ================================================================
ensure_func_registry_capacity:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rax, [func_registry_count]
    mov rbx, [func_name_registry_capacity]
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
    mov r14, rax                       ; new name array

    mov rdi, r13
    shl rdi, 3
    call heap_alloc_zero
    test rax, rax
    jz .done
    mov r15, rax                       ; new field array

    mov rdi, r14
    mov rsi, [func_name_registry]
    mov rdx, r12
    shl rdx, 3
    call mem_copy

    mov rdi, r15
    mov rsi, [func_field_array_ptrs]
    mov rdx, r12
    shl rdx, 3
    call mem_copy

    mov [func_name_registry], r14
    mov [func_field_array_ptrs], r15
    mov [func_name_registry_capacity], r13

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ================================================================
; parse_function() -> AST_FUNCTION*
; ================================================================
parse_function:
    push rbx
    push r12
    push r13
    push r14
    push r15

    ; Check if struct return type was pre-consumed (by parse_struct_def)
    ; In that case, current_func_return_type and current_func_return_fields
    ; are already set, and the current token is the function name.
    cmp qword [struct_ret_pre_consumed], 0
    je .pf_normal_start
    ; Pre-consumed: skip type consumption, jump to function name parsing
    mov qword [struct_ret_pre_consumed], 0   ; clear flag
    mov rbx, [current_func_return_type]
    jmp .pf_after_type

.pf_normal_start:
    ; return_type (current token is type keyword)
    mov rbx, [parser_state.current_token]

    ; Consume return type
    call advance

    ; Handle struct return type: struct [Name]
    ; If return type is struct, optionally consume tag name and look up field_array_ptr.
    cmp rbx, TOK_KW_STRUCT
    jne .not_struct_ret
    mov qword [current_func_return_fields], 0   ; default: no fields (anonymous)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_IDENT
    jne .not_struct_ret
    ; Has a tag name — look up the named struct
    call copy_token_string
    push rax
    call advance                     ; consume tag name
    pop rdi                          ; rdi = tag name
    push rbx
    call find_named_struct
    pop rbx
    mov [current_func_return_fields], rcx   ; save field_array_ptr (0 if not found)
    test rax, rax
    jnz .struct_ret_have_fields
    mov qword [current_func_return_fields], 0
.struct_ret_have_fields:
.not_struct_ret:

.pf_after_type:
    ; Handle multiple pointer type (*) modifiers
.ptr_loop_func:
    mov rax, [parser_state.current_token]
    cmp rax, TOK_STAR
    jne .ptr_done_func
    add rbx, PTR_TYPE_FLAG
    call advance
    jmp .ptr_loop_func
.ptr_done_func:
    mov [current_func_return_type], rbx    ; save for void-check in return stmts

    ; Check if function name was pre-consumed (by parse_struct_def)
    cmp qword [func_name_pre_consumed], 0
    je .pf_normal_name
    ; Pre-consumed: use the saved function name, skip name parsing
    mov qword [func_name_pre_consumed], 0   ; clear flag
    mov r12, [pre_consumed_func_name]
    jmp .pf_after_name

.pf_normal_name:
    ; Expect function name
    mov rax, [parser_state.current_token]
    cmp rax, TOK_IDENT
    je .have_name
    mov rsi, msg_expect_ident
    call error
    xor rax, rax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.have_name:
    call copy_token_string
    mov r12, rax               ; r12 = name (heap copy)
    call advance

.pf_after_name:
    ; Expect '(' — if not found, this might be a global var declaration
    mov rax, [parser_state.current_token]
    cmp rax, TOK_LPAREN
    je .have_lparen
    ; Not a function — save type+name for global var parsing
    mov [parser_saved_type], rbx
    mov [parser_saved_name], r12
    xor rax, rax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.have_lparen:
    call advance               ; consume '('

    ; Parse parameter list
    mov rdi, 127
    call alloc_ptr_array
    mov r14, rax               ; r14 = param array
    xor r15, r15               ; r15 = param count

.parse_param:
    mov rax, [parser_state.current_token]
    cmp rax, TOK_RPAREN
    je .params_done

    ; Check for 'const' keyword before type
    cmp rax, TOK_KW_CONST
    jne .parse_param_no_const
    mov qword [parser_saved_const], VAR_CONST
    call advance                     ; consume 'const'
    jmp .parse_param

.parse_param_no_const:
    ; Parse type keyword
    mov rcx, [parser_state.current_token]
    cmp rcx, TOK_KW_INT
    je .param_has_type
    cmp rcx, TOK_KW_CHAR
    je .param_has_type
    cmp rcx, TOK_KW_STRUCT
    je .param_struct_type
    cmp rcx, TOK_KW_VOID
    je .param_void_only
    ; Not a type keyword — error, try to recover
    mov rsi, msg_expect_type
    call error
    jmp .params_error

; `void` as the sole parameter (e.g., `int main(void)`) means "no parameters".
; Consume `void` and require `)` next. Any other use of `void` as a parameter
; type is rejected (void variables don't exist in C2X).
.param_void_only:
    call advance               ; consume 'void'
    mov rax, [parser_state.current_token]
    cmp rax, TOK_RPAREN
    je .params_done
    ; `void` followed by something other than `)` is an error
    mov rsi, msg_expect_rparen
    call error
    jmp .params_error

.param_struct_type:
    ; Parse struct Name param.
    ; `struct Name p` keeps the existing lowered-by-pointer ABI behavior.
    ; `struct Name* p` and deeper pointer forms are treated as explicit
    ; pointer parameters and encoded with extra PTR_TYPE_FLAG levels.
    call advance               ; consume 'struct'
    mov rax, [parser_state.current_token]
    cmp rax, TOK_IDENT
    jne .param_struct_err
    call copy_token_string
    mov r8, rax                ; r8 = tag name
    call advance               ; consume tag name
    ; Check for '{' (anonymous struct not supported)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_LBRACE
    je .param_struct_err
    ; Look up named struct to get field_array_ptr
    mov rdi, r8
    call find_named_struct
    test rax, rax
    jz .param_struct_err
    ; rax = total_size, rcx = field_array_ptr
    mov r9, rcx                ; r9 = field_array_ptr

    ; Count explicit pointer modifiers after the struct tag.
    xor r10, r10               ; r10 = explicit pointer count
.param_struct_ptr_loop:
    mov rax, [parser_state.current_token]
    cmp rax, TOK_STAR
    jne .param_struct_ptr_done
    inc r10
    call advance               ; consume '*'
    jmp .param_struct_ptr_loop
.param_struct_ptr_done:

    ; Expect param name
    mov rax, [parser_state.current_token]
    cmp rax, TOK_IDENT
    jne .param_struct_err
    call copy_token_string
    push rax                   ; save param name on the compiler stack
    call advance               ; consume param name

    ; Build the stored parameter type.
    ; Stage 0 lowers `struct Name p` to a single pointer-typed parameter.
    ; An explicit `struct Name* p` should keep that same single pointer level,
    ; while `struct Name** p` and deeper forms add extra pointer layers.
    mov rcx, TOK_KW_STRUCT
    test r10, r10
    jnz .param_struct_explicit_ptr
    add rcx, PTR_TYPE_FLAG
    jmp .param_struct_type_ready
.param_struct_explicit_ptr:
.param_struct_type_loop:
    add rcx, PTR_TYPE_FLAG
    dec r10
    jnz .param_struct_type_loop
.param_struct_type_ready:

    ; Create AST_VAR_DECL: type = computed struct/pointer type,
    ; data3 = param index, data4 = field_array_ptr.
    pop rdx                    ; rdx = param name
    push r9                    ; save field_array_ptr
    push rdx                   ; save param name
    push rcx                   ; save computed type
    mov rdi, AST_VAR_DECL
    call alloc_node
    pop rcx                    ; rcx = computed type
    pop rdx                    ; rdx = param name
    pop r9                     ; r9 = field_array_ptr
    test rax, rax
    jz .param_struct_alloc_fail
     mov [rax + ast_node_t.data1], rcx    ; type
     mov [rax + ast_node_t.data2], rdx    ; name
     mov [rax + ast_node_t.data3], r15    ; param index (for struct ptr params, data3 is unused)
     mov [rax + ast_node_t.data4], r9     ; field_array_ptr (stored in data4 for struct ptr params)
     mov qword [parser_saved_const], 0   ; clear const flag (not supported for struct ptr params)
    ; The param index is not needed after compilation.
    ; For struct pointer params, we keep field_array_ptr in data4 for codegen.
    cmp r15, 127
    jae .param_too_many
    mov [r14 + 8 + r15 * 8], rax
    inc r15
    jmp .param_after_store
.param_struct_alloc_fail:
    jmp .param_after_store
.param_struct_err:
    mov rsi, msg_syntax
    call error
    jmp .params_error

.param_has_type:
    call advance               ; consume type keyword
    ; Handle pointer modifiers
.param_ptr_loop:
    mov rax, [parser_state.current_token]
    cmp rax, TOK_STAR
    jne .param_ptr_done
    add rcx, PTR_TYPE_FLAG
    call advance
    jmp .param_ptr_loop
.param_ptr_done:

    ; Expect identifier (param name)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_IDENT
    je .param_have_name
    mov rsi, msg_expect_ident
    call error
    jmp .params_error

.param_have_name:
    push rcx                   ; save param type (alloc_node clobbers rcx)

    call copy_token_string
    push rax                   ; save param name (heap copy)

    call advance               ; consume identifier

    ; Handle array-decay in parameter declarations: `T x[]` is equivalent to `T *x`.
    ; This makes `char *argv[]` parse as `char **argv` (pointer to pointer to char).
    ; The optional size expression inside `[]` is ignored per C semantics.
    ; We must rewrite the saved type on the stack because alloc_node clobbers rcx.
    mov rax, [parser_state.current_token]
    cmp rax, TOK_LBRACKET
    jne .param_no_array_decay
    call advance               ; consume '['
    ; Optionally consume a number (the array size, ignored for param decay)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_NUMBER
    jne .param_array_no_size
    call advance               ; consume size number
.param_array_no_size:
    mov rdi, TOK_RBRACKET
    mov rsi, msg_expect_rbracket
    call expect                ; consume ']'
    ; Rewrite the saved type on the stack: T x[] becomes T *x
    ; Stack layout at this point: [param_type, param_name] (top is param_name)
    ; so the param type is at [rsp + 8].
    mov rax, [rsp + 8]         ; rax = saved param type
    add rax, PTR_TYPE_FLAG
    mov [rsp + 8], rax         ; update saved type
.param_no_array_decay:

    ; Create AST_VAR_DECL for this parameter
    mov rdi, AST_VAR_DECL
    call alloc_node
    test rax, rax
    jz .param_alloc_fail

     pop rdi                    ; rdi = param name
     pop rcx                    ; rcx = param type (possibly modified by [] decay)
     mov [rax + ast_node_t.data1], rcx    ; type
     mov [rax + ast_node_t.data2], rdi    ; name_ptr
     mov [rax + ast_node_t.data3], r15    ; param index
     ; Store const flag in data4
     mov rcx, [parser_saved_const]
     mov [rax + ast_node_t.data4], rcx
     mov qword [parser_saved_const], 0

    cmp r15, 127
    jae .param_too_many
    mov [r14 + 8 + r15 * 8], rax
    inc r15
    jmp .param_after_store

.param_alloc_fail:
    pop rdi                    ; discard param name
    pop rcx                    ; discard param type

.param_after_store:
    ; Check for comma or ')'
    mov rax, [parser_state.current_token]
    cmp rax, TOK_COMMA
    je .param_comma
    cmp rax, TOK_RPAREN
    je .params_done
    ; Unexpected token — try to recover
    jmp .params_error

.param_comma:
    call advance               ; consume ','
    jmp .parse_param

.param_too_many:
    jmp .param_after_store

.params_done:
    mov [r14], r15             ; store param count in array[0]
    jmp .params_end

.params_error:
    ; Recovery: skip until ')' or '{' or EOF
.params_recover:
    mov rax, [parser_state.current_token]
    cmp rax, TOK_RPAREN
    je .params_done
    cmp rax, TOK_LBRACE
    je .params_done
    cmp rax, TOK_EOF
    je .params_done
    call advance
    jmp .params_recover

.params_end:
    mov qword [parser_saved_const], 0   ; clear const flag (set by const param)
    ; Expect ')'
    mov rdi, TOK_RPAREN
    mov rsi, msg_expect_rparen
    call expect

    ; Register function name in registry (for forward-decl enforcement)
    push rbx
    push rcx
    push rsi
    push rdi
    mov rdi, r12                    ; function name pointer
    call register_func_name
    pop rdi
    pop rsi
    pop rcx
    pop rbx

    ; Store field_array_ptr for this function (for struct returns).
    ; The index is func_registry_count - 1 (the just-added entry).
    push rax
    push rcx
    mov rax, [func_registry_count]
    test rax, rax
    jz .skip_field_store
    dec rax
    mov rcx, [current_func_return_fields]
    mov rdx, [func_field_array_ptrs]
    mov [rdx + rax * 8], rcx
.skip_field_store:
    pop rcx
    pop rax

    ; Check for forward declaration (no body)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_SEMI
    je .forward_decl

    ; Parse body block
    call parse_block
    mov r13, rax               ; r13 = body block
    jmp .create_func_node

.forward_decl:
    call advance               ; consume ';'
    xor r13, r13               ; body_ptr = 0 (no body)

.create_func_node:
    ; Create AST_FUNCTION node
    mov rdi, AST_FUNCTION
    call alloc_node
    test rax, rax
    jz .func_done
    mov [rax + ast_node_t.data1], rbx    ; return_type
    mov [rax + ast_node_t.data2], r12    ; name_ptr
    mov [rax + ast_node_t.data3], r13    ; body_ptr (0 = forward decl)
    mov [rax + ast_node_t.data4], r14    ; param_array
    mov rdx, [current_func_return_fields]
    mov [rax + ast_node_t.data5], rdx    ; field_array_ptr (for struct returns)

.func_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ================================================================
; parse_block() -> AST_BLOCK*
; ================================================================
parse_block:
    push rbx
    push r12
    push r13
    push r14                         ; emergency iteration counter
    push r15                         ; capacity (grows dynamically)

    ; Expect '{'
    mov rdi, TOK_LBRACE
    mov rsi, msg_expect_lbrace
    call expect

    ; Allocate array for statements (grows dynamically)
    mov rdi, 32                  ; initial capacity
    call alloc_ptr_array
    mov r13, rax               ; r13 = statement array
    xor r12, r12               ; r12 = statement count
    mov r15, 32                ; r15 = current capacity
    mov r14, 4096              ; r14 = emergency iteration budget

.stmt_loop:
    dec r14
    jz .block_end               ; emergency abort if too many iterations
    mov rax, [parser_state.current_token]
    cmp rax, TOK_RBRACE
    je .block_end
    cmp rax, TOK_EOF
    je .block_end

    push rbx
    call parse_statement
    test rax, rax
    jz .stmt_failed
    pop rbx

    ; Check if array needs to grow
    cmp r12, r15
    jb .store_stmt

    ; Grow array: double capacity
    push rax                    ; save statement node
    push r13                    ; save old array pointer

    mov rdi, r15
    shl rdi, 1                  ; rdi = new capacity = old * 2
    push rdi                    ; save new capacity
    call alloc_ptr_array
    test rax, rax
    jz .grow_fail
    pop rdi                     ; rdi = new capacity
    mov r15, rdi                ; update capacity
    pop rcx                     ; rcx = old array pointer
    mov r13, rax                ; r13 = new array pointer

    ; Copy old entries to new array
    xor r8, r8                  ; i = 0
.grow_copy:
    cmp r8, r12
    jae .grow_done
    mov r9, [rcx + 8 + r8*8]
    mov [r13 + 8 + r8*8], r9
    inc r8
    jmp .grow_copy
.grow_done:
    pop rax                     ; restore statement node
    jmp .store_stmt

.grow_fail:
    add rsp, 24                 ; discard stmt node + old ptr + new cap
    jmp .block_end

.store_stmt:
    mov rdi, rax
    mov [r13 + 8 + r12 * 8], rdi
    inc r12
    jmp .stmt_loop

.stmt_failed:
    ; parse_statement returned 0 — pop saved rbx and continue
    pop rbx
    jmp .stmt_loop

.block_end:
    mov [r13], r12             ; update count
    call advance               ; consume '}'

    ; Create AST_BLOCK node
    mov rdi, AST_BLOCK
    call alloc_node
    test rax, rax
    jz .block_done
    mov [rax + ast_node_t.data1], r12    ; stmt count
    mov [rax + ast_node_t.data2], r13    ; stmt array

.block_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ================================================================
; parse_statement() -> AST node pointer (or 0)
; ================================================================
parse_statement:
    push rbx
    push r12

    mov rax, [parser_state.current_token]

    ; Check for type keyword (variable declaration)
    cmp rax, TOK_KW_INT
    je .var_decl
    cmp rax, TOK_KW_CHAR
    je .var_decl
    cmp rax, TOK_KW_CONST
    je .const_check

    cmp rax, TOK_KW_IF
    je .if_stmt
    cmp rax, TOK_KW_WHILE
    je .while_stmt
    cmp rax, TOK_KW_FOR
    je .for_stmt
    cmp rax, TOK_KW_BREAK
    je .break_stmt
    cmp rax, TOK_KW_CONTINUE
    je .continue_stmt
    cmp rax, TOK_KW_RETURN
    je .return_stmt
    cmp rax, TOK_LBRACE
    je .block_stmt
    cmp rax, TOK_IDENT
    je .expr_or_assign
    cmp rax, TOK_NUMBER
    je .expr_or_assign
    cmp rax, TOK_CHAR
    je .expr_or_assign
    cmp rax, TOK_STRING
    je .expr_or_assign
    cmp rax, TOK_LPAREN
    je .expr_or_assign
    cmp rax, TOK_STAR
    je .expr_or_assign
    cmp rax, TOK_AMPERSAND
    je .expr_or_assign
    cmp rax, TOK_MINUS
    je .expr_or_assign
    cmp rax, TOK_TILDE
    je .expr_or_assign
    cmp rax, TOK_INCR
    je .expr_or_assign
    cmp rax, TOK_DECR
    je .expr_or_assign
    cmp rax, TOK_KW_STRUCT
    je .struct_def
    cmp rax, TOK_KW_EXTERN
    je .extern_decl_stmt
    cmp rax, TOK_SEMI
    je .empty_stmt

    ; Unknown token — error
    mov rsi, msg_unexpected
    call error
    xor rax, rax
    pop r12
    pop rbx
    ret

.const_check:
    ; Advance past 'const' first, then check the next token
    call advance                     ; consume 'const'
    mov rax, [parser_state.current_token]
    cmp rax, TOK_KW_STRUCT
    je .const_struct_def
    ; Set const flag for var decl path
    mov qword [parser_saved_const], VAR_CONST
    jmp .var_decl

.extern_decl_stmt:
    ; extern declaration inside a function body — parse and discard.
    ; The function is already declared at the top level, so we just
    ; consume the declaration and return an empty statement.
    call advance                     ; consume 'extern'
    ; Expect a type keyword
    mov rax, [parser_state.current_token]
    cmp rax, TOK_KW_INT
    je .exts_parse_func
    cmp rax, TOK_KW_CHAR
    je .exts_parse_func
    cmp rax, TOK_KW_VOID
    je .exts_parse_func
    ; Unknown type — error
    mov rsi, msg_expect_type
    call error
    xor rax, rax
    pop r12
    pop rbx
    ret

.exts_parse_func:
    ; Parse the function declaration (name + params + ;)
    ; Consume type keyword
    call advance
    ; Expect function name
    mov rax, [parser_state.current_token]
    cmp rax, TOK_IDENT
    jne .exts_err
    call copy_token_string
    push rax
    call advance
    pop rdi
    ; Register the function name (if not already registered)
    push rdi
    call func_is_declared
    pop rdi
    test rax, rax
    jnz .exts_already_declared
    push rdi
    call register_func_name
    pop rdi
.exts_already_declared:
    ; Expect '('
    mov rax, [parser_state.current_token]
    cmp rax, TOK_LPAREN
    jne .exts_err
    call advance
    ; Skip parameters until ')'
    xor rcx, rcx                     ; paren depth
.exts_params_loop:
    mov rax, [parser_state.current_token]
    cmp rax, TOK_EOF
    je .exts_err
    cmp rax, TOK_RPAREN
    je .exts_params_done
    cmp rax, TOK_LPAREN
    jne .exts_not_lparen
    inc rcx
.exts_not_lparen:
    cmp rax, TOK_RPAREN
    je .exts_check_rparen
    jmp .exts_advance
.exts_check_rparen:
    dec rcx
    cmp rcx, 0
    jl .exts_err
.exts_advance:
    call advance
    jmp .exts_params_loop
.exts_params_done:
    call advance                     ; consume ')'
    ; Expect ';'
    mov rax, [parser_state.current_token]
    cmp rax, TOK_SEMI
    jne .exts_err
    call advance                     ; consume ';'
    ; Return 0 (no-op statement)
    xor rax, rax
    pop r12
    pop rbx
    ret

.exts_err:
    mov rsi, msg_unexpected
    call error
    xor rax, rax
    pop r12
    pop rbx
    ret

.var_decl:
    call parse_var_decl
    mov qword [parser_saved_const], 0
    pop r12
    pop rbx
    ret

.struct_def:
    call parse_struct_def
    pop r12
    pop rbx
    ret

.const_struct_def:
    ; 'const' already consumed by .const_check; current token is 'struct'
    mov qword [parser_saved_const], VAR_CONST
    call parse_struct_def
    mov qword [parser_saved_const], 0
    pop r12
    pop rbx
    ret

.if_stmt:
    call parse_if_stmt
    pop r12
    pop rbx
    ret

.while_stmt:
    call parse_while_stmt
    pop r12
    pop rbx
    ret

.for_stmt:
    call parse_for_stmt
    pop r12
    pop rbx
    ret

.break_stmt:
    call parse_break_stmt
    pop r12
    pop rbx
    ret

.continue_stmt:
    call parse_continue_stmt
    pop r12
    pop rbx
    ret

.return_stmt:
    call parse_return_stmt
    pop r12
    pop rbx
    ret

.block_stmt:
    call parse_block
    pop r12
    pop rbx
    ret

.expr_or_assign:
    ; Could be assignment (ident = expr) or expression (ident)
    ; Peek: after ident, if '=', it's assignment
    call parse_expression
    mov r12, rax               ; r12 = expression node

    ; Check for '=' (assignment) or compound assignment
    mov rax, [parser_state.current_token]
    cmp rax, TOK_EQ
    je .plain_assign
    cmp rax, TOK_ADDEQ
    jb .not_assign
    cmp rax, TOK_XOREQ
    ja .not_assign

    ; Compound assignment: desugar into a = a + b
    ; Save r13,r14,r15 (used by parse_block/parse_function)
    push r13
    push r14
    push r15
    push r12
    push rax
    call advance
    call parse_expression
    mov r15, rax                    ; r15 = RHS
    pop r8                          ; r8 = compound token
    pop r12                         ; r12 = LHS

    ; Map compound token -> binary operator
    mov r14, TOK_PLUS
    cmp r8, TOK_ADDEQ
    je .ca_doit
    mov r14, TOK_MINUS
    cmp r8, TOK_SUBEQ
    je .ca_doit
    mov r14, TOK_STAR
    cmp r8, TOK_MULEQ
    je .ca_doit
    mov r14, TOK_SLASH
    cmp r8, TOK_DIVEQ
    je .ca_doit
    mov r14, TOK_PERCENT
    cmp r8, TOK_MODEQ
    je .ca_doit
    mov r14, TOK_LSHIFT
    cmp r8, TOK_LSHIFT_EQ
    je .ca_doit
    mov r14, TOK_RSHIFT
    cmp r8, TOK_RSHIFT_EQ
    je .ca_doit
    mov r14, TOK_AMPERSAND
    cmp r8, TOK_ANDEQ
    je .ca_doit
    mov r14, TOK_PIPE
    cmp r8, TOK_OREQ
    je .ca_doit
    mov r14, TOK_XOR

.ca_doit:
    ; r12 = LHS, r14 = binop, r15 = RHS
    ; Clone LHS ident
    mov rdi, AST_IDENT
    call alloc_node
    test rax, rax
    jz .ca_fail
    mov r13, rax                     ; r13 = clone
    mov rdi, [r12 + ast_node_t.data1]
    mov [r13 + ast_node_t.data1], rdi

    ; Binary op: r14=op, r13=clone, r15=RHS
    mov rdi, AST_BINARY_OP
    call alloc_node
    test rax, rax
    jz .ca_fail
    mov [rax + ast_node_t.data1], r14
    mov [rax + ast_node_t.data2], r13
    mov [rax + ast_node_t.data3], r15

    ; Assign: left=r12, right=rax(binary_op)
    mov r15, rax                     ; r15 = binary op node
    mov rdi, AST_ASSIGN
    call alloc_node
    test rax, rax
    jz .ca_fail
    mov [rax + ast_node_t.data1], r12
    mov [rax + ast_node_t.data2], r15

    ; Success: restore callee-saved regs, return AST_ASSIGN
    pop r15
    pop r14
    pop r13
    push rax
    mov rdi, TOK_SEMI
    mov rsi, msg_expect_semi
    call expect
    pop rax
    pop r12
    pop rbx
    ret

.ca_fail:
    pop r15
    pop r14
    pop r13
    xor rax, rax
    push rax
    mov rdi, TOK_SEMI
    mov rsi, msg_expect_semi
    call expect
    pop rax
    pop r12
    pop rbx
    ret

.plain_assign:
    ; Build AST_ASSIGN node
    mov rdi, rax   ; save eq token (discarded)
    call advance   ; consume '='
    call parse_expression
    mov rbx, rax   ; rbx = right side

    mov rdi, AST_ASSIGN
    call alloc_node
    test rax, rax
    jz .assign_done
    mov [rax + ast_node_t.data1], r12    ; left (ident)
    mov [rax + ast_node_t.data2], rbx    ; right (expr)

.assign_done:
    ; Expect ';'
    push rax                        ; save AST_ASSIGN node pointer
    mov rdi, TOK_SEMI
    mov rsi, msg_expect_semi
    call expect                     ; expect clobbers rax with next token type
    pop rax                         ; restore AST_ASSIGN node pointer
    pop r12
    pop rbx
    ret

.not_assign:
    ; expr only (without assignment)
    mov rax, r12
    ; Expect ';'
    push rax
    mov rdi, TOK_SEMI
    mov rsi, msg_expect_semi
    call expect
    pop rax
    pop r12
    pop rbx
    ret

.empty_stmt:
    call advance   ; consume ';'
    xor rax, rax   ; no node
    pop r12
    pop rbx
    ret

; ================================================================
; parse_var_decl() -> AST_VAR_DECL*
; [const] type IDENT (= expression)? ;
; ================================================================
parse_var_decl:
    push rbx
    push r12
    push r13
    push r14
    push r15

    xor r14, r14                  ; r14 = const flag (0 default)

    ; Read const flag from parser_saved_const (set by .const_check or .global_const)
    mov r14, [parser_saved_const]
    mov qword [parser_saved_const], 0  ; reset for next decl

    ; var_type
    mov r13, [parser_state.current_token]   ; r13 = type token
    call advance

    ; Handle multiple pointer type (*)
.ptr_loop_var:
    mov rax, [parser_state.current_token]
    cmp rax, TOK_STAR
    jne .not_ptr_var
    add r13, PTR_TYPE_FLAG                  ; encode as pointer type
    call advance
    jmp .ptr_loop_var
.not_ptr_var:

    ; IDENT
    mov rax, [parser_state.current_token]
    cmp rax, TOK_IDENT
    je .have_ident
    mov rsi, msg_expect_ident
    call error
    xor rax, rax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.have_ident:
    call copy_token_string
    mov r12, rax               ; r12 = name
    call advance

    ; Check for '[' (array declaration)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_LBRACKET
    je .array_decl

    ; Check for '='
    xor rbx, rbx               ; rbx = init expression (0 if none)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_EQ
    jne .no_init

    call advance               ; consume '='
    call parse_expression
    mov rbx, rax               ; rbx = init expression

.no_init:
    ; Expect ';'
    mov rdi, TOK_SEMI
    mov rsi, msg_expect_semi
    call expect

    ; Create AST_VAR_DECL node
    mov rdi, AST_VAR_DECL
    call alloc_node
    test rax, rax
    jz .done
    mov [rax + ast_node_t.data1], r13    ; var_type
    mov [rax + ast_node_t.data2], r12    ; name_ptr
    mov [rax + ast_node_t.data3], rbx    ; init_ptr
    mov [rax + ast_node_t.data4], r14    ; const flag (VAR_CONST or 0)
    jmp .done
    jmp .done

.array_decl:
    push r14                    ; save const flag (r14 will be reused)
    call advance               ; consume '['
    ; Parse element count. A numeric literal gives a fixed-size array; any
    ; other token starts a runtime size expression (VLA): int a[x + 2];.
    ; For VLAs, r14 holds the size-expression AST* and VLA_FLAG is ORed into
    ; data5 at node creation; data3 stores the expression instead of a count.
    mov rax, [parser_state.current_token]
    cmp rax, TOK_RBRACKET
    je .array_no_count           ; empty [] — not supported as a local
    cmp rax, TOK_NUMBER
    jne .array_vla_size
    call parse_number_value
    mov r14, rax               ; r14 = element count (dim1, or total if 2D)
    call advance               ; consume number
    ; Expect ']'
    mov rdi, TOK_RBRACKET
    mov rsi, msg_expect_rbracket
    call expect
    xor r15, r15               ; r15 = dim2 (0 = 1D, no VLA flag)
    ; --- 2D array support: check for a second dimension [M] ---
    mov rax, [parser_state.current_token]
    cmp rax, TOK_LBRACKET
    jne .array_check_init
    call advance               ; consume '['
    mov rax, [parser_state.current_token]
    cmp rax, TOK_NUMBER
    jne .array_no_count_2d
    call parse_number_value
    mov r15, rax               ; r15 = dim2
    call advance               ; consume number
    mov rdi, TOK_RBRACKET
    mov rsi, msg_expect_rbracket
    call expect
    ; total_count = dim1 * dim2
    mov rax, r14
    imul rax, r15
    mov r14, rax               ; r14 = total element count
    jmp .array_check_init
.array_no_count_2d:
    mov rsi, msg_syntax
    call error
    xor rax, rax
    pop r14                     ; discard saved const flag
    pop r15
    jmp .done
    ; --- end 2D array support ---

.array_vla_size:
    ; Runtime-sized array (VLA): parse a full expression as the element count.
    call parse_expression
    mov r14, rax               ; r14 = size expression AST*
    ; Expect ']'
    mov rdi, TOK_RBRACKET
    mov rsi, msg_expect_rbracket
    call expect
    ; Mark as VLA: set r15 = -1 (sentinel that can't be a valid dim2, which
    ; is always >= 1). data5 gets VLA_FLAG at node creation.
    mov r15, -1
    ; A VLA cannot have a second dimension; if one follows, error.
    mov rax, [parser_state.current_token]
    cmp rax, TOK_LBRACKET
    jne .array_check_init
    mov rsi, msg_syntax
    call error
    jmp .array_check_init

.array_check_init:
    ; Check for '=' (array init)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_EQ
    jne .array_no_init
    call advance               ; consume '='
    ; Parse array initializer list: { expr, expr, ... }
    call parse_array_init_list
    mov r8, rax                ; r8 = init list (AST_INIT_LIST*)
    jmp .array_have_init
.array_no_init:
    xor r8, r8                 ; r8 = 0 (no init)
.array_have_init:
    ; Create AST_ARRAY_DECL node
    mov rdi, AST_ARRAY_DECL
    call alloc_node
    push rax                         ; save node pointer before expect clobbers rax
    ; Expect ';'
    mov rdi, TOK_SEMI
    mov rsi, msg_expect_semi
    call expect
    pop rax                          ; restore node pointer
    test rax, rax
    jz .array_pop_const              ; alloc failed — pop const flag and bail
    mov [rax + ast_node_t.data1], r13    ; var_type
    mov [rax + ast_node_t.data2], r12    ; name_ptr
    mov [rax + ast_node_t.data3], r14    ; element count, or size-expression AST* (VLA)
    pop rcx                              ; rcx = const flag (restore from stack)
    ; Build data5: const flag | dim2<<2 (for fixed 2D) | VLA_FLAG (for VLAs).
    ; r15 holds either dim2 (fixed array, >=0) or -1 for a VLA.
    test r15, r15
    jz .array_store_const_1d
    cmp r15, -1
    je .array_store_vla
    ; 2D fixed array: data5 = (dim2 << 2) | const_flag
    shl r15, 2
    or rcx, r15
    jmp .array_store_const_1d
.array_store_vla:
    or rcx, VLA_FLAG
.array_store_const_1d:
    mov [rax + ast_node_t.data5], rcx    ; store flags + optional dim2
    ; For non-struct arrays, store init list in data4 (0 for none)
    cmp r13, TOK_KW_STRUCT
    je .done
    mov [rax + ast_node_t.data4], r8     ; init list (or 0)
    jmp .done

.array_pop_const:
    add rsp, 8                           ; discard saved const flag
    jmp .done

.array_no_count:
    add rsp, 8                  ; discard saved const flag (stack cleanup)
    mov rsi, msg_syntax
    call error
    xor rax, rax

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ================================================================
; register_named_struct(rdi = name_ptr, rsi = total_size, rdx = field_array_ptr)
; Register a named struct type for later lookup by tag name.
; ================================================================
    global register_named_struct
register_named_struct:
    push rdi
    push rsi
    push rdx
    push rbx
    push rcx

    mov rax, [named_struct_count]
    cmp rax, MAX_NAMED_STRUCTS
    jae .done

    imul rbx, rax, 8
    mov [named_struct_names + rbx], rdi
    mov [named_struct_sizes + rbx], rsi
    mov [named_struct_fields + rbx], rdx
    inc qword [named_struct_count]
    ; Return the registry index in rax (callers that pre-register placeholders
    ; need it to update the entry / patch forward references later).
    mov rax, rbx
    shr rax, 3
    jmp .ret

.done:
    mov rax, -1
.ret:
    pop rcx
    pop rbx
    pop rdx
    pop rsi
    pop rdi
    ret

; ================================================================
; find_named_struct_index(rdi = name_ptr) -> rax = index, or -1 if not found.
; Like find_named_struct but returns the registry slot so callers can update
; a forward-declared placeholder in place.
; ================================================================
    global find_named_struct_index
find_named_struct_index:
    push rbx
    push r8
    push r9
    push r10
    mov r8, [named_struct_count]
    test r8, r8
    jz .fnsi_not_found
    mov rsi, rdi
    call strlen
    mov r9, rax
    mov r10, rdi
    xor rbx, rbx
.fnsi_loop:
    cmp rbx, r8
    jge .fnsi_not_found
    imul rax, rbx, 8
    mov rdi, [named_struct_names + rax]
    mov rsi, rdi
    push rcx
    call strlen
    pop rcx
    cmp rax, r9
    jne .fnsi_next
    mov rsi, r10
    mov rdx, r9
    call mem_eq
    test rax, rax
    jz .fnsi_found
.fnsi_next:
    inc rbx
    jmp .fnsi_loop
.fnsi_found:
    mov rax, rbx
    pop r10
    pop r9
    pop r8
    pop rbx
    ret
.fnsi_not_found:
    mov rax, -1
    pop r10
    pop r9
    pop r8
    pop rbx
    ret

; ================================================================
; find_named_struct(rdi = name_ptr) -> rax=total_size, rcx=field_array_ptr
; Find a named struct type by tag name. Returns 0 if not found.
; strcmp-style: uses mem_eq for comparison.
; ================================================================
    global find_named_struct
find_named_struct:
    push rbx
    push r8
    push r9
    push r10

    mov r8, [named_struct_count]
    test r8, r8
    jz .nf_not_found

    ; Get target name length
    mov rsi, rdi
    call strlen
    mov r9, rax                ; r9 = target length
    mov r10, rdi               ; r10 = target name ptr

    xor rbx, rbx               ; rbx = index
.nf_loop:
    cmp rbx, r8
    jge .nf_not_found

    ; Get registered name: use rax for temp offset
    imul rax, rbx, 8
    mov rdi, [named_struct_names + rax]  ; rdi = registered name
    
    ; Compare lengths
    mov rsi, rdi
    push rcx
    call strlen
    pop rcx
    cmp rax, r9
    jne .nf_next

    ; Lengths match — compare strings
    ; rdi = registered name, r10 = target name, r9 = length
    mov rsi, r10               ; rsi = target name
    mov rdx, r9                ; rdx = length
    call mem_eq
    test rax, rax
    jz .nf_found               ; mem_eq returns 0 if equal

.nf_next:
    inc rbx
    jmp .nf_loop

.nf_found:
    imul rax, rbx, 8
    mov rax, [named_struct_sizes + rax]
    imul rcx, rbx, 8
    mov rcx, [named_struct_fields + rcx]
    pop r10
    pop r9
    pop r8
    pop rbx
    ret

.nf_not_found:
    xor rax, rax
    xor rcx, rcx
    pop r10
    pop r9
    pop r8
    pop rbx
    ret

; ================================================================
; fwd_ref_record(rdi = registry index, rsi = &field_descriptor.sub_array_ptr)
; Remember that the field descriptor at rsi should receive the field array
; pointer of the struct registered at index rdi once that struct is defined.
; ================================================================
fwd_ref_record:
    push rax
    push rbx
    mov rax, [fwd_ref_count]
    cmp rax, FWD_REF_MAX
    jae .fr_done
    mov rbx, rax
    shl rbx, 3
    mov [fwd_ref_slot + rbx], rdi
    mov [fwd_ref_desc + rbx], rsi
    inc qword [fwd_ref_count]
.fr_done:
    pop rbx
    pop rax
    ret

; ================================================================
; fwd_ref_patch(rdi = registry index, rsi = field_array_ptr)
; When a struct with the given registry index is defined, copy its field array
; pointer into every field descriptor that forward-referenced it.
; ================================================================
fwd_ref_patch:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    xor rcx, rcx                  ; rcx = scan index
.frp_loop:
    cmp rcx, [fwd_ref_count]
    jge .frp_done
    mov rbx, rcx
    shl rbx, 3
    mov rax, [fwd_ref_slot + rbx]
    cmp rax, rdi
    jne .frp_next
    mov rdx, [fwd_ref_desc + rbx]
    mov [rdx], rsi                ; descriptor.sub_array_ptr = field_array_ptr
.frp_next:
    inc rcx
    jmp .frp_loop
.frp_done:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ================================================================
; parse_struct_def() -> AST_STRUCT_DEF*
; struct [tag] { type name; ... } var;
; ================================================================
parse_struct_def:
    push rbx
    push r12
    push r13
    push r14
    push r15

    call advance                     ; consume 'struct'
    xor r14, r14                     ; r14 = tag name (0 = anonymous)

    ; Check for named struct tag: struct ident { ... }
    mov rax, [parser_state.current_token]
    cmp rax, TOK_IDENT
    jne .have_body                   ; no tag → anonymous struct

    ; Save the struct tag name
    call copy_token_string
    mov r14, rax                     ; r14 = tag name (or 0 for anonymous)
    call advance                     ; consume tag name

    ; Check if followed by '{' (struct definition) or something else (variable)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_LBRACE
    je .have_body                    ; struct Name { ... } → parse body

    ; Not followed by '{' — this is a variable of named struct type: struct Name var;
    ; r14 = struct type name (tag)
    ; Current token should be the variable name
    mov rdi, r14
    call find_named_struct
    ; rax = total_size, rcx = field_array_ptr
    test rax, rax
    jz .unknown_type                ; struct type not registered

    mov r13, rax                     ; r13 = total_size (from registered type)
    mov r15, rcx                     ; r15 = field_array_ptr

    ; Check for pointer type modifiers: struct Name *var;
    xor r14, r14                     ; r14 = ptr_count
.ptr_check:
    mov rax, [parser_state.current_token]
    cmp rax, TOK_STAR
    jne .ptr_done
    inc r14                          ; ptr_count++
    call advance                     ; consume '*'
    jmp .ptr_check
.ptr_done:

    ; Parse variable name (must be an identifier)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_IDENT
    jne .expected_ident_err

    call copy_token_string
    mov rbx, rax                     ; rbx = var name
    call advance

    test r14, r14
    jnz .create_ptr_var              ; has pointer modifier

    ; Not a pointer — check for '(' (function with struct return type)
    ; e.g., "struct Token next_token(void)" — after consuming the function
    ; name, the next token is '(', not ';' or '['.
    mov rax, [parser_state.current_token]
    cmp rax, TOK_LPAREN
    jne .psd_not_func
    ; It's a function! Set up flags and call parse_function.
    ; rbx = function name (just parsed), current token = '('
    ; Save the function name for parse_function to use
    mov [pre_consumed_func_name], rbx
    ; Set the pre-consumed flags
    mov qword [struct_ret_pre_consumed], 1
    mov qword [func_name_pre_consumed], 1
    ; Set the return type info
    mov qword [current_func_return_type], TOK_KW_STRUCT
    mov [current_func_return_fields], r15   ; field_array_ptr
    ; Call parse_function
    call parse_function
    ; Clean up and return
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.psd_not_func:
    ; Not a pointer — check for array: struct Name var[N]
    mov rax, [parser_state.current_token]
    cmp rax, TOK_LBRACKET
    je .named_struct_array

    ; Check for '=' (struct initializer)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_EQ
    je .named_struct_init

    ; Single struct variable — no init
    mov rdi, TOK_SEMI
    mov rsi, msg_expect_semi
    call expect

    mov rdi, AST_STRUCT_DEF
    call alloc_node
    test rax, rax
    jz .sd_done
    mov [rax + ast_node_t.data1], r13    ; total_size
    mov [rax + ast_node_t.data2], r15    ; field_array ptr
    mov [rax + ast_node_t.data3], rbx    ; var name ptr
    mov qword [rax + ast_node_t.data4], 0 ; no init
    mov r8, [parser_saved_const]
    mov [rax + ast_node_t.data5], r8     ; const flag
    jmp .sd_done

.named_struct_init:
    call advance                     ; consume '='
    ; Check if initializer is a brace list ({ ... }) or an expression
    mov rax, [parser_state.current_token]
    cmp rax, TOK_LBRACE
    je .named_struct_init_list
    ; Expression initializer (e.g., function call returning struct)
    push r15                         ; save field_array_ptr
    call parse_expression
    pop r15                          ; restore field_array_ptr
    mov r14, rax                     ; r14 = init expression
    jmp .named_struct_init_done
.named_struct_init_list:
    push r15                         ; save field_array_ptr
    mov rdi, r15                     ; rdi = field_array_ptr
    call parse_init_list
    pop r15                          ; restore field_array_ptr
    mov r14, rax                     ; r14 = init list node
.named_struct_init_done:
    ; Expect ';'
    mov rdi, TOK_SEMI
    mov rsi, msg_expect_semi
    call expect
    ; Create AST_STRUCT_DEF node with init
    mov rdi, AST_STRUCT_DEF
    call alloc_node
    test rax, rax
    jz .sd_done
    mov [rax + ast_node_t.data1], r13    ; total_size
    mov [rax + ast_node_t.data2], r15    ; field_array ptr
    mov [rax + ast_node_t.data3], rbx    ; var name ptr
    mov [rax + ast_node_t.data4], r14    ; init expr/list ptr
    mov r8, [parser_saved_const]
    mov [rax + ast_node_t.data5], r8     ; const flag
    jmp .sd_done

.named_struct_array:
    ; struct Name arr[N] — create AST_ARRAY_DECL
    call advance                        ; consume '['
    mov rax, [parser_state.current_token]
    cmp rax, TOK_NUMBER
    jne .expected_number_err
    call parse_number_value
    mov r12, rax                        ; r12 = element count
    call advance                        ; consume number
    mov rdi, TOK_RBRACKET
    mov rsi, msg_expect_rbracket
    call expect
    mov rdi, TOK_SEMI
    mov rsi, msg_expect_semi
    call expect

    push r15                            ; save field_array_ptr
    push rbx                            ; save name
    mov rdi, AST_ARRAY_DECL
    call alloc_node
    pop rbx                             ; rbx = name
    pop r15                             ; r15 = field_array_ptr
    test rax, rax
    jz .sd_done
    mov [rax + ast_node_t.data1], r13   ; struct total_size (for BSS alloc)
    mov [rax + ast_node_t.data2], rbx   ; name
    mov [rax + ast_node_t.data3], r12   ; element count
    mov [rax + ast_node_t.data4], r15   ; field_array_ptr
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.create_ptr_var:
    ; Create AST_VAR_DECL for struct pointer
    ; data1 = TOK_KW_STRUCT + PTR_TYPE_FLAG * ptr_count  (r14 = count)
    ; data2 = name
    ; data3 = init expression (or 0 if no init)
    ; data4 = field_array_ptr (for struct pointers, ptr_count >= 1)

    ; Check for a function returning a struct pointer:
    ;   struct Name *...* func(params) { ... }
    ; If the token following the name is '(', this is a function (not a
    ; variable).  Route to parse_function with the return type already
    ; consumed, mirroring the non-pointer struct-return handling above
    ; (see .psd_not_func).  rbx = name, r14 = ptr_count, r15 = fields.
    mov rax, [parser_state.current_token]
    cmp rax, TOK_LPAREN
    jne .ptr_not_func
    ; Compute return type = TOK_KW_STRUCT + PTR_TYPE_FLAG * ptr_count.
    mov rax, TOK_KW_STRUCT
    mov rcx, r14
.ptr_ret_type_loop:
    test rcx, rcx
    jz .ptr_ret_type_done
    add rax, PTR_TYPE_FLAG
    dec rcx
    jmp .ptr_ret_type_loop
.ptr_ret_type_done:
    mov [current_func_return_type], rax
    ; Struct pointer returns use the plain pointer ABI (value in rax, no
    ; hidden struct-copy slot). The pointee's field_array_ptr IS needed,
    ; though: member access on the call result (p_cur()->kind, f()->x)
    ; resolves the field through it (codegen .gc_set_ret_type). r15 holds
    ; the struct's field array here.
    mov [current_func_return_fields], r15
    ; Hand the function name and pre-consumed flags to parse_function.
    mov [pre_consumed_func_name], rbx
    mov qword [struct_ret_pre_consumed], 1
    mov qword [func_name_pre_consumed], 1
    call parse_function
    jmp .sd_done
.ptr_not_func:

    ; Check for array: struct Name* arr[N]
    mov rax, [parser_state.current_token]
    cmp rax, TOK_LBRACKET
    jne .ptr_not_array
    call advance                     ; consume '['
    mov rax, [parser_state.current_token]
    cmp rax, TOK_NUMBER
    jne .expected_number_err
    call parse_number_value
    mov r12, rax                     ; r12 = element count
    call advance                     ; consume number
    mov rdi, TOK_RBRACKET
    mov rsi, msg_expect_rbracket
    call expect
    mov rdi, TOK_SEMI
    mov rsi, msg_expect_semi
    call expect

    ; Build type: TOK_KW_STRUCT + PTR_TYPE_FLAG * ptr_count
    mov rcx, TOK_KW_STRUCT
    mov r13, r14                     ; r13 = ptr_count (counter)
.ptr_array_type_loop:
    add rcx, PTR_TYPE_FLAG
    dec r13
    jnz .ptr_array_type_loop

    ; Create AST_ARRAY_DECL for struct pointer array
    push r15                         ; save field_array_ptr
    push rbx                         ; save name
    push rcx                         ; save type
    push r12                         ; save element count
    mov rdi, AST_ARRAY_DECL
    call alloc_node
    pop r12                          ; r12 = element count
    pop rcx                          ; rcx = type
    pop rbx                          ; rbx = name
    pop r15                          ; r15 = field_array_ptr
    test rax, rax
    jz .sd_done
    mov [rax + ast_node_t.data1], rcx    ; type (struct ptr)
    mov [rax + ast_node_t.data2], rbx    ; name
    mov [rax + ast_node_t.data3], r12    ; element count
    mov [rax + ast_node_t.data4], r15    ; field_array_ptr
    jmp .sd_done

.ptr_not_array:
    ; Check for optional '=' initializer
    xor r12, r12                     ; r12 = init expression (0 if none)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_EQ
    jne .ptr_no_init
    call advance                     ; consume '='
    call parse_expression
    mov r12, rax                     ; r12 = init expression
.ptr_no_init:

    mov rdi, TOK_SEMI
    mov rsi, msg_expect_semi
    call expect

    ; Build type: start with TOK_KW_STRUCT, add PTR_TYPE_FLAG per pointer level
    mov rcx, TOK_KW_STRUCT
    mov r13, r14                     ; r13 = ptr_count (counter)
.pointer_type_loop:
    add rcx, PTR_TYPE_FLAG
    dec r13
    jnz .pointer_type_loop

    ; rcx = type, rbx = name, r14 = ptr_count, r15 = field_array_ptr, r12 = init
    mov rdi, AST_VAR_DECL
    push rcx
    push rbx
    push r14
    push r15
    push r12
    call alloc_node
    pop r12
    pop r15
    pop r14
    pop rbx
    pop rcx
    test rax, rax
    jz .sd_done
    mov [rax + ast_node_t.data1], rcx    ; type
    mov [rax + ast_node_t.data2], rbx    ; name
    mov [rax + ast_node_t.data3], r12    ; init expression (or 0)
    ; Store field_array_ptr in data4 for struct pointers (ptr_count >= 1)
    test r14, r14
    jz .ptr_no_fields
    mov [rax + ast_node_t.data4], r15    ; field_array_ptr
    jmp .sd_ptr_done
.ptr_no_fields:
    mov qword [rax + ast_node_t.data4], 0
.sd_ptr_done:
    jmp .sd_done
    ; and not modify it. Then at the end, check r12.


.unknown_type:
    ; Struct type not found — report error and skip to ';'
    mov rsi, msg_syntax
    call error
    jmp .skip_to_semi

.expected_ident_err:
    mov rsi, msg_expect_ident
    call error
    jmp .skip_to_semi

.expected_number_err:
    mov rsi, msg_syntax
    call error

.skip_to_semi:
    ; Skip tokens until ';' or EOF
    mov rax, [parser_state.current_token]
    cmp rax, TOK_SEMI
    je .skip_semi_done
    cmp rax, TOK_EOF
    je .skip_semi_done
    call advance
    jmp .skip_to_semi
.skip_semi_done:
    call advance                     ; consume ';'
    xor rax, rax                     ; return null
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.have_body:
    ; r14 = tag name (0 if anonymous, non-0 if named)
    ; Save tag name on stack: it will be overwritten by field parsing
    ; Stack layout at this point: [tag, ...saved regs...]
    push r14                         ; save tag name above saved regs

    ; Current token is '{'
    mov rdi, TOK_LBRACE
    mov rsi, msg_expect_lbrace
    call expect

    ; Allocate field descriptor buffer: room for 32 fields × 32 bytes + 8 byte count
    mov rdi, 32 * 32 + 8
    call heap_alloc_zero
    mov r15, rax                     ; r15 = field array base
    mov qword [r15], 0               ; field count = 0
    xor r12, r12                     ; r12 = field count
    xor r13, r13                     ; r13 = current offset (total size)
    push qword 1                     ; [rsp] = max_alignment (starts at 1)

    ; Pre-register named struct with size=0 so self-references in the body
    ; (e.g., `struct Node { struct Node* next; }`) can find the type.
    ; Store the index in a global so we don't need extra stack slots.
    ; If a forward-reference placeholder already exists for this tag (created
    ; when an earlier struct referenced it through a pointer), reuse that slot
    ; instead of creating a duplicate — the field descriptors to back-patch are
    ; keyed on that slot index.
    mov qword [struct_pre_reg_index], -1   ; default: not pre-registered
    mov rax, [rsp + 8]               ; rax = tag name (saved above saved regs)
    test rax, rax
    jz .field_loop
    mov rdi, rax                     ; rdi = tag name
    push r15                         ; save field array ptr
    call find_named_struct_index
    pop r15
    cmp rax, 0
    jge .pre_reg_existing
    mov rdi, [rsp + 8]               ; rdi = tag name
    xor rsi, rsi                     ; rsi = size = 0 (placeholder)
    mov rdx, r15                     ; rdx = field array ptr
    call register_named_struct
.pre_reg_existing:
    mov [struct_pre_reg_index], rax  ; save index for later size update
    ; Point the entry at this body's field array now, so self-references inside
    ; the body (which look the struct up mid-parse) can resolve fields.
    mov rbx, rax
    shl rbx, 3
    mov [named_struct_fields + rbx], r15

.field_loop:
    mov rax, [parser_state.current_token]
    cmp rax, TOK_RBRACE
    je .fields_done
    cmp rax, TOK_EOF
    je .fields_done

    ; Reset const flag for this field
    mov qword [parser_field_const], 0

    ; Check for leading `const` qualifier (e.g. `const int field;`)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_KW_CONST
    jne .field_type_check
    mov qword [parser_field_const], 1
    call advance                     ; consume 'const'
.field_type_check:
    ; Parse field type
    mov rax, [parser_state.current_token]
    cmp rax, TOK_KW_INT
    je .field_int
    cmp rax, TOK_KW_CHAR
    je .field_char
    cmp rax, TOK_KW_STRUCT
    je .field_struct
    ; Unknown type in struct
    mov rsi, msg_expect_type
    call error
    call advance
    jmp .field_loop

.field_int:
    mov r14, TOK_KW_INT              ; r14 = field type
    mov rcx, 8                       ; field size
    jmp .field_ptr_check
.field_char:
    mov r14, TOK_KW_CHAR
    mov rcx, 1
.field_ptr_check:
    call advance                     ; consume type keyword

    ; Handle multiple pointer type (*) modifiers
.field_ptr_loop:
    mov rax, [parser_state.current_token]
    cmp rax, TOK_STAR
    jne .have_field_type
    add r14, PTR_TYPE_FLAG           ; encode as pointer type
    mov rcx, 8                       ; pointer size
    call advance
    jmp .field_ptr_loop
.have_field_type:
    ; Trailing const after type/pointer: `int const field;` or `int* const field;`
    mov rax, [parser_state.current_token]
    cmp rax, TOK_KW_CONST
    jne .field_align_start
    mov qword [parser_field_const], 1
    call advance
.field_align_start:

    ; Align current offset to field's alignment before storing
    cmp rcx, 1
    je .align_done
    mov rax, r13
    add rax, 7
    and rax, -8
    mov r13, rax
    mov rax, [rsp]
    cmp rax, rcx
    jae .align_done
    mov [rsp], rcx
.align_done:

    ; Expect field name
    mov rax, [parser_state.current_token]
    cmp rax, TOK_IDENT
    jne .field_bad

    call copy_token_string           ; rax = field name ptr
    mov rbx, rax                     ; rbx = field name
    call advance                     ; consume field name

    ; Check for array field: name[N]
    xor r8, r8                       ; r8 = element count (0 = not array)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_LBRACKET
    jne .field_semi
    ; Array field: parse [N]
    call advance                     ; consume '['
    mov rax, [parser_state.current_token]
    cmp rax, TOK_NUMBER
    jne .field_bad
    call parse_number_value              ; rax = element count
    mov r8, rax                          ; r8 = element count
    call advance                         ; consume number
    mov rdi, TOK_RBRACKET
    mov rsi, msg_expect_rbracket
    call expect                      ; expect ']'
    ; Update type: add ARRAY_TYPE_FLAG
    add r14, ARRAY_TYPE_FLAG
    ; Update field size: rcx = element_count * element_size
    mov rax, r8
    imul rcx, rax                    ; rcx = count * element_size

.field_semi:
    ; Expect ';'
    mov rdi, TOK_SEMI
    mov rsi, msg_expect_semi
    call expect

    ; Store field descriptor: [name_ptr, offset, type, sub_array_ptr]
    cmp r12, 32
    jae .field_loop                  ; too many fields, skip

    imul rdi, r12, 32                ; rdi = field index * 32
    add rdi, 8                       ; +8 for count header
    add rdi, r15                     ; rdi = address in field array
    mov [rdi], rbx                   ; name_ptr
    mov [rdi + 8], r13               ; offset (aligned)
    mov [rdi + 16], r14              ; type (with ARRAY_TYPE_FLAG if array)
    mov [rdi + 24], r8               ; sub_array_ptr (0 for simple, count for array)

    ; Apply const flag: OR FIELD_CONST_FLAG into the type if `const` was seen
    cmp qword [parser_field_const], 0
    je .field_no_const_flag
    or qword [rdi + 16], FIELD_CONST_FLAG
.field_no_const_flag:

    inc r12                          ; field count++
    add r13, rcx                     ; total size += field size
    jmp .field_loop

.field_struct:
    ; Current token is TOK_KW_STRUCT
    call advance                     ; consume 'struct'

    ; Check for named struct type: struct Name field or struct Name { ... }
    mov rax, [parser_state.current_token]
    cmp rax, TOK_IDENT
    jne .fs_anonymous
    ; Has a tag name after struct
    call copy_token_string
    push rax                         ; save tag name
    call advance                     ; consume tag name
    mov rax, [parser_state.current_token]
    cmp rax, TOK_LBRACE
    jne .fs_named_ref
    ; struct Name { ... } — type definition with body, pop tag and parse inline
    pop rdi                          ; discard tag (will be registered in have_body)
    jmp .fs_body

.fs_named_ref:
    ; struct Name field; — reference to previously defined named struct
    pop rdi                          ; rdi = tag name
    push r12                         ; save outer field count (r12)
    push r13                         ; save outer offset (r13)
    push r15                         ; save outer field array (r15)
    push r8                          ; save r8 (caller-saved, but be safe)
    ; Save the tag name so we can re-look-up / register a placeholder if the
    ; struct is not defined yet (forward reference through a pointer).
    push rdi                         ; save tag name
    call find_named_struct
    ; rax = total_size, rcx = field_array_ptr
    mov r9, rax                      ; r9 = total_size (field size)
    mov r8, rcx                      ; r8 = sub_array_ptr
    pop rdi                          ; rdi = tag name
    ; Remember whether this was found, for the forward-reference branch.
    mov qword [parser_fwd_index], -1
    test r8, r8
    jnz .fs_named_found
    ; Not defined yet. Only pointer fields can forward-reference a struct
    ; (their size is always 8). Peek the next tokens for at least one '*'
    ; before the field name; if present, register a placeholder struct and
    ; schedule a back-patch of this field's field-array pointer.
    mov rax, [parser_state.current_token]
    cmp rax, TOK_STAR
    jne .fs_named_ref_bad            ; non-pointer field to unknown struct → error
    push rdi
    xor rsi, rsi                     ; placeholder size = 0 (unknown yet)
    xor rdx, rdx                     ; placeholder field array = 0
    call register_named_struct
    mov [parser_fwd_index], rax      ; index of the placeholder for back-patch
    pop rdi
    xor r8, r8                       ; no field array yet
    xor r9, r9                       ; size 0
    jmp .fs_named_found
.fs_named_ref_bad:
    pop rcx                          ; discard saved r8
    pop r15
    pop r13
    pop r12
    jmp .field_bad
.fs_named_found:
    pop rcx                          ; discard saved r8
    pop r15                          ; restore outer field array
    pop r13                          ; restore outer offset
    pop r12                          ; restore outer field count
    mov rcx, r9                      ; rcx = field size
    mov r14, TOK_KW_STRUCT           ; field type

    ; Handle optional `*` for `struct Name*` pointer fields.
    ; `struct Name*` is encoded as TOK_KW_STRUCT + PTR_TYPE_FLAG (same as
    ; struct parameters — passed by pointer at the ABI level).
    ; Each `*` makes the field a pointer: size must be 8 bytes, not the
    ; pointee struct's total_size (which was loaded into rcx above).
.fs_named_ptr_loop:
    mov rax, [parser_state.current_token]
    cmp rax, TOK_STAR
    jne .fs_named_no_ptr
    add r14, PTR_TYPE_FLAG
    mov rcx, 8                   ; pointer fields are always 8 bytes
    call advance                 ; consume '*'
    jmp .fs_named_ptr_loop
.fs_named_no_ptr:
    ; By-value field of a struct that is still being defined (its registry
    ; entry is the pre-registration with size 0 — e.g. `struct G { struct G s; }`
    ; or `struct G { struct G arr[2]; }`). The type has infinite size; C says
    ; "array type has incomplete element type", we say it in plain words.
    ; Pointer fields were rewired to size 8 above, so only by-value fields
    ; reach this test with size 0. Without the check, struct_total_size
    ; recurses into the struct's own (incomplete) field array forever.
    ; The saved registers were already restored at .fs_named_found, so this
    ; path must not pop anything.
    test rcx, rcx
    jnz .fs_size_ok
    mov rsi, msg_infinite_struct
    call error
    call advance
    jmp .field_loop
.fs_size_ok:

    ; Trailing const after struct type/pointers: `struct Name const field;`
    mov rax, [parser_state.current_token]
    cmp rax, TOK_KW_CONST
    jne .fs_named_align_start
    mov qword [parser_field_const], 1
    call advance
.fs_named_align_start:

    ; Align offset: named struct fields are 8-byte aligned
    mov rax, r13
    add rax, 7
    and rax, -8
    mov r13, rax
    mov rax, [rsp]
    cmp rax, 8
    jae .fs_named_align_ok
    mov qword [rsp], 8
.fs_named_align_ok:
    ; Expect field name
    mov rax, [parser_state.current_token]
    cmp rax, TOK_IDENT
    jne .field_bad
    call copy_token_string
    mov rbx, rax
    call advance

    ; Check for array field: name[N]
    xor r9, r9                       ; r9 = element count (0 = not array)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_LBRACKET
    jne .ns_field_semi
    call advance                     ; consume '['
    mov rax, [parser_state.current_token]
    cmp rax, TOK_NUMBER
    jne .field_bad
    call parse_number_value
    mov r9, rax                      ; r9 = element count
    call advance                     ; consume number
    mov rdi, TOK_RBRACKET
    mov rsi, msg_expect_rbracket
    call expect                      ; expect ']'
    ; Update type and size for array field
    add r14, ARRAY_TYPE_FLAG
    mov rax, r9
    imul rcx, rax                    ; rcx *= element count
    ; For struct array fields (type = ARRAY_TYPE_FLAG + TOK_KW_STRUCT),
    ; pack both element count and field_array_ptr into a heap-allocated info struct.
    ; Otherwise (pointer-to-struct array), sub_array_ptr = element count directly.
    mov rax, r14
    sub rax, ARRAY_TYPE_FLAG
    cmp rax, TOK_KW_STRUCT
    jne .ns_no_struct_info
    ; r14 = ARRAY_TYPE_FLAG + TOK_KW_STRUCT: allocate info struct
    push r8                          ; save field_array_ptr
    push rcx                         ; save field size
    push r9                          ; save element count
    mov rdi, 16
    call heap_alloc_zero
    mov rdx, rax                     ; rdx = info struct ptr
    pop r9                           ; restore element count
    pop rcx                          ; restore field size
    pop r8                           ; restore field_array_ptr
    mov [rdx], r9                    ; info[0] = element count
    mov [rdx + 8], r8                ; info[8] = field_array_ptr
    mov r8, rdx                      ; r8 = info struct ptr (as sub_array_ptr)
    jmp .ns_field_semi
.ns_no_struct_info:
    ; Pointer-to-struct array fields: sub_array_ptr cannot hold both the
    ; element count and the pointee's field array, so pack them into the same
    ; 16-byte info struct struct-array fields use: [count, field_array_ptr].
    ; The field type keeps ARRAY_TYPE_FLAG + PTR_TYPE_FLAG + base, which the
    ; member-array codegen paths use to tell this case apart (a stripped
    ; element type >= PTR_TYPE_FLAG means "info struct", not a bare count).
    mov rax, r14
    sub rax, ARRAY_TYPE_FLAG
    cmp rax, PTR_TYPE_FLAG
    jb .ns_plain_array_info
    push r8                          ; save field_array_ptr
    push rcx                         ; save field size (heap_alloc_zero clobbers rcx)
    push r9                          ; save element count
    mov rdi, 16
    call heap_alloc_zero
    mov rdx, rax                     ; rdx = info struct ptr
    pop r9
    pop rcx
    pop r8
    mov [rdx], r9                    ; info[0] = element count
    mov [rdx + 8], r8                ; info[8] = pointee field_array_ptr
    mov r8, rdx                      ; r8 = info struct ptr (as sub_array_ptr)
    jmp .ns_field_semi
.ns_plain_array_info:
    ; Scalar (int/char) array fields: sub_array_ptr = element count directly
    mov r8, r9                       ; sub_array_ptr = element count

.ns_field_semi:
    mov rdi, TOK_SEMI
    mov rsi, msg_expect_semi
    call expect
    ; Store field descriptor with sub_array_ptr
    cmp r12, 32
    jae .field_loop
    imul rdi, r12, 32
    add rdi, 8
    add rdi, r15
    mov [rdi], rbx                   ; name_ptr
    mov [rdi + 8], r13               ; offset
    mov [rdi + 16], r14              ; type (with ARRAY_TYPE_FLAG if array)
    mov [rdi + 24], r8               ; sub_array_ptr (element count or info struct ptr)
    cmp qword [parser_field_const], 0
    je .ns_no_const_flag
    or qword [rdi + 16], FIELD_CONST_FLAG
.ns_no_const_flag:
    ; If this field forward-references a not-yet-defined struct, record the
    ; address of its sub_array_ptr slot so we can patch it when that struct is
    ; defined (fwd_ref_patch at definition time). rdi = field descriptor.
    cmp qword [parser_fwd_index], 0
    jl .ns_no_fwd
    push rdi
    lea rsi, [rdi + 24]              ; &field_descriptor.sub_array_ptr
    mov rdi, [parser_fwd_index]      ; registry index of the placeholder
    call fwd_ref_record
    pop rdi
    mov qword [parser_fwd_index], -1
.ns_no_fwd:
    inc r12
    add r13, rcx                     ; total_size += field size
    jmp .field_loop

.fs_anonymous:
    ; No tag name after struct — must be { body }

.fs_body:
    ; Save outer loop state
    push r12                         ; outer field count
    push r13                         ; outer offset
    push r15                         ; outer field array base
    push qword [parser_field_const]  ; save outer const flag

    ; Parse inner struct body: { fields... }
    mov rdi, TOK_LBRACE
    mov rsi, msg_expect_lbrace
    call expect

    ; Allocate inner field descriptor buffer (max 16 fields)
    mov rdi, 16 * 32 + 8
    call heap_alloc_zero
    mov r15, rax                     ; r15 = inner field array base
    mov qword [r15], 0               ; inner field count = 0
    xor r12, r12                     ; inner field count
    xor r13, r13                     ; inner offset
    push qword 1                     ; inner max_alignment

.inner_field_loop:
    mov rax, [parser_state.current_token]
    cmp rax, TOK_RBRACE
    je .inner_fields_done
    cmp rax, TOK_EOF
    je .inner_fields_done

    ; Reset const flag for this inner field
    mov qword [parser_field_const], 0

    ; Check for leading `const` qualifier
    mov rax, [parser_state.current_token]
    cmp rax, TOK_KW_CONST
    jne .inner_field_type
    mov qword [parser_field_const], 1
    call advance                     ; consume 'const'
.inner_field_type:

    mov rax, [parser_state.current_token]
    cmp rax, TOK_KW_INT
    je .inner_field_int
    cmp rax, TOK_KW_CHAR
    je .inner_field_char
    mov rsi, msg_expect_type
    call error
    call advance
    jmp .inner_field_loop

.inner_field_int:
    mov r14, TOK_KW_INT
    mov rcx, 8
    jmp .inner_field_common
.inner_field_char:
    mov r14, TOK_KW_CHAR
    mov rcx, 1
.inner_field_common:
    call advance
.inner_ptr_loop:
    mov rax, [parser_state.current_token]
    cmp rax, TOK_STAR
    jne .inner_have_type
    add r14, PTR_TYPE_FLAG
    mov rcx, 8
    call advance
    jmp .inner_ptr_loop
.inner_have_type:
    ; Trailing const after type/pointer inside nested anonymous structs
    mov rax, [parser_state.current_token]
    cmp rax, TOK_KW_CONST
    jne .inner_align_start
    mov qword [parser_field_const], 1
    call advance
.inner_align_start:
    cmp rcx, 1
    je .inner_align_done
    mov rax, r13
    add rax, 7
    and rax, -8
    mov r13, rax
    mov rax, [rsp]
    cmp rax, rcx
    jae .inner_align_done
    mov [rsp], rcx
.inner_align_done:
    mov rax, [parser_state.current_token]
    cmp rax, TOK_IDENT
    jne .inner_field_bad
    call copy_token_string
    mov rbx, rax
    call advance

    ; Check for array field: name[N]
    xor r8, r8                       ; r8 = element count (0 = not array)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_LBRACKET
    jne .inner_field_semi
    call advance                     ; consume '['
    mov rax, [parser_state.current_token]
    cmp rax, TOK_NUMBER
    jne .inner_field_bad
    call parse_number_value              ; rax = element count
    mov r8, rax                          ; r8 = element count
    call advance                         ; consume number
    mov rdi, TOK_RBRACKET
    mov rsi, msg_expect_rbracket
    call expect                      ; expect ']'
    add r14, ARRAY_TYPE_FLAG
    mov rax, r8
    imul rcx, rax                    ; rcx = count * element_size

.inner_field_semi:
    mov rdi, TOK_SEMI
    mov rsi, msg_expect_semi
    call expect
    cmp r12, 16
    jae .inner_field_loop
    imul rdi, r12, 32
    add rdi, 8
    add rdi, r15
    mov [rdi], rbx
    mov [rdi + 8], r13
    mov [rdi + 16], r14
    mov [rdi + 24], r8               ; sub_array_ptr (0 for simple, count for array)
    cmp qword [parser_field_const], 0
    je .inner_no_const_flag
    or qword [rdi + 16], FIELD_CONST_FLAG
.inner_no_const_flag:
    inc r12
    add r13, rcx
    jmp .inner_field_loop

.inner_field_bad:
    mov rsi, msg_expect_ident
    call error
    call advance
    jmp .inner_field_loop

.inner_fields_done:
    mov [r15], r12
    pop rbx                          ; inner max_alignment
    cmp rbx, 1
    je .inner_tail_done
    dec rbx
    mov rax, r13
    add rax, rbx
    not rbx
    and rax, rbx
    mov r13, rax
.inner_tail_done:
    ; Expect '}'
    mov rdi, TOK_RBRACE
    mov rsi, msg_expect_rbrace
    call expect

    ; r13 = inner total_size, r15 = inner field array ptr
    mov rcx, r13                     ; rcx = field size (inner total_size)
    mov r14, TOK_KW_STRUCT           ; r14 = field type
    mov r8, r15                      ; r8 = sub_array_ptr

    ; Restore outer const flag (was saved before inner max_alignment push)
    pop qword [parser_field_const]
    ; Restore outer loop state
    pop r15                          ; outer field array base
    pop r13                          ; outer offset
    pop r12                          ; outer field count

    ; Align outer offset to 8 bytes (struct contains int/ptr fields)
    mov rax, r13
    add rax, 7
    and rax, -8
    mov r13, rax
    mov rax, [rsp]
    cmp rax, 8
    jae .fs_outer_align_done
    mov qword [rsp], 8
.fs_outer_align_done:

    ; Expect field name
    mov rax, [parser_state.current_token]
    cmp rax, TOK_IDENT
    jne .field_bad
    call copy_token_string
    mov rbx, rax
    call advance
    mov rdi, TOK_SEMI
    mov rsi, msg_expect_semi
    call expect
    cmp r12, 32
    jae .field_loop
    imul rdi, r12, 32
    add rdi, 8
    add rdi, r15
    mov [rdi], rbx
    mov [rdi + 8], r13
    mov [rdi + 16], r14
    mov [rdi + 24], r8
    cmp qword [parser_field_const], 0
    je .fs_body_no_const_flag
    or qword [rdi + 16], FIELD_CONST_FLAG
.fs_body_no_const_flag:
    inc r12
    add r13, rcx
    jmp .field_loop

.field_bad:
    mov rsi, msg_expect_ident
    call error
    call advance
    jmp .field_loop

.fields_done:
    ; Update field count in header
    mov [r15], r12

    ; Add tail padding: align total size to max_alignment
    pop rbx                              ; rbx = max_alignment
    cmp rbx, 1
    je .tail_pad_done
    dec rbx                              ; rbx = max_align - 1
    mov rax, r13
    add rax, rbx
    not rbx
    and rax, rbx
    mov r13, rax
.tail_pad_done:

    ; Expect '}'
    mov rdi, TOK_RBRACE
    mov rsi, msg_expect_rbrace
    call expect

    ; Pop tag name (pushed at .have_body). max_alignment was already popped
    ; at .fields_done.
    pop r14                              ; r14 = tag name (0 = anonymous)

    test r14, r14
    jz .after_tag                        ; skip registration if anonymous

    ; Check if we pre-registered this struct (for self-reference support).
    ; struct_pre_reg_index = -1 means not pre-registered.
    mov rax, [struct_pre_reg_index]
    cmp rax, 0
    jge .update_entry                    ; pre-registered → update in place

    ; Not pre-registered. A forward-reference placeholder may already exist for
    ; this tag (created when a pointer field referenced it before definition).
    ; If so, reuse that slot; otherwise register a new entry.
    push r15                             ; save field array ptr
    mov rdi, r14                         ; rdi = tag name
    call find_named_struct_index
    pop r15
    cmp rax, 0
    jge .have_index

    ; Register new entry, returning its index in rax.
    mov rdi, r14                         ; tag name
    mov rsi, r13                         ; total size
    mov rdx, r15                         ; field array ptr
    call register_named_struct
    cmp rax, 0
    jl .after_tag                        ; registry full → nothing to patch
    jmp .patch_index

.update_entry:
    ; Update the pre-registered entry's size and field array pointer.
    mov rbx, rax
    shl rbx, 3
    mov [named_struct_sizes + rbx], r13
    mov [named_struct_fields + rbx], r15
.have_index:
    ; rax = index of the (placeholder) entry; fill in real size + fields.
    mov rbx, rax
    shl rbx, 3
    mov [named_struct_sizes + rbx], r13
    mov [named_struct_fields + rbx], r15
.patch_index:
    ; rax = registry index. Patch every forward-referencing field descriptor
    ; to point at this struct's real field array.
    mov rdi, rax
    mov rsi, r15
    call fwd_ref_patch

.after_tag:
    ; If this was `const struct Name { ... }`, mark every field const so
    ; later instances reject field assignment even without `const` on the var.
    cmp qword [parser_saved_const], 0
    je .after_tag_no_type_const
    test r15, r15
    jz .after_tag_no_type_const
    mov rcx, [r15]                       ; rcx = field count
    xor rdx, rdx                         ; rdx = field index
.after_tag_const_loop:
    cmp rdx, rcx
    jge .after_tag_no_type_const
    imul rax, rdx, 32
    lea rax, [r15 + 8 + rax]             ; rax = field descriptor
    or qword [rax + 16], FIELD_CONST_FLAG
    inc rdx
    jmp .after_tag_const_loop
.after_tag_no_type_const:

    ; Expect variable name (identifier)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_IDENT
    jne .no_var_name

    call copy_token_string
    mov rbx, rax                     ; rbx = var name
    call advance

    ; Check for '='
    mov rax, [parser_state.current_token]
    cmp rax, TOK_EQ
    je .inline_struct_init

    ; Expect ';'
    mov rdi, TOK_SEMI
    mov rsi, msg_expect_semi
    call expect

    ; Create AST_STRUCT_DEF node (no init)
    mov rdi, AST_STRUCT_DEF
    call alloc_node
    test rax, rax
    jz .sd_done
    mov [rax + ast_node_t.data1], r13    ; total_size
    mov [rax + ast_node_t.data2], r15    ; field array ptr
    mov [rax + ast_node_t.data3], rbx    ; var name ptr
    mov qword [rax + ast_node_t.data4], 0
    mov r8, [parser_saved_const]
    mov [rax + ast_node_t.data5], r8     ; const flag
    jmp .sd_done

.inline_struct_init:
    call advance                     ; consume '='
    push r15                         ; save field_array_ptr
    mov rdi, r15                     ; rdi = field_array_ptr
    call parse_init_list
    pop r15                          ; restore field_array_ptr
    mov r14, rax                     ; r14 = init list node
    ; Expect ';'
    mov rdi, TOK_SEMI
    mov rsi, msg_expect_semi
    call expect
    ; Create AST_STRUCT_DEF node with init
    mov rdi, AST_STRUCT_DEF
    call alloc_node
    test rax, rax
    jz .sd_done
    mov [rax + ast_node_t.data1], r13    ; total_size
    mov [rax + ast_node_t.data2], r15    ; field array ptr
    mov [rax + ast_node_t.data3], rbx    ; var name ptr
    mov [rax + ast_node_t.data4], r14    ; init list ptr
    mov r8, [parser_saved_const]
    mov [rax + ast_node_t.data5], r8     ; const flag

.sd_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.no_var_name:
    ; Check if named struct type-only definition
    test r14, r14
    jnz .named_type_only
    ; Anonymous struct without variable: error
    mov rsi, msg_expect_ident
    call error
    xor rax, rax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.named_type_only:
    ; Consume ';' and return null (no variable, just type registration)
    mov rdi, TOK_SEMI
    mov rsi, msg_expect_semi
    call expect
    xor rax, rax
    jmp .sd_done

; ================================================================
; parse_init_list(rdi = field_array_ptr) -> AST_INIT_LIST*
; Parses { init_expr1, init_expr2, ... } for struct initialization.
; For struct-typed fields, recursively parses nested { ... }.
; ================================================================
parse_init_list:
    push r12
    push r13
    push r14
    push r15
    ; Allocate local stack slots for field_array_ptr and field_count
    sub rsp, 16

    mov [rsp], rdi                       ; save field_array_ptr to local slot 1
    mov r12, [rdi]                       ; r12 = field count
    mov [rsp + 8], r12                   ; save field_count to local slot 2

    ; Expect '{'
    mov rdi, TOK_LBRACE
    mov rsi, msg_expect_lbrace
    call expect

    ; Check for empty init list: { }
    mov rax, [parser_state.current_token]
    cmp rax, TOK_RBRACE
    je .pil_empty

    ; Allocate init value array: (field_count * INIT_SLOT_MULT) * 8 bytes (zeroed)
    ; INIT_SLOT_MULT allows for designated initializers that target the same
    ; field multiple times or nested struct fields.
    mov rax, r12
    test rax, rax
    jz .pil_empty                        ; no fields → just close
    shl rax, 3
    shl rax, 3                          ; multiply by 8 for extra slots
    mov rdi, rax
    call heap_alloc_zero
    mov r14, rax                         ; r14 = init array ptr
    xor r15, r15                         ; r15 = index (0)

.pil_loop:
    ; Check for closing brace first
    mov rax, [parser_state.current_token]
    cmp rax, TOK_RBRACE
    je .pil_close

    ; Check for designated initializer (.field = value)
    cmp rax, TOK_DOT
    je .pil_designated

    ; Get field descriptor for current field
    imul rdi, r15, 32
    mov rax, [rsp]                       ; rax = field_array_ptr
    lea rdi, [rax + 8 + rdi]             ; rdi = field descriptor
    mov rax, [rdi + 16]                  ; rax = field type

    cmp rax, TOK_KW_STRUCT
    je .pil_struct_field

    ; Simple type (int/char) — parse expression
    call parse_expression
    mov [r14 + r15 * 8], rax             ; store init expression
    jmp .pil_next

.pil_designated:
    ; Designated initializer: .field[.subfield...] = value
    ; Parse the designator path and compute the final byte offset
    ; field_array_ptr is at [rsp], field_count at [rsp+8]
    push qword [rsp]                     ; push field_array_ptr
    push qword [rsp + 16]                ; push field_count (after first push, offset is +16)
    push r14
    push r15
    call parse_designated_init
    pop r15
    pop r14
    add rsp, 16                          ; pop field_count and field_array_ptr
    ; Store the designated init node in the init array at current index
    mov [r14 + r15 * 8], rax
    jmp .pil_next

.pil_struct_field:
    ; Struct field — parse nested init list
    push qword [rsp]                     ; push field_array_ptr
    push qword [rsp + 16]                ; push field_count
    push r14
    push r15
    mov rdi, [rdi + 24]                  ; rdi = sub_array_ptr
    call parse_init_list
    pop r15
    pop r14
    add rsp, 16                          ; pop field_count and field_array_ptr
    mov [r14 + r15 * 8], rax             ; store nested init list
    jmp .pil_next

.pil_next:
    inc r15

    ; Check for ',' before next field
    mov rax, [parser_state.current_token]
    cmp rax, TOK_COMMA
    jne .pil_close                       ; if no comma, we're done
    call advance                         ; consume ','
    jmp .pil_loop

.pil_close:
    ; Expect '}'
    mov rdi, TOK_RBRACE
    mov rsi, msg_expect_rbrace
    call expect
    jmp .pil_create

.pil_empty:
    mov rdi, TOK_RBRACE
    mov rsi, msg_expect_rbrace
    call expect
    xor r14, r14                         ; null init array

.pil_create:
    mov rdi, AST_INIT_LIST
    call alloc_node
    test rax, rax
    jz .pil_done
    mov [rax + ast_node_t.data1], r15    ; count (actual init count, may exceed field count for designated)
    mov [rax + ast_node_t.data2], r14    ; init array (0 if none)

.pil_done:
    add rsp, 16                          ; pop local slots
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; ================================================================
; parse_designated_init() -> AST_DESIGNATED_INIT*
; Parses .field[.subfield...] = value for designated initializers.
; Computes the final byte offset within the struct and stores it in data1.
; data2 = value expression (or nested init list for struct fields).
; r12 = field_array_ptr (outer struct's field array)
; r13 = field count (outer struct's field count)
; ================================================================
parse_designated_init:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12, [rsp + 72]                 ; r12 = field_array_ptr (outer) [caller's push]
    mov r13, [rsp + 64]                 ; r13 = field count (outer) [caller's push]
    xor r14, r14                         ; r14 = accumulated byte offset
    mov r15, r12                         ; r15 = current field_array_ptr

.pdi_loop:
    ; Expect '.'
    push r12
    push r15
    mov rdi, TOK_DOT
    mov rsi, msg_expect_dot
    call expect
    pop r15
    pop r12

    ; Expect field name (identifier)
    push r12
    push r15
    mov rax, [parser_state.current_token]
    cmp rax, TOK_IDENT
    jne .pdi_expected_ident_pop

    ; Get field name
    call copy_token_string
    mov rbx, rax                         ; rbx = field name
    call advance                         ; consume identifier
    pop r15
    pop r12

    ; Find field in current field array
    push r12
    push r14
    push rbx
    mov rdi, r15
    mov rsi, rbx
    call find_field_desc
    pop rbx
    pop r14
    pop r12
    test rax, rax
    jz .pdi_field_not_found

    ; rax = field descriptor ptr
    ; field descriptor layout: [0..7]=name_ptr, [8..15]=offset, [16..23]=type, [24..31]=sub_array_ptr
    mov rcx, [rax + 8]                   ; rcx = field offset
    add r14, rcx                         ; accumulate offset
    mov rdx, [rax + 16]                  ; rdx = field type
    mov r15, [rax + 24]                  ; r15 = sub_array_ptr (for nested struct lookup)

    ; Check if there's another '.field' (nested) or '=' (end of designator)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_DOT
    je .pdi_loop                         ; nested designator

    ; Expect '='
    push r12
    push r14
    push r15
    mov rdi, TOK_EQ
    mov rsi, msg_expect_eq
    call expect
    pop r15
    pop r14
    pop r12

    ; Parse value expression
    push r14
    call parse_expression
    pop r14

    ; Create AST_DESIGNATED_INIT node
    push rax                             ; save value expr
    mov rdi, AST_DESIGNATED_INIT
    call alloc_node
    pop rcx                              ; rcx = value expr
    test rax, rax
    jz .pdi_done
    mov [rax + ast_node_t.data1], r14    ; byte offset
    mov [rax + ast_node_t.data2], rcx    ; value expression

.pdi_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.pdi_expected_ident_pop:
    pop r15
    pop r12
.pdi_expected_ident:
    mov rsi, msg_expect_ident
    call error
    xor rax, rax
    jmp .pdi_done

.pdi_field_not_found:
    mov rsi, msg_syntax
    call error
    xor rax, rax
    jmp .pdi_done

; ================================================================
; find_field_desc(rdi=field_array_ptr, rsi=field_name_ptr) -> field_desc_ptr
; Returns pointer to the field descriptor (32 bytes) if found, else 0.
; Field descriptor layout: [0..7]=name_ptr, [8..15]=offset, [16..23]=type, [24..31]=sub_array_ptr
; ================================================================
find_field_desc:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12, rdi                         ; r12 = field array base
    mov r13, rsi                         ; r13 = field name to find
    mov r14, [r12]                       ; r14 = field count

    ; Get target field name length
    mov rsi, r13
    call strlen
    mov r15, rax                         ; r15 = target name length

    xor rbx, rbx                         ; rbx = index
.ffd_loop:
    cmp rbx, r14
    jge .ffd_not_found

    ; Field descriptor address = base + 8 + index * 32
    imul rdi, rbx, 32
    lea rdi, [r12 + 8 + rdi]             ; rdi = field descriptor
    push rdi
    mov rsi, [rdi]                       ; field name_ptr
    call strlen
    cmp rax, r15
    pop rdi
    jne .ffd_next

    ; Compare names
    push rdi                             ; save field desc ptr
    mov rdi, [rdi]                       ; rdi = field name_ptr
    mov rsi, r13                         ; rsi = target field name
    mov rdx, r15                         ; length
    call mem_eq
    pop rdi                              ; restore field desc ptr
    test rax, rax
    jnz .ffd_next                        ; not equal

    ; Found!
    mov rax, rdi                         ; return field descriptor ptr
    jmp .ffd_done

.ffd_next:
    inc rbx
    jmp .ffd_loop

.ffd_not_found:
    xor rax, rax
.ffd_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ================================================================
; parse_array_init_list() -> AST_INIT_LIST*
; Parses { expr1, expr2, ... } for array initialization.
; Also supports string literal: "abc" is equivalent to {'a','b','c','\0'}
; Returns AST_INIT_LIST with data1=count, data2=array of expr ptrs.
; ================================================================
parse_array_init_list:
    push r12
    push r13
    push r14
    push r15

    ; Check for string literal at start (e.g., char arr[5] = "hello")
    mov rax, [parser_state.current_token]
    cmp rax, TOK_STRING
    jne .pail_brace
    jmp .pail_string_init

.pail_brace:
    ; Expect '{'
    mov rdi, TOK_LBRACE
    mov rsi, msg_expect_lbrace
    call expect

    ; Allocate array for up to 128 init expressions
    mov rdi, 128
    call alloc_ptr_array
    mov r14, rax                         ; r14 = init array
    xor r15, r15                         ; r15 = count

    ; Check for empty init list: { }
    mov rax, [parser_state.current_token]
    cmp rax, TOK_RBRACE
    je .pail_close

.pail_loop:
    cmp r15, 127
    jge .pail_skip_rest

    ; Parse expression
    call parse_expression
    mov [r14 + 8 + r15 * 8], rax         ; store expression
    inc r15

    ; Check for ',' or '}'
    mov rax, [parser_state.current_token]
    cmp rax, TOK_COMMA
    jne .pail_close
    call advance                           ; consume ','
    jmp .pail_loop

.pail_skip_rest:
    ; Too many initializers — skip remaining tokens until '}'
    mov rax, [parser_state.current_token]
    cmp rax, TOK_RBRACE
    je .pail_close
    cmp rax, TOK_EOF
    je .pail_close
    call advance
    jmp .pail_skip_rest

.pail_close:
    ; Expect '}'
    mov rdi, TOK_RBRACE
    mov rsi, msg_expect_rbrace
    call expect
    jmp .pail_create

; String literal init: "abc" -> {'a','b','c'}
; Current token is TOK_STRING
.pail_string_init:
    ; Copy the string and get its length
    call copy_token_string
    mov r12, rax                         ; r12 = string ptr
    mov r13, [parser_state.token_len]    ; r13 = string length
    call advance                         ; consume string token

    ; Allocate init array (128 slots max)
    mov rdi, 128
    call alloc_ptr_array
    mov r14, rax                         ; r14 = init array

    ; Create char expressions for each byte (up to 127)
    xor r15, r15                         ; r15 = count
    xor rcx, rcx                         ; rcx = index into string
.pail_string_loop:
    cmp r15, 127
    jge .pail_string_done
    cmp rcx, r13
    jge .pail_string_done

    ; Get the byte value
    movzx rbx, byte [r12 + rcx]

    ; Create AST_CHAR node
    push rcx
    push r12
    push r13
    push r15
    mov rdi, AST_CHAR
    call alloc_node
    pop r15
    pop r13
    pop r12
    pop rcx
    test rax, rax
    jz .pail_string_skip
    mov [rax + ast_node_t.data1], rbx
    mov [r14 + 8 + r15 * 8], rax         ; store char expression
    inc r15
.pail_string_skip:
    inc rcx
    jmp .pail_string_loop
.pail_string_done:
    jmp .pail_create

.pail_create:
    ; Store count in array header
    mov [r14], r15

    ; Create AST_INIT_LIST node
    mov rdi, AST_INIT_LIST
    call alloc_node
    test rax, rax
    jz .pail_done
    mov [rax + ast_node_t.data1], r15    ; count
    mov [rax + ast_node_t.data2], r14    ; init array

.pail_done:
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; ================================================================
; parse_if_stmt() -> AST_IF*
; if (expression) block (else block)?
; ================================================================
; Parse a compound statement: { block } or a single statement
; Returns: AST_BLOCK* (may wrap a single statement)
parse_compound_stmt:
    push rbx
    push r12
    push r13

    ; Require '{' — C2X enforces braces on all if/while/for bodies.
    ; parse_block already expects '{' first, so just delegate.
    call parse_block

    pop r13
    pop r12
    pop rbx
    ret

parse_if_stmt:
    push rbx
    push r12
    push r13

    call advance               ; consume 'if'

    ; Expect '('
    mov rdi, TOK_LPAREN
    mov rsi, msg_expect_lparen
    call expect

    ; Parse condition
    call parse_expression
    mov rbx, rax               ; rbx = condition

    ; Expect ')'
    mov rdi, TOK_RPAREN
    mov rsi, msg_expect_rparen
    call expect

    ; Parse then block (or single statement)
    call parse_compound_stmt
    mov r12, rax               ; r12 = then_block

    ; Check for 'else'
    xor r13, r13               ; r13 = else_block (0 if none)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_KW_ELSE
    jne .no_else

    call advance               ; consume 'else'

    ; Handle `else if` by recursively parsing the if-statement as the else block.
    ; `else if (b) { ... }` is equivalent to `else { if (b) { ... } }`.
    mov rax, [parser_state.current_token]
    cmp rax, TOK_KW_IF
    jne .else_compound
    ; Recursively parse `if (...)` as the else body
    call parse_if_stmt
    mov r13, rax               ; r13 = else_block (AST_IF*)
    jmp .wrap_else_if

.else_compound:
    call parse_compound_stmt
    mov r13, rax               ; r13 = else_block
    jmp .no_else

.wrap_else_if:
    ; Wrap the AST_IF in an AST_BLOCK so the outer AST_IF node has a uniform
    ; shape: else_block is always AST_BLOCK* containing statements.
    ; NOTE: rbx currently holds the condition node — must preserve it.
    ; Allocate a 1-element statement array and store the nested AST_IF in it.
    push rbx
    push r13
    mov rdi, 1
    call alloc_ptr_array
    pop r13
    test rax, rax
    jz .wrap_else_if_pop
    mov [rax + 8], r13         ; array[1] = the nested AST_IF
    mov rbx, rax               ; rbx = statement array (safe — saved above)
    mov rdi, AST_BLOCK
    call alloc_node
    test rax, rax
    jz .wrap_else_if_pop
    mov qword [rax + ast_node_t.data1], 1   ; stmt count = 1
    mov [rax + ast_node_t.data2], rbx       ; stmt array
    mov r13, rax                            ; r13 = wrapped else_block
.wrap_else_if_pop:
    pop rbx                    ; restore condition node

.no_else:
    ; Create AST_IF node
    mov rdi, AST_IF
    call alloc_node
    test rax, rax
    jz .done
    mov [rax + ast_node_t.data1], rbx    ; condition
    mov [rax + ast_node_t.data2], r12    ; then_block
    mov [rax + ast_node_t.data3], r13    ; else_block

.done:
    pop r13
    pop r12
    pop rbx
    ret

; ================================================================
; parse_while_stmt() -> AST_WHILE*
; while (expression) block
; ================================================================
parse_while_stmt:
    push rbx
    push r12

    call advance               ; consume 'while'

    ; Expect '('
    mov rdi, TOK_LPAREN
    mov rsi, msg_expect_lparen
    call expect

    ; Parse condition
    call parse_expression
    mov rbx, rax               ; rbx = condition

    ; Expect ')'
    mov rdi, TOK_RPAREN
    mov rsi, msg_expect_rparen
    call expect

    ; Parse body (block or single statement)
    call parse_compound_stmt
    mov r12, rax               ; r12 = body

    ; Create AST_WHILE node
    mov rdi, AST_WHILE
    call alloc_node
    test rax, rax
    jz .done
    mov [rax + ast_node_t.data1], rbx    ; condition
    mov [rax + ast_node_t.data2], r12    ; body

.done:
    pop r12
    pop rbx
    ret

; ================================================================
; parse_for_stmt() -> AST_FOR*  (for loop)
; for (init; cond; incr) body
; Produces: AST_FOR(init, cond, incr, body)
; AST_FOR layout: data1=init, data2=cond, data3=incr, data4=body
; ================================================================
parse_for_stmt:
    push rbx
    push r12
    push r13
    push r14
    push r15

    call advance               ; consume 'for'

    ; Expect '('
    mov rdi, TOK_LPAREN
    mov rsi, msg_expect_lparen
    call expect

    ; --- Parse init (optional, ends at ';') ---
    xor r12, r12               ; r12 = init statement (0 if empty)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_SEMI
    je .for_init_skip_semi     ; empty init — consume the ';' below

    ; Check for type keyword (var decl)
    cmp rax, TOK_KW_INT
    je .for_init_var
    cmp rax, TOK_KW_CHAR
    je .for_init_var
    cmp rax, TOK_KW_CONST
    je .for_init_var
    ; Expression — must handle assignment (parse_expression stops at '=')
    call parse_expression
    mov r12, rax               ; r12 = LHS expression

    ; Check for '=' (assignment)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_EQ
    je .for_init_plain_assign
    cmp rax, TOK_ADDEQ
    jb .for_init_done          ; not an assignment
    cmp rax, TOK_XOREQ
    ja .for_init_done
    ; Compound assignment — desugar to a = a OP b
    push r13
    push r14
    push r15
    push r12                   ; save LHS
    push rax                   ; save compound token
    call advance               ; consume compound token
    call parse_expression      ; RHS
    mov r15, rax               ; r15 = RHS
    pop r8                     ; r8 = compound token
    pop r12                    ; r12 = LHS
    ; Map compound token to binary op
    mov r14, TOK_PLUS
    cmp r8, TOK_ADDEQ
    je .for_ca_doit
    mov r14, TOK_MINUS
    cmp r8, TOK_SUBEQ
    je .for_ca_doit
    mov r14, TOK_STAR
    cmp r8, TOK_MULEQ
    je .for_ca_doit
    mov r14, TOK_SLASH
    cmp r8, TOK_DIVEQ
    je .for_ca_doit
    mov r14, TOK_PERCENT
    cmp r8, TOK_MODEQ
    je .for_ca_doit
    mov r14, TOK_LSHIFT
    cmp r8, TOK_LSHIFT_EQ
    je .for_ca_doit
    mov r14, TOK_RSHIFT
    cmp r8, TOK_RSHIFT_EQ
    je .for_ca_doit
    mov r14, TOK_AMPERSAND
    cmp r8, TOK_ANDEQ
    je .for_ca_doit
    mov r14, TOK_PIPE
    cmp r8, TOK_OREQ
    je .for_ca_doit
    mov r14, TOK_XOR
.for_ca_doit:
    ; Clone LHS
    push r12
    mov rdi, AST_IDENT
    call alloc_node
    pop r12
    test rax, rax
    jz .for_ca_fail
    mov r13, rax               ; r13 = clone
    mov rdi, [r12 + ast_node_t.data1]
    mov [r13 + ast_node_t.data1], rdi
    ; Binary op
    mov rdi, AST_BINARY_OP
    call alloc_node
    test rax, rax
    jz .for_ca_fail
    mov [rax + ast_node_t.data1], r14
    mov [rax + ast_node_t.data2], r13
    mov [rax + ast_node_t.data3], r15
    ; Assign
    mov r15, rax
    mov rdi, AST_ASSIGN
    call alloc_node
    test rax, rax
    jz .for_ca_fail
    mov [rax + ast_node_t.data1], r12
    mov [rax + ast_node_t.data2], r15
    mov r12, rax
    pop r15
    pop r14
    pop r13
    jmp .for_init_done

.for_ca_fail:
    pop r15
    pop r14
    pop r13
    xor r12, r12
    jmp .for_init_done

.for_init_plain_assign:
    call advance               ; consume '='
    call parse_expression
    mov rbx, rax               ; rbx = RHS
    push rbx
    mov rdi, AST_ASSIGN
    call alloc_node
    pop rbx
    test rax, rax
    jz .for_init_done
    mov [rax + ast_node_t.data1], r12    ; LHS
    mov [rax + ast_node_t.data2], rbx    ; RHS
    mov r12, rax               ; r12 = assign node
    jmp .for_init_done

.for_init_var:
    call parse_var_decl         ; parse_var_decl already consumes ';'
    mov r12, rax               ; r12 = var decl AST
    jmp .for_init_skip_semi    ; ';' already consumed by parse_var_decl

.for_init_done:
    ; Expect ';'
    mov rdi, TOK_SEMI
    mov rsi, msg_expect_semi
    call expect

.for_init_skip_semi:
    ; Init was empty or a var decl (already consumed ';')
    ; Check current token — if it's ';', consume it (empty init case)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_SEMI
    jne .for_cond_parse
    call advance               ; consume ';'

.for_cond_parse:
    ; --- Parse condition (optional, ends at ';') ---
    xor r13, r13               ; r13 = condition (0 = always true)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_SEMI
    je .for_cond_done

    call parse_expression
    mov r13, rax               ; r13 = condition
    jmp .for_cond_done

.for_cond_done:
    ; Expect ';'
    mov rdi, TOK_SEMI
    mov rsi, msg_expect_semi
    call expect

    ; --- Parse increment (optional, ends at ')') ---
    xor r14, r14               ; r14 = incr statement (0 if empty)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_RPAREN
    je .for_incr_done

    ; Parse increment — handle assignment (parse_expression stops at '=')
    call parse_expression
    mov r14, rax               ; r14 = LHS

    ; Check for '=' (assignment)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_EQ
    je .for_incr_plain_assign
    cmp rax, TOK_ADDEQ
    jb .for_incr_done
    cmp rax, TOK_XOREQ
    ja .for_incr_done
    ; Compound assignment
    push r13
    push r15
    push r14
    push rax
    call advance
    call parse_expression
    mov r15, rax
    pop r8
    pop r14
    mov r13, TOK_PLUS
    cmp r8, TOK_ADDEQ
    je .for_ica_doit
    mov r13, TOK_MINUS
    cmp r8, TOK_SUBEQ
    je .for_ica_doit
    mov r13, TOK_STAR
    cmp r8, TOK_MULEQ
    je .for_ica_doit
    mov r13, TOK_SLASH
    cmp r8, TOK_DIVEQ
    je .for_ica_doit
    mov r13, TOK_PERCENT
    cmp r8, TOK_MODEQ
    je .for_ica_doit
    mov r13, TOK_LSHIFT
    cmp r8, TOK_LSHIFT_EQ
    je .for_ica_doit
    mov r13, TOK_RSHIFT
    cmp r8, TOK_RSHIFT_EQ
    je .for_ica_doit
    mov r13, TOK_AMPERSAND
    cmp r8, TOK_ANDEQ
    je .for_ica_doit
    mov r13, TOK_PIPE
    cmp r8, TOK_OREQ
    je .for_ica_doit
    mov r13, TOK_XOR
.for_ica_doit:
    push r14
    mov rdi, AST_IDENT
    call alloc_node
    pop r14
    test rax, rax
    jz .for_ica_fail
    mov rbx, rax
    mov rdi, [r14 + ast_node_t.data1]
    mov [rbx + ast_node_t.data1], rdi
    push rbx
    mov rdi, AST_BINARY_OP
    call alloc_node
    pop rbx
    test rax, rax
    jz .for_ica_fail
    mov [rax + ast_node_t.data1], r13
    mov [rax + ast_node_t.data2], rbx
    mov [rax + ast_node_t.data3], r15
    mov rbx, rax
    mov rdi, AST_ASSIGN
    call alloc_node
    test rax, rax
    jz .for_ica_fail
    mov [rax + ast_node_t.data1], r14
    mov [rax + ast_node_t.data2], rbx
    mov r14, rax
    pop r15
    pop r13
    jmp .for_incr_done

.for_ica_fail:
    pop r15
    pop r13
    xor r14, r14
    jmp .for_incr_done

.for_incr_plain_assign:
    call advance
    call parse_expression
    mov rbx, rax
    push rbx
    mov rdi, AST_ASSIGN
    call alloc_node
    pop rbx
    test rax, rax
    jz .for_incr_done
    mov [rax + ast_node_t.data1], r14
    mov [rax + ast_node_t.data2], rbx
    mov r14, rax

.for_incr_done:
    ; Expect ')'
    mov rdi, TOK_RPAREN
    mov rsi, msg_expect_rparen
    call expect

    ; --- Parse body ---
    call parse_compound_stmt
    mov r15, rax               ; r15 = body block

    ; --- Build AST_FOR ---
    ; If no condition, use AST_NUMBER(1)
    test r13, r13
    jnz .for_build
    mov rdi, AST_NUMBER
    call alloc_node
    test rax, rax
    jz .for_done
    mov qword [rax + ast_node_t.data1], 1
    mov r13, rax

.for_build:
    ; Create AST_FOR(init, cond, incr, body)
    mov rdi, AST_FOR
    call alloc_node
    test rax, rax
    jz .for_done
    mov [rax + ast_node_t.data1], r12    ; init (0 if empty)
    mov [rax + ast_node_t.data2], r13    ; condition
    mov [rax + ast_node_t.data3], r14    ; incr (0 if empty)
    mov [rax + ast_node_t.data4], r15    ; body

.for_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
; ================================================================
; parse_break_stmt() -> AST_BREAK*
; break;
; ================================================================
parse_break_stmt:
    push rbx

    call advance               ; consume 'break'

    ; Expect ';'
    mov rdi, TOK_SEMI
    mov rsi, msg_expect_semi
    call expect

    ; Create AST_BREAK node
    mov rdi, AST_BREAK
    call alloc_node

    pop rbx
    ret

; ================================================================
; parse_continue_stmt() -> AST_CONTINUE*
; continue;
; ================================================================
parse_continue_stmt:
    push rbx

    call advance               ; consume 'continue'

    ; Expect ';'
    mov rdi, TOK_SEMI
    mov rsi, msg_expect_semi
    call expect

    ; Create AST_CONTINUE node
    mov rdi, AST_CONTINUE
    call alloc_node

    pop rbx
    ret

; ================================================================
; parse_return_stmt() -> AST_RETURN*
parse_return_stmt:
    push rbx

    call advance               ; consume 'return'

    ; Check for optional expression
    xor rbx, rbx
    mov rax, [parser_state.current_token]
    cmp rax, TOK_SEMI
    je .no_expr

    call parse_expression
    mov rbx, rax

    ; Check for void function returning a value
    cmp qword [current_func_return_type], TOK_KW_VOID
    jne .no_expr
    mov rsi, msg_void_return_val
    call error
    xor rbx, rbx
    jmp .no_expr

.no_expr:
    ; Expect ';'
    mov rdi, TOK_SEMI
    mov rsi, msg_expect_semi
    call expect

    ; Create AST_RETURN node
    mov rdi, AST_RETURN
    call alloc_node
    test rax, rax
    jz .done
    mov [rax + ast_node_t.data1], rbx    ; expression

.done:
    pop rbx
    ret

; ================================================================
; Expression Parsing
; ================================================================

; parse_expression() -> AST node
; expression = logical_or
parse_expression:
    call parse_logical_or
    ret

; parse_logical_or() -> AST node
; logical_or = logical_and ("||" logical_and)*
parse_logical_or:
    push rbx
    push r12

    call parse_logical_and
    mov r12, rax               ; r12 = left

.lor_loop:
    mov rax, [parser_state.current_token]
    cmp rax, TOK_OR
    jne .lor_done
    mov rbx, rax               ; rbx = operator token
    call advance
    call parse_logical_and
    mov rdi, rax               ; rdi = right

    ; Create logical OR node
    push r12
    push rdi
    mov rdi, AST_LOGICAL_OR
    call alloc_node
    pop rdi
    pop r12
    test rax, rax
    jz .lor_done
    mov [rax + ast_node_t.data1], rbx    ; operator token (unused)
    mov [rax + ast_node_t.data2], r12    ; left
    mov [rax + ast_node_t.data3], rdi    ; right
    mov r12, rax
    jmp .lor_loop

.lor_done:
    mov rax, r12
    pop r12
    pop rbx
    ret

; parse_logical_and() -> AST node
; logical_and = equality ("&&" equality)*
parse_logical_and:
    push rbx
    push r12

    call parse_equality
    mov r12, rax               ; r12 = left

.land_loop:
    mov rax, [parser_state.current_token]
    cmp rax, TOK_AND
    jne .land_done
    mov rbx, rax               ; rbx = operator token
    call advance
    call parse_equality
    mov rdi, rax               ; rdi = right

    ; Create logical AND node
    push r12
    push rdi
    mov rdi, AST_LOGICAL_AND
    call alloc_node
    pop rdi
    pop r12
    test rax, rax
    jz .land_done
    mov [rax + ast_node_t.data1], rbx    ; operator token (unused)
    mov [rax + ast_node_t.data2], r12    ; left
    mov [rax + ast_node_t.data3], rdi    ; right
    mov r12, rax
    jmp .land_loop

.land_done:
    mov rax, r12
    pop r12
    pop rbx
    ret

; parse_equality() -> AST node
; equality = comparison (("==" | "!=") comparison)*
parse_equality:
    push rbx
    push r12

    call parse_comparison
    mov r12, rax               ; r12 = left

.eq_loop:
    mov rax, [parser_state.current_token]
    cmp rax, TOK_EQEQ
    je .have_op
    cmp rax, TOK_NEQ
    je .have_op
    mov rax, r12
    pop r12
    pop rbx
    ret

.have_op:
    mov rbx, rax               ; rbx = operator token
    call advance
    call parse_comparison
    mov rdi, rax               ; rdi = right

    ; Create binary op node
    push r12
    push rdi
    mov rdi, AST_BINARY_OP
    call alloc_node
    pop rdi
    pop r12
    test rax, rax
    jz .eq_done
    mov [rax + ast_node_t.data1], rbx    ; operator
    mov [rax + ast_node_t.data2], r12    ; left
    mov [rax + ast_node_t.data3], rdi    ; right
    mov r12, rax

.eq_done:
    jmp .eq_loop

; parse_comparison() -> AST node
; comparison = addition (("<" | "<=" | ">" | ">=") addition)*
parse_comparison:
    push rbx
    push r12

    call parse_addition
    mov r12, rax

.cmp_loop:
    mov rax, [parser_state.current_token]
    cmp rax, TOK_LT
    je .have_op
    cmp rax, TOK_LE
    je .have_op
    cmp rax, TOK_GT
    je .have_op
    cmp rax, TOK_GE
    je .have_op
    mov rax, r12
    pop r12
    pop rbx
    ret

.have_op:
    mov rbx, rax
    call advance
    call parse_addition
    mov rdi, rax

    push r12
    push rdi
    mov rdi, AST_BINARY_OP
    call alloc_node
    pop rdi
    pop r12
    test rax, rax
    jz .cmp_done
    mov [rax + ast_node_t.data1], rbx
    mov [rax + ast_node_t.data2], r12
    mov [rax + ast_node_t.data3], rdi
    mov r12, rax

.cmp_done:
    jmp .cmp_loop

; parse_addition() -> AST node
; addition = term (("+" | "-" | "<<" | ">>" | "&" | "|" | "^") term)*
parse_addition:
    push rbx
    push r12

    call parse_term
    mov r12, rax

.add_loop:
    mov rax, [parser_state.current_token]
    cmp rax, TOK_PLUS
    je .have_op
    cmp rax, TOK_MINUS
    je .have_op
    cmp rax, TOK_LSHIFT
    je .have_op
    cmp rax, TOK_RSHIFT
    je .have_op
    cmp rax, TOK_AMPERSAND
    je .have_op
    cmp rax, TOK_PIPE
    je .have_op
    cmp rax, TOK_XOR
    je .have_op
    mov rax, r12
    pop r12
    pop rbx
    ret

.have_op:
    mov rbx, rax
    call advance
    call parse_term
    mov rdi, rax

    push r12
    push rdi
    mov rdi, AST_BINARY_OP
    call alloc_node
    pop rdi
    pop r12
    test rax, rax
    jz .add_done
    mov [rax + ast_node_t.data1], rbx
    mov [rax + ast_node_t.data2], r12
    mov [rax + ast_node_t.data3], rdi
    mov r12, rax

.add_done:
    jmp .add_loop

; parse_term() -> AST node
; term = unary (("*" | "/" | "%") unary)*
parse_term:
    push rbx
    push r12

    call parse_unary
    mov r12, rax

.term_loop:
    mov rax, [parser_state.current_token]
    cmp rax, TOK_STAR
    je .have_op
    cmp rax, TOK_SLASH
    je .have_op
    cmp rax, TOK_PERCENT
    je .have_op
    mov rax, r12
    pop r12
    pop rbx
    ret

.have_op:
    mov rbx, rax
    call advance
    call parse_unary
    mov rdi, rax

    push r12
    push rdi
    mov rdi, AST_BINARY_OP
    call alloc_node
    pop rdi
    pop r12
    test rax, rax
    jz .term_done
    mov [rax + ast_node_t.data1], rbx
    mov [rax + ast_node_t.data2], r12
    mov [rax + ast_node_t.data3], rdi
    mov r12, rax

.term_done:
    jmp .term_loop

; parse_unary() -> AST node
; unary = ("-" | "!") unary | primary
parse_unary:
    push rbx
    push r12

    mov rax, [parser_state.current_token]
    cmp rax, TOK_MINUS
    je .unary_minus
    cmp rax, TOK_STAR          ; dereference
    je .unary_star
    cmp rax, TOK_AMPERSAND     ; address-of
    je .unary_amp
    cmp rax, TOK_NOT           ; logical not
    je .unary_not
    cmp rax, TOK_TILDE         ; bitwise not
    je .unary_tilde
    cmp rax, TOK_INCR          ; prefix ++
    je .unary_incr
    cmp rax, TOK_DECR          ; prefix --
    je .unary_decr

    ; Not a unary op - parse primary
    call parse_primary
    ; Postfix: check for '.' and '->' (member access on any expression)
    push rax                          ; save primary expr
    mov rax, [parser_state.current_token]
    cmp rax, TOK_DOT
    je .postfix_dot_or_arrow
    cmp rax, TOK_ARROW
    je .postfix_dot_or_arrow
    cmp rax, TOK_INCR
    je .postfix_incr
    cmp rax, TOK_DECR
    je .postfix_decr
    cmp rax, TOK_LBRACKET
    je .postfix_index
    jmp .no_postfix_dot

.postfix_dot_or_arrow:
    pop rcx                           ; rcx = base expression
    cmp rax, TOK_ARROW
    jne .member_postfix_loop          ; dot: go to loop directly
    ; Arrow: wrap base in deref first: (*base).field
    push rcx
    mov rdi, AST_UNARY_OP
    call alloc_node
    pop rcx
    test rax, rax
    jz .member_postfix_fail
    mov rdi, TOK_STAR
    mov [rax + ast_node_t.data1], rdi
    mov [rax + ast_node_t.data2], rcx
    mov rcx, rax                      ; rcx = *base

.member_postfix_loop:
    ; rcx holds the base expression for the member node.  Keep it across
    ; lexer/parser helper calls because rcx is caller-saved by the ABI.
    push rcx
    call advance                      ; consume '.' or '->'
    pop rcx
    mov rax, [parser_state.current_token]
    cmp rax, TOK_IDENT
    jne .member_postfix_bad
    push rcx
    call copy_token_string            ; rax = field name ptr
    pop rcx
    push rcx
    push rax                          ; save field name
    call advance                      ; consume field name
    pop rbx                           ; rbx = field name
    pop rcx

    ; Create AST_MEMBER(base=rcx, field=rbx)
    push rcx                          ; save base around alloc_node
    mov rdi, AST_MEMBER
    call alloc_node
    pop rcx                           ; restore base
    test rax, rax
    jz .member_postfix_fail
    mov [rax + ast_node_t.data1], rcx ; base expression
    mov [rax + ast_node_t.data2], rbx ; field name
    mov rcx, rax                      ; rcx = current AST_MEMBER (for chaining)

    ; Check for chained member access (. or ->)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_DOT
    je .member_postfix_loop
    cmp rax, TOK_ARROW
    jne .member_postfix_done
    ; Arrow chaining: wrap current member in deref, then continue
    push rcx
    mov rdi, AST_UNARY_OP
    call alloc_node
    pop rcx
    test rax, rax
    jz .member_postfix_fail
    mov rdi, TOK_STAR
    mov [rax + ast_node_t.data1], rdi
    mov [rax + ast_node_t.data2], rcx
    mov rcx, rax                      ; rcx = *member
    jmp .member_postfix_loop

.member_postfix_done:
    ; No more chaining — check for postfix array index [expr]
    push rcx                          ; save AST_MEMBER node
    mov rax, [parser_state.current_token]
    cmp rax, TOK_LBRACKET
    jne .member_postfix_return
    ; Handle postfix [expr] after member access
    pop rcx                           ; rcx = base (AST_MEMBER)
    push rcx                          ; save base (parse_expression clobbers rcx)
    call advance                      ; consume '['
    call parse_expression             ; rax = index expr (full expression)
    push rax                          ; save index
    mov rdi, TOK_RBRACKET
    mov rsi, msg_expect_rbracket
    call expect
    pop rbx                           ; rbx = index expr
    pop rcx                           ; rcx = base expr (restored)
    push rcx                          ; save base
    push rbx                          ; save index
    mov rdi, AST_INDEX
    call alloc_node
    pop rbx                           ; rbx = index expr
    pop rcx                           ; rcx = base expr
    test rax, rax
    jz .member_postfix_index_fail
    mov [rax + ast_node_t.data1], rcx ; base expression
    mov [rax + ast_node_t.data2], rbx ; index expression

    ; Check for chained member access after index: entries[i].field
    ; Must preserve rax (AST_INDEX node) across the token read.
    mov rcx, rax                      ; rcx = AST_INDEX node (new base)
    push rcx                          ; save AST_INDEX node for restore on return
    mov rax, [parser_state.current_token]
    cmp rax, TOK_DOT
    je .member_postfix_index_dot
    cmp rax, TOK_ARROW
    jne .member_postfix_index_return_pop
    ; Arrow after index: wrap base in deref, then continue chaining
    push rcx
    mov rdi, AST_UNARY_OP
    call alloc_node
    pop rcx
    test rax, rax
    jz .member_postfix_index_fail_pop
    mov rdi, TOK_STAR
    mov [rax + ast_node_t.data1], rdi
    mov [rax + ast_node_t.data2], rcx
    pop rcx                           ; discard saved AST_INDEX
    mov rcx, rax                      ; rcx = *AST_INDEX (deref)
    jmp .member_postfix_loop

.member_postfix_index_return_pop:
    pop rax                           ; restore AST_INDEX node into rax
.member_postfix_index_return:
    pop r12
    pop rbx
    ret

.member_postfix_index_dot:
    pop rcx                           ; discard saved AST_INDEX
    jmp .member_postfix_loop

.member_postfix_index_fail_pop:
    pop rax                           ; discard saved AST_INDEX
.member_postfix_index_fail:
    xor rax, rax
    pop r12
    pop rbx
    ret

.member_postfix_return:
    ; No postfix index — return the AST_MEMBER
    mov rax, rcx
    pop rcx                           ; discard saved value
    pop r12
    pop rbx
    ret

.member_postfix_bad:
    mov rsi, msg_expect_ident
    call error
    xor rax, rax
    pop r12
    pop rbx
    ret

.member_postfix_fail:
    xor rax, rax
    pop r12
    pop rbx
    ret

.postfix_incr:
    ; a++ → AST_POST_INCR(a): returns old value, increments variable as side effect
    pop rbx                           ; rbx = primary expression (AST_IDENT)
    call advance                      ; consume '++'
    mov rdi, AST_POST_INCR
    call alloc_node
    test rax, rax
    jz .no_postfix_dot_fail
    mov [rax + ast_node_t.data1], rbx
    pop r12
    pop rbx
    ret

.postfix_decr:
    ; a-- → AST_POST_DECR(a): returns old value, decrements variable as side effect
    pop rbx                           ; rbx = primary expression (AST_IDENT)
    call advance                      ; consume '--'
    mov rdi, AST_POST_DECR
    call alloc_node
    test rax, rax
    jz .no_postfix_dot_fail
    mov [rax + ast_node_t.data1], rbx
    pop r12
    pop rbx
    ret

.postfix_index:
    ; base[index] → AST_INDEX(base, index)
    pop rcx                           ; rcx = base expression
    push rcx                          ; save base (parse_expression clobbers rcx)
    call advance                      ; consume '['
    call parse_expression             ; rax = index expr (full expression)
    push rax                          ; save index expr
    mov rdi, TOK_RBRACKET
    mov rsi, msg_expect_rbracket
    call expect
    pop rbx                           ; rbx = index expr
    pop rcx                           ; rcx = base expr (restored)
    push rcx                          ; save base
    push rbx                          ; save index
    mov rdi, AST_INDEX
    call alloc_node
    pop rbx                           ; rbx = index expr
    pop rcx                           ; rcx = base expr
    test rax, rax
    jz .postfix_index_fail
    mov [rax + ast_node_t.data1], rcx ; base expression
    mov [rax + ast_node_t.data2], rbx ; index expression

    ; Check for chained member access after index: arr[i].field
    ; Must preserve rax (AST_INDEX node) across the token read.
    mov rcx, rax                      ; rcx = AST_INDEX node (new base)
    push rcx                          ; save AST_INDEX node for restore on return
    mov rax, [parser_state.current_token]
    cmp rax, TOK_DOT
    je .postfix_index_dot
    cmp rax, TOK_ARROW
    jne .postfix_index_return_pop
    ; Arrow after index: wrap base in deref, then continue chaining
    push rcx
    mov rdi, AST_UNARY_OP
    call alloc_node
    pop rcx
    test rax, rax
    jz .postfix_index_fail_pop
    mov rdi, TOK_STAR
    mov [rax + ast_node_t.data1], rdi
    mov [rax + ast_node_t.data2], rcx
    pop rcx                           ; discard saved AST_INDEX
    mov rcx, rax                      ; rcx = *AST_INDEX (deref)
    jmp .member_postfix_loop

.postfix_index_return_pop:
    pop rax                           ; restore AST_INDEX node into rax
.postfix_index_return:
    pop r12
    pop rbx
    ret

.postfix_index_dot:
    pop rcx                           ; discard saved AST_INDEX
    jmp .member_postfix_loop

.postfix_index_fail_pop:
    pop rax                           ; discard saved AST_INDEX
.postfix_index_fail:
    xor rax, rax
    pop r12
    pop rbx
    ret

.no_postfix_dot:
    pop rax                           ; restore primary expr
    pop r12
    pop rbx
    ret

.no_postfix_dot_fail:
    pop rcx                           ; discard primary expr from stack
    xor rax, rax
    pop r12
    pop rbx
    ret

.unary_minus:
    mov rbx, TOK_MINUS
    jmp .make_unary
.unary_star:
    mov rbx, TOK_STAR
    jmp .make_unary
.unary_amp:
    mov rbx, TOK_AMPERSAND
    jmp .make_unary
.unary_not:
    mov rbx, TOK_NEQ    ; represent ! as NEQ (logical not)
    jmp .make_unary
.unary_tilde:
    mov rbx, TOK_TILDE
    jmp .make_unary

.unary_incr:
    ; ++a → desugar to a += 1
    push r13
    push r14
    push r15
    call advance        ; consume '++'
    call parse_unary    ; parse operand → rax
    mov r12, rax        ; r12 = operand (lvalue)

    ; Clone operand for the binary op's left side
    mov rdi, AST_IDENT
    call alloc_node
    test rax, rax
    jz .ui_fail
    mov rdi, [r12 + ast_node_t.data1]
    mov [rax + ast_node_t.data1], rdi

    ; Create AST_NUMBER(1)
    mov r13, rax
    mov rdi, AST_NUMBER
    call alloc_node
    test rax, rax
    jz .ui_fail
    mov qword [rax + ast_node_t.data1], 1

    ; Create AST_BINARY_OP(PLUS, clone, 1)
    mov r14, rax
    mov rdi, AST_BINARY_OP
    call alloc_node
    test rax, rax
    jz .ui_fail
    mov qword [rax + ast_node_t.data1], TOK_PLUS
    mov [rax + ast_node_t.data2], r13
    mov [rax + ast_node_t.data3], r14

    ; Create AST_ASSIGN(operand, binary_op)
    mov r15, rax
    mov rdi, AST_ASSIGN
    call alloc_node
    test rax, rax
    jz .ui_fail
    mov [rax + ast_node_t.data1], r12
    mov [rax + ast_node_t.data2], r15
    pop r15
    pop r14
    pop r13
    jmp .unary_done

.ui_fail:
    pop r15
    pop r14
    pop r13
    xor rax, rax
    jmp .unary_done

.unary_decr:
    ; --a → desugar to a -= 1
    push r13
    push r14
    push r15
    call advance        ; consume '--'
    call parse_unary    ; parse operand → rax
    mov r12, rax        ; r12 = operand (lvalue)

    ; Clone operand
    mov rdi, AST_IDENT
    call alloc_node
    test rax, rax
    jz .ud_fail
    mov rdi, [r12 + ast_node_t.data1]
    mov [rax + ast_node_t.data1], rdi

    ; Create AST_NUMBER(1)
    mov r13, rax
    mov rdi, AST_NUMBER
    call alloc_node
    test rax, rax
    jz .ud_fail
    mov qword [rax + ast_node_t.data1], 1

    ; Create AST_BINARY_OP(MINUS, clone, 1)
    mov r14, rax
    mov rdi, AST_BINARY_OP
    call alloc_node
    test rax, rax
    jz .ud_fail
    mov qword [rax + ast_node_t.data1], TOK_MINUS
    mov [rax + ast_node_t.data2], r13
    mov [rax + ast_node_t.data3], r14

    ; Create AST_ASSIGN(operand, binary_op)
    mov r15, rax
    mov rdi, AST_ASSIGN
    call alloc_node
    test rax, rax
    jz .ud_fail
    mov [rax + ast_node_t.data1], r12
    mov [rax + ast_node_t.data2], r15
    pop r15
    pop r14
    pop r13
    jmp .unary_done

.ud_fail:
    pop r15
    pop r14
    pop r13
    xor rax, rax
    jmp .unary_done

.make_unary:
    call advance               ; consume unary op
    call parse_unary
    mov r12, rax               ; r12 = operand (preserved across alloc_node)

    mov rdi, AST_UNARY_OP
    call alloc_node
    test rax, rax
    jz .unary_done
    mov [rax + ast_node_t.data1], rbx    ; operator
    mov [rax + ast_node_t.data2], r12    ; operand

.unary_done:
    pop r12
    pop rbx
    ret

; ================================================================
; parse_primary() -> AST node
; primary = NUMBER | STRING | CHAR | IDENT | "(" expression ")"
; ================================================================
parse_primary:
    push rbx

    mov rax, [parser_state.current_token]

    cmp rax, TOK_NUMBER
    je .number
    cmp rax, TOK_CHAR
    je .char
    cmp rax, TOK_STRING
    je .string
    cmp rax, TOK_IDENT
    je .ident
    cmp rax, TOK_LPAREN
    je .paren

    ; Not a primary expression
    mov rsi, msg_expected_primary
    call error
    xor rax, rax
    pop rbx
    ret

.number:
    call parse_number_value
    mov rbx, rax               ; rbx = number value
    call advance

    mov rdi, AST_NUMBER
    call alloc_node
    test rax, rax
    jz .num_done
    mov [rax + ast_node_t.data1], rbx

.num_done:
    pop rbx
    ret

.char:
    ; The char value is in tok_buf (first byte)
    mov rsi, [parser_state.token_value]
    xor rbx, rbx
    mov bl, [rsi]              ; first byte = character value
    call advance

    mov rdi, AST_CHAR
    call alloc_node
    test rax, rax
    jz .char_done
    mov [rax + ast_node_t.data1], rbx

.char_done:
    pop rbx
    ret

.string:
    call copy_token_string
    mov rbx, rax               ; rbx = string (heap copy)
    push r15                   ; save caller's r15 (callee-saved)
    mov r15, [parser_state.token_len]  ; r15 = string length (includes embedded nulls)
    push r15                   ; save string length across alloc_node
    call advance

    mov rdi, AST_STRING
    call alloc_node
    test rax, rax
    jz .str_fail
    pop r15                    ; restore string length
    mov [rax + ast_node_t.data1], rbx
    mov [rax + ast_node_t.data2], r15    ; store length for codegen

.str_done:
    pop r15                    ; restore caller's r15
    pop rbx
    ret

.str_fail:
    pop r15                    ; discard string length
    pop r15                    ; discard saved r15
    xor rax, rax
    pop rbx
    ret

.ident:
    call copy_token_string
    mov rbx, rax               ; rbx = name (heap copy)
    call advance

    ; Check for function call: ident '('
    mov rax, [parser_state.current_token]
    cmp rax, TOK_LPAREN
    je .func_call

    ; Check for array index: ident '['
    cmp rax, TOK_LBRACKET
    je .array_index

    ; Check for member access: ident '.'
    cmp rax, TOK_DOT
    je .member_access

    ; Regular identifier
    mov rdi, AST_IDENT
    call alloc_node
    test rax, rax
    jz .ident_done
    mov [rax + ast_node_t.data1], rbx

.ident_done:
    pop rbx
    ret

.array_index:
    ; rbx = name_ptr (heap copy)
    ; Create AST_IDENT node for the base
    push rbx
    mov rdi, AST_IDENT
    call alloc_node
    pop rbx
    test rax, rax
    jz .ident_done
    mov [rax + ast_node_t.data1], rbx    ; store name_ptr in ident node
    push rax                             ; save ident node

    call advance                         ; consume '['
    call parse_expression                ; rax = index expr
    push rax                             ; save index expr

    mov rdi, TOK_RBRACKET
    mov rsi, msg_expect_rbracket
    call expect

    pop rbx                              ; rbx = index expr
    pop rax                              ; rax = ident node
    push rax
    push rbx

    mov rdi, AST_INDEX
    call alloc_node
    test rax, rax
    jz .array_fail
    pop rbx                              ; rbx = index expr
    pop rcx                              ; rcx = ident node
    mov [rax + ast_node_t.data1], rcx    ; base ident node
    mov [rax + ast_node_t.data2], rbx    ; index expr
    pop rbx                              ; restore saved rbx
    ret

.array_fail:
    ; rax = 0, clean up stack
    pop rbx                              ; discard index expr
    pop rbx                              ; discard ident node
    xor rax, rax
    pop rbx
    ret

.member_access:
    ; rbx = struct_name_ptr (heap copy)
    ; Current token is '.'
    push rbx                             ; save struct name

    call advance                         ; consume '.'

    ; Next token must be an identifier (field name)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_IDENT
    jne .member_bad

    call copy_token_string               ; rax = field_name_ptr
    push rax                             ; save field name

    call advance                         ; consume field name

    pop rbx                              ; rbx = field_name_ptr
    pop rcx                              ; rcx = struct_name_ptr
    push rcx
    push rbx

    mov rdi, AST_MEMBER
    call alloc_node
    test rax, rax
    jz .member_fail
    pop rbx                              ; rbx = field_name_ptr
    pop rcx                              ; rcx = struct_name_ptr
    mov [rax + ast_node_t.data1], rcx    ; struct name ptr
    mov [rax + ast_node_t.data2], rbx    ; field name ptr

    ; Check for chained member access (another '.' or '->')
    mov r12, rax                         ; r12 = current AST_MEMBER node
.member_chain_check:
    mov rax, [parser_state.current_token]
    cmp rax, TOK_DOT
    je .mcc_dot_or_arrow
    cmp rax, TOK_ARROW
    jne .member_chain_done

.mcc_dot_or_arrow:
    cmp rax, TOK_ARROW
    jne .mcc_consume_dot
    ; Arrow: wrap current node in deref first
    push r12
    mov rdi, AST_UNARY_OP
    call alloc_node
    pop r12
    test rax, rax
    jz .member_fail
    mov rdi, TOK_STAR
    mov [rax + ast_node_t.data1], rdi
    mov [rax + ast_node_t.data2], r12
    mov r12, rax                         ; r12 = *member
.mcc_consume_dot:
    call advance                         ; consume '.' or '->'
    mov rax, [parser_state.current_token]
    cmp rax, TOK_IDENT
    jne .member_bad
    call copy_token_string               ; rax = new field_name_ptr
    push rax                             ; save new field name
    call advance                         ; consume field name
    pop rbx                              ; rbx = new field name

    mov rdi, AST_MEMBER
    push rbx
    push r12
    call alloc_node
    pop r12                              ; restore base expression
    pop rbx                              ; restore field name
    test rax, rax
    jz .member_fail
    mov [rax + ast_node_t.data1], r12    ; base expression (AST_MEMBER node)
    mov [rax + ast_node_t.data2], rbx    ; field name
    mov r12, rax                         ; new current node
    jmp .member_chain_check

.member_chain_done:
    mov rax, r12
    pop rbx                              ; restore saved rbx
    ret

.member_bad:
    ; Error: expected field name after '.'
    mov rsi, msg_syntax
    call error
    pop rbx                              ; discard struct name
    xor rax, rax
    pop rbx
    ret

.member_fail:
    ; rax = 0, clean up stack
    pop rbx                              ; discard field name
    pop rbx                              ; discard struct name
    xor rax, rax
    pop rbx
    ret

.func_call:
    ; Function call: ident '(' args ')'
    ; Check that the function has been declared/defined
    push rbx                   ; save function name
    mov rdi, rbx
    call func_is_declared
    test rax, rax
    pop rbx                    ; restore function name
    jnz .fcall_proceed
    ; Error: function not declared
    push rbx
    mov rsi, msg_undeclared_func
    call error
    pop rbx
    ; Recover: skip the function call tokens ( (...) )
    mov rax, [parser_state.current_token]
    cmp rax, TOK_LPAREN
    jne .func_call_skip_done
    call advance               ; consume '('
    xor rcx, rcx               ; paren depth
.func_call_skip:
    mov rax, [parser_state.current_token]
    cmp rax, TOK_EOF
    je .func_call_skip_done
    cmp rax, TOK_LPAREN
    jne .func_call_skip_not_open
    inc rcx
    jmp .func_call_skip_next
.func_call_skip_not_open:
    cmp rax, TOK_RPAREN
    jne .func_call_skip_next
    test rcx, rcx
    jz .func_call_skip_close
    dec rcx
.func_call_skip_next:
    call advance
    jmp .func_call_skip
.func_call_skip_close:
    call advance               ; consume ')'
.func_call_skip_done:
    xor rax, rax
    pop rbx
    ret

.fcall_proceed:
    call advance               ; consume '('

    push r12
    push r13

    ; Allocate arg array (max 127 args)
    mov rdi, 127
    call alloc_ptr_array
    mov r12, rax               ; r12 = arg array
    xor r13, r13               ; r13 = arg count

.fcall_arg_loop:
    mov rax, [parser_state.current_token]
    cmp rax, TOK_RPAREN
    je .fcall_args_done
    cmp rax, TOK_EOF
    je .fcall_args_done

    ; Parse an argument expression
    call parse_expression
    test rax, rax
    jz .fcall_arg_skip

    ; Store arg in array
    cmp r13, 127
    jae .fcall_arg_skip
    mov [r12 + 8 + r13 * 8], rax
    inc r13

.fcall_arg_skip:
    mov rax, [parser_state.current_token]
    cmp rax, TOK_COMMA
    jne .fcall_args_done
    call advance               ; consume ','
    jmp .fcall_arg_loop

.fcall_args_done:
    mov [r12], r13             ; store arg count in array[0]

    ; Expect ')'
    mov rdi, TOK_RPAREN
    mov rsi, msg_expect_rparen
    call expect

    mov rdi, AST_CALL
    call alloc_node
    test rax, rax
    jz .fcall_done
    mov [rax + ast_node_t.data1], rbx    ; function name
    mov [rax + ast_node_t.data2], r12    ; arg array

.fcall_done:
    pop r13
    pop r12
    pop rbx
    ret

.paren:
    call advance               ; consume '('

    ; Check for C-style cast: (type) expr
    ; Peek at next token — if it's a type keyword, this is a cast
    mov rax, [parser_state.current_token]
    cmp rax, TOK_KW_INT
    je .cast_expr
    cmp rax, TOK_KW_CHAR
    je .cast_expr
    cmp rax, TOK_KW_STRUCT
    je .cast_expr
    ; Not a cast — fall through to parenthesized expression
    call parse_expression
    push rax
    mov rdi, TOK_RPAREN
    mov rsi, msg_expect_rparen
    call expect
    pop rax
    pop rbx
    ret

.cast_expr:
    ; C-style cast: parse and preserve the target type so codegen can keep
    ; correct pointer/struct metadata for expressions like
    ; ((struct Node*)raw)->field and ((char*)ptr)[i].
    push qword 0                      ; local: field_array_ptr
    push qword 0                      ; local: target_type

    ; First, consume the type keyword (int, char, struct)
    mov rax, [parser_state.current_token]
    cmp rax, TOK_KW_STRUCT
    jne .cast_basic_type
    ; struct [Name] [*] — handle named struct pointer cast
    call advance                     ; consume 'struct'
    mov qword [rsp], TOK_KW_STRUCT
    ; Check for optional struct name
    mov rax, [parser_state.current_token]
    cmp rax, TOK_IDENT
    jne .cast_ptr_loop
    call copy_token_string           ; rax = struct tag name
    push rax
    call advance                     ; consume struct name
    pop rdi
    call find_named_struct
    mov [rsp + 8], rcx               ; save field_array_ptr for struct casts
    jmp .cast_ptr_loop

.cast_basic_type:
    mov [rsp], rax                   ; save base target type token
    call advance                     ; consume type keyword (int/char/void)

    ; Parse optional pointer modifiers (*)
.cast_ptr_loop:
    mov rax, [parser_state.current_token]
    cmp rax, TOK_STAR
    jne .cast_ptr_done
    mov rax, [rsp]
    add rax, PTR_TYPE_FLAG
    mov [rsp], rax
    call advance                     ; consume '*'
    jmp .cast_ptr_loop
.cast_ptr_done:

    ; Expect ')'
    mov rdi, TOK_RPAREN
    mov rsi, msg_expect_rparen
    call expect

    ; Parse the expression being cast. Use parse_unary to support casts on
    ; dereference/address-of like `(int)*str`.
    call parse_unary

    ; Wrap the inner expression in AST_CAST so codegen can preserve the
    ; target type even though the runtime operation is still a no-op.
    push rax                         ; save inner expression
    mov rdi, AST_CAST
    call alloc_node
    test rax, rax
    jz .cast_fail
    pop rcx                          ; rcx = inner expression
    mov rdx, [rsp]                   ; rdx = target_type
    mov r8, [rsp + 8]                ; r8 = field_array_ptr
    add rsp, 16                      ; pop cast locals
    mov [rax + ast_node_t.data1], rdx
    mov [rax + ast_node_t.data2], rcx
    mov [rax + ast_node_t.data3], r8
    pop rbx
    ret

.cast_fail:
    add rsp, 24                      ; discard inner expression + cast locals
    xor rax, rax
    pop rbx
    ret

; ================================================================
; Function name registry
; ================================================================

; register_func_name(rdi = name_ptr) — add function name to registry
register_func_name:
    push rax
    push rcx
    push rdi
    push rsi

    call ensure_func_registry_capacity

    mov rdi, [rsp + 8]
    mov rax, [func_registry_count]
    mov rcx, [func_name_registry_capacity]
    cmp rax, rcx
    jae .rfn_done

    ; Check for duplicate
    xor rcx, rcx
.rfn_check:
    cmp rcx, rax
    jae .rfn_add
    mov rdx, [func_name_registry]
    mov rsi, [rdx + rcx * 8]
    push rdi
    push rcx
    push rax
    call mem_eq_str                 ; compare rsi(name in registry), rdi(target)
    pop rax
    pop rcx
    pop rdi
    test rax, rax
    jz .rfn_done                    ; already registered
    inc rcx
    jmp .rfn_check

.rfn_add:
    mov rdx, [func_name_registry]
    mov [rdx + rax * 8], rdi
    inc qword [func_registry_count]

.rfn_done:
    pop rsi
    pop rdi
    pop rcx
    pop rax
    ret

; func_is_declared(rdi = name_ptr) -> rax = 1 if declared, 0 if not
func_is_declared:
    push rcx
    push rsi
    push rdi

    mov rcx, [func_registry_count]
    test rcx, rcx
    jz .fid_not_found

.fid_loop:
    dec rcx
    mov rdx, [func_name_registry]
    mov rsi, [rdx + rcx * 8]
    push rcx
    push rdi
    call mem_eq_str
    pop rdi
    pop rcx
    test rax, rax
    jz .fid_found
    test rcx, rcx
    jnz .fid_loop

.fid_not_found:
    xor rax, rax
    pop rdi
    pop rsi
    pop rcx
    ret

.fid_found:
    mov rax, 1
    pop rdi
    pop rsi
    pop rcx
    ret

; mem_eq_str(rdi = str1, rsi = str2) -> rax = 0 if equal, 1 if different
; Compare two null-terminated strings
global mem_eq_str
mem_eq_str:
    push rcx
    push rsi
    push rdi

.loop:
    mov al, [rdi]
    mov cl, [rsi]
    cmp al, cl
    jne .diff
    test al, al
    jz .equal
    inc rdi
    inc rsi
    jmp .loop

.diff:
    mov rax, 1
    pop rdi
    pop rsi
    pop rcx
    ret

.equal:
    xor rax, rax
    pop rdi
    pop rsi
    pop rcx
    ret

; ================================================================
; Parser Cleanup
; ================================================================
parser_cleanup:
    call lexer_cleanup
    ret

; ================================================================
; Utility Functions
; ================================================================
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
