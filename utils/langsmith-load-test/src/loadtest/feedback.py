"""Feedback on the traces sent, on its own threads, counted and drained after the load.

Awaited in the trace path, feedback made each trace wait a server round trip, so the offered rate
fell as the server slowed (Hari Narayan's design in terraform #469 moved it off the loop; Dzmitry
Dubarau's review of #488 capped the threads at WORKERS).
"""

from __future__ import annotations

import asyncio
import functools
from concurrent.futures import ThreadPoolExecutor
from typing import Any
from uuid import UUID

from langsmith import Client
from loadtest import results
from loadtest.draw import share_due
from loadtest.reads import FEEDBACK_KEY

WORKERS = 32


class FeedbackSender:
    def __init__(self, client: Client, project_id: UUID, per_trace: float, counts: results.WriteCounts) -> None:
        self._client = client
        self._project_id = project_id
        self._per_trace = per_trace
        self._counts = counts
        self._pool = ThreadPoolExecutor(max_workers=WORKERS, thread_name_prefix="feedback")
        self._pending: set[asyncio.Future[Any]] = set()

    def send(self, trace_id: UUID, number: int) -> None:
        """The feedback due on trace `number`, started without waiting for it."""
        loop = asyncio.get_running_loop()
        for _ in range(share_due(self._per_trace, number)):
            sent = loop.run_in_executor(
                self._pool,
                functools.partial(
                    self._client.create_feedback, run_id=trace_id, trace_id=trace_id, session_id=self._project_id,
                    key=FEEDBACK_KEY, score=1.0,
                ),
            )
            self._pending.add(sent)
            sent.add_done_callback(self._done)

    def _done(self, done: asyncio.Future[Any]) -> None:
        self._pending.discard(done)
        error = None if done.cancelled() else done.exception()
        if done.cancelled() or error is not None:
            self._counts.feedback_errors += 1
            self._counts.first_error = self._counts.first_error or str(error or "feedback cancelled")
        else:
            self._counts.feedback_sent += 1

    async def drain(self, seconds: float) -> None:
        """Wait for what is still in flight, then cancel the rest, each counted as an error.

        Waited for without a limit, a stalled server hung the run after the load had finished.
        """
        if not self._pending:
            return
        _, stalled = await asyncio.wait(set(self._pending), timeout=seconds)
        if stalled:
            self._counts.first_error = self._counts.first_error or (
                f"{len(stalled)} feedback calls still pending {seconds:g} s after the load"
            )
            for future in stalled:
                future.cancel()
            await asyncio.sleep(0)

    def close(self) -> None:
        self._pool.shutdown(wait=False, cancel_futures=True)
