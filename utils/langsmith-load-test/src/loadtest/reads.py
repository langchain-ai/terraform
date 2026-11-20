"""Read load: the five classes the sizing model weights, sent with the pinned langsmith SDK.

Each class is one SDK call (the SDK's v2 resources, which call the instance's /api/v2/ endpoints;
an instance without them answers not found, and those reads count as errors). Reads touch the test's projects, the busier ones more often; heavy_filter also filters on the test's id.
"""

from __future__ import annotations

import asyncio
import datetime
import random
import time
from collections import deque
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import TYPE_CHECKING
from uuid import UUID

from langsmith import Client
from loadtest.draw import Projects, weighted_choice
from loadtest.stats import summarize

if TYPE_CHECKING:
    # The SDK exports the select names only from its generated client; typed here, a rename fails mypy, not a run.
    from langsmith._openapi_client.types.run_select_field import RunSelectField

FEEDBACK_KEY = "load_test_feedback"
LIST_SELECTS: list[RunSelectField] = ["ID", "NAME", "START_TIME", "END_TIME", "STATUS"]
TRACE_SELECTS: list[RunSelectField] = [
    "ID", "NAME", "RUN_TYPE", "STATUS", "START_TIME", "END_TIME", "PARENT_RUN_IDS", "DOTTED_ORDER",
    "INPUTS_PREVIEW", "OUTPUTS_PREVIEW",
]
# A read of a known trace names a window around its start so the store can prune.
TRACE_WINDOW = datetime.timedelta(minutes=5)
LIST_LIMIT = 20
POOL_LIMIT = 2000


def run_filter(test_id: str) -> str:
    return f'and(eq(metadata_key, "load_test_id"), eq(metadata_value, "{test_id}"))'


@dataclass
class TracePool:
    """Traces old enough to be stored: a read of a trace still in flight would count as an error."""

    min_age_seconds: float
    fresh: deque[tuple[float, str, datetime.datetime, str]] = field(default_factory=deque)
    aged: list[tuple[str, datetime.datetime, str]] = field(default_factory=list)

    def add(self, trace_id: str, sent_at: float, started: datetime.datetime, project_id: str) -> None:
        self.fresh.append((sent_at, trace_id, started, project_id))

    def pick(self, now: float, random_source: random.Random) -> tuple[str, datetime.datetime, str] | None:
        """(trace id, start, its project id) of a trace old enough to read."""
        while self.fresh and now - self.fresh[0][0] >= self.min_age_seconds:
            _, trace_id, started, project_id = self.fresh.popleft()
            self.aged.append((trace_id, started, project_id))
        if len(self.aged) > 2 * POOL_LIMIT:
            del self.aged[:-POOL_LIMIT]
        return random_source.choice(self.aged) if self.aged else None


@dataclass
class ClassStats:
    component: str
    latencies_seconds: list[float] = field(default_factory=list)
    errors: int = 0
    skipped: int = 0
    first_error: str | None = None

    def report(self) -> dict[str, object]:
        latency = summarize(self.latencies_seconds)
        return {
            "component": self.component, "count": latency["count"], "errors": self.errors, "skipped": self.skipped,
            "p50_seconds": latency["p50"], "p95_seconds": latency["p95"], "p99_seconds": latency["p99"],
            "first_error": self.first_error,
        }


class Reader:
    def __init__(
        self, client: Client, projects: Projects, test_id: str, started: datetime.datetime,
        profile_mix: dict[str, dict[str, object]], heavy_window_days: float, pool: TracePool, seed: int | None,
    ) -> None:
        self.client = client
        self.projects = projects
        self.test_id = test_id
        self.started = started
        self.weights = {name: float(entry["weight"]) for name, entry in profile_mix.items()}  # type: ignore[arg-type]
        self.heavy_window = datetime.timedelta(days=heavy_window_days)
        self.pool = pool
        self.random_source = random.Random(seed)
        self.stats = {name: ClassStats(str(entry.get("component", ""))) for name, entry in profile_mix.items()}
        self.calls: dict[str, Callable[[], Awaitable[object]]] = {
            "list_traces": self.list_traces, "read_trace": self.read_trace, "project_stats": self.project_stats,
            "feedback_stats": self.feedback_stats, "heavy_filter": self.heavy_filter,
        }

    def _project(self) -> str:
        """A project drawn as traces are written to them, so reads land where the writes are."""
        return str(self.projects.ids[self.projects.pick(self.random_source)])

    async def list_traces(self) -> object:
        # client.traces.query: the most recent root traces of the project, one page.
        return await self.client.traces.query(
            project_id=self._project(), min_start_time=self.started, page_size=LIST_LIMIT, selects=LIST_SELECTS,
        )

    async def read_trace(self) -> object:
        # client.traces.list_runs: every run of one trace, the call behind opening a trace.
        picked = self.pool.pick(time.monotonic(), self.random_source)
        if picked is None:
            return None
        trace_id, started, project_id = picked
        return await self.client.traces.list_runs(
            trace_id, project_id=project_id, min_start_time=started - TRACE_WINDOW,
            max_start_time=started + TRACE_WINDOW, selects=TRACE_SELECTS,
        )

    async def project_stats(self) -> object:
        # Client.read_project(include_stats=True): the project row with run count, latency and error rate.
        return await asyncio.to_thread(self.client.read_project, project_id=self._project(), include_stats=True)

    async def feedback_stats(self) -> object:
        # The SDK has no feedback-statistics method. Client.get_run_stats (POST /runs/stats) over the
        # project's root runs that carry the test's feedback key returns run_count and feedback_stats.
        return await asyncio.to_thread(
            self.client.get_run_stats, project_ids=list[UUID | str](self.projects.ids), is_root=True,
            start_time=self.started.isoformat(), filter=f'eq(feedback_key, "{FEEDBACK_KEY}")',
        )

    async def heavy_filter(self) -> object:
        # client.runs.query: a metadata filter on the test's id across the heavy window.
        now = datetime.datetime.now(datetime.UTC)
        return await self.client.runs.query(
            project_ids=self.projects.id_strings, is_root=True, filter=run_filter(self.test_id),
            min_start_time=now - self.heavy_window, max_start_time=now, page_size=LIST_LIMIT, selects=LIST_SELECTS,
        )

    async def read(self, _number: int) -> None:
        name = weighted_choice(self.weights, self.random_source)
        stats = self.stats[name]
        started = time.monotonic()
        try:
            result = await self.calls[name]()
        except Exception as error:  # noqa: BLE001 - a failed read is counted, never fatal to the load
            stats.errors += 1
            stats.first_error = stats.first_error or f"{type(error).__name__}: {' '.join(str(error).splitlines())[:300]}"
            return
        if result is None:
            stats.skipped += 1
            return
        stats.latencies_seconds.append(time.monotonic() - started)
