"""The quality gate scores what radon and coverage report, and never passes an empty or untested tree."""

import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

import quality


def block(name: str, cc: int, first: int, last: int, kind: str = "function") -> dict:
    return {"type": kind, "name": name, "complexity": cc, "lineno": first, "endline": last, "classname": ""}


class Scores(unittest.TestCase):
    def test_the_def_line_does_not_count_as_covered(self) -> None:
        self.assertEqual(quality.coverage_of(block("f", 1, 10, 12), ({10}, {11, 12})), 0.0)
        self.assertEqual(quality.coverage_of(block("f", 1, 10, 12), ({11, 12}, set())), 1.0)

    def test_a_file_no_test_imported_is_zero_not_skipped(self) -> None:
        self.assertEqual(quality.coverage_of(block("f", 1, 1, 3), None), 0.0)

    def test_crap_is_cc_when_covered_and_grows_when_not(self) -> None:
        rows = quality.scores({"a.py": [block("f", 5, 1, 3), block("C", 9, 4, 9, "class")]}, {"a.py": {"executed_lines": [2, 3], "missing_lines": []}})
        self.assertEqual([(round(r[0]), r[2]) for r in rows], [(5, 5)])
        rows = quality.scores({"a.py": [block("f", 5, 1, 3)]}, {})
        self.assertEqual(round(rows[0][0]), 30)


class Gate(unittest.TestCase):
    def run_gate(self, radon: dict, files: dict) -> tuple[int, str]:
        with tempfile.TemporaryDirectory() as d:
            Path(d, "r.json").write_text(json.dumps(radon))
            Path(d, "c.json").write_text(json.dumps({"files": files}))
            out = io.StringIO()
            with redirect_stdout(out):
                code = quality.main([f"{d}/r.json", f"{d}/c.json"])
        return code, out.getvalue()

    def test_an_empty_tree_fails(self) -> None:
        self.assertEqual(self.run_gate({}, {})[0], 1)

    def test_complexity_at_the_bar_fails_even_when_covered(self) -> None:
        code, text = self.run_gate({"a.py": [block("f", 15, 1, 3)]}, {"a.py": {"executed_lines": [2, 3], "missing_lines": []}})
        self.assertEqual(code, 1)
        self.assertIn("FAIL a.py:1 f", text)

    def test_a_covered_simple_tree_passes(self) -> None:
        code, text = self.run_gate({"a.py": [block("f", 3, 1, 3)]}, {"a.py": {"executed_lines": [2, 3], "missing_lines": []}})
        self.assertEqual(code, 0)
        self.assertIn("held", text)


if __name__ == "__main__":
    unittest.main()
