import unittest

from loadtest.cli import build_parser, cluster_options, cluster_rows, resolve
from loadtest.profile import from_document
from loadtest.results import ERROR_CHARS, short_error
from loadtest.runner import LoadSettings
from profiles import document as profile


def parse(*argv: str) -> dict:
    parsed = vars(build_parser(LoadSettings()).parse_args(argv))
    cluster_options(parsed)
    return parsed


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


class ProjectsTest(unittest.TestCase):
    def test_one_project_keeps_its_name_and_many_are_numbered_busiest_first(self) -> None:
        from types import SimpleNamespace
        from uuid import uuid4

        from loadtest import cli
        from loadtest.profile import Shape

        made: list[str] = []

        def create_project(project_name: str, upsert: bool) -> SimpleNamespace:
            made.append(project_name)
            return SimpleNamespace(id=uuid4())

        client = SimpleNamespace(create_project=create_project)
        self.assertEqual(cli._projects(client, "load-test", Shape()).names, ("load-test",))  # type: ignore[arg-type]
        many = cli._projects(client, "load-test", Shape(projects=3, project_skew=0.5))  # type: ignore[arg-type]
        self.assertEqual((many.names, many.skew), (("load-test-000", "load-test-001", "load-test-002"), 0.5))
        self.assertEqual(made, ["load-test", "load-test-000", "load-test-001", "load-test-002"])

    def test_the_shape_flags_replace_the_profiles(self) -> None:
        _, values = resolve(arguments("--projects", "200", "--project-skew", "1", "--metadata-keys", "34", "--batch-runs", "40"), None)
        self.assertNotIn("projects", values)
        loaded, _ = resolve(arguments("--projects", "200", "--metadata-keys", "34", "--batch-runs", "40"), None)
        self.assertEqual((loaded.shape.projects, loaded.shape.metadata_keys, loaded.shape.batch_runs), (200, 34, 40))


class ClusterRowsTest(unittest.TestCase):
    def test_a_workload_with_memory_and_no_cpu_reads_not_read(self) -> None:
        # magus, 2026-11-25: a verify's 60 s window gave one workload a memory peak and no CPU rate,
        # and formatting the None stopped the summary with a TypeError.
        rows = cluster_rows({"queue": {"cores_used": None, "memory_peak_mib": 412.4},
                             "backend": {"cores_used": 0.5, "runs_per_core": 20.0}})
        self.assertEqual(rows, [("queue", "not read", "", "412 MiB"), ("backend", "0.50", "20.0", "not read")])


class ShortErrorTest(unittest.TestCase):
    def test_a_batch_error_keeps_its_cause_and_says_how_much_was_cut(self) -> None:
        cause = "Server error (500) caused failure to POST /runs/multipart"
        text = cause + "; trace=x,id=y" * 1000
        short = short_error(text)
        self.assertTrue(short.startswith(cause))
        self.assertTrue(short.endswith(f"({len(text) - ERROR_CHARS:,} more characters)"))
        self.assertEqual(short_error(cause), cause)
