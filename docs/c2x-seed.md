# C2X Seed (Stage 0) — Reference

The seed compiler is the bootstrap stage of the C2X compiler chain. Written in x86_64 NASM assembly, it compiles `c2x-proto` source files into x86_64 assembly. It has no dependencies beyond Linux syscalls.

**Current status:** The compiler successfully compiles programs with:
- Variable declarations (`int`, `char`)
- Control flow: `if`/`else`, `while`, `for`, `return`
- **Function parameters** — up to 127 params per function, passed via rdi/rsi/rdx/rcx/r8/r9 and stack per x86_64 ABI
- **Arrays** (`int arr[10];`) with indexing (`arr[i] = val; val = arr[i];`)
- **Array initializers** (`int arr[3] = {1, 2, 3};`, `char buf[4] = {'a', 'b', 'c', 'd'};`) for both local and global arrays
- **Runtime array bounds checking** — out-of-bounds `arr[i]` access exits with code 1 via `sys_exit`
- **Structs** (`struct { int x; int y; } s;`) with member access (`s.x = 10; return s.x;`)
- **Named structs** (`struct Point { int x; int y; }; struct Point p;`) with type registry and reuse
- **Struct pointers** (`struct Point *p; p = &g; (*p).x = 42;`, also `p->x`) for both local and global structs
- **Struct pointer fields** (`struct Def { struct Field* fields; }`) — named struct pointer fields are 8-byte pointers. Indexing through them (`d.fields[i].offset`) scales by the pointee struct size and preserves field metadata for nested member access. (Fixed: pointer fields used to be sized as the pointee struct, and nested indexing lost the field array so the stride defaulted to 32.)
- **Struct arrays** (`struct Point pts[N];` with `pts[i].field` access)
- **Struct parameters** (`struct Point p` in function params, passed by pointer; caller passes `&s`)
- **Arrow operator** (`ptr->field` is syntactic sugar for `(*ptr).field`)
- **Indexed arrow access** (`ptr->field[i]`) — indexing into a struct pointer's field works when the field is a pointer type (e.g., `char*`); the field is loaded, then used as the base address for the index
- **Reliable member postfix parsing** — the parser preserves the base expression while consuming `.field` / `->field`, so member assignments after helper calls (for example `node->data2 = (int)name;`) keep the correct target base.
- **Global variables** (top-level `int g_x;`, `int g_arr[10];`, `struct { ... } g_s;`; also `struct Point g;`)
- **Dynamic program-level AST arrays** — the parser grows its persistent function/global declaration arrays as needed during multi-file compilation. It no longer silently drops globals after the initial 128-entry capacity.
- **Global variable initialization** (`int g_x = 42;`)
- **Struct variable initialization** (`struct Point p = { 10, 20 };`) including nested initializer lists for struct-typed fields (`struct Outer o = { { 1, 2 }, 3 };`)
- **Struct initialization with expression** (`struct Point p = make_point(3, 4);`) — when the initializer is a function call returning a struct, the compiler emits a struct copy from the return slot to the local variable
- **Struct return values** (`struct Point make_point(int x, int y) { ... return p; }`) — functions can return structs via a hidden pointer parameter (System V AMD64 ABI). The **caller** sets up a destination buffer (a 256-byte BSS slot `struct_ret_slot`) and passes it as the first argument in `rdi`. The **callee** stores the hidden return pointer in a reentrant stack slot `[rbp - 8]` (reserved before `collect_symbols`), copies the returned struct to wherever that pointer points, and returns normally. The `__struct_copy` runtime helper handles byte-wise copying of struct values between any two memory locations. The BSS-based caller approach does not support nested or recursive struct-returning function calls (the hidden pointer always points to the same global slot), but this trade-off avoids stack corruption from the `call __struct_copy` return address.
- **Struct pointer initialization** (`struct Point *p = &g;`) — address-of operator can initialize a struct pointer directly at declaration
- **C-style casts** (`(int)expr`, `(char)expr`) — cast syntax is recognized by the parser; treated as a no-op (returns the inner expression unchanged). Useful for documentation/readability and required for some expression contexts.
- **Nested function calls** — `add(add(1,2), add(3,4))` works correctly
- **String literals** — `"hello"` style string literals; stored in `.rodata` with `LC0`/`LC1`/etc. labels; expression result is a `char*` pointer; supports escape sequences `\n`, `\t`, `\\`, `\"`, `\'`, `\0`; embedded null bytes preserve full length (not truncated)
- **Bitwise operators** — `<<`, `>>`, `&`, `|`, `^` supported as binary operators in `parse_addition`
- **Bitwise NOT** — `~x` supported as a unary prefix operator (`TOK_TILDE`); compiles to a single `not rax` instruction. `~x` is its own inverse (`~~x == x`).
- **Logical AND/OR (short-circuit)** — `&&`, `||` supported as binary operators with precedence below equality (`==`, `!=`) and above bitwise OR (`|`). Implemented with proper short-circuit evaluation: `&&` only evaluates the right operand if the left is non-zero; `||` only evaluates the right operand if the left is zero. The result is always exactly 0 or 1 (boolean), unlike the previous bitwise implementation which could produce any integer.
- **Compound assignment** — `+=`, `-=`, `*=`, `/=`, `%=`, `<<=`, `>>=`, `&=`, `|=`, `^=` desugared to `a = a OP b` in the parser
- **Prefix and postfix increment/decrement** — `++a`, `--a`, `a++`, `a--` supported. Prefix returns the new value; postfix returns the old value (correct C semantics).
- **Hex literals** — `0x2A`, `0xFF` etc. parsed by lexer and converted in `parse_number_value`; supports upper and lowercase hex digits
- **`void` return with value rejected** — `void f() { return 42; }` produces a compile error
- **Forward declarations** — `int add(int a, int b);` followed by a later definition; calling before definition works
- **Error detection** — unknown characters, multi-char literals, lone `!`, unexpected tokens, and syntax errors are detected and reported with `file:line:col` and source line + caret; compilation aborts on error
- **Braces required on control flow** — all `if`/`else`, `while`, and `for` bodies must use `{ }`. Single-statement bodies without braces produce a compile error.
- **`else if` chains** — `if (a) {} else if (b) {} else if (c) {}` parses correctly. Implemented via recursive `parse_if_stmt` call after `else` when the next token is `if`. The nested `if` is wrapped in an `AST_BLOCK` so the outer `AST_IF` node has a uniform shape (`else_block` is always `AST_BLOCK*`).
- **`break` and `continue`** — `break;` exits the innermost loop; `continue;` skips to the next iteration. Supported in `while` and `for` loops.
- **Centralized error system** — all error messages live in `src/c2x-seed/errors.asm` with numeric error codes; `error_code()`/`error_at_code()` provide lookup from code to message string

See [Limitations](#limitations) for what is not yet implemented.

## Build & Run

```bash
make                    # build c2x-seed -> build/c2x-seed
./build/c2x-seed file.c2                   # compile file.c2 → a.out (ELF binary)
./build/c2x-seed file.c2 -S                # compile → NASM assembly to stdout
./build/c2x-seed file.c2 -o output         # compile → output (ELF binary)
./build/c2x-seed file1.c2 file2.c2 -o out  # multi-file compilation
./build/c2x-seed --verbose file.c2         # verbose debug output
./build/c2x-seed --emit-result file.c2     # compile with result printing (-r for short)
./build/c2x-seed --emit-returns file.c2    # every return in the binary prints its value (-e for short)
./build/c2x-seed --keep-asm -o out file.c2 # preserve the intermediate .asm file for debugging
make clean              # remove build artifacts
```

By default, the compiler produces an ELF binary (`a.out`). Use `-S` to output raw assembly to stdout instead (the version banner is printed to stderr, so the stdout stream is always valid nasm input). The `-o` flag specifies the output binary path. Use `--emit-result` (or `-r`) to have the generated binary print `main()`'s return value as decimal text to stdout before exiting — this avoids Linux exit-code mod-256 truncation. Use `--emit-returns` (or `-e`) to print every `return` value to stdout at runtime, one per line; useful for debugging and test validation. Use `--keep-asm` to preserve the intermediate `.asm` file (its path is printed to stdout) instead of deleting it after assembly — useful for inspecting generated code.

The compiler runs `nasm` and `ld` as subprocesses to produce the binary (includes a `_start` entry that calls `main` and exits). Temp files are created under `/tmp` using a per-process prefix such as `/tmp/c2x_build_<pid>.asm` and `/tmp/c2x_build_<pid>.o`, then cleaned up afterward (unless `--keep-asm` is given).

The toolchain: `nasm` (assembler) → `ld` (linker). No libc or external tools.

## Source Organization

Each module in `src/c2x-seed/` compiles to a separate `.o` file; all are linked together.

| File | Responsibility |
|------|---------------|
| `main.asm` | Entry point (`_start`), calls compiler pipeline stages |
| `syscalls.asm` | Linux syscall numbers, constants, wrapper functions |
| `memory.asm` | Bump allocator (10 MB heap), stack frame helpers |
| `types.asm` | Data type system and runtime helpers |
| `io.asm` | Buffered I/O, string utilities, file operations |
| `compiler.asm` | Compiler pipeline: init, main loop, cleanup |
| `lexer.asm` | Lexical analyzer: tokenizes source into tokens |
| `parser.asm` | Syntax analyzer: builds AST from token stream |
| `codegen.asm` | Code generator: emits x86_64 assembly from AST |
| `errors.asm` | Centralized error system: message strings, code→string lookup table, `error_code()`/`error_at_code()` functions |

## Data Types

All values are 64-bit; the architecture is x86_64 throughout.

| Type | ID | Size | Description |
|---|---|---|---|
| `void` | `TYPE_VOID = 0` | 0 | No value |
| `int` | `TYPE_INT = 1` | 8 bytes | 64-bit signed integer (universal workhorse) |
| `char` | `TYPE_CHAR = 2` | 1 byte | 8-bit signed integer (byte/ASCII). Generated loads and `char` function returns sign-extend to 64-bit `int` values. |
| `*` (pointer) | `TYPE_PTR = 3` | 8 bytes | 64-bit memory address |
| `[N]` (array) | `KIND_ARRAY = 2` | N × elem_size | Fixed-size array of base type |
| `struct { ... }` | `KIND_STRUCT = 3` | sum of fields | Aggregate of base type |

Pointer/array/struct types are encoded as `kind << 32 | pointee_type_id`:
- `KIND_BASE = 0`, `KIND_PTR = 1`, `KIND_ARRAY = 2`, `KIND_STRUCT = 3`
- Pre-encoded: `TYPE_ENC_INT`, `TYPE_ENC_CHAR`, `TYPE_ENC_CHAR_PTR`, `TYPE_ENC_INT_PTR`, `TYPE_ENC_VOID_PTR`

### Arrays

Arrays are fixed-size, declared as `int arr[10];` or `char buf[256];`. Elements are 64-bit (`int`) or 8-bit (`char`). Indexing uses `arr[i]` syntax:

```c
int arr[3];
arr[0] = 10;
arr[1] = 20;
arr[2] = arr[0] + arr[1];  // arr[2] = 30
return arr[2];
```

**Codegen:** Array base address is computed via `lea rax, [rbp-offset]`, index is scaled by element size (8 for `int`, 1 for `char`), then added. Store/load uses `mov [rbx], rax` or `mov [rbx], al`.

#### Multi-Dimensional Arrays (2D)

Two-dimensional arrays are supported with the standard C syntax `T arr[N][M]`:

```c
int grid[3][4];
grid[1][2] = 42;
int v = grid[1][2];  // v = 42
```

Internally, 2D arrays are stored in row-major order as a flat block of `N * M` elements. The parser stores `total_count = N * M` in the AST node's `data3` (for allocation) and stores `dim2 = M` in `data5` (shifted left by 2 to avoid colliding with the `VAR_CONST` flag bit).

The codegen packs both dimensions into the symbol's `extra` field as `dim1 | (dim2 << 32)`, where `dim1 = total_count / dim2`. When indexing `arr[i]` on a 2D array:

1. **Bounds check** uses `dim1` (the first dimension) — `i < N`.
2. **Stride** is `dim2 * elem_size` (e.g., `M * 8` for `int`) — so `arr[i]` computes `base + i * (M * elem_size)`.
3. **No load** — the first index returns the *address* of the row (like struct arrays), not a loaded value.
4. **gen_expr_type** is set to the element type (`TOK_KW_INT` / `TOK_KW_CHAR`), so the outer `[j]` index uses `elem_size` for its stride and loads the value.

This makes nested indexing `arr[i][j]` work naturally through the existing `AST_INDEX(AST_INDEX(arr, i), j)` AST structure. The outer `[j]` goes through the `.index_general` codegen path, which evaluates the inner `arr[i]` to get the row address, then scales `j` by `elem_size`.

Works for both local (stack-allocated) and global (BSS-allocated) 2D arrays of `int` and `char` types.

#### Variable-Length Arrays (VLAs)

Local arrays may use a runtime expression as the element count, producing a stack-allocated variable-length array:

```c
int x = 1;
int num[x + 2];        // VLA with 3 elements
num[0] = 10;
num[1] = 20;
num[2] = 30;
return num[0] + num[1] + num[2];  // → 60
```

**Parser** (`parser.asm`): When `[` is followed by a non-numeric token, the full expression is parsed as the size and stored in `AST_ARRAY_DECL.data3` (as an AST pointer). The `VLA_FLAG` bit (bit 0, value 1) is set in `data5` to distinguish VLAs from fixed arrays. The sentinel `r15 = -1` in the parser distinguishes VLA from 2D (where `r15 = dim2 ≥ 1`). VLAs cannot have a second dimension or brace initializers.

**Codegen** (`codegen.asm`):
- `collect_symbols`: For a VLA, reserves a 16-byte frame slot `{base_ptr, count}` (base at the more-negative offset, count at the less-negative offset = base_offset − 8). Sets `extra = −1` to mark the symbol as a VLA.
- `gen_stmt` `.array_decl`: When `VLA_FLAG` is set, evaluates the size expression, stores the count into the upper slot, computes `count * elem_size`, aligns to 16 bytes, `sub rsp, rax`, and stores the resulting `rsp` as the base pointer.
- **Indexing** (`.index_local_vla`): Loads the base pointer from the frame slot, loads the runtime count into `r9`, evaluates the index, performs a runtime bounds check (`index ≥ 0 && index < count`), then scales by element size (1 for char, 8 for int) and loads/stores through the base pointer.
- **Assignment** (`.ai_local_vla`): Same base/count/bounds flow, then stores the RHS value at `base + scaled_index`.
- **Address-of** (`.addr_index_local`): When `extra == −1`, loads the base pointer from the slot (like a pointer variable) instead of using `lea`.

Supported for `int` and `char` element types. Globals/static/extern arrays still require a constant size.

#### Array Initializers

Arrays can be initialized with a brace-enclosed list of expressions:

```c
int arr[5] = {10, 20, 30, 40, 50};
char buf[4] = {'A', 'B', 'C', 'D'};
```

`char` arrays can also be initialized directly with a string literal:

```c
char msg[6] = "hello";  // equivalent to {'h','e','l','l','o','\0'}
```

When a string literal is used as the initializer, `parse_array_init_list` detects the `TOK_STRING` token at the start and expands each character (including the implicit null terminator) into individual `AST_CHAR` expression nodes in the init list. If the array size is larger than the string length, remaining elements are zero-initialized. If the array size is smaller, extra characters are silently truncated (the array size determines how many bytes are stored).

The initializer list is parsed by `parse_array_init_list`, which creates an `AST_INIT_LIST` node (data1 = count, data2 = pointer array). The codegen iterates over the list and emits a store instruction for each element. Supported both for local arrays (stack-allocated via `gen_array_init`) and global arrays (emitted in `.data` section with `dq`/`db` directives). Struct array field initialization in brace-enclosed lists (`struct { int cells[3]; int x; } s = {10, 20, 30, 42};`) is handled by `gen_struct_init`, which uses a separate init counter on the stack to correctly map array field init values to their positions.

If the initializer list has fewer elements than the array size, the remaining elements are zero-initialized.

#### Runtime Bounds Checking

Every array access (`arr[i]` in expressions and assignments, including struct array fields like `s.cells[i]`) is bounds-checked at runtime. The codegen emits:

```nasm
cmp rax, 0          ; check negative index
jl .L_bounds_fail_N
mov rbx, count
cmp rbx, rax        ; check index >= count
jle .L_bounds_fail_N
jmp .L_bounds_ok_N
.L_bounds_fail_N:
    mov rdi, 1
    mov rax, 60     ; sys_exit(1)
    syscall
.L_bounds_ok_N:
```

Bounds checks are emitted by `emit_bounds_check(count)` after the index expression is evaluated but before the memory access. For struct array fields, the bounds check uses inline `cmp` instructions rather than a subroutine call: the index is compared against 0 and the element count (loaded from `gen_expr_array_count`), and a failing check calls `sys_exit(1)`. The element count is read from the field descriptor's `sub_array_ptr` (offset 24), which stores either the direct count (for scalar array fields) or a pointer to a heap-allocated info struct holding `[count, field_array_ptr]` (for struct array fields).

Out-of-bounds access causes the program to exit with code 1 via `sys_exit`.

### Structs

Structs are anonymous inline types with member declarations:

```c
struct {
    int x;
    int y;
    char tag;
} s;

s.x = 10;
s.y = 32;
s.tag = 'A';
return s.x + s.y;  // 42
```

Members are laid out sequentially. Each field is aligned to its natural alignment (8 bytes for `int` and pointer types, 1 byte for `char`). Struct total size is padded to a multiple of the maximum field alignment.

**Nested structs:** Struct fields can themselves be struct types:
```c
struct {
    int x;
    struct { int a; int b; } inner;
    int y;
} s;
s.inner.a = 10;      // chained member access
s.inner.b = 20;
return s.x + s.y;     // flat member access still works
```

Nested structs use a 32-byte field descriptor format: `[name_ptr, offset, type, sub_array_ptr]`. The `sub_array_ptr` points to the nested struct's own field descriptor array, enabling recursive field lookups for chained access like `s.inner.a`.

**Codegen:** Struct variable allocated as a single stack slot (total size). Member access computes `lea rax, [rbp - (struct_offset - field_offset)]`, then loads/stores with correct operand size (qword for int/ptr, byte for char). Chained member access computes the inner field's address, looks up the outer field in the inner struct's field array, and adds the outer offset before loading/storing.

**Array fields:** Struct fields can be arrays of scalar types (`char` or `int`):

```c
struct {
    char cells[10];
    int ptr;
} buf;

buf.cells[3] = 'Z';     // write to array field element
char c = buf.cells[3];  // read from array field element
```

The field descriptor stores the element count in `sub_array_ptr` (offset 24). The field type is encoded with `ARRAY_TYPE_FLAG` (`20000`) added to the base element type. Field size becomes `count × element_size`. When a member access path detects `ARRAY_TYPE_FLAG` on a field, it leaves the field's **address** in `rax` and sets `gen_expr_type = element_type + PTR_TYPE_FLAG`. The codegen's assign-index and read-index paths handle expression-based bases (e.g. `s.cells[i]`) by evaluating the base expression (which yields the field address), evaluating the index, scaling by element size (1 for char, 8 for int), computing the target address, and loading/storing with the correct operand width. RHS values are truncated to byte for char targets. The `gen_expr_type` is preserved in callee-saved `r14` between the base-eval and index-eval calls since it is a global variable that gets overwritten by every `gen_expr` invocation.

**Limitations:**
- Array fields of struct type are supported but with bounds checking (element count stored in a heap-allocated info struct alongside the field_array_ptr).
- Pointer element types (`int*`, `char*`) in array fields are supported.
- Bounds checking is fully implemented for array field accesses. The element count is read from the field descriptor's `sub_array_ptr` (offset 24), saved into `gen_expr_array_count`, and checked at runtime before each array index operation (`s.cells[i]`). Out-of-bounds access exits with code 1.
- Array field initialization in brace-enclosed lists (`struct { int cells[3]; int x; } s = {10, 20, 30, 42};`) is supported. The `gen_struct_init` codegen uses a separate init counter (on the stack) distinct from the field index (`r10`). Array fields consume `element_count` init values while advancing the field index by only 1; subsequent scalar fields read from the next init values.

**Named structs (v2):** Struct types can be named and reused:

```c
struct Point { int x; int y; };
struct Rect  { int x; int y; int w; int h; };

int main() {
    struct Point a;
    struct Point b;
    struct Rect  r;
    a.x = 3;  b.x = 5;
    r.h = 40;
    return r.h / b.x;  // 40 / 5 = 8
}
```

Named structs use a simple parallel-array registry (max 16 types) with three arrays: `named_struct_names` (tag name ptr), `named_struct_sizes` (total byte size), and `named_struct_fields` (field descriptor array ptr). Two helper functions manage the registry:

- `register_named_struct(rdi=name, rsi=size, rdx=field_array)` — adds a new type, increments count
- `find_named_struct(rdi=name)` → `rax=size, rcx=field_array` — linear search by tag name

**Syntax forms:**
1. `struct Name { fields... };` — type-only definition (registers type, no variable)
2. `struct Name { fields... } var;` — combined definition and variable
3. `struct Name var;` — variable of previously defined type (must be registered first)

All three forms work at both file scope (globals) and function scope (locals). Codegen allocates `resb total_size` for globals or stack space via `collect_symbols` for locals.

**Struct pointers:** Pointers to named structs are supported:
```c
struct Point { int x; int y; };
struct Point g;
struct Point *p;

int main() {
    p = &g;
    (*p).x = 10;
    (*p).y = 32;
    return (*p).x + (*p).y;  // 42
}
```

Member access through a pointer uses either `(*ptr).field` or the arrow operator `ptr->field` (both are equivalent). The arrow operator is handled in the parser by wrapping the base expression in a dereference (`*ptr`), then applying member access — the codegen sees the same AST as `(*ptr).field`. Chained access like `p->x.y` and mixed `p.x->y` are also supported. While parsing chained postfix member operations, the parser saves the base AST pointer across token-advance and token-copy helper calls because those calls may clobber caller-saved registers.

Global struct pointers require the `field_array_ptr` to be passed as the `extra` field in the symbol table — this is handled in both `register_globals` and `emit_global_vars`.

**Struct arrays:** Arrays of named structs are supported:
```c
struct Point { int x; int y; };
struct Point pts[3];

int main() {
    pts[0].x = 1;
    pts[0].y = 2;
    pts[1].x = 10;
    pts[1].y = 20;
    pts[2].x = 100;
    pts[2].y = 200;
    return pts[0].x + pts[0].y + pts[1].x + pts[1].y + pts[2].x + pts[2].y;
}
```

The parser recognizes `struct Name arr[N]` syntax and creates an `AST_ARRAY_DECL` node with the struct total_size in `data1`, element count in `data3`, and field_array_ptr in `data4`. Codegen allocates `resb (struct_size * N)` in BSS. Array indexing uses the struct's total size as the element stride. The struct's field array pointer is stored in the global symbol table's `extra` field, allowing `pts[i].field` to work by computing the element address, then applying field offset and loading/storing.

**Struct initialization:** Local struct variables can be initialized with a brace-enclosed list of expressions:

```c
struct Point { int x; int y; };
struct Point p = { 10, 20 };        // scalar fields
return p.x;                          // 10
```

For nested structs, braces nest to match the struct hierarchy:

```c
struct Inner { int a; int b; };
struct Outer {
    struct Inner inner;
    int c;
};
struct Outer o = { { 10, 20 }, 30 };
return o.inner.a + o.inner.b + o.c;  // 60
```

The initializer list is parsed recursively: each struct-typed field expects a nested `{ ... }` block. A trailing comma before `}` is optional, and extra fields beyond the number of initializers are left uninitialized (stack garbage — avoid relying on zero-init for local structs).

Codegen emits a `mov qword/byte [rbp-offset], value` for each leaf field, walking the field descriptor tree and accumulating offsets.

**Designated initializers:** Fields can be initialized by name using `.field = value` syntax. This works for both simple and nested struct fields, and supports out-of-order initialization:

```c
struct Point { int x; int y; };
struct Point p = {.y = 20, .x = 10}; // order doesn't matter
return p.x + p.y; // 30

struct Inner { int value; };
struct Outer { struct Inner inner; };
struct Outer o = {.inner.value = 42}; // nested designated init
return o.inner.value; // 42
```

Designated initializers are implemented via `AST_DESIGNATED_INIT` nodes (type 32) with `data1 = byte_offset` and `data2 = value_expression`. The parser accumulates offsets through nested `.field` lookups using `find_field_desc`. The codegen handles them in `gen_struct_init` (local) and `emit_global_vars.data_struct_init_node` (global) by using the stored byte offset directly. Global designated inits emit `.data` section entries with `dq` directives at the correct byte offsets.

**`const` keyword:** Variables can be declared with the `const` qualifier to mark them as immutable. Assignment to a const variable (after initialization) is a compile-time error:

```c
int main() {
    const int x = 42;
    return x; // 42
}

const int g = 100;

int main() {
    g = 200; // compile error: Cannot assign to const variable
    return g;
}
```

**Const struct fields** are also supported. A field declared `const` cannot be assigned after the struct is constructed (init lists remain valid):

```c
struct Point {
    const int x;   // leading const
    int const y;   // trailing const
    const char buf[8];
};

int main() {
    struct Point p = {10, 20}; // OK — initialization
    p.x = 99;                   // error: Cannot assign to const variable 'x'
    p.buf[0] = 'a';             // error: Cannot assign to const variable 'arr'
    p.y++;                      // error: Cannot assign to const variable 'y'
    return p.x;
}
```

Supported for `int`, `char`, pointer types (`int*`, `char*`), arrays, structs (whole-variable const), **per-field const inside struct bodies**, **type-level `const struct Name { ... }`** (marks every field of the registered type const so later `struct Name t; t.field = ...` fails), and function parameters. Works for both local and global variables. The const flag is stored in `AST_VAR_DECL.data4` (bit 1, `VAR_CONST = 2`), in `AST_ARRAY_DECL.data5` and `AST_STRUCT_DEF.data5` for arrays and structs. Struct field descriptors OR `FIELD_CONST_FLAG` (65536) into the field type; after a `const struct Name { ... }` definition the parser ORs that flag onto every field in the named type's field array. `find_field` strips the flag for normal type use and sets `find_field_is_const`. The codegen maintains separate `symbol_const` and `global_symbol_const` byte arrays to track which symbols are const. During `gen_assign` / post-inc / array index assign, const is checked for scalar (`AST_IDENT`), array element (`AST_INDEX`), and struct field (`AST_MEMBER`) accesses, and a compile error is emitted if violated. The error message includes the name (e.g., `Cannot assign to const variable 'x'`), reported via the `report_const_error` helper in `codegen.asm`.

**Struct parameters:** Function parameters of named struct types are supported. The struct is passed by pointer at the ABI level:
```c
struct Point { int x; int y; };

int sum(struct Point p) {
    return p->x + p->y;
}

int main() {
    struct Point pt;
    pt.x = 10;
    pt.y = 32;
    return sum(&pt);  // pass address of pt
}
```

The parameter type is encoded as `TOK_KW_STRUCT + PTR_TYPE_FLAG` with the `field_array_ptr` stored in `data3` so the codegen can resolve member accesses inside the function.

**Struct pointer returns:** Functions may return a pointer to a named struct (`struct Name *func(params) { ... }`). This is a plain pointer return (value in `rax`); it does **not** use the hidden struct-copy ABI that struct-value returns use. The parser's `parse_struct_def` detects `struct Name *...* name (` and routes to `parse_function` with the return type set to `TOK_KW_STRUCT + PTR_TYPE_FLAG` per pointer level. The codegen treats any return type whose low 16 bits differ from bare `TOK_KW_STRUCT` (i.e. with the pointer flag set) as a normal pointer return, so no hidden `[rbp-8]` slot is reserved and no `__struct_copy` is emitted.

```c
struct Node { int value; int next; };
struct Node g_a;

struct Node* pick(int which) {
    if (which == 0) { return &g_a; }
    return 0;
}

int main(void) {
    struct Node* p;
    p = pick(0);
    return p->value;
}
```

### Global Variables

Variables declared at file scope (outside any function) are global:

```c
int g_counter;
int g_buffer[256];
struct { int x; int y; } g_point;

int main() {
    g_counter = 42;
    g_point.x = 1;
    g_point.y = 2;
    return g_counter;  // 42
}
```

Globals reside in the `.bss` section (zero-initialized). Emitted as:
```nasm
section .bss
g_g_counter:  resq 1
g_g_buffer:   resq 256
g_g_point:    resb 16
```

Access uses absolute addressing: `mov rax, [g_g_counter]`, `lea rax, [g_g_point]`, etc. A separate global symbol table (`global_symbols`) tracks names, types, and extra info (array count, struct field array).

### Runtime Globals: `argc` and `argv`

The generated `_start` trampoline saves the kernel-provided `argc` and `argv` into global variables that C2X code can access via `extern`:

```c
extern int argc;
extern char** argv;

int main() {
    if (argc < 2) return 1;
    // argv[1] is the first argument
    return 0;
}
```

These globals are always emitted by the code generator in the BSS section (`g_argc` and `g_argv`) and initialized by the `_start` entry point before calling `main()`. No special flags are required.

**`main(int argc, char **argv)` style:** The `_start` trampoline also sets `rdi = argc` and `rsi = argv` before calling `main`, so standard C-style `main` signatures work directly:

```c
int main(int argc, char **argv) {
    if (argc < 2) return 1;
    return (int)argv[1][0];  // first char of first argument
}
```

The `char *argv[]` form is also accepted — in C, array notation in parameter declarations decays to a pointer, so `char *argv[]` is equivalent to `char **argv`:

```c
int main(int argc, char *argv[]) {
    if (argc < 2) return 1;
    return (int)argv[1][0];
}
```

**`main(void)` style:** The empty-parameter-list idiom `int main(void)` is supported — `void` as the sole parameter is parsed as "no parameters":

```c
int main(void) {
    return 42;
}
```

`void` followed by anything other than `)` (e.g., `void x`) is rejected as a syntax error.

**Example — HEXDUMP with `argc`/`argv`:** The enhanced `tests/c2x_seed_complex_tests/hexdump/test_hexdump.c2` demonstrates a full hexdump program that accepts a filename via `argv[1]`, handles missing arguments (prints usage to stderr, exits 1), missing files (exits 2), and empty files (exits 3). It reads the file in 16-byte chunks and produces output byte-identical to the C reference (`hexdump.c`). A test script (`test_hexdump_argv.sh`) exercises all five paths and compares against the C reference.

**Example — WORD-FREQ with hash tables and struct pointers:** The `tests/c2x_seed_complex_tests/word-freq/test_word_freq.c2` program (PROGRAM 2 from `rules.md`) demonstrates advanced features: self-referential structs (`struct HashNode { struct HashNode* next; }`), struct pointer fields, arrays of struct pointers (`struct HashNode* buckets[64]`), hash tables with djb2 hashing, dynamic memory via a bump allocator, and top-N selection. It reads a file from `argv[1]`, counts word frequencies, and prints the 10 most frequent words. A test script (`test_word_freq_argv.sh`) exercises all five paths (no args, small file, large file, missing file, empty file) and compares against the C reference (`word-freq.c`) using sorted output to handle hash-collision ties.

**Example — MATH-EVAL with recursive descent parser and struct returns:** The `tests/c2x_seed_complex_tests/math-eval/test_math_eval.c2` program (PROGRAM 3 from `rules.md`) demonstrates: recursive descent parsing (`parse_expr` → `parse_term` → `parse_factor`), named structs (`struct Token { int kind; int value; int pos; }`), struct return values (`struct Token next_token(void)`), multiple pointers (`char* input`, struct Token state), all arithmetic operators (`+`, `-`, `*`, `/`), hex literals (`0x00`-`0x05` for error codes), nested parentheses, and argc/argv handling. A test script (`test_math_eval_argv.sh`) exercises 17 scenarios including operator precedence, nested parens, whitespace handling, and error cases, comparing against the C reference (`math-eval.c`).

**Example — BASE64-ENCODE with file I/O and bitwise operations:** The `tests/c2x_seed_complex_tests/base64-encode/test_base64_encode.c2` program (PROGRAM 4 from `rules.md`) demonstrates: file I/O via syscalls (`syscall_open`, `syscall_read`, `syscall_write`, `syscall_close`), char arrays with character initialization, bitwise operations (`<<`, `>>`, `&`, `|`), hex literals (`0x3F` for 6-bit mask), loops (`while`), array indexing, and argc/argv handling. It reads a file in 3-byte chunks, combines them into a 24-bit integer, extracts four 6-bit values, maps to the base64 alphabet (`A-Z`, `a-z`, `0-9`, `+`, `/`), and pads with `=` for incomplete chunks. A test script (`test_base64_encode_argv.sh`) exercises 10 scenarios including 1/2/3 byte inputs, multi-chunk inputs, empty files, and binary data, comparing against the C reference (`base64-encode.c`).

**Example — BF-TO-ASM with brainfuck compilation:** The `tests/c2x_seed_complex_tests/bf-to-asm/test_bf_to_asm.c2` program (PROGRAM 5 from `rules.md`) demonstrates: brainfuck-to-assembly compilation, file I/O (read `.bf`, write `.s`), character-by-character processing, loop stack (array of loop IDs for nested loops), integer-to-string conversion (for unique label numbers), and argc/argv handling. It translates each brainfuck command to x86_64 assembly (`>` → `inc rbx`, `+` → `inc byte [rbx]`, `[` → `cmp byte [rbx], 0; je loop_end_N`, etc.) and generates a complete executable. A test script (`test_bf_to_asm_argv.sh`) exercises 5 brainfuck programs (single increment, multi increment, simple loop, Hello World, nested loops), assembles both C2X and C reference outputs with `nasm`, links with `ld`, and verifies the resulting binaries produce identical output.

### String Literals

String literals (e.g., `"hello"`) are parsed by the lexer and stored as `AST_STRING` nodes with the string content on the heap. The code generator emits them in a `.rodata` section:

```c
int main() {
    char* s = "hello";
    return *s;  // returns 'h' = 104
}
```

Each unique string literal gets a label in the form `LC0`, `LC1`, etc. The codegen maintains a string pool (up to 64 entries) that collects string pointers and lengths during `gen_expr`. After all function code is generated, the codegen emits a `.rodata` section with the pooled string data:

```nasm
section .rodata
LC0:
    db 104, 101, 108, 108, 111, 0     ; "hello"
LC1:
    db 119, 111, 114, 108, 100, 0     ; "world"
```

The expression `"hello"` evaluates to a `char*` pointer (address of the string in `.rodata`). Dereferencing (`*s` or `*("hello")`) loads the first byte using `movzx rax, byte [rax]`.

**Escape sequences** supported by the lexer: `\n` (newline, byte 10), `\t` (tab, byte 9), `\\` (backslash), `\"` (quote), `\'` (single quote), `\0` (null byte). Strings are null-terminated in `.rodata`.

**Full-length preservation:** The full string length (including embedded null bytes) is preserved by storing `token_len` in `AST_STRING.data2` during parsing. The codegen reads this stored length instead of recomputing via `strlen`, so strings like `"ab\0cd"` are emitted with all 6 bytes (`a`, `b`, `\0`, `c`, `d`, trailing `\0`) in `.rodata`. The string pool emits raw bytes up to the stored length, followed by the terminator.

### Pointer types

Pointer types are declared with `int* p` or `char* p` syntax. The type is encoded internally as `PTR_TYPE_FLAG (10000) + base_token`, e.g. `int*` = 10050, `char*` = 10051. Pointer variables are 8 bytes and can be initialized with `&var` or `&arr[i]`.

**Pointer arithmetic:**
- `ptr + n` → advance by `n * sizeof(pointee)` bytes
- `n + ptr` → commutative
- `ptr - n` → retreat by `n * sizeof(pointee)` bytes  
- `ptr1 - ptr2` → element offset (integer result)

Example:
```c
int arr[4] = {10, 20, 30, 40};
int* p = &arr[0];
int* q = p + 2;     // q = &arr[2]
int diff = q - p;   // diff = 2
return *(p + 1);    // returns 20
```

### Functions with Parameters

Functions can have up to 127 parameters. Each parameter is declared with a `type name` pair, following the same type rules as local variables (including pointer types with `*`):

```c
int add(int a, int b) {
    return a + b;
}

int sum4(int a, int b, int c, int d) {
    return a + b + c + d;
}

int main() {
    return add(14, 28);                   // returns 42
}
```

**Calling convention** matches x86_64 System V AMD64:
- First 6 integer/pointer parameters: `rdi`, `rsi`, `rdx`, `rcx`, `r8`, `r9`
- Parameters 7+: pushed on the stack (rightmost first)
- Return value: `rax` (64-bit), `al` (8-bit for `char`)

**Callee codegen** (`register_params` + `emit_param_copy` in `codegen.asm`):
- Parameters are registered as local symbols with negative `rbp` offsets, just like local variables
- After the frame is allocated (`sub rsp, frame_size`), the callee emits copies from ABI registers to frame slots:
  ```nasm
  mov qword [rbp-16], rdi      ; param 0 (a)
  mov qword [rbp-24], rsi      ; param 1 (b)
  ; ... for params 6+:
  mov rax, [rbp+16]            ; param 6 (first stack arg)
  mov qword [rbp-56], rax
  ```
- `char` parameters use `mov byte [rbp-Off], dil` / `sil` etc.

**Caller codegen** (`gen_call`):
- Arguments are evaluated right-to-left (for stack ordering), each pushed:
  ```nasm
  mov rax, 28
  push rax
  mov rax, 14
  push rax
  pop rdi        ; first arg
  pop rsi        ; second arg
  call add
  add rsp, 0    ; (no stack args to clean up)
  ```
- For more than 6 args, the remaining values stay on the stack (in the correct positions for the ABI) and are cleaned up with `add rsp, (N-6)*8` after the call.

**Nested calls** work correctly — `add(add(1,2), add(3,4))` evaluates each argument expression in turn, which may themselves be function calls with their own argument setup.

### Inline Assembly (`asm()`)

C2X-seed provides a built-in `asm()` function that allows embedding raw x86_64 assembly instructions directly into generated code. This is essential for low-level operations (register manipulation, syscalls, etc.) that cannot be expressed in C2X. Unlike GCC's extended asm, C2X-seed's implementation is simple but functional.

**Syntax:**
```c
asm("template" [, var [, var...]]);
```

The first argument is a template string containing assembly instructions. Additional arguments are C2X variable references whose stack addresses are substituted into the template via `%0`, `%1`, etc.

**Basic Example (no operands):**
```c
int main() {
    int x;
    asm("    mov qword [rbp-8], 42");
    return x;  // returns 42
}
```

**With Operand Substitution:**
```c
int main() {
    int x;
    asm("mov qword %0, 42", x);   // %0 → [rbp-8]
    return x;  // returns 42
}
```

**Multiple Operands:**
```c
int main() {
    int a = 10;
    int b = 20;
    int c;
    asm("mov rax, %0\n add rax, %1\n mov %2, rax", a, b, c);
    return c;  // returns 30
}
```

**Template Substitution Rules:**
- `%0`, `%1`, ..., `%9` — replaced with the corresponding operand's `[rbp-offset]` address. The first extra arg is `%0`, the second is `%1`, etc.
- `%%` — emits a literal `%` character.
- Any other `%X` sequence — emits the `%` and `X` verbatim.
- Operand variables must be local variables (the compiler looks them up in the local symbol table).

**How it works:**
1. The parser registers `"asm"` as a known function name during initialization.
2. `asm(...)` is parsed as a normal function call (`AST_CALL` node) with a string literal as the first argument and optional variable references as subsequent arguments.
3. The code generator detects `"asm"` in `gen_call` and intercepts before normal argument evaluation:
   - The template string is extracted from the first arg.
   - Each operand variable name is looked up in the local symbol table to find its `[rbp-offset]`.
   - The template is processed character-by-character, substituting `%N` references with the variable's address.
4. No `call` instruction is emitted — the modified template is written verbatim to the output.

**Limitations:**
- Both local and global variables are supported as operands. Global variables are emitted as `g_name` references rather than `[rbp-offset]` addresses.
- No register constraints or clobber lists — the user must choose registers compatible with the surrounding code.
- No output/input distinction — operands are all treated as memory references (`[rbp-offset]` for locals, `g_name` for globals).
- Function calls use the full System V AMD64 register + stack argument ABI (first 6 in registers, remainder on the stack).

**Codegen implementation** (`codegen.asm`):
The `asm_rbp_prefix` string `"[rbp-"` is concatenated with the operand's positive offset (via `emit_int`) and a closing `"]"` to form the address reference. The template scanner is a simple character loop with a `%` escape handler.

### Runtime Helpers

The generated binary automatically includes a small set of runtime helpers:

- **`g_argc`** / **`g_argv`** (BSS globals) — `argc` and `argv` saved from the kernel's process stack before calling `main()`. Access via `extern int argc; extern char** argv;`.
- **Syscall wrappers** (`.text` functions) — 5 syscall wrappers are emitted as global functions, callable via `extern`:
  - `extern int syscall_read(int fd, char* buf, int count);` — `SYS_read` (0)
  - `extern int syscall_write(int fd, char* buf, int count);` — `SYS_write` (1)
  - `extern int syscall_open(char* path, int flags, int mode);` — `SYS_open` (2)
  - `extern int syscall_close(int fd);` — `SYS_close` (3)
  - `extern int syscall_exit(int code);` — `SYS_exit` (60), does not return

**Type queries** (in `types.asm`):
- `type_size(type_id)` → size in bytes
- `type_align(type_id)` → alignment requirement
- `type_is_integer(type_id)` → 1 if `int` or `char`
- `type_is_pointer(encoded_type)` → 1 if pointer or array kind
- `type_get_pointee(encoded_type)` → pointee base type

**Value conversion** (in `types.asm`):
- `sign_extend_char` / `zero_extend_char` — 8→64 bit
- `truncate_int_to_char` — 64→8 bit (low byte)

**Pointer arithmetic** (in `types.asm`):
- `ptr_add(base, index, elem_size)` → `base + index * elem_size`
- `ptr_diff(ptr1, ptr2, elem_size)` → element offset

**Memory access** (in `types.asm`):
- `deref_int(ptr)`, `deref_char(ptr)`, `deref_ptr(ptr)` — load
- `store_int(ptr, val)`, `store_char(ptr, val)`, `store_ptr(ptr, val)` — store

## Memory Model

| Region | Mechanism | Size |
|---|---|---|
| **Heap** | Bump allocator (static array `heap_base`) | 10 MB |
| **Stack** | x86_64 `rsp`/`rbp` with frame helpers | Runtime |
| **Static** | `.data` / `.bss` sections | Linker-managed |

### Bump Allocator API

```asm
call heap_init         ; set heap_ptr = heap_base
mov rdi, size
call heap_alloc        ; rax = pointer (or 0 on OOM)
mov rdi, size
call heap_alloc_zero   ; same, but zero-filled
```

### Stack Frame Helpers

```asm
call frame_push        ; save rbp, set up new frame
mov rdi, size
call frame_alloc       ; rax = rsp-relative pointer
call frame_pop         ; restore previous frame
```

### Memory Utilities

```asm
mov rdi, ptr
mov rsi, size
call mem_zero          ; zero-fill

mov rdi, dst
mov rsi, src
mov rdx, size
call mem_copy          ; byte copy
call mem_eq            ; rax = 0 if equal, 1 if different
```

## I/O System

### Output Buffer (for code generation)

Characters are buffered into a 64 KB array (`out_buffer`) before being written to stdout:

```asm
call out_init               ; reset pointers
mov dil, char
call out_write_char         ; single character
mov rsi, string_ptr
call out_write_string       ; null-terminated string
mov rsi, string_ptr
mov rdx, length
call out_write_string_len   ; length-prefixed string
call out_write_newline      ; '\n'
mov rdi, int_value
call out_write_int          ; decimal (signed)
call out_write_hex          ; "0x" + 16 hex digits
call out_flush              ; flush buffer to stdout
```

### Input Buffer (for source reading)

Files are read through an 8 KB buffer (`in_buffer`):

```asm
mov rdi, fd
call in_init                ; attach file descriptor
call in_get_char            ; al = next char (ZF set on EOF)
call in_peek_char           ; al = next char without consuming
call in_skip_char           ; consume current char
```

### File Operations

```asm
mov rdi, path
call file_open_read          ; rax = fd (or negative error)
call file_open_write         ; rax = fd, creates/truncates file
mov rdi, fd
call file_close              ; close fd
```

## Syscall Wrappers

All Linux x86_64 syscalls used by the compiler, defined in `syscalls.asm`:

| Wrapper | Syscall | Arguments |
|---|---|---|
| `sys_exit` | 60 | `rdi = code` |
| `sys_read` | 0 | `rdi=fd, rsi=buf, rdx=count` |
| `sys_write` | 1 | `rdi=fd, rsi=buf, rdx=count` |
| `sys_open` | 2 | `rdi=path, rsi=flags, rdx=mode` |
| `sys_close` | 3 | `rdi=fd` |
| `sys_brk` | 12 | `rdi=addr` |
| `sys_mmap` | 9 | 6 args per x86_64 convention |

Closedir flags: `O_RDONLY=0`, `O_WRONLY=1`, `O_RDWR=2`, `O_CREAT=64`, `O_TRUNC=512`.

## Calling Convention (System V AMD64)

- Arguments (up to 6): `rdi, rsi, rdx, rcx, r8, r9`
- Return: `rax` (64-bit) or `al` (8-bit)
- Callee-saved: `rbx, rbp, r12–r15`
- Caller-saved: `rax, rcx, rdx, rsi, rdi, r8–r11`
- Stack alignment: 16 bytes at `call`

## Compiler Pipeline

The pipeline is wired in `compiler.asm`:

```
compiler_init     → heap init, output buffer init, startup banner
compiler_main     → open source file, lex → parse → codegen → emit
compiler_cleanup  → flush output, close files
```

### Lexer (`lexer.asm`)

The lexer tokenizes C2X source code into a stream of tokens. Each call to `lexer_next_token()` advances through the input one token at a time.

**Token types and their numeric IDs:**

| Category | Token IDs | Examples |
|---|---|---|
| Special | `TOK_EOF = 0` | End of file |
| Literals | `TOK_IDENT = 1`, `TOK_NUMBER = 2`, `TOK_STRING = 3`, `TOK_CHAR = 4` | `main`, `42`, `"hello"`, `'x'` |
| Arithmetic | `TOK_PLUS = 10`, `TOK_MINUS = 11`, `TOK_STAR = 12`, `TOK_SLASH = 13`, `TOK_PERCENT = 14` | `+`, `-`, `*`, `/`, `%` |
| Bitwise | `TOK_LSHIFT = 15`, `TOK_RSHIFT = 16`, `TOK_PIPE = 47`, `TOK_XOR = 48`, `TOK_TILDE = 49`, `TOK_AND = 82`, `TOK_OR = 83` | `<<`, `>>`, `\|`, `^`, `~`, `&&`, `\|\|` |
| Comparison | `TOK_EQ = 20`, `TOK_EQEQ = 21`, `TOK_NEQ = 22`, `TOK_LT = 23`, `TOK_LE = 24`, `TOK_GT = 25`, `TOK_GE = 26` | `=`, `==`, `!=`, `<`, `<=`, `>`, `>=` |
| Delimiters | `TOK_LPAREN = 30`, `TOK_RPAREN = 31`, `TOK_LBRACE = 32`, `TOK_RBRACE = 33`, `TOK_LBRACKET = 34`, `TOK_RBRACKET = 35` | `(`, `)`, `{`, `}`, `[`, `]` |
| Punctuation | `TOK_SEMI = 40`, `TOK_COMMA = 41`, `TOK_COLON = 42`, `TOK_ARROW = 43`, `TOK_AMPERSAND = 44`, `TOK_NOT = 46` | `;`, `,`, `:`, `->`, `&`, `!` |
| Keywords | `TOK_KW_INT = 50`, `TOK_KW_CHAR = 51`, `TOK_KW_IF = 52`, `TOK_KW_ELSE = 53`, `TOK_KW_WHILE = 54`, `TOK_KW_RETURN = 55`, `TOK_KW_VOID = 56`, `TOK_KW_STRUCT = 57`, `TOK_KW_EXTERN = 58`, `TOK_KW_FOR = 59`, `TOK_KW_BREAK = 60`, `TOK_KW_CONTINUE = 61` | `int`, `char`, `if`, `else`, `while`, `for`, `break`, `continue`, `return`, `void`, `struct`, `extern` |

**Lexer state** (exported as `lexer_state` for parser access):

| Offset | Field | Description |
|---|---|---|
| 0 | `current_char` | Current lookahead character (0 = EOF) |
| 8 | `line` | Current line number (1-based) |
| 16 | `column` | Current column number (0-based) |
| 24 | `tok_type` | Type of the most recently recognized token |
| 32 | `tok_buf[256]` | Buffer holding the token text (null-terminated) |
| 288 | `tok_len` | Length of token text in `tok_buf` |
| 296 | `tok_line` | Line where the token started |
| 304 | `tok_col` | Column where the token started |

Features:
- Line and block comments: `// ...` and `/* ... */`
- String literals with escape sequences: `\n`, `\t`, `\\`, `\"`, `\'`, `\0`
- Character literals: `'a'`, `'\n'`, etc.
- Single- and multi-character operator scanning (`==`, `!=`, `<=`, `>=`, `->`)

### Code Generator (`codegen.asm`)

The code generator walks the AST and emits x86_64 NASM assembly. It is organized as a set of mutually recursive `gen_*` functions following the AST node types.

**Key functions:**

| Function | Input (`rdi`) | Output | Description |
|---|---|---|---|
| `gen_program` | `AST_PROGRAM*` | — | Iterates functions, calls `gen_function` for each |
| `gen_function` | `AST_FUNC_DEF*` | — | Prologue, calls `collect_symbols`, `register_params` (adds params to symbol table), emits `sub rsp, frame_size`, `emit_param_copy` (copies ABI regs/stack to frame slots), then body (`gen_block`), epilogue |
| `collect_symbols` | `AST_BLOCK*` | Updates `symbol_count`, `frame_size` | Walks block, registers `VAR_DECL` in symbol table, computes frame layout |
| `register_params` | `param_array*` | Updates `symbol_count`, `frame_size` | Iterates parameter list from AST_FUNCTION.data4, allocates frame slots, adds each param as a local symbol |
| `gen_block` | `AST_BLOCK*` | — | Iterates statements; delegates to `gen_var_decl`, `gen_assign`, `gen_return`, `gen_if`, `gen_while`, `gen_expr`. Dead-code tracking is scoped so an early return inside an `if` body does not suppress later reachable statements in the enclosing block. |
| `gen_var_decl` | `AST_VAR_DECL*` | — | Looks up offset via `find_symbol`, emits `mov qword/byte [rbp-offset], rax/al` |
| `gen_assign` | `AST_ASSIGN*` | — | Evaluates RHS, stores to LHS (supports `AST_IDENT` and `*expr` dereference on LHS) |
| `gen_return` | `AST_RETURN*` | — | Evaluates return expression into `rax` (if any). Epilogue is emitted by `gen_function` |
| `gen_if` | `AST_IF*` | — | Emits `cmp`/`je`/`jmp` with `.L_else_N`/`.L_end_N` labels |
| `gen_while` | `AST_WHILE*` | — | Emits `.L_begin_N`/`.L_end_N` loop labels |
| `gen_expr` | AST expression node | `rax` | Dispatches on expression type (number, char, ident, binary, unary). Unary supports `-`, `!`, `~` (bitwise NOT), `*` (dereference), `&` (address-of). |
| `gen_binary` | `AST_BINARY*` | `rax` | Pushes left, evaluates right, pops left, applies operator |
| `gen_call` | `AST_CALL*` | — | Evaluates arguments right-to-left, pushes results, pops first 6 into regs, emits `call`; cleans up stack args after call |

**Symbol table:** Stored as an array of 40-byte entries (local) and a parallel global table:

| Offset | Field | Description |
|---|---|---|
| 0 | `name_ptr` | Pointer to variable name string |
| 8 | `name_len` | Length of name (for comparison) |
| 16 | `offset` | Negative offset from `rbp` (local); 0 for global |
| 24 | `type` | Token type (`TOK_KW_INT` = 50, `TOK_KW_CHAR` = 51, `TOK_KW_STRUCT` = 57) |
| 32 | `extra` | Array element count, or struct field-array pointer |

`collect_symbols` is called once per function before code generation. It walks the AST block, finds all `VAR_DECL`, `ARRAY_DECL`, and `STRUCT_DEF` nodes, and `add_symbol`s them, computing `frame_size` as the sum of variable sizes. Global variables are registered in `global_symbols` during `emit_global_vars` (called after function codegen). `find_symbol` searches local table; `find_global_symbol` searches global table. Both do string comparison via `mem_eq` (length + content).

**Stack frame layout:**
```
        High addresses
        +-------------+
        | return addr |  (pushed by `call`)
        +-------------+
  rbp → | saved rbp   |  (pushed by prologue)
        +-------------+
        | var N       |  (highest offset, e.g. rbp-9 for char c)
        | ...         |
        | var 1       |  (lowest offset, e.g. rbp-8 for int x)
  rsp → +-------------+
        Low addresses
```

**Global variables** reside in `.bss` (linker-zeroed). Accessed via absolute addressing:
- `mov rax, [g_name]` — load int
- `movzx rax, byte [g_name]` — load char
- `mov [g_name], rax` — store int
- `lea rax, [g_name]` — address of global (for arrays/structs)

## Example: Arrays, Structs, Globals

```c
int g_counter;
int g_buffer[4];

struct {
    int x;
    int y;
} g_point;

int main() {
    int arr[3];
    struct { int a; int b; } s;
    
    arr[0] = 1; arr[1] = 2; arr[2] = 3;
    s.a = 10; s.b = 20;
    g_point.x = 100; g_point.y = 200;
    g_counter = 42;
    g_buffer[0] = g_counter;
    
    return s.a + s.b + g_point.x + g_point.y + arr[1] + g_buffer[0];  // 10+20+100+200+2+42 = 374
}
```

Output (abridged):
```nasm
section .bss
g_g_counter:  resq 1
g_g_buffer:   resq 4
g_g_point:    resb 16

section .text
global _start
_start:
    call main
    mov rdi, rax
    mov rax, 60
    syscall
; With --emit-result, _start prints rax as decimal text to stdout first

global main
main:
    push rbp
    mov rbp, rsp
    sub rsp, 49          ; 3*8 + 16 + 8 + 9 (struct + array + int + char padding)
    ...
    mov rax, 1
    mov qword [rbp-8], rax      ; arr[0]
    mov rax, 2
    mov qword [rbp-16], rax     ; arr[1]
    ...
    mov rax, 100
    mov qword [g_g_point], rax  ; g_point.x
    mov rax, 200
    mov qword [g_g_point+8], rax ; g_point.y
    ...
    mov rax, 374
    mov rsp, rbp
    pop rbp
    ret
```

## Limitations

| Limitation | Details |
|---|---|
| **Forward declarations** | `int f();` syntax supported; functions can be called before their definition. |
| **Increment/decrement** | Both prefix `++a`/`--a` and postfix `a++`/`a--` are supported. Prefix returns the new value; postfix returns the old value (correct semantics). |
| **Struct padding** | Fields aligned to natural alignment (int/ptr = 8, char = 1). Tail padding to max alignment. |
| **Pointer arithmetic** | `ptr + n`, `ptr - n`, `ptr1 - ptr2` supported. Declare with `int* p`. |
| **Assign via dereference** | `*ptr = val` works (writable). |
| **Global init** | `int g_x = 42;` supported at top level. |
| **Global vars** | Single and multiple globals work; assign, read, and member access tested. |
| **Struct pointers** | `struct Name *p;` with `(*p).field` and `p->field` access works for locals and globals. |
| **Struct arrays** | `struct Name arr[N]` with `arr[i].field` access works for globals. Local struct arrays also supported. |
| **Variable-length arrays (VLA)** | `int n = 5; int a[n];` or `int a[x + 2];` — runtime-sized local arrays allocated on the stack. Supported for `int` and `char` elements. 16-byte frame slot `{base_ptr, count}`; runtime bounds checking against the stored count. No brace init or 2D. |
| **Struct array fields** | `struct { char cells[10]; int* ptrs[5]; }` — array fields inside structs. `char`, `int`, and pointer element types supported. Access via `s.cells[i]` for both read and write. Bounds checking enforced at runtime. Struct array fields (`struct S inners[N]`) also supported with a heap-allocated info struct storing `[element_count, field_array_ptr]`. |
| **Struct params** | `struct Name p` in function parameters works (passed by pointer; caller passes `&s`). |
| **Struct pointer returns** | `struct Name *func(params) { ... }` is supported as a plain pointer return (no hidden struct-copy ABI). `parse_struct_def` detects `struct Name *name(` and routes to `parse_function`. |
| **Error recovery** | Lexer/parser errors are counted; compilation aborts after parse phase. |
| **Error messages** | `file:line:col: error: message` format with source line and caret (`^`) highlight. Messages: `Expected ';'`, `Expected '}'`, `Unexpected token`, `Unexpected character`, etc. |
| **Nested named structs** | `struct Inner y;` in named struct bodies works. Chained access `s.y.a` and `s.y.b` works for both read and write. |
| **`extern` keyword** | `extern int x;`, `extern int arr[N];`, `extern int func();` — declares a symbol defined in another translation unit. No storage emitted for extern globals. |
| **`for` loops** | `for (init; cond; incr) { body }` uses a dedicated `AST_FOR` node with `init`/`cond`/`incr`/`body` sub-nodes. `continue` jumps to the increment (correct C semantics), `break` jumps to just after the loop. Init can be empty, an expression, or a variable declaration (`int i = 0`). Condition is optional (defaults to `1` = infinite loop). Increment is optional. Assignment (`=`, `+=`, etc.) in init and increment is handled. |
| **Braces required** | All `if`/`else`, `while`, and `for` bodies **must** use braces (`{ }`). Single-statement bodies without braces produce a compile error. |
| **`break`/`continue`** | `break;` exits the innermost loop, `continue;` jumps to the next iteration. Works in both `while` and `for` loops. Nested loops supported via global loop-label save/restore. |
| **Multi-file compilation** | Multiple `.c2` files accepted on command line. Parser accumulates functions and globals across files using persistent registries. |
| **Dynamic statement arrays** | `parse_block` allocates a growing pointer array for block statements: starts at capacity 32, doubles on overflow, copies old entries. No hard limit on statements per block. |
| **Nested member chains** | Chained access through struct-typed fields works for any depth (`b.a.x`, `c.b.a.x`) and for index-rooted chains (`o[i].inner.a`). Struct-typed field reads yield the field *address* (struct value semantics), and the address-of/index paths recurse through a shared `gen_addr` helper. |

## Recent Bug Fixes (harmony-base bring-up)

These c2x-seed defects were found and fixed while bootstrapping `harmony-base`.
Each has a regression case under `tests/c2x-seed/cases/` (run `make test-seed`).

| Bug | Symptom | Fix |
|---|---|---|
| **Binary-expression index on a struct-field pointer** | `s.p[i + 2]` failed to parse (`Expected ']'`), while `s.p[i]` and `arr[i + 2]` worked. | The two postfix-index parser paths used `parse_unary` for the index expression, which cannot parse binary operators. Changed both to `parse_expression`. |
| **Local struct arrays** | `struct Point pts[3];` segfaulted the compiler — even the documented example. | `collect_symbols` registered `extra = element count` for struct arrays, but the index handler needs `extra = field_array_ptr`, so it dereferenced a small integer. Struct-array registration now stores the field-array pointer in `extra`, and `.index_scale_struct` uses `rbx` (the field array on every path) instead of `r13`. |
| **Address of a struct-array field through a pointer** | `&r->spans[0]` segfaulted the compiler. | `gen_expr`'s `.addr_index` path assumed the operand was `ident[index]`, misread the `AST_MEMBER` base, and dereferenced garbage. It now detects a non-ident base and evaluates it via `gen_addr`. |
| **Nested struct member reads/writes** | `b.a.x` read the wrong slot, deeper chains (`c.b.a.x`) returned garbage, and index-rooted chains (`o[i].inner.a`) crashed. | Struct-typed member reads now keep the field address instead of loading a scalar; chained member access is routed through a new recursive `gen_addr` helper that computes the address of any lvalue (`IDENT`, `MEMBER`, `INDEX`, `*ptr`). Both read and assign paths use it. |
| **Global struct arrays of array-bearing structs** | Emitted `g_g_name` (doubled prefix) and failed assembly. | The general index-address path now runs the name through `strip_g_prefix`, matching the other emit paths. |
| **Type-flag collision on double pointers** | `struct N**` encoded as `57 + 2*PTR_TYPE_FLAG = 20057 = ARRAY_TYPE_FLAG + TOK_KW_STRUCT`, so a double pointer was classified as a struct array and crashed `struct_total_size`. | `ARRAY_TYPE_FLAG` raised above every reachable pointer encoding (`1<<28`; pointer depth is additive, so any depth-`d` pointer is `base + d*PTR_TYPE_FLAG`) and `FIELD_CONST_FLAG` moved to a distinct high bit. |
| **Pointer-to-struct member/index metadata** | `pp[i]->field` and `l->items[i]->kind` dropped stores / returned garbage: pointer depth ≥ 2 lost the pointee's field array, and pointer-element indexing skipped the ×8 scale. | A depth-agnostic `type_base_is_struct` helper now drives symbol registration, member metadata, and index scaling (everything except `char` scales by 8); `.index_loaded` propagates the pointee field array to chained access. |
| **Forward struct references** | `struct A { struct B* b; };` with `B` defined later failed to parse, so mutually recursive types were impossible. | A pointer field may now name an undefined struct: the parser registers a placeholder and records the field descriptor's `sub_array_ptr` slot; when the struct is defined, `fwd_ref_patch` fills in every pending slot. Self-reference pre-registration reuses the placeholder slot instead of duplicating it. |
| **Non-deterministic output binaries** | Two `-o` builds of the same source produced binaries differing in `.strtab`: c2x-seed wrote the temp assembly to a PID-unique path (`/tmp/c2x_build_<pid>.asm`), passed that path to nasm, and nasm recorded it as the object's `FILE` symbol, which `ld` copied into the executable. | The temp `.asm` is still written (so `--keep-asm` works), but nasm now reads it from a stable name: the compiler opens the temp file read-only and `dup2`s the fd onto the child's stdin, passing `/dev/stdin` as nasm's input argument. Added a `sys_dup2` wrapper and an optional `rcx` stdin fd to `run_and_wait`. Covered by `tests/c2x-seed/determinism.sh`. |
| **Compiler crash on an undeclared indexed/address-of name** | Any `x[i]`, `&x[i]`, `&x`, or `x[i] = v` where `x` is not a declared local or global (e.g. a typo, or code the resolver has not yet rejected) segfaulted the compiler in codegen — even `int main(void) { return g_buf[0]; }` on its own. | The index/address-of fast paths pushed the base name pointer, then jumped to the shared epilogue without popping it when the name was not found, so the codegen operand stack grew on every such node until later stages read off the end. Each not-found path now pops the pointer, emits nothing, and yields 0 — matching `.ident`'s existing not-found path. Covered by `tests/c2x-seed/cases/undeclared_index_no_crash.c2`. |

## External Declarations

Variables and functions can be declared `extern` to indicate they are defined in another translation unit:

```c
extern int shared_val;
extern int shared_arr[16];
extern int get_value();
```

An `extern` declaration reserves the name in the compiler's global symbol table but does **not** allocate storage (storage is emitted only where the variable is defined without `extern`).

**Supported syntax:**
- `extern int name;` — external scalar variable
- `extern int name[N];` — external array variable
- `extern type name(params...);` — external function forward declaration (existing forward-decl support)

**Codegen:** The AST node's `data4` field is set to `1` for extern declarations. In `emit_global_vars`, extern declarations emit an `extern g_<name>` directive (instead of BSS/data storage) so the assembler and linker resolve the symbol. The symbol is registered in the compiler's global symbol table so variable references in the function body generate correct `g_<name>` load/store instructions.

## Multi-file Compilation

Multiple source files can be passed on the command line; the parser accumulates functions and globals across all files:

```bash
./build/c2x-seed -o program lib.c2 main.c2
```

**Implementation:**
- `parser_init` allocates persistent function/global arrays and zeroes counts.
- `parser_parse_program` loads persistent arrays into registers, parses top-level declarations.
- After the first file, arrays and counts are saved to `prog_func_count/array`, `prog_global_count/array`.
- For subsequent files, `parser_reinit` resets lexer/parser token state but preserves registries.
- After all files, a single `AST_PROGRAM` is handed to codegen.

**Compiler loop:**
```nasm
.init_source_loop:
    xor r15, r15
.source_loop:
    ; open file, init input ...
    test r15, r15
    jnz .source_reinit
    call parser_init
    jmp .source_parse
.source_reinit:
    call parser_reinit
.source_parse:
    call parser_parse_program
    ; close file ...
    inc r15
    cmp r15, [source_count]
    jl .source_loop
```

**Persistent state:**
```asm
prog_func_count    resq 1    ; accumulated function count
prog_func_array    resq 1    ; pointer to function ptr array
prog_global_count  resq 1    ; accumulated global count
prog_global_array  resq 1    ; pointer to global decl array
```

## Warning System

The compiler emits **advisory warnings** for suspicious code patterns. Warnings never abort compilation — they are written to stderr and a summary is printed at the end:

```
file.c2:5:2: warning: uninitialized pointer dereferenced
N warning(s) generated
```

### CLI Flags

| Flag | Effect |
|------|--------|
| `--no-warnings` / `-Wno-all` | Suppress all warnings |
| _(none)_ | All warnings ON by default |

### Warning Categories

| # | Category | Trigger |
|---|----------|---------|
| 1 | `uninitialized variable` | Reading a scalar local before assignment |
| 2 | `uninitialized pointer dereferenced` | `*p` or `p->f` where `p` was never assigned |
| 3 | `non-void function should return a value` | Non-void function may fall off the end |
| 4 | `unused variable` | Local declared and initialized but never read |
| 5 | `unreachable code after return/break/continue` | Statement immediately following a terminator |
| 6 | `implicit cast` | Int literal assigned to `char` variable |
| 7 | `empty body for control flow statement` | `if (x) {}` or `while (x) {}` |
| 8 | `condition is always true` | `if (1)` or `while (0)` (literal numeric condition) |

### Implementation

- **Module:** `src/c2x-seed/warnings.asm` — categories, messages, emit functions
- **Hooks:** inline calls in `codegen.asm` at the points where each condition is detected
- **Output:** all warnings route through `warn_at(category, line, col, msg)` which saves/restores `out_fd` so the assembly output buffer is never corrupted
- **Multi-file behavior:** top-level functions and globals retain their originating source paths during codegen, so warnings in multi-file builds point at the correct input file instead of whichever file was parsed last

### Example

```c
int main() {
    int *p;
    *p = 1;              // warning: uninitialized pointer dereferenced
    return 0;
}
```

Output:
```
prog.c:3:5: warning: uninitialized pointer dereferenced
1 warning(s) generated
```

## BSS Section Emission Fix

Fixed a pre-existing bug in `emit_global_vars` where an uninitialized array or struct variable following an initialized scalar (e.g., `int x = 42; int arr[10];`) would emit its storage in the `.data` section instead of switching to `.bss`. The non-VAR_DECL code path for arrays/structs now checks `rbx == 1` (`.data` emitted) and switches to `.bss` before emitting the label, matching the behavior of the VAR_DECL path.

## Constraint Checks

- [x] **No floating-point logic** — all values are integer or pointer
- [x] **No structs or unions** — use raw pointer offsets (`node_ptr + 8`)
- [x] **Zero external dependencies** — only Linux syscalls via `syscall` instruction
- [x] **Self-hosting ready** — pipeline is structured for the eventual c2x-proto rewrite
