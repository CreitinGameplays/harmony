#!/usr/bin/env python3
"""Shared test-harness configuration for the bootstrap-retirement burn-in.

Mirrors tests/env.sh:

    HARMONY = compiler under test for compatibility suites (default: legacy)
    HC      = self-hosted compiler used by v1-only / differential suites
    ORACLE  = differential oracle (default: legacy harmony-base)
    HB      = backwards-compatible alias for ORACLE
"""
import os

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
HARMONY = os.environ.get("HARMONY", os.path.join(ROOT, "build", "harmony-base"))
HC = os.environ.get("HC", os.path.join(ROOT, "build", "harmony"))
ORACLE = os.environ.get("ORACLE", os.path.join(ROOT, "build", "harmony-base"))
HB = ORACLE
