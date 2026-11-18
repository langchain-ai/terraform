"""Send traces at a rate or from concurrent users, read them back, and collect what the test saw."""

from __future__ import annotations

import asyncio
import dataclasses
import datetime
import math
import time
from collections.abc import Callable
from contextlib import suppress
from dataclasses import dataclass, field
from typing import Any
from uuid import UUID, uuid4

from langsmith import Client
from langsmith.run_trees import RunTree
from loadtest import results
from loadtest.draw import share_due
from loadtest.feedback import FeedbackSender
from loadtest.lag import LagTracker
from loadtest.payloads.generator import PayloadGenerator, RunPayload
from loadtest.profile import Profile
from loadtest.reads import Reader, TracePool
from loadtest.schedule import open_loop
from loadtest.stats import summarize
from loadtest.verify import Stored, settle

READ_BATCH_WINDOW = datetime.timedelta(minutes=1)


@dataclass
class LoadSettings:
    users: int = 10
    duration_seconds: float = 10
    ramp_up_seconds: float = 0
    run_limit: int | None = None
    pause_seconds: float = 0
    simulated_delay_ms: float = 0
    traces_per_second: float | None = None
    max_in_flight: int = 256
    data_seed: int | None = None
    latency_limit_seconds: float | None = None
    progress_seconds: float = 10
    feedback_drain_seconds: float = 60
    read: bool = False
    reads_per_second: float | None = None
    read_min_age_seconds: float = 60
    lag_sample: float = 0.05
    lag_deadline_seconds: float = 120
    lag_poll_seconds: float = 2
    settle_seconds: float = 60

    def __post_init__(self) -> None:
        for name in (
            "users", "duration_seconds", "run_limit", "latency_limit_seconds", "feedback_drain_seconds",
            "traces_per_second", "max_in_flight", "reads_per_second", "lag_deadline_seconds", "lag_poll_seconds",
        ):
            value = getattr(self, name)
            if value is not None and (not math.isfinite(value) or value <= 0):
                raise ValueError(f"--{name.replace('_', '-')} must be greater than zero and finite")
        for name in (
            "ramp_up_seconds", "pause_seconds", "simulated_delay_ms", "progress_seconds", "settle_seconds",
            "read_min_age_seconds",
        ):
            value = getattr(self, name)
            if not math.isfinite(value) or value < 0:
                raise ValueError(f"--{name.replace('_', '-')} must be zero or greater and finite")
        if not 0 <= self.lag_sample <= 1:
            raise ValueError("--lag-sample must be between 0 and 1")
        if self.read and self.reads_per_second is None:
            raise ValueError("--read needs a rate: --reads-per-second, or a --profile with read.requests_per_second above zero")


@dataclass
class LoadOutcome:
    test_id: str
    started_at: datetime.datetime
    ended_at: datetime.datetime
    write: results.WriteCounts
    reader: Reader | None
    read_dropped: int
    read_lags_seconds: list[float]
    lag: LagTracker
    lag_poll_errors: int
    lag_sampled: int
    stored: Stored
    read_mix: dict[str, Any] = field(default_factory=dict)


def post_trace(client: Client, project_name: str, trace_id: UUID, number: int, test_id: str, payloads: list[RunPayload]) -> None:
    """One root run with its children, each carrying its own text; every run carries the test's id."""
    metadata = {"load_test": True, "load_test_id": test_id, "load_test_sequence": number}
    root_payload = payloads[0]
    root = RunTree(
        name="load-test-trace", run_type="chain", id=trace_id, inputs=root_payload.inputs, project_name=project_name,
        ls_client=client, extra={"metadata": {**metadata, "load_test_payload_profile": root_payload.size_name}},
        tags=["load-test", f"profile:{root_payload.size_name}"],
    )
    root.post()
    for position, payload in enumerate(payloads[1:], start=1):
        child = root.create_child(name=f"step-{position}", run_type="llm" if position % 2 else "tool", inputs=payload.inputs)
        child.post()
        child.end(outputs=payload.outputs)
        child.patch()
    root.end(outputs=root_payload.outputs)
    root.patch()


async def run_load_test(
    settings: LoadSettings,
    profile: Profile,
    client: Client | None,
    project_name: str,
    project_id: UUID | None,
    on_progress: Callable[[int, int, float], None] | None = None,
) -> LoadOutcome:
    generator = PayloadGenerator(profile.mix, profile.sizes_kib, settings.data_seed)
    counts = results.WriteCounts(
        mode="open-loop" if settings.traces_per_second else "closed-loop", target_traces_per_second=settings.traces_per_second,
    )
    loop = asyncio.get_running_loop()
    test_id = str(uuid4())
    started_at = datetime.datetime.now(datetime.UTC)
    total_seconds = settings.ramp_up_seconds + settings.duration_seconds
    pool = TracePool(settings.read_min_age_seconds)
    lag = LagTracker(settings.lag_deadline_seconds)
    lag_state = {"sampled": 0, "poll_errors": 0}
    reader: Reader | None = None
    if client is not None and project_id is not None:
        # Touch the SDK's lazily fetched server info here: the first read would otherwise do it
        # as a blocking call on the event loop.
        await asyncio.to_thread(lambda: client.info)
        if settings.read:
            reader = Reader(
                client, project_id, test_id, started_at, profile.read_mix, profile.heavy_window_days, pool, settings.data_seed,
            )
    feedback = FeedbackSender(client, project_id, profile.feedback_per_trace, counts) if client is not None and project_id is not None else None

    async def one_trace(number: int) -> None:
        run_count = max(1, share_due(profile.runs_per_trace, number))
        try:
            payloads = await asyncio.to_thread(lambda: [generator.next_run() for _ in range(run_count)])
            await asyncio.sleep(settings.simulated_delay_ms / 1000)
            trace_id = uuid4()
            sent_at = time.monotonic()
            if client is not None:
                await asyncio.to_thread(post_trace, client, project_name, trace_id, number, test_id, payloads)
            counts.send_latencies_seconds.append(time.monotonic() - sent_at)
            counts.traces_sent += 1
            # Starts on the ramp offer half the target on average; the rate a plan is judged on is
            # the one held after it (schedule.start_offset fixes which starts those are).
            if settings.traces_per_second and number - 1 >= settings.traces_per_second * settings.ramp_up_seconds / 2:
                counts.steady_traces_sent += 1
            counts.runs_sent += run_count
            if client is not None:
                pool.add(str(trace_id), sent_at, datetime.datetime.now(datetime.UTC))
                if share_due(settings.lag_sample, number):
                    lag.add(str(trace_id), sent_at)
                    lag_state["sampled"] += 1
                if feedback is not None:
                    feedback.send(trace_id, number)
        except Exception as error:  # noqa: BLE001 - record a failed trace and continue the load
            counts.run_errors += 1
            counts.first_error = counts.first_error or str(error)

    async def run_user(user_number: int) -> None:
        await asyncio.sleep(settings.ramp_up_seconds * user_number / settings.users)
        while loop.time() < deadline:
            if settings.run_limit is not None and counts.traces_started >= settings.run_limit:
                return
            counts.traces_started += 1
            await one_trace(counts.traces_started)
            await asyncio.sleep(min(settings.pause_seconds, max(0, deadline - loop.time())))

    async def readable(ids: list[str]) -> set[str]:
        assert client is not None
        try:
            page = await client.runs.query(
                project_ids=[str(project_id)], ids=ids, min_start_time=started_at - READ_BATCH_WINDOW,
                page_size=len(ids), selects=["ID"],
            )
        except Exception as error:  # noqa: BLE001 - a failed check is counted; the run stays pending until its deadline
            lag_state["poll_errors"] += 1
            counts.first_error = counts.first_error or f"lag check: {error}"
            return set()
        return {str(run.id) for run in page.items or []}

    async def report_progress() -> None:
        assert on_progress is not None
        while True:
            await asyncio.sleep(settings.progress_seconds)
            on_progress(counts.traces_sent, counts.run_errors + counts.feedback_errors, loop.time() - origin)

    origin = loop.time()
    deadline = origin + total_seconds
    finished = asyncio.Event()
    poll_task = None
    if client is not None and settings.lag_sample > 0:
        poll_task = asyncio.create_task(lag.poll(readable, time.monotonic, settings.lag_poll_seconds, finished))
    progress_task = None
    if on_progress is not None and settings.progress_seconds > 0:
        progress_task = asyncio.create_task(report_progress())
    read_dropped = 0
    read_lags: list[float] = []
    try:
        load: list[Any] = []
        if settings.traces_per_second:
            load.append(open_loop(
                settings.traces_per_second, settings.ramp_up_seconds, total_seconds, one_trace,
                settings.max_in_flight, settings.run_limit,
            ))
        else:
            load.extend(run_user(user) for user in range(settings.users))
        if reader is not None and settings.reads_per_second:
            load.append(open_loop(
                settings.reads_per_second, settings.ramp_up_seconds, total_seconds, reader.read, settings.max_in_flight,
            ))
        outcomes = await asyncio.gather(*load)
        counts.duration_seconds = loop.time() - origin
        if settings.traces_per_second:
            write_loop = outcomes[0]
            counts.traces_started = write_loop.started
            counts.dropped_starts = write_loop.dropped
            counts.schedule_lags_seconds = write_loop.lags_seconds
        if reader is not None and settings.reads_per_second:
            read_dropped = outcomes[-1].dropped
            read_lags = outcomes[-1].lags_seconds
        if feedback is not None:
            await feedback.drain(settings.feedback_drain_seconds)
        stored = Stored()
        if client is not None and project_id is not None:
            await asyncio.to_thread(client.flush)
            finished.set()
            if poll_task is not None:
                await poll_task
            stored = await settle(client, project_id, test_id, started_at - READ_BATCH_WINDOW, counts.runs_sent, settings.settle_seconds)
    finally:
        finished.set()
        if feedback is not None:
            feedback.close()
        for task in (progress_task, poll_task):
            if task is not None:
                task.cancel()
                with suppress(asyncio.CancelledError):
                    await task
    return LoadOutcome(
        test_id, started_at, datetime.datetime.now(datetime.UTC), counts, reader, read_dropped, read_lags,
        lag, lag_state["poll_errors"], lag_state["sampled"], stored,
    )


def build_report(
    outcome: LoadOutcome, settings: LoadSettings, profile: Profile, project_name: str, tracing_enabled: bool,
    upload_errors: int, first_upload_error: str | None, app_version: str | None = None,
) -> dict[str, Any]:
    write = outcome.write
    send = summarize(write.send_latencies_seconds)
    schedule = summarize(write.schedule_lags_seconds)
    limit = settings.latency_limit_seconds
    limit_passed = None if limit is None else (send["p95"] is not None and send["p95"] <= limit)
    lag = summarize(outcome.lag.lags_seconds)
    reads = outcome.reader.stats if outcome.reader else {}
    read_count = sum(len(entry.latencies_seconds) + entry.errors for entry in reads.values())
    stored = outcome.stored
    missing_runs = None if stored.runs is None else max(0, write.runs_sent - stored.runs)
    missing_traces = None if stored.traces is None else max(0, write.traces_sent - stored.traces)
    return results.assemble(
        server={"app_version": app_version},
        profile=profile.document, settings=dataclasses.asdict(settings), test_id=outcome.test_id, project=project_name,
        started_at=outcome.started_at.isoformat(), ended_at=outcome.ended_at.isoformat(),
        write={
            "mode": write.mode, "tracing_enabled": tracing_enabled,
            "target_traces_per_second": write.target_traces_per_second,
            "achieved_traces_per_second": write.traces_sent / write.duration_seconds if write.duration_seconds else 0,
            "steady_traces_per_second": write.steady_traces_sent / settings.duration_seconds if write.mode == "open-loop" and settings.duration_seconds else None,
            "duration_seconds": write.duration_seconds, "traces_started": write.traces_started,
            "traces_sent": write.traces_sent, "runs_sent": write.runs_sent, "run_errors": write.run_errors,
            "dropped_starts": write.dropped_starts,
            "send_latency_seconds": {key: send[key] for key in ("p50", "p95", "p99", "max")},
            "schedule_lag_seconds": {key: schedule[key] for key in ("p50", "p95", "p99", "max")},
            "first_error": write.first_error or first_upload_error,
        },
        feedback={"per_trace": profile.feedback_per_trace, "sent": write.feedback_sent, "errors": write.feedback_errors},
        reads={
            "enabled": outcome.reader is not None, "target_requests_per_second": settings.reads_per_second,
            "achieved_requests_per_second": read_count / write.duration_seconds if write.duration_seconds else 0,
            "dropped": outcome.read_dropped, "classes": {name: entry.report() for name, entry in reads.items()},
        },
        lag={
            "sample_share": settings.lag_sample, "sampled": outcome.lag_sampled, "readable": len(outcome.lag.lags_seconds),
            "never_readable": outcome.lag.never_readable, "deadline_seconds": settings.lag_deadline_seconds,
            "poll_errors": outcome.lag_poll_errors, "p50_seconds": lag["p50"], "p95_seconds": lag["p95"],
            "p99_seconds": lag["p99"], "max_seconds": lag["max"],
        },
        stored={
            "settle_seconds": settings.settle_seconds, "traces_sent": write.traces_sent, "traces_stored": stored.traces,
            "traces_missing": missing_traces, "runs_sent": write.runs_sent, "runs_stored": stored.runs,
            "missing_runs": missing_runs, "error": stored.error,
        },
        targets=profile.targets, upload_errors=upload_errors, latency_limit_passed=limit_passed,
    )
