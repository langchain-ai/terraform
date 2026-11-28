"""Open-loop scheduling: start work on a clock, whatever happened to earlier work."""

from __future__ import annotations

import asyncio
import math
from collections.abc import Callable, Coroutine
from dataclasses import dataclass, field
from typing import Any


def start_offset(index: int, rate: float, ramp_seconds: float) -> float:
    """Seconds after the start at which start number `index` (0-based) is due.

    The rate climbs linearly from zero to `rate` over the ramp and holds. The count due by time t is
    rate * t^2 / (2 * ramp) during the ramp and rate * (t - ramp / 2) after it, inverted here, so
    the first start is at 0 and the average rate over the ramp is half the target.
    """
    ramp_starts = rate * ramp_seconds / 2
    if index < ramp_starts:
        return math.sqrt(2 * index * ramp_seconds / rate)
    return index / rate + ramp_seconds / 2


@dataclass
class OpenLoopStats:
    scheduled: int = 0
    started: int = 0
    dropped: int = 0
    lags_seconds: list[float] = field(default_factory=list)


async def open_loop(
    rate: float,
    ramp_seconds: float,
    total_seconds: float,
    start: Callable[[int], Coroutine[Any, Any, None]],
    max_in_flight: int,
    limit: int | None = None,
) -> OpenLoopStats:
    """Start `start(number)` at each due time until `total_seconds` or `limit` starts.

    A start that is due while `max_in_flight` are still running is dropped and counted, never
    delayed: delaying it would turn this back into a closed loop that slows when the server does.
    A start the loop is late for runs at once, so the offered load keeps its schedule, and the
    lateness is recorded.
    """
    loop = asyncio.get_running_loop()
    origin = loop.time()
    stats = OpenLoopStats()
    running: set[asyncio.Task[None]] = set()
    while limit is None or stats.scheduled < limit:
        offset = start_offset(stats.scheduled, rate, ramp_seconds)
        if offset >= total_seconds:
            break
        await asyncio.sleep(max(0.0, origin + offset - loop.time()))
        stats.scheduled += 1
        stats.lags_seconds.append(max(0.0, loop.time() - (origin + offset)))
        if len(running) >= max_in_flight:
            stats.dropped += 1
            continue
        stats.started += 1
        task = asyncio.create_task(start(stats.scheduled))
        running.add(task)
        task.add_done_callback(running.discard)
    if running:
        await asyncio.gather(*running)
    return stats
