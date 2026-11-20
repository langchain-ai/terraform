"""The collector reads what the install did through kubectl alone, and reads a missing value as unknown."""

import unittest

from fake_cluster import NS, RELEASE, STEP_SECONDS, FakeCluster, samples
from loadtest import cluster

WINDOW = (1_000.0 + STEP_SECONDS, 1_000.0 + 6 * STEP_SECONDS)


class ParseTest(unittest.TestCase):
    def test_a_family_brings_its_sum_count_and_total_and_nothing_else(self) -> None:
        text = 'a_sum 1\na_count{x="y"} 2\na_total 3\na_bucket{le="1"} 4\nb 5\n# HELP a\nc 6'
        self.assertEqual(cluster.parse_prometheus(text, ["a", "b"]), [("a_sum", {}, 1.0), ("a_count", {"x": "y"}, 2.0), ("a_total", {}, 3.0), ("b", {}, 5.0)])

    def test_pods_sum_except_the_oldest_pending_job_which_is_the_earliest(self) -> None:
        merged = cluster.merge_smithdb([[("compaction_queue_job_count", {}, 2.0), (cluster.OLDEST, {}, 50.0)], [("compaction_queue_job_count", {}, 3.0), (cluster.OLDEST, {}, 40.0)]])
        self.assertEqual(merged, {"compaction_queue_job_count": 5.0, cluster.OLDEST: 40.0})


class SampleTest(unittest.TestCase):
    def test_one_sample_reads_every_source(self) -> None:
        s = samples(2)[1]
        self.assertEqual(s["queues"]["ingestion_queue.pending"], 40)
        self.assertEqual(s["queues"]["compaction.pending"], 4)
        self.assertEqual(s["redis"]["maxmemory"], 100 * 2**20)
        self.assertEqual(s["hpa"]["ingest-queue"], [2, 4])
        self.assertEqual(s["replicas"]["ingest-queue"], 1)
        self.assertIn("compaction_jobs_executed_total{status=success,job_kind=runs}", s["smithdb"])
        self.assertEqual(s["queues"]["oldest_task_seconds"], 2)
        self.assertEqual((s["redis"]["connected_clients"], s["postgres"]["max_connections"]), (41, 100))
        self.assertNotIn("unrelated_family", s["smithdb"])
        self.assertEqual({e["workload"] for e in s["cpu"].values()}, {"ingest-queue", "platform-backend", "smithdb-ingestion"})
        self.assertEqual(s["unread"], [])

    def test_a_failed_read_is_named_and_left_out_never_zero(self) -> None:
        s = samples(2, unreadable=("platform-backend:1984", "cadvisor", "redis-cli", "psql"))[1]
        self.assertNotIn("ingestion_queue.pending", s["queues"])
        self.assertEqual(s["cpu"], {})
        self.assertEqual(s["redis"], {})
        self.assertNotIn("oldest_task_seconds", s["queues"])
        self.assertEqual(s["postgres"], {})
        self.assertEqual(sorted(s["unread"]), ["cAdvisor on 1 of 1 nodes", "platform-backend queues", "postgres connections", "redis INFO"])
        _, section = cluster.summarize(samples(7, unreadable=("cadvisor",)), WINDOW, 100.0)
        self.assertEqual(section["coefficients"], {})


class SummaryTest(unittest.TestCase):
    def setUp(self) -> None:
        self.metrics, self.section = cluster.summarize(samples(), WINDOW, 1000.0)

    def test_cores_used_and_runs_per_core_come_from_cpu_seconds_over_the_window(self) -> None:
        c = self.section["coefficients"]
        self.assertAlmostEqual(c["ingest-queue"]["cores_used"], 2.0)
        self.assertAlmostEqual(c["ingest-queue"]["runs_per_core"], 500.0)
        self.assertAlmostEqual(c["platform-backend"]["runs_per_core"], 1000.0)
        self.assertAlmostEqual(self.section["smithdb_rows_flushed_per_second"], 1000.0)

    def test_a_backlog_that_drains_by_the_window_end_kept_up(self) -> None:
        self.assertEqual(self.section["kept_up"], {"ingestion_queue": True, "compaction": True})
        climbing = [s | {"queues": {"ingestion_queue.pending": float(i * 10)}} for i, s in enumerate(samples())]
        _, section = cluster.summarize(climbing, WINDOW, 1000.0)
        self.assertFalse(section["kept_up"]["ingestion_queue"])

    def test_every_watch_item_is_keyed_as_the_plan_names_it(self) -> None:
        m = self.metrics
        self.assertEqual(m["run-backlog-at-ceiling"]["peak"], 80)
        self.assertEqual(m["run-backlog-at-ceiling"]["peak_per_pod"], 80)
        self.assertAlmostEqual(m["redis-memory"]["peak"], 56.0)
        self.assertEqual(m["redis-evictions"]["during_run"], 0)
        self.assertEqual(m["autoscaler-at-ceiling:ingest-queue"]["max"], 4)
        self.assertGreater(m["autoscaler-at-ceiling:ingest-queue"]["at_ceiling_share"], 0)
        self.assertEqual(m["oom-killed"]["during_run"], 1)
        self.assertAlmostEqual(m["object-store-latency"]["mean"], 0.02)
        self.assertAlmostEqual(m["go-cpu-throttling"]["share"], 0.1)
        self.assertEqual(m["compaction-oldest-pending"]["peak"], 30)
        self.assertEqual(m["compaction-completions"]["completed_in_window"], {"compaction_jobs_executed_total{status=success,job_kind=runs}": 25})
        self.assertEqual(m["oldest-queued-task"]["peak"], 12)
        self.assertEqual(m["redis-clients"]["peak"], 46)
        self.assertEqual((m["postgres-connections"]["peak"], m["postgres-connections"]["max_connections"]), (18, 100))
        self.assertNotIn("metastore-flush", m)

    def test_pending_jobs_and_l0_segments_are_read_apart_from_in_flight_jobs_and_l1(self) -> None:
        # In flight: 7 jobs, and 5,000 l1 entries waiting for their scheduled flush: neither is a backlog.
        self.assertEqual(self.metrics["compaction-jobs"]["peak"], 2)
        self.assertEqual(self.metrics["pending-segments"]["peak"], 240)
        unlabelled = [s | {"smithdb": {"compaction_queue_job_count": 9.0}} for s in samples()]
        metrics, _ = cluster.summarize(unlabelled, WINDOW, 1000.0)
        self.assertEqual(metrics["compaction-jobs"]["peak"], 9)  # an older SmithDB without the label

    def test_runs_skipped_as_expired_are_counted_from_the_logs_when_sampling_stops(self) -> None:
        fake = FakeCluster()
        collector = cluster.Collector(fake, NS, RELEASE, STEP_SECONDS, clock=lambda: fake.t)
        collector.samples = [collector.sample()]
        fake.step()
        samples_ = collector.stop()
        self.assertEqual(samples_[-1]["expired_runs"], 2)
        logs = next(c for c in fake.calls if c[0] == "logs")
        self.assertIn("--since=30s", logs)
        self.assertIn("--tail=-1", logs)
        metrics, _ = cluster.summarize(samples_, WINDOW, 1000.0)
        self.assertEqual(metrics["expired-runs"], {"during_run": 2, "unit": "runs skipped as expired"})


if __name__ == "__main__":
    unittest.main()
