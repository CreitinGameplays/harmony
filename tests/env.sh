#!/usr/bin/env bash
# Shared test-harness configuration for the bootstrap-retirement burn-in.
#
#   HARMONY  compiler under test for *compatibility* suites (tests/harmony/*,
#            harmony-final/run.sh, fuzzers). Defaults to legacy harmony-base
#            so the historical lane is unchanged; set HARMONY=build/harmony
#            to burn in the self-hosted compiler on those same suites.
#   HC       the self-hosted compiler used by v1-only and differential suites.
#            Defaults to build/harmony. It is intentionally NOT controlled by
#            HARMONY: those suites test the v1 compiler against a reference.
#   ORACLE   the reference compiler for differential suites (legacy by
#            default). Keep it on harmony-base during the burn-in.
#   HB       backwards-compatible alias for ORACLE.
#
# Sourcing keeps a ROOT already set by the caller; otherwise ROOT is derived
# from this file's location (the tests/ directory's parent).
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HARMONY="${HARMONY:-$ROOT/build/harmony-base}"
HC="${HC:-$ROOT/build/harmony}"
ORACLE="${ORACLE:-$ROOT/build/harmony-base}"
HB="$ORACLE"
export ROOT HARMONY HC ORACLE HB
