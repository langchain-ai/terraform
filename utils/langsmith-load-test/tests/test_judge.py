"""verify, judge and step decide from a results file and the install's readings beside it."""

import unittest
from typing import Any

from loadtest import judge


def results(missing: int = 0, refused: int = 0, kept: bool | None = True, passed: bool = True) -> dict[str, Any]:
    return {
        "write": {"runs_sent": 100, "run_errors": refused, "first_error": None},
        "errors": {"upload": 0},
        "stored": {"missing_runs": missing, "runs_stored": 100 - missing, "runs_sent": 100, "error": None},
        "lag": {"never_readable": 0, "p95_seconds": 2.0},
        "cluster": {"kept_up": {"ingestion_queue": kept}},
        "targets": {
            "stored_within_seconds_p99": {"observed": "lag_p99", "observed_seconds": 3.0, "target_seconds": 60, "passed": True},
            "trace_load_seconds_p99": {"observed": "read_trace_p99", "observed_seconds": None, "target_seconds": 5, "passed": None},
            "no_missing_runs": {"missing": missing, "passed": missing == 0},
        },
        "metrics": {"redis-memory": {"peak": 95.0, "end": 60.0, "unit": "% of maxmemory", "samples": 5}},
        "passed": passed,
    }


def sample(pending: float, rows: float | None) -> dict[str, Any]:
    smithdb = {"query_admission_queue_length": 0.0, **({} if rows is None else {"ingest_flush_rows_sum{status=success,level=L0}": rows})}
    return {"queues": {"ingestion_queue.pending": pending}, "smithdb": smithdb, "replicas": {"smithdb": 1}, "unread": []}


class HopsTest(unittest.TestCase):
    def verdicts(self, r: dict[str, Any], series: list[dict[str, Any]]) -> dict[str, bool | None]:
        return {hop: ok for hop, _, ok, _ in judge.hops(r, series)}

    def test_every_hop_passes_when_runs_flow(self) -> None:
        self.assertEqual(set(self.verdicts(results(), [sample(0, 10), sample(0, 110)]).values()), {True})

    def test_runs_left_in_redis_stop_at_drained(self) -> None:
        v = self.verdicts(results(missing=40), [sample(0, 10), sample(40, 70)])
        self.assertEqual((v["accepted"], v["drained"], v["flushed"], v["readable"]), (True, False, True, False))

    def test_an_unread_install_is_not_read_never_ok(self) -> None:
        v = self.verdicts(results(), [])
        self.assertEqual((v["drained"], v["flushed"]), (None, None))

    def test_rows_flushed_before_the_first_flush_series_count_from_zero(self) -> None:
        v = self.verdicts(results(), [sample(0, None), sample(0, 100)])
        self.assertTrue(v["flushed"])

    def test_an_unread_smithdb_is_not_zero_rows(self) -> None:
        unread = {**sample(0, None), "unread": ["smithdb metrics from 1 of 1 pods"]}
        self.assertIsNone(self.verdicts(results(), [unread, sample(0, 100)])["flushed"])

    def test_refused_runs_stop_at_accepted(self) -> None:
        self.assertFalse(self.verdicts(results(refused=3), [sample(0, 1), sample(0, 2)])["accepted"])


class HeldTest(unittest.TestCase):
    def test_a_climbing_backlog_did_not_hold_even_with_every_target_met(self) -> None:
        self.assertFalse(judge.held(results(kept=False)))
        self.assertTrue(judge.held(results(kept=None)))
        self.assertFalse(judge.held(results(passed=False)))

    def test_without_a_plan_params_levels_judge_and_a_crossing_is_observed_not_failed(self) -> None:
        verdicts = judge.signals(results(), None, [sample(0, 1)])
        redis = next(v for v in verdicts if v["item"] == "watch:redis-memory")
        self.assertEqual(redis["verdict"], "observed")
        self.assertIn("ABOVE the alarm level", redis["detail"])
        self.assertEqual([v["item"] for v in judge.crossed(verdicts)], ["watch:redis-memory"])

    def test_the_watch_list_follows_the_topology_read(self) -> None:
        unified = {i["id"] for i in judge.watch_items(None, "unified")}
        self.assertNotIn("compaction-jobs", unified)
        self.assertIn("compaction-jobs", {i["id"] for i in judge.watch_items(None, "cluster")})


if __name__ == "__main__":
    unittest.main()
