; =============================================================================
; Harmony — Zed / Tree-sitter highlighting query
; Language spec: Harmony v0.3.3 (with the explicitly decided v1 spellings
; called out below). Source extension: .harmony
;
; IMPORTANT — parser contract
; ---------------------------
; The Harmony document supplies an EBNF, not a Tree-sitter grammar. A .scm
; query is coupled to the concrete node names and fields produced by that
; grammar. This query targets the following conventional Harmony node/field
; names; adapt those names if your grammar.js uses different ones.
;
; Lexical leaf nodes:
;   identifier, type_identifier, integer_literal, float_literal,
;   char_literal, byte_literal, string_literal, escape_sequence,
;   line_comment, block_comment, doc_comment
;
; Structural nodes / fields used below:
;   fn_decl(name), extern_decl(name), const_decl(name),
;   struct_decl(name), enum_decl(name), enum_variant(name),
;   field_decl(name), field_init(name), param(name), type_parameter(name),
;   life_parameter(name), life_use, let_stmt(name), field_expr(field),
;   call_expr(callee), path_expr(name), variant_pattern(name),
;   generics, generic_args, bound
;
; These names are a reference interface, not names guaranteed by the EBNF.
; Zed loads this file as the grammar's `highlights.scm` query.
; =============================================================================

; -----------------------------------------------------------------------------
; Comments
; -----------------------------------------------------------------------------

(doc_comment) @comment @comment.doc
(line_comment) @comment
(block_comment) @comment

; -----------------------------------------------------------------------------
; Strings, characters, bytes, numbers, and booleans
; -----------------------------------------------------------------------------

(string_literal) @string
(escape_sequence) @string.escape
(char_literal) @string @character
(byte_literal) @string @character
(integer_literal) @number
(float_literal) @number @number.float

; Generic identifier fallback. More specific declaration / call / field patterns
; below refine the appropriate identifiers.
(identifier) @variable

"true" @boolean
"false" @boolean

; -----------------------------------------------------------------------------
; Type names
; -----------------------------------------------------------------------------

; Primitive types and the standard-library types named by the Harmony spec.
((type_identifier) @type @type.builtin
  (#match? @type.builtin "^(i8|i16|i32|i64|isize|u8|u16|u32|u64|usize|f32|f64|bool|char|never|str|String|Vec|Heap|Maybe|Outcome|Shared|Range|RangeInclusive|Iter|IterMut|Drain|Chars|Bytes|Ordering|IoError|ParseError|Formatter)$"))

; User-defined and other named types.
((type_identifier) @type
  (#not-match? @type "^(i8|i16|i32|i64|isize|u8|u16|u32|u64|usize|f32|f64|bool|char|never|str|String|Vec|Heap|Maybe|Outcome|Shared|Range|RangeInclusive|Iter|IterMut|Drain|Chars|Bytes|Ordering|IoError|ParseError|Formatter)$"))


; -----------------------------------------------------------------------------
; Declaration names and other definition sites
; -----------------------------------------------------------------------------

(fn_decl
  name: (identifier) @function)

(extern_decl
  name: (identifier) @function)

(const_decl
  name: (identifier) @constant)

(struct_decl
  name: (type_identifier) @type @type.definition)

(enum_decl
  name: (type_identifier) @type @type.definition)

(enum_variant
  name: (identifier) @variant)

(field_decl
  name: (identifier) @property)

(field_init
  name: (identifier) @property)

(param
  name: (identifier) @variable @variable.parameter)

(type_parameter
  name: (type_identifier) @type @type.parameter)

(life_parameter
  name: (identifier) @label)

(let_stmt
  name: (identifier) @variable)

; `self` is a built-in receiver name, but is not a declaration keyword.
"self" @variable @variable.builtin

; `life` is contextual in Harmony: highlight it only in lifetime syntax.
; `player.life`, a local named `life`, and other ordinary uses stay identifiers.
(life_parameter "life" @keyword @keyword.type)
(life_use "life" @keyword @keyword.type)
(life_use
  (identifier) @label)

(life_use
  (identifier) @constant @constant.builtin
  (#eq? @constant.builtin "static"))

; -----------------------------------------------------------------------------
; Variables, members, paths, calls, and variants
; -----------------------------------------------------------------------------

(field_expr
  field: (identifier) @property)

(call_expr
  callee: (identifier) @function)

(call_expr
  callee: (field_expr
    field: (identifier) @function @function.method))

; Namespaced calls such as geometry::length() and Type::make(). The parser may
; expose all path components here; type_identifier should be used for type
; segments where the grammar can distinguish them.
(call_expr
  callee: (path_expr
    name: (identifier) @function))

(variant_pattern
  name: (identifier) @variant)

; Prelude sum-type variants used as values: Maybe<T> and Outcome<T, E>.
((identifier) @variant
  (#match? @variant "^(Has|Empty|Good|Bad)$"))

; Convention from §4.1: SCREAMING_SNAKE names are constants. This also catches
; associated constants such as i32::MIN when represented as identifiers.
((identifier) @constant
  (#match? @constant "^[A-Z][A-Z0-9_]*$"))

; -----------------------------------------------------------------------------
; Prelude functions
; -----------------------------------------------------------------------------

((call_expr
   callee: (identifier) @function @function.builtin)
  (#match? @function.builtin "^(print|println|eprintln|format|trap|assert|unreachable|exit|drop|leak|swap|replace)$"))

; Intrinsic-like expression forms. In Harmony these are syntax, not ordinary
; user-defined functions: heap(expr) and sizeof(Type).
"heap" @function @function.builtin
"sizeof" @function @function.builtin

; -----------------------------------------------------------------------------
; Keywords — Harmony v0.3.3
; -----------------------------------------------------------------------------

; Declarations and visibility
"fn" @keyword @keyword.function
"let" @keyword
"mut" @keyword @keyword.modifier
"const" @keyword
"struct" @keyword
"enum" @keyword
"methods" @keyword
"copy" @keyword @keyword.modifier
"export" @keyword
"import" @keyword @keyword.import
"extern" @keyword

; Control flow
"if" @keyword @keyword.control
"else" @keyword @keyword.control
"while" @keyword @keyword.control
"for" @keyword @keyword.control
"switch" @keyword @keyword.control
"case" @keyword @keyword.control
"default" @keyword @keyword.control
"return" @keyword @keyword.control
"break" @keyword @keyword.control
"continue" @keyword @keyword.control

; Memory and safety
"unchecked" @keyword
"raw" @keyword

; Conversion operator
"as" @keyword @keyword.operator

; `eq` and `ord` are compiler-known generic bounds, not global keywords.
(bound "eq" @keyword)
(bound "ord" @keyword)

; -----------------------------------------------------------------------------
; Reserved future / v1 syntax explicitly described in the design document
; -----------------------------------------------------------------------------

"abilities" @keyword
"async" @keyword
"await" @keyword
"macro" @keyword
"try" @keyword @keyword.control

; NOTE: `life` is intentionally absent from the global keyword list.
; `static`, `in`, `trait`, `spawn`, `send`, and the recognized foreign words
; (unsafe, impl, match, pub, use, loop, goto, null, NULL, nullptr, malloc,
; free, new, delete, Box, Option, Some, None, Result, Ok, Err, panic) are not
; Harmony keywords and are therefore intentionally not captured as keywords.

; -----------------------------------------------------------------------------
; Operators
; -----------------------------------------------------------------------------

; Assignment and compound assignment
"=" @operator
"+=" @operator
"-=" @operator
"*=" @operator
"/=" @operator
"%=" @operator
"&=" @operator
"|=" @operator
"^=" @operator
"<<=" @operator
">>=" @operator

; Arithmetic, shifts, bitwise, comparison, and logical operators
"+" @operator
"-" @operator
"*" @operator
"/" @operator
"%" @operator
"<<" @operator
">>" @operator
"&" @operator
"^" @operator
"|" @operator
"==" @operator
"!=" @operator
"<=" @operator
">=" @operator
"<" @operator
">" @operator
"&&" @operator
"||" @operator
"!" @operator
"~" @operator

; Ranges
".." @operator
"..=" @operator

; -----------------------------------------------------------------------------
; Punctuation and delimiters
; -----------------------------------------------------------------------------

"(" @punctuation.bracket
")" @punctuation.bracket
"[" @punctuation.bracket
"]" @punctuation.bracket
"{" @punctuation.bracket
"}" @punctuation.bracket

"," @punctuation.delimiter
";" @punctuation.delimiter
":" @punctuation.delimiter

"." @punctuation @punctuation.delimiter
"::" @punctuation @punctuation.delimiter
"->" @punctuation @punctuation.operator

; Generic-angle brackets are punctuation in type/parameter lists. The global
; < and > operator captures above continue to cover comparisons elsewhere.
(generics
  "<" @punctuation.bracket
  ">" @punctuation.bracket)

(generic_args
  "<" @punctuation.bracket
  ">" @punctuation.bracket)

; The wildcard / discard token is distinct from an ordinary identifier.
"_" @variable.special
