"""Send traces at a rate or from concurrent users, read them back, and collect what the test saw."""

from __future__ import annotations

import asyncio
import dataclasses
import datetime
import math
import random
import time
from collections.abc import Callable
from contextlib import suppress
from dataclasses import dataclass, field
from typing import Any
from urllib.parse import urlsplit
from uuid import UUID, uuid4

from langsmith import Client
from langsmith.run_trees import RunTree
from loadtest import results
from loadtest.draw import Projects, share_due
from loadtest.feedback import FeedbackSender
from loadtest.lag import LagTracker
from loadtest.payloads.generator import PayloadGenerator, RunPayload
from loadtest.profile import Profile
from loadtest.reads import Reader, TracePool
from loadtest.schedule import open_loop
from loadtest.stats import summarize
from loadtest.verify import Stored, settle

READ_BATCH_WINDOW = datetime.timedelta(minutes=1)
# The endpoint is probed with a TCP connect this often, and the run ends after this many misses in a
# row: when a laptop slept, its tunnel to the install closed and the SDK retried every upload for the
# rest of the run, printing each payload (magus, 2026-11-25).
ENDPOINT_PROBE_SECONDS = 10.0
ENDPOINT_GONE_AFTER = 3


class EndpointGone(RuntimeError):
    """The install's endpoint stopped taking connections during the run."""
HIGH_CARDINALITY_EVERY = 5
LOW_CARDINALITY_VALUES = 8


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


def trace_metadata(test_id: str, number: int, keys: int) -> dict[str, Any]:
    """The test's own keys, then `keys` more as an application tags its runs: every fifth a per-trace id
    (a thread, user or request id), the rest from a handful of values. SmithDB indexes metadata, and
    Ben Nagengast's load test sent 34 keys a run, 5 of them per-trace ids."""
    metadata: dict[str, Any] = {"load_test": True, "load_test_id": test_id, "load_test_sequence": number}
    trace_id = str(uuid4())
    for n in range(keys):
        metadata[f"key_{n:02d}"] = trace_id if n % HIGH_CARDINALITY_EVERY == 0 else f"value-{(number + n) % LOW_CARDINALITY_VALUES}"
    return metadata


def post_trace(
    client: Client, project_name: str, trace_id: UUID, number: int, test_id: str, payloads: list[RunPayload],
    send: str = "post_then_patch", metadata_keys: int = 0,
) -> None:
    """One root run with its children, each carrying its own payload; every run carries the test's id.
    post_then_patch creates each run and then updates it with its outputs, as a traced function does;
    post_once sends each run finished, in one request, as a run logged after the fact is."""
    metadata = trace_metadata(test_id, number, metadata_keys)
    root_payload = payloads[0]
    root = RunTree(
        name="load-test-trace", run_type="chain", id=trace_id, inputs=root_payload.inputs, project_name=project_name,
        ls_client=client, extra={"metadata": {**metadata, "load_test_payload_profile": root_payload.size_name}},
        tags=["load-test", f"profile:{root_payload.size_name}"], attachments=root_payload.attachments,
    )
    once = send == "post_once"
    if not once:
        root.post()
    for position, payload in enumerate(payloads[1:], start=1):
        child = root.create_child(name=f"step-{position}", run_type="llm" if position % 2 else "tool", inputs=payload.inputs, attachments=payload.attachments)
        if once:
            child.end(outputs=payload.outputs)
            child.post()
            continue
        child.post()
        child.end(outputs=payload.outputs)
        child.patch()
    root.end(outputs=root_payload.outputs)
    if once:
        root.post()
    else:
        root.patch()


class _Run:
    """One load test's shared state: the sending, reading and checking steps are its methods."""

    def __init__(
        self, settings: LoadSettings, profile: Profile, client: Client | None, projects: Projects,
        on_progress: Callable[[int, int, float], None] | None,
    ) -> None:
        self.settings, self.profile, self.client, self.projects, self.on_progress = settings, profile, client, projects, on_progress
        shape = profile.shape
        self.generator = PayloadGenerator(
            profile.mix, profile.sizes_kib, settings.data_seed,
            fields_per_side=shape.fields_per_side, content=shape.content, attachment_kib=shape.attachment_kib_per_run,
        )
        self.counts = results.WriteCounts(
            mode="open-loop" if settings.traces_per_second else "closed-loop", target_traces_per_second=settings.traces_per_second,
        )
        self.test_id = str(uuid4())
        self.started_at = datetime.datetime.now(datetime.UTC)
        self.total_seconds = settings.ramp_up_seconds + settings.duration_seconds
        self.pool = TracePool(settings.read_min_age_seconds)
        self.lag = LagTracker(settings.lag_deadline_seconds)
        self.lag_sampled = self.lag_poll_errors = 0
        self.gone: str | None = None
        self.pick_project = random.Random(settings.data_seed)
        self.reader: Reader | None = None
        self.feedback = FeedbackSender(client, profile.feedback_per_trace, self.counts) if client is not None else None
        self.origin = self.deadline = 0.0

    async def one_trace(self, number: int) -> None:
        s, counts = self.settings, self.counts
        run_count = max(1, share_due(self.profile.runs_per_trace, number))
        try:
            payloads = await asyncio.to_thread(lambda: [self.generator.next_run() for _ in range(run_count)])
            await asyncio.sleep(s.simulated_delay_ms / 1000)
            trace_id = uuid4()
            at = self.projects.pick(self.pick_project)
            sent_at = time.monotonic()
            if self.client is not None:
                shape = self.profile.shape
                await asyncio.to_thread(post_trace, self.client, self.projects.names[at], trace_id, number, self.test_id, payloads, shape.send, shape.metadata_keys)
            counts.send_latencies_seconds.append(time.monotonic() - sent_at)
            counts.traces_sent += 1
            # Starts on the ramp offer half the target on average; the rate a plan is judged on is
            # the one held after it (schedule.start_offset fixes which starts those are).
            if s.traces_per_second and number - 1 >= s.traces_per_second * s.ramp_up_seconds / 2:
                counts.steady_traces_sent += 1
            counts.runs_sent += run_count
            counts.payload_bytes_sent += sum(p.input_bytes + p.output_bytes for p in payloads)
            self._track(trace_id, number, sent_at, at)
        except Exception as error:  # noqa: BLE001 - record a failed trace and continue the load
            counts.run_errors += 1
            counts.first_error = counts.first_error or results.short_error(str(error))

    def _track(self, trace_id: UUID, number: int, sent_at: float, at: int) -> None:
        """What follows a sent trace: the read pool, the lag sample and its feedback."""
        if self.client is None:
            return
        self.pool.add(str(trace_id), sent_at, datetime.datetime.now(datetime.UTC), str(self.projects.ids[at]))
        if share_due(self.settings.lag_sample, number):
            self.lag.add(str(trace_id), sent_at)
            self.lag_sampled += 1
        if self.feedback is not None:
            self.feedback.send(trace_id, number, self.projects.ids[at])

    async def run_user(self, user_number: int) -> None:
        s, loop = self.settings, asyncio.get_running_loop()
        await asyncio.sleep(s.ramp_up_seconds * user_number / s.users)
        while loop.time() < self.deadline:
            if s.run_limit is not None and self.counts.traces_started >= s.run_limit:
                return
            self.counts.traces_started += 1
            await self.one_trace(self.counts.traces_started)
            await asyncio.sleep(min(s.pause_seconds, max(0, self.deadline - loop.time())))

    async def readable(self, ids: list[str]) -> set[str]:
        assert self.client is not None
        try:
            page = await self.client.runs.query(
                project_ids=self.projects.id_strings, ids=ids, min_start_time=self.started_at - READ_BATCH_WINDOW,
                page_size=len(ids), selects=["ID"],
            )
        except Exception as error:  # noqa: BLE001 - a failed check is counted; the run stays pending until its deadline
            self.lag_poll_errors += 1
            self.counts.first_error = self.counts.first_error or f"lag check: {error}"
            return set()
        return {str(run.id) for run in page.items or []}

    async def report_progress(self) -> None:
        assert self.on_progress is not None
        loop = asyncio.get_running_loop()
        while True:
            await asyncio.sleep(self.settings.progress_seconds)
            self.on_progress(self.counts.traces_sent, self.counts.run_errors + self.counts.feedback_errors, loop.time() - self.origin)

    def _loads(self) -> list[Any]:
        s = self.settings
        load: list[Any] = []
        if s.traces_per_second:
            load.append(open_loop(s.traces_per_second, s.ramp_up_seconds, self.total_seconds, self.one_trace, s.max_in_flight, s.run_limit))
        else:
            load.extend(self.run_user(user) for user in range(s.users))
        if self.reader is not None and s.reads_per_second:
            load.append(open_loop(s.reads_per_second, s.ramp_up_seconds, self.total_seconds, self.reader.read, s.max_in_flight))
        return load

    async def _settle(self, finished: asyncio.Event, poll_task: asyncio.Task[None] | None) -> Stored:
        if self.feedback is not None:
            await self.feedback.drain(self.settings.feedback_drain_seconds)
        if self.client is None:
            return Stored()
        await asyncio.to_thread(self.client.flush)
        finished.set()
        if poll_task is not None:
            await poll_task
        return await settle(self.client, self.projects.ids, self.test_id, self.started_at - READ_BATCH_WINDOW, self.counts.runs_sent, self.settings.settle_seconds)

    def _tasks(self, finished: asyncio.Event) -> tuple[asyncio.Task[None] | None, asyncio.Task[None] | None]:
        s = self.settings
        poll_task = None
        if self.client is not None and s.lag_sample > 0:
            poll_task = asyncio.create_task(self.lag.poll(self.readable, time.monotonic, s.lag_poll_seconds, finished))
        progress_task = asyncio.create_task(self.report_progress()) if self.on_progress is not None and s.progress_seconds > 0 else None
        return poll_task, progress_task

    async def _watch_endpoint(self, main: asyncio.Task[Any]) -> None:
        assert self.client is not None
        url = urlsplit(self.client.api_url)
        host, port = url.hostname or "localhost", url.port or (443 if url.scheme == "https" else 80)
        misses = 0
        while True:
            await asyncio.sleep(ENDPOINT_PROBE_SECONDS)
            try:
                _, writer = await asyncio.wait_for(asyncio.open_connection(host, port), ENDPOINT_PROBE_SECONDS / 2)
                writer.close()
                misses = 0
            except (OSError, TimeoutError):
                misses += 1
                if misses >= ENDPOINT_GONE_AFTER:
                    self.gone = f"{host}:{port} took no connection {misses} times in a row: the tunnel or the install is gone"
                    main.cancel()
                    return

    async def go(self) -> LoadOutcome:
        s, loop = self.settings, asyncio.get_running_loop()
        if self.client is not None:
            client = self.client
            # Touch the SDK's lazily fetched server info here: the first read would otherwise do it
            # as a blocking call on the event loop.
            await asyncio.to_thread(lambda: client.info)
            if s.read:
                self.reader = Reader(client, self.projects, self.test_id, self.started_at, self.profile.read_mix, self.profile.heavy_window_days, self.pool, s.data_seed)
        self.origin = loop.time()
        self.deadline = self.origin + self.total_seconds
        finished = asyncio.Event()
        poll_task, progress_task = self._tasks(finished)
        main = asyncio.current_task()
        watch_task = asyncio.create_task(self._watch_endpoint(main)) if self.client is not None and self.client.api_url and main else None
        read_dropped, read_lags = 0, []
        try:
            outcomes = await asyncio.gather(*self._loads())
            self.counts.duration_seconds = loop.time() - self.origin
            if s.traces_per_second:
                write_loop = outcomes[0]
                self.counts.traces_started, self.counts.dropped_starts, self.counts.schedule_lags_seconds = write_loop.started, write_loop.dropped, write_loop.lags_seconds
            if self.reader is not None and s.reads_per_second:
                read_dropped, read_lags = outcomes[-1].dropped, outcomes[-1].lags_seconds
            stored = await self._settle(finished, poll_task)
        except asyncio.CancelledError:
            if self.gone is None:
                raise
            raise EndpointGone(self.gone) from None
        finally:
            await self._close(finished, (progress_task, poll_task, watch_task))
        return LoadOutcome(
            self.test_id, self.started_at, datetime.datetime.now(datetime.UTC), self.counts, self.reader, read_dropped, read_lags,
            self.lag, self.lag_poll_errors, self.lag_sampled, stored,
        )

    async def _close(self, finished: asyncio.Event, tasks: tuple[asyncio.Task[None] | None, ...]) -> None:
        finished.set()
        if self.feedback is not None:
            self.feedback.close()
        for task in tasks:
            if task is not None:
                task.cancel()
                with suppress(asyncio.CancelledError):
                    await task


async def run_load_test(
    settings: LoadSettings,
    profile: Profile,
    client: Client | None,
    projects: Projects,
    on_progress: Callable[[int, int, float], None] | None = None,
) -> LoadOutcome:
    return await _Run(settings, profile, client, projects, on_progress).go()


def _write_section(write: Any, settings: LoadSettings, profile: Profile, tracing_enabled: bool, first_upload_error: str | None) -> dict[str, Any]:
    send = summarize(write.send_latencies_seconds)
    schedule = summarize(write.schedule_lags_seconds)
    return {
        "mode": write.mode, "tracing_enabled": tracing_enabled,
        "target_traces_per_second": write.target_traces_per_second,
        "achieved_traces_per_second": write.traces_sent / write.duration_seconds if write.duration_seconds else 0,
        "steady_traces_per_second": write.steady_traces_sent / settings.duration_seconds if write.mode == "open-loop" and settings.duration_seconds else None,
        "duration_seconds": write.duration_seconds, "traces_started": write.traces_started,
        "traces_sent": write.traces_sent, "runs_sent": write.runs_sent, "run_errors": write.run_errors,
        "payload_bytes_sent": write.payload_bytes_sent,
        "payload_kib_per_run": write.payload_bytes_sent / 1024 / write.runs_sent if write.runs_sent else None,
        "dropped_starts": write.dropped_starts,
        "send_latency_seconds": {key: send[key] for key in ("p50", "p95", "p99", "max")},
        "schedule_lag_seconds": {key: schedule[key] for key in ("p50", "p95", "p99", "max")},
        "first_error": write.first_error or first_upload_error,
        "payload_shape": dataclasses.asdict(profile.shape),
    }


def _stored_section(outcome: LoadOutcome, settings: LoadSettings) -> dict[str, Any]:
    write, stored = outcome.write, outcome.stored
    return {
        "settle_seconds": settings.settle_seconds, "traces_sent": write.traces_sent, "traces_stored": stored.traces,
        "traces_missing": None if stored.traces is None else max(0, write.traces_sent - stored.traces),
        "runs_sent": write.runs_sent, "runs_stored": stored.runs,
        "missing_runs": None if stored.runs is None else max(0, write.runs_sent - stored.runs), "error": stored.error,
    }


def build_report(
    outcome: LoadOutcome, settings: LoadSettings, profile: Profile, project_name: str, tracing_enabled: bool,
    upload_errors: int, first_upload_error: str | None, app_version: str | None = None,
    cluster: tuple[dict[str, Any], dict[str, Any]] = results.NOT_READ,
) -> dict[str, Any]:
    """cluster is (metrics keyed by watch item id, the cluster section)."""
    write = outcome.write
    send = summarize(write.send_latencies_seconds)
    limit = settings.latency_limit_seconds
    limit_passed = None if limit is None else (send["p95"] is not None and send["p95"] <= limit)
    lag = summarize(outcome.lag.lags_seconds)
    reads = outcome.reader.stats if outcome.reader else {}
    read_count = sum(len(entry.latencies_seconds) + entry.errors for entry in reads.values())
    return results.assemble(
        server={"app_version": app_version},
        profile=profile.document, settings=dataclasses.asdict(settings), test_id=outcome.test_id, project=project_name,
        started_at=outcome.started_at.isoformat(), ended_at=outcome.ended_at.isoformat(),
        write=_write_section(write, settings, profile, tracing_enabled, first_upload_error),
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
        stored=_stored_section(outcome, settings),
        targets=profile.targets, upload_errors=upload_errors, latency_limit_passed=limit_passed,
        cluster=cluster,
    )
