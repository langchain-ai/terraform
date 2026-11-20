"""Runs sent against runs stored: count what the test's projects hold for its id."""

from __future__ import annotations

import asyncio
import datetime
import functools
import time
from collections.abc import Sequence
from dataclasses import dataclass
from uuid import UUID

from langsmith import Client
from loadtest.reads import run_filter

SETTLE_POLL_SECONDS = 5.0


async def stored_counts(client: Client, project_ids: Sequence[UUID], test_id: str, since: datetime.datetime) -> tuple[int, int]:
    """(traces, runs) stored for the test: Client.get_run_stats (POST /runs/stats) twice, roots only and all.

    Every run carries the test's id in its metadata, so a filter on it counts the test's own runs
    in a project that holds other data too.
    """
    stats = functools.partial(
        client.get_run_stats, project_ids=[str(p) for p in project_ids], start_time=since.isoformat(), filter=run_filter(test_id),
    )
    roots = await asyncio.to_thread(stats, is_root=True)
    everything = await asyncio.to_thread(stats)
    return int(roots["run_count"]), int(everything["run_count"])


@dataclass
class Stored:
    traces: int | None = None
    runs: int | None = None
    error: str | None = None


async def settle(
    client: Client, project_ids: Sequence[UUID], test_id: str, since: datetime.datetime, runs_sent: int, settle_seconds: float,
) -> Stored:
    """Count stored runs until they reach `runs_sent` or the settle period ends, whichever is first."""
    stored = Stored()
    deadline = time.monotonic() + settle_seconds
    while True:
        try:
            stored.traces, stored.runs = await stored_counts(client, project_ids, test_id, since)
            stored.error = None
        except Exception as error:  # noqa: BLE001 - an unverifiable count is reported, not guessed
            stored.error = f"{type(error).__name__}: {' '.join(str(error).splitlines())[:300]}"
        if stored.runs is not None and stored.runs >= runs_sent:
            return stored
        if time.monotonic() >= deadline:
            return stored
        await asyncio.sleep(min(SETTLE_POLL_SECONDS, max(0.0, deadline - time.monotonic())))
