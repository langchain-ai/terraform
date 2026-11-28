import asyncio
import unittest

from loadtest.lag import BATCH, LagTracker


class LagTrackerTest(unittest.TestCase):
    def test_records_lag_and_expires_at_the_deadline(self) -> None:
        tracker = LagTracker(deadline_seconds=10)
        tracker.add("a", 0.0)
        tracker.add("b", 0.0)
        tracker.add("c", 5.0)
        tracker.record({"a"}, 3.0)
        self.assertEqual(tracker.lags_seconds, [3.0])
        tracker.expire(10.5)
        self.assertEqual(tracker.never_readable, 1)
        self.assertEqual(set(tracker.pending), {"c"})


class PollTest(unittest.IsolatedAsyncioTestCase):
    async def test_pending_ids_are_checked_in_batches_and_each_lag_is_its_own(self) -> None:
        tracker = LagTracker(deadline_seconds=1000)
        for number in range(250):
            tracker.add(f"r{number}", 0.0)
        batches: list[int] = []
        clock = [0.0]

        async def readable(ids: list[str]) -> set[str]:
            batches.append(len(ids))
            clock[0] += 1.0
            return set(ids)

        finished = asyncio.Event()
        finished.set()
        await asyncio.wait_for(tracker.poll(readable, lambda: clock[0], 0.001, finished), timeout=5)
        self.assertEqual(batches, [100, 100, 50])
        self.assertEqual(BATCH, 100)
        # Each batch is stamped after its own check: 1 s for the first 100, 2 s for the next, 3 s for the last.
        self.assertEqual(sorted(set(tracker.lags_seconds)), [1.0, 2.0, 3.0])
        self.assertEqual(tracker.pending, {})

    async def test_a_run_that_never_appears_expires_and_ends_the_poll(self) -> None:
        tracker = LagTracker(deadline_seconds=25)
        for number in range(3):
            tracker.add(f"r{number}", 0.0)
        clock = [0.0]

        async def readable(ids: list[str]) -> set[str]:
            clock[0] += 10.0
            return set()

        finished = asyncio.Event()
        finished.set()
        await asyncio.wait_for(tracker.poll(readable, lambda: clock[0], 0.001, finished), timeout=5)
        self.assertEqual((tracker.never_readable, tracker.lags_seconds, tracker.pending), (3, [], {}))

    async def test_poll_keeps_running_until_finished_is_set(self) -> None:
        tracker = LagTracker(deadline_seconds=100)
        finished = asyncio.Event()

        async def readable(ids: list[str]) -> set[str]:
            return set(ids)

        task = asyncio.create_task(tracker.poll(readable, lambda: 1.0, 0.001, finished))
        await asyncio.sleep(0.05)
        self.assertFalse(task.done())
        tracker.add("late", 0.0)
        await asyncio.sleep(0.05)
        finished.set()
        await asyncio.wait_for(task, timeout=2)
        self.assertEqual(tracker.lags_seconds, [1.0])


if __name__ == "__main__":
    unittest.main()
