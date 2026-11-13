; C2X Seed - Memory Management
; Bump allocator for heap, stack frame management

; ------------------------------------------------------------
; Exported Functions and Data
; ------------------------------------------------------------
global heap_init, heap_alloc, heap_alloc_zero
global frame_push, frame_pop, frame_alloc
global mem_zero, mem_copy, mem_eq
global heap_base, heap_ptr, heap_end, current_rbp, frame_depth
global HEAP_SIZE, STACK_FRAME_SIZE

section .data
    ; Heap configuration
    ; Large multi-file units (c2x-proto with ELF/MC backend modules) need
    ; more headroom than the original 10 MiB; 64 MiB keeps self-host viable.
    HEAP_SIZE       equ 64 * 1024 * 1024
    STACK_FRAME_SIZE equ 256               ; Default stack frame size

section .bss
    ; Heap memory region
    heap_base:      resb HEAP_SIZE
    heap_ptr:       resq 1                 ; Current heap pointer
    heap_end:       resq 1                 ; End of heap (heap_base + HEAP_SIZE)
    
    ; Stack frame tracking
    current_rbp:    resq 1                 ; Saved RBP for current frame
    frame_depth:    resq 1                 ; Current frame nesting depth

default rel

section .text

; ------------------------------------------------------------
; Heap Initialization
; ------------------------------------------------------------
heap_init:
    ; Set heap_ptr to heap_base
    mov rax, heap_base
    mov [heap_ptr], rax
    
    ; Calculate heap_end = heap_base + HEAP_SIZE
    add rax, HEAP_SIZE
    mov [heap_end], rax
    
    ; Initialize frame tracking
    mov qword [frame_depth], 0
    mov rax, rbp
    mov [current_rbp], rax
    
    ret

; ------------------------------------------------------------
; Bump Allocator: heap_alloc(size_t size) -> void*
; Allocates 'size' bytes from heap, returns pointer in rax
; Returns 0 (NULL) on out of memory
; Clobbers: rax, rdx
; ------------------------------------------------------------
heap_alloc:
    ; Align size to 8 bytes (64-bit alignment)
    mov rax, rdi
    add rax, 7
    and rax, ~7
    mov rdi, rax                 ; rdi = aligned size
    
    ; Check if allocation fits
    mov rax, [heap_ptr]
    add rax, rdi
    cmp rax, [heap_end]
    ja .oom                      ; Overflow - out of memory
    
    ; Allocation succeeds
    mov rax, [heap_ptr]          ; Return current pointer
    add qword [heap_ptr], rdi    ; Bump pointer
    ret

.oom:
    xor rax, rax                 ; Return NULL
    ret

; ------------------------------------------------------------
; heap_alloc_zero(size_t size) -> void*
; Allocates and zeroes memory
; Clobbers: rax, rdi, rsi, rdx, rcx
; ------------------------------------------------------------
heap_alloc_zero:
    call heap_alloc
    test rax, rax
    jz .done
    
    ; Zero the allocated memory
    mov rdi, rax                 ; Save pointer (dst) in rdi
    push rax                     ; Save return value
    xor rax, rax                 ; Value = zero (for stosq)
    mov rdx, [heap_ptr]          ; Current ptr (after allocation)
    sub rdx, rdi                 ; Size allocated
    mov rcx, rdx
    shr rcx, 3                   ; Divide by 8 for qword stores
    rep stosq
    ; Handle remaining bytes
    mov rcx, rdx
    and rcx, 7
    rep stosb
    pop rax                      ; Restore return value (pointer)
.done:
    ret

; ------------------------------------------------------------
; Stack Frame Management
; ------------------------------------------------------------

; frame_push() - Save current frame, create new one
; Clobbers: rax
frame_push:
    ; Save current RBP
    mov rax, rbp
    mov [current_rbp], rax
    
    ; Standard x86_64 frame setup
    push rbp
    mov rbp, rsp
    
    ; Increment frame depth
    inc qword [frame_depth]
    ret

; frame_pop() - Restore previous frame
; Clobbers: rax
frame_pop:
    ; Standard frame teardown
    mov rsp, rbp
    pop rbp
    
    ; Decrement frame depth
    dec qword [frame_depth]
    ret

; frame_alloc(size_t size) -> void*
; Allocates 'size' bytes on current stack frame
; Returns pointer in rax (relative to RBP, negative offset)
; Clobbers: rax
frame_alloc:
    ; Align to 16 bytes for SSE compatibility
    mov rax, rdi
    add rax, 15
    and rax, ~15
    
    sub rsp, rax
    mov rax, rsp                 ; Return pointer to allocated space
    ret

; ------------------------------------------------------------
; Memory Utility Functions
; ------------------------------------------------------------

; mem_zero(void* ptr, size_t size)
; Zeroes 'size' bytes at 'ptr'
; Input: rdi = ptr, rsi = size
; Clobbers: rax, rcx, rdi
mem_zero:
    mov rax, rdi
    mov rcx, rsi
    shr rcx, 3                   ; qword count
    xor rdi, rdi                 ; zero value
    rep stosq
    mov rcx, rsi
    and rcx, 7
    rep stosb
    ret

; mem_copy(void* dst, const void* src, size_t size)
; Copies 'size' bytes from src to dst
; Input: rdi = dst, rsi = src, rdx = size
; Clobbers: rax, rcx, rdi, rsi
mem_copy:
    mov rcx, rdx
    shr rcx, 3
    rep movsq
    mov rcx, rdx
    and rcx, 7
    rep movsb
    ret

; mem_eq(const void* a, const void* b, size_t size) -> int
; Compares 'size' bytes at a and b
; Returns: rax = 0 if equal, 1 if different
; Clobbers: rax, rcx, rdi, rsi
mem_eq:
    mov rcx, rdx
    shr rcx, 3
    repe cmpsq
    jne .notequal
    mov rcx, rdx
    and rcx, 7
    repe cmpsb
    jne .notequal
    xor rax, rax
    ret

.notequal:
    mov rax, 1
    ret