import datetime
import unittest

from loadtest import results, runner
from loadtest.lag import LagTracker
from loadtest.profile import from_document
from loadtest.reads import ClassStats, Reader
from loadtest.verify import Stored
from profiles import document as profile

TARGETS = {"stored_within_seconds": 30.0, "trace_load_seconds": 5.0}


def lag_summary(p99: float | None, sampled: int = 100, never: int = 0) -> dict:
    return {"sampled": sampled, "never_readable": never, "p99_seconds": p99}


class VerdictTest(unittest.TestCase):
    def test_pass_fail_and_not_measured(self) -> None:
        verdicts = results.target_verdicts(TARGETS, lag_summary(12.0), {"read_trace": {"p99_seconds": 4.0}}, 0)
        self.assertTrue(verdicts["stored_within_seconds_p99"]["passed"])
        self.assertTrue(verdicts["trace_load_seconds_p99"]["passed"])
        self.assertTrue(verdicts["no_missing_runs"]["passed"])
        verdicts = results.target_verdicts(TARGETS, lag_summary(31.0), {"read_trace": {"p99_seconds": 5.1}}, 3)
        self.assertFalse(verdicts["stored_within_seconds_p99"]["passed"])
        self.assertFalse(verdicts["trace_load_seconds_p99"]["passed"])
        self.assertFalse(verdicts["no_missing_runs"]["passed"])
        verdicts = results.target_verdicts(TARGETS, lag_summary(None, sampled=0), {}, None)
        self.assertIsNone(verdicts["stored_within_seconds_p99"]["passed"])
        self.assertIsNone(verdicts["trace_load_seconds_p99"]["passed"])
        self.assertIsNone(verdicts["no_missing_runs"]["passed"])

    def test_never_readable_runs_fail_the_lag_target(self) -> None:
        verdicts = results.target_verdicts(TARGETS, lag_summary(10.0, sampled=100, never=2), {}, 0)
        self.assertFalse(verdicts["stored_within_seconds_p99"]["passed"])
        verdicts = results.target_verdicts(TARGETS, lag_summary(10.0, sampled=100, never=1), {}, 0)
        self.assertTrue(verdicts["stored_within_seconds_p99"]["passed"])

    def test_never_readable_runs_fail_even_when_no_run_was_readable(self) -> None:
        # No lag was measured (p99 None) but every sampled run is missing: that is a failure, not "not measured".
        verdicts = results.target_verdicts(TARGETS, lag_summary(None, sampled=10, never=10), {}, 0)
        self.assertIs(verdicts["stored_within_seconds_p99"]["passed"], False)


def outcome(sent_runs: int, stored_runs: int | None, never: int = 0, lag_values: list[float] | None = None) -> runner.LoadOutcome:
    now = datetime.datetime.now(datetime.UTC)
    write = results.WriteCounts(
        mode="open-loop", target_traces_per_second=2.0, duration_seconds=10.0, traces_started=20, traces_sent=20,
        runs_sent=sent_runs, dropped_starts=1, send_latencies_seconds=[0.01] * 20, schedule_lags_seconds=[0.001] * 20,
        feedback_sent=10,
    )
    lag = LagTracker(30)
    lag.lags_seconds = lag_values if lag_values is not None else [1.0, 2.0, 3.0]
    lag.never_readable = never
    stats = {"read_trace": ClassStats("query", [0.2, 0.4]), "list_traces": ClassStats("query", [0.1])}
    reader = Reader.__new__(Reader)
    reader.stats = stats
    stored = Stored(traces=20, runs=stored_runs) if stored_runs is not None else Stored(error="RuntimeError: nope")
    return runner.LoadOutcome("tid", now, now, write, reader, 0, [], lag, 0, 3 + never, stored)


class ReportTest(unittest.TestCase):
    def build(self, loaded: runner.LoadOutcome) -> dict:
        return runner.build_report(loaded, runner.LoadSettings(), from_document(profile()), "p", True, 0, None)

    def test_a_clean_run_passes_with_all_sections(self) -> None:
        report = self.build(outcome(150, 150))
        self.assertEqual(report["schema"], "langsmith-load-results/1")
        self.assertTrue(report["passed"])
        self.assertEqual(report["stored"]["missing_runs"], 0)
        self.assertEqual(report["write"]["achieved_traces_per_second"], 2.0)
        self.assertEqual(report["reads"]["classes"]["read_trace"]["count"], 2)
        self.assertEqual(report["lag"]["p99_seconds"], 3.0)
        self.assertEqual(report["write"]["send_latency_seconds"]["p95"], 0.01)
        self.assertEqual(report["profile"]["schema"], "langsmith-load-profile/1")
        for key in ("started_at", "ended_at", "feedback", "targets", "errors", "settings"):
            self.assertIn(key, report)

    def test_missing_runs_fail_the_run(self) -> None:
        report = self.build(outcome(150, 147))
        self.assertEqual(report["stored"]["missing_runs"], 3)
        self.assertFalse(report["passed"])

    def test_a_stored_count_with_an_error_is_unknown_and_fails(self) -> None:
        # How the error arises (settle's except path) is tested in test_verify and test_runner.
        report = self.build(outcome(150, None))
        self.assertIsNone(report["stored"]["missing_runs"])
        self.assertEqual(report["stored"]["error"], "RuntimeError: nope")
        self.assertFalse(report["passed"])

    def test_dropped_starts_and_schedule_lags_reach_the_report(self) -> None:
        loaded = outcome(150, 150)
        loaded.write.schedule_lags_seconds = [0.001, 0.002, 0.5]
        report = self.build(loaded)
        self.assertEqual(report["write"]["dropped_starts"], 1)
        self.assertEqual(report["write"]["schedule_lag_seconds"]["max"], 0.5)
        self.assertEqual(report["write"]["schedule_lag_seconds"]["p50"], 0.002)

    def test_lag_over_target_fails(self) -> None:
        report = self.build(outcome(150, 150, lag_values=[1.0, 45.0]))
        self.assertFalse(report["targets"]["stored_within_seconds_p99"]["passed"])
        self.assertFalse(report["passed"])


if __name__ == "__main__":
    unittest.main()
