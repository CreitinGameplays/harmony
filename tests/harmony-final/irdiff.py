#!/usr/bin/env python3
"""Byte-for-byte LLVM IR differential gate (roadmap/harmony R6, gate 1).

The rewrite's emitter and harmony-base's emitter must produce the *same bytes*
for every accepted program in the corpus. The rewrite is compiled once into a
batch driver (lowering ~2,600 lines of Harmony for every case separately is
far too slow); the driver then prints each program's IR between markers.

    python3 tests/harmony-final/irdiff.py [corpus-directory]
"""
import difflib
import os
import posixpath
import re
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import typeharness

ROOT = typeharness.ROOT
HB = typeharness.HB
TEMPLATE = os.path.join(ROOT, "tests/harmony-final/irbatch.hr")
DRIVER = os.path.join(ROOT, "tests/harmony-final/irbatch_gen.hr")


def gather_modules(root_path):
    """Returns (virtual_path, source) for the root and its import graph.

    The rewrite has no file IO yet, so the driver receives every module as an
    embedded string. Virtual paths are relative to the root module, exactly
    like harmony-base's import resolution.
    """
    root_dir = os.path.dirname(root_path)
    modules = []
    seen = set()
    pending = [(root_path, "main.harmony")]
    while pending:
        actual, virtual = pending.pop(0)
        if actual in seen:
            continue
        seen.add(actual)
        src = open(actual).read()
        modules.append((virtual, src))
        # Ignore import examples in comments.
        code = re.sub(r"//.*", "", src)
        code = re.sub(r"/\*.*?\*/", "", code, flags=re.S)
        for imported in re.findall(r'\bimport\s+"([^"]+)"', code):
            child_actual = os.path.normpath(os.path.join(os.path.dirname(actual), imported))
            child_virtual = posixpath.normpath(posixpath.join(posixpath.dirname(virtual), imported))
            pending.append((child_actual, child_virtual))
    return modules


def corpus(which):
    directory = os.path.join(ROOT, "tests/harmony", which)
    singles, modules = [], []
    for fn in sorted(os.listdir(directory)):
        if not fn.endswith(".harmony"):
            continue
        path = os.path.join(directory, fn)
        src = open(path).read()
        if 'import "' in src:
            modules.append((fn, path, gather_modules(path)))
        else:
            singles.append((fn, path, src))
    return singles, modules


def replace_array(body, name, element_type, values):
    if element_type == "&str":
        literal = ",\n        ".join('"%s"' % typeharness.hs(v) for v in values)
    else:
        literal = ",\n        ".join(str(v) for v in values)
    arr = "let %s: [%s; %d] = [\n        %s,\n    ];" % (
        name, element_type, len(values), literal)
    return re.sub(r"let %s: \[%s; \d+\] = \[.*?\];" % (name, element_type),
                  lambda _m: arr, body, count=1, flags=re.S)


def build_driver(singles, module_cases):
    body = open(TEMPLATE).read()
    module_paths = []
    module_chunks = []
    chunk_starts = []
    chunk_ends = []
    module_roots = []
    starts = []
    ends = []
    for _name, _path, mods in module_cases:
        starts.append(len(module_paths))
        for path, src in mods:
            module_paths.append(path)
            chunk_starts.append(len(module_chunks))
            # Harmony string literals have a fixed maximum length. Keep the
            # embedded pieces comfortably below it.
            pieces = [src[i:i + 1000] for i in range(0, len(src), 1000)]
            module_chunks.extend(pieces or [""])
            chunk_ends.append(len(module_chunks))
        ends.append(len(module_paths))
        module_roots.append("main.harmony")
    # Replace the small arrays before inserting source text: a corpus file
    # could itself contain one of these declaration spellings.
    body = replace_array(body, "module_paths", "&str", module_paths or ["main.harmony"])
    body = replace_array(body, "module_chunks", "&str", module_chunks or ["fn main() -> i32 { return 0; }"])
    body = replace_array(body, "chunk_starts", "i32", [str(v) for v in chunk_starts] or ["0"])
    body = replace_array(body, "chunk_ends", "i32", [str(v) for v in chunk_ends] or ["1"])
    body = replace_array(body, "module_roots", "&str", module_roots or ["main.harmony"])
    body = replace_array(body, "module_starts", "i32", [str(v) for v in starts] or ["0"])
    body = replace_array(body, "module_ends", "i32", [str(v) for v in ends] or ["1"])
    body = replace_array(body, "sources", "&str", [src for _n, _p, src in singles])
    open(DRIVER, "w").write(body)
    work = tempfile.mkdtemp(prefix="harmony-irbatch-", dir="/tmp/opencode")
    out = os.path.join(work, "batch")
    b = subprocess.run([HB, "build", DRIVER, "-o", out],
                       capture_output=True, text=True)
    if b.returncode != 0:
        raise SystemExit("IR batch driver build failed:\n" + (b.stdout + b.stderr)[:4000])
    return out


def split_ir(output):
    result = {}
    pattern = re.compile(r"@@@CASE (\d+)\n@@@IR\n(.*?)@@@END \d+\n", re.S)
    for m in pattern.finditer(output):
        result[int(m.group(1))] = m.group(2).encode()
    return result


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else "codegen"
    singles, module_cases = corpus(which)
    cases = [(name, path) for name, path, _src in singles]
    cases += [(name, path) for name, path, _mods in module_cases]
    if not cases:
        print("no cases")
        return 1
    t0 = time.time()
    driver = build_driver(singles, module_cases)
    t1 = time.time()
    rewrite = {}
    mismatches = 0
    skipped = 0
    for i, (name, path) in enumerate(cases):
        # One process per case keeps a runtime trap in one lowered program
        # from hiding every later case. The expensive part (compiling the
        # emitter) still happens only once.
        run = subprocess.run([driver, str(i)], capture_output=True, text=True)
        rewrite.update(split_ir(run.stdout))
        oracle = subprocess.run([HB, "emit-llvm", path], capture_output=True)
        expected = oracle.stdout
        got = rewrite.get(i)
        # M2 changes the final compiler's IR for owning types by design: drop
        # flags and structural clone helpers do not exist in v0 harmony-base.
        # Skip those cases here but still compare every M2-neutral program.
        if (b"MOVE-" in (run.stdout + run.stderr).encode()
                or (got is not None and (b"harmony__drop__" in got
                                         or b"harmony__clone__" in got))):
            skipped += 1
            continue
        if got != expected:
            mismatches += 1
            print("MISMATCH %s" % name)
            if got is None:
                print("  rewrite produced no IR")
                continue
            diff = difflib.unified_diff(
                expected.decode(errors="replace").splitlines(),
                got.decode(errors="replace").splitlines(),
                fromfile="harmony-base", tofile="harmony", lineterm="")
            for line in list(diff)[:40]:
                print("  " + line)
    try:
        os.remove(DRIVER)
    except OSError:
        pass
    shutil.rmtree(os.path.dirname(driver), ignore_errors=True)
    t2 = time.time()
    print("\nbuild %.2fs, diff %.2fs, %d cases, %d mismatches, %d M2-skipped" %
          (t1 - t0, t2 - t1, len(cases), mismatches, skipped))
    return 1 if mismatches else 0


if __name__ == "__main__":
    sys.exit(main())
