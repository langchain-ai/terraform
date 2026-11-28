"""The whole write path, run against a fake client: what is sent, drained, flushed, counted and reported."""

import dataclasses
import json
import socket
import threading
import time
import unittest
from unittest import mock
from uuid import uuid4

from fakes import FakeClient
from loadtest import runner
from loadtest.draw import Projects
from loadtest.payloads.generator import KIB
from loadtest.profile import from_document
from loadtest.runner import EndpointGone, LoadSettings, build_report, run_load_test
from profiles import document


def small_profile(runs_per_trace: float = 3, feedback_per_trace: float = 0.5, size_kib: float = 1):
    doc = document()
    doc["write"]["runs_per_trace"] = runs_per_trace
    doc["write"]["feedback_per_trace"] = feedback_per_trace
    doc["write"]["payload"]["mix"] = {"small": 100.0}
    doc["write"]["payload"]["sizes_kib"] = {"small": {"in": size_kib, "out": size_kib}}
    return from_document(doc)


def settings(**overrides) -> LoadSettings:
    base = dict(
        users=2, duration_seconds=10, run_limit=10, progress_seconds=0, lag_sample=1.0, lag_poll_seconds=0.02,
        lag_deadline_seconds=0.5, settle_seconds=0.2, feedback_drain_seconds=0.3, data_seed=1,
    )
    return LoadSettings(**{**base, **overrides})


async def run(client: FakeClient, loaded=None, **overrides):
    config = settings(**overrides)
    loaded = loaded or small_profile()
    outcome = await run_load_test(config, loaded, client, Projects(("p",), (uuid4(),)))
    return outcome, build_report(outcome, config, loaded, "p", True, 0, None)


class ClosedLoopTest(unittest.IsolatedAsyncioTestCase):
    async def test_a_run_sends_feedback_flushes_then_counts_what_the_project_stored(self) -> None:
        client = FakeClient()
        outcome, report = await run(client)
        # 10 traces of 3 runs each; 0.5 feedback a trace is floor(10 * 0.5) = 5 calls, all drained.
        self.assertEqual((outcome.write.traces_sent, outcome.write.runs_sent), (10, 30))
        self.assertEqual(len(client.created), 30)
        self.assertEqual(len(client.feedback), 5)
        self.assertEqual((outcome.write.feedback_sent, outcome.write.feedback_errors), (5, 0))
        self.assertEqual({call["key"] for call in client.feedback}, {"load_test_feedback"})
        # Counted after the flush, never before it, and by the project's own count.
        self.assertEqual(client.events[0], "flush")
        self.assertEqual(client.events.count("stats"), 2)
        self.assertEqual((outcome.stored.traces, outcome.stored.runs), (10, 30))
        # Every sampled trace was read back and the poll task ended with nothing left pending.
        self.assertEqual((report["lag"]["sampled"], report["lag"]["readable"], report["lag"]["never_readable"]), (10, 10, 0))
        self.assertEqual(outcome.lag.pending, {})
        self.assertIn(report["stored"]["missing_runs"], (0,))
        self.assertTrue(report["passed"])
        self.assertEqual(client.info_reads, 1)

    async def test_every_run_carries_the_test_id_and_the_profile_size(self) -> None:
        client = FakeClient()
        outcome, _ = await run(client, small_profile(size_kib=2), run_limit=4, users=1)
        self.assertEqual(len(client.created), 12)
        for run_ in client.created:
            self.assertEqual(run_["extra"]["metadata"]["load_test_id"], outcome.test_id)
            text = run_["inputs"]["input"]
            self.assertTrue(text.isascii())
            # 2 KiB asked for, and the serialized bytes the server receives are within one word of it.
            self.assertLessEqual(len(json.dumps(run_["inputs"]).encode()), 2 * KIB + len('{"input": ""}'))
            self.assertGreater(len(text.encode()), 2 * KIB - 16)
        for patch in client.patched:
            text = patch["outputs"]["output"]
            self.assertLessEqual(len(text.encode()), 2 * KIB)
            self.assertGreater(len(text.encode()), 2 * KIB - 16)
        self.assertEqual(len(client.patched), 12)

    async def test_post_once_sends_each_run_finished_with_its_attachment_in_one_request(self) -> None:
        loaded = small_profile()
        loaded = dataclasses.replace(loaded, shape=dataclasses.replace(loaded.shape, send="post_once", attachment_kib_per_run=3, fields_per_side=2, content="json"))
        client = FakeClient()
        await run(client, loaded, run_limit=2, users=1)
        self.assertEqual((len(client.created), len(client.patched)), (6, 0))
        for run_ in client.created:
            self.assertIsNotNone(run_.get("end_time"))
            self.assertEqual(set(run_["outputs"]), {"output_0", "output_1"})
            self.assertIsInstance(run_["inputs"]["input_0"], list)
            self.assertEqual(len(run_["attachments"]["file"][1]), 3 * KIB)  # the SDK passes it on as (mime type, bytes)

    async def test_agent_traces_send_every_run_nested_under_its_parent_with_the_test_id(self) -> None:
        loaded = small_profile()
        loaded = dataclasses.replace(loaded, shape=dataclasses.replace(loaded.shape, traces="agent"))
        client = FakeClient()
        outcome, report = await run(client, loaded, run_limit=6, users=1)
        trees = [runner.AgentTraces(runner.AgentModel.from_params(), 1).trace(n) for n in range(1, 7)]
        self.assertEqual(outcome.write.runs_sent, sum(sum(1 for _ in t.walk()) for t in trees))
        self.assertEqual(len(client.created), outcome.write.runs_sent)
        self.assertEqual(outcome.write.payload_bytes_sent, sum(t.payload_bytes() for t in trees))
        by_id = {r["id"]: r for r in client.created}
        for run_ in client.created:
            self.assertEqual(run_["extra"]["metadata"]["load_test_id"], outcome.test_id)
            if run_["run_type"] == "llm":
                self.assertEqual(by_id[run_["parent_run_id"]]["name"], "model")
            if run_["run_type"] == "tool":
                self.assertEqual(by_id[run_["parent_run_id"]]["name"], "tools")
        self.assertEqual((outcome.stored.traces, outcome.stored.runs), (6, outcome.write.runs_sent))
        self.assertEqual(report["write"]["payload_shape"]["traces"], "agent")

    async def test_traces_spread_over_projects_by_rank_and_feedback_follows_each_trace(self) -> None:
        loaded = small_profile(runs_per_trace=1, feedback_per_trace=1)
        loaded = dataclasses.replace(loaded, shape=dataclasses.replace(loaded.shape, metadata_keys=10))
        projects = Projects(("p-000", "p-001", "p-002"), (uuid4(), uuid4(), uuid4()), skew=1.0)
        client = FakeClient()
        config = settings(run_limit=600, users=4)
        await run_load_test(config, loaded, client, projects)
        per = [sum(r["session_name"] == name for r in client.created) for name in projects.names]
        # Zipf 1 over three ranks: 6/11, 3/11 and 2/11 of the traces.
        for share, count in zip((6 / 11, 3 / 11, 2 / 11), per, strict=True):
            self.assertAlmostEqual(count / 600, share, delta=0.06)
        by_trace = {r["id"]: projects.ids[projects.names.index(r["session_name"])] for r in client.created}
        self.assertEqual({call["session_id"] for call in client.feedback if by_trace[call["trace_id"]] != call["session_id"]}, set())
        meta = client.created[0]["extra"]["metadata"]
        self.assertEqual(len([k for k in meta if k.startswith("key_")]), 10)
        ids = {r["extra"]["metadata"]["key_00"] for r in client.created}
        self.assertEqual(len(ids), 600)  # every fifth key, the first included, is a per-trace id

    async def test_a_hung_feedback_call_is_cancelled_after_the_drain_and_counted(self) -> None:
        client = FakeClient()
        release = threading.Event()
        self.addCleanup(release.set)
        # Calls 1 and 2 return; every later one blocks until the test ends.
        client.on_feedback = lambda number: None if number <= 2 else release.wait(10)
        outcome, report = await run(client, small_profile(feedback_per_trace=1), run_limit=4, users=1, feedback_drain_seconds=0.2)
        self.assertEqual(len(client.feedback), 4)
        self.assertEqual((outcome.write.feedback_sent, outcome.write.feedback_errors), (2, 2))
        self.assertIn("2 feedback calls still pending", outcome.write.first_error or "")
        self.assertEqual(report["feedback"], {"per_trace": 1, "sent": 2, "errors": 2})
        self.assertFalse(report["passed"])

    async def test_a_failed_send_is_counted_with_its_first_error(self) -> None:
        client = FakeClient()
        client.create_run_error = RuntimeError("server said no")
        outcome, report = await run(client, run_limit=3, users=1)
        self.assertEqual((outcome.write.traces_sent, outcome.write.run_errors), (0, 3))
        self.assertEqual(report["write"]["first_error"], "server said no")
        self.assertFalse(report["passed"])

    async def test_without_a_client_nothing_is_sent_and_nothing_is_stored(self) -> None:
        outcome = await run_load_test(settings(run_limit=3, users=1), small_profile(), None, Projects(("p",), (uuid4(),)))
        self.assertEqual((outcome.write.traces_sent, outcome.write.runs_sent), (3, 9))
        self.assertEqual((outcome.stored.traces, outcome.stored.runs), (None, None))


class OpenLoopTest(unittest.IsolatedAsyncioTestCase):
    async def test_a_slow_send_under_a_cap_of_one_drops_starts_and_the_report_says_so(self) -> None:
        client = FakeClient()
        # 50 traces/s for 0.4 s is 20 due starts; each started trace waits 0.3 s, one at a time.
        outcome, report = await run(
            client, traces_per_second=50, users=10, run_limit=None, duration_seconds=0.4, max_in_flight=1,
            simulated_delay_ms=300, lag_sample=0,
        )
        write = report["write"]
        self.assertEqual(write["mode"], "open-loop")
        self.assertGreater(write["dropped_starts"], 10)
        self.assertEqual(write["traces_started"] + write["dropped_starts"], 20)
        self.assertEqual(write["traces_sent"], write["traces_started"])
        self.assertIsNotNone(write["schedule_lag_seconds"]["p99"])

    async def test_an_open_loop_with_room_drops_nothing_and_keeps_its_schedule(self) -> None:
        client = FakeClient()
        outcome, report = await run(
            client, traces_per_second=20, users=10, run_limit=None, duration_seconds=1, lag_sample=0,
        )
        write = report["write"]
        self.assertEqual(write["dropped_starts"], 0)
        self.assertAlmostEqual(write["traces_started"], 20, delta=1)
        self.assertLess(write["schedule_lag_seconds"]["p99"], 0.1)
        self.assertGreater(write["duration_seconds"], 0.9)


    async def test_the_steady_rate_leaves_out_the_ramp(self) -> None:
        # 20 traces/s: a 1 s ramp starts 10 (half the rate on average), then 1 s holds 20
        client = FakeClient()
        _, report = await run(
            client, traces_per_second=20, users=10, run_limit=None, duration_seconds=1, ramp_up_seconds=1, lag_sample=0,
        )
        write = report["write"]
        self.assertAlmostEqual(write["traces_sent"], 30, delta=1)
        self.assertAlmostEqual(write["steady_traces_per_second"], 20, delta=1)
        self.assertLess(write["achieved_traces_per_second"], 17)  # the whole run, ramp included, reads low

class VerifyThroughTheReportTest(unittest.IsolatedAsyncioTestCase):
    async def test_runs_that_never_become_readable_fail_the_stored_within_target(self) -> None:
        client = FakeClient()
        client.readable = False
        outcome, report = await run(client, run_limit=5, users=1, lag_deadline_seconds=0.2)
        self.assertEqual(report["lag"]["sampled"], 5)
        self.assertEqual(report["lag"]["never_readable"], 5)
        self.assertEqual(report["lag"]["readable"], 0)
        self.assertIsNone(report["lag"]["p99_seconds"])
        self.assertIs(report["targets"]["stored_within_seconds_p99"]["passed"], False)
        self.assertFalse(report["passed"])

    async def test_a_count_that_cannot_be_read_is_unknown_and_fails(self) -> None:
        client = FakeClient()
        client.stats_error = ConnectionError("stats down")
        outcome, report = await run(client, run_limit=5, users=1)
        self.assertEqual(report["stored"]["error"], "ConnectionError: stats down")
        self.assertIsNone(report["stored"]["missing_runs"])
        self.assertIsNone(report["stored"]["runs_stored"])
        self.assertFalse(report["passed"])

    async def test_runs_the_project_did_not_store_are_missing(self) -> None:
        client = FakeClient()
        real = client.runs_resource.query

        async def short(**kw: object) -> object:
            page = await real(**kw)
            if "ids" not in kw and not kw.get("is_root"):
                page.items = page.items[:-2]
            return page

        client.runs_resource.query = short
        _, report = await run(client, run_limit=5, users=1, lag_sample=0)
        self.assertEqual(report["stored"]["missing_runs"], 2)
        self.assertFalse(report["passed"])



class EndpointTest(unittest.IsolatedAsyncioTestCase):
    async def test_a_run_ends_with_one_reason_when_its_endpoint_stops_taking_connections(self) -> None:
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        client = FakeClient()
        client.api_url = f"http://127.0.0.1:{port}"
        started = time.monotonic()
        with mock.patch.object(runner, "ENDPOINT_PROBE_SECONDS", 0.02), self.assertRaisesRegex(EndpointGone, f"127.0.0.1:{port} took no connection 3 times"):
            await run(client, users=1, run_limit=None, duration_seconds=30, pause_seconds=0.01)
        self.assertLess(time.monotonic() - started, 5)

    async def test_an_endpoint_that_answers_lets_the_run_finish(self) -> None:
        with socket.socket() as listening:
            listening.bind(("127.0.0.1", 0))
            listening.listen()
            client = FakeClient()
            client.api_url = f"http://127.0.0.1:{listening.getsockname()[1]}"
            with mock.patch.object(runner, "ENDPOINT_PROBE_SECONDS", 0.02):
                _, report = await run(client, run_limit=5, users=1, lag_sample=0)
        self.assertEqual(report["stored"]["missing_runs"], 0)


if __name__ == "__main__":
    unittest.main()
