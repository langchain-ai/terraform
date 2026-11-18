import unittest

from loadtest.cli import build_parser, resolve
from loadtest.profile import from_document
from loadtest.runner import LoadSettings
from profiles import document as profile


def parse(*argv: str) -> dict:
    return vars(build_parser(LoadSettings()).parse_args(argv))


def arguments(*argv: str) -> dict:
    values = parse(*argv)
    for name in ("json", "results", "profile"):
        values.pop(name)
    return values


class ResolveTest(unittest.TestCase):
    def test_no_rate_is_the_closed_loop_default(self) -> None:
        loaded, values = resolve(arguments(), None)
        settings = LoadSettings(**values)
        # Hand-written: 10 closed-loop users for 10 s, no reads, and the model's 10 runs a trace.
        self.assertIsNone(values["traces_per_second"])
        self.assertIsNone(values["reads_per_second"])
        self.assertEqual((settings.users, settings.duration_seconds, settings.read), (10, 10.0, False))
        self.assertEqual((loaded.runs_per_trace, loaded.feedback_per_trace), (10.0, 0.5))

    def test_profile_sets_the_rate_and_peak_the_peak(self) -> None:
        loaded = from_document(profile())
        _, values = resolve(arguments(), loaded)
        self.assertEqual(values["traces_per_second"], 50.0)
        _, values = resolve(arguments("--peak"), loaded)
        self.assertEqual(values["traces_per_second"], 150.0)
        _, values = resolve(arguments("--traces-per-second", "7"), loaded)
        self.assertEqual(values["traces_per_second"], 7.0)

    def test_profile_read_rate_applies_when_reads_are_enabled(self) -> None:
        _, values = resolve(arguments("--read"), from_document(profile()))
        self.assertEqual(LoadSettings(**values).reads_per_second, 20.0)

    def test_contradictions_are_refused(self) -> None:
        with self.assertRaises(ValueError):
            resolve(arguments("--users", "5", "--traces-per-second", "2"), None)
        with self.assertRaises(ValueError):
            resolve(arguments("--peak"), None)
        with self.assertRaises(ValueError):
            _, values = resolve(arguments("--read"), None)
            LoadSettings(**values)

    def test_feedback_override_replaces_the_profile_value(self) -> None:
        loaded, _ = resolve(arguments("--feedback-per-trace", "2"), from_document(profile()))
        self.assertEqual(loaded.feedback_per_trace, 2.0)


if __name__ == "__main__":
    unittest.main()
