"""Run a local echo agent concurrently and collect timing and error counts."""

from __future__ import annotations

import asyncio
import math
from collections.abc import Callable
from contextlib import nullcontext, suppress
from dataclasses import dataclass, field
from uuid import UUID, uuid4

from langchain_core.tracers.context import tracing_v2_enabled
from langsmith import Client

from loadtest.echo_agent import PAYLOAD_KEY, create_echo_agent
from loadtest.payloads.generator import PayloadGenerator


@dataclass
class LoadSettings:
    users: int = 10
    duration_seconds: float = 10
    ramp_up_seconds: float = 0
    run_limit: int | None = None
    pause_seconds: float = 0
    simulated_delay_ms: float = 0
    feedback_percent: float = 50
    data_seed: int | None = None
    latency_limit_seconds: float | None = None
    progress_seconds: float = 10

    def __post_init__(self) -> None:
        for name in ("users", "duration_seconds", "run_limit", "latency_limit_seconds"):
            value = getattr(self, name)
            if value is not None and (not math.isfinite(value) or value <= 0):
                raise ValueError(f"--{name.replace('_', '-')} must be greater than zero and finite")
        for name in ("ramp_up_seconds", "pause_seconds", "simulated_delay_ms", "progress_seconds"):
            value = getattr(self, name)
            if not math.isfinite(value) or value < 0:
                raise ValueError(f"--{name.replace('_', '-')} must be zero or greater and finite")
        if not 0 <= self.feedback_percent <= 100:
            raise ValueError("--feedback-percent must be between 0 and 100")


@dataclass
class LoadResult:
    duration_seconds: float = 0
    latencies_seconds: list[float] = field(default_factory=list)
    run_errors: int = 0
    feedback_queued: int = 0
    feedback_errors: int = 0
    first_error: str | None = None

    def report(self) -> dict:
        latencies = sorted(self.latencies_seconds)
        runs = len(latencies)

        def percentile(percent: int) -> float | None:
            return latencies[round(percent / 100 * (runs - 1))] if runs else None

        return {
            "runs": runs,
            "run_errors": self.run_errors,
            "duration_seconds": self.duration_seconds,
            "runs_per_second": runs / self.duration_seconds if self.duration_seconds else 0,
            "latency_p50_seconds": percentile(50),
            "latency_p95_seconds": percentile(95),
            "latency_p99_seconds": percentile(99),
            "feedback_queued": self.feedback_queued,
            "feedback_errors": self.feedback_errors,
            "first_error": self.first_error,
        }


async def run_load_test(
    settings: LoadSettings,
    client: Client | None,
    project_name: str,
    project_id: UUID | None,
    on_progress: Callable[[int, int, float], None] | None = None,
) -> LoadResult:
    payloads = PayloadGenerator(settings.data_seed)
    # Generate the cached documents before measuring run times.
    await asyncio.to_thread(payloads.prepare)
    agent = create_echo_agent(payloads)
    result = LoadResult()
    loop = asyncio.get_running_loop()
    started_at = loop.time()
    deadline = started_at + settings.ramp_up_seconds + settings.duration_seconds
    scheduled_runs = 0
    test_id = uuid4()

    async def report_progress() -> None:
        while True:
            await asyncio.sleep(settings.progress_seconds)
            on_progress(
                len(result.latencies_seconds), result.run_errors + result.feedback_errors,
                loop.time() - started_at,
            )

    async def run_user(user_number: int) -> None:
        nonlocal scheduled_runs
        await asyncio.sleep(settings.ramp_up_seconds * user_number / settings.users)
        while loop.time() < deadline:
            if settings.run_limit is not None and scheduled_runs >= settings.run_limit:
                return
            scheduled_runs += 1
            # Reserve the sequence before yielding so concurrent users cannot share it.
            trace_number = scheduled_runs
            run_started_at = loop.time()
            try:
                # Yield even with zero delay so all simulated users can make progress.
                await asyncio.sleep(settings.simulated_delay_ms / 1000)
                payload = payloads.next_payload()
                run_id = uuid4()
                await agent.ainvoke(
                    {
                        "messages": [{"role": "user", "content": f"Load test run number {trace_number}."}],
                        PAYLOAD_KEY: payload.inputs,
                    },
                    {
                        "run_id": run_id,
                        "configurable": {"thread_id": f"{test_id}-run-{trace_number}"},
                        "tags": ["load-test", "payload:json", f"profile:{payload.size_name}"],
                        "metadata": {
                            "load_test": True,
                            "load_test_sequence": trace_number,
                            "load_test_payload_profile": payload.size_name,
                            "load_test_source_bytes": payload.input_bytes,
                        },
                    },
                )
                # Spread feedback evenly instead of leaving short runs to chance.
                if client is not None and trace_number * settings.feedback_percent // 100 > (
                    (trace_number - 1) * settings.feedback_percent // 100
                ):
                    try:
                        client.create_feedback(
                            run_id=run_id, trace_id=run_id, session_id=project_id,
                            key="load_test_feedback", score=1.0,
                        )
                        result.feedback_queued += 1
                    except Exception as error:  # noqa: BLE001 - count feedback failures separately
                        result.feedback_errors += 1
                        result.first_error = result.first_error or str(error)
            except Exception as error:  # noqa: BLE001 - record a failed attempt and continue the load
                result.run_errors += 1
                result.first_error = result.first_error or str(error)
            result.latencies_seconds.append(loop.time() - run_started_at)
            if settings.run_limit is not None and scheduled_runs >= settings.run_limit:
                return
            await asyncio.sleep(min(settings.pause_seconds, max(0, deadline - loop.time())))

    progress_task = None
    if on_progress is not None and settings.progress_seconds > 0:
        progress_task = asyncio.create_task(report_progress())
    try:
        tracing = tracing_v2_enabled(project_name=project_name, client=client) if client else nullcontext()
        with tracing:
            await asyncio.gather(*(run_user(user_number) for user_number in range(settings.users)))
    finally:
        if progress_task is not None:
            progress_task.cancel()
            with suppress(asyncio.CancelledError):
                await progress_task
    result.duration_seconds = loop.time() - started_at
    return result
