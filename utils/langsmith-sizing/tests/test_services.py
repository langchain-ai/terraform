import unittest

from helpers import P, blend
from langsmith_sizing.model import services

PTS = P["ingest.runs_per_core_points"]
KW = {"headroom": P["ingest.cpu_headroom"], "pod_cpu": P["ingest.pod_cpu"], "min_pods": P["ingest.min_pods"]}


class IngestQueue(unittest.TestCase):
    def test_runs_per_core_by_run_size(self) -> None:
        self.assertEqual(services.ingest_runs_per_core(8, PTS), 55)
        self.assertAlmostEqual(services.ingest_runs_per_core(64, PTS), 20.9, places=1)
        self.assertEqual(services.ingest_runs_per_core(190, PTS), 12.6)
        self.assertEqual(services.ingest_runs_per_core(5000, PTS), 12.6)

    def test_the_guide_blend_is_a_harmonic_mean(self) -> None:
        k = services.harmonic_per_worker([0.7, 0.25, 0.05], [55, 20.91, 12.6])
        self.assertAlmostEqual(k, 34.90, places=2)
        self.assertLess(k, 0.7 * 55 + 0.25 * 20.91 + 0.05 * 12.6)

    def test_cpus_and_pods_at_the_defaults(self) -> None:
        self.assertAlmostEqual(services.ingest_queue_cpus(1500, 34.9, 1.25), 53.7, places=1)
        self.assertEqual(services.ingest_queue_pods(1500, 34.9, **KW), 27)
        self.assertEqual(services.ingest_queue_pods(500, 34.9, **KW), 9)

    def test_two_pods_at_least(self) -> None:
        self.assertEqual(services.ingest_queue_pods(1, 34.9, **KW), 2)

    def test_keda_max_rounds_to_the_nearest_five_with_halves_up(self) -> None:
        f, to = P["keda.max_factor"], P["keda.round_to"]
        self.assertEqual([services.keda_max(n, f, to) for n in (17, 20, 4)], [25, 30, 5])
        self.assertEqual(services.keda_max(15, f, to), 25)  # 22.5 / 5 = 4.5: a half rounds up, not to even

    def test_replicas_at_the_defaults(self) -> None:
        ing = services.ingest(1500, 500, 34.897766815621345, keda_factor=P["keda.max_factor"], keda_round_to=P["keda.round_to"], **KW)
        r = services.ingest_queue_replicas(int(ing["min_pods"]), int(ing["max_pods"]), ing["keda_max"])
        self.assertEqual(r, {"replicas": 27, "min": 9, "max": 40})

    def test_platform_backend_pods(self) -> None:
        self.assertEqual(services.platform_backend_pods(9512.9, blend()["pb_per_1k"]), 5)


class Application(unittest.TestCase):
    PROFILE = {"fe": 4, "pb": 20, "iq": 24, "be": 50, "min_fe": 2, "min_pb": 8, "min_iq": 8, "min_be": 20}
    ING = {"min_pods": 9, "max_pods": 27, "keda_max": 40}

    def test_the_guide_is_the_floor_under_the_payload_and_the_chart_default_under_both(self) -> None:
        low = {"fe": 1, "pb": 3, "iq": 3, "be": 2, "min_fe": 1, "min_pb": 3, "min_iq": 3, "min_be": 2}
        self.assertEqual(services.application_replicas(low, self.ING, 5, 3, None)["platform-backend"]["replicas"], 5)
        self.assertEqual(services.application_replicas(low, self.ING, 1, 3, None)["platform-backend"]["replicas"], 3)
        self.assertEqual(services.application_replicas(self.PROFILE, self.ING, 5, 3, None)["platform-backend"]["replicas"], 20)

    def test_smithdb_serving_reads_takes_the_python_backend_off_the_read_path(self) -> None:
        self.assertEqual(services.application_replicas(self.PROFILE, self.ING, 5, 3, 2)["backend"]["replicas"], 2)
        self.assertEqual(services.application_replicas(self.PROFILE, self.ING, 5, 3, None)["backend"]["replicas"], 50)


if __name__ == "__main__":
    unittest.main()
