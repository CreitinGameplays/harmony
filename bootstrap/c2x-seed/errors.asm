format ELF64

; ================================================================
; errors.asm — Centralized Error System
;
; All error codes, messages, and the code→string lookup table.
; Exports error_code() and error_at_code() for use by lexer,
; parser, and code generator.
; ================================================================

; ------------------------------------------------------------
; Error Codes
; ------------------------------------------------------------
; Lexer errors (1-99)
ERR_UNKNOWN_CHAR = 1
ERR_MULTI_CHAR = 2
ERR_UNTERM_STRING = 3
ERR_UNTERM_COMMENT = 4
ERR_INVALID_ESC = 5

; Parser errors (100-199)
ERR_SYNTAX = 100
ERR_EXPECTED_SEMI = 101
ERR_EXPECTED_RPAREN = 102
ERR_EXPECTED_RBRACE = 103
ERR_EXPECTED_TYPE = 104
ERR_EXPECTED_IDENT = 105
ERR_EXPECTED_LBRACE = 106
ERR_EXPECTED_RBRACKET = 107
ERR_UNEXPECTED = 108
ERR_EXPECTED_PRIMARY = 109
ERR_EXPECTED_LPAREN = 110
ERR_ASSIGN_CONST = 111

; Semantic errors (150-199)
ERR_INFINITE_STRUCT = 150

; Compiler errors (200-299)
ERR_ASM_FAIL = 201
ERR_LD_FAIL = 202
ERR_BUILD_FAIL = 203
ERR_OPEN_FAIL = 204

; ------------------------------------------------------------
; External dependencies
; ------------------------------------------------------------

; ------------------------------------------------------------
; Initialized Data — Error Messages
; ------------------------------------------------------------
section '.data' writeable

; Lexer messages
msg_unknown_char:    db "Unexpected character", 0
msg_multi_char:      db "Multi-character literal", 0
msg_unterm_string:   db "Unterminated string literal", 0
msg_unterm_comment:  db "Unterminated block comment", 0
msg_invalid_esc:     db "Invalid escape sequence", 0

; Parser messages
msg_syntax:          db "Syntax error", 0
msg_expect_semi:     db "Expected ';'", 0
msg_expect_rparen:   db "Expected ')'", 0
msg_expect_rbrace:   db "Expected '}'", 0
msg_expect_type:     db "Expected type (int, char, void)", 0
msg_expect_ident:    db "Expected identifier", 0
msg_expect_lbrace:   db "Expected '{'", 0
msg_expect_rbracket: db "Expected ']'", 0
msg_unexpected:      db "Unexpected token", 0
msg_expected_primary: db "Expected primary expression", 0
msg_expect_lparen:   db "Expected '('", 0
msg_void_return_val: db "void function returning a value", 0
msg_undeclared_func: db "function not declared before use", 0
msg_expect_dot:      db "Expected '.'", 0
msg_expect_eq:       db "Expected '='", 0
msg_assign_const:    db "Cannot assign to const variable", 0
msg_no_field:        db "no field named", 0
msg_infinite_struct: db "struct cannot contain itself by value (use a pointer field)", 0
msg_undeclared:      db "undeclared identifier", 0

; Compiler messages
msg_asm_fail:        db "Error: assembly failed", 10, 0
msg_ld_fail:         db "Error: linking failed", 10, 0
msg_build_fail:      db "Error: build failed", 10, 0
msg_open_fail:       db "Error: could not open source file", 10, 0

; Fallback
msg_unknown_error:   db "Unknown error", 0

; ------------------------------------------------------------
; Error Code-to-String Lookup Table
; Pairs of (code, string_ptr), terminated by -1
; ------------------------------------------------------------
err_table:
    dq ERR_UNKNOWN_CHAR,   msg_unknown_char
    dq ERR_MULTI_CHAR,     msg_multi_char
    dq ERR_UNTERM_STRING,  msg_unterm_string
    dq ERR_UNTERM_COMMENT, msg_unterm_comment
    dq ERR_INVALID_ESC,    msg_invalid_esc
    dq ERR_SYNTAX,         msg_syntax
    dq ERR_EXPECTED_SEMI,  msg_expect_semi
    dq ERR_EXPECTED_RPAREN, msg_expect_rparen
    dq ERR_EXPECTED_RBRACE, msg_expect_rbrace
    dq ERR_EXPECTED_TYPE,  msg_expect_type
    dq ERR_EXPECTED_IDENT, msg_expect_ident
    dq ERR_EXPECTED_LBRACE, msg_expect_lbrace
    dq ERR_EXPECTED_RBRACKET, msg_expect_rbracket
    dq ERR_UNEXPECTED,     msg_unexpected
    dq ERR_EXPECTED_PRIMARY, msg_expected_primary
    dq ERR_EXPECTED_LPAREN, msg_expect_lparen
    dq ERR_ASSIGN_CONST,   msg_assign_const
    dq ERR_INFINITE_STRUCT, msg_infinite_struct
    dq ERR_ASM_FAIL,       msg_asm_fail
    dq ERR_LD_FAIL,        msg_ld_fail
    dq ERR_BUILD_FAIL,     msg_build_fail
    dq ERR_OPEN_FAIL,      msg_open_fail
    dq -1                               ; sentinel

; ------------------------------------------------------------
; Text (executable code)
; ------------------------------------------------------------
section '.text' executable

; ------------------------------------------------------------
; Look up error message by code
; rdi = error code
; Returns: rax = message string pointer (or ptr to "Unknown error")
; ------------------------------------------------------------
lookup_error:
    push rbx
    push rcx
    xor rax, rax
    mov rbx, err_table
.loop:
    mov rcx, [rbx]          ; code
    cmp rcx, -1
    je .not_found
    cmp rcx, rdi
    je .found
    add rbx, 16             ; next pair
    jmp .loop
.found:
    mov rax, [rbx + 8]      ; string_ptr
    pop rcx
    pop rbx
    ret
.not_found:
    mov rax, msg_unknown_error
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; error_code(rdi = error_code)
; Print error using lexer's current token position.
; Replacement for: mov rsi, msg_xxx; call error
; ------------------------------------------------------------
error_code:
    push rdi
    mov rdi, [lexer_state + 296] ; tok_line
    mov rsi, [lexer_state + 304] ; tok_col
    pop rdx                      ; rdx = error_code
    call error_at_code
    ret

; ------------------------------------------------------------
; error_at_code(rdi = error_code, rsi = line, rdx = col)
; Print error with position, looking up message from code.
; Replacement for: mov rdx, msg_xxx; call error_at
; ------------------------------------------------------------
error_at_code:
    push rsi                ; save line
    push rdx                ; save col
    mov rdi, rdi            ; already error_code
    call lookup_error       ; rax = message string ptr
    mov rdx, rax            ; rdx = msg string
    pop rsi                 ; rsi = col
    pop rdi                 ; rdi = line
    call error_at
    ret

; ------------------------------------------------------------
; String exports for legacy compatibility (expect, etc.)
; These are the message strings that some callers pass by pointer.
; ------------------------------------------------------------
extrn error_at
extrn out_write_string
extrn lexer_state
public err_table
public lookup_error
public error_code
public error_at_code
public msg_unknown_char
public msg_multi_char
public msg_unterm_string
public msg_unterm_comment
public msg_invalid_esc
public msg_syntax
public msg_expect_semi
public msg_expect_rparen
public msg_expect_rbrace
public msg_expect_type
public msg_expect_ident
public msg_expect_lbrace
public msg_expect_rbracket
public msg_unexpected
public msg_expected_primary
public msg_expect_lparen
public msg_void_return_val
public msg_undeclared_func
public msg_expect_dot
public msg_expect_eq
public msg_assign_const
public msg_no_field
public msg_infinite_struct
public msg_undeclared
public msg_asm_fail
public msg_ld_fail
public msg_build_fail
public msg_open_fail
public msg_unknown_error
