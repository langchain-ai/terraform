"""The reader against a fake client, with every SDK call checked against the installed SDK's signature."""

import datetime
import inspect
import random
import typing
import unittest
from types import SimpleNamespace
from uuid import uuid4

from langsmith import Client
from langsmith._openapi_client.resources.runs.runs import AsyncRunsResource
from langsmith._openapi_client.resources.traces import AsyncTracesResource
from langsmith._openapi_client.types import RunSelectField
from loadtest.profile import from_document
from loadtest.reads import FEEDBACK_KEY, Reader, TracePool
from profiles import document

NOW = datetime.datetime.now(datetime.UTC)
WEIGHTS = {"list_traces": 45, "read_trace": 30, "project_stats": 15, "feedback_stats": 8, "heavy_filter": 2}


class RecordingClient:
    def __init__(self) -> None:
        self.calls: list[tuple[str, tuple, dict]] = []
        self.fail: dict[str, Exception] = {}
        self.runs = SimpleNamespace(query=self.record("runs.query"))
        self.traces = SimpleNamespace(query=self.record("traces.query"), list_runs=self.record("traces.list_runs"))
        self.read_project = self.record_sync("read_project")
        self.get_run_stats = self.record_sync("get_run_stats")

    def record(self, name: str):
        async def call(*args, **kwargs):
            self.calls.append((name, args, kwargs))
            if name in self.fail:
                raise self.fail[name]
            return SimpleNamespace(items=[])

        return call

    def record_sync(self, name: str):
        def call(*args, **kwargs):
            self.calls.append((name, args, kwargs))
            if name in self.fail:
                raise self.fail[name]
            return {}

        return call

    def named(self, name: str) -> list[tuple[tuple, dict]]:
        return [(args, kwargs) for call, args, kwargs in self.calls if call == name]


def make_reader(client: RecordingClient, pool: TracePool | None = None, seed: int = 1) -> Reader:
    mix = from_document(document()).read_mix
    return Reader(client, uuid4(), "tid", NOW, mix, 30, pool or TracePool(0), seed)  # type: ignore[arg-type]


class ReaderTest(unittest.IsolatedAsyncioTestCase):
    async def read_many(self, reader: Reader, count: int) -> None:
        for number in range(count):
            await reader.read(number)

    async def test_classes_are_drawn_by_the_profile_weights_and_each_calls_its_sdk_method(self) -> None:
        client = RecordingClient()
        pool = TracePool(0)
        pool.add("t1", 0.0, NOW)
        reader = make_reader(client, pool)
        await self.read_many(reader, 4000)
        report = {name: entry.report() for name, entry in reader.stats.items()}
        for name, weight in WEIGHTS.items():
            self.assertAlmostEqual(report[name]["count"] / 4000, weight / 100, delta=0.03, msg=name)
            self.assertEqual(report[name]["errors"], 0)
        # Each class made its own call, once per read.
        self.assertEqual(len(client.named("traces.query")), report["list_traces"]["count"])
        self.assertEqual(len(client.named("traces.list_runs")), report["read_trace"]["count"])
        self.assertEqual(len(client.named("read_project")), report["project_stats"]["count"])
        self.assertEqual(len(client.named("runs.query")), report["heavy_filter"]["count"])
        self.assertEqual(len(client.named("get_run_stats")), report["feedback_stats"]["count"])
        self.assertEqual({entry["component"] for name, entry in report.items() if name in ("list_traces", "read_trace", "heavy_filter")}, {"query"})
        self.assertEqual(report["project_stats"]["component"], "stats-query")

    async def test_a_failing_class_counts_errors_for_that_class_only(self) -> None:
        client = RecordingClient()
        client.fail["read_project"] = RuntimeError("no")
        reader = make_reader(client)
        await self.read_many(reader, 600)
        report = {name: entry.report() for name, entry in reader.stats.items()}
        self.assertEqual(report["project_stats"]["count"], 0)
        self.assertGreater(report["project_stats"]["errors"], 50)
        self.assertEqual(report["project_stats"]["first_error"], "RuntimeError: no")
        self.assertEqual(report["list_traces"]["errors"], 0)
        self.assertIsNotNone(report["list_traces"]["p99_seconds"])

    async def test_read_trace_is_skipped_until_a_trace_is_old_enough(self) -> None:
        client = RecordingClient()
        reader = make_reader(client, TracePool(min_age_seconds=10_000))
        reader.weights = {"read_trace": 1.0}
        await self.read_many(reader, 20)
        stats = reader.stats["read_trace"]
        self.assertEqual((stats.skipped, len(stats.latencies_seconds), stats.errors), (20, 0, 0))
        self.assertEqual(client.named("traces.list_runs"), [])

    async def test_calls_carry_the_project_the_window_and_the_tests_own_filters(self) -> None:
        client = RecordingClient()
        pool = TracePool(0)
        pool.add("trace-1", 0.0, NOW)
        reader = make_reader(client, pool)
        for name in WEIGHTS:
            await reader.calls[name]()
        project = reader.project_id
        (_, query), = client.named("traces.query")
        self.assertEqual((query["project_id"], query["min_start_time"], query["page_size"]), (project, NOW, 20))
        (args, listing), = client.named("traces.list_runs")
        self.assertEqual(args, ("trace-1",))
        self.assertEqual(listing["project_id"], project)
        self.assertEqual(listing["min_start_time"], NOW - datetime.timedelta(minutes=5))
        self.assertEqual(listing["max_start_time"], NOW + datetime.timedelta(minutes=5))
        (_, stats), = client.named("read_project")
        self.assertEqual(stats, {"project_id": project, "include_stats": True})
        (_, feedback), = client.named("get_run_stats")
        self.assertEqual((feedback["project_ids"], feedback["is_root"]), ([project], True))
        self.assertEqual(feedback["filter"], f'eq(feedback_key, "{FEEDBACK_KEY}")')
        (_, heavy), = client.named("runs.query")
        self.assertIn('"tid"', heavy["filter"])
        self.assertEqual(heavy["project_ids"], [project])
        self.assertIs(heavy["is_root"], True)
        self.assertAlmostEqual((heavy["max_start_time"] - heavy["min_start_time"]).days, 30, delta=0)

    async def test_every_call_binds_to_the_installed_sdk_signature_with_valid_selects(self) -> None:
        client = RecordingClient()
        pool = TracePool(0)
        pool.add("trace-1", 0.0, NOW)
        reader = make_reader(client, pool)
        for name in WEIGHTS:
            await reader.calls[name]()
        signatures = {
            "runs.query": (inspect.signature(AsyncRunsResource.query), None),
            "traces.query": (inspect.signature(AsyncTracesResource.query), None),
            "traces.list_runs": (inspect.signature(AsyncTracesResource.list_runs), None),
            "read_project": (inspect.signature(Client.read_project), None),
            "get_run_stats": (inspect.signature(Client.get_run_stats), None),
        }
        allowed = set(typing.get_args(RunSelectField))
        for name, args, kwargs in client.calls:
            signature, _ = signatures[name]
            # `self` is the first positional of an unbound method; the fake client replaced it.
            signature.bind(None, *args, **kwargs)
            self.assertLessEqual(set(kwargs.get("selects", [])), allowed, name)


class TracePoolTest(unittest.TestCase):
    def test_only_traces_old_enough_are_picked(self) -> None:
        pool = TracePool(min_age_seconds=60)
        pool.add("old", 10.0, NOW)
        pool.add("young", 100.0, NOW)
        random_source = random.Random(1)
        self.assertIsNone(pool.pick(50.0, random_source))
        for _ in range(20):
            self.assertEqual(pool.pick(75.0, random_source)[0], "old")  # type: ignore[index]

    def test_the_aged_pool_is_bounded(self) -> None:
        pool = TracePool(min_age_seconds=0)
        for number in range(4500):
            pool.add(f"t{number}", 0.0, NOW)
        pool.pick(1.0, random.Random(1))
        self.assertLessEqual(len(pool.aged), 4000)
        self.assertEqual(pool.aged[-1][0], "t4499")


if __name__ == "__main__":
    unittest.main()
