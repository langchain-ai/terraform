import unittest

from helpers import P, blend, coeffs
from langsmith_sizing.model import payload, services


class Curves(unittest.TestCase):
    def test_loglog_between_anchors(self) -> None:
        pts = [(8, 3.75), (64, 15)]
        self.assertAlmostEqual(payload.loglog(20, pts, "value", "ratio"), 6.91, places=2)
        self.assertEqual(payload.loglog(8, pts, "value", "ratio"), 3.75)

    def test_loglog_outside_the_anchors_holds_the_value_or_the_ratio(self) -> None:
        pts = [(8, 3.75), (64, 15)]
        self.assertEqual(payload.loglog(1, pts, "value", "ratio"), 3.75)
        self.assertEqual(payload.loglog(128, pts, "value", "ratio"), 30)
        self.assertEqual(payload.loglog(128, pts, "value", "value"), 15)

    def test_a_measured_run_reproduces_its_anchors(self) -> None:
        for (i, o), want in {(4, 4): (3.75, 0, 9.7), (32, 32): (15, 38, 2.9), (750, 750): (112, 84, 12)}.items():
            c = coeffs(i, o)
            for got, w in zip((c["smithdb_kb"], c["blob_kb"], c["redis_kb"]), want, strict=True):
                self.assertAlmostEqual(got, w)
            self.assertEqual(c["basis"], "measured")

    def test_smithdb_floor_for_a_small_run(self) -> None:
        self.assertAlmostEqual(coeffs(4, 4)["smithdb_kb"], 3.75)

    def test_an_offloaded_run_costs_redis_only_a_pointer(self) -> None:
        c = coeffs(20, 20)
        self.assertEqual(c["placement"], "offloaded")
        self.assertAlmostEqual(c["redis_kb"], 2.9)

    def test_blob_per_run_for_32_and_32(self) -> None:
        self.assertAlmostEqual(coeffs(32, 32)["blob_kb"], 38)

    def test_threshold_is_compared_per_field_in_kib(self) -> None:
        self.assertEqual(coeffs(20, 19)["placement"], "partial")
        self.assertEqual(coeffs(19, 19)["placement"], "inline")
        self.assertEqual(coeffs(20, 20)["placement"], "offloaded")

    def test_blob_storage_off_keeps_every_field_in_redis(self) -> None:
        c = coeffs(32, 32, blob=False)
        self.assertEqual((c["placement"], c["blob_kb"]), ("inline", 0))
        self.assertGreater(c["redis_kb"], coeffs(32, 32)["redis_kb"])

    def test_compression_never_stores_more_than_the_raw_run(self) -> None:
        c = coeffs(4, 4, compression=10)
        self.assertLessEqual(c["smithdb_kb"], 8 * 1.024 + 3.75 + 1e-9)
        self.assertLessEqual(c["redis_kb"], 9.7 + 8 * 1.024)

    def test_a_size_off_the_measured_sizes_is_marked(self) -> None:
        self.assertEqual(coeffs(100, 4)["basis"], "interpolated")  # between the medium and large runs, one field inline under 8 KiB
        self.assertEqual(coeffs(3000, 3000)["basis"], "extrapolated")  # past the largest measured run
        self.assertEqual(coeffs(16, 16)["basis"], "extrapolated")  # offloaded below the smallest offloaded run
        self.assertEqual(coeffs(4, 4, threshold_kib=8)["basis"], "interpolated")  # off the default threshold it is no longer the measured case


class Mix(unittest.TestCase):
    def test_weights_normalize_by_their_sum_and_an_empty_mix_falls_back(self) -> None:
        self.assertEqual(payload.mix_weights([7, 2.5, 0.5], [70, 25, 5])["weights"], [0.7, 0.25, 0.05])
        w = payload.mix_weights([70, 25, 5], [70, 25, 5])
        self.assertFalse(w["normalized"])
        self.assertTrue(payload.mix_weights([14, 5, 1], [70, 25, 5])["normalized"] is True)
        self.assertEqual(payload.mix_weights([0, 0, 0], [70, 25, 5])["weights"], [0.7, 0.25, 0.05])

    def test_the_blend_is_the_run_weighted_sum(self) -> None:
        b = blend()
        self.assertAlmostEqual(b["smithdb_kb"], 0.7 * 3.75 + 0.25 * 15 + 0.05 * 112)
        self.assertAlmostEqual(b["redis_kb"], 0.7 * 9.7 + 0.25 * 2.9 + 0.05 * 12)
        self.assertAlmostEqual(b["redis_kb"], 8.115)

    def test_platform_backend_pods_for_ten_billion_traces_a_year(self) -> None:
        peak = 1e10 / P["time.seconds_per_year"] * 10 * 3
        self.assertEqual(services.platform_backend_pods(peak, blend()["pb_per_1k"]), 5)
        curves = payload.curves_from_params(P)
        for run, pods in ((8, 3), (64, 6), (1500, 10)):
            self.assertAlmostEqual(curves.pb_per_1k(run) * peak / 1000, pods)


if __name__ == "__main__":
    unittest.main()
