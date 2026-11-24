#!/usr/bin/env bash
# M5 diagnostics polish gate: story/fix data, glyph fallbacks, colour,
# cascade folding, display caps, sorting and the full explain corpus.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/env.sh"
DIR="$ROOT/tests/harmony-final/diag"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

if [ ! -x "$HC" ]; then
    echo "error: build harmony first" >&2
    exit 1
fi
cd "$ROOT"

# --- story, fixes and JSON structure ---------------------------------------
"$HC" check "$DIR/fold.harmony" >"$TMP/story.out" 2>&1
if grep -q '①  7  let a = Owner' "$TMP/story.out" \
    && grep -q '②  8  take(a)' "$TMP/story.out" \
    && grep -q '③  9  let b = a.v' "$TMP/story.out" \
    && grep -q '◂ here' "$TMP/story.out"; then
    ok "ownership story is numbered and time-ordered"
else
    bad "ownership story is numbered and time-ordered"
    head -12 "$TMP/story.out" | sed 's/^/     /'
fi
if grep -q '^   also used at lines 10$' "$TMP/story.out" \
    && [ "$(grep -c 'STOP  MOVE-01' "$TMP/story.out")" -eq 1 ]; then
    ok "follow-on uses fold into one report"
else
    bad "follow-on uses fold into one report"
    head -12 "$TMP/story.out" | sed 's/^/     /'
fi
if [ "$(grep -c '^   try:' "$TMP/story.out")" -ge 1 ]; then
    ok "STOP carries a concrete try: fix"
else
    bad "STOP carries a concrete try: fix"
fi

"$HC" check --format=json "$DIR/fold.harmony" >"$TMP/story.json" 2>&1
if grep -q '"role": "born"' "$TMP/story.json" \
    && grep -q '"role": "moved"' "$TMP/story.json" \
    && grep -q '"role": "used", "file"' "$TMP/story.json" \
    && grep -q '"trigger": true' "$TMP/story.json" \
    && grep -q '"fixes": \[{"label"' "$TMP/story.json" \
    && grep -q '"also_used": \[10\]' "$TMP/story.json" \
    && grep -q '"learn": "harmony explain MOVE-01"' "$TMP/story.json"; then
    ok "JSON carries roles, fixes, folded uses and learn"
else
    bad "JSON carries roles, fixes, folded uses and learn"
    head -2 "$TMP/story.json" | sed 's/^/     /'
fi

# --- glyph fallbacks and colour ---------------------------------------------
"$HC" check --ascii "$DIR/fold.harmony" >"$TMP/ascii.out" 2>&1
if grep -q '(1)  7' "$TMP/ascii.out" && grep -q '<-- here' "$TMP/ascii.out" \
    && ! grep -q '①' "$TMP/ascii.out"; then
    ok "--ascii substitutes step and pointer glyphs"
else
    bad "--ascii substitutes step and pointer glyphs"
fi
if grep -q '①' "$TMP/story.out" && grep -q '◂ here' "$TMP/story.out"; then
    ok "default pretty output uses Unicode glyphs"
else
    bad "default pretty output uses Unicode glyphs"
fi

if command -v script >/dev/null 2>&1; then
    script -qec "$HC check $DIR/fold.harmony" /dev/null >"$TMP/tty.out" 2>&1
    if grep -q $'\033\[31mSTOP' "$TMP/tty.out"; then
        ok "colour is enabled on a terminal"
    else
        bad "colour is enabled on a terminal"
    fi
    script -qec "$HC --no-color check $DIR/fold.harmony" /dev/null \
        >"$TMP/tty-nocolor.out" 2>&1
    if ! grep -q $'\033\[' "$TMP/tty-nocolor.out"; then
        ok "--no-color suppresses ANSI decoration"
    else
        bad "--no-color suppresses ANSI decoration"
    fi
    script -qec "env NO_COLOR=1 $HC check $DIR/fold.harmony" /dev/null \
        >"$TMP/tty-env.out" 2>&1
    if ! grep -q $'\033\[' "$TMP/tty-env.out"; then
        ok "NO_COLOR suppresses ANSI decoration"
    else
        bad "NO_COLOR suppresses ANSI decoration"
    fi
else
    ok "terminal colour checks skipped (script(1) unavailable)"
fi

# --- imported sources -------------------------------------------------------
"$HC" check "$DIR/main.harmony" >"$TMP/import.out" 2>&1
if grep -q 'child.harmony:2' "$TMP/import.out" \
    && grep -q '▸  2  export fn bad' "$TMP/import.out"; then
    ok "imported diagnostics quote their own source and path"
else
    bad "imported diagnostics quote their own source and path"
    head -12 "$TMP/import.out" | sed 's/^/     /'
fi

# --- ordering, caps and --all ------------------------------------------------
"$HC" check --format=line "$DIR/caps.harmony" >"$TMP/caps.line" 2>&1
if [ "$(grep -c 'stop\[TYPE-01\]' "$TMP/caps.line")" -eq 5 ] \
    && grep -q '1 more stops (use --all)' "$TMP/caps.line"; then
    ok "stop display is capped at five with a tail note"
else
    bad "stop display is capped at five with a tail note"
    cat "$TMP/caps.line" | sed 's/^/     /'
fi
"$HC" --all check --format=line "$DIR/caps.harmony" >"$TMP/all.line" 2>&1
if [ "$(grep -c 'stop\[TYPE-01\]' "$TMP/all.line")" -eq 6 ] \
    && ! grep -q 'more stops' "$TMP/all.line"; then
    ok "--all lifts the display cap"
else
    bad "--all lifts the display cap"
fi
sorted=$(grep 'stop\[TYPE-01\]' "$TMP/all.line" | sed -E 's/.*:[0-9]+:[0-9]+:.*//' | sort -u | wc -l)
if [ "$sorted" -eq 1 ]; then
    ok "diagnostics are ordered by primary location"
else
    bad "diagnostics are ordered by primary location"
fi

# --- every STOP has a fix ----------------------------------------------------
stops=$(grep -c '^STOP  ' "$TMP/all.line" 2>/dev/null || true)
# line format has no STOP headers; re-render pretty with --all.
"$HC" --all check "$DIR/caps.harmony" >"$TMP/all.pretty" 2>&1
stops=$(grep -c '^STOP  ' "$TMP/all.pretty")
fixes=$(grep -c '^   try:' "$TMP/all.pretty")
if [ "$stops" -gt 0 ] && [ "$stops" -eq "$fixes" ]; then
    ok "every STOP carries at least one try: fix"
else
    bad "every STOP carries at least one try: fix ($stops stops, $fixes fixes)"
fi

# --- the full explain corpus -------------------------------------------------
codes="ICE-01 SYN-01 SYN-02 SYN-03 SYN-04 SYN-05 LEX-01 NAME-01 NAME-02 \
NAME-03 NAME-04 SHADOW-01 TYPE-01 TYPE-02 TYPE-03 TYPE-04 TYPE-05 TYPE-06 \
ABLT-01 ABLT-02 FMT-01 FFI-01 CONST-01 FLOW-01 FLOW-02 FLOW-03 MACRO-01 \
MACRO-02 MACRO-03 MACRO-04 MUT-01 MUT-02 MUT-03 INIT-01 MOVE-01 MOVE-02 \
MOVE-03 MOVE-04 LOAN-01 LOAN-02 LOAN-03 LIFE-01 LIFE-02 LIFE-03 LIFE-04 \
CASE-01 CASE-02 DROP-01 DROP-02 UNCK-01 UNCK-02 UNCK-03 UNCK-04 UNCK-05 \
UNUSED-01 UNUSED-02 DEAD-01 STYLE-01 RET-01"
missing=""
for code in $codes; do
    "$HC" explain "$code" >"$TMP/explain" 2>&1
    if ! head -1 "$TMP/explain" | grep -q "^$code" \
        || ! grep -q '^WHAT   ' "$TMP/explain" \
        || ! grep -q '^WHY    ' "$TMP/explain" \
        || ! grep -q '^BAD    ' "$TMP/explain" \
        || ! grep -q '^GOOD   ' "$TMP/explain" \
        || ! grep -q '^NOTE   ' "$TMP/explain" \
        || ! grep -q '^SEE    ' "$TMP/explain"; then
        missing="$missing $code"
    fi
done
if [ -z "$missing" ]; then
    ok "all documented codes have a full explain lesson"
else
    bad "incomplete explain lessons:$missing"
fi
if "$HC" explain NOPE-99 >"$TMP/unknown" 2>&1; then
    bad "unknown explain code is rejected"
else
    ok "unknown explain code is rejected"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
