# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

"""Each function's cyclomatic complexity (under 15) and CRAP (under 30), from radon and coverage.

    python3 quality.py radon.json coverage.json

CRAP = cc^2 x (1 - coverage)^3 + cc: complex code with no test fails even where the total coverage
looks fine. Three choices each fixed a wrong reading: the def line is left out of a function's span
(it runs at import, and read an untested function as partly covered); only function and method entries
are scored (radon also lists methods under their class); a file no test imported is 0% covered, and
radon finding no functions fails (an empty list is a wrong path, not a clean tree). Standard library only.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Optional, Set, Tuple

MAX_COMPLEXITY = 15
MAX_CRAP = 30.0

Lines = Tuple[Set[int], Set[int]]


def coverage_of(block: dict, seen: Optional[Lines]) -> float:
    if seen is None:
        return 0.0
    first, last = block["lineno"], block["endline"]
    span = range(first + 1, last + 1) if last > first else range(first, first + 1)
    run = sum(1 for n in span if n in seen[0])
    total = run + sum(1 for n in span if n in seen[1])
    return run / total if total else 0.0


def scores(radon: dict, files: dict) -> list:
    lines = {Path(p).resolve(): (set(f["executed_lines"]), set(f["missing_lines"])) for p, f in files.items()}
    rows = []
    for path, blocks in radon.items():
        seen = lines.get(Path(path).resolve())
        for b in (b for b in blocks if b["type"] in ("function", "method")):
            cc, cov = b["complexity"], coverage_of(b, seen)
            name = f"{b['classname']}.{b['name']}" if b.get("classname") else b["name"]
            rows.append((cc * cc * (1 - cov) ** 3 + cc, f"{Path(path).name}:{b['lineno']} {name}", cc, cov))
    return sorted(rows, reverse=True)


def main(argv: Any = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    rows = scores(json.loads(Path(args[0]).read_text()), json.loads(Path(args[1]).read_text())["files"])
    if not rows:
        print("radon found no functions: check the path it was given")
        return 1
    bad = [r for r in rows if r[0] >= MAX_CRAP or r[2] >= MAX_COMPLEXITY]
    for crap, at, cc, cov in bad or rows[:1]:
        print(f"{'FAIL' if (crap, at, cc, cov) in bad else 'worst'} {at}: cc {cc}, coverage {cov:.0%}, crap {crap:.1f}")
    print(f"{len(rows)} functions: cc < {MAX_COMPLEXITY} and crap < {MAX_CRAP:g} {'held' if not bad else f'broken by {len(bad)}'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
