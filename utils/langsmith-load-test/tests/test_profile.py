import json
import tempfile
import unittest
from pathlib import Path

import profiles
from loadtest.profile import SINGLE, ProfileError, from_document, from_file, from_params
from profiles import document as profile


class ProfileTest(unittest.TestCase):
    def test_reads_a_valid_profile(self) -> None:
        loaded = from_document(profile())
        # By hand for 10 users at 50 traces/s: peak is 3x the rate, 2 read requests/s a user (the
        # scale guide's anchor), 10 runs a trace and the 70/25/5 mix of 4, 32 and 750 KiB from params.
        self.assertEqual(loaded.traces_per_second, 50.0)
        self.assertEqual(loaded.peak_traces_per_second, 150.0)
        self.assertEqual(loaded.runs_per_trace, 10.0)
        self.assertEqual(loaded.mix, {"small": 70.0, "medium": 25.0, "large": 5.0})
        self.assertEqual(loaded.sizes_kib, {"small": (4.0, 4.0), "medium": (32.0, 32.0), "large": (750.0, 750.0)})
        self.assertEqual(loaded.feedback_per_trace, 0.5)
        self.assertEqual(loaded.targets, {"stored_within_seconds": 30.0, "trace_load_seconds": 5.0})
        self.assertEqual(loaded.read_requests_per_second, 20.0)
        self.assertEqual({name: entry["weight"] for name, entry in loaded.read_mix.items()},
                         {"list_traces": 45, "read_trace": 30, "project_stats": 15, "feedback_stats": 8, "heavy_filter": 2})
        self.assertEqual(loaded.heavy_window_days, 30.0)

    def test_rejects_a_wrong_schema(self) -> None:
        document = profile()
        document["schema"] = "langsmith-load-profile/2"
        with self.assertRaisesRegex(ProfileError, "langsmith-load-profile/2"):
            from_document(document)

    def test_rejects_a_missing_field_and_an_unknown_read_class(self) -> None:
        document = profile()
        del document["write"]["feedback_per_trace"]
        with self.assertRaisesRegex(ProfileError, "write.feedback_per_trace"):
            from_document(document)
        document = profile()
        document["read"]["mix"]["delete_everything"] = {"weight": 1}
        with self.assertRaisesRegex(ProfileError, "delete_everything"):
            from_document(document)

    def test_rejects_a_mix_size_without_a_size(self) -> None:
        document = profile()
        document["write"]["payload"]["mix"]["huge"] = 1
        with self.assertRaisesRegex(ProfileError, "huge"):
            from_document(document)

    def test_single_run_size_replaces_the_mix(self) -> None:
        document = profile()
        document["write"]["payload"]["single_run_kib"] = [10, 20]
        loaded = from_document(document)
        self.assertEqual(loaded.mix, {SINGLE: 100.0})
        self.assertEqual(loaded.sizes_kib, {SINGLE: (10.0, 20.0)})

    def test_file_that_is_not_json_is_a_profile_error(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "profile.json"
            path.write_text("not json")
            with self.assertRaises(ProfileError):
                from_file(path)
            path.write_text(json.dumps(profile()))
            self.assertEqual(from_file(path).runs_per_trace, 10.0)

    def test_defaults_come_from_the_sizing_params_without_helm(self) -> None:
        defaults = from_params()
        self.assertIsNone(defaults.traces_per_second)
        self.assertIsNone(defaults.read_requests_per_second)
        # The same numbers the real profile carries, reached by the other path: no chart, no helm.
        sized = from_document(profile())
        for name in ("mix", "sizes_kib", "runs_per_trace", "feedback_per_trace", "heavy_window_days", "targets"):
            self.assertEqual(getattr(defaults, name), getattr(sized, name), name)
        self.assertEqual({name: entry["weight"] for name, entry in defaults.read_mix.items()},
                         {name: entry["weight"] for name, entry in sized.read_mix.items()})

    def test_the_stub_chart_gives_the_document_the_real_chart_gives(self) -> None:
        from langsmith_sizing import chart

        if not (chart.CACHE / "charts" / profiles.CHART_VERSION / "langsmith" / "Chart.yaml").exists():
            self.skipTest("chart not in the sizing cache; this check never pulls")
        self.assertEqual(profiles.real_document(chart.Chart(profiles.CHART_VERSION)), profile())

    def test_peak_follows_a_known_busiest_hour(self) -> None:
        from langsmith_sizing import citations, inputs, params
        from langsmith_sizing import profile as sizing_profile

        document = sizing_profile.load_profile(
            inputs.Inputs(chart_version=profiles.CHART_VERSION, users=5, traces_per_second=10, peak_traces_per_second=12),
            profiles.StubChart(), params.load(), citations.load(),
        )
        self.assertEqual(from_document(document).peak_traces_per_second, 12.0)


if __name__ == "__main__":
    unittest.main()
