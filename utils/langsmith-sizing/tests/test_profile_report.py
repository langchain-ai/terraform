import tempfile
import unittest
from pathlib import Path

from langsmith_sizing import profile_report
from tests.helpers import CHART

PLAN = {
    "workloads": {
        "frontend": {"min": 1, "max": 1, "requests": {"cpu": 0.5, "memory_gib": 1.0}},
        "platform-backend": {"min": 1, "max": 1, "requests": {"cpu": 1.0, "memory_gib": 2.0}},
    },
    "scale": {"frontend": {"applied": {"kind": "hpa", "min": 1, "max": 5}}},
}
AWS = """
frontend:
  deployment: {resources: {requests: {cpu: 100m, memory: 256Mi}}}
  autoscaling: {hpa: {enabled: true, minReplicas: 1, maxReplicas: 10}}
platformBackend:
  deployment: {replicas: 1, resources: {requests: {cpu: "1", memory: 2Gi}}}
"""


def _root() -> Path:
    root = Path(tempfile.mkdtemp())
    path = profile_report.values_path(root, "aws", "dev")
    path.parent.mkdir(parents=True)
    path.write_text(AWS)
    return root


class ProfileReport(unittest.TestCase):
    def test_a_profile_table_flags_each_difference_and_counts_them(self) -> None:
        table, differing = profile_report.profile_table("dev", PLAN, _root())
        rows = {r.split(" | ")[0].strip("| "): r for r in table.splitlines()}
        # aws frontend: replicas 1-10 against the plan's 1-5 (max differs), 0.1 CPU against 0.5, 0.25 GiB against 1
        self.assertIn("| 1-10*, 0.1* / 0.25* |", rows["frontend"])
        # aws platform-backend: the same replicas and requests as the plan: nothing flagged
        self.assertIn("| 1-1, 1 / 2 |", rows["platform-backend"])
        self.assertEqual(differing["aws"], 3)
        self.assertIn("no file", rows["frontend"])
        self.assertEqual(differing["gcp"], 0)

    def test_the_report_names_the_counts(self) -> None:
        text = profile_report.report(CHART, {"dev": PLAN}, _root())
        self.assertIn(f"## dev (chart {CHART})", text)
        self.assertIn("aws 3 of 8", text)

    def test_a_missing_figure_is_shown_as_not_set(self) -> None:
        self.assertEqual(profile_report.module_figures({"frontend": {}}, "frontend"), {"min": None, "max": None, "cpu": None, "memory_gib": None})

    def test_a_workload_name_becomes_the_charts_key(self) -> None:
        self.assertEqual([profile_report.values_key(n) for n in ("frontend", "platform-backend", "ingest-queue", "ace-backend")], ["frontend", "platformBackend", "ingestQueue", "aceBackend"])

    def test_nothing_is_written_to_the_modules(self) -> None:
        root = _root()
        before = sorted(p.stat().st_mtime_ns for p in root.rglob("*") if p.is_file())
        profile_report.report(CHART, {"dev": PLAN}, root)
        self.assertEqual(before, sorted(p.stat().st_mtime_ns for p in root.rglob("*") if p.is_file()))


if __name__ == "__main__":
    unittest.main()
