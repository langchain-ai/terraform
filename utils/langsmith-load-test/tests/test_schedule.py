import asyncio
import unittest

from loadtest.schedule import open_loop, start_offset


class VirtualLoop(asyncio.SelectorEventLoop):
    """An event loop whose clock jumps to the next timer instead of waiting: timing tests are exact
    and instant. Only for coroutines that never wait on a thread."""

    def __init__(self) -> None:
        super().__init__()
        self.now = 0.0

    def time(self) -> float:
        return self.now

    def _run_once(self) -> None:
        if not self._ready and self._scheduled:
            self.now = max(self.now, self._scheduled[0]._when)
        super()._run_once()


def run_virtual(coroutine):
    loop = VirtualLoop()
    try:
        return loop.run_until_complete(coroutine)
    finally:
        loop.close()


class StartOffsetTest(unittest.TestCase):
    def test_without_ramp_starts_are_evenly_spaced(self) -> None:
        offsets = [start_offset(index, 4.0, 0.0) for index in range(9)]
        self.assertEqual(offsets, [index / 4 for index in range(9)])

    def test_ramp_climbs_to_the_rate_then_holds(self) -> None:
        rate, ramp = 10.0, 4.0
        offsets = [start_offset(index, rate, ramp) for index in range(100)]
        self.assertEqual(offsets[0], 0.0)
        gaps = [later - earlier for earlier, later in zip(offsets, offsets[1:], strict=False)]
        # Gaps shrink through the ramp, then settle at 1 / rate.
        self.assertTrue(all(later <= earlier + 1e-9 for earlier, later in zip(gaps, gaps[1:], strict=False)))
        self.assertAlmostEqual(gaps[-1], 1 / rate)
        # The ramp delivers half the starts a flat rate would: rate * ramp / 2 by the time it ends.
        self.assertEqual(sum(1 for offset in offsets if offset < ramp), 20)
        self.assertAlmostEqual(start_offset(20, rate, ramp), ramp)

    def test_ramp_and_hold_join_without_a_jump(self) -> None:
        rate, ramp = 5.0, 6.0
        boundary = int(rate * ramp / 2)
        before = start_offset(boundary - 1, rate, ramp)
        after = start_offset(boundary, rate, ramp)
        self.assertAlmostEqual(after, ramp)
        self.assertLess(before, after)


class OpenLoopPacingTest(unittest.TestCase):
    def test_twenty_per_second_for_one_second_is_twenty_starts_spread_evenly(self) -> None:
        times: list[float] = []

        async def scenario():
            loop = asyncio.get_running_loop()

            async def start(_number: int) -> None:
                times.append(loop.time())

            return await open_loop(20.0, 0.0, 1.0, start, max_in_flight=100)

        stats = run_virtual(scenario())
        self.assertAlmostEqual(len(times), 20, delta=1)
        first_half = sum(1 for moment in times if moment < 0.5)
        self.assertAlmostEqual(first_half, len(times) - first_half, delta=1)
        # One start every 1/20 s, whatever the work does.
        gaps = [later - earlier for earlier, later in zip(times, times[1:], strict=False)]
        for gap in gaps:
            self.assertAlmostEqual(gap, 0.05, delta=0.001)
        self.assertLess(max(stats.lags_seconds), 0.001)
        self.assertEqual(stats.dropped, 0)

    def test_a_ramp_starts_slowly_and_ends_at_the_rate(self) -> None:
        times: list[float] = []

        async def scenario():
            loop = asyncio.get_running_loop()

            async def start(_number: int) -> None:
                times.append(loop.time())

            await open_loop(10.0, 2.0, 4.0, start, max_in_flight=100)

        run_virtual(scenario())
        # Over a 2 s ramp to 10/s: 10 starts in the ramp, then 10 a second for the 2 s left.
        self.assertEqual(sum(1 for moment in times if moment < 2.0), 10)
        self.assertEqual(sum(1 for moment in times if 2.0 <= moment < 3.0), 10)
        self.assertEqual(sum(1 for moment in times if 1.0 <= moment < 2.0), 7)  # starts 3 to 9 of the ramp: start i is due at sqrt(0.4 i) s

    def test_a_start_the_loop_is_late_for_runs_at_once_and_records_the_lateness(self) -> None:
        async def scenario():
            async def start(_number: int) -> None:
                # The first start blocks the loop for 0.3 s: the next ones are late, not skipped.
                if _number == 1:
                    loop = asyncio.get_running_loop()
                    loop.now += 0.3  # type: ignore[attr-defined]

            return await open_loop(10.0, 0.0, 1.0, start, max_in_flight=100)

        stats = run_virtual(scenario())
        self.assertEqual(stats.started, 10)
        self.assertGreater(max(stats.lags_seconds), 0.15)
        self.assertLessEqual(sum(1 for lag in stats.lags_seconds if lag > 0.001), 3)


class OpenLoopTest(unittest.IsolatedAsyncioTestCase):
    async def test_starts_do_not_wait_for_earlier_work(self) -> None:
        started: list[int] = []

        async def slow(number: int) -> None:
            started.append(number)
            await asyncio.sleep(0.5)

        stats = await open_loop(50.0, 0.0, 0.2, slow, max_in_flight=1000)
        self.assertEqual(stats.started, 10)
        self.assertEqual(started, list(range(1, 11)))
        self.assertEqual(stats.dropped, 0)

    async def test_starts_over_the_cap_are_dropped_not_delayed(self) -> None:
        async def slow(_number: int) -> None:
            await asyncio.sleep(0.5)

        stats = await open_loop(50.0, 0.0, 0.2, slow, max_in_flight=2)
        self.assertEqual(stats.started, 2)
        self.assertEqual(stats.dropped, 8)
        self.assertEqual(stats.scheduled, 10)

    async def test_limit_stops_the_schedule(self) -> None:
        async def instant(_number: int) -> None:
            return None

        stats = await open_loop(1000.0, 0.0, 10.0, instant, max_in_flight=100, limit=7)
        self.assertEqual(stats.scheduled, 7)


if __name__ == "__main__":
    unittest.main()
