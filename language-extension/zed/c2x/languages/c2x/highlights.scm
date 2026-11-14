; Comments
(comment) @comment

; Variables & Identifiers
(identifier) @variable

; Struct & Union Fields
(field_identifier) @property

; Labels (for goto)
(statement_identifier) @label

; Constants & Macros (ALL_CAPS convention)
((identifier) @constant
  (#match? @constant "^[A-Z][A-Z\\d_]*$"))

(preproc_def
  name: (identifier) @constant)

(preproc_function_def
  name: (identifier) @function.special)

; Built-in Constants & Booleans
(null) @constant.builtin
[
  (true)
  (false)
] @boolean

; Strings, Characters & Numbers
(string_literal) @string
(system_lib_string) @string.special
(escape_sequence) @string.escape
(char_literal) @constant
(number_literal) @number

; Types & Type Qualifiers
(primitive_type) @type.builtin
(sized_type_specifier) @type.builtin
(type_identifier) @type

[
  "const"
  "volatile"
  "restrict"
  "_Atomic"
  "_Noreturn"
  "noreturn"
] @type.qualifier

; Storage Classes
[
  "auto"
  "extern"
  "inline"
  "register"
  "static"
  "thread_local"
] @keyword

; Keywords
[
  "break"
  "case"
  "continue"
  "default"
  "do"
  "else"
  "enum"
  "for"
  "goto"
  "if"
  "return"
  "sizeof"
  "struct"
  "switch"
  "typedef"
  "union"
  "while"
] @keyword

; Preprocessor Directives
[
  "#define"
  "#elif"
  "#else"
  "#endif"
  "#if"
  "#ifdef"
  "#ifndef"
  "#include"
  (preproc_directive)
] @preproc

; Functions (Definitions, Declarations & Calls)
(function_declarator
  declarator: (identifier) @function)

(function_declarator
  declarator: (parenthesized_declarator
    (pointer_declarator
      declarator: (identifier) @function)))

(call_expression
  function: (identifier) @function)

(call_expression
  function: (field_expression
    field: (field_identifier) @function))

; Parameters
(parameter_declaration
  declarator: (identifier) @variable.parameter)

(parameter_declaration
  declarator: (pointer_declarator
    declarator: (identifier) @variable.parameter))

(parameter_declaration
  declarator: (array_declarator
    declarator: (identifier) @variable.parameter))

; Operators
[
  "="
  "+="
  "-="
  "*="
  "/="
  "%="
  "&="
  "|="
  "^="
  "<<="
  ">>="
  "+"
  "-"
  "*"
  "/"
  "%"
  "++"
  "--"
  "=="
  "!="
  "<"
  ">"
  "<="
  ">="
  "&&"
  "||"
  "!"
  "&"
  "|"
  "^"
  "~"
  "<<"
  ">>"
  "?"
  ":"
  "->"
] @operator

; Punctuation & Delimiters
[
  "."
  ","
  ";"
] @punctuation.delimiter

[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket
