; C2X Seed - Lexical Analyzer
; Tokenizes C2X source code into a stream of tokens.
; Input characters come from the buffered I/O system (io.asm):
;   in_get_char() -> char in al (ZF set on EOF)
;   in_peek_char() -> char in al, no advance
;   in_skip_char() -> advance one byte
;
; Token return convention:
;   lexer_next_token() -> token type in rax
;   Token text, length, and position are stored in lexer_state

; ------------------------------------------------------------
; External Dependencies
; ------------------------------------------------------------
extern in_get_char, in_peek_char, in_skip_char
extern out_write_string_len
extern error_count
extern error_at
extern error_at_code

; ------------------------------------------------------------
; Exported Symbols
; ------------------------------------------------------------
global lexer_init, lexer_next_token, lexer_cleanup
global lexer_state

; ------------------------------------------------------------
; Token Type Constants
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

; Compound assignment operators
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

; Increment/decrement
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

; Error codes (matching errors.asm)
ERR_UNKNOWN_CHAR   equ 1
ERR_MULTI_CHAR     equ 2

; ------------------------------------------------------------
; Initialized Data
; ------------------------------------------------------------
section .data
    ; Keyword strings for lookup
    kw_int    db "int", 0
    kw_char   db "char", 0
    kw_void   db "void", 0
    kw_if     db "if", 0
    kw_else   db "else", 0
    kw_while  db "while", 0
    kw_return db "return", 0
    kw_struct db "struct", 0
    kw_extern db "extern", 0
    kw_for    db "for", 0
    kw_break  db "break", 0
    kw_continue db "continue", 0
    kw_const    db "const", 0
    ; Error messages

; ------------------------------------------------------------
; Uninitialized Data
; ------------------------------------------------------------
section .bss
    ; Lexer state - exported for parser access
    global lexer_state
    lexer_state:
        .current_char   resb 1          ; Current lookahead character (0 = EOF)
        .pad            resb 7          ; Padding to align next fields
        .line           resq 1          ; Current line number (1-based)
        .column         resq 1          ; Current column number (0-based)
        .tok_type       resq 1          ; Type of the most recently recognized token
        .tok_buf        resb 256        ; Buffer holding the token text
        .tok_len        resq 1          ; Length of token text in tok_buf
        .tok_line       resq 1          ; Line where the token started
        .tok_col        resq 1          ; Column where the token started

    ; Previous token position (saved before advancing to next token)
    global prev_tok_line, prev_tok_col
    prev_tok_line       resq 1
    prev_tok_col        resq 1

default rel

; ------------------------------------------------------------
section .text

; ------------------------------------------------------------
; lexer_init()
; Initialize lexer state and load the first character.
; ------------------------------------------------------------
lexer_init:
    mov qword [lexer_state.line], 1
    xor rax, rax
    mov [lexer_state.column], rax
    mov [lexer_state.tok_type], rax
    mov [lexer_state.tok_len], rax

    ; Read first character into lookahead
    call in_get_char
    mov [lexer_state.current_char], al
    ret

; ------------------------------------------------------------
; lexer_cleanup()
; No-op for now; may release resources in the future.
; ------------------------------------------------------------
lexer_cleanup:
    ret

; ------------------------------------------------------------
; lexer_next_token()
; Scan and return the next token from the input.
; Returns: rax = token type
; Stores token details in lexer_state.
; ------------------------------------------------------------
lexer_next_token:
    push rbx
    push r12

    ; Reset token length (only scan_ident/scan_number/scan_string/scan_char set it)
    mov qword [lexer_state.tok_len], 0

    ; Save previous token position before advancing
    mov rax, [lexer_state.tok_line]
    mov [prev_tok_line], rax
    mov rax, [lexer_state.tok_col]
    mov [prev_tok_col], rax

    ; Save token start position
    mov rax, [lexer_state.line]
    mov [lexer_state.tok_line], rax
    mov rax, [lexer_state.column]
    mov [lexer_state.tok_col], rax

; ---- Skip whitespace ----
.skip_ws:
    mov al, [lexer_state.current_char]
    test al, al
    jz .return_eof

    cmp al, ' '             ; space
    je .skip_ws_adv
    cmp al, 9               ; horizontal tab
    je .skip_ws_adv
    cmp al, 13              ; carriage return
    je .skip_ws_adv
    cmp al, 10              ; newline
    je .skip_ws_nl
    jmp .dispatch

.skip_ws_nl:
    inc qword [lexer_state.line]
    xor rax, rax
    mov [lexer_state.column], rax
    jmp .skip_ws_adv

.skip_ws_adv:
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    jmp .skip_ws

; ---- EOF ----
.return_eof:
    xor rax, rax
    mov [lexer_state.tok_type], rax
    pop r12
    pop rbx
    ret

; ---- Dispatch on first character ----
.dispatch:
    mov al, [lexer_state.current_char]

    ; Identifier start: [A-Za-z_]
    cmp al, 'A'
    jb .not_upper
    cmp al, 'Z'
    jbe .scan_ident
.not_upper:
    cmp al, 'a'
    jb .not_lower
    cmp al, 'z'
    jbe .scan_ident
.not_lower:
    cmp al, '_'
    je .scan_ident

    ; Digit start
    cmp al, '0'
    jb .not_digit
    cmp al, '9'
    jbe .scan_number
.not_digit:

    ; String / char literals
    cmp al, '"'
    je .scan_string
    cmp al, 39              ; '
    je .scan_char

    ; Slash or comment
    cmp al, '/'
    je .slash_or_comment

    ; Single-char / multi-char operators
    cmp al, '+'
    je .token_plus
    cmp al, '-'
    je .token_minus_or_arrow
    cmp al, '*'
    je .token_star
    cmp al, '%'
    je .token_percent
    cmp al, '='
    je .token_eq_or_eqeq
    cmp al, '!'
    je .token_bang_or_neq
    cmp al, '<'
    je .token_lt_or_le
    cmp al, '>'
    je .token_gt_or_ge
    cmp al, '('
    je .token_lparen
    cmp al, ')'
    je .token_rparen
    cmp al, '{'
    je .token_lbrace
    cmp al, '}'
    je .token_rbrace
    cmp al, '['
    je .token_lbracket
    cmp al, ']'
    je .token_rbracket
    cmp al, ';'
    je .token_semi
    cmp al, ','
    je .token_comma
    cmp al, ':'
    je .token_colon
    cmp al, '&'
    je .token_ampersand
    cmp al, '|'
    je .token_pipe
    cmp al, '^'
    je .token_xor
    cmp al, '~'
    je .token_tilde
    cmp al, '.'
    je .token_dot

    ; Unknown character – report error and skip
    mov rdi, ERR_UNKNOWN_CHAR
    mov rsi, [lexer_state.line]
    mov rdx, [lexer_state.column]
    call error_at_code
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    jmp .skip_ws

; ================================================================
;  TOKEN: Single / two-char operators
; ================================================================

; Each token handler follows the same pattern:
;   - Advance past the token characters by calling in_get_char for
;     each consumed character plus one more (to fill current_char).
;   - The first consumed character is the one already in current_char.
;   - For a single-char token: 1 extra in_get_char call.
;   - For a two-char token:    2 extra in_get_char calls.

.token_plus:
    call in_peek_char
    cmp al, '='
    je .token_addeq
    cmp al, '+'
    je .token_incr
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    mov qword [lexer_state.tok_type], TOK_PLUS
    mov rax, TOK_PLUS
    pop r12
    pop rbx
    ret

.token_addeq:
    call in_get_char
    call in_get_char
    mov [lexer_state.current_char], al
    add qword [lexer_state.column], 2
    mov qword [lexer_state.tok_type], TOK_ADDEQ
    mov rax, TOK_ADDEQ
    pop r12
    pop rbx
    ret

.token_incr:
    call in_get_char
    call in_get_char
    mov [lexer_state.current_char], al
    add qword [lexer_state.column], 2
    mov qword [lexer_state.tok_type], TOK_INCR
    mov rax, TOK_INCR
    pop r12
    pop rbx
    ret

.token_minus_or_arrow:
    call in_peek_char
    cmp al, '>'
    je .token_arrow
    cmp al, '='
    je .token_subeq
    cmp al, '-'
    je .token_decr
    ; Single minus
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    mov qword [lexer_state.tok_type], TOK_MINUS
    mov rax, TOK_MINUS
    pop r12
    pop rbx
    ret

.token_arrow:
    ; Consume '-' (current) and '>' (peeked) and the next char
    call in_get_char
    call in_get_char
    mov [lexer_state.current_char], al
    add qword [lexer_state.column], 2
    mov qword [lexer_state.tok_type], TOK_ARROW
    mov rax, TOK_ARROW
    pop r12
    pop rbx
    ret

.token_subeq:
    call in_get_char
    call in_get_char
    mov [lexer_state.current_char], al
    add qword [lexer_state.column], 2
    mov qword [lexer_state.tok_type], TOK_SUBEQ
    mov rax, TOK_SUBEQ
    pop r12
    pop rbx
    ret

.token_decr:
    call in_get_char
    call in_get_char
    mov [lexer_state.current_char], al
    add qword [lexer_state.column], 2
    mov qword [lexer_state.tok_type], TOK_DECR
    mov rax, TOK_DECR
    pop r12
    pop rbx
    ret

.token_star:
    call in_peek_char
    cmp al, '='
    je .token_muleq
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    mov qword [lexer_state.tok_type], TOK_STAR
    mov rax, TOK_STAR
    pop r12
    pop rbx
    ret

.token_muleq:
    call in_get_char
    call in_get_char
    mov [lexer_state.current_char], al
    add qword [lexer_state.column], 2
    mov qword [lexer_state.tok_type], TOK_MULEQ
    mov rax, TOK_MULEQ
    pop r12
    pop rbx
    ret

.token_percent:
    call in_peek_char
    cmp al, '='
    je .token_modeq
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    mov qword [lexer_state.tok_type], TOK_PERCENT
    mov rax, TOK_PERCENT
    pop r12
    pop rbx
    ret

.token_modeq:
    call in_get_char
    call in_get_char
    mov [lexer_state.current_char], al
    add qword [lexer_state.column], 2
    mov qword [lexer_state.tok_type], TOK_MODEQ
    mov rax, TOK_MODEQ
    pop r12
    pop rbx
    ret

.token_eq_or_eqeq:
    call in_peek_char
    cmp al, '='
    je .token_eqeq
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    mov qword [lexer_state.tok_type], TOK_EQ
    mov rax, TOK_EQ
    pop r12
    pop rbx
    ret

.token_eqeq:
    call in_get_char
    call in_get_char
    mov [lexer_state.current_char], al
    add qword [lexer_state.column], 2
    mov qword [lexer_state.tok_type], TOK_EQEQ
    mov rax, TOK_EQEQ
    pop r12
    pop rbx
    ret

.token_bang_or_neq:
    call in_peek_char
    cmp al, '='
    je .token_neq
    ; Single '!' – logical not
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    mov qword [lexer_state.tok_type], TOK_NOT
    mov rax, TOK_NOT
    pop r12
    pop rbx
    ret

.token_neq:
    call in_get_char
    call in_get_char
    mov [lexer_state.current_char], al
    add qword [lexer_state.column], 2
    mov qword [lexer_state.tok_type], TOK_NEQ
    mov rax, TOK_NEQ
    pop r12
    pop rbx
    ret

.token_lt_or_le:
    call in_peek_char
    cmp al, '='
    je .token_le
    cmp al, '<'
    je .token_lshift
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    mov qword [lexer_state.tok_type], TOK_LT
    mov rax, TOK_LT
    pop r12
    pop rbx
    ret

.token_le:
    call in_get_char
    call in_get_char
    mov [lexer_state.current_char], al
    add qword [lexer_state.column], 2
    mov qword [lexer_state.tok_type], TOK_LE
    mov rax, TOK_LE
    pop r12
    pop rbx
    ret

.token_lshift:
    call in_get_char          ; consume second '<'
    call in_peek_char
    cmp al, '='
    je .token_lshift_eq
    call in_get_char          ; consume next char
    mov [lexer_state.current_char], al
    add qword [lexer_state.column], 2
    mov qword [lexer_state.tok_type], TOK_LSHIFT
    mov rax, TOK_LSHIFT
    pop r12
    pop rbx
    ret

.token_lshift_eq:
    call in_get_char          ; consume '='
    call in_get_char          ; consume next char
    mov [lexer_state.current_char], al
    add qword [lexer_state.column], 3
    mov qword [lexer_state.tok_type], TOK_LSHIFT_EQ
    mov rax, TOK_LSHIFT_EQ
    pop r12
    pop rbx
    ret

.token_gt_or_ge:
    call in_peek_char
    cmp al, '='
    je .token_ge
    cmp al, '>'
    je .token_rshift
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    mov qword [lexer_state.tok_type], TOK_GT
    mov rax, TOK_GT
    pop r12
    pop rbx
    ret

.token_ge:
    call in_get_char
    call in_get_char
    mov [lexer_state.current_char], al
    add qword [lexer_state.column], 2
    mov qword [lexer_state.tok_type], TOK_GE
    mov rax, TOK_GE
    pop r12
    pop rbx
    ret

.token_rshift:
    call in_get_char          ; consume second '>'
    call in_peek_char
    cmp al, '='
    je .token_rshift_eq
    call in_get_char          ; consume next char
    mov [lexer_state.current_char], al
    add qword [lexer_state.column], 2
    mov qword [lexer_state.tok_type], TOK_RSHIFT
    mov rax, TOK_RSHIFT
    pop r12
    pop rbx
    ret

.token_rshift_eq:
    call in_get_char          ; consume '='
    call in_get_char          ; consume next char
    mov [lexer_state.current_char], al
    add qword [lexer_state.column], 3
    mov qword [lexer_state.tok_type], TOK_RSHIFT_EQ
    mov rax, TOK_RSHIFT_EQ
    pop r12
    pop rbx
    ret

; ---- Delimiters ----
.token_lparen:
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    mov qword [lexer_state.tok_type], TOK_LPAREN
    mov rax, TOK_LPAREN
    pop r12
    pop rbx
    ret

.token_rparen:
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    mov qword [lexer_state.tok_type], TOK_RPAREN
    mov rax, TOK_RPAREN
    pop r12
    pop rbx
    ret

.token_lbrace:
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    mov qword [lexer_state.tok_type], TOK_LBRACE
    mov rax, TOK_LBRACE
    pop r12
    pop rbx
    ret

.token_rbrace:
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    mov qword [lexer_state.tok_type], TOK_RBRACE
    mov rax, TOK_RBRACE
    pop r12
    pop rbx
    ret

.token_lbracket:
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    mov qword [lexer_state.tok_type], TOK_LBRACKET
    mov rax, TOK_LBRACKET
    pop r12
    pop rbx
    ret

.token_rbracket:
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    mov qword [lexer_state.tok_type], TOK_RBRACKET
    mov rax, TOK_RBRACKET
    pop r12
    pop rbx
    ret

.token_semi:
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    mov qword [lexer_state.tok_type], TOK_SEMI
    mov rax, TOK_SEMI
    pop r12
    pop rbx
    ret

.token_comma:
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    mov qword [lexer_state.tok_type], TOK_COMMA
    mov rax, TOK_COMMA
    pop r12
    pop rbx
    ret

.token_colon:
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    mov qword [lexer_state.tok_type], TOK_COLON
    mov rax, TOK_COLON
    pop r12
    pop rbx
    ret

.token_ampersand:
    call in_peek_char
    cmp al, '&'
    je .token_and
    cmp al, '='
    je .token_andeq
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    mov qword [lexer_state.tok_type], TOK_AMPERSAND
    mov rax, TOK_AMPERSAND
    pop r12
    pop rbx
    ret

.token_and:
    call in_get_char
    call in_get_char
    mov [lexer_state.current_char], al
    add qword [lexer_state.column], 2
    mov qword [lexer_state.tok_type], TOK_AND
    mov rax, TOK_AND
    pop r12
    pop rbx
    ret

.token_andeq:
    call in_get_char
    call in_get_char
    mov [lexer_state.current_char], al
    add qword [lexer_state.column], 2
    mov qword [lexer_state.tok_type], TOK_ANDEQ
    mov rax, TOK_ANDEQ
    pop r12
    pop rbx
    ret

.token_pipe:
    call in_peek_char
    cmp al, '|'
    je .token_or
    cmp al, '='
    je .token_oreq
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    mov qword [lexer_state.tok_type], TOK_PIPE
    mov rax, TOK_PIPE
    pop r12
    pop rbx
    ret

.token_or:
    call in_get_char
    call in_get_char
    mov [lexer_state.current_char], al
    add qword [lexer_state.column], 2
    mov qword [lexer_state.tok_type], TOK_OR
    mov rax, TOK_OR
    pop r12
    pop rbx
    ret

.token_oreq:
    call in_get_char
    call in_get_char
    mov [lexer_state.current_char], al
    add qword [lexer_state.column], 2
    mov qword [lexer_state.tok_type], TOK_OREQ
    mov rax, TOK_OREQ
    pop r12
    pop rbx
    ret

.token_xor:
    call in_peek_char
    cmp al, '='
    je .token_xoreq
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    mov qword [lexer_state.tok_type], TOK_XOR
    mov rax, TOK_XOR
    pop r12
    pop rbx
    ret

.token_xoreq:
    call in_get_char
    call in_get_char
    mov [lexer_state.current_char], al
    add qword [lexer_state.column], 2
    mov qword [lexer_state.tok_type], TOK_XOREQ
    mov rax, TOK_XOREQ
    pop r12
    pop rbx
    ret

.token_tilde:
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    mov qword [lexer_state.tok_type], TOK_TILDE
    mov rax, TOK_TILDE
    pop r12
    pop rbx
    ret

.token_dot:
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    mov qword [lexer_state.tok_type], TOK_DOT
    mov rax, TOK_DOT
    pop r12
    pop rbx
    ret

; ================================================================
;  TOKEN: Slash (/) or comment (// or /* */)
; ================================================================
.slash_or_comment:
    call in_peek_char
    cmp al, '/'
    je .line_comment
    cmp al, '*'
    je .block_comment
    cmp al, '='
    je .token_diveq

    ; Just a divide operator
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    mov qword [lexer_state.tok_type], TOK_SLASH
    mov rax, TOK_SLASH
    pop r12
    pop rbx
    ret

.token_diveq:
    call in_get_char
    call in_get_char
    mov [lexer_state.current_char], al
    add qword [lexer_state.column], 2
    mov qword [lexer_state.tok_type], TOK_DIVEQ
    mov rax, TOK_DIVEQ
    pop r12
    pop rbx
    ret

.line_comment:
    ; Consume the two '/' characters
    call in_get_char          ; skip first '/'
    call in_get_char          ; skip second '/', get next char
    mov [lexer_state.current_char], al
    add qword [lexer_state.column], 2

.lc_loop:
    mov al, [lexer_state.current_char]
    test al, al
    jz .lc_end
    cmp al, 10
    je .lc_end

    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    jmp .lc_loop

.lc_end:
    ; Do NOT consume the newline – whitespace handler deals with it
    jmp .skip_ws

.block_comment:
    ; Consume the '/' and '*'
    call in_get_char          ; skip '/'
    call in_get_char          ; skip '*', get next char
    mov [lexer_state.current_char], al
    add qword [lexer_state.column], 2

.bc_loop:
    mov al, [lexer_state.current_char]
    test al, al
    jz .bc_continue           ; EOF inside comment – just stop

    cmp al, '*'
    je .bc_star

    cmp al, 10
    jne .bc_adv

    ; Track newlines inside block comment
    inc qword [lexer_state.line]
    xor rax, rax
    mov [lexer_state.column], rax

.bc_adv:
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    jmp .bc_loop

.bc_star:
    call in_peek_char
    cmp al, '/'
    je .bc_end

    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    jmp .bc_loop

.bc_end:
    ; Consume '*' and '/'
    call in_get_char          ; skip '*'
    call in_get_char          ; skip '/', get next char
    mov [lexer_state.current_char], al
    add qword [lexer_state.column], 2

.bc_continue:
    jmp .skip_ws

; ================================================================
;  TOKEN: Identifier or Keyword
; ================================================================
.scan_ident:
    lea rbx, [lexer_state.tok_buf]
    xor r12d, r12d            ; length counter

.id_loop:
    mov al, [lexer_state.current_char]
    mov [rbx], al
    inc rbx
    inc r12

    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]

    ; Check if next character continues the identifier
    mov al, [lexer_state.current_char]
    cmp al, 'A'
    jb .id_check_digit
    cmp al, 'Z'
    jbe .id_loop
.id_check_digit:
    cmp al, 'a'
    jb .id_check_under
    cmp al, 'z'
    jbe .id_loop
.id_check_under:
    cmp al, '0'
    jb .id_check_under2
    cmp al, '9'
    jbe .id_loop
.id_check_under2:
    cmp al, '_'
    je .id_loop

    ; Terminate the token buffer
    mov byte [rbx], 0
    mov [lexer_state.tok_len], r12

    ; ---- Keyword matching ----
    lea rsi, [lexer_state.tok_buf]
    mov rdx, r12

    lea rdi, [kw_int]
    call str_eq
    test rax, rax
    jnz .kw_int

    lea rdi, [kw_char]
    call str_eq
    test rax, rax
    jnz .kw_char

    lea rdi, [kw_void]
    call str_eq
    test rax, rax
    jnz .kw_void

    lea rdi, [kw_if]
    call str_eq
    test rax, rax
    jnz .kw_if

    lea rdi, [kw_else]
    call str_eq
    test rax, rax
    jnz .kw_else

    lea rdi, [kw_while]
    call str_eq
    test rax, rax
    jnz .kw_while

    lea rdi, [kw_return]
    call str_eq
    test rax, rax
    jnz .kw_return

    lea rdi, [kw_struct]
    call str_eq
    test rax, rax
    jnz .kw_struct

    lea rdi, [kw_extern]
    call str_eq
    test rax, rax
    jnz .kw_extern

    lea rdi, [kw_for]
    call str_eq
    test rax, rax
    jnz .kw_for

    lea rdi, [kw_break]
    call str_eq
    test rax, rax
    jnz .kw_break

    lea rdi, [kw_continue]
    call str_eq
    test rax, rax
    jnz .kw_continue

    lea rdi, [kw_const]
    call str_eq
    test rax, rax
    jnz .kw_const

    ; Not a keyword – regular identifier
    mov qword [lexer_state.tok_type], TOK_IDENT
    mov rax, TOK_IDENT
    pop r12
    pop rbx
    ret

.kw_int:
    mov qword [lexer_state.tok_type], TOK_KW_INT
    mov rax, TOK_KW_INT
    pop r12
    pop rbx
    ret

.kw_char:
    mov qword [lexer_state.tok_type], TOK_KW_CHAR
    mov rax, TOK_KW_CHAR
    pop r12
    pop rbx
    ret

.kw_void:
    mov qword [lexer_state.tok_type], TOK_KW_VOID
    mov rax, TOK_KW_VOID
    pop r12
    pop rbx
    ret

.kw_if:
    mov qword [lexer_state.tok_type], TOK_KW_IF
    mov rax, TOK_KW_IF
    pop r12
    pop rbx
    ret

.kw_else:
    mov qword [lexer_state.tok_type], TOK_KW_ELSE
    mov rax, TOK_KW_ELSE
    pop r12
    pop rbx
    ret

.kw_while:
    mov qword [lexer_state.tok_type], TOK_KW_WHILE
    mov rax, TOK_KW_WHILE
    pop r12
    pop rbx
    ret

.kw_return:
    mov qword [lexer_state.tok_type], TOK_KW_RETURN
    mov rax, TOK_KW_RETURN
    pop r12
    pop rbx
    ret

.kw_struct:
    mov qword [lexer_state.tok_type], TOK_KW_STRUCT
    mov rax, TOK_KW_STRUCT
    pop r12
    pop rbx
    ret

.kw_extern:
    mov qword [lexer_state.tok_type], TOK_KW_EXTERN
    mov rax, TOK_KW_EXTERN
    pop r12
    pop rbx
    ret

.kw_for:
    mov qword [lexer_state.tok_type], TOK_KW_FOR
    mov rax, TOK_KW_FOR
    pop r12
    pop rbx
    ret

.kw_break:
    mov qword [lexer_state.tok_type], TOK_KW_BREAK
    mov rax, TOK_KW_BREAK
    pop r12
    pop rbx
    ret

.kw_continue:
    mov qword [lexer_state.tok_type], TOK_KW_CONTINUE
    mov rax, TOK_KW_CONTINUE
    pop r12
    pop rbx
    ret

.kw_const:
    mov qword [lexer_state.tok_type], TOK_KW_CONST
    mov rax, TOK_KW_CONST
    pop r12
    pop rbx
    ret

; ================================================================
;  TOKEN: Integer Number
; ================================================================
.scan_number:
    lea rbx, [lexer_state.tok_buf]
    xor r12d, r12d

    ; Check for hex literal: '0x' or '0X'
    mov al, [lexer_state.current_char]
    cmp al, '0'
    jne .num_loop
    call in_peek_char
    cmp al, 'x'
    je .scan_hex
    cmp al, 'X'
    je .scan_hex
    ; Fall through to normal decimal parsing

.num_loop:
    mov al, [lexer_state.current_char]
    mov [rbx], al
    inc rbx
    inc r12

    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]

    mov al, [lexer_state.current_char]
    cmp al, '0'
    jb .num_done
    cmp al, '9'
    jbe .num_loop

.num_done:
    mov byte [rbx], 0
    mov [lexer_state.tok_len], r12
    mov qword [lexer_state.tok_type], TOK_NUMBER
    mov rax, TOK_NUMBER
    pop r12
    pop rbx
    ret

.scan_hex:
    ; Consume '0' and 'x'
    mov byte [rbx], '0'
    inc rbx
    inc r12
    call in_get_char               ; consume '0'
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]

    mov byte [rbx], 'x'
    inc rbx
    inc r12
    call in_get_char               ; consume 'x'
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]

.hex_loop:
    mov al, [lexer_state.current_char]
    mov [rbx], al
    inc rbx
    inc r12

    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]

    mov al, [lexer_state.current_char]
    cmp al, '0'
    jb .hex_done
    cmp al, '9'
    jbe .hex_loop
    ; Check for hex letters (a-f, A-F)
    cmp al, 'a'
    jb .check_upper
    cmp al, 'f'
    jbe .hex_loop
.check_upper:
    cmp al, 'A'
    jb .hex_done
    cmp al, 'F'
    jbe .hex_loop

.hex_done:
    mov byte [rbx], 0
    mov [lexer_state.tok_len], r12
    mov qword [lexer_state.tok_type], TOK_NUMBER
    mov rax, TOK_NUMBER
    pop r12
    pop rbx
    ret

; ================================================================
;  TOKEN: String Literal
; ================================================================
.scan_string:
    ; Consume the opening '"' (current_char)
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]

    lea rbx, [lexer_state.tok_buf]
    xor r12d, r12d

.str_loop:
    mov al, [lexer_state.current_char]
    test al, al
    jz .str_end               ; EOF before closing quote

    cmp al, '"'
    je .str_close

    cmp al, '\'
    je .str_escape

    ; Regular character
    mov [rbx], al
    inc rbx
    inc r12
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    jmp .str_loop

.str_escape:
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]

    mov al, [lexer_state.current_char]
    cmp al, 'n'
    je .str_esc_newline
    cmp al, 'r'
    je .str_esc_cr
    cmp al, 't'
    je .str_esc_tab
    cmp al, 0x5C               ; backslash
    je .str_esc_copy
    cmp al, '"'
    je .str_esc_copy
    cmp al, 0x27               ; single quote
    je .str_esc_copy
    cmp al, '0'
    je .str_esc_null

    ; Unknown escape – copy verbatim
    jmp .str_esc_copy

.str_esc_newline:
    mov byte [rbx], 10
    inc rbx
    inc r12
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    jmp .str_loop

.str_esc_cr:
    mov byte [rbx], 13
    inc rbx
    inc r12
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    jmp .str_loop

.str_esc_tab:
    mov byte [rbx], 9
    inc rbx
    inc r12
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    jmp .str_loop

.str_esc_null:
    mov byte [rbx], 0
    inc rbx
    inc r12
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    jmp .str_loop

.str_esc_copy:
    mov [rbx], al
    inc rbx
    inc r12
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    jmp .str_loop

.str_close:
    ; Consume the closing '"'
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]

.str_end:
    mov byte [rbx], 0
    mov [lexer_state.tok_len], r12
    mov qword [lexer_state.tok_type], TOK_STRING
    mov rax, TOK_STRING
    pop r12
    pop rbx
    ret

; ================================================================
;  TOKEN: Character Literal
; ================================================================
.scan_char:
    ; Consume the opening '\'' (current_char)
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]

    lea rbx, [lexer_state.tok_buf]
    xor r12d, r12d

    ; Read first character
    mov al, [lexer_state.current_char]
    test al, al
    jz .char_end_eof

    cmp al, 0x27              ; closing quote immediately – empty char
    je .char_close

    cmp al, 0x5C              ; backslash
    je .char_escape

    ; Regular character
    mov [rbx], al
    inc rbx
    inc r12
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    jmp .char_expect_close

.char_escape:
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]

    mov al, [lexer_state.current_char]
    cmp al, 'n'
    je .char_esc_newline
    cmp al, 'r'
    je .char_esc_cr
    cmp al, 't'
    je .char_esc_tab
    cmp al, 0x5C              ; backslash
    je .char_esc_copy
    cmp al, 0x27              ; single quote
    je .char_esc_copy
    cmp al, '"'
    je .char_esc_copy
    cmp al, '0'
    je .char_esc_null
    jmp .char_esc_copy

.char_esc_newline:
    mov byte [rbx], 10
    inc rbx
    inc r12
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    jmp .char_expect_close

.char_esc_cr:
    mov byte [rbx], 13
    inc rbx
    inc r12
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    jmp .char_expect_close

.char_esc_tab:
    mov byte [rbx], 9
    inc rbx
    inc r12
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    jmp .char_expect_close

.char_esc_null:
    mov byte [rbx], 0
    inc rbx
    inc r12
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    jmp .char_expect_close

.char_esc_copy:
    mov [rbx], al
    inc rbx
    inc r12
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]

.char_expect_close:
    ; Expect closing '\''
    mov al, [lexer_state.current_char]
    test al, al
    jz .char_end_eof

    cmp al, 0x27
    je .char_close

    ; Multi-character literal — report error, then skip to closing quote
    push r12                         ; save char count
    mov rdi, ERR_MULTI_CHAR
    mov rsi, [lexer_state.tok_line]
    mov rdx, [lexer_state.tok_col]
    call error_at_code
    pop r12                          ; restore char count
    jmp .char_skip_to_close

.char_skip_to_close:
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]
    mov al, [lexer_state.current_char]
    test al, al
    jz .char_end_eof
    cmp al, 0x27
    jne .char_skip_to_close

.char_close:
    ; Consume closing '\''
    call in_get_char
    mov [lexer_state.current_char], al
    inc qword [lexer_state.column]

.char_end_eof:
    mov byte [rbx], 0
    mov [lexer_state.tok_len], r12
    mov qword [lexer_state.tok_type], TOK_CHAR
    mov rax, TOK_CHAR
    pop r12
    pop rbx
    ret

; ================================================================
;  str_eq(const char *a, const char *b, size_t len) -> bool
;  Compare two strings for exact equality up to len bytes.
;  a begins at RSI, b at RDI, length in RDX.
;  Returns: rax = 1 if equal, 0 otherwise.
; ================================================================
str_eq:
    push rcx
    push rsi
    push rdi

    mov rcx, rdx
.next:
    mov al, [rsi]
    mov bl, [rdi]
    cmp al, bl
    jne .noteq
    test al, al
    jz .eq_done          ; Both strings ended at same point

    inc rsi
    inc rdi
    dec rcx
    jnz .next

    ; All rdx bytes matched; verify keyword ends here
    cmp byte [rdi], 0
    jne .noteq

.eq_done:
    mov rax, 1
    pop rdi
    pop rsi
    pop rcx
    ret

.noteq:
    xor rax, rax
    pop rdi
    pop rsi
    pop rcx
    ret

; ------------------------------------------------------------
; print_string(const char* str) — write null-terminated string
; Input: rsi = string
; ------------------------------------------------------------
print_string:
    push rsi
    push rcx
    push rdx
    mov rdi, rsi
    xor rcx, rcx
.count:
    cmp byte [rdi + rcx], 0
    je .write
    inc rcx
    jmp .count
.write:
    mov rsi, rdi
    mov rdx, rcx
    call out_write_string_len
    pop rdx
    pop rcx
    pop rsi
    ret
