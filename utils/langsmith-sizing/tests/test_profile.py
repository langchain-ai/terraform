import unittest

from langsmith_sizing import citations, inputs, params, profile
from tests.helpers import CHART, chart_at, needs_helm


@needs_helm
class Profile(unittest.TestCase):
    def test_the_profile_carries_the_load_the_plan_sizes(self) -> None:
        p = params.load()
        prof = profile.load_profile(inputs.Inputs(chart_version=CHART, users=10, traces_per_second=50), chart_at(CHART), p, citations.load())
        self.assertEqual(prof["schema"], profile.SCHEMA)
        self.assertEqual(prof["write"]["peak_traces_per_second"], 150)  # 50 x the default peak factor of 3
        self.assertEqual(round(sum(prof["write"]["payload"]["mix"].values())), 100)
        # the three measured run sizes, each field in KiB (the payload tests reproduce their anchors)
        self.assertEqual(prof["write"]["payload"]["sizes_kib"], {"small": {"in": 4, "out": 4}, "medium": {"in": 32, "out": 32}, "large": {"in": 750, "out": 750}})
        self.assertEqual(prof["read"]["requests_per_second"], 20)  # 2 a user, from the scale guide
        self.assertIn("heavy_filter", prof["read"]["mix"])

    def test_a_known_busiest_hour_replaces_the_peak_factor(self) -> None:
        prof = profile.load_profile(inputs.Inputs(chart_version=CHART, users=5, traces_per_second=10, peak_traces_per_second=12), chart_at(CHART), params.load(), citations.load())
        self.assertEqual(prof["write"]["peak_traces_per_second"], 12)


if __name__ == "__main__":
    unittest.main()
