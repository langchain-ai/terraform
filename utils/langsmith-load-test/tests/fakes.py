"""A fake langsmith Client for tests that run the whole load path with no network.

It subclasses the real Client (RunTree insists on one) without calling its constructor, and it
records what the tool sends: runs created and patched, feedback, and every read. What the project
"stores" is derived from the recorded runs, so a count a test checks was not computed by the
tool's own code.
"""

from __future__ import annotations

import threading
from collections.abc import Callable
from types import SimpleNamespace
from typing import Any

from langsmith import Client


class FakeClient(Client):
    def __init__(self) -> None:  # noqa: D107 - the real constructor would open a connection
        self.lock = threading.Lock()
        self.events: list[str] = []
        self.created: list[dict[str, Any]] = []
        self.patched: list[dict[str, Any]] = []
        self.feedback: list[dict[str, Any]] = []
        self.queries: list[dict[str, Any]] = []
        self.stats_calls: list[dict[str, Any]] = []
        self.readable = True
        self.create_run_error: Exception | None = None
        self.stats_error: Exception | None = None
        self.on_feedback: Callable[[int], None] = lambda number: None
        self.runs_resource = SimpleNamespace(query=self._runs_query)
        self.traces_resource = SimpleNamespace(query=self._unused, list_runs=self._unused)
        self.info_reads = 0

    @property  # type: ignore[override]
    def runs(self) -> Any:
        return self.runs_resource

    @property  # type: ignore[override]
    def traces(self) -> Any:
        return self.traces_resource

    @property  # type: ignore[override]
    def info(self) -> dict[str, Any]:
        self.info_reads += 1
        return {}

    async def _unused(self, *args: Any, **kwargs: Any) -> Any:
        raise AssertionError("not used by the write path")

    async def _runs_query(self, **kwargs: Any) -> Any:
        self.queries.append(kwargs)
        ids = kwargs["ids"] if self.readable else []
        return SimpleNamespace(items=[SimpleNamespace(id=run_id) for run_id in ids])

    def create_run(self, **kwargs: Any) -> None:
        if self.create_run_error:
            raise self.create_run_error
        with self.lock:
            self.created.append(kwargs)

    def update_run(self, **kwargs: Any) -> None:
        with self.lock:
            self.patched.append(kwargs)

    def create_feedback(self, **kwargs: Any) -> None:
        with self.lock:
            self.feedback.append(kwargs)
            number = len(self.feedback)
        self.on_feedback(number)

    def flush(self, timeout: float | None = None) -> None:
        self.events.append("flush")

    def get_run_stats(self, **kwargs: Any) -> dict[str, Any]:
        self.events.append("stats")
        self.stats_calls.append(kwargs)
        if self.stats_error:
            raise self.stats_error
        ours = [run for run in self.created if "load_test_id" in run["extra"]["metadata"]]
        runs = [run for run in ours if kwargs.get("is_root") is not True or run.get("parent_run_id") is None]
        return {"run_count": len(runs)}

    def read_project(self, **kwargs: Any) -> Any:
        return SimpleNamespace(run_count=0)
