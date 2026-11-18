"""Send-to-readable lag: how long a sent run takes to show up in a query."""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field

# Ids per readable check: one query for the whole batch.
BATCH = 100


@dataclass
class LagTracker:
    """Tracks sampled runs until each is readable or its deadline passes.

    The clock starts when the test begins sending the trace, so SDK batching counts: that wait is
    part of what a user sees. A run is first seen at a poll, so a lag is an upper bound within one
    poll interval.
    """

    deadline_seconds: float
    pending: dict[str, float] = field(default_factory=dict)
    lags_seconds: list[float] = field(default_factory=list)
    never_readable: int = 0

    def add(self, run_id: str, sent_at: float) -> None:
        self.pending[run_id] = sent_at

    def record(self, readable: set[str], now: float) -> None:
        for run_id in list(self.pending):
            if run_id in readable:
                self.lags_seconds.append(now - self.pending.pop(run_id))

    def expire(self, now: float) -> None:
        for run_id, sent_at in list(self.pending.items()):
            if now - sent_at > self.deadline_seconds:
                del self.pending[run_id]
                self.never_readable += 1

    async def poll(
        self,
        readable: Callable[[list[str]], Awaitable[set[str]]],
        now: Callable[[], float],
        interval_seconds: float,
        finished: asyncio.Event,
    ) -> None:
        """Check pending runs every interval until `finished` is set and none is left pending."""
        while not (finished.is_set() and not self.pending):
            await asyncio.sleep(interval_seconds)
            ids = list(self.pending)
            for start in range(0, len(ids), BATCH):
                found = await readable(ids[start : start + BATCH])
                self.record(found, now())
            self.expire(now())
