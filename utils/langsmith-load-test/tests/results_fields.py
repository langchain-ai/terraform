"""The documents docs/results-fields.md is generated from: real reports from `runner.build_report`.

Run as `python tests/results_fields.py` (`make reference` in langsmith-sizing does) to rewrite the file.
"""

from __future__ import annotations

import sys
from pathlib import Path

from loadtest import fields, runner
from loadtest.profile import from_document
from loadtest.reads import ClassStats, Reader
from profiles import document
from test_results import outcome

DOC = Path(__file__).resolve().parent.parent / "docs" / "results-fields.md"


def reports() -> list[dict]:
    """A clean open-loop run, and a run whose counts could not be read, with errors and a latency limit,
    so every field that is sometimes null appears with and without a value."""
    profile = from_document(document())
    clean = runner.build_report(outcome(150, 150), runner.LoadSettings(), profile, "p", True, 0, None)
    broken = outcome(150, None)
    broken.write.mode = "closed-loop"
    broken.write.first_error = "run error"
    reader = Reader.__new__(Reader)
    reader.stats = {"read_trace": ClassStats("query", [], errors=1, first_error="ReadError: nope")}
    broken.reader = reader
    failed = runner.build_report(broken, runner.LoadSettings(latency_limit_seconds=1.0), profile, "p", False, 1, None)
    return [clean, failed]


def render() -> str:
    return fields.render(fields.paths(reports()))


if __name__ == "__main__":
    DOC.write_text(render())
    sys.stdout.write(f"wrote {DOC}\n")
