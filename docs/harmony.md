# A Conceptual GC-Free, Memory-Safe, C-Shaped Language
UPDATE LANG NAME: Harmony
File Extension: .harmony

> **Status:** concept notes, version 0.3. This document describes a language that does not exist yet.
> It is a design sketch for a compiler, not a specification of a shipped implementation, and it is
> **intentionally unnamed**: everywhere below, "the language" means "whatever this document grows into".
>
> **Goal:** the *minimum* set of ideas that lets a compiler prove memory safety with **no garbage
> collector**, no reference counting, and no runtime bookkeeping at all — while keeping the surface
> syntax familiar enough that somebody who knows C can read a program on day one.
>
> **Cost:** the compiler does the hard work instead of the runtime. There is a borrow checker, a move
> checker, a definite-initialization pass, and an exhaustiveness pass. The programmer pays in "the
> compiler argues with me", not in GC pauses.

---

## Contents

1. [What this is, and what it refuses to be](#1-what-this-is-and-what-it-refuses-to-be)
2. [Quick tour](#2-quick-tour)
3. [The identity card](#3-the-identity-card)
4. [The five rules](#4-the-five-rules)
5. [What those rules buy: the fault classes](#5-what-those-rules-buy-the-fault-classes)
6. [The C-head rules](#6-the-c-head-rules)
7. [Lexical structure](#7-lexical-structure)
8. [Types and values](#8-types-and-values)
9. [Bindings and definite initialization](#9-bindings-and-definite-initialization)
10. [Functions](#10-functions)
11. [Structs](#11-structs)
12. [Enums](#12-enums)
13. [`switch`](#13-switch)
14. [Loops and control flow](#14-loops-and-control-flow)
15. [Ownership and moves](#15-ownership-and-moves)
16. [Borrowing](#16-borrowing)
17. [Lifetimes: `life`](#17-lifetimes-life)
18. [The heap: `new` and `Heap<T>`](#18-the-heap-new-and-heapt)
19. [Text: `str`, `Text`, and `own`](#19-text-str-text-and-own)
20. [Collections: `Vec`, arrays, slices](#20-collections-vec-arrays-slices)
21. [Destruction: `drop` and `discard`](#21-destruction-drop-and-discard)
22. [`unchecked` and `Raw<T>`](#22-unchecked-and-rawt)
23. [Reports: the compiler's error format](#23-reports-the-compilers-error-format)
24. [How the compiler proves it](#24-how-the-compiler-proves-it)
25. [Pipeline and backends](#25-pipeline-and-backends)
26. [Runtime and memory model](#26-runtime-and-memory-model)
27. [Idioms and worked examples](#27-idioms-and-worked-examples)
28. [What v0 leaves out](#28-what-v0-leaves-out)
29. [Honest downsides](#29-honest-downsides)
30. [Appendix A — Grammar](#appendix-a--grammar)
31. [Appendix B — Operators and precedence](#appendix-b--operators-and-precedence)
32. [Appendix C — Report catalogue](#appendix-c--report-catalogue)
33. [Appendix D — Keywords and builtins](#appendix-d--keywords-and-builtins)
34. [Appendix E — Glossary](#appendix-e--glossary)
35. [Appendix F — One page](#appendix-f--one-page-if-you-remember-nothing-else)

---

## 1. What this is, and what it refuses to be

A small statically-typed language with:

- **value semantics** everywhere, with an explicit `copy` marker for types that are cheap to duplicate;
- **one owner per value**, so the compiler knows exactly where every allocation dies;
- **references** that are checked for aliasing and for liveness;
- **lifetime parameters** (called `life`) for the cases where a reference outlives the call that made it;
- **no null**, **no uninitialized values**, **no implicit conversions**, **no unchecked indexing** in
  safe code;
- **no GC**, no tracing, no refcounts, no `free()`, no `delete`, no `malloc` in user code;
- an **escape hatch** called `unchecked`, which is small, loud, and greppable.

It refuses to be:

| Refusal | Reason |
|---|---|
| A scripting language with hidden allocation | The whole point is knowing where memory dies. |
| A language where safety is a library convention | A convention is not a proof. The checker must reject the program. |
| A language with two string types *and* three pointer types *and* four smart pointers | Small enough to teach in an afternoon. |
| A language where `unsafe` is a vibe | The escape hatch has a name that says what it means, and a report ID when you misuse it. |
| A language with a runtime | The "runtime" is a C file with `alloc`, `free`, `abort`, and a few memcpy wrappers. |

### Design weights

When two goals conflict, the tie is broken in this order:

1. **Memory safety** — a safe program must not corrupt memory, ever.
2. **Teachability** — the rule that produces a compile fault must be statable in one sentence.
3. **Surface familiarity** — braces, semicolons, `if (cond)`, `while (cond)`.
4. **Expressiveness** — closures, traits, operator overloading, and macros can wait.
5. **Performance** — "no GC" already wins most of this; explicit `unchecked` covers the rest.

---

## 2. Quick tour

```c
// hello.lang
fn main() {
    println("hello, world");
}
```

```c
copy struct Point { x: i32; y: i32; }

copy enum Shape { Circle(f64), Rect(f64, f64), Dot, }

fn area(s: Shape) -> f64 {
    switch (s) {
        case Circle(r):  { return 3.14159 * r * r; }
        case Rect(w, h): { return w * h; }
        case Dot:        { return 0.0; }
    }
}

fn main() {
    let mut total: f64 = 0.0;

    for (let mut i: i32 = 0; i < 10; i += 1) {
        let s = Shape::Circle(1.0);   // enum variant construction
        total += area(s);
    }

    if (total > 50.0) {
        println("big: {:.2}", total);
    } else {
        println("small: {:.2}", total);
    }
}
```

Two things to notice, because they are the personality of the language:

```c
let name = own("Ada");      // an owned Text, built from a borrowed string literal
name.append(" Lovelace");   // no `String::from`, no `to_owned`, no `clone`

unchecked "buf.len() is 8, i < 8" {   // the escape hatch is a block with a reason
    *(buf + i) = 0;                   // raw store, allowed only in here
}
```

---

## 3. The identity card

Every language has a handful of decisions that, once you know them, let you guess the rest. These
are that handful. None of them are load-bearing on their own; together they are the "feel".

| Idea | Surface form in this design | Why this shape |
|---|---|---|
| Attach functions to a type | `methods Point { ... }` | Says what it does. One keyword, no ceremony. |
| Branch on a value | `switch (x) { case ...: { } }` | C-heads already read it. But **safe**: no fallthrough, must be exhaustive. |
| Optional value | `Maybe<T>` with `Has(x)` / `Empty` | Reads like English, not like a category-theory footnote. |
| Unique heap box | `Heap<T>`, built with `new` | "This lives on the heap." Nothing else to remember. |
| Iterate a container | `for (x : &v)` | C++ range-for shape; the sigil chooses borrow, borrow-mut, or move. |
| Lifetime parameter | `life a` declares, `life(a)` uses | `let x` vs `sizeof(x)`: same declare/use split. |
| Cheap-to-copy marker | `copy struct`, `copy enum` | One word, checked exhaustively. |
| Owned growable text | `Text`, built by `own("…")` | The word is the operation: *make me an owner*. |
| Copy an owning value | `v.copy()` | Same word, now a method: *duplicate the bytes I own*. |
| Escape hatch | `unchecked { ... }` + `Raw<T>` | Names the property you gave up, not the property you kept. |
| Boolean operators | `and`, `or`, `not` | Kills the `&`/`&&` and `=`/`==` typo families outright. |
| Bitwise operators | `band`, `bor`, `bxor`, `bnot`, `shl`, `shr` | `&` already means borrow; don't overload it. |
| Compiler errors | `fault · move.after-handoff` | Named, greppable, teachable. No E-codes to memorize. |

---

## 4. The five rules

Everything else in this document is a consequence. If you remember five sentences, remember these.

### R1 — Every value has exactly one owner

An owner is a variable, a field, or an element. It is not a pointer, not a handle, not a table entry.
Exactly one of them is responsible for destroying the value.

### R2 — When the owner goes out of scope, the value is freed at the closing `}`

No GC, no `free()`, no `delete`. Destruction happens at a deterministic point, in a deterministic
order, on the line with the `}`. If you can read the source, you know when the memory goes back.

### R3 — Passing or assigning by value moves it, unless the type is `copy`

After `consume(name)` or `let other = name;`, the old name is dead. Not "invalidated at runtime":
**rejected at compile time**. For types marked `copy` (numbers, `bool`, `char`, small `copy struct`s),
the bytes are duplicated and both names stay alive.

### R4 — Many `&`, or one `&mut`, never both while alive

Shared borrows may be duplicated. Exclusive borrows may not. "While alive" means **until the last
use**, not until the `}` — a loan ends where you stop touching it.

### R5 — A reference cannot outlive what it points to

The compiler tracks how long each referenced value lives and rejects references that could be used
after the referenced storage is gone. When it cannot infer this from the function signature, you
write it down with `life`.

### The corollary rules

These are not extra rules; they are the same five, applied:

- **No null.** Every optional thing is a `Maybe<T>`, and the compiler makes you look inside.
- **No uninitialized reads.** A variable must be written on every path before it is read.
- **No unchecked indexing in safe code.** `v[i]` is bounds-checked; integer overflow traps.
- **No raw pointers, no unions, no pointer arithmetic** outside `unchecked`.
- **No implicit conversions.** `i32 + u32` is a fault. You convert on purpose, with a named operation.
- **No aliasing through owners.** Two owners of the same allocation cannot be constructed in safe code,
  so double-free is not a runtime event; it is a program that does not build.

---

## 5. What those rules buy: the fault classes

"Memory safe" is a slogan until you list the bug classes. This is the list, and the rule that kills
each one. Every row is *statically* prevented unless marked otherwise.

| Bug class | How it usually happens | What prevents it here |
|---|---|---|
| Use-after-free | pointer kept after `free` | R1+R2+R3: the owner is compile-time dead after a move, and destruction is tied to scope, not to a call. |
| Double free | two owners call `free` | R1: exactly one owner. Second owner cannot exist. |
| Dangling reference | borrow outlives the value | R5 + `life` checking. |
| Null dereference | `NULL` returned on error | No null. `Maybe<T>`, and `switch` must handle `Empty`. |
| Uninitialized read | `int x; use(x);` | Definite-initialization analysis on the control-flow graph. |
| Buffer overflow | `a[i]` with `i >= len` | Every index is bounds-checked; slices carry their length. |
| Integer wraparound | signed overflow UB, unsigned wrap | Overflow traps. Wrapping is a named operation: `wrap_add`. |
| Iterator invalidation | mutate a container while iterating | R4: `push` needs `&mut v`; a live `&v[i]` forbids it. |
| Aliased mutation | two pointers, one write | R4: `&mut` is exclusive for its whole live range. |
| Data race (v1) | shared state without sync | R4 is the same rule that makes races impossible once threads exist. |
| Silent truncation | `int64 -> int32` assignment | No implicit conversion. `narrow(x)` returns `Maybe<T>`. |
| Forgotten enum case | `default:` swallowing a new variant | Exhaustive `switch`; a new variant is a compile fault at every site. |
| Fallthrough bug | missing `break` | `switch` does not fall through at all. |
| Freeing `static` data | `free(&literal)` | You never call `free`. |
| Leak | early `return` skips cleanup | R2: destruction is scope-based and inserted by the compiler, including on `return`. |

### The one thing that is not free: `keep()`

The single sanctioned leak is explicit:

```c
let shared: &life(static) str = keep(own("program lifetime"));
```

`keep` converts an owning value into a `&life(static)` reference by leaking the allocation. It is a
**safe** function, deliberately: leaking is memory-safe, just rude. It shows up in `--report=seams`
next to your `unchecked` blocks, so `keep` cannot hide.

---

## 6. The C-head rules

Somebody arriving from C should not have to unlearn braces. These are the places where the language
looks like C on purpose — and the two places where it looks like C but is safer.

**Familiar on purpose:**

- Control-flow conditions need parentheses: `if (x)`, `while (x)`, `switch (x)`.
- Braces are mandatory, even for one statement. There is no brace-less `if`.
- Every statement ends with `;`. Every block is `{ }` and does not.
- Types are written after the name: `let n: u32 = 0;` — one declaration form everywhere.
- Comments are `//` and `/* */` (nesting allowed).
- C-style `for (init; cond; step)` exists and is the normal counting loop.
- `break` and `continue` do what they say.

**Safer on purpose:**

- **Assignment is a statement, not an expression.** `if (x = 5)` does not parse. Report
  `syntax.assignment-is-not-an-expression`.
- **Conditions are `bool`.** `if (1)` is a fault; there is no truthiness. Report `type.not-a-bool`.
- **`switch` does not fall through** and must cover every case. Report `switch.not-exhaustive`.
- **`break` inside `switch` exits the enclosing loop.** Since `switch` never needs a break of its own,
  the two uses of the keyword never get confused.
- **Returns are explicit statements.** No trailing-expression magic; a function body is a list of
  statements. `return;` is legal in a unit function.
- **No `goto`.** No labels in v0.
- **No implicit casts, not even widening.** `x as i64` exists, but it is written.
- **No pointer arithmetic** outside `unchecked`.

---

## 7. Lexical structure

```
program    = one file, UTF-8, no BOM required, no significant whitespace
comment    = "//" { any } newline | "/*" { any | nested comment } "*/"
ident      = (letter | "_") { letter | digit | "_" }
file       = "*.lang"
```

- **Keywords are reserved** (Appendix D). Identifiers are `snake_case` for values and functions,
  `UpperCamelCase` for types and enum variants. The compiler does not enforce the convention but the
  formatter does.
- **No automatic semicolon insertion.** A missing `;` is a parse fault with a fix-it.
- **No tabs vs spaces war.** The formatter owns layout; the parser does not care.

### Literals

| Literal | Examples | Notes |
|---|---|---|
| Integer | `0`, `42`, `1_000_000`, `0xFF`, `0b1010`, `0o755` | Unsuffixed literals adapt to the expected type; suffix to pin it: `42u8`, `9i64`. |
| Float | `1.0`, `3.5e-2`, `1_000.0f64` | Always has a `.` or exponent. A float is never silently an integer. |
| Bool | `true`, `false` | The only two values of `bool`. |
| Char | `'a'`, `'\n'`, `'\u{1F600}'` | One Unicode scalar value, 4 bytes, always valid. |
| String | `"hello"`, `"line\nbreak"`, `"{} items"` | Type is `&life(static) str`. `{}` placeholders live in the string but are only interpreted by formatting builtins. |
| Array | `[1, 2, 3]`, `[0; 8]` | `[0; 8]` repeats a `copy` value eight times. |
| Unit | `()` | The value of "nothing returned". |

Escapes in chars and strings: `\n \r \t \\ \" \' \0 \u{...}`. A literal `\0` inside `str` is allowed;
`str` is length-delimited, not NUL-delimited.

### Statement shape

```
stmts are one per line by convention, `;`-terminated by rule
blocks are `{ ... }`, never optional
```

---

## 8. Types and values

### 8.1 Primitives

Sizes are fixed. There is no `int`, no `long`, no implementation-defined width.

| Type | Size | Range / meaning |
|---|---|---|
| `u8 u16 u32 u64 u128` | 1,2,4,8,16 | unsigned, wrapping is **not** implicit |
| `i8 i16 i32 i64 i128` | 1,2,4,8,16 | two's complement, overflow traps |
| `f32 f64` | 4,8 | IEEE-754; `NaN != NaN` |
| `bool` | 1 | `true` / `false`, no arithmetic |
| `char` | 4 | one Unicode scalar value, always valid |
| `()` | 0 | unit |
| `!` | 0 | the type of `return`, `panic`, `break`, `continue`; coerces to anything |

Rules:

- **Signedness is in the name.** No `signed` modifier to forget.
- **`char != u8 != u32`.** Same bits, different types, zero implicit conversion.
- **No `void*`.** There is no untyped anything; that is the point.
- **`f32`/`f64` are not ordered.** They have equality and comparison, but sorting requires an explicit
  comparison function, and there is no default ordering for floats.
- **No subtyping among numbers.** `u32` is never a `u64`. `as` widens, `narrow` proves, `wrap` truncates.

### 8.2 Copy types vs owning types

| | `copy` | owning |
|---|---|---|
| Assignment | duplicates bytes | moves ownership |
| Passing to a function | duplicates | transfers |
| Needs a `drop` hook | never | optionally |
| Examples | numbers, `bool`, `char`, `()`, `Point` | `Text`, `Vec<T>`, `Heap<T>`, `File` |

- A `struct`/`enum` is `copy` only when the programmer writes `copy` **and** every field is `copy`.
  Forgetting the marker is a deliberate speed bump; the checker reports
  `type.not-copy` when you rely on copying without the marker.
- The largest copy type is bounded: total size must be ≤ 128 bytes (`copy.too-large`). This keeps
  accidental 10 KB memcpys from hiding behind one `=`.
- An owning value is **never** implicitly duplicated. `Text` has no hidden duplicate operation; it has
  `copy()`, a visible method call.

### 8.3 Composite and library types

| Type | Kind | Description |
|---|---|---|
| `[T; N]` | value | fixed array, `copy` if `T` is `copy` |
| `[T]` | unsized | slice, always behind `&` / `&mut` |
| `Vec<T>` | owning | growable array, `{ptr, length, capacity}` |
| `Text` | owning | growable UTF-8 buffer |
| `str` | unsized | borrowed text, `&str` |
| `Heap<T>` | owning | unique heap allocation of one `T` |
| `Maybe<T>` | value | `Has(T)` or `Empty`; `copy` iff `T` is `copy` |
| `Raw<T>` | unchecked | a raw address, only nameable under `unchecked` |
| `(T, U)` | — | **not in v0.** Use a named struct; it reads better anyway. |

### 8.4 Recursive types need indirection

```c
struct Node {
    value: i32;
    next: Maybe<Heap<Node>>;   // fine: Heap is a pointer-sized indirection
}

// struct Loop { inner: Loop; }   // fault type.infinite-size
```

---

## 9. Bindings and definite initialization

```c
let x = 5;                 // immutable, inferred i32
let mut total: i32 = 0;    // mutable, explicit type
let flag: bool;            // declared, not initialized
```

- **`let` without `mut` is immutable.** Reassignment is a fault (`assign.not-mutable`).
- **Initialization is optional**, and checked. This is the language's answer to the missing ternary:

```c
let label: &str;
if (n > 0) {
    label = "positive";
} else {
    label = "zero or negative";
}
println("{}", label);       // fine: both paths wrote it
```

- **Reading before writing on any path** is a fault (`init.read-before-write`), reported on the read
  with the uninitialized path shown as a secondary span.
- **Shadowing is allowed** and creates a *new* binding:

```c
let count: u32 = 12;
let count: u64 = count as u64;   // new binding, same name, different type
```

The initializer of a shadowing `let` sees the **previous** binding; the new one starts after the `;`.

- **A moved variable can be re-armed** by assigning a fresh value:

```c
let mut s = own("a");
consume(s);         // s is moved
s = own("b");       // s is initialized again
consume(s);         // fine
```

- **Destruction order is the reverse of declaration**, within a block:

```c
let a = own("a");
let b = own("b");
// at `}`: b dropped first, then a
```

---

## 10. Functions

```c
fn add(a: i32, b: i32) -> i32 {
    return a + b;
}
```

- **No overloading.** One name, one function. Name things `add_i32` if you must.
- **No default arguments.** Write a second function or a struct of options.
- **Parameters are immutable** unless declared `mut`, which only affects the local copy:

```c
fn shout(mut s: Text) {     // owns s; may mutate its own copy of the handle
    s.append("!");
    println("{}", s);
}                            // s is destroyed here
```

- **Return is a statement.** A block's last expression is not the return value.

```c
fn bad(a: i32) -> i32 {
    a + 1            // fault syntax.expected-return: this expression is a statement, not a value
}
```

- **`return;`** is required syntax in unit functions when returning early; falling off the end of a
  unit function is fine.
- **All paths must return** in a non-unit function (`control.missing-return`).

### 10.1 Generic parameters

```c
fn first<T>(v: &Vec<T>) -> Maybe<&T> {
    if (v.length() == 0) {
        return Empty;
    }
    return Has(&v[0]);
}
```

- Generic parameters are `<T>`, `<T, U>`, or combined with lives: `<T, life a>`.
- **The only bound in v0 is `copy`**: `<T: copy>` means the function may duplicate `T` with `=`.
- Generics are monomorphized. No traits, no dynamic dispatch, no vtables.

### 10.2 Methods and associated functions

`methods` blocks attach functions to a type (see §11). The distinction is in the first parameter:

| First parameter | Call shape | Meaning |
|---|---|---|
| *(none)* | `Type::name(args)` | associated function; no receiver |
| `&self` | `value.name(args)` | shared borrow of the receiver |
| `&mut self` | `value.name(args)` | exclusive borrow of the receiver |
| `self` | `value.name(args)` | consumes the receiver |

- `self` is a keyword only inside a `methods` block.
- Calling a `&mut self` method auto-borrows: `c.bump()` is `Counter::bump(&mut c)`.
- There is no `Deref` trait. `.` auto-derefs through `&`, `&mut`, and `Heap<T>` — and nothing else.

### 10.3 `main`

```c
fn main() { ... }
fn main() -> Maybe<()> { ... }   // v1: exit status / error reporting
```

In v0, `main` takes no parameters and returns nothing. The process exits `0` unless it panics.

### 10.4 Foreign functions

```c
extern fn write(fd: i32, buf: Raw<u8>, count: u64) -> i64;
```

- `extern fn` is a *declaration only* — no body.
- Calling one requires an `unchecked` block (§22).
- If the signature mentions `Raw<T>`, the declaration must be `unchecked extern fn`.
- There is no implicit C-string conversion, no variadic support in v0, and no name mangling contract
  beyond "C ABI".

### 10.5 `unchecked fn`

```c
unchecked fn peek(p: Raw<i32>) -> i32 {
    unchecked {
        return *p;
    }
}
```

An `unchecked fn` is required whenever `Raw<T>` appears in the signature. It is a *type-level* marker:
it says "raw addresses cross this boundary". The dangerous operations still need explicit `unchecked`
blocks inside, and calling an `unchecked fn` is itself an unchecked operation: the call must be written
inside an `unchecked` block. Full rules in §22.

---

## 11. Structs

```c
copy struct Point { x: i32; y: i32; }
struct Player { name: Text; pos: Point; }
```

- Fields are declared like `let`: `name: Type;` — so fields end in `;`.
- No inheritance, no anonymous embedding, no bitfields, no `union`.
- Field order is declaration order; it is also destruction order.
- A struct with no `copy` marker is an owning type and moves.
- `copy struct` requires every field to be `copy`, and total size ≤ 128 bytes.

### 11.1 Construction

```c
let p = Point { .x = 1, .y = 2 };
let q = Point { .x = 3, .y = p.y };     // p.y is copy, fine
let pl = Player { .name = own("Ada"), .pos = p };
```

- The leading `.` on field names is deliberate: it looks like a field access, so beginners read
  `Point { .x = 1 }` as "a Point whose `x` is 1" instead of confusing `:` with a type annotation.
- **Every field must be initialized.** There is no zeroing, no `Default`, no partial init.
  Missing fields are reported with the list of what is missing (`init.missing-field`).
- Field order in the literal is free; the compiler reorders.
- The last field may keep or drop its trailing `,`.

### 11.2 Field access and borrowing

```c
let mut p = Point { .x = 1, .y = 2 };
p.x += 1;                    // write through ownership

let r = &p.x;                // borrow one field
let s = &mut p.y;            // borrow a *different* field at the same time: fine
println("{} {}", r, s);
```

Field-level precision matters: `&p.x` and `&mut p.y` coexist because they are disjoint places. The
checker works on *places*, not on "the whole struct".

### 11.3 Methods

```c
struct Counter { count: u32; }

methods Counter {
    fn new() -> Counter {
        return Counter { .count = 0 };
    }

    fn bump(&mut self) {
        self.count += 1;
    }

    fn get(&self) -> u32 {
        return self.count;
    }

    fn into_value(self) -> u32 {     // consumes the counter
        return self.count;
    }
}

fn main() {
    let mut c = Counter::new();
    c.bump();
    println("{}", c.get());
    let n = c.into_value();          // c is moved here
}
```

- `methods` blocks may be repeated for the same type, but only in the same file (v0 has no modules).
- A `methods` block can be generic: `methods<life a> Words<life(a)> { ... }`.
- No trait objects, no extension methods, no operator overloading.

---

## 12. Enums

```c
copy enum Shape {
    Circle(f64),
    Rect(f64, f64),
    Dot,
}
```

- Variants are separated by `,` (they are alternatives in a list), unlike fields, which are
  declarations and end in `;`. The trailing comma is optional.
- A variant may carry zero or more payloads, each with a type. Payload types are positional, not named.
- An enum with no payloads is a C-like constant set:

```c
copy enum Direction { North, South, East, West, }
let d = Direction::North;
```

- Construction uses `Type::Variant(...)`:

```c
let s = Shape::Rect(3.0, 4.0);
let dot = Shape::Dot;
```

- Enums are the only sum type. `Maybe<T>` is just a built-in enum:

```c
enum Maybe<T> { Has(T), Empty, }   // built-in; `copy` exactly when `T` is `copy`
```

- Built-in enums (`Maybe`) derive `copy` from their type arguments. User enums do not: you write
  `copy` yourself, and the checker verifies every payload. The asymmetry is deliberate — the built-in
  is audit-able by reading this one line.

- No explicit discriminants, no `as` on enums, no C-style integer layout guarantees. If you need a
  wire format, write the encoder.

---

## 13. `switch`

`switch` is the only branching construct for values, and it is where most of the safety lives.

```c
switch (expr) {
    case Circle(r):  { ... }
    case Rect(w, h): { ... }
    case Dot:        { ... }
    default:         { ... }     // optional catch-all
}
```

### 13.1 The rules

1. **No fallthrough.** Each `case` body is a block; control leaves the `switch` at its `}`.
   There is no `break` needed, and no way to accidentally reach the next case.
2. **Braces are mandatory** on every arm. This kills the dangling-`else`-shaped ambiguity that
   brace-less arms create.
3. **Exhaustive.** Every possible value must be covered, or there must be a `default`. Missing cases
   are reported with the *witness*: the smallest value that is not covered.
4. **Arms are tried top to bottom.** First match wins. Overlapping arms that can never match are
   `switch.unreachable-arm` warnings.
5. **`break` inside an arm exits the enclosing loop**, not the `switch`. If there is no enclosing
   loop, `break` is a fault (`control.break-outside-loop`). Use `return` to leave a function early.
6. **No `goto` targets, no labels, no guards** in v0. Guards (`case n if (n > 0)`) are a v1 item;
   today you nest an `if` inside the arm.
7. **Subjects are integers, `bool`, `char`, `&str`, or an enum.** An enum (and `bool`) has a closed set
   of values, so exhaustiveness can be proven without a `default`. For open domains (integers, strings)
   a `default` is required, and forgetting it is `switch.not-exhaustive` with the witness
   `any other value`.

### 13.2 Patterns

| Pattern | Matches | Binds |
|---|---|---|
| `_` | anything | nothing |
| `name` | anything | the whole matched value, bound to `name` |
| `42`, `'x'`, `"text"`, `true` | that literal | nothing |
| `Variant` | a unit variant | nothing |
| `Variant(p1, p2)` | a variant with payloads | each payload, recursively |
| `Variant(_)` | a variant, ignoring its payload | nothing |
| `Variant(Has(x))` | nested patterns | `x` |
| `default` | anything not yet matched | nothing |

Bindings are irrefutable inside their arm; there is no `if let`.

### 13.3 Binding modes: what the subject's shape gives you

This is the one rule people get wrong, so it is a table:

| Subject expression | Subject type | `case Has(x)` binds | After the `switch` |
|---|---|---|---|
| `m` (owned) | `Maybe<Text>` | `x: Text` — **moved** out | `m` is moved; unusable |
| `&m` | `&Maybe<Text>` | `x: &Text` — borrowed | `m` is still owned and usable |
| `&mut m` | `&mut Maybe<Text>` | `x: &mut Text` — mutably borrowed | `m` usable after the switch |
| `m`, a `copy` enum | `Shape` | payloads are copied | `m` still usable |

So: **switching on an owned value consumes it; switching on a reference lends you its insides.**
Bindings never silently deep-copy, and never move a *field* — the subject moves as a whole.

### 13.4 Exhaustiveness and the witness

```c
copy enum Shape { Circle(f64), Rect(f64, f64), Dot, }

fn area(s: Shape) -> f64 {
    switch (s) {
        case Circle(r): { return 3.14159 * r * r; }
        case Rect(w, h): { return w * h; }
    }
}
```

```
╭─ fault · switch.not-exhaustive ─────────────────────────── main.lang:5:5
│
│    5 │     switch (s) {
│      │     ◀──── this switch can finish without producing a value
│      │
│      │  missing case: Dot
│      │
├ rule  a switch must handle every value its subject can take, or have a `default`
├ got   `Shape` has 3 variants; 2 are handled
├ fix   add the missing arm:
│           case Dot: { return 0.0; }
├ fix   or add a catch-all (and hide future variants from the checker):
│           default: { return 0.0; }
╰ see   `--explain switch.not-exhaustive`
```

Adding a variant to `Shape` now produces a fault at **every** `switch` that lacks a `default`. That is
the point: the compiler finds the sites you forgot.

### 13.5 Matching without consuming

```c
fn label(m: &Maybe<Text>) -> &str {
    switch (m) {
        case Has(t): { return t.as_str(); }
        case Empty:  { return "nothing"; }
    }
}
```

Elision gives the returned `&str` the life of `m`; `t` is a `&Text` derived from `m`, so `t.as_str()`
carries the same life. This is the bread-and-butter shape of the language: match a borrow, return a
borrow, never copy the payload.

---

## 14. Loops and control flow

### 14.1 `if`

```c
if (x > 0) {
    ...
} else if (x < 0) {
    ...
} else {
    ...
}
```

`if` is a statement. It produces no value. There is no ternary; use a declared-but-uninitialized
binding (§9).

### 14.2 `while`

```c
while (i < 10) {
    i += 1;
}
```

`while (true) { ... }` is the infinite loop; `break` leaves it. There is no `loop` keyword and no
`do { } while ( );` in v0.

### 14.3 C-style `for`

```c
for (let mut i: u32 = 0; i < 10; i += 1) {
    println("{}", i);
}
```

- The init clause may be a `let` or an assignment; the step is one assignment or a call.
- The loop variable is scoped to the loop.
- This is the idiomatic counting loop. There are no range literals in v0.

### 14.4 Range-style `for`

```c
let mut v: Vec<u32> = Vec::new();
v.push(10);
v.push(20);

for (n : &v)     { println("{}", n); }   // n: &u32, v still owned
for (n : &mut v) { *n += 1; }            // n: &mut u32, v still owned
for (n : v)      { println("{}", n); }   // n: u32 (copied), v is consumed
```

| Form | Element binding | Container afterwards |
|---|---|---|
| `for (x : &c)` | `&T` | usable |
| `for (x : &mut c)` | `&mut T` | usable |
| `for (x : c)` | `T` if `T: copy`, else `T` moved out | moved (dead) |
| `for (x : arr)`, `arr: [T; N]` | `T` | copied if `T: copy`, else moved |

- Works on `Vec<T>`, `[T; N]`, `&[T]`, `&mut [T]`.
- If the expression is already a reference (`program: &Vec<Op>`), write `for (op : program)`; it is
  the shared form, and yields `&Op`. The `&c` spelling is only needed when `c` is owned.
- The container is borrowed for the whole loop; mutating it inside the loop is a fault
  (`borrow.conflict`), and that fault *is* the iterator-invalidation bug.
- No iterators, no `.map`, no lazy chains. Write a `while` loop with an index.

### 14.5 `break`, `continue`, and nested loops

```c
let mut i: u32 = 0;
while (i < 10) {
    i += 1;
    if (i % 2 == 0) {
        continue;               // next iteration
    }
    if (i > 7) {
        break;                  // leaves the while
    }
}
```

There are no labels in v0. To break out of two loops, set a flag and check it:

```c
let mut done = false;
while (not done and i < n) {
    for (j : &v) {
        if (*j == target) {
            done = true;
            break;              // inner loop only
        }
    }
    i += 1;
}
```

### 14.6 Early return and destruction

`return` runs the same destruction sequence as falling off the end of the block, for every value that
was initialized at that point. "No leak on early return" is therefore a compile-time property, not a
discipline.

---

## 15. Ownership and moves

### 15.1 Where moves happen

A value moves (rather than copies) when it is **not `copy`** and it is:

1. assigned: `let b = a;` or `b = a;`
2. passed by value: `f(a)`
3. returned by value: `return a;`
4. used to build a struct or enum: `Point { .x = a }` moves `a` into the field
5. switched on while owned: `switch (m)` moves `m`'s payloads out

After any of these the old name is **dead**. Using it is a compile fault, never a runtime surprise.

### 15.2 The classic: use after handoff

```c
fn consume(s: Text)   { println("eating {}", s); }
fn peek(s: &Text)     { println("looking at {}", s); }

fn main() {
    let name = own("Ada");
    peek(&name);       // fine: a loan, ends when peek returns
    consume(name);     // ownership handed over
    peek(&name);       // fault
}
```

```
╭─ fault · move.after-handoff ────────────────────────────── main.lang:8:10
│
│    7 │     consume(name);
│      │             ◀───── `name` is handed to `consume` here
│    8 │     peek(&name);
│      │          ◀────── and used again here, one line too late
│
├ rule  a value has exactly one owner; passing it by value transfers the owner
├ got   `Text` is an owning type (heap-backed, growable) and is not `copy`
├ fix   lend it before you hand it over:
│           peek(&name);
│           consume(name);
├ fix   or hand over an independent copy:
│           consume(name.copy());
╰ see   `--explain move.after-handoff`
```

Read the two markers as one sentence: *handed over here … used again here*. Every move-related
report in this language is built from that pair.

### 15.3 Conditional moves

```c
let s = own("maybe");

if (flag) {
    consume(s);        // s is moved on this path only
}

println("{}", s);      // fault move.maybe-moved
```

The checker keeps a "maybe moved" state per variable at every point in the control-flow graph. A read
is allowed only where **no path** to that point moved the value. Assigning a fresh value on the missing
paths makes the join clean:

```c
if (flag) {
    consume(s);
} else {
    discard(s);        // both paths agree: s is gone
}
```

### 15.4 Partial moves are forbidden

```c
struct Pair { a: Text; b: Text; }

let p = Pair { .a = own("x"), .b = own("y") };
let a = p.a;          // fault move.partial
```

Why forbid it? Because then every type has one simple destruction story: either the whole value is
alive and will be destroyed as a unit, or it was moved as a unit. `copy` fields can still be read out;
owning fields cannot.

When you genuinely want to take a field, use the builtin:

```c
let a: Text = take(p.a);    // p is now partially moved and dead as a whole
```

`take(place)` moves a field out and marks the containing value **partially moved**: it may be
reassigned as a whole, but not read. That is the minimal, teachable version of partial moves.

### 15.5 Moving out of a `Heap`

```c
let boxed: Heap<Text> = new own("hi");
let text: Text = take(*boxed);   // moves the Text out and frees the box
```

Dereferencing a `Heap` to move its contents is spelled `take(*b)`. The box is then empty and dead; the
checker enforces that you do not use `b` afterwards.

### 15.6 Why moves are "logical, not physical"

At runtime a move is a `memcpy` of the value's bytes plus a promise not to read the source again. In
debug builds the source bytes are poisoned (`0xDD`) so that a compiler bug — or an `unchecked` bug —
shows up as a wild pointer instead of a silent double free.

### 15.7 Reassignment and drop flags

```c
let mut s = own("a");
s = own("b");     // the old "a" is destroyed here, before the new value lands
```

Assignment to an owning variable destroys the old value first. Internally "initialized" is a drop
flag; conceptually, `s` always holds exactly one live value, or none.

### 15.8 Return values and `self`

Returning a local moves it out; the block's epilogue then destroys only what is left. That is why
returning a `Vec` from a function costs nothing extra here: it is a move, not a copy.

---

## 16. Borrowing

### 16.1 The two references

```c
fn length(s: &Text) -> u64   { return s.length(); }
fn clear(s: &mut Text)       { s.truncate(0); }
```

| Form | Name | Can read | Can write | Duplicable | Aliasing |
|---|---|---|---|---|---|
| `&T` | shared borrow | yes | no | yes (`&T` is `copy`) | many at once |
| `&mut T` | exclusive borrow | yes | yes | no | exactly one |

`&mut T` is not a `copy` type. Passing one to a function performs an **implicit reborrow** for the
duration of that call, so the caller keeps using the original afterwards:

```c
fn bump(n: &mut u32) { *n += 1; }

let mut x = 1;
bump(&mut x);
bump(&mut x);      // fine: each call reborrowed for its own duration
println("{}", x);  // 3
```

### 16.2 Liveness, not braces

A borrow ends at its **last use**, not at the end of the block. This is the single biggest ergonomics
decision in the language, and it is what makes borrow checking tolerable:

```c
let mut v: Vec<u32> = Vec::new();
v.push(1);

let first = &v[0];
println("{}", first);     // last use of `first`: the loan ends here
v.push(2);                // fine
```

Move the print below the `push` and the same program stops compiling — because the loan is now alive
when `push` needs `&mut v`:

```c
let first = &v[0];
v.push(2);                // fault borrow.conflict
println("{}", first);
```

```
╭─ fault · borrow.conflict ──────────────────────────────── main.lang:8:5
│
│    6 │     let first = &v[0];
│      │                  ◀──── shared loan of `v` starts here
│    7 │     v.push(2);
│      │     ◀──── needs `&mut v` while the loan is still alive
│    8 │     println("{}", first);
│      │                    ◀──── the loan is alive because of this use
│
├ rule  many `&`, or one `&mut`, never both while alive (R4)
├ note  `push` may reallocate the buffer, so `first` would point at freed memory
├ fix   finish with the borrow before growing the vector:
│           println("{}", v[0]);
│           v.push(2);
├ fix   or copy the element out instead of borrowing it:
│           let first = v[0];
╰ see   `--explain borrow.conflict`
```

### 16.3 Loans attach to storage, not to variables

This is a rule worth stating separately, because it is what makes pointer-walking loops work:

> A loan is a permission attached to the **place** it points into. Overwriting the variable you used
> to reach that place does not, by itself, invalidate the loan; writing to the **referent's storage**
> does.

```c
struct Node { value: i32; next: Maybe<Heap<Node>>; }

fn sum(head: &Maybe<Heap<Node>>) -> i32 {
    let mut total: i32 = 0;
    let mut cur: &Maybe<Heap<Node>> = head;

    while (true) {
        switch (cur) {
            case Has(node): {
                total += node.value;
                cur = &node.next;      // fine: the loan points at the list's storage,
                                       // not at the local `cur`
            }
            case Empty: {
                return total;
            }
        }
    }
}
```

If loans were attached to variables, this loop would be impossible to write without indices. Because
they are attached to storage, the walk is legal and still checked: `cur` can only ever point into the
list that `head` lends, and the list outlives the function call.

### 16.4 What `.` does

`.` auto-derefs through any number of `&`, `&mut`, and `Heap<T>`. It never goes through `Vec` or
`Maybe` — those need `v[i]` and `switch`.

```c
struct Inner { n: i32; }
struct Outer { inner: Inner; }

let o = new Outer { .inner = Inner { .n = 7 } };   // Heap<Outer>
println("{}", o.inner.n);                          // no `->`, no `*`
```

### 16.5 Field-precision

Borrows are per-place, so disjoint fields do not conflict:

```c
let mut p = Point { .x = 1, .y = 2 };
let a = &p.x;          // loan of p.x
let b = &mut p.y;      // loan of p.y: different place, fine
*a; *b;
```

The same precision applies inside a `switch` arm: `case Has(node)` lends you the payload place, not
the whole enum.

### 16.6 No interior mutability in v0

There is no `Cell`, no `RefCell`, no `Mutex`, no atomics. If you need mutation through a shared
reference, you restructure (pass `&mut`, or move the value, or use indices into a `Vec`). This is a
deliberate omission: interior mutability is where the "one rule" gets a footnote, and v0 has no
footnotes.

### 16.7 Temporary values cannot be borrowed across statements

```c
let s = own("hi");
let r = &s.as_str();        // fine: `s` is a named place
// let bad = &own("hi").as_str();   // fault life.temporary: the Text dies at the `;`
```

If you want a reference to a temporary, name the temporary first. The report says exactly that.

---

## 17. Lifetimes: `life`

Most programs never write a `life`. The compiler infers reference lifetimes from function signatures
(elision rules below). `life` exists for the cases where the signature does not say enough.

### 17.1 Declare with `life`, use with `life(name)`

```c
fn longest<life a>(x: &life(a) str, y: &life(a) str) -> &life(a) str {
    if (x.length() > y.length()) {
        return x;
    }
    return y;
}
```

- `<life a>` **declares** a lifetime parameter, exactly like `<T>` declares a type parameter.
- `life(a)` **uses** it in a type, exactly like `sizeof(x)` uses a name.
- `life(static)` means "lives for the whole program".

The comparison is intentional: `let x` declares a variable, `sizeof(x)` mentions it. `life a` declares
a region, `life(a)` mentions it. One syntactic idea, two uses.

### 17.2 Elision: the entire rule list

If you write no `life` annotations, the compiler applies these rules, in order:

| # | Rule | Example |
|---|---|---|
| E1 | Each elided input reference gets its own fresh life. | `fn f(a: &str, b: &str)` → two lives |
| E2 | If there is exactly **one** input life, every elided output life is that one. | `fn f(a: &str) -> &str` |
| E3 | If the first parameter is `&self` or `&mut self`, elided output lives are `self`'s. | `fn as_str(&self) -> &str` |
| E4 | Otherwise an elided output life is a fault: name it. | `fn f(a: &str, b: &str) -> &str` → `life.cannot-elide` |

`life(static)` never elides. Rules E2 and E3 cover essentially every function a beginner writes;
E4 is the "be explicit" wall, and its report tells you exactly which parameter to name:

```
╭─ fault · life.cannot-elide ─────────────────────────────── main.lang:1:31
│
│    1 │ fn pick(a: &str, b: &str) -> &str {
│      │                               ◀──── which input does this borrow from?
│
├ rule  an elided output life needs exactly one candidate input life
├ got   2 input lives: `a` and `b`
├ fix   name the life you mean:
│           fn pick<life a>(x: &life(a) str, y: &life(a) str) -> &life(a) str
├ fix   or return an owned value:
│           fn pick(a: &str, b: &str) -> Text
╰ see   `--explain life.cannot-elide`
```

### 17.3 References in structs

A struct that holds a reference must name the life. There is no anonymous life in a type definition.

```c
struct Words<life a> {
    text: &life(a) str;
    pos: u64;
}

methods<life a> Words<life(a)> {
    fn new(text: &life(a) str) -> Words<life(a)> {
        return Words { .text = text, .pos = 0 };
    }

    // Returns a slice of the ORIGINAL text, not of `self`:
    fn next_word(&mut self) -> Maybe<&life(a) str> {
        // ... scan from self.pos, return the next run of non-space bytes ...
    }
}
```

Note the signature of `next_word`: the output is tied to `life(a)` (the original text), **not** to
`&mut self`. That is the whole reason `life` exists — without it, elision rule E3 would tie the result
to the `Words` value, and you could not keep the slice while dropping the iterator.

### 17.4 The dangling-reference report

```c
fn broken() -> &str {
    let s = own("hi");
    return s.as_str();
}
```

```
╭─ fault · life.outlives ────────────────────────────────── main.lang:4:12
│
│    3 │ fn broken() -> &str {
│      │                ◀──── the returned reference must stay valid for the caller
│    4 │     let s = own("hi");
│      │         ◀──── `s` is created here...
│    5 │     return s.as_str();
│      │            ◀──── ...and destroyed at the closing `}` of `broken`
│
├ rule  a reference cannot outlive what it points to (R5)
├ got   there is no input reference to borrow the output's life from
├ fix   return the owner instead of a borrow:
│           fn ok() -> Text { let s = own("hi"); return s; }
├ fix   or borrow from an input:
│           fn ok(s: &str) -> &str { return s; }
╰ see   `--explain life.outlives`
```

### 17.5 Subtyping: long lives shorten, short lives never lengthen

Only references have subtyping, and only in one direction:

- `&life(a) T` where `a` outlives `b` can be used as `&life(b) T`.
- `&mut life(a) T` is **invariant** in `a` (a mutable borrow cannot be silently shortened or
  lengthened), but covariant in `T`.
- `Heap<T>`, `Vec<T>`, `Text` are invariant in their parameters: they own, so they cannot be
  reinterpreted.
- `&life(static) T` converts to any shorter life. That is why string literals work everywhere.

```c
fn take_any(s: &str) { ... }

fn main() {
    let literal: &life(static) str = "lives forever";
    take_any(literal);            // static → call: shortening, fine
}
```

### 17.6 `life` and `keep`

`keep(x)` returns a `&life(static) T` by leaking the allocation. It is the only way to get a static
reference from a runtime value, it is safe, and it shows up in the audit report:

```c
fn intern(name: &str) -> &life(static) str {
    return keep(own(name));    // leaked on purpose, reported by --report=seams
}
```

### 17.7 What `life` does *not* do

- It does not make anything live longer. It is a *claim* the compiler verifies, not a lifetime
  extender.
- It does not appear on locals. A local reference's life is inferred; only signatures and type
  definitions name lives.
- It is not a region variable you can assign to. There is no `life a = ...;`.

---

## 18. The heap: `new` and `Heap<T>`

```c
let mut b: Heap<i32> = new 42;
*b += 1;
println("{}", *b);
// no free(), no delete, no GC. `b` is freed at the closing brace.
```

- `new expr` allocates one value on the heap and returns `Heap<T>`, a **unique** owning pointer.
- `Heap<T>` is move-only. There is no second owner, therefore no double free.
- `.` auto-derefs through `Heap`; `*b` is the explicit form. There is no pointer arithmetic.
- The allocation is freed when its owner dies. No `delete`.
- `Heap<T>` is a thin pointer: `size_of(Heap<T>) == size_of(Raw<T>)`. No refcount word, no vtable.

### 18.1 Why `new` without `delete` is not a leak

Because `new` produces an *owner*, and owners are destroyed at scope end by R2. Compare:

```c
fn make() -> Heap<i32> {
    let b = new 7;
    return b;        // move out; the box survives the function
}                    // nothing left to destroy

fn main() {
    let x = make();
    println("{}", *x);
}                    // x destroyed: the box is freed here
```

A `Heap` that is moved out is not destroyed; a `Heap` that is still owned at `}` is. That is the whole
allocation story.

### 18.2 Recursive types

Indirection is what makes recursion possible:

```c
struct Node {
    value: i32;
    next: Maybe<Heap<Node>>;
}

fn push_front(head: Maybe<Heap<Node>>, value: i32) -> Maybe<Heap<Node>> {
    return Has(new Node { .value = value, .next = head });
}
```

Each `Node` owns its successor through a `Heap`, so destroying the head destroys the chain
recursively. That recursion is generated by the compiler from the type definition; there is no
user-written recursive free.

### 18.3 Taking the value back out

```c
let b: Heap<Text> = new own("hi");
let t: Text = take(*b);      // value moved out, box freed
println("{}", t);
```

`take(*b)` is the only way to move a value out of a `Heap`. After it, `b` is dead.

### 18.4 Allocation failure

If the allocator fails, the program panics with `panic.out-of-memory`, prints a report, and exits with
code `101`. There is no `new` that returns `Maybe<Heap<T>>`; a program that cannot get 8 bytes cannot
continue meaningfully. (A fallible-allocator mode is a v1 item.)

### 18.5 What is deliberately absent

| Absent | Consequence |
|---|---|
| `Rc`, `Arc` | no shared ownership, no cycles, no refcount cost |
| `Weak` | no cycle breaking needed |
| `free`, `delete` | no manual lifetime management |
| `malloc` | allocation is `new` only |
| pointer arithmetic | no `p + 1` outside `unchecked` |
| null | no `Maybe<Heap<T>>`-as-null punning; `Maybe` is a real tagged value |

Cycles are impossible to construct in safe code. That is not a limitation to apologize for: it is why
there is no `Rc` and no cycle collector. If you need a graph, use indices (§27.4), and if you truly
need a cycle of heap nodes, you need `unchecked` — and the audit report will say so.

---

## 19. Text: `str`, `Text`, and `own`

There are exactly two text types, and the difference is ownership.

| Type | Owns its bytes | Size | Built from | Typical use |
|---|---|---|---|---|
| `str` (unsized) | no | `{ptr, len}` behind `&` | a literal, `t.as_str()`, `t.slice(..)` | parameters, returns, views |
| `Text` | yes, heap | 3 words | `own("…")`, `t.copy()` | storage, growth, ownership |

### 19.1 Why `own("Ada")` instead of a `from` constructor

The obvious spelling is a namespaced constructor (`Text::from("Ada")` in the style of many languages).
This design rejects it, for three reasons:

1. **It is a type-name ritual.** Naming the type adds a word that carries no information — the
   compiler already knows the type from the binding.
2. **The interesting fact is the *conversion*, not the type.** You are moving from "borrowed bytes
   that live somewhere else" to "bytes I own and may grow". `own` names that.
3. **It pairs with the borrow sigil.** `&name` borrows a `Text`; `own(s)` owns a `str`. One word each
   direction, both one syllable, both impossible to confuse with a method call.

```c
let literal: &str = "Ada";       // borrowed, static
let owned:   Text = own(literal); // owned, heap, growable
let copied:  Text = owned.copy(); // a second independent owner
let view:    &str = owned.as_str(); // borrow it back
```

The full conversion vocabulary:

| You have | You want | Write |
|---|---|---|
| `&str` | `Text` (a copy of the bytes) | `own(s)` |
| `Text` | `Text` (independent duplicate) | `t.copy()` |
| `Text` | `&str` | `t.as_str()` or `&t` |
| `&str` | `&str` (sub-slice) | `s.slice(a, b)` |
| `&str` | `&life(static) str` | `keep(own(s))` (leaks; reported) |

There is no `Text::new()` either — an empty `Text` is `own("")`. One constructor, one spelling.

### 19.2 Methods

| Method | Signature | Notes |
|---|---|---|
| `length` | `(&self) -> u64` | **byte** length |
| `char_count` | `(&self) -> u64` | number of Unicode scalar values |
| `append` | `(&mut self, s: &str)` | grow, may reallocate |
| `truncate` | `(&mut self, n: u64)` | keep the first `n` bytes; must be a char boundary |
| `slice` | `(&self, a: u64, b: u64) -> &str` | byte range, `a <= b <= length` |
| `as_str` | `(&self) -> &str` | borrow the whole thing |
| `copy` | `(&self) -> Text` | independent duplicate |
| `find` | `(&self, needle: &str) -> Maybe<u64>` | first byte index |
| `char_at` | `(&self, byte_index: u64) -> char` | traps if not a boundary |

```c
fn first_word(text: &str) -> &str {
    let mut i: u64 = 0;
    while (i < text.length() and text.char_at(i) != ' ') {
        i += 1;
    }
    return text.slice(0, i);
}
```

Elision (E2) gives the result the life of `text`. No allocation, no copy, no `life` annotation.

### 19.3 Unicode honesty

- Indices are **byte** offsets, because `str` is a UTF-8 byte buffer.
- `slice` and `truncate` trap (`panic.not-a-char-boundary`) rather than split a codepoint.
- `char_at` reads one scalar value at a boundary; it does not index by character number.
- `for` does not iterate a `Text` in v0. If you need characters, index bytes and call `char_at`.

This is deliberately explicit rather than convenient: "length means bytes" is a sentence that prevents
a class of bugs, and hidden O(n) iteration is a v1 feature with its own design.

### 19.4 Equality and ordering

- `==` and `!=` compare byte sequences for `str` and `Text`.
- `<`, `<=`, `>`, `>=` on strings compare lexicographically by bytes (not locale-aware).
- Comparing `str` with `Text` is a fault; call `as_str()` or compare explicitly. No implicit coercion.

### 19.5 Formatting

```c
println("{}", name);          // display: strings print their bytes, numbers their value
println("{:?}", shape);       // structural debug, generated by the compiler
println("{:.2}", 3.14159);    // float precision
println("{} items", v.length());
```

- `{}` prints **through** any number of `&`, `&mut`, and `Heap<T>` levels.
- `{:?}` prints a structural form for any type: `Point { x: 1, y: 2 }`, `Has("x")`, `Empty`,
  `[1, 2, 3]`. It is compiler-generated; there is no formatting trait to implement.
- Mismatched placeholder counts are a fault (`syntax.format-arity`).
- Formatting is the only place the compiler generates code from a string; it is parsed at compile
  time, not interpreted at runtime.

---

## 20. Collections: `Vec`, arrays, slices

### 20.1 `Vec<T>`

```c
let mut v: Vec<u32> = Vec::new();   // the one constructor
v.push(10);
let last: Maybe<u32> = v.pop();     // Has(10)
```

| Method | Signature | Notes |
|---|---|---|
| `Vec::new` | `() -> Vec<T>` | empty, no allocation until first push |
| `push` | `(&mut self, T)` | may reallocate; invalidates live loans |
| `pop` | `(&mut self) -> Maybe<T>` | `Empty` when empty |
| `length` | `(&self) -> u64` | element count |
| `get` | `(&self, i: u64) -> Maybe<&T>` | checked, non-panicking |
| `get_mut` | `(&mut self, i: u64) -> Maybe<&mut T>` | checked, non-panicking |
| `slice` | `(&self, a: u64, b: u64) -> &[T]` | checked range |
| `slice_mut` | `(&mut self, a: u64, b: u64) -> &mut [T]` | checked range |
| `clear` | `(&mut self)` | drops elements, keeps capacity |
| `truncate` | `(&mut self, n: u64)` | drops the tail |
| `insert` | `(&mut self, i: u64, T)` | checked index |
| `remove` | `(&mut self, i: u64) -> T` | checked index, moves the tail |

- Capacity growth is conceptually `max(4, 2 * cap)`. `reserve(n)` is available; nothing else about
  capacity is promised.
- `push` and `insert` need `&mut self`, so they cannot run while any element is borrowed. That is
  where the "iterator invalidation" bug class goes to die.
- `Vec<T>` has `.copy()` **only when `T: copy`** — a deep copy of owning elements is written as a
  loop, on purpose. The language refuses to hide an allocation loop behind one method call.

```c
fn total(v: &Vec<u32>) -> u64 {
    let mut sum: u64 = 0;
    for (x : v) {
        sum += *x as u64;
    }
    return sum;
}
```

### 20.2 Arrays

```c
let mut a: [i32; 4] = [1, 2, 3, 4];
a[0] = 9;
let zeros: [u8; 8] = [0; 8];     // repeat form, `0` must be `copy`
```

- Length is part of the type; `a.length()` is a compile-time constant.
- A `[T; N]` is `copy` iff `T` is `copy`; then it is capped by the 128-byte copy limit.
- Indexing is checked; the check is usually removed by the optimizer when the index is provably in
  range (loop bounds).

### 20.3 Slices

```c
fn max_of(xs: &[i32]) -> Maybe<i32> {
    if (xs.length() == 0) {
        return Empty;
    }
    let mut best = xs[0];
    for (x : xs) {
        if (*x > best) {
            best = *x;
        }
    }
    return Has(best);
}

let v: Vec<i32> = Vec::new();
let s: &[i32] = v.slice(0, v.length());
max_of(s);
```

- A slice is a borrowed view: pointer plus length. No ownership.
- `&mut [T]` gives write access with the same exclusivity rule.
- Slices are the idiomatic parameter type for "read-only sequence"; `&Vec<T>` is for when you need
  `push`/`pop`.

### 20.4 Bounds faults

```c
let v: Vec<i32> = Vec::new();
let x = v[0];
```

```
runtime fault · panic.bounds
  at  main.lang:3:13
  got index 0, length 0
  why every `[]` is checked; a program cannot read outside its container
  fix use `v.get(0)` for a `Maybe<&i32>` instead of panicking
```

Bounds faults are **runtime** faults, not compile faults: the index is a runtime value. The compiler's
job is to make sure every container knows its length, never to trust an arithmetic result.

---

## 21. Destruction: `drop` and `discard`

### 21.1 The hook

```c
unchecked extern fn close(fd: u64) -> i32;

struct File { handle: u64; }

methods File {
    fn drop(self) {
        unchecked "handle is a valid OS descriptor owned by this File" {
            close(self.handle);
        }
    }
}
```

- A `drop` method takes `self` by value. It runs **before** the fields are destroyed.
- Fields are then destroyed in declaration order.
- Locals are destroyed in reverse declaration order, then parameters.
- A `drop` hook may not be defined on a `copy` type (`drop.on-copy-type`): copying would destroy the
  same value twice.
- A `drop` hook may not panic. If it does, the program aborts (`panic.in-drop`) — there is no unwinding
  through a second destructor.

### 21.2 `discard`

```c
let f = open_file("notes.txt");
discard(f);      // destroy now, not at `}`
```

`discard(x)` takes ownership and destroys immediately. It is the language's `drop(x)` builtin: explicit,
greppable, and useful when a resource must be released before a long computation.

### 21.3 `take` and partially moved values

If a field is moved out with `take`, the remaining fields still get destroyed at scope end; the
container cannot be read as a whole anymore, and reassigning it destroys the remainder first.

```c
struct Pair { a: Text; b: Text; }
let mut p = Pair { .a = own("x"), .b = own("y") };
let a = take(p.a);        // p.b is still owned, p is unreadable as a whole
p = Pair { .a = own("x"), .b = own("z") };  // old b destroyed here
```

### 21.4 Panics and destruction order (v0 aborts)

v0 panics **abort** the process: a report is printed and `abort()` is called. Destructors do not run at
the panic point. This is a deliberate simplification: unwinding requires landing pads, and "run
destructors during a second fault" is the most complicated corner of any ownership language. The OS
reclaims the memory; a process that is dying does not need to be tidy.

Panic kinds (all abort): `panic.explicit`, `panic.overflow`, `panic.divide-by-zero`,
`panic.shift-too-large`, `panic.bounds`, `panic.not-a-char-boundary`, `panic.out-of-memory`,
`panic.in-drop`.

---

## 22. `unchecked` and `Raw<T>`

This is the only place memory safety is not proven. It is called `unchecked` rather than `unsafe`
because the name describes **what the compiler stops doing**, not a vague property of the code.

> `unchecked` is not "dangerous code". It is "code the checker did not read".

### 22.1 The two forms

```c
// 1. a block: the unit of auditing
unchecked "why this is sound" {
    ...
}

// 2. a function: required when a raw type crosses the signature
unchecked fn peek(p: Raw<i32>) -> i32 {
    unchecked {
        return *p;
    }
}
```

- The reason string is optional syntax, required by `--strict` and by the `warn · seam.no-reason` lint.
  One block, one sentence: what did you check, and where?
- `unchecked` blocks are **statements**, not expressions. They produce no value. This is what keeps
  raw values from escaping into safe code through an expression position.
- `unchecked fn` is required if and only if `Raw<T>` appears in the signature. It is a type-level
  marker: "a raw address crosses this boundary".

### 22.2 What only `unchecked` may do

| Operation | Syntax | Why it is gated |
|---|---|---|
| Take an address | `raw(&x)`, `raw(&mut x)` | the result can outlive the borrow rules |
| Make a null address | `null<T>()` | there is no null in safe code |
| Read through a raw address | `*p` | bounds and initialization are unproven |
| Write through a raw address | `*p = v` | exclusivity is unproven |
| Pointer arithmetic | `p + n`, `p - n`, `p2 - p1` | scaled by `size_of(T)`, can leave any object |
| Raw casts | `p as Raw<u8>`, `n as Raw<i32>`, `p as u64` | type and provenance are dropped |
| Call a foreign function | `extern fn` call | the C side has no obligations to us |
| Call an `unchecked fn` | `peek(p)` | the signature admits raw addresses, so the call crosses the seam |
| Lossy numeric casts | `f64 as u8` | truncation and saturation are explicit here |

Everything else is still checked **inside** an `unchecked` block: types, moves, drops, bounds on
`v[i]`, integer overflow, format strings, exhaustiveness. `unchecked` turns off exactly one analyzer,
not the compiler.

### 22.3 What `unchecked` may not do

- **It may not leak a `Raw<T>` into safe code.** A `Raw` local declared inside the block dies at the
  block's `}`. Assigning it to an outer variable is `unchecked.raw-escapes`, and naming `Raw<T>` at all
  outside an `unchecked` block (or an `unchecked fn`) is the same fault.
- **It may not appear in a safe signature.** `fn f(p: Raw<u8>)` without `unchecked fn` is
  `unchecked.in-safe-signature`.
- **It may not extend a borrow.** A reference made with `&*p` is an ordinary checked borrow: it lives
  until its last use and must not outlive the storage.
- **It may not define types.** There are no unions, no layout attributes, no raw struct fields.

### 22.4 The contract

If you write an `unchecked` block, you are asserting all four of these:

1. **Bounds** — the address, plus the size of the access, lies inside one allocation.
2. **Alignment** — the address is aligned for `T`.
3. **Initialization** — the memory holds a valid `T` (bit patterns included: no invalid `char`,
   no invalid `bool`, no dangling `Text`).
4. **Exclusivity** — if you write, no other live reference aliases that memory.

Break one and the program has **undefined behavior**. This is the only UB in the language, and it can
only be reached from `unchecked` code. Everything else — a bad index, an overflow, a null `Maybe` — has
defined behavior (a report and an abort).

### 22.5 Example: skipping bounds checks in a hot loop

```c
fn checksum(bytes: &[u8]) -> u64 {
    let n = bytes.length();
    if (n == 0) {
        return 0;
    }

    let mut sum: u64 = 0;
    let mut i: u64 = 0;

    unchecked "p points into `bytes`, and i < n at every iteration" {
        let mut p: Raw<u8> = raw(bytes);
        while (i < n) {
            sum += *p as u64;
            p += 1;
            i += 1;
        }
    }

    return sum;
}
```

Note what stays checked: `sum` is a `u64` (no silent wrap), `i < n` is a `bool` comparison, the
`while` condition is checked, and the `unchecked` block's locals die at its `}`.

### 22.6 Example: calling C

```c
unchecked extern fn write(fd: i32, buf: Raw<u8>, count: u64) -> i64;

fn say(s: &str) {
    unchecked "write() only reads `count` bytes, and the slice outlives the call" {
        write(1, raw(s), s.length());
    }
}
```

- `raw(s)` on a `&str` yields `Raw<u8>` pointing at the first byte.
- `str` is **not** NUL-terminated. If the C side needs a terminator, you build one; the language will
  not silently append bytes you did not ask for.
- The return value is ignored here; a real wrapper would map it to `Maybe`/`i64` and report errors.

### 22.7 Re-entering the checked world

```c
unchecked "the caller guaranteed len >= 1" {
    let p: Raw<u8> = raw(bytes);
    let b: &u8 = &*p;      // this borrow is ordinary and fully checked from here on
    total += *b as u64;
}
```

The dereference is unchecked; the resulting reference is not. That is the seam: raw on one side,
checked on the other, and the block boundary is where the transfer happens.

### 22.8 Auditing

| Command | What it prints |
|---|---|
| `--report=seams` | every `unchecked` block, every `unchecked fn`, every `keep`, with file, line, and reason |
| `--strict` | requires a reason string on every block |
| `--forbid=unchecked` | refuses to build if a single `unchecked` block exists (for safety-critical profiles) |
| `--forbid=keep` | same, for deliberate leaks |
| `--explain unchecked` | the long-form rulebook |

A project's safety claim is therefore measurable: "zero `unchecked` lines outside `src/ffi.lang`, and
those four have reasons." That is a sentence a reviewer can check.

### 22.9 Why not per-operation `unsafe fn`?

Because a block is the smallest thing a human can audit. One block, one reason, one entry in the
report. A per-operation marker (a cast here, a deref there) produces a hundred tiny islands with no
shared justification; a block forces the justification to be written once, next to the code it covers.

---

## 23. Reports: the compiler's error format

Compile errors are the language's most-read documentation. Most programmers will meet the report
before they meet the reference manual, so the report *is* the teaching surface. This design gives it
a fixed shape, a named identity, and a machine-readable twin.

### 23.1 The four questions

Every report answers four questions, in this order, and the layout makes the order visible:

| # | Question | Where it is answered |
|---|---|---|
| 1 | **What broke?** | header: `fault · <id>` and the one-line summary |
| 2 | **Where?** | header: `file:line:col`, then the marked source lines |
| 3 | **Whose rule is it?** | `├ rule` line, citing the plain-language rule |
| 4 | **How do I fix it?** | `├ fix` lines, with compilable code |

If a report cannot answer all four, it is not finished. That is a compiler contribution rule, not a
style preference: the test suite asserts that every report has a rule line and at least one span.

### 23.2 Severity words

| Word | Meaning | Effect |
|---|---|---|
| `fault` | the program is not well-formed | build stops, exit code `1` |
| `warn` | the program builds, but something is suspicious | build continues, exit code `0` |
| `runtime fault` | the program was well-formed and stopped while running | process aborts, exit code `101` |

The word `error` is deliberately not used. "Fault" is a property of the program; "error" sounds like a
property of the programmer. The same vocabulary covers compile time and run time, so beginners do not
have to learn two taxonomies.

### 23.3 Anatomy

```
╭─ fault · borrow.conflict ──────────────────────────────── main.lang:8:5
│
│    6 │     let first = &v[0];
│      │                  ◀──── shared loan of `v` starts here
│    7 │     v.push(2);
│      │     ◀──── needs `&mut v` while the loan is alive
│
├ rule  many `&`, or one `&mut`, never both while alive
├ got   one live shared loan at the moment of the `push`
├ fix   finish with the borrow first:
│           println("{}", v[0]);
│           v.push(2);
╰ see   `--explain borrow.conflict`
```

The parts, top to bottom:

1. **Corner + identity**: `╭─ fault · borrow.conflict`. The ID is the stable name; the severity is the
   first word so it is greppable (`grep '^╭─ fault'`).
2. **Location**: `main.lang:8:5` — the primary span. Editors parse this exact suffix.
3. **Source block**: line numbers in a gutter, `│` separating gutter from source. Source is reproduced
   exactly, including indentation, and is never wrapped.
4. **Markers**: `◀────` under the relevant columns, followed by a label. Multiple markers per span
   group are normal, and they are ordered top-to-bottom in source order, so the report reads like a
   sentence written down the page.
5. **Labelled lines**: `rule`, `got`, `want`, `note`, `why`, `fix`, `from`. One per line, aligned in a
   five-character column.
6. **Suggestions**: `fix` lines contain **compilable code**, indented under the label with `│`
   continuation, so you can copy-paste instead of translating prose.
7. **Footer**: `╰ see …` points at the long-form explanation or the exact command to learn more.

### 23.4 The format rules

These are normative; the formatter and the test suite enforce them.

| Rule | Why |
|---|---|
| The primary location is always in the header | tooling can jump without parsing the body |
| Source lines are shown unmodified, never reflowed | the reader is looking at their file |
| At most 6 source lines per report, never a whole function | reports must fit on a terminal |
| Markers are `◀` + label; never `^` chains | a word is more useful than a caret run |
| Labels come from a closed set (§23.5) | predictable scanning |
| `fix` code must compile if applied verbatim | trust |
| No IDs like `E0382` | a name is memorable; a number is not |
| Reports are ordered by primary span, ascending | reading the build output walks down the file |
| A report never says "invalid" without saying what would be valid | `got`/`want` or a `fix` |

### 23.5 The label set

| Label | Meaning | Example |
|---|---|---|
| `rule` | the plain-language rule being broken | `a value has exactly one owner` |
| `got` | what the compiler found | `` `Text` (owning, not `copy`) `` |
| `want` | what it needed instead | `` `u64` `` |
| `note` | extra context the reader needs | `push may reallocate the buffer` |
| `why` | why the rule exists | ``so `first` would not point at freed memory`` |
| `from` | where a value/type originated | `name created here` |
| `fix` | a concrete edit, compilable | `peek(&name); consume(name);` |
| `see` | pointer to long-form help | `` `--explain life.outlives` `` |

### 23.6 Identity: `area.slug`, never a number

Every report has a stable ID of the form `<area>.<slug>`:

| Area | Covers | Examples |
|---|---|---|
| `syntax` | the parser | `syntax.missing-semicolon`, `syntax.assignment-is-not-an-expression` |
| `name` | resolution | `name.not-found`, `name.duplicate` |
| `type` | type checking | `type.mismatch`, `type.not-a-bool`, `type.not-copy`, `type.infinite-size` |
| `init` | initialization | `init.read-before-write`, `init.missing-field` |
| `move` | ownership | `move.after-handoff`, `move.maybe-moved`, `move.partial` |
| `borrow` | aliasing | `borrow.conflict`, `borrow.while-iterating` |
| `life` | regions | `life.outlives`, `life.cannot-elide`, `life.temporary` |
| `switch` | patterns | `switch.not-exhaustive`, `switch.unreachable-arm` |
| `control` | flow | `control.missing-return`, `control.break-outside-loop` |
| `drop` | destruction | `drop.on-copy-type`, `drop.panics` |
| `unchecked` | the seam | `unchecked.missing-block`, `unchecked.raw-escapes`, `unchecked.in-safe-signature` |
| `copy` | copy marker | `copy.too-large`, `copy.field-not-copy` |
| `assign` | mutation | `assign.not-mutable` |
| `extern` | FFI | `extern.unknown-symbol`, `extern.abi-mismatch` |
| `seam` | warnings about the seam | `seam.no-reason` |
| `panic` | runtime | `panic.bounds`, `panic.overflow` |
| `compiler` | internal | `compiler.internal` (this one is a bug in the compiler) |

Why names instead of codes:

- **Greppable in a codebase.** `--forbid=unchecked` and `--allow=seam.no-reason` need names; nobody
  remembers that `E0382` is "use of moved value" and `E0505` is "cannot move out because borrowed".
- **Stable across compiler versions** without a lookup table.
- **Self-describing in a bug report.** "I hit `life.temporary` on this snippet" needs no decoder ring.
- **A name can be wrong in a readable way.** `move.after-handoff` is a sentence; `E0382` is a scar.

The IDs are a public API: renaming one is a breaking change and goes through the deprecation process
(`warn · compiler.renamed-id`, old ID accepted for two releases).

### 23.7 More reports, in full

**Type mismatch, no implicit conversion:**

```
╭─ fault · type.mismatch ────────────────────────────────── main.lang:12:24
│
│   12 │     let total: u64 = count + 1;
│      │                      ◀──── this is `u32`
│      │                              ◀ this literal is `u32` too
│
├ rule  no implicit conversions, not even widening ones
├ want  `u64`
├ got   `u32`
├ fix   convert on purpose:
│           let total: u64 = count as u64 + 1;
├ note  `count as u64` is a total conversion: every `u32` fits in a `u64`
╰ see   `--explain type.mismatch`
```

**Uninitialized read:**

```
╭─ fault · init.read-before-write ───────────────────────── main.lang:10:21
│
│    6 │     let label: &str;
│      │         ◀──── declared without a value
│    7 │     if (n > 0) {
│    8 │         label = "positive";
│    9 │     }
│      │     ◀──── only this branch writes `label`
│   10 │     println("{}", label);
│      │                    ◀──── read on a path where it was never written
│
├ rule  a value must be written on every path before it is read
├ got   1 of 2 paths initialize `label`
├ fix   cover the other branch:
│           } else {
│               label = "zero or negative";
│           }
╰ see   `--explain init.read-before-write`
```

**A raw type escaping the seam:**

```
╭─ fault · unchecked.raw-escapes ────────────────────────── main.lang:4:9
│
│    4 │     let p: Raw<u8>;
│      │            ◀──── a raw type declared outside any `unchecked` block
│    5 │     unchecked {
│    6 │         p = raw(&x);
│      │             ◀──── the address would outlive the block that justified it
│    7 │     }
│
├ rule  `Raw<T>` exists only inside `unchecked`; it may not escape into safe code
├ note  a raw address has no bounds, no life, and no owner to check it
├ fix   keep the pointer and every use of it in one block:
│           unchecked "x is 1 byte" {
│               let q: Raw<u8> = raw(&x);
│               *q = 1;
│           }
╰ see   `--explain unchecked`
```

**Missing `unchecked` block:**

```
╭─ fault · unchecked.missing-block ──────────────────────── main.lang:2:14
│
│    1 │ unchecked fn get(p: Raw<i32>) -> i32 {
│    2 │     let n = *p;
│      │              ◀──── dereference of `Raw<i32>` outside any `unchecked` block
│
├ rule  raw dereference is unchecked code, and unchecked code is written down
├ fix   mark the block and give the reason:
│           let mut n: i32 = 0;
│           unchecked "p is valid for one i32" {
│               n = *p;
│           }
│           return n;
├ note  the block is a statement, so the value is written to `n` inside it
╰ see   `--explain unchecked`
```

**A warning:**

```
╭─ warn · seam.no-reason ────────────────────────────────── ffi.lang:22:5
│
│   22 │     unchecked {
│      │     ◀──── no reason given for this block
│
├ rule  every unchecked block states what was checked, in one sentence
├ fix   add the reason string:
│           unchecked "handle was opened by `open_file` and is owned by `self`" {
├ note  silence with `--allow=seam.no-reason`, or enforce with `--strict`
╰ see   `--explain seam.no-reason`
```

### 23.8 Runtime faults use a different shape

Compile reports are *read*; runtime faults are *grepped out of a log*. So they get a flat, one-line
prefix and no box drawing:

```
runtime fault · panic.bounds
  at   main.lang:3:13 in `main`
  got  index 0, length 0
  why  every `[]` is checked; a program cannot read outside its container
  fix  use `v.get(0)` for a `Maybe<&i32>` instead of panicking
  note v0 aborts here; destructors do not run
```

- Always starts in column 0 with `runtime fault · <id>`.
- No caret art, because the log may be a pipe, a journal, or a CI transcript.
- A backtrace follows in debug builds, one frame per line, innermost first.

### 23.9 Ordering, grouping, and limits

- Reports sort by file, then by primary span, ascending. Multiple faults in one function therefore read
  top-to-bottom like the source.
- A "did you mean" is never a separate report; it is a `fix` on the report that failed.
- Cascading faults are suppressed: after a type mismatch, uses of that expression do not produce more
  type faults. One cause, one report.
- `--max-faults=N` caps output (default 50) and appends `… 12 more faults (--max-faults=0 to see all)`.
- A clean build prints nothing at all. No "Compiling…", no banner; stdout is for the program under
  test and for reports.

### 23.10 Machine-readable twin

Every report has a JSON form (`--report=json`, one object per line, stable keys):

```json
{
  "report": "borrow.conflict",
  "severity": "fault",
  "summary": "cannot borrow `v` as mutable while a shared loan is alive",
  "primary": {"file": "main.lang", "line": 8, "col": 5, "end_line": 8, "end_col": 12},
  "spans": [
    {"file": "main.lang", "line": 6, "col": 18, "label": "shared loan of `v` starts here", "role": "origin"},
    {"file": "main.lang", "line": 7, "col": 5,  "label": "needs `&mut v` while the loan is alive", "role": "primary"},
    {"file": "main.lang", "line": 8, "col": 24, "label": "loan is alive because of this use", "role": "use"}
  ],
  "rule": "many `&`, or one `&mut`, never both while alive",
  "notes": ["push may reallocate the buffer, so `first` would point at freed memory"],
  "fixes": [
    {"title": "finish with the borrow first",
     "code": "println(\"{}\", v[0]);\nv.push(2);\n",
     "applicability": "manual"}
  ],
  "explain": "borrow.conflict"
}
```

- `role` is one of `primary`, `origin`, `use`, `conflict`, `note`.
- `applicability` is `machine` (safe to apply unattended) or `manual` (a human must choose).
- The text renderer is a pure function of this object; there is one report model, two views.

### 23.11 Fix-its

```console
$ lang --fix main.lang
fixed 2 of 3 suggestions
  main.lang:8:5   borrow.conflict        applied  (manual review advised)
  main.lang:12:24 type.mismatch         applied
  main.lang:22:5  seam.no-reason        skipped (no machine-applicable fix)
```

- Only `applicability: "machine"` edits are applied without confirmation.
- A fix that would change meaning (adding a `copy()`, adding an `unchecked` block) is `manual`.
- `--fix --dry-run` prints the patch instead of writing.

### 23.12 `--explain`

```console
$ lang --explain move.after-handoff
```

prints the long-form page for that ID: the rule, two worked examples, the three most common causes, and
the connection to the other rules. The same text lives in the compiler repository at
`reports/<id>/explain.md`, which means the documentation ships with the compiler and cannot drift.

### 23.13 The report is a test case

Each ID owns a directory with at least one source file and the expected report text:

```
reports/
  move.after-handoff/
    explain.md
    case-01.lang
    case-01.expect
  borrow.conflict/
    explain.md
    case-01.lang
    case-01.expect
```

The test suite diffs the rendered report against `.expect` byte for byte. A report that changes
wording changes a fixture — which is exactly the review you want on the most-read text in the project.

### 23.14 Accessibility and plain output

- Colour is never load-bearing: every distinction is also carried by a word (`fault`, `warn`) and a
  glyph.
- `--ascii` replaces `╭ │ ├ ╰ ◀` with `+ | + + <`, for terminals, fonts, and screen readers that
  cannot render box drawing.
- No spinner, no progress bar, no animation in compiler output.
- Line numbers are never abbreviated (`8` is never `…8`), because copy-pasting a line number into an
  editor is the most common next action.

---

## 24. How the compiler proves it

This section is the "why it is not vibes" section. It describes the analyses in enough detail that an
implementer could start, and enough plain language that a user can predict what the checker will say.

### 24.1 Places, not expressions

The checker talks about **places**: a root local plus a path of projections.

```
place := local
       | place . field
       | place [ index ]      (a runtime index, treated as the whole container for loans)
       | * place              (deref of &, &mut, or Heap)
```

`p.x`, `v[3]`, `*b`, `self.pos` are places. Borrows, moves, and initialization are all properties of
places. This is why `&p.x` and `&mut p.y` do not conflict: they are different places.

### 24.2 Initialization and moves are one analysis

A moved variable and an uninitialized variable have the same problem: there is nothing there to read.
So the compiler runs **one** must-analysis over the control-flow graph, with this lattice per place:

```
        Init            (has a live value)
       /    \
  Moved     Uninit      (both mean "no value"; `Moved` remembers why)
```

- At a **join** (after `if`/`switch`/loop), the result is `Init` only if every incoming path is `Init`;
  otherwise it is the merged "no value" state and the report says `move.maybe-moved` or
  `init.read-before-write`, whichever cause applies.
- A read requires `Init`.
- A move sets the place to `Moved`.
- An assignment sets the place to `Init` (and destroys the old value first if it was `Init`).
- `switch (owned)` sets the subject to `Moved` after the switch.
- `take(p.f)` sets `p.f` to `Moved` and `p` to `Partial`.

The two report IDs exist because the *advice* differs: "you never wrote it" versus "you gave it away".
Same analysis, different sentence.

### 24.3 Loans

A **loan** is created by `&place` or `&mut place`:

```
loan = { place, mutability (shared | exclusive), region }
```

Loans die at the last use of any reference derived from them — that is the liveness-based rule from
§16.2. The checker does not use the enclosing block as the region; it uses the set of program points
between creation and last use, which is computed by a backwards liveness pass over the reference's
value.

Conflict rules, at any program point:

| Access to place `P` | Requires |
|---|---|
| read `P` | no live **exclusive** loan on `P` or an ancestor of `P` |
| write `P` | no live loan (shared or exclusive) on `P` or an ancestor of `P` |
| `&P` | no live exclusive loan on `P` or an ancestor of `P` |
| `&mut P` | no live loan of any kind on `P` or an ancestor of `P` |
| disjoint sibling places | no interaction at all |

- "Ancestor" matters: a loan on `v` conflicts with `v[0]`, because indexing is a projection of `v`.
  A loan on `v[0]` does **not** conflict with `v.length()`, because `length` only reads the header
  fields and the checker models methods on built-in containers with a field-level summary
  (`v.len` is a read, `v.ptr` is a read, `push` writes all three plus the buffer).
- Reborrowing creates a child loan whose region is inside the parent's. That is how
  `fn bump(n: &mut u32)` can be called twice in a row.

### 24.4 Regions and `life`

For a single function body, regions are inferred from liveness. Across a call, regions become
constraints:

```
&life(a) str  ->  &life(b) str     requires  a ⊒ b   (a outlives b)
&mut life(a) T                     is invariant in a
T                              no constraint
```

The compiler builds a directed graph of "outlives" edges, adds the declared `life` parameters as
roots, and computes the transitive closure. Two checks fall out:

1. **Dangling return**: the returned reference's region must be implied by an input region or a
   `static` region. If not, `life.outlives`.
2. **Elision**: rules E1–E3 are just constraint generation; E4 is the error when no constraint can be
   generated.

This is the whole lifetime system. There is no "region variable" visible to the user, no `'a` notation,
and no way to name a region on a local. If the constraints cannot be solved, the report tells you which
parameter to annotate.

### 24.5 The list-walk exception, precisely

§16.3 said loans attach to storage, not variables. Implementation-wise:

- When a place is reached through a deref (`*p`, or `.` through `&`/`Heap`), the loan is keyed by the
  **allocation identity** of the referent, not by the local variable that held the reference.
- Assigning to that local (`cur = &node.next`) is a write to the local's slot. It does not write the
  allocation, so it does not conflict with the loan.
- Writing **through** the reference (`*cur = ...`) does write the allocation, and it does conflict with
  a live shared loan. That is the rule you actually want.

This is a deliberate, documented deviation from the "borrow is a loan on the local path" model. It
costs a little analysis (allocation identity must survive reassignment) and buys the natural
pointer-walk idiom without indices or raw pointers.

### 24.6 Drop insertion

After checks pass, the compiler inserts destruction calls:

- At every scope exit (falling off the end, `return`, `break`, `continue`), for every place that is
  `Init` along that path, in reverse declaration order.
- `switch` arms destroy their own arm bindings when the arm ends.
- A `take`n field is not destroyed by the container; the moved-out value is destroyed by its new owner.
- A value that is returned is moved out before the epilogue, so it is not destroyed.
- Panic paths do not exist (v0 aborts), which removes landing pads from the whole design.

### 24.7 Exhaustiveness

Patterns are compiled into a matrix (one column per payload position, one row per arm, `default` is a
wildcard row). Coverage is decided by the standard usefulness algorithm, which is also what produces
the *witness* in the report:

```
missing case: Dot
missing case: Rect(_, 0.0)     ← witnesses can be partial, which is why they read like examples
```

- Redundant arms are `warn · switch.unreachable-arm`.
- `default` is a wildcard row, so it always closes the matrix. The report's second `fix` exists to make
  the trade-off visible: a `default` silences future variants too.
- Exhaustiveness runs on the typed AST; it needs types only to know the variant set and the arity.

### 24.8 What is checked, where

| Property | Pass | Kills |
|---|---|---|
| syntax | parse | malformed programs, assignment-in-condition |
| names | resolution | typos, duplicate definitions |
| types | checking | implicit conversions, arity, field existence |
| copy legality | type checking | copying owning types, oversized copies |
| exhaustiveness | pattern matrix | forgotten enum cases |
| initialization | dataflow | uninitialized reads |
| moves | dataflow | use-after-free, double free |
| loans | liveness + regions | aliasing, iterator invalidation |
| lives | constraint solver | dangling references |
| drops | insertion pass | leaks |
| seam | AST lint | unreasoned or escaped `unchecked` |

### 24.9 Termination, speed, and the on-save budget

- Every pass is linear or near-linear in the size of the function; there is no whole-program
  inference, no fixpoint over the call graph.
- Borrow checking is per-function. Cross-function facts are entirely in signatures (types + `life`),
  which is why signatures are also the documentation.
- The design target is: a 100k-line project re-checks in under a second in release mode, so the checker
  can run on every save.

### 24.10 The soundness argument, in one paragraph

Assume a program passes all checks. Every allocation has exactly one owning place at every program
point (R1: moves preserve one owner, `new` creates one, `copy` only duplicates `copy` values which
own nothing). Every owning place is destroyed exactly once, at a point where it is `Init` (R2 + drop
insertion + the init analysis). Every live reference points into an allocation that is live at that
point (R5: regions are constrained by `life`, and loans require the referent to be `Init`). Every
access to a borrowed place is compatible with all live loans (R4: the conflict table). Therefore no
read or write can touch freed or uninitialized memory in a program with no `unchecked` block, and no
allocation can be freed twice. `unchecked` blocks are the only holes, and they are audited by
construction (§22.4).

### 24.11 What the checker does not prove

- **Termination.** A `while (true)` loop is legal.
- **Panic freedom.** Bounds checks and overflow traps can still fire; they abort safely.
- **Functional correctness.** Types and ownership say nothing about whether the program is right.
- **Data-race freedom.** v0 is single-threaded. When threads arrive, R4 is the rule that extends
  (Send-like: transferring ownership gives exclusive access; `&T` sharing requires `T` to be immutable
  and copyable).

---

## 25. Pipeline and backends

### 25.1 The stages

| # | Stage | Input → output | Can fail with |
|---|---|---|---|
| 1 | lex | bytes → tokens | `syntax.*` |
| 2 | parse | tokens → AST | `syntax.*` |
| 3 | resolve | AST → HIR with IDs | `name.*` |
| 4 | type check | HIR → typed HIR | `type.*`, `copy.*` |
| 5 | exhaustiveness | typed HIR | `switch.*` |
| 6 | dataflow | typed HIR → MIR | `init.*`, `move.*` |
| 7 | borrow + lives | MIR | `borrow.*`, `life.*` |
| 8 | drop insertion | MIR → MIR' | `drop.*` |
| 9 | lower | MIR' → C11 or LLVM IR | `compiler.internal` |
| 10 | link | objects → executable | `extern.*`, linker errors |

- **HIR** keeps names, types, and source spans: it is what reports point at.
- **MIR** is a control-flow graph of basic blocks over places and temporaries: it is what the dataflow
  and borrow checks consume. It is also where `--report=json` gets the `use`/`origin` span roles.
- Errors never escape as panics. An internal fault prints `compiler.internal` with the source snippet
  and a "this is a bug" footer, and exits `70`.

### 25.2 Emitting C first

The primary backend emits **C11** plus a ~400-line runtime. It is the friendliest first backend for
three reasons: you can read the output, you can compile it with anything, and you can diff two
versions of the generated code when a bug smells like a codegen issue.

The mapping is deliberate and boring:

| Language construct | Emitted C |
|---|---|
| `Text` | `struct { uint8_t *ptr; uint64_t len; uint64_t cap; }` |
| `Vec<T>` | `struct { T *ptr; uint64_t len; uint64_t cap; }` |
| `Heap<T>` | `T *` (unique, freed by owner) |
| `&T`, `&mut T` | `const T *`, `T *` |
| `Maybe<T>` | `struct { bool has; union { T value; } }` or a tagged struct |
| move | `memcpy` + debug poison of the source |
| `drop` | `Type_drop(&place)` calls at scope exit |
| `switch` | `switch` on a tag, one `case` per variant, no fallthrough |
| `v[i]` | `(*rt_index(&v, i, file, line))` |
| `a + b` on ints | `rt_add_i32(a, b, file, line)` in debug, plain `+` where overflow is proven |
| `unchecked { }` | the body, verbatim |
| `keep(x)` | `rt_leak(x)` |

- `restrict` is emitted for `&mut` parameters, because R4 already proves exclusivity. That is a free
  optimization that falls out of a safety rule.
- Debug builds poison moved-from memory, fill fresh allocations with `0xAA`, and keep every bounds
  check. Release builds remove checks that range analysis proves redundant, but never change
  semantics.
- Builds are deterministic: no timestamps, no paths, no random hashes in symbol names.

### 25.3 Why not LLVM first

LLVM gives better code and worse debuggability of the compiler itself. The C backend is the reference
semantics: if the C output is wrong, you can read it. LLVM is the second backend, and its only job is
to be faster, not to be the definition of the language.

### 25.4 The driver

```console
$ lang build main.lang -o hello
$ lang build main.lang --emit=c > main.c        # inspect the generated C
$ lang check main.lang                          # parse + check, no codegen, fastest
$ lang run main.lang
$ lang --explain borrow.conflict
```

- `check` is the on-save mode: no codegen, no linking, reports only.
- `--emit=c`, `--emit=ir`, `--emit=asm` for inspection.
- There is no package manager in v0, no build script, no macros. One file in, one binary out.

### 25.5 Bootstrapping

The first compiler is written in C, with the five rules applied by hand and reviewed. The second
compiler is written in the language once the language can express a compiler (needs `Vec`, `Text`,
enums, `switch`, `Heap`, and `unchecked` for the syscall seam — which is exactly the v0 feature set).
That is the milestone that proves the design is not a toy: **the language must be able to implement its
own checker**.

---

## 26. Runtime and memory model

### 26.1 What a value is

A value is a contiguous block of bytes with a type that says how to read, copy, and destroy it:

```
fn f() {
    let t: Text = own("hello");
}
```

```
stack frame of f                    heap
┌────────────────────────┐         ┌──────────────────┐
│ t: Text                │         │ 'h' 'e' 'l' 'l' 'o' │
│   ptr ─────────────────┼────────▶│                  │
│   len = 5              │         └──────────────────┘
│   cap = 5              │
└────────────────────────┘
   at `}`: Text_drop(&t) → free(t.ptr)
```

- Fields are laid out in declaration order, naturally aligned. There is no field reordering in v0.
- Padding bytes exist but are never observable: there is no `memcmp` on values, no structural `==` on
  owning types, and no serialization by `transmute`.
- `Heap<T>` is one pointer. `Vec<T>`/`Text` are three words. `Maybe<Heap<T>>` is one pointer plus a tag,
  or a null-pointer optimization internally — but never a null in the type system.

### 26.2 What allocates

| Operation | Allocates? | When freed |
|---|---|---|
| `new expr` | yes, one value | owner's scope end, or `keep` |
| `own(str)` | yes, bytes | owner's scope end |
| `t.append(...)` | maybe, when growing | with the `Text` |
| `v.push(...)` | maybe, when growing | with the `Vec` |
| `Vec::new()` | no, until first push | — |
| `keep(x)` | no, but never freed | process exit |
| `println` | may allocate for formatting | immediately, inside the call |
| any `&`/`&mut` | no | — |
| move, copy, drop | no | — |

Every allocation is visible in the source as `new`, `own`, or a container growth. Nothing allocates
behind a `+` or a function call you did not write.

### 26.3 Equality

| Types | `==` |
|---|---|
| integers, floats, `bool`, `char` | value equality (`NaN != NaN`) |
| `str`, `Text` | byte equality |
| `&T`, `&mut T` | pointer identity (use `*a == *b` for value equality) |
| `copy struct` / `copy enum` | **structural**, field by field, generated |
| owning `struct` / `enum` | not available; write a method |
| `Maybe<T>` | structural if `T` supports `==` |
| `Heap<T>` | not available (owning type); compare addresses only inside `unchecked` |

Structural equality for `copy` types is generated field-wise, so padding never matters and behavior is
not dependent on uninitialized bytes. Owning types get no `==` because "same bytes" and "same owner"
are different questions, and the language refuses to guess.

### 26.4 Statics, constants, and globals

- **No mutable globals in v0.** No `static mut`, no interior mutability, no lazy initialization, no
  init-order bugs.
- `const NAME: T = <const-expr>;` is allowed: literals, arithmetic, and other constants. A `const` is
  inlined at every use; it has no address.
- String literals live in read-only data for the whole program: `&life(static) str`.

### 26.5 The runtime

The entire runtime is roughly:

```
rt_alloc(size, align)        → abort with panic.out-of-memory on failure
rt_free(ptr)
rt_index(v, i, file, line)   → abort with panic.bounds
rt_add_i32 / rt_mul_i64 / …  → checked arithmetic, abort with panic.overflow
rt_div / rt_rem             → abort with panic.divide-by-zero
rt_shift                    → abort with panic.shift-too-large
rt_abort(id, msg, file, line) → print a runtime fault, flush, abort
rt_leak(x)                   → record the leak, return the address
formatting helpers           → for `{}` / `{:?}` / `{:.N}`
```

- No GC, no scheduler, no thread library, no `atexit` chain, no dynamic loading.
- `rt_leak` records leaked bytes and prints a summary at exit in debug builds. It cannot reclaim
  anything; it exists so `keep` is visible.
- The runtime never allocates on its own except during formatting, and that allocation is freed before
  the formatting call returns.

### 26.6 Leak freedom, stated carefully

> In safe code with no `keep` and no `unchecked`, every heap allocation is freed exactly once, before
> the process exits.

The proof is the ownership tree: each allocation has exactly one owning place; every owning place is
destroyed at a statically known point (drop insertion); moves preserve the count of owning places;
therefore each allocation is destroyed exactly once. Cycles cannot exist (no shared ownership), so
there is no reachable-but-undestroyed case. `keep` and `unchecked` are the two documented exits from
this theorem, and both appear in `--report=seams`.

### 26.7 Memory safety is not the same as correctness

A program can be memory-safe and completely wrong: it can print the wrong answer, loop forever, or
abort on a bounds check. The claim of this language is narrow and absolute: **no safe program touches
memory it does not own, no safe program reads memory that was never written, and no safe program
outlives its own data.** Everything else is still your job.

---

## 27. Idioms and worked examples

### 27.1 FizzBuzz, in full

```c
fn fizz(n: u32) {
    if (n % 15 == 0) {
        println("FizzBuzz");
    } else if (n % 3 == 0) {
        println("Fizz");
    } else if (n % 5 == 0) {
        println("Buzz");
    } else {
        println("{}", n);
    }
}

fn main() {
    for (let mut i: u32 = 1; i <= 100; i += 1) {
        fizz(i);
    }
}
```

No early free, no `int` width guessing, no format-string mismatch.

### 27.2 A stack machine: `Vec` + `enum` + `switch`

```c
copy enum Op { Push(i64), Plus, Times, Pop, }

fn run(program: &Vec<Op>) -> Maybe<i64> {
    let mut stack: Vec<i64> = Vec::new();

    for (op : program) {
        switch (op) {
            case Push(n): {
                stack.push(*n);
            }
            case Plus: {
                if (stack.length() < 2) {
                    return Empty;
                }
                let y = or(stack.pop(), 0);     // safe: length checked above
                let x = or(stack.pop(), 0);
                stack.push(x + y);
            }
            case Times: {
                if (stack.length() < 2) {
                    return Empty;
                }
                let y = or(stack.pop(), 0);
                let x = or(stack.pop(), 0);
                stack.push(x * y);
            }
            case Pop: {
                if (stack.length() == 0) {
                    return Empty;
                }
                discard(stack.pop());
            }
        }
    }

    return stack.pop();     // exactly one value left → Has(it)
}

fn main() {
    let mut program: Vec<Op> = Vec::new();
    program.push(Op::Push(2));
    program.push(Op::Push(3));
    program.push(Op::Plus);
    program.push(Op::Push(4));
    program.push(Op::Times);

    switch (run(&program)) {
        case Has(n): { println("{}", n); }   // 20
        case Empty:  { println("bad program"); }
    }
}
```

Note `or(m, default)` as the honest alternative to `unwrap`. It is not a hidden panic: the fallback is
written at the call site, and it is a plain value.

### 27.3 A linked list that walks itself

```c
struct Node {
    value: i32;
    next: Maybe<Heap<Node>>;
}

fn sum(head: &Maybe<Heap<Node>>) -> i32 {
    let mut total: i32 = 0;
    let mut cur: &Maybe<Heap<Node>> = head;
    while (true) {
        switch (cur) {
            case Has(node): {
                total += node.value;
                cur = &node.next;
            }
            case Empty: {
                return total;
            }
        }
    }
}
```

Three rules working together: `Heap` gives the indirection that makes the type finite; `Maybe` gives
the end of the list; and §16.3 (loans attach to storage) makes the walk expressible with a borrow
instead of an index.

Destroying the list is not shown because there is nothing to write: when the head's owner dies, the
compiler-generated recursive drop walks `next` and frees every node.

### 27.4 The honest answer for graphs and doubly linked lists

Safe code has no shared ownership, so graphs are stored as **indices**:

```c
struct Graph {
    edges: Vec<Vec<u64>>,
}

methods Graph {
    fn new() -> Graph {
        return Graph { .edges = Vec::new() };
    }

    fn add_node(&mut self) -> u64 {
        self.edges.push(Vec::new());
        return self.edges.length() - 1;
    }

    fn link(&mut self, from: u64, to: u64) {
        if (from < self.edges.length() and to < self.edges.length()) {
            self.edges[from].push(to);
        }
    }
}

fn reachable(g: &Graph, start: u64) -> Vec<u64> {
    let n = g.edges.length();

    let mut seen: Vec<bool> = Vec::new();
    for (let mut i: u64 = 0; i < n; i += 1) {
        seen.push(false);
    }
    if (start >= n) {
        return Vec::new();
    }

    let mut queue: Vec<u64> = Vec::new();
    queue.push(start);
    seen[start] = true;

    let mut head: u64 = 0;
    while (head < queue.length()) {
        let node = queue[head];
        for (next : &g.edges[node]) {
            if (not seen[*next]) {
                seen[*next] = true;
                queue.push(*next);
            }
        }
        head += 1;
    }

    return queue;
}
```

A doubly linked list is the same trick with two index fields:

```c
struct Slot {
    value: i32;
    next: Maybe<u64>,
    prev: Maybe<u64>,
}

struct List {
    slots: Vec<Maybe<Slot>>,   // Empty = free slot
    head: Maybe<u64>,
    tail: Maybe<u64>,
}
```

- Every mutation is index bookkeeping; no borrow survives a `push`.
- Indices are `Maybe<u64>` because "no next" is a real case, not a sentinel.
- A stale index is a bounds fault at runtime, never a dangling pointer. That is the trade: you get
  panic-on-use-after-remove instead of UB.

This is wordier than a pointer graph. It is also completely checked, and it is the same trade every
GC-free language makes. The design's position is: make it easy to write the wordy version, and make
the linear version impossible by accident.

### 27.5 A view that outlives its cursor: `life` in anger

```c
struct Words<life a> {
    text: &life(a) str;
    pos: u64;
}

methods<life a> Words<life(a)> {
    fn new(text: &life(a) str) -> Words<life(a)> {
        return Words { .text = text, .pos = 0 };
    }

    fn next_word(&mut self) -> Maybe<&life(a) str> {
        while (self.pos < self.text.length() and self.text.char_at(self.pos) == ' ') {
            self.pos += 1;
        }
        if (self.pos == self.text.length()) {
            return Empty;
        }

        let start = self.pos;
        while (self.pos < self.text.length() and self.text.char_at(self.pos) != ' ') {
            self.pos += 1;
        }
        return Has(self.text.slice(start, self.pos));
    }
}

fn main() {
    let text = own("the quick brown fox");
    let mut w = Words::new(text.as_str());

    while (true) {
        switch (w.next_word()) {
            case Has(word): { println("{}", word); }
            case Empty:     { break; }
        }
    }
}
```

`next_word` takes `&mut self` but returns a slice of `life(a)`, the original text — so the returned
word does not keep the cursor borrowed. Change the signature to `-> Maybe<&str>` (elision rule E3) and
the same program stops compiling, because each word would pin `w` forever.

### 27.6 A file handle: `drop` plus a narrow seam

```c
unchecked extern fn open(path: Raw<u8>, flags: i32) -> i32;
unchecked extern fn read(fd: i32, buf: Raw<u8>, count: u64) -> i64;
unchecked extern fn close(fd: i32) -> i32;

struct File { fd: i32; }

methods File {
    fn open(path: &str) -> Maybe<File> {
        let mut fd: i32 = -1;
        unchecked "open() only reads the path bytes; the slice outlives the call" {
            fd = open(raw(path), 0);
        }
        if (fd < 0) {
            return Empty;
        }
        return Has(File { .fd = fd });
    }

    fn read_some(&mut self, buf: &mut [u8]) -> Maybe<u64> {
        let mut n: i64 = -1;
        unchecked "read() writes at most buf.length() bytes into an owned slice" {
            n = read(self.fd, raw(buf), buf.length());
        }
        if (n < 0) {
            return Empty;
        }
        return narrow(n);      // i64 -> u64, checked, returns Maybe<u64>
    }

    fn drop(self) {
        unchecked "fd came from File::open and is owned by this value" {
            close(self.fd);
        }
    }
}
```

Two `unchecked` blocks, two reasons, one `drop`. The seam is small, and `--report=seams` lists all
three lines.

### 27.7 Translation table: what to write instead

For people arriving from C, C++, or any GC language:

| You would reach for | Write instead |
|---|---|
| `int` | `i32` / `u32` / `u64` — pick a width |
| `char*` | `&str` for a view, `Text` for ownership |
| `strdup`, `new char[]` | `own(s)` |
| `malloc` + `free` | `new` + nothing |
| `delete` | nothing |
| `Box<T>` | `Heap<T>` |
| `clone()` | `.copy()` |
| `unwrap()` / `expect()` | `switch` on `Maybe`, or `or(m, fallback)` |
| `NULL` | `Empty` / `Maybe<T>` |
| `Rc<RefCell<T>>` | indices into a `Vec`, or restructure to `&mut` |
| `unsafe { }` | `unchecked "reason" { }` |
| `goto cleanup` | a block; destruction runs at `}` and on `return` |
| `do { } while (c)` | `while (true) { ... if (not c) { break; } }` |
| `a ? b : c` | `let x: T; if (cond) { x = b; } else { x = c; }` |
| `#define MAX 10` | `const MAX: u32 = 10;` |
| macros / templates | generics, or write it twice |
| `switch` fallthrough | a nested `switch`, or an `if` chain |
| `printf("%d")` | `println("{}", n)` |
| `p->x` | `p.x` |
| iterator chains | a `while` loop with an index |
| closures | a struct with a method, or a plain function |
| exceptions | `Maybe` for expected absence; `panic` for unrecoverable |

---

## 28. What v0 leaves out

Every omission below is a decision, not an oversight. The column "cost" is what you must write
instead.

| Feature | Status | Cost today |
|---|---|---|
| Traits / interfaces | v2 | write one function per type; generics are unbounded |
| Closures | v2 | pass a struct with a method, or duplicate the loop |
| Macros | never | `const`, functions, and `println`'s compile-time format parser |
| Operator overloading | never | named methods: `a.add(b)` |
| `Result<T, E>` + `?` | v1 | `Maybe` plus explicit matching; panics for unrecoverable |
| Threads, atomics, `Send`-like rules | v2 | single-threaded programs only |
| `Rc` / `RefCell` / interior mutability | never | indices, `&mut`, or restructure |
| Tuples | v1 | a named `copy struct` |
| Modules, `use`, visibility | v1 | one file |
| Pattern guards | v1 | `if` inside the arm |
| Labelled `break` | v1 | a `done` flag |
| Range literals (`0..n`) | v1 | C-style `for` or `while` |
| `if let` / `let else` | never | `switch` |
| Destructuring `let` | v1 | `switch` |
| Async / coroutines | never | — |
| Exceptions / unwinding | never | `panic` aborts; `Maybe` for absence |
| Variadics | never | fixed-arity `println` builtins; FFI calls with raw pointers |
| Inline assembly | never | `unchecked extern` |
| SIMD intrinsics | v2 | `unchecked` + FFI |
| Global mutable state | never | pass a `&mut` |
| Build system / package manager | v1 | `lang build file.lang` |
| Incremental compilation | v1 | `lang check` on save |
| Debugger integration | v1 | generated C is debuggable with `gdb`/`lldb` |

Roadmap in one line each:

- **v0** — everything in this document.
- **v1** — modules and `use`, `Result<T, E>` without `?`, tuples, labelled loops, guards, slice
  patterns, `if let` as sugar for a two-arm `switch`, fallible allocation.
- **v2** — traits with static dispatch, closures without captures (function pointers with an
  environment struct), threads with `Send`-like transfer rules derived from R4, SIMD intrinsics behind
  `unchecked`.
- **never** — a GC, a tracing runtime, `null`, implicit conversions, operator overloading, macros.

---

## 29. Honest downsides

1. **Some data structures are painful.** Doubly linked lists, graphs with cycles, and parent pointers
   all become index bookkeeping or `unchecked`. That is the price of "no GC, no refcounts". Every
   language in this family pays it; this one pays it more cheaply than most, but it does pay.

2. **There is a learning wall, and it is on day two.** The first hour is C-shaped and pleasant. Then
   you write a function that returns a reference to a local, and the compiler says `life.outlives`.
   The mitigation is the report format: it names the rule, shows the two spans, and offers two
   compilable fixes. But it is still a wall.

3. **The checker is opinionated about structure.** Two mutable borrows of the same container at once
   is impossible, even when the two indices are provably different. You restructure: split the struct,
   use `split_at`, or index sequentially.

4. **`unchecked` is real UB, and it is the only UB.** That is a smaller hole than most languages have,
   but it is a hole, and a wrong reason string is a wrong program. `--forbid=unchecked` exists for
   code that cannot afford the risk.

5. **No closures makes callback code noisy.** Event loops, visitors, and generic algorithms over
   containers want closures; v0 gives you structs with methods and `switch`. This is the omission most
   likely to annoy working programmers, and it is why closures are the first v2 item.

6. **Copy limits are a speed bump.** 128 bytes is generous for coordinates and stingy for a 40-field
   config struct. The error is explicit (`copy.too-large`) and the fix is "own it, don't copy it",
   which is usually the right answer anyway.

7. **No globals means plumbing.** Configuration, loggers, and pools must be passed as `&`/`&mut`
   parameters. That is good for testing and tedious for prototyping.

8. **The compiler is bigger than the language.** Parsing a 40-line language is a weekend; borrow
   checking it is a year. The design deliberately concentrates complexity in the compiler so the
   runtime can be 400 lines of C — but somebody has to write and maintain those analyses.

9. **Diagnostics can be wrong in the boring direction.** Liveness-based checking sometimes reports a
   conflict that a human can see is fine (a "false positive" in the shape of the analysis). The
   escape hatches are restructure, indices, or `unchecked`; false negatives (accepting an unsound
   program) are not an acceptable escape hatch.

10. **It is still a concept.** Every example here is hand-checked against the rules, not compiled.

---

## Appendix A — Grammar

EBNF. `{ x }` is zero or more, `[ x ]` is optional, `|` is alternation. Operator precedence is not
encoded here; see Appendix B.

```ebnf
(* ---------- program structure ---------- *)

program        = { item } ;

item           = fn_decl | extern_decl | struct_decl | enum_decl
               | methods_decl | const_decl ;

fn_decl        = [ "unchecked" ] "fn" ID [ generics ] "(" [ params ] ")"
                 [ "->" type ] block ;

extern_decl    = [ "unchecked" ] "extern" "fn" ID "(" [ params ] ")"
                 [ "->" type ] ";" ;

params         = param { "," param } ;
param          = [ "mut" ] ID ":" type
               | "self"
               | "&" "self"
               | "&" "mut" "self" ;

generics       = "<" gparam { "," gparam } ">" ;
gparam         = "life" ID | ID [ ":" "copy" ] ;

struct_decl    = [ "copy" ] "struct" ID [ generics ] "{" { field } "}" ;
field          = ID ":" type ";" ;

enum_decl      = [ "copy" ] "enum" ID [ generics ] "{" variants "}" ;
variants       = [ variant { "," variant } [ "," ] ] ;
variant        = ID [ "(" type { "," type } ")" ] ;

methods_decl   = "methods" [ generics ] type "{" { fn_decl } "}" ;

const_decl     = "const" ID ":" type "=" const_expr ";" ;

(* ---------- types ---------- *)

type           = "&" [ "mut" ] [ "life" "(" life_arg ")" ] type
               | "[" type ";" INT "]"                 (* array: [T; N] *)
               | "[" type "]"                         (* slice: [T] *)
               | ID [ "<" targ { "," targ } ">" ]     (* i32, Vec<T>, Maybe<T>, Text, ... *)
               | "()" ;

targ           = type | "life" "(" life_arg ")" ;
life_arg       = ID | "static" ;

(* ---------- statements ---------- *)

block          = "{" { stmt } "}" ;

stmt           = let_stmt
               | assign_stmt
               | expr_stmt
               | if_stmt
               | while_stmt
               | for_stmt
               | switch_stmt
               | return_stmt
               | break_stmt
               | continue_stmt
               | unchecked_stmt
               | block ;

let_stmt       = "let" [ "mut" ] ID [ ":" type ] [ "=" expr ] ";" ;

assign_stmt    = place ( "=" | "+=" | "-=" | "*=" | "/=" | "%=" ) expr ";" ;

expr_stmt      = expr ";" ;

if_stmt        = "if" "(" expr ")" block [ "else" ( if_stmt | block ) ] ;

while_stmt     = "while" "(" expr ")" block ;

for_stmt       = "for" "(" for_head ")" block ;

for_head       = let_inner ";" expr ";" step      (* C-style *)
               | [ "let" [ "mut" ] ] ID ":" expr ; (* range-style *)

let_inner      = "let" [ "mut" ] ID [ ":" type ] "=" expr ;

step           = place ( "=" | "+=" | "-=" | "*=" | "/=" | "%=" ) expr
               | expr ;

switch_stmt    = "switch" "(" expr ")" "{" { arm } "}" ;

arm            = ( "case" pattern | "default" ) ":" block ;

pattern        = "_"
               | literal
               | ID [ "(" pattern { "," pattern } ")" ] ;

return_stmt    = "return" [ expr ] ";" ;
break_stmt     = "break" ";" ;
continue_stmt  = "continue" ";" ;

unchecked_stmt = "unchecked" [ STRING ] block ;

(* ---------- expressions ---------- *)

expr           = unary { binop unary } ;

binop          = "+" | "-" | "*" | "/" | "%"
               | "==" | "!=" | "<" | "<=" | ">" | ">="
               | "and" | "or"
               | "band" | "bor" | "bxor" | "shl" | "shr" ;

unary          = "-" unary
               | "not" unary
               | "bnot" unary
               | "*" unary
               | "&" [ "mut" ] unary
               | "new" unary
               | postfix ;

postfix        = primary { "." ID [ "(" [ args ] ")" ]
                        | "[" expr "]"
                        | "(" [ args ] ")"
                        | "as" type } ;

primary        = literal
               | ID
               | "(" expr ")"
               | struct_init
               | array_lit
               | ID "::" ID [ "(" [ args ] ")" ] ;

args           = expr { "," expr } [ "," ] ;

struct_init    = ID "{" { "." ID "=" expr "," } "}" ;

array_lit      = "[" [ expr { "," expr } ] "]"
               | "[" expr ";" INT "]" ;

literal        = INT | FLOAT | STRING | CHAR | "true" | "false" | "()" ;

place          = [ "*" ] ID { "." ID | "[" expr "]" } ;  (* a place expression *)

const_expr     = expr ;   (* restricted to literals, arithmetic, and other constants *)
```

Grammar notes, the ones that bite:

1. **`&` means borrow, never bitwise-and.** Bitwise operators are words (`band`, `bor`). This removes
   the entire `&`/`&&` and `|`/`||` typo family, and it makes `&x` unambiguous everywhere.
2. **`unchecked` is a statement, not an expression.** There is no `let x = unchecked { ... };`. This is
   what prevents raw values from escaping into safe code (see §22.3).
3. **`case X:` is resolved, not parsed, as a variant or a binding.** If `X` names a variant of the
   subject's type, it is a variant pattern; otherwise it binds the whole value. An unknown capitalised
   name that looks like a variant gets `name.unknown-variant` rather than silently becoming a binding.
4. **No trailing expression.** A `block` is a list of statements; a function returns only via `return`.
5. **`as` is postfix and type-directed.** In safe code it is only accepted for total conversions
   (§8.1); in `unchecked` it accepts any bit-level cast.
6. **`place` is a syntactic subset of expressions.** Assignment targets, `take(...)`, and borrows
   require a place; `f() = 3` is `assign.not-a-place`.
7. **`self` is a keyword only inside `methods` bodies.** `name.self-outside-methods` otherwise.
8. **No semicolon after block statements.** `if`, `while`, `for`, `switch`, `unchecked`, and bare
   blocks are statements without `;`.

---

## Appendix B — Operators and precedence

### B.1 Table

| Level | Operators | Associativity | Notes |
|---|---|---|---|
| 1 (tightest) | `.` `[]` `()` `::` `as` | left | postfix: field, index, call, path, cast |
| 2 | unary `-` `not` `bnot` `*` `&` `&mut` `new` | right | `*` is deref, `&` is borrow, `bnot` is bitwise not |
| 3 | `*` `/` `%` | left | `/` truncates toward zero; `%` takes the sign of the dividend |
| 4 | `+` `-` | left | overflow traps |
| 5 | `shl` `shr` | left | shift ≥ bit width traps; `shr` on signed is arithmetic |
| 6 | `band` | left | bitwise and, on integers |
| 7 | `bxor` | left | bitwise xor |
| 8 | `bor` | left | bitwise or |
| 9 | `==` `!=` `<` `<=` `>` `>=` | non-associative | `a < b < c` is a fault |
| 10 | `and` | left | short-circuit |
| 11 (loosest) | `or` | left | short-circuit |
| — | `=` `+=` `-=` `*=` `/=` `%=` | statement only | never an expression |

### B.2 The traps this table is designed to avoid

- **`a band 0xF == 0`** parses as `(a band 0xF) == 0`, because `band` binds tighter than `==`.
  In C, `==` binds tighter than `&`, which is the classic bug this ordering removes.
- **`not a == b`** parses as `(not a) == b`, because `not` is a tight unary operator. Write
  `not (a == b)` when that is what you mean. The `if` condition's mandatory parens usually make this
  obvious.
- **`x as u64 + 1`** parses as `(x as u64) + 1`, because `as` is postfix.
- **`a < b < c`** is rejected outright rather than parsed as `(a < b) < c`, which is never what anyone
  means (and would not typecheck anyway, since `bool < bool` is a fault).
- **`if (x = 5)`** never reaches precedence: `=` is not an expression operator, so the condition is a
  parse fault with a fix-it suggesting `==`.

### B.3 Arithmetic semantics

| Operation | Behavior |
|---|---|
| `+ - *` on integers | trap on overflow (`panic.overflow`) |
| `/` `%` | trap on division by zero; `i32::MIN / -1` traps |
| `shl` `shr` | trap if the shift amount ≥ bit width; no masking |
| floats | IEEE-754: no traps, `NaN` propagates, `NaN != NaN` |
| mixed widths | fault; write the conversion |
| mixed signedness | fault; write the conversion |
| `as` | total (widening) conversions only, unless inside `unchecked` |

Explicit alternatives for integers:

| Function | Meaning |
|---|---|
| `wrap_add(a, b)`, `wrap_sub`, `wrap_mul` | two's-complement wrap, defined |
| `sat_add`, `sat_sub`, `sat_mul` | saturate at the type's bounds |
| `checked_add`, `checked_sub`, `checked_mul` | return `Maybe<T>` |
| `narrow(x)` | checked narrowing, returns `Maybe<T>` |
| `wrap(x)` | truncating conversion, defined |

---

## Appendix C — Report catalogue

Severity is `F` (fault, stops the build) or `W` (warning). "Fix" is the shortest correct repair.

### Syntax and names

| ID | Sev | Trigger | Fix |
|---|---|---|---|
| `syntax.missing-semicolon` | F | statement not terminated | add `;` |
| `syntax.unexpected-token` | F | parser cannot continue | usually a missing `)` or `}` |
| `syntax.assignment-is-not-an-expression` | F | `if (x = 5)` | use `==`, or move the assignment out |
| `syntax.expected-return` | F | trailing expression in a function | `return expr;` |
| `syntax.format-arity` | F | `{}` count ≠ argument count | match them |
| `syntax.invalid-escape` | F | `\q` in a string/char | use a valid escape |
| `syntax.integer-literal-too-large` | F | literal exceeds its type | widen the type or the suffix |
| `name.not-found` | F | unknown identifier | declare it, or fix the spelling |
| `name.duplicate` | F | two definitions, one name | rename |
| `name.duplicate-field` | F | two fields with one name | rename |
| `name.unknown-variant` | F | `Shape::Tri` with no `Tri` | fix the variant name |
| `name.self-outside-methods` | F | `self` in a free function | take a parameter |

### Types

| ID | Sev | Trigger | Fix |
|---|---|---|---|
| `type.mismatch` | F | `u32` where `u64` is needed | `x as u64` / `narrow(x)` |
| `type.not-a-bool` | F | `if (1)` | compare: `if (n != 0)` |
| `type.not-copy` | F | copying an owning type | `&x`, `.copy()`, or `copy` the type |
| `type.infinite-size` | F | recursive struct with no indirection | insert `Heap<T>` |
| `type.unknown-field` | F | `p.z` | fix the field name |
| `type.arity-mismatch` | F | wrong argument count | match the signature |
| `type.no-such-method` | F | `v.foo()` | check the method table |
| `type.return-mismatch` | F | returned type ≠ declared | convert or change the signature |
| `type.call-on-non-function` | F | `x(1)` where `x: i32` | fix the name |
| `copy.too-large` | F | `copy` type > 128 bytes | own it instead |
| `copy.field-not-copy` | F | `copy struct` with a `Text` field | drop the marker |

### Initialization and moves

| ID | Sev | Trigger | Fix |
|---|---|---|---|
| `init.read-before-write` | F | read on a path with no write | initialize on every branch |
| `init.missing-field` | F | struct literal omits a field | add `.f = ...` |
| `move.after-handoff` | F | use after a move | reorder, `&`, or `.copy()` |
| `move.maybe-moved` | F | moved on one branch only | move on both, or reassign |
| `move.partial` | F | `let a = p.a;` on an owning field | `take(p.a)` |
| `move.out-of-heap` | F | `*b` used as a value | `take(*b)` |
| `assign.not-mutable` | F | write to a `let` binding | add `mut` |
| `assign.not-a-place` | F | `f() = 1` | assign to a variable |

### Borrowing and lives

| ID | Sev | Trigger | Fix |
|---|---|---|---|
| `borrow.conflict` | F | `&mut` while a loan is live | finish the loan first |
| `borrow.while-iterating` | F | mutate the container in a `for (x : &v)` | collect indices, then mutate |
| `borrow.move-while-borrowed` | F | move a value that is lent out | end the loan first |
| `borrow.mut-through-shared` | F | write through `&T` | take `&mut T` |
| `life.outlives` | F | reference outlives its referent | return the owner, or borrow an input |
| `life.cannot-elide` | F | ambiguous elided output life | name a `life` |
| `life.temporary` | F | borrow of a temporary across statements | bind the temporary first |
| `life.unknown` | F | `life(b)` never declared | add `<life b>` |
| `life.not-static` | F | `life(static)` required but not proven | use `keep` explicitly |

### Control flow, patterns, drops

| ID | Sev | Trigger | Fix |
|---|---|---|---|
| `switch.not-exhaustive` | F | missing variant | add the arm, or `default` |
| `switch.unreachable-arm` | W | arm can never match | delete or reorder |
| `switch.duplicate-arm` | F | two identical patterns | merge |
| `switch.not-a-variant` | F | variant pattern on a non-enum | match on the value directly |
| `control.missing-return` | F | non-unit function can fall off the end | add `return` |
| `control.break-outside-loop` | F | `break` in a switch with no loop | return instead |
| `control.continue-outside-loop` | F | `continue` outside a loop | remove |
| `control.unreachable-code` | W | statements after `return` | delete |
| `drop.on-copy-type` | F | `fn drop` on a `copy` type | remove the marker or the hook |
| `drop.panics` | F | `panic` inside `drop` | handle it, don't panic |

### The seam and FFI

| ID | Sev | Trigger | Fix |
|---|---|---|---|
| `unchecked.missing-block` | F | raw deref/cast/call in safe code | wrap in `unchecked` |
| `unchecked.raw-escapes` | F | `Raw<T>` outside a block/`unchecked fn` | keep it inside |
| `unchecked.in-safe-signature` | F | `fn f(p: Raw<u8>)` | add `unchecked` to `fn` |
| `seam.no-reason` | W | `unchecked {` without a reason | add `"..."` |
| `extern.unknown-symbol` | F | symbol not found at link | fix the name/signature |
| `extern.abi-mismatch` | F | declared signature disagrees with the C header | match the header |
| `const.not-constant` | F | const initializer calls a function | use a literal expression |
| `const.cycle` | F | `const A = B; const B = A;` | break the cycle |

### Runtime

| ID | Sev | Trigger | Fix |
|---|---|---|---|
| `panic.bounds` | runtime | `v[i]` out of range | check `i`, or use `v.get(i)` |
| `panic.overflow` | runtime | integer overflow | use `wrap_add` / `sat_add` / `checked_add` |
| `panic.divide-by-zero` | runtime | `/ 0` or `% 0` | guard the divisor |
| `panic.shift-too-large` | runtime | shift ≥ width | mask or guard |
| `panic.explicit` | runtime | `panic("...")` | intentional |
| `panic.not-a-char-boundary` | runtime | slicing mid-codepoint | slice on a boundary |
| `panic.out-of-memory` | runtime | allocator returned null | reduce allocation |
| `panic.in-drop` | runtime | a `drop` hook panicked | never panic in `drop` |
| `compiler.internal` | F | the compiler itself failed | file a bug with the snippet |

---

## Appendix D — Keywords and builtins

### D.1 Keywords

| Group | Keywords |
|---|---|
| declarations | `fn` `methods` `struct` `enum` `copy` `const` `let` `mut` |
| modules of code | `extern` `unchecked` `self` |
| types | `life` `static` |
| control | `if` `else` `while` `for` `switch` `case` `default` `return` `break` `continue` |
| values | `new` `true` `false` |
| operators | `and` `or` `not` `band` `bor` `bxor` `bnot` `shl` `shr` `as` |

Reserved but unused in v0 (held for the roadmap): `mod` `use` `pub` `trait` `impl` `where` `loop`
`match` `async` `await` `yield` `macro` `union`.

`bnot` is a unary word operator at precedence level 2: `bnot x` flips every bit. It applies only to
unsigned integers.

### D.2 Builtins

These are ordinary names in the prelude; they cannot be shadowed.

| Builtin | Signature | Notes |
|---|---|---|
| `own` | `(&str) -> Text` | copies the bytes into a new heap buffer |
| `keep` | `<T>(T) -> &life(static) T` | leaks on purpose; reported by `--report=seams` |
| `discard` | `<T>(T)` | destroy now, like a manual drop |
| `take` | `<T>(place: T) -> T` | moves a field or `*Heap` value out (special form) |
| `raw` | `<T>(&T) -> Raw<T>`, `<T>(&mut T) -> Raw<T>`; on `&[T]`/`&mut [T]`/`&str` it returns `Raw<T>`/`Raw<u8>` pointing at the first element | `unchecked` only |
| `null` | `<T>() -> Raw<T>` | `unchecked` only; the only null in the language |
| `size_of` | `<T>() -> u64` | compile-time constant |
| `align_of` | `<T>() -> u64` | compile-time constant |
| `panic` | `(&str) -> !` | prints a runtime fault, aborts |
| `assert` | `(bool, &str)` | `panic` with the message if false |
| `print` | `(&str, ...)` | formatting, no newline |
| `println` | `(&str, ...)` | formatting, newline |
| `format` | `(&str, ...) -> Text` | allocate a formatted `Text` |
| `or` | `<T>(Maybe<T>, T) -> T` | the honest `unwrap` |
| `narrow` | `<T>(int) -> Maybe<T>` | checked narrowing |
| `wrap` | `<T>(int) -> T` | truncating conversion |
| `wrap_add` / `wrap_sub` / `wrap_mul` | `(T, T) -> T` | define the wrap |
| `sat_add` / `sat_sub` / `sat_mul` | `(T, T) -> T` | saturate |
| `checked_add` / `checked_sub` / `checked_mul` | `(T, T) -> Maybe<T>` | explicit failure |

Formatting placeholders: `{}` (display), `{:?}` (structural), `{:.N}` (float precision). `{}` prints
through any number of references and `Heap`s.

---

## Appendix E — Glossary

| Term | Meaning |
|---|---|
| **owner** | the single place responsible for destroying a value |
| **move** | transfer of ownership; the source becomes unusable |
| **copy** | byte duplication of a `copy` type; both names stay valid |
| **place** | a storage location: a local, a field, an index, or a deref |
| **loan** | the permission created by `&` or `&mut`, alive until its last use |
| **live range** | the program points between a loan's creation and its last use |
| **region / life** | a set of program points that a reference may be used in |
| **outlives** | `a ⊒ b`: region `a` contains region `b` |
| **elision** | inferring `life` annotations from rules E1–E3 |
| **drop** | the hook that runs when an owner dies, before its fields |
| **discard** | destroy a value immediately, by name |
| **take** | move a field or heap contents out, leaving a partial value |
| **seam** | an `unchecked` block or `unchecked fn`: the boundary where checking stops |
| **witness** | the smallest concrete value a `switch` fails to cover |
| **monomorphize** | generate one copy of a generic function per type argument |
| **ZST** | zero-sized type; `()` and empty `copy struct`s |
| **report** | a compile-time diagnostic with an ID, a rule, spans, and a fix |
| **fault** | a report that stops the build; also a runtime abort, by ID |
| **seam audit** | the `--report=seams` listing of every `unchecked`/`keep` |

---

## Appendix F — One page, if you remember nothing else

```c
fn main() {
    let mut names: Vec<Text> = Vec::new();
    names.push(own("Ada"));
    names.push(own("Grace"));

    for (n : &names) {
        println("hello, {}", n);
    }

    let first = names[0].copy();     // independent duplicate
    println("{} and {}.", first, names[1]);
}                                    // `first` freed, then `names` and its elements
```

- One owner per value. The `}` frees it. No GC, no `free`, no `delete`.
- Assignment and passing move. `copy` types duplicate. `.copy()` duplicates an owner, visibly.
- `&` reads, `&mut` writes, never both while alive. Loans die at their last use.
- A reference cannot outlive its referent; `life` is how you say it when elision cannot.
- `Maybe<T>` instead of null. `switch` instead of unchecked branches. No implicit conversions.
- `unchecked "reason" { }` is the only place the checker stops reading, and it is audited.
- When the compiler complains, it says what broke, where, whose rule it is, and how to fix it — by ID,
  in a box, with compilable code.
