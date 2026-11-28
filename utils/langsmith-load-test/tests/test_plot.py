"""The page draws every signal the run read, says which it did not, and marks the plan's alarm level."""

import json
import tempfile
import unittest
from pathlib import Path

from fake_cluster import STEP_SECONDS, samples
from loadtest import cluster, plot


class PlotTest(unittest.TestCase):
    def setUp(self) -> None:
        self.samples = samples()
        _, section = cluster.summarize(self.samples, (1_000.0 + STEP_SECONDS, 1_000.0 + 6 * STEP_SECONDS), 1000.0)
        self.results = {"test_id": "t", "cluster": section}

    def test_every_panel_read_is_drawn_and_one_not_read_says_so(self) -> None:
        page = plot.render(self.results, self.samples)
        self.assertEqual(page.count("<polyline"), 1 + 2 + 2 + 1 + 1 + 1 + 1 + 3)  # oldest task, the two queues, pending jobs both ways, l0, admission, Redis, replicas, three workloads
        self.assertEqual(page.count("Not read in this run."), 0)
        self.assertIn('class=window', page)
        unread = plot.render(self.results, [s | {"redis": {}} for s in self.samples])
        self.assertEqual(unread.count("Not read in this run."), 1)

    def test_the_plans_alarm_level_is_a_line(self) -> None:
        plan = {"watch": [{"id": "redis-memory", "threshold": {"value": 70, "unit": "%"}}, {"id": "feedback-backlog", "threshold": "observe"}]}
        self.assertIn("alarm 70", plot.render(self.results, self.samples, plan))

    def test_the_command_writes_the_page_beside_the_results(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            results = Path(d) / "run.json"
            results.write_text(json.dumps(self.results))
            results.with_suffix(".metrics.jsonl").write_text("".join(json.dumps(s) + "\n" for s in self.samples))
            self.assertEqual(plot.main([str(results)]), 0)
            self.assertTrue((Path(d) / "run.html").read_text().startswith("<!doctype html>"))


if __name__ == "__main__":
    unittest.main()
