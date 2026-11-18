import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from typing import Any

from langsmith_sizing import cli, compare

PLAN = {
    "rates": {"peak_traces_per_second": 100},
    "watch": [
        {"id": "redis-memory", "metric": "used_memory", "threshold": {"value": 70, "unit": "% of maxmemory", "from": "param:redis.alarm_pct"}},
        {"id": "metastore-flush", "metric": "metastore_batch_flush_duration", "threshold": "observe"},
    ],
}


def results(achieved: float = 104.0, lag: float | None = 12.0, read: float | None = 2.0, missing: int | None = 0, mode: str = "open-loop", **extra: Any) -> dict[str, Any]:
    ok = lambda seen, target: None if seen is None else seen <= target  # noqa: E731
    return {
        "write": {"mode": mode, "target_traces_per_second": 100, "achieved_traces_per_second": achieved},
        "targets": {
            "stored_within_seconds_p99": {"target_seconds": 30, "observed": "lag_p99", "observed_seconds": lag, "passed": ok(lag, 30)},
            "trace_load_seconds_p99": {"target_seconds": 5, "observed": "read_trace_p99", "observed_seconds": read, "passed": ok(read, 5)},
            "no_missing_runs": {"missing": missing, "passed": None if missing is None else missing == 0},
            "send_latency_limit": {"passed": None},
        },
    } | extra


def by_item(verdicts: list[dict[str, Any]]) -> dict[str, str]:
    return {v["item"]: v["verdict"] for v in verdicts}


class Compare(unittest.TestCase):
    def test_a_run_that_met_everything_passes_and_leaves_the_server_unmeasured(self) -> None:
        v = compare.compare(PLAN, results())
        self.assertEqual(
            by_item(v),
            {"write-rate": "pass", "stored_within_seconds_p99": "pass", "trace_load_seconds_p99": "pass", "no_missing_runs": "pass",
             "watch:redis-memory": "not measured", "watch:metastore-flush": "not measured"},
        )
        self.assertFalse(compare.failed(v))
        self.assertIn("not measured by the load test", v[-1]["detail"])

    def test_missing_runs_fail_the_comparison(self) -> None:
        v = compare.compare(PLAN, results(missing=3))
        self.assertEqual(by_item(v)["no_missing_runs"], "fail")
        self.assertIn("3 runs sent and not stored", next(x for x in v if x["item"] == "no_missing_runs")["detail"])
        self.assertTrue(compare.failed(v))

    def test_a_rate_under_the_plans_peak_fails(self) -> None:
        v = compare.compare(PLAN, results(achieved=99.0))
        self.assertEqual(by_item(v)["write-rate"], "fail")
        self.assertTrue(compare.failed(v))

    def test_the_rate_is_judged_after_the_ramp(self) -> None:
        # 100 traces/s held for 10 s after a ramp that averaged half: 75 over the whole run
        held = results(achieved=75.0, settings={"duration_seconds": 10})
        held["write"]["steady_traces_per_second"] = 100.0
        self.assertEqual(by_item(compare.compare(PLAN, held))["write-rate"], "pass")
        # one start short over 10 s is the window's edge (999 of 1,000); two short is not the rate
        edge = results(settings={"duration_seconds": 10})
        edge["write"]["steady_traces_per_second"] = 99.9
        self.assertEqual(by_item(compare.compare(PLAN, edge))["write-rate"], "pass")
        short = results(settings={"duration_seconds": 10})
        short["write"]["steady_traces_per_second"] = 99.8
        self.assertEqual(by_item(compare.compare(PLAN, short))["write-rate"], "fail")

    def test_a_late_lag_fails_and_a_slow_read_fails(self) -> None:
        v = by_item(compare.compare(PLAN, results(lag=31.0, read=5.5)))
        self.assertEqual((v["stored_within_seconds_p99"], v["trace_load_seconds_p99"]), ("fail", "fail"))

    def test_a_target_nothing_measured_is_not_measured_and_does_not_fail(self) -> None:
        v = compare.compare(PLAN, results(read=None))
        self.assertEqual(by_item(v)["trace_load_seconds_p99"], "not measured")
        self.assertFalse(compare.failed(v))

    def test_a_stored_count_that_could_not_be_read_is_not_measured(self) -> None:
        v = compare.compare(PLAN, results(missing=None))
        self.assertEqual(by_item(v)["no_missing_runs"], "not measured")

    def test_a_closed_loop_run_has_no_rate_to_compare(self) -> None:
        v = compare.compare(PLAN, results(mode="closed-loop", achieved=7.0))
        self.assertEqual(by_item(v)["write-rate"], "not measured")
        self.assertFalse(compare.failed(v))

    def test_a_reading_the_results_carry_is_observed_not_judged(self) -> None:
        v = by_item(compare.compare(PLAN, results(metrics={"redis-memory": 41})))
        self.assertEqual((v["watch:redis-memory"], v["watch:metastore-flush"]), ("observed", "not measured"))

    def test_the_summary_counts_each_verdict(self) -> None:
        last = compare.render(compare.compare(PLAN, results(missing=1))).splitlines()[-1]
        self.assertEqual(last, "3 pass, 1 fail, 2 not measured, 0 observed")


class Command(unittest.TestCase):
    def _run(self, res: dict[str, Any]) -> tuple[int, str]:
        d = Path(tempfile.mkdtemp())
        (d / "plan.json").write_text(json.dumps(PLAN))
        (d / "results.json").write_text(json.dumps(res))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = cli.main(["compare", "--plan", str(d / "plan.json"), "--results", str(d / "results.json")])
        return code, out.getvalue()

    def test_exit_zero_when_nothing_failed(self) -> None:
        code, out = self._run(results())
        self.assertEqual(code, 0)
        self.assertIn("PASS         write-rate", out)

    def test_exit_one_on_a_failed_verdict(self) -> None:
        code, out = self._run(results(missing=2))
        self.assertEqual(code, 1)
        self.assertIn("FAIL         no_missing_runs", out)

    def test_an_unreadable_file_is_an_error(self) -> None:
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(cli.main(["compare", "--plan", "/nonexistent.json", "--results", "/nonexistent.json"]), 1)
        self.assertIn("cannot read", err.getvalue())


if __name__ == "__main__":
    unittest.main()
