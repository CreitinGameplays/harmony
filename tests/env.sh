#!/usr/bin/env bash
# Shared test-harness configuration (post bootstrap-retirement).
#
#   HARMONY  compiler under test — the canonical self-hosted compiler.
#   HC       the compiler used by the v1/differential suites; the same binary.
#   HB       backwards-compatible alias for HARMONY.
#
# The legacy ORACLE and the HARMONY/ORACLE lane switches were retired together
# with the bootstrap toolchain. Their frozen forms live on the
# `legacy/bootstrap` branch, tagged `legacy/bootstrap-final`.
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HARMONY="${HARMONY:-$ROOT/build/harmony}"
HC="${HC:-$ROOT/build/harmony}"
HB="$HARMONY"
export ROOT HARMONY HC HB
