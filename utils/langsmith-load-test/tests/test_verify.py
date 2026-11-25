import datetime
import time
import unittest
from types import SimpleNamespace
from unittest import mock
from uuid import uuid4

from fakes import FakeClient
from loadtest import verify
from loadtest.reads import run_filter

SINCE = datetime.datetime(2026, 1, 1, tzinfo=datetime.UTC)


class Counting(FakeClient):
    """runs.query answers from a script: a number of runs, or an exception to raise, paged as the API pages."""

    def __init__(self, script: list) -> None:
        super().__init__()
        self.script = list(script)
        self.runs_resource.query = self._scripted

    async def _scripted(self, **kwargs):
        if not kwargs.get("cursor"):
            self.stats_calls.append(kwargs)
            step = self.script.pop(0) if len(self.script) > 1 else self.script[0]
            if isinstance(step, Exception):
                raise step
            self.remaining = step
        size = min(self.remaining, kwargs["page_size"])
        self.remaining -= size
        return SimpleNamespace(items=[SimpleNamespace(id=i) for i in range(size)], next_cursor="more" if self.remaining else None)


class StoredCountsTest(unittest.IsolatedAsyncioTestCase):
    async def test_counts_roots_then_everything_for_this_tests_id_only(self) -> None:
        client = Counting([4, 12])
        project = uuid4()
        self.assertEqual(await verify.stored_counts(client, [project], "tid", SINCE), (4, 12))
        roots, everything = client.stats_calls
        self.assertIs(roots["is_root"], True)
        self.assertNotIn("is_root", everything)
        for call in (roots, everything):
            self.assertEqual(call["project_ids"], [str(project)])
            self.assertEqual(call["filter"], run_filter("tid"))
            self.assertEqual(call["min_start_time"], SINCE)
        self.assertIn('"load_test_id"', run_filter("tid"))
        self.assertIn('"tid"', run_filter("tid"))

    async def test_a_count_past_one_page_reads_every_page(self) -> None:
        with mock.patch.object(verify, "PAGE_SIZE", 3):
            self.assertEqual(await verify.stored_counts(Counting([4, 10]), [uuid4()], "tid", SINCE), (4, 10))


class SettleTest(unittest.IsolatedAsyncioTestCase):
    async def settle(self, client: Counting, runs_sent: int, seconds: float) -> tuple[verify.Stored, float]:
        started = time.monotonic()
        with mock.patch.object(verify, "SETTLE_POLL_SECONDS", 0.01):
            stored = await verify.settle(client, [uuid4()], "tid", SINCE, runs_sent, seconds)
        return stored, time.monotonic() - started

    async def test_returns_at_once_when_every_run_is_stored(self) -> None:
        client = Counting([5, 30])
        stored, elapsed = await self.settle(client, 30, 5)
        self.assertEqual((stored.traces, stored.runs, stored.error), (5, 30, None))
        self.assertLess(elapsed, 1)

    async def test_a_failing_read_is_retried_until_it_succeeds_and_the_error_is_cleared(self) -> None:
        client = Counting([ConnectionError("down"), ConnectionError("down"), 5, 30])
        stored, _ = await self.settle(client, 30, 5)
        self.assertEqual((stored.runs, stored.error), (30, None))

    async def test_a_count_that_never_reaches_runs_sent_ends_at_the_deadline_with_the_last_count(self) -> None:
        client = Counting([5, 27])
        stored, elapsed = await self.settle(client, 30, 0.3)
        self.assertEqual(stored.runs, 27)
        self.assertGreaterEqual(elapsed, 0.3)
        self.assertLess(elapsed, 2)

    async def test_a_read_that_always_fails_is_an_error_not_a_zero(self) -> None:
        client = Counting([RuntimeError("boom\nsecond line")])
        stored, elapsed = await self.settle(client, 30, 0.2)
        self.assertEqual((stored.traces, stored.runs), (None, None))
        self.assertEqual(stored.error, "RuntimeError: boom second line")
        self.assertGreaterEqual(elapsed, 0.2)


if __name__ == "__main__":
    unittest.main()
