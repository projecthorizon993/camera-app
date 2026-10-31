#!/usr/bin/env python3
"""ghidra_find_tables.py -- SKELETON for locating native LUT/lens tables in .so.

Context
-------
Some colour-look and lens-profile parameters never appear as assets: they are
embedded as float/half-float arrays inside native libraries that the Java side
loads via JNI. The dumps contain several such libraries (see
``docs/extraction-notes.md``); identifying the exact arrays requires static
analysis of the binaries, which is OUT OF SCOPE for task 22a and deliberately
not attempted here.

This file is a *stub* that a follow-up task can run under Ghidra's headless
analyzer (Jython, i.e. Python 2 syntax rules apply there). It is written to be
syntactically valid Python 3 so the repository's `python -m compileall scripts`
gate stays green; the Ghidra imports are guarded so importing/compiling it
outside Ghidra is harmless.

Intended usage (follow-up)
--------------------------
    analyzeHeadless <proj> <name> -import libfoo.so \
        -postScript ghidra_find_tables.py --out tables.json --size 33

Strategy (skeleton, not implemented)
------------------------------------
1. For each requested N in {8, 16, 17, 32, 33, 64, 65}, compute the byte widths
   of an N^3 * 3 float32 (and float16) table.
2. Scan .rodata/.data blocks for a contiguous run whose declared length equals
   one of those widths.
3. Validate numeric plausibility (values within [-1, 1] or [0, 1] for colour;
   monotone-ish / bounded for lens tables) and record the symbol/offset.
4. Emit {library, section, offset, candidate_size, dtype, value_range, conf}.

Nothing here is executed by CI; it exists so the follow-up has a concrete entry
point and a shared vocabulary with the Python tooling.
"""

from __future__ import annotations

import sys
from typing import Any

# Candidate LUT sizes and the float widths we would probe for (bytes/pixel).
CANDIDATE_SIZES = (8, 16, 17, 32, 33, 64, 65)
FLOAT_WIDTHS = {"float32": 4, "float16": 2}


def candidate_byte_lengths() -> dict[int, list[tuple[str, int]]]:
    """Map N -> [(dtype, expected_bytes), ...] for an N^3 RGB table."""
    table: dict[int, list[tuple[str, int]]] = {}
    for n in CANDIDATE_SIZES:
        table[n] = [(dtype, n ** 3 * 3 * width)
                    for dtype, width in FLOAT_WIDTHS.items()]
    return table


def find_float_tables(program: Any, sizes: list[int] | None = None) -> list[dict]:
    """STUB: return [] until implemented against a real Ghidra program.

    A full implementation would iterate memory blocks and call
    ``program.getListing()`` / ``getMemory()`` to locate runs matching
    ``candidate_byte_lengths()``.
    """
    _ = program
    _ = sizes or list(CANDIDATE_SIZES)
    return []


def run() -> int:
    # Under Ghidra, ``currentProgram`` is injected into the script namespace.
    program = globals().get("currentProgram")  # type: ignore[name-defined]
    if program is None:
        print(
            "ghidra_find_tables.py is a Ghidra headless stub; run it via "
            "analyzeHeadless -postScript, or import find_float_tables() from "
            "your own driver.",
            file=sys.stderr,
        )
        return 0
    results = find_float_tables(program)
    for row in results:
        print(row)
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
