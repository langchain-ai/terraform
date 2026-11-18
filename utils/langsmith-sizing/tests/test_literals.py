"""The model's rule: a number is a parameter, a citation, the chart or an input, never a literal in code.

Every module under src/ is scanned. What may stay is identity (0, 1, one half) and the unit
constants of units.py, the one file where a conversion is spelled out; each is imported by name.
A hidden cap such as `min(1000, pods)` is a literal like any other and fails here. A number that
is plumbing and not sizing (a timeout, a JSON indent, how many characters of a quote to show) is
listed below with the reason, per file and value, so a new one cannot ride in behind it.
"""

import ast
import unittest
from pathlib import Path

SRC = Path(__file__).resolve().parent.parent / "src" / "langsmith_sizing"
IDENTITY = {0, 1, 0.5}
UNITS = SRC / "units.py"
PLUMBING = {
    ("chart.py", 300): "seconds helm may take before the call is abandoned",
    ("chart.py", 500): "characters of helm's stderr shown in an error",
    ("citations.py", 30): "seconds a docs fetch may take",
    ("citations.py", 12): "characters of a commit shown in a problem line",
    ("citations.py", 90): "characters of a quote shown in a problem line",
    ("params.py", 3): "chart settings named in a problem line",
    ("cli.py", 2): "JSON indent of printed output",
    ("wizard.py", 2): "JSON indent of the files the wizard writes",
    ("docs_gen.py", 60): "characters past which a parameter's value is a pointer to params.yaml in the docs table",
    ("docs_gen.py", 2): "a regex group of the generated-block marker",
    ("docs_gen.py", 4): "a regex group of the generated-block marker",
    ("figures.py", 120): "seconds Chrome may take to draw a figure",
    ("figures.py", 7): "characters of a commit shown in a figure",
    ("figures.py", 2): "JSON indent of rendered.json",
    ("figures.py", 250): "TWK Lausanne's display weight, the brand's",
    ("figures.py", 600): "TWK Lausanne's emphasis weight, the brand's",
    ("figures.py", 400): "Aeonik Mono's regular weight, the brand's",
    ("figures.py", 500): "Aeonik Mono's medium weight, the brand's",
}


def modules() -> list[Path]:
    return sorted(SRC.rglob("*.py"))


def numbers(source: str) -> list[tuple[int, float]]:
    """Every numeric literal in the source, as (line, value)."""
    return [
        (n.lineno, n.value)
        for n in ast.walk(ast.parse(source))
        if isinstance(n, ast.Constant) and isinstance(n.value, (int, float)) and not isinstance(n.value, bool)
    ]


def stray(path: Path, source: str) -> list[str]:
    return [
        f"{path.name}:{line}: {value}"
        for line, value in numbers(source)
        if value not in IDENTITY and (path.name, value) not in PLUMBING
    ]


class NoLiterals(unittest.TestCase):
    def test_the_scan_covers_the_whole_package(self) -> None:
        names = {p.relative_to(SRC).as_posix() for p in modules()}
        self.assertGreaterEqual(len(names), 20)
        for must in ("plan.py", "values.py", "presets.py", "chart.py", "deploy.py", "wizard.py", "profile_report.py", "cli.py", "model/scale.py", "model/watch.py", "model/services.py", "units.py"):
            self.assertIn(must, names)

    def test_every_listed_exception_still_exists(self) -> None:
        for (name, value), reason in PLUMBING.items():
            self.assertTrue(reason)
            self.assertIn(value, [v for _, v in numbers((SRC / name).read_text())], f"{name} no longer has {value}: remove the exception")

    def test_no_number_in_the_package_but_the_unit_constants(self) -> None:
        found = [s for p in modules() if p != UNITS for s in stray(p, p.read_text())]
        self.assertEqual(found, [])

    def test_the_unit_file_only_defines_named_constants(self) -> None:
        tree = ast.parse(UNITS.read_text())
        for node in tree.body:
            if isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant):
                continue  # the docstring
            self.assertIsInstance(node, ast.Assign, ast.dump(node))
            assert isinstance(node, ast.Assign)
            (target,) = node.targets
            self.assertTrue(isinstance(target, ast.Name) and target.id.isupper(), ast.dump(target))

    def test_an_injected_cap_is_caught(self) -> None:
        for cap in ("min(100, ceil(x))", "min(1000, pods)", "max(2, n)", "x * 30", "pods if pods < 1e9 else 1e12"):
            self.assertTrue(stray(Path("model/services.py"), f"y = {cap}"), cap)

    def test_a_cap_in_a_real_model_source_is_caught(self) -> None:
        source = (SRC / "model" / "services.py").read_text()
        capped = source.replace("return ceil(peak_runs_per_second / KILO * pods_per_1k)", "return min(100, ceil(peak_runs_per_second / KILO * pods_per_1k))")
        self.assertNotEqual(source, capped)
        self.assertEqual(stray(SRC / "model" / "services.py", source), [])
        self.assertEqual(len(stray(SRC / "model" / "services.py", capped)), 1)

    def test_identity_and_a_named_unit_pass(self) -> None:
        self.assertEqual(stray(Path("x.py"), "y = a * 0.5 + 1 - 0\nz = b / KILO"), [])


if __name__ == "__main__":
    unittest.main()
