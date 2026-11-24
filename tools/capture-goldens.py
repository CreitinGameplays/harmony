#!/usr/bin/env python3
"""Capture (or verify) the legacy compiler's oracle outputs as goldens.

This is Phase 1 of the bootstrap retirement. It is purely additive: it writes
files under tests/golden/v0.3.3/ (or, with --verify, compares against them in a
temporary directory). No source is deleted, no tag is created, no release is
published. The legacy harmony-base binary must be built (`make harmony-base`).

Usage:
    python3 tools/capture-goldens.py            # write goldens
    python3 tools/capture-goldens.py --verify   # re-capture and diff
"""
import argparse
import difflib
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "tests"))
sys.path.insert(0, os.path.join(ROOT, "tests", "harmony-final"))
import env  # noqa: E402
import difftest  # noqa: E402
import parsediff  # noqa: E402
import resolvediff  # noqa: E402
import typediff  # noqa: E402
import irdiff  # noqa: E402

HB = env.ORACLE
OUT = os.path.join(ROOT, "tests", "golden", "v0.3.3")
CODE_RE = re.compile(r"\b([A-Z]+-\d+)\b")


def run(args, cwd=ROOT):
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def codes(text):
    return " ".join(sorted(set(CODE_RE.findall(text))))


def capture(dst, work):
    """Capture every oracle output into dst (an existing directory)."""
    def put(rel, text):
        path = os.path.join(dst, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)

    # 1. Token streams (difftest snippets).
    for i, src in enumerate(difftest.SNIPPETS):
        f = os.path.join(work, "tok%d.harmony" % i)
        with open(f, "w") as fh:
            fh.write(src)
        r = run([HB, "--dump-tokens", f])
        put("tokens/%02d.tok" % i, r.stdout)
    put("tokens/SNIPPETS.txt",
        "".join("%02d: %s\n" % (i, s) for i, s in enumerate(difftest.SNIPPETS)))

    # 2. AST dumps (parsediff accept cases) and codes for reject cases.
    for i, src in enumerate(parsediff.ACCEPT):
        f = os.path.join(work, "ast%d.harmony" % i)
        with open(f, "w") as fh:
            fh.write(src + "\n")
        r = run([HB, "check", "--dump-ast", f])
        put("ast/accept_%02d.ast" % i, r.stdout)
    for i, (src, want) in enumerate(parsediff.REJECT):
        f = os.path.join(work, "astrej%d.harmony" % i)
        with open(f, "w") as fh:
            fh.write(src + "\n")
        r = run([HB, "check", f])
        put("ast/reject_%02d.codes" % i,
            "want=%s got=%s\n" % (want, codes(r.stdout + r.stderr)))

    # 3. Resolver NAME-* codes.
    for name, modules, root in resolvediff.CASES:
        case_dir = os.path.join(work, "resolve", name)
        os.makedirs(case_dir, exist_ok=True)
        for path, src in modules.items():
            fp = os.path.join(case_dir, path)
            os.makedirs(os.path.dirname(fp), exist_ok=True)
            with open(fp, "w") as fh:
                fh.write(src)
        r = run([HB, "check", "--format=line", os.path.join(case_dir, root)])
        put("resolve/%s.codes" % name, codes(r.stdout + r.stderr) + "\n")

    # 4. Type-checker codes, for the inline corpus and the .harmony corpora.
    for name, src in typediff.CASES:
        f = os.path.join(work, "type_%s.harmony" % name)
        with open(f, "w") as fh:
            fh.write(src)
        r = run([HB, "check", "--all", f])
        put("types/snippets/%s.codes" % name, codes(r.stdout + r.stderr) + "\n")
    for corpus in ("error-handling", "codegen"):
        for path in sorted(glob.glob(os.path.join(ROOT, "tests", "harmony", corpus, "*.harmony"))):
            r = run([HB, "check", "--all", path])
            put("types/%s/%s.codes" % (corpus, os.path.basename(path)),
                codes(r.stdout + r.stderr) + "\n")

    # 5. Byte-exact LLVM IR for the codegen corpus (single- and multi-module).
    singles, module_cases = irdiff.corpus("codegen")
    for name, path, _src in singles:
        r = run([HB, "emit-llvm", path])
        put("ir/%s.ll" % name, r.stdout)
    for name, _path, mods in module_cases:
        case_dir = os.path.join(work, "irmod", name)
        os.makedirs(case_dir, exist_ok=True)
        for virtual, src in mods:
            fp = os.path.join(case_dir, virtual)
            os.makedirs(os.path.dirname(fp), exist_ok=True)
            with open(fp, "w") as fh:
                fh.write(src)
        r = run([HB, "emit-llvm", os.path.join(case_dir, "main.harmony")])
        put("ir/modules/%s.ll" % name, r.stdout)

    # 6. Driver surfaces and formatter token stream.
    put("driver/explain_CONST-01.txt", run([HB, "explain", "CONST-01"]).stdout)
    # Use repo-relative paths so goldens are machine-independent.
    audit_src = "tests/harmony/codegen/unchecked-fn.harmony"
    put("driver/audit.json", run([HB, "audit", "--format=json", audit_src]).stdout)
    ir_src = "tests/harmony/codegen/return-constant.harmony"
    put("driver/emit-llvm.ll", run([HB, "emit-llvm", ir_src]).stdout)
    fmt_src = "tests/harmony-final/fmt/sample.harmony"
    put("fmt/sample.tok", run([HB, "--dump-tokens", fmt_src]).stdout)

    manifest = {
        "oracle": os.path.relpath(HB, ROOT),
        "oracle_sha256": sha256_file(HB),
        "legacy_commit": subprocess.run(["git", "rev-parse", "HEAD"],
                                        cwd=ROOT, capture_output=True,
                                        text=True).stdout.strip(),
        "counts": {
            "tokens": len(difftest.SNIPPETS),
            "ast_accept": len(parsediff.ACCEPT),
            "ast_reject": len(parsediff.REJECT),
            "resolve": len(resolvediff.CASES),
            "types_snippets": len(typediff.CASES),
            "ir_singles": len(singles),
            "ir_modules": len(module_cases),
        },
    }
    put("MANIFEST.json", json.dumps(manifest, indent=2, sort_keys=True) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--verify", action="store_true",
                    help="capture into a temp dir and diff against the committed goldens")
    args = ap.parse_args()
    if not os.path.isfile(HB) or not os.access(HB, os.X_OK):
        raise SystemExit("oracle not built: %s (run 'make harmony-base')" % HB)

    work = tempfile.mkdtemp(prefix="harmony-goldens-")
    try:
        if not args.verify:
            os.makedirs(OUT, exist_ok=True)
            capture(OUT, work)
            print("goldens written to %s" % os.path.relpath(OUT, ROOT))
            return 0
        tmp_out = os.path.join(work, "goldens")
        os.makedirs(tmp_out)
        capture(tmp_out, work)
        # MANIFEST records provenance (including the HEAD at capture time), so
        # it necessarily differs on every later commit; only oracle outputs
        # are verified here.
        diff = subprocess.run(["diff", "-ru", "--exclude=MANIFEST.json",
                               OUT, tmp_out], capture_output=True, text=True)
        if diff.returncode == 0:
            print("goldens verified: %s" % os.path.relpath(OUT, ROOT))
            return 0
        print(diff.stdout[:8000])
        print("goldens MISMATCH", file=sys.stderr)
        return 1
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
