#!/usr/bin/env bash
# Regenerates the root VERSION file (AGENTS.md: Semantic Versioning 2.0.0,
# rolling support only).
#
#   MAJOR.MINOR.PATCH-dev|beta|stable.NUMBER+<short-commit-sha>
#
# Example: `1.0.0-dev.1+130fa507`
#
# The base (MAJOR.MINOR.PATCH) is *preserved* from the existing VERSION file:
# bumping it is a deliberate release action, not something a build should
# decide. Everything after it is derived from the repository state, so the
# file is never hand-edited:
#
#   channel  stable — HEAD carries a release tag.
#            beta   — HEAD is on a release branch (`1.0`, `1.1`, ...).
#            dev    — anything else.
#   NUMBER   commits since the last release tag (all commits when there is no
#            tag yet). A release resets it, because the tag moves the base.
#   sha      the short commit sha of HEAD, as SemVer build metadata.
#
# Usage: tools/version.sh [--print]
#   --print   write to stdout instead of the VERSION file.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT/VERSION"
PRINT=0
[ "${1:-}" = "--print" ] && PRINT=1

cd "$ROOT"

# ---- base version ----------------------------------------------------------
# The base (MAJOR.MINOR.PATCH) has two sources:
#   * on a release branch (`1.0`, `1.1`, ...) the branch *is* the version:
#     `1.0` means 1.0.x, so the major/minor come from the branch name and the
#     patch is preserved when the file already carries one for it;
#   * elsewhere the base is preserved from the existing VERSION file, because
#     bumping it is a deliberate release action, not a build decision.
base=""
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
branch_base=""
if printf '%s' "$branch" | grep -Eq '^[0-9]+\.[0-9]+$'; then
    branch_base="$(printf '%s' "$branch" | awk -F. '{printf "%d.%d", $1, $2}')"
fi

file_base=""
file_patch=""
if [ -f "$VERSION_FILE" ]; then
    file_base="$(sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' \
        "$VERSION_FILE" | head -1)"
    file_patch="$(printf '%s' "$file_base" | cut -d. -f3)"
fi

if [ -n "$branch_base" ]; then
    base="${branch_base}.0"
    # Keep a patch already recorded for this major.minor.
    if [ -n "$file_base" ]; then
        file_minor="$(printf '%s' "$file_base" | cut -d. -f1,2)"
        if [ "$file_minor" = "$branch_base" ] && [ -n "$file_patch" ]; then
            base="${branch_base}.${file_patch}"
        fi
    fi
elif [ -n "$file_base" ]; then
    base="$file_base"
else
    # No VERSION file yet: start from the language spec version, which the
    # design document carries (`docs/harmony.md` → "Conceptual Design
    # Document · vX.Y.Z").
    spec="$(sed -n 's/^### Conceptual Design Document . v\([0-9][0-9.]*\).*/\1/p' \
        "$ROOT/docs/harmony.md" | head -1)"
    base="$(printf '%s' "${spec:-0.0.0}" | awk -F. '{printf "%d.%d.%d", $1, $2, $3}')"
fi

# ---- channel ---------------------------------------------------------------
channel="dev"
number=0
sha="$(git rev-parse --short=8 HEAD 2>/dev/null || echo "unknown")"

last_tag="$(git describe --tags --abbrev=0 2>/dev/null || true)"

if [ -n "$last_tag" ] && git diff --quiet HEAD "${last_tag}^{commit}" 2>/dev/null; then
    # HEAD *is* the tagged release.
    channel="stable"
    number=1
elif [ -n "$branch_base" ]; then
    # A release branch: `1.0`, `1.1`, ...
    channel="beta"
    if [ -n "$last_tag" ]; then
        number="$(git rev-list --count "${last_tag}^{commit}..HEAD" 2>/dev/null || echo 1)"
    else
        number="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
    fi
else
    channel="dev"
    if [ -n "$last_tag" ]; then
        number="$(git rev-list --count "${last_tag}^{commit}..HEAD" 2>/dev/null || echo 1)"
    else
        number="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
    fi
fi

version="${base}-${channel}.${number}+${sha}"

if [ "$PRINT" = "1" ]; then
    printf '%s\n' "$version"
    exit 0
fi

# Write only when the content changes, so a build does not churn the file.
if [ -f "$VERSION_FILE" ] && [ "$(cat "$VERSION_FILE")" = "$version" ]; then
    exit 0
fi
printf '%s\n' "$version" > "$VERSION_FILE"
echo "VERSION: $version"
