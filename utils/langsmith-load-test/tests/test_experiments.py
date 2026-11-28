"""Experiments compared: step folders found in order, spreads of minutes, and a step described as one row."""

import json
import tempfile
import unittest
from pathlib import Path

from loadtest import experiments


def sample(t: float, pods: float, written: float, l1: float = 0.0) -> dict:
    return {"t": t, "machine": {"pods": {"seconds": pods}, "disks": {"nvme0n1": {"written": written}}},
            "cpu": {"smithdb-0/smithdb": {"workload": "smithdb", "seconds": pods / 2, "memory": 2**30}},
            "smithdb": {experiments.L1: l1}}


def soak(traces: str = "agent") -> dict:
    return {"stored": {"runs_sent": 100, "runs_stored": 100}, "write": {"payload_kib_per_run": 40.0, "payload_shape": {"traces": traces}},
            "lag": {"p50_seconds": 3.0, "p99_seconds": 9.0}, "passed": True,
            "reads": {"classes": {"read_trace": {"p99_seconds": 1.5}}},
            "cluster": {"window": {"from": 0, "to": 600}, "runs_per_second_sent": 5.0,
                        "coefficients": {"smithdb": {"cores_used": 0.5, "memory_peak_mib": 2048}},
                        "disk_bytes_per_run": {"rustfs:/data": 30000, "rustfs:/data/langsmith-blobs": 14000, "rustfs:/data/smithdb": 16000}}}


class ExperimentsTest(unittest.TestCase):
    def test_steps_are_found_in_order_old_and_numbered_folders_alike(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            for size, folders in (("s", ("1-1x", "2-1x", "3-2x", "4-3x", "5-1x-coding", "notes")), ("m", ("2x", "1x"))):
                for f in folders:
                    d = Path(tmp, size, f)
                    d.mkdir(parents=True)
                    (d / "soak.json").write_text(json.dumps(soak()))
                    (d / "soak.metrics.jsonl").write_text(json.dumps(sample(0, 0, 0)) + "\n")
            steps = experiments.load(Path(tmp))
        self.assertEqual([(s.size, s.index, s.multiple) for s in steps],
                         [("s", 1, 1.0), ("s", 2, 1.0), ("s", 3, 2.0), ("s", 4, 3.0), ("s", 5, 1.0), ("m", 1, 1.0), ("m", 2, 2.0)])
        self.assertEqual([s.variant for s in steps if s.size == "s"], ["", "", "", "", "coding"])

    def test_spreads_are_of_minutes_so_a_counter_scraped_late_reads_its_rate(self) -> None:
        # The pods' counter moves every 30 s, not every 15: over minutes it reads its rate, 2 cores.
        samples = [sample(15 * i, 60.0 * (i // 2), 2**20 * 15 * i) for i in range(41)]
        step = experiments.Step("e", "agent", "s", 1, 1.0, soak(), samples)
        cores = experiments.pods_cores(step)
        self.assertTrue(all(abs(c - 2.0) < 0.6 for c in cores), cores)
        self.assertAlmostEqual(experiments.disk_written(step)[0], 1.0)

    def test_a_step_is_one_row_with_the_buckets_apart(self) -> None:
        samples = [sample(15 * i, 30.0 * i, 0, l1=10 * i) for i in range(41)]
        row = experiments.describe(experiments.Step("e", "agent", "s", 2, 1.0, soak(), samples))
        self.assertEqual((row["traces"], row["runs_stored"], row["l1_peak"]), ("agent", 100, 400.0))
        self.assertEqual((row["blobs_bytes_per_run"], row["segments_bytes_per_run"]), (14000, 16000))
        self.assertAlmostEqual(row["pods_cores_mean"], 2.0)
        self.assertAlmostEqual(row["smithdb_memory_gib"], 2.0)

    def test_too_few_minutes_say_nothing(self) -> None:
        self.assertIsNone(experiments.spread([1.0, 2.0]))

    def test_a_size_holds_up_to_the_first_multiple_with_a_failed_step(self) -> None:
        def rows(*verdicts: tuple[float, bool]) -> list[dict]:
            return [{"multiple": k, "passed": ok} for k, ok in verdicts]

        self.assertEqual(experiments.ceiling(rows((1, True), (1, True), (2, False), (3, True))), 1)
        self.assertEqual(experiments.ceiling(rows((1, True), (1, False), (2, True))), 0)  # a repeat that failed fails the multiple
        self.assertEqual(experiments.ceiling(rows((1, True), (2, True), (3, True))), 3)

    def test_a_step_with_a_variant_does_not_move_the_ceiling(self) -> None:
        rows = [{"multiple": 1.0, "passed": True, "variant": ""}, {"multiple": 1.0, "passed": False, "variant": "stall"},
                {"multiple": 2.0, "passed": True, "variant": ""}]
        self.assertEqual(experiments.ceiling(rows), 2.0)

    def test_a_failed_step_says_which_target_it_missed_and_a_refused_read(self) -> None:
        s = {"targets": {"trace_load_seconds_p99": {"passed": False}, "no_missing_runs": {"passed": True}}, "errors": {"reads": 80}}
        self.assertEqual(experiments.missed(s), ["reads slow", "reads refused"])
        self.assertEqual(experiments.missed({"targets": {}, "errors": {"reads": 0}}), [])

    def test_a_step_with_a_variant_is_labelled_by_it_and_is_not_a_repeat(self) -> None:
        same = [{"multiple": 1.0, "step": 1, "variant": ""}, {"multiple": 1.0, "step": 2, "variant": "coding"}, {"multiple": 1.0, "step": 3, "variant": ""}]
        self.assertEqual([experiments.step_label(r, same) for r in same], ["1x", "1x coding", "1x again"])

    def test_a_repeated_multiple_is_labelled_again(self) -> None:
        same = [{"multiple": 1.0, "step": 1}, {"multiple": 1.0, "step": 2}, {"multiple": 2.0, "step": 3}]
        self.assertEqual([experiments.step_label(r, same) for r in same], ["1x", "1x again", "2x"])

    def test_experiments_are_ordered_by_start_and_the_newest_is_drawn_solid(self) -> None:
        rows = [{"experiment": e, "label": e} for e in ("20261126T204323Z", "20261126T010357Z", "20261128T090000Z")]
        self.assertEqual(experiments.runs(rows), ["20261126T010357Z", "20261126T204323Z", "20261128T090000Z"])
        self.assertEqual([experiments.look(rows, e) for e in experiments.runs(rows)], ["dotted", "dashed", "line"])

    def test_an_experiment_is_named_by_its_label_and_each_size_read_against_its_own_plan(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "settings").write_text("SIZES=s\nTRACES=agent\nLABEL=agent traces on the measured plan\nCOMMIT=abc1234\n")
            d = root / "s" / "1-1x"
            d.mkdir(parents=True)
            (d / "soak.json").write_text(json.dumps(soak()))
            (d / "soak.metrics.jsonl").write_text(json.dumps(sample(0, 0, 0)) + "\n")
            (root / "s" / "plan.json").write_text(json.dumps({"pods": {"smithdb": {"lim_mem_mi": 6144}}}))
            step = experiments.load(root)[0]
        self.assertEqual(experiments.settings(root.parent / "none"), {})
        self.assertEqual(step.label, "agent traces on the measured plan")
        self.assertEqual(experiments._smithdb_limit_gib(step.plan), 6.0)

    def test_a_merge_is_the_pile_halving_and_is_counted_over_minutes_of_load(self) -> None:
        # A 10-minute timer fires at most once in a 10-minute step, so gaps within a step would time only
        # the merges row counts forced; minutes of load a merge does not depend on the step's length.
        pile = (0, 40, 80, 120, 10, 50, 90, 5, 8)
        step = experiments.Step("e", "agent", "s", 1, 1.0, soak(), [sample(i * 60.0, 0, 0, v) for i, v in enumerate(pile)])
        self.assertEqual(experiments.merges(step), [240.0, 420.0])
        self.assertEqual(experiments._merge_minutes([step], "e"), (4.0, 2))
        self.assertEqual(experiments._merge_minutes([step], "other"), (float("inf"), 0))

    def test_a_change_is_read_against_the_last_experiment_with_the_same_traces(self) -> None:
        rows = [{"experiment": e, "traces": t} for e, t in (("1", "simple"), ("2", "agent"), ("3", "simple"), ("4", "agent"))]
        self.assertEqual(experiments._before(rows), "2")
        self.assertIsNone(experiments._before(rows[:1]))

    def test_the_plan_changes_are_the_requests_and_redis_that_moved_most(self) -> None:
        before = {"pods": {"smithdb": {"cpu_m": 500, "mem_mi": 3072}, "ingestQueue": {"cpu_m": 300, "mem_mi": 1352}, "grafana": {"cpu_m": 50}},
                  "data": {"redis_maxmemory_mi": 1087}}
        after = {"pods": {"smithdb": {"cpu_m": 500, "mem_mi": 6144}, "ingestQueue": {"cpu_m": 90, "mem_mi": 1352}, "grafana": {"cpu_m": 10}},
                 "data": {"redis_maxmemory_mi": 516}, "smithdb_merge": {"l1_timeout_minutes": 4}}
        self.assertEqual(experiments._plan_changes(before, after),
                         ["ingest-queue CPU 0.30 -> 0.09 cores", "redis maxmemory 1.1 -> 0.5 GiB", "smithdb memory 3.0 -> 6.0 GiB"])
        merged = {**before, "smithdb_merge": {"l1_timeout_minutes": 10}}
        self.assertEqual(experiments._plan_changes(merged, after)[0], "smithdb merge l1_timeout_minutes 10 -> 4")

    def test_the_figures_that_need_a_plan_skip_without_one(self) -> None:
        self.assertIsNone(experiments.requests([], [], {}))
        self.assertIsNone(experiments.machine([], [], {}))


if __name__ == "__main__":
    unittest.main()
