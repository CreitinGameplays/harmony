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
ERR_UNKNOWN_CHAR   equ 1
ERR_MULTI_CHAR     equ 2
ERR_UNTERM_STRING  equ 3
ERR_UNTERM_COMMENT equ 4
ERR_INVALID_ESC    equ 5

; Parser errors (100-199)
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
ERR_ASSIGN_CONST    equ 111

; Semantic errors (150-199)
ERR_INFINITE_STRUCT equ 150

; Compiler errors (200-299)
ERR_ASM_FAIL       equ 201
ERR_LD_FAIL        equ 202
ERR_BUILD_FAIL     equ 203
ERR_OPEN_FAIL      equ 204

; ------------------------------------------------------------
; External dependencies
; ------------------------------------------------------------
extern error_at
extern out_write_string
extern lexer_state

; ------------------------------------------------------------
; Initialized Data — Error Messages
; ------------------------------------------------------------
section .data

; Lexer messages
msg_unknown_char    db "Unexpected character", 0
msg_multi_char      db "Multi-character literal", 0
msg_unterm_string   db "Unterminated string literal", 0
msg_unterm_comment  db "Unterminated block comment", 0
msg_invalid_esc     db "Invalid escape sequence", 0

; Parser messages
msg_syntax          db "Syntax error", 0
msg_expect_semi     db "Expected ';'", 0
msg_expect_rparen   db "Expected ')'", 0
msg_expect_rbrace   db "Expected '}'", 0
msg_expect_type     db "Expected type (int, char, void)", 0
msg_expect_ident    db "Expected identifier", 0
msg_expect_lbrace   db "Expected '{'", 0
msg_expect_rbracket db "Expected ']'", 0
msg_unexpected      db "Unexpected token", 0
msg_expected_primary db "Expected primary expression", 0
msg_expect_lparen   db "Expected '('", 0
msg_void_return_val db "void function returning a value", 0
msg_undeclared_func db "function not declared before use", 0
msg_expect_dot      db "Expected '.'", 0
msg_expect_eq       db "Expected '='", 0
msg_assign_const    db "Cannot assign to const variable", 0
msg_infinite_struct db "struct cannot contain itself by value (use a pointer field)", 0
msg_undeclared      db "undeclared identifier", 0

; Compiler messages
msg_asm_fail        db "Error: assembly failed", 10, 0
msg_ld_fail         db "Error: linking failed", 10, 0
msg_build_fail      db "Error: build failed", 10, 0
msg_open_fail       db "Error: could not open source file", 10, 0

; Fallback
msg_unknown_error   db "Unknown error", 0

; ------------------------------------------------------------
; Error Code-to-String Lookup Table
; Pairs of (code, string_ptr), terminated by -1
; ------------------------------------------------------------
    global err_table
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
default rel
section .text

; ------------------------------------------------------------
; Look up error message by code
; rdi = error code
; Returns: rax = message string pointer (or ptr to "Unknown error")
; ------------------------------------------------------------
    global lookup_error
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
    global error_code
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
    global error_at_code
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
    global msg_unknown_char
    global msg_multi_char
    global msg_unterm_string
    global msg_unterm_comment
    global msg_invalid_esc
    global msg_syntax
    global msg_expect_semi
    global msg_expect_rparen
    global msg_expect_rbrace
    global msg_expect_type
    global msg_expect_ident
    global msg_expect_lbrace
    global msg_expect_rbracket
    global msg_unexpected
    global msg_expected_primary
    global msg_expect_lparen
    global msg_void_return_val
    global msg_undeclared_func
    global msg_expect_dot
    global msg_expect_eq
    global msg_assign_const
    global msg_infinite_struct
    global msg_undeclared
    global msg_infinite_struct
    global msg_asm_fail
    global msg_ld_fail
    global msg_build_fail
    global msg_open_fail
    global msg_unknown_error
