#!/usr/bin/env python3
"""Shared test-harness configuration (post bootstrap-retirement).

Mirrors tests/env.sh:

    HARMONY = compiler under test (the canonical self-hosted compiler)
    HC      = compiler used by the v1/differential suites (same binary)
    HB      = backwards-compatible alias for HARMONY

The legacy ORACLE and the lane switches were retired with the bootstrap
toolchain; their frozen forms live on the `legacy/bootstrap` branch.
"""
import os

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
HARMONY = os.environ.get("HARMONY", os.path.join(ROOT, "build", "harmony"))
HC = os.environ.get("HC", os.path.join(ROOT, "build", "harmony"))
HB = HARMONY
