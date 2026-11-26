"""The collector reads what the install did through kubectl alone, and reads a missing value as unknown."""

import time
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

    def test_stores_in_their_own_namespace_labelled_by_name_are_read_there(self) -> None:
        fake = FakeCluster(data_namespace="ls-data")
        s = cluster.Collector(fake, NS, RELEASE, STEP_SECONDS, clock=lambda: fake.t, data_namespace="ls-data").sample()
        self.assertEqual((s["redis"]["maxmemory"], s["postgres"]["max_connections"]), (100 * 2**20, 100))
        execs = [c for c in fake.calls if c[0] == "exec"]
        self.assertEqual({c[2] for c in execs}, {"ls-data"})
        self.assertIn('psql -U "${POSTGRES_USER:-postgres}"', next(c[-1] for c in execs if c[-2] == "-c"))
        self.assertEqual(s["unread"], [])

    def test_a_failed_read_is_named_and_left_out_never_zero(self) -> None:
        s = samples(2, unreadable=("platform-backend:1984", "cadvisor", "redis-cli", "psql"))[1]
        self.assertNotIn("ingestion_queue.pending", s["queues"])
        self.assertEqual(s["cpu"], {})
        self.assertEqual(s["redis"], {})
        self.assertNotIn("oldest_task_seconds", s["queues"])
        self.assertEqual(s["postgres"], {})
        self.assertEqual(sorted(s["unread"]), ["each pod's CPU and memory (the kubelet's cAdvisor on 1 of 1 nodes refused, and no --prometheus)", "platform-backend queues", "postgres connections", "redis INFO"])
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

    def test_a_run_shorter_than_the_interval_still_has_a_first_and_a_last_reading(self) -> None:
        fake = FakeCluster()
        collector = cluster.Collector(fake, NS, RELEASE, 3600, clock=lambda: fake.t)
        collector.start()
        while not collector.samples:
            time.sleep(0.01)
        self.assertEqual(len(collector.stop()), 2)

    def test_cpu_comes_from_a_named_prometheus_without_touching_the_kubelet(self) -> None:
        fake = FakeCluster()
        s = cluster.Collector(fake, NS, RELEASE, STEP_SECONDS, clock=lambda: fake.t, prometheus="obs/prometheus-server:80").sample()
        self.assertEqual({e["workload"] for e in s["cpu"].values()}, {"ingest-queue", "platform-backend", "smithdb-ingestion"})
        self.assertFalse(any("/metrics/cadvisor" in " ".join(c) for c in fake.calls))
        path = next(" ".join(c) for c in fake.calls if "/federate?" in " ".join(c))
        self.assertIn("/api/v1/namespaces/obs/services/prometheus-server:80/proxy/federate?match%5B%5D=", path)
        self.assertEqual(s["unread"], [])

    def test_the_stores_namespace_is_read_with_langsmiths(self) -> None:
        # magus, 2026-11-26: Postgres used 1.7 cores on an idle install and no run showed it.
        fake = FakeCluster(data_namespace="ls-data")
        s = cluster.Collector(fake, NS, RELEASE, STEP_SECONDS, clock=lambda: fake.t, data_namespace="ls-data", prometheus="obs/prometheus-server:80").sample()
        self.assertIn("postgres", {e["workload"] for e in s["cpu"].values()})
        path = next(" ".join(c) for c in fake.calls if "/federate?" in " ".join(c))
        self.assertIn("ls%7Cls-data", path)

    def test_the_machine_is_every_pod_together_and_each_disk_that_moved(self) -> None:
        fake = FakeCluster()
        collector = cluster.Collector(fake, NS, RELEASE, STEP_SECONDS, clock=lambda: fake.t, prometheus="obs/prometheus-server:80")
        taken = []
        for _ in range(4):
            taken.append(collector.sample())
            fake.step()
        m = cluster.machine(taken, taken)
        assert m is not None
        # Hand-written from the fake: 8 cores, 100 of 1,000 periods throttled, 4 MiB/s written, busy 0.25.
        self.assertAlmostEqual(m["pods_cores"], 8.0)
        self.assertAlmostEqual(m["pods_throttled_share"], 0.1)
        self.assertEqual(list(m["disks"]), ["nvme0n1"])  # the loop device is not a disk
        self.assertAlmostEqual(m["disks"]["nvme0n1"]["written_mib_per_second"], 4.0)
        self.assertAlmostEqual(m["disks"]["nvme0n1"]["busy_share"], 0.25)

    def test_memory_peaks_are_the_largest_sample_not_the_last(self) -> None:
        peaks = cluster.memory_peaks(samples(4))
        self.assertEqual(peaks["ingest-queue"], 300.0)

    def test_a_volume_mounted_from_a_claim_is_read_with_du(self) -> None:
        spec = {"volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "d"}}, {"name": "tmp", "emptyDir": {}}],
                "containers": [{"name": "postgres", "volumeMounts": [{"name": "data", "mountPath": "/var/lib/postgresql"}, {"name": "tmp", "mountPath": "/tmp"}]}]}
        self.assertEqual(cluster._claim_mounts(spec), [("postgres", "/var/lib/postgresql")])

    def test_disk_growth_is_bytes_a_run_over_the_window(self) -> None:
        window = [{"t": 0.0, "disk": {"rustfs:/data": 1000}}, {"t": 30.0, "disk": {}}, {"t": 60.0, "disk": {"rustfs:/data": 1600}}]
        self.assertEqual(cluster.disk_per_run(window, 10.0), {"rustfs:/data": 600 * 1024 / 600})
        self.assertIsNone(cluster.disk_per_run(window[:2], 10.0))

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
