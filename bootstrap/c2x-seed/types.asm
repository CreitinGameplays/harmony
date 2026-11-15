format ELF64

; C2X Seed - Data Type Definitions
; Minimalist 64-bit architecture: int (64-bit), char (8-bit), pointers

; ------------------------------------------------------------
; Exported Functions
; ------------------------------------------------------------

section '.data' writeable
    ; ------------------------------------------------------------
    ; Type System Constants
    ; ------------------------------------------------------------
    
    ; Base type IDs (for compiler symbol table)
    TYPE_VOID = 0
    TYPE_INT = 1  ; 64-bit signed integer (universal workhorse)
    TYPE_CHAR = 2  ; 8-bit signed integer (byte/ASCII)
    TYPE_PTR = 3  ; Pointer type (base + pointee type)
    
    ; Type sizes in bytes
    SIZE_INT = 8
    SIZE_CHAR = 1
    SIZE_PTR = 8  ; 64-bit pointers
    
    ; Type alignment requirements
    ALIGN_INT = 8
    ALIGN_CHAR = 1
    ALIGN_PTR = 8
    
    ; ------------------------------------------------------------
    ; Type Encoding
    ; ------------------------------------------------------------
    ; High 32 bits: kind bits, low 32 bits = pointee type ID (for pointers)
    ; ------------------------------------------------------------
    TYPE_KIND_SHIFT = 32
    TYPE_KIND_MASK = 7
    
    KIND_BASE = 0  ; int, char, void
    KIND_PTR = 1  ; pointer to type
    KIND_ARRAY = 2  ; array of type
    
    ; Pre-encoded common types (computed: kind << 32  or  base_type)
    ; KIND_BASE (0) << 32 = 0
    TYPE_ENC_INT = 1
    TYPE_ENC_CHAR = 2
    TYPE_ENC_VOID = 0
    ; KIND_PTR (1) << 32 = 0x100000000
    TYPE_ENC_CHAR_PTR = 0x100000002  ; 0x100000000  or  TYPE_CHAR(2)
    TYPE_ENC_INT_PTR = 0x100000001  ; 0x100000000  or  TYPE_INT(1)
    TYPE_ENC_VOID_PTR = 0x100000000  ; 0x100000000  or  TYPE_VOID(0)
    
    ; ------------------------------------------------------------
    ; Register Calling Convention (System V AMD64 ABI)
    ; ------------------------------------------------------------
    ; Argument registers (in order): rdi, rsi, rdx, rcx, r8, r9
    ; Return register: rax (64-bit), al (8-bit)
    ; Callee-saved: rbx, rbp, r12-r15
    ; Caller-saved: rax, rcx, rdx, rsi, rdi, r8-r11
    
    ARG_REGS_COUNT = 6
    ; Argument registers (use as register names directly in code)
    ; ARG_REG_1 = rdi, ARG_REG_2 = rsi, ARG_REG_3 = rdx
    ; ARG_REG_4 = rcx, ARG_REG_5 = r8, ARG_REG_6 = r9
    ; Return registers: RET_REG_64 = rax, RET_REG_8 = al


section '.text' executable

; ------------------------------------------------------------
; Type Utility Functions (for compiler runtime)
; ------------------------------------------------------------

; type_size(type_id) -> size_t
; Returns size in bytes for a base type
; Input: rdi = type_id (TYPE_INT, TYPE_CHAR, TYPE_PTR)
; Output: rax = size
type_size:
    cmp rdi, TYPE_INT
    je .is_int
    cmp rdi, TYPE_CHAR
    je .is_char
    cmp rdi, TYPE_PTR
    je .is_ptr
    
    xor rax, rax               ; Unknown type = 0
    ret

.is_int:
    mov rax, SIZE_INT
    ret

.is_char:
    mov rax, SIZE_CHAR
    ret

.is_ptr:
    mov rax, SIZE_PTR
    ret

; type_align(type_id) -> size_t
; Returns alignment requirement for a base type
; Input: rdi = type_id
; Output: rax = alignment
type_align:
    cmp rdi, TYPE_INT
    je .align_int
    cmp rdi, TYPE_CHAR
    je .align_char
    cmp rdi, TYPE_PTR
    je .align_ptr
    
    mov rax, 1                 ; Default alignment
    ret

.align_int:
    mov rax, ALIGN_INT
    ret

.align_char:
    mov rax, ALIGN_CHAR
    ret

.align_ptr:
    mov rax, ALIGN_PTR
    ret

; type_is_integer(type_id) -> bool
; Returns true (1) if type is integer (int or char)
; Input: rdi = type_id
; Output: rax = 1 if integer, 0 otherwise
type_is_integer:
    cmp rdi, TYPE_INT
    je .yes
    cmp rdi, TYPE_CHAR
    je .yes
    xor rax, rax
    ret

.yes:
    mov rax, 1
    ret

; type_is_pointer(type_id) -> bool
; Returns true (1) if type is a pointer
; Input: rdi = encoded_type_id
; Output: rax = 1 if pointer, 0 otherwise
type_is_pointer:
    mov rax, rdi
    shr rax, TYPE_KIND_SHIFT
    and rax, TYPE_KIND_MASK
    cmp rax, KIND_PTR
    je .yes
    cmp rax, KIND_ARRAY
    je .yes
    xor rax, rax
    ret

.yes:
    mov rax, 1
    ret

; type_get_pointee(encoded_type) -> base_type_id
; Extracts pointee type from pointer type encoding
; Input: rdi = encoded_type
; Output: rax = pointee type_id (or 0 if not a pointer)
type_get_pointee:
    mov rax, rdi
    shr rax, TYPE_KIND_SHIFT
    and rax, TYPE_KIND_MASK
    cmp rax, KIND_PTR
    jne .not_ptr
    mov eax, edi               ; Low 32 bits = pointee type (zero-extended)
    ret

.not_ptr:
    xor rax, rax
    ret

; ------------------------------------------------------------
; Value Representation Helpers
; ------------------------------------------------------------

; sign_extend_char_to_int(char_val) -> int64
; Sign-extends 8-bit value in al to 64-bit in rax
; Input: al = 8-bit value
; Output: rax = sign-extended 64-bit
sign_extend_char:
    movsx rax, al
    ret

; zero_extend_char_to_int(char_val) -> uint64
; Zero-extends 8-bit value in al to 64-bit in rax
; Input: al = 8-bit value
; Output: rax = zero-extended 64-bit
zero_extend_char:
    movzx rax, al
    ret

; truncate_int_to_char(int64_val) -> char
; Truncates 64-bit value to 8-bit
; Input: rax = 64-bit value
; Output: al = low 8 bits
truncate_int_to_char:
    ; rax already has low 8 bits in al
    ret

; ------------------------------------------------------------
; Pointer Arithmetic Helpers
; ------------------------------------------------------------

; ptr_add(base_ptr, index, element_size) -> void*
; Computes base_ptr + index * element_size
; Input: rdi = base_ptr, rsi = index, rdx = element_size
; Output: rax = computed pointer
ptr_add:
    mov rax, rsi
    imul rax, rdx              ; rax = index * element_size
    add rax, rdi               ; rax = base + offset
    ret

; ptr_diff(ptr1, ptr2, element_size) -> int64
; Computes (ptr1 - ptr2) / element_size
; Input: rdi = ptr1, rsi = ptr2, rdx = element_size
; Output: rax = difference in elements
; Clobbers: rdx
ptr_diff:
    mov rax, rdi
    sub rax, rsi               ; rax = byte difference
    mov rcx, rdx               ; save element_size in rcx before cqo clobbers rdx
    cqo                        ; Sign-extend rax to rdx:rax
    idiv rcx                   ; rax = difference / element_size
    ret

; ------------------------------------------------------------
; Dereference Helpers (for code generation)
; ------------------------------------------------------------

; deref_int(void* ptr) -> int64
; Loads 64-bit integer from memory
; Input: rdi = pointer
; Output: rax = 64-bit value
deref_int:
    mov rax, [rdi]
    ret

; deref_char(void* ptr) -> int8 (in al)
; Loads 8-bit integer from memory
; Input: rdi = pointer
; Output: al = 8-bit value
deref_char:
    mov al, [rdi]
    ret

; deref_ptr(void* ptr) -> void*
; Loads 64-bit pointer from memory
; Input: rdi = pointer
; Output: rax = 64-bit pointer value
deref_ptr:
    mov rax, [rdi]
    ret

; store_int(void* ptr, int64_val)
; Stores 64-bit integer to memory
; Input: rdi = pointer, rsi = value
store_int:
    mov [rdi], rsi
    ret

; store_char(void* ptr, int8_val)
; Stores 8-bit integer to memory
; Input: rdi = pointer, sil = value
store_char:
    mov [rdi], sil
    ret

; store_ptr(void* ptr, void* val)
; Stores 64-bit pointer to memory
; Input: rdi = pointer, rsi = value
store_ptr:
    mov [rdi], rsi
    ret
public type_size
public type_align
public type_is_integer
public type_is_pointer
public type_get_pointee
public sign_extend_char
public zero_extend_char
public truncate_int_to_char
public ptr_add
public ptr_diff
public deref_int
public deref_char
public deref_ptr
public store_int
public store_char
public store_ptr
