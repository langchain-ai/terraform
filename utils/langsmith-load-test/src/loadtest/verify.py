"""Runs sent against runs stored: count what the test's projects hold for its id."""

from __future__ import annotations

import asyncio
import datetime
import time
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Any
from uuid import UUID

from langsmith import Client
from loadtest.reads import run_filter

SETTLE_POLL_SECONDS = 5.0
PAGE_SIZE = 1000


async def _count(client: Client, **query: Any) -> int:
    """Runs a client.runs.query matches, a page of ids at a time."""
    total, after = 0, dict[str, Any]()
    while True:
        page = await client.runs.query(**query, **after, page_size=PAGE_SIZE, selects=["ID"])
        total += len(page.items or [])
        if not page.next_cursor:
            return total
        after = {"cursor": page.next_cursor}


async def stored_counts(client: Client, project_ids: Sequence[UUID], test_id: str, since: datetime.datetime) -> tuple[int, int]:
    """(traces, runs) stored for the test: client.runs.query twice, roots only and all, counted by listing.

    Every run carries the test's id in its metadata, so a filter on it counts the test's own runs
    in a project that holds other data too. POST /runs/stats (Client.get_run_stats) answered 0 for
    runs SmithDB had stored and runs.query returned (LangSmith 0.18 on SmithDB, magus, 2026-11-25).
    ponytail: one id per run read, fine to about 100,000 runs a test; a SmithDB count endpoint is the
    upgrade path.
    """
    query = {"project_ids": [str(p) for p in project_ids], "filter": run_filter(test_id), "min_start_time": since}
    return await _count(client, **query, is_root=True), await _count(client, **query)


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
