#!/usr/bin/env python3
"""Convert the c2x-seed NASM sources to flat-assembler (FASM) syntax.

Operates on a *copy* of the c2x-seed sources so the NASM tree stays intact
until the FASM build is proven. Line-local transforms plus a few whole-file
passes (macros, strucs, symbol exports) so the output diffs cleanly.

Key NASM -> FASM differences handled here:
  - `format ELF64` must be declared once per source file.
  - `global a, b, c`  -> one `public a` per symbol AND the `public` must come
    *after* the symbol is defined for `equ` constants (FASM resolves `public`
    at the point it is seen). We therefore emit all `public`/`extrn` lines
    after collecting symbols (publics are appended at end-of-file).
  - `extern a, b, c`  -> one `extrn a` per symbol; duplicates are dropped
    (FASM rejects a repeated `extrn`).
  - `section .text`   -> `section '.text' executable`, etc.
  - `default rel`     -> dropped (`[rel X]` -> `[X]`): FASM is RIP-relative
    for data symbols by default.
  - `resb/resq/resd/resw` -> `rb/rq/rd/rw`.
  - `equ`             -> `=`; `$`-relative `equ` becomes an assembler-time
    `=`, which FASM evaluates after layout.
  - `~N`              -> `not N` (FASM expression operator).
  - `A | B | C` can't appear in a FASM operand, so `|` in an *operand* is
    rewritten to `or` only where it is an expression (symbols, not chars
    like `'|'`).
  - `bt [mem], reg`   -> `bt qword [mem], reg` (FASM wants an explicit size).
  - `%define`/`%macro`/`struc` translated (see the pass functions).
  - `match` is a FASM reserved word, so the label `match` is renamed.
"""
import re
import sys
from pathlib import Path

SRC = Path("/tmp/opencode/c2x-fasm")

# Labels that collide with FASM reserved words / directives.
RENAME = {"match": "match_tok"}


def split_symbols(rest: str):
    return [s for s in re.split(r"[,\s]+", rest.strip()) if s]


def collect_and_strip_directives(lines):
    """Remove `global`/`extern` lines, returning (body, publics, externs)."""
    body = []
    publics = []
    externs = []
    seen_ext = set()
    for line in lines:
        s = line.strip()
        m = re.match(r"^global\s+(.*)$", s)
        if m:
            for name in split_symbols(m.group(1)):
                if name not in publics:
                    publics.append(name)
            continue
        m = re.match(r"^extern\s+(.*)$", s)
        if m:
            for name in split_symbols(m.group(1)):
                if name not in seen_ext:
                    seen_ext.add(name)
                    externs.append(name)
            continue
        body.append(line)
    return body, publics, externs


SECTION_MAP = {
    "section .text": "section '.text' executable",
    "section .data": "section '.data' writeable",
    "section .bss": "section '.bss' writeable",
    "section .rodata": "section '.rodata'",
}


def split_strings(line):
    """Split a line into (code, string, code, string, ...) so transforms can
    skip the contents of double-quoted literals (the emitted assembly lives in
    `db "..."` strings and must keep its own spelling)."""
    parts = []
    buf = []
    i = 0
    n = len(line)
    while i < n:
        c = line[i]
        if c == '"':
            parts.append(("".join(buf), False))
            buf = ['"']
            i += 1
            while i < n and line[i] != '"':
                if line[i] == "\\" and i + 1 < n:
                    buf.append(line[i])
                    i += 1
                buf.append(line[i])
                i += 1
            if i < n:
                buf.append('"')
                i += 1
            parts.append(("".join(buf), True))
            buf = []
        else:
            buf.append(c)
            i += 1
    parts.append(("".join(buf), False))
    return parts


def transform_outside_strings(line, fn):
    out = []
    for text, is_str in split_strings(line):
        out.append(text if is_str else fn(text))
    return "".join(out)


def convert_sections(lines):
    out = []
    for line in lines:
        s = line.strip()
        if s in SECTION_MAP:
            out.append(SECTION_MAP[s])
            continue
        if s == "default rel":
            continue
        out.append(line)
    return out


def convert_defines_equ(lines):
    out = []
    for line in lines:
        m = re.match(r"^(\s*)%define\s+(\w+)\s+(.*?)\s*(;.*)?$", line)
        if m:
            indent, name, val, comment = m.groups()
            tail = ("  " + comment) if comment else ""
            out.append(f"{indent}{name} = {val}{tail}")
            continue
        # `NAME equ VALUE` -> `NAME = VALUE` (FASM `=` constant).
        m = re.match(r"^(\s*)([A-Za-z_]\w*)\s+equ\s+(.*?)\s*(;.*)?$", line)
        if m:
            indent, name, val, comment = m.groups()
            tail = ("  " + comment) if comment else ""
            out.append(f"{indent}{name} = {val}{tail}")
            continue
        out.append(line)
    return out


def _xform_reserves(text):
    text = re.sub(r"\bresb\b", "rb", text)
    text = re.sub(r"\bresq\b", "rq", text)
    text = re.sub(r"\bresd\b", "rd", text)
    text = re.sub(r"\bresw\b", "rw", text)
    return text


def convert_reserves(lines):
    return [transform_outside_strings(l, _xform_reserves) for l in lines]


def _xform_ops(text):
    # `[rel X` -> `[X`.
    text = re.sub(r"\[rel\s+", "[", text)
    # `~N` immediate -> `not N`.
    text = re.sub(r"~\s*(\w+)", r"not \1", text)
    # `bt [mem], reg` -> `bt qword [mem], reg` (size is required by FASM).
    text = re.sub(r"\bbt\s+\[", "bt qword [", text)
    return text


def convert_ops(lines):
    out = []
    for line in lines:
        # `mov rsi, A | B | C`: `|` between symbols is an OR expression, which
        # FASM spells `or`. Guard on a quoted char (`'|'`) and on comments.
        if "'|'" not in line:
            code, is_str = split_strings(line)[0]
            if "|" in code and ";" not in code[: code.find("|")]:
                pass
            line = re.sub(r"(?<=[A-Za-z0-9_)\s])\|(?=\s*[A-Za-z0-9_(])",
                          " or ", line)
        line = transform_outside_strings(line, _xform_ops)
        out.append(line)
    return out


def convert_times(lines):
    out = []
    for line in lines:
        # `label: times N db X` -> `label: db N dup X`
        m = re.match(r"^(\s*)([^;]*?)\btimes\s+(\S+)\s+db\s+(.+?)\s*$", line)
        if m and "times" in line:
            indent, label, count, val = m.groups()
            out.append(f"{indent}{label.rstrip()} db {count} dup {val}")
            continue
        out.append(line)
    return out


def convert_strucs(lines):
    """NASM `struc NAME ... .field resq 1 ... endstruc` becomes absolute
    constants `NAME.field = <offset>` (only offsets are ever used, as
    `[reg + NAME.field]`), plus the `NAME_size` total NASM also auto-defines."""
    out = []
    i = 0
    while i < len(lines):
        s = lines[i].strip()
        m = re.match(r"^struc\s+(\w+)\s*$", s)
        if not m:
            out.append(lines[i])
            i += 1
            continue
        name = m.group(1)
        i += 1
        off = 0
        fields = []
        while i < len(lines):
            fs = lines[i].strip()
            if fs == "endstruc":
                i += 1
                break
            fm = re.match(r"^\.(\w+)\s+(res[bqdw])\s+(\d+)", fs)
            if fm:
                field, _kind, count = fm.groups()
                fields.append(f"{name}.{field} = {off}")
                width = {"resb": 1, "resw": 2, "resd": 4, "resq": 8}[_kind]
                off += width * int(count)
            i += 1
        out += fields
        # NASM auto-defines `<struc>_size`; FASM does not, so emit it.
        out.append(f"{name}_size = {off}")
        continue
    return out


BARE_DATA_RE = re.compile(
    r"^(\s*)([A-Za-z_]\w*)(\s+)(res[bqdw]|db|dq|dd|dw)\b")


def add_data_label_colons(lines):
    """FASM needs an explicit `:` on a data label (`foo: rb 8`); NASM accepts
    `foo rb 8`. A bare `db 0` (no label) is left alone."""
    out = []
    for line in lines:
        if line.lstrip().startswith(";"):
            out.append(line)
            continue
        m = BARE_DATA_RE.match(line)
        if m and not m.group(2).endswith(":"):
            indent, name, sp, kind = m.groups()
            out.append(f"{indent}{name}:{sp}{kind}" + line[m.end():])
            continue
        out.append(line)
    return out


def convert_macros(lines):
    out = []
    i = 0
    while i < len(lines):
        s = lines[i].strip()
        m = re.match(r"^%macro\s+(\w+)\s+(\d+)(-?\*)?\s*$", s)
        if not m:
            out.append(lines[i])
            i += 1
            continue
        name = m.group(1)
        nparams = int(m.group(2))
        i += 1
        body = []
        while i < len(lines) and lines[i].strip() != "%endmacro":
            body.append(lines[i])
            i += 1
        i += 1  # skip %endmacro

        if name == "PROLOGUE":
            out += ["macro PROLOGUE [regs] {", "    push regs", "}"]
            continue
        if name == "EPILOGUE":
            # `reverse` the register list for the pops, then `common` so the
            # single trailing `ret` is emitted once (not once per register —
            # a bare `ret` after a `reverse` region repeats per iteration).
            out += ["macro EPILOGUE [regs] {", "    reverse",
                    "    pop regs", "    common", "    ret", "}"]
            continue
        mname = re.match(r"^syscall(\d+)$", name)
        if mname:
            # The declared param count (not the syscall number) is what the
            # macro body's %1..%N reference.
            argnames = ["nr", "a", "b", "c", "d", "e", "f"][:nparams]
            out.append(f"macro {name} {', '.join(argnames)}" + " {")
            out += translate_macro_body(body, argnames)
            out.append("}")
            continue
        raise SystemExit(f"unhandled macro {name}")
    return out


def translate_macro_body(body, argnames):
    res = []
    for line in body:
        def repl(m):
            idx = int(m.group(1))
            if idx == 0:
                return ""
            return argnames[idx - 1]
        res.append(re.sub(r"%(\d)", repl, line))
    return res


def convert_file(path: Path):
    raw = path.read_text()
    lines = raw.splitlines()
    lines = convert_strucs(lines)
    lines = convert_macros(lines)
    body, publics, externs = collect_and_strip_directives(lines)
    body = convert_sections(body)
    body = convert_defines_equ(body)
    body = add_data_label_colons(body)
    body = convert_reserves(body)
    body = convert_times(body)
    body = convert_ops(body)
    body = [rename_labels(l) for l in body]
    if path.name == "codegen.asm":
        body = convert_emitted_strings(body)
    if path.name == "compiler.asm":
        body = convert_invocation(body)
    body = fix_comments(body)

    # A source file with no `section` directive at all (syscalls.asm) defaults
    # to `.text` under NASM; FASM's default is `.flat` (WAX), which would make
    # the linked binary's writable segment executable. Pin it to `.text` so the
    # emitted object matches NASM's.
    if not any(l.strip().startswith("section '") for l in body):
        body = ["section '.text' executable", ""] + body

    header = ["format ELF64", ""]
    tail = []
    for name in externs:
        tail.append("extrn " + name)
    for name in publics:
        tail.append("public " + name)
    path.write_text("\n".join(header + body + tail) + "\n")


# ---------------------------------------------------------------------------
# Stage 2: c2x-seed *emits* assembly. Its templates and its assembler call must
# also speak FASM. The emitted text lives inside `db "..."` literals in
# codegen.asm, so these replacements target those literals by exact text.
# ---------------------------------------------------------------------------
EMITTED_STRING_FIXES = [
    # Directives.
    ('db "section .text"', "db \"section '.text' executable\""),
    ('db "section .data"', "db \"section '.data' writeable\""),
    ('db "section .bss"', "db \"section '.bss' writeable\""),
    ('db "section .rodata"', "db \"section '.rodata'\""),
    ('db "global "', 'db "public "'),
    ('db "extern g_"', 'db "extrn g_"'),
    ('db "    resq "', 'db "    rq "'),
    ('db "    resb "', 'db "    rb "'),
    # RIP-relative: FASM is RIP-relative by default, `rel` is not a keyword.
    ('[rel g_', '[g_'),
    ('[rel LC', '[LC'),
]

# The generated file must start with a format declaration.
FORMAT_ELIG64_STR = "format ELF64"


def convert_emitted_strings(lines):
    out = []
    for line in lines:
        for old, new in EMITTED_STRING_FIXES:
            line = line.replace(old, new)
        out.append(line)
    # Every emitted `db "...global NAME..."` preamble (the `_start` trampoline
    # strings embed `global _start` inline) must say `public`, not `global`.
    out = [re.sub(r'(\bdb\s+"[^"]*)\bglobal ', r'\1public ', l) for l in out]
    # Emit `format ELF64` as the very first thing codegen_generate writes.
    for idx, line in enumerate(out):
        if line.strip() == "mov rsi, asm_section_text" and \
           "codegen_generate" in "\n".join(out[:idx]):
            out[idx:idx] = ["    mov rsi, asm_format_elf64",
                            "    call emit_string"]
            break
    # Declare the string constant near asm_section_text.
    for idx, line in enumerate(out):
        if 'db "section \'.text\' executable"' in line:
            out.insert(idx, f'    asm_format_elf64:      db "{FORMAT_ELIG64_STR}", 10, 0')
            break
    return out


def convert_invocation(lines):
    """Point the driver at fasm: `fasm -m <limit> <src> <out>` (FASM cannot
    read from /dev/stdin and needs an explicit memory limit for the 16 MiB
    generated .bss; it does not embed the input path, so a PID temp name stays
    reproducible)."""
    out = []
    for line in lines:
        out.append(line)
    text = "\n".join(out)

    # --- Replace the nasm argv block with the fasm one. ---
    old_argv = """    ; Build nasm argv
    lea r15, [nasm_argv]
    mov rax, str_nasm_path
    mov [r15], rax          ; argv[0] = nasm path
    mov rax, str_f
    mov [r15 + 8], rax      ; argv[1] = "-f"
    mov rax, str_elf64
    mov [r15 + 16], rax     ; argv[2] = "elf64"
    mov rax, str_o_flag
    mov [r15 + 24], rax     ; argv[3] = "-o"
    lea rax, [tmp_obj_path]
    mov [r15 + 32], rax     ; argv[4] = tmp .o file
    mov rax, str_dev_stdin
    mov [r15 + 40], rax     ; argv[5] = "/dev/stdin" (stable FILE symbol)
    mov qword [r15 + 48], 0 ; argv[6] = NULL"""
    new_argv = """    ; Build fasm argv: fasm -m <limit> <asm> <obj>
    lea r15, [nasm_argv]
    mov rax, str_nasm_path
    mov [r15], rax          ; argv[0] = fasm path
    mov rax, str_m_flag
    mov [r15 + 8], rax      ; argv[1] = "-m"
    mov rax, str_mem_limit
    mov [r15 + 16], rax     ; argv[2] = memory limit (KB)
    lea rax, [tmp_asm_path]
    mov [r15 + 24], rax     ; argv[3] = input .asm (fasm needs a real path)
    lea rax, [tmp_obj_path]
    mov [r15 + 32], rax     ; argv[4] = tmp .o file
    mov qword [r15 + 40], 0 ; argv[5] = NULL"""
    if old_argv not in text:
        raise SystemExit("compiler.asm: nasm argv block not found")
    text = text.replace(old_argv, new_argv)

    # --- Drop the now-unused stdin dup2 for the assembler child. ---
    old_call = """    mov rdi, str_nasm_path
    lea rsi, [nasm_argv]
    mov rdx, [envp]
    mov rcx, [nasm_asm_fd]  ; rcx = fd to dup onto the child's stdin
    call run_and_wait
    mov rbx, rax            ; save status; always close our stdin copy
    mov rdi, [nasm_asm_fd]
    call sys_close
    test rbx, rbx
    jnz .asm_fail"""
    new_call = """    mov rdi, str_nasm_path
    lea rsi, [nasm_argv]
    mov rdx, [envp]
    mov rcx, -1             ; no stdin redirection for fasm
    call run_and_wait
    test rax, rax
    jnz .asm_fail"""
    if old_call not in text:
        raise SystemExit("compiler.asm: assembler call block not found")
    text = text.replace(old_call, new_call)

    # --- Silence fasm's stdout banner. `fasm` prints "flat assembler ..." and
    # a "N passes" line to stdout; diagnostics go to stderr. The child of
    # run_and_wait opens /dev/null and dup2's it onto fd 1 so a normal build
    # stays as quiet as the nasm one was (errors still reach the terminal). ---
    old_child = """.child:
    ; Redirect stdin if a source fd was provided.
    cmp r14, 0
    jl .child_exec
    mov rdi, r14            ; oldfd
    xor rsi, rsi            ; newfd = 0 (stdin)
    call sys_dup2
.child_exec:"""
    new_child = """.child:
    ; Redirect stdin if a source fd was provided.
    cmp r14, 0
    jl .child_null
    mov rdi, r14            ; oldfd
    xor rsi, rsi            ; newfd = 0 (stdin)
    call sys_dup2
.child_null:
    ; Drop stdout to /dev/null: fasm prints a version banner there and
    ; diagnostics on stderr. Keeps a clean build (errors still visible).
    lea rdi, [str_dev_null]
    mov rsi, 1              ; O_WRONLY
    xor rdx, rdx
    call sys_open
    test rax, rax
    js .child_exec
    mov rdi, rax            ; oldfd = /dev/null
    mov rsi, 1              ; newfd = 1 (stdout)
    call sys_dup2
.child_exec:"""
    if old_child not in text:
        raise SystemExit("compiler.asm: run_and_wait child block not found")
    text = text.replace(old_child, new_child)

    # Swap the now-unused /dev/stdin path constant for the /dev/null one the
    # child uses to drop fasm's stdout banner.
    text = re.sub(
        r'str_dev_stdin:?\s+db "/dev/stdin", 0[^\n]*\n',
        'str_dev_null:     db "/dev/null", 0\n', text)

    # --- Remove the temp-.asm open/close that only existed for the stdin pipe. ---
    old_open = """    ; Open the temp .asm read-only; its fd is dup2'd onto the child's stdin.
    lea rdi, [tmp_asm_path]
    xor rsi, rsi            ; O_RDONLY
    xor rdx, rdx
    call sys_open
    test rax, rax
    js .asm_fail            ; unreadable temp .asm -> assembler cannot run
    mov [nasm_asm_fd], rax

"""
    text = text.replace(old_open, "")

    # --- Paths / flags. ---
    text = re.sub(r"str_nasm_path:?\s+db \"/usr/bin/nasm\", 0",
                  'str_nasm_path: db "/usr/bin/fasm", 0', text)
    text = re.sub(r"str_f:?\s+db \"-f\", 0",
                  'str_m_flag: db "-m", 0', text)
    text = re.sub(r"str_elf64:?\s+db \"elf64\", 0",
                  'str_mem_limit: db "262144", 0', text)

    # --- Comment accuracy: the assembler is now fasm, and the build no longer
    # pipes assembly on stdin. ---
    text = text.replace("; --- NASM: assemble .asm -> .o ---",
                        "; --- ASM: assemble .asm -> .o (fasm) ---")
    text = text.replace("""    ; The assembly is fed to nasm on stdin (input argument "/dev/stdin"),
    ; NOT through its PID-unique temp path. nasm records the *input path* in
    ; the object's FILE symbol, and `ld` copies that into the final
    ; executable's .strtab; a temp path containing the PID would make the
    ; output binary differ on every build. "/dev/stdin" is stable, so the
    ; build is reproducible (docs/harmony.md §25.6). The temp .asm is still
    ; written to disk so --keep-asm can show it after a failure.""",
                        """    ; fasm reads the temp .asm by path and does NOT embed that path in the
    ; object, so a PID-unique temp name stays reproducible (docs/harmony.md
    ; §25.6). The nasm build needed a stable "/dev/stdin" name for the same
    ; reason. The temp .asm is written to disk so --keep-asm can show it.""")
    text = text.replace("; If -o was given, close temp file and run nasm+ld",
                        "; If -o was given, close temp file and run fasm+ld")
    text = text.replace("; Build final binary by running nasm + ld as subprocesses.",
                        "; Build final binary by running fasm + ld as subprocesses.")
    text = text.replace("; the assembly stream must stay clean (nasm parses stdout as input).",
                        "; the assembly stream must stay clean (the compiler banners go to stderr).")
    text = text.replace("; Abort before invoking nasm,",
                        "; Abort before invoking the assembler,")
    text = text.replace("; execve, so a tool like nasm can read its input from stdin. Pass -1 to leave",
                        "; execve (for tools that read their input on stdin). Pass -1 to leave")
    return text.splitlines()


# Comments that name the old assembler; updated so the committed FASM source
# reads correctly. Purely cosmetic (code comments), matched by exact text.
COMMENT_FIXES = [
    ("; Walks AST and emits x86_64 NASM assembly",
     "; Walks AST and emits x86_64 assembly (the FASM dialect)"),
    ("; These let c2x-proto (and other generated compilers) fork/exec nasm+ld to",
     "; These let c2x-proto (and other generated compilers) fork/exec ld to"),
    ("; Build final binary by running nasm + ld as subprocesses.",
     "; Build final binary by running fasm + ld as subprocesses."),
    ("; The temp assembly file hit the asm safety cap. Abort before invoking nasm,",
     "; The temp assembly file hit the asm safety cap. Abort before assembling,"),
    ("    nasm_asm_fd:     rq 1          ; read-only fd of the temp .asm, dup2'd to nasm's stdin",
     "    nasm_asm_fd:     rq 1          ; (unused by fasm; kept for the nasm build)"),
    ("    nasm_argv:       rq 7          ; nasm, -f, elf64, -o, tmp.o, tmp.asm, NULL",
     "    nasm_argv:       rq 7          ; fasm, -m, <limit>, tmp.asm, tmp.o, NULL"),
    ("; Written in x86_64 NASM Assembly for Linux",
     "; Written in x86_64 assembly (flat assembler / FASM syntax) for Linux"),
    ("; Build: nasm -f elf64 -o build/main.o bootstrap/c2x-seed/main.asm",
     "; Build: bash build.sh (fasm assembles each bootstrap/c2x-seed/*.asm)"),
]


def fix_comments(lines):
    out = []
    for line in lines:
        for old, new in COMMENT_FIXES:
            line = line.replace(old, new)
        out.append(line)
    return out


def rename_labels(line):
    for old, new in RENAME.items():
        line = re.sub(rf"\b{old}\b", new, line)
    return line


def main():
    for f in sorted(SRC.glob("*.asm")):
        convert_file(f)
        print("converted", f.name)


if __name__ == "__main__":
    main()
