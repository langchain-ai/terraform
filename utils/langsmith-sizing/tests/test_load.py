import unittest

from helpers import CITED, P
from langsmith_sizing.model import load

READS, WRITES = load.anchors(CITED["scale.read_anchors"]), load.anchors(CITED["scale.write_anchors"])
GRID = load.build_grid(load.published_profiles(CITED), P["grid.blend"])


def at(users: float, tps: float) -> load.Profile:
    return load.profile_for(users, tps, GRID, READS, WRITES)


class Bands(unittest.TestCase):
    def test_anchors_are_the_guides(self) -> None:
        self.assertEqual((READS, WRITES), ([5, 20, 50], [10, 100, 1000]))

    def test_classify(self) -> None:
        self.assertEqual(load.classify_bands(10, 50, READS, WRITES), {"r": "m", "w": "m"})
        self.assertEqual(load.classify_bands(5, 10, READS, WRITES), {"r": "l", "w": "l"})

    def test_band_coord(self) -> None:
        self.assertAlmostEqual(load.band_coord(10, READS), 0.333, places=3)
        self.assertAlmostEqual(load.band_coord(50, WRITES), 0.444, places=3)
        self.assertEqual((load.band_coord(1, READS), load.band_coord(500, READS)), (0, 2))

    def test_a_blend_rounds_up_once_at_the_end(self) -> None:
        # corners 3, 4 / 16, 17 at the Low-to-Medium read position 1/3 and write position 1/2: the
        # rows blend to 3.5 and 16.5, then 3.5 + (16.5 - 3.5) / 3 = 7.83, which rounds up to 8.
        # Rounding each row first (4 and 17) would give 4 + 13 / 3 = 8.33 and so 9.
        def node(v: float) -> load.Profile:
            return dict.fromkeys(load.NUMERIC, v) | {"ch_n": 1, "ch_rep_documented": True}

        grid = [[node(3), node(3), node(4)], [node(16), node(16), node(17)], [node(16), node(16), node(17)]]
        got = load.grid_profile(10, 55, grid, READS, WRITES)
        self.assertEqual({got[f] for f in load.NUMERIC}, {8})

    def test_extrapolation(self) -> None:
        f = load.extrapolation_factors(200, 5000, READS, WRITES)
        self.assertEqual((f["rx"], f["wx"]), (4, 5))
        self.assertEqual(load.scale_up(50, 4), 200)

    def test_beyond_published(self) -> None:
        self.assertFalse(load.beyond_published(50, 1000, READS, WRITES))
        self.assertTrue(load.beyond_published(51, 1000, READS, WRITES))

    def test_ceil_ignores_float_noise(self) -> None:
        self.assertEqual((load.ceil(20.000000001), load.ceil(709.5)), (20, 710))


class Rates(unittest.TestCase):
    def test_run_rates(self) -> None:
        r = load.run_rates(50, 10, 3)
        self.assertEqual((r["runs_per_second_avg"], r["runs_per_second_peak"], r["runs_per_day"]), (500, 1500, 43_200_000))

    def test_ten_billion_traces_a_year(self) -> None:
        tps = 1e10 / P["time.seconds_per_year"]
        self.assertAlmostEqual(tps, 317.098, places=3)
        self.assertAlmostEqual(load.run_rates(tps, 10, 3)["runs_per_second_peak"], 9512.9, places=1)

    def test_a_measured_peak_replaces_the_factor(self) -> None:
        self.assertEqual(load.run_rates(50, 10, 3, peak_tps=80)["runs_per_second_peak"], 800)

    def test_per_month(self) -> None:
        m = P["time.seconds_per_month"]
        self.assertAlmostEqual(load.traces_per_second(10e6, m), 3.807, places=3)
        self.assertEqual(round(load.run_rates(load.traces_per_second(10e6, m), 10, 3)["runs_per_second_peak"]), 114)
        self.assertAlmostEqual(load.traces_per_second(500e3, m), 0.1904, places=4)
        self.assertAlmostEqual(load.traces_per_month(50, m) / 1e6, 131.3, places=1)


class Grid(unittest.TestCase):
    def test_published_corners_come_through_unaltered(self) -> None:
        for (u, t), want in {
            (5, 10): {"fe": 1, "pb": 3, "iq": 3, "be": 2, "redis_gi": 8},
            (5, 1000): {"fe": 4, "pb": 20, "iq": 24, "be": 5, "redis_gi": 26},
            (50, 10): {"fe": 2, "pb": 3, "iq": 3, "be": 40, "redis_gi": 8},
            (20, 100): {"fe": 2, "pb": 3, "iq": 6, "be": 16, "redis_gi": 13},
            (50, 1000): {"fe": 4, "pb": 20, "iq": 24, "be": 50, "redis_gi": 26},
        }.items():
            got = at(u, t)
            self.assertEqual({k: got[k] for k in want}, want, (u, t))

    def test_below_the_smallest_configuration_is_a_floor(self) -> None:
        self.assertEqual(at(1, 1), at(5, 10))

    def test_autoscaler_floors_of_the_examples(self) -> None:
        self.assertEqual({k: at(50, 1000)[k] for k in ("min_fe", "min_pb", "min_iq", "min_be")}, {"min_fe": 2, "min_pb": 8, "min_iq": 8, "min_be": 20})
        self.assertEqual({k: at(50, 10)[k] for k in ("min_fe", "min_pb", "min_iq", "min_be")}, {"min_fe": 2, "min_pb": 3, "min_iq": 2, "min_be": 16})

    def test_an_unpublished_node_never_falls_below_a_neighbor_it_outranks(self) -> None:
        # Med/Med runs 3 platform-backend replicas where Low/High runs 20; the blend alone sits below
        self.assertGreaterEqual(at(20, 1000)["pb"], 20)
        self.assertGreaterEqual(at(5, 100)["pb"], 3)
        for tps in (10, 100, 1000):
            counts = [at(u, tps)["be"] for u in (5, 12, 20, 35, 50)]
            self.assertEqual(counts, sorted(counts), tps)

    def test_past_the_highest_configuration_scales_linearly(self) -> None:
        g = at(200, 5000)
        self.assertEqual((g["be"], g["fe"], g["pb"], g["iq"]), (200, 16, 100, 120))
        self.assertEqual(g["ch_cpu"], at(50, 1000)["ch_cpu"])

    def test_replicated_clickhouse_is_documented_only_where_the_guide_publishes_it(self) -> None:
        pub = load.published_profiles(CITED)
        self.assertEqual({k: v["ch_rep_documented"] for k, v in pub.items()}, {"ll": False, "lh": False, "hl": True, "mm": False, "hh": True})
        self.assertEqual((pub["mm"]["ch_rep_cpu"], pub["mm"]["ch_rep_mem"]), (8, 16))
        self.assertEqual((pub["hh"]["ch_rep_cpu"], pub["hh"]["ch_rep_mem"], pub["hh"]["ch_n"]), (14, 24, 3))
        self.assertFalse(at(30, 100)["ch_rep_documented"])


if __name__ == "__main__":
    unittest.main()
