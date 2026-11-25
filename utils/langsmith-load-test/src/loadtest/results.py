"""Assemble the results document (schema "langsmith-load-results/1") and its target verdicts."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

SCHEMA = "langsmith-load-results/1"
NOT_READ: tuple[dict[str, Any], dict[str, Any]] = ({}, {"read": False, "why": "no --namespace: the run measured what a client sees, not the install"})


@dataclass
class WriteCounts:
    mode: str = "closed-loop"
    target_traces_per_second: float | None = None
    duration_seconds: float = 0.0
    traces_started: int = 0
    traces_sent: int = 0
    steady_traces_sent: int = 0
    runs_sent: int = 0
    payload_bytes_sent: int = 0
    run_errors: int = 0
    dropped_starts: int = 0
    send_latencies_seconds: list[float] = field(default_factory=list)
    schedule_lags_seconds: list[float] = field(default_factory=list)
    feedback_sent: int = 0
    feedback_errors: int = 0
    first_error: str | None = None


def verdict(target: float, observed: float | None, *, observed_name: str) -> dict[str, Any]:
    """`passed` is None when nothing was measured: that neither passes nor fails the run."""
    return {
        "target_seconds": target, "observed": observed_name, "observed_seconds": observed,
        "passed": None if observed is None else observed <= target,
    }


def target_verdicts(
    targets: dict[str, float], lag: dict[str, Any], reads: dict[str, dict[str, Any]], missing_runs: int | None,
) -> dict[str, Any]:
    # A run that never became readable has a lag longer than any deadline, so it fails the p99
    # target whenever those runs are more than 1% of the sample.
    lag_p99 = lag["p99_seconds"]
    if lag["sampled"] and lag["never_readable"] / lag["sampled"] > 0.01:
        lag_p99 = float("inf")
    trace_load = reads.get("read_trace", {}).get("p99_seconds")
    return {
        "stored_within_seconds_p99": verdict(targets["stored_within_seconds"], lag_p99, observed_name="lag_p99"),
        "trace_load_seconds_p99": verdict(targets["trace_load_seconds"], trace_load, observed_name="read_trace_p99"),
        "no_missing_runs": {"missing": missing_runs, "passed": None if missing_runs is None else missing_runs == 0},
    }


def assemble(
    *, profile: dict[str, Any], settings: dict[str, Any], test_id: str, project: str, started_at: str, ended_at: str,
    write: dict[str, Any], feedback: dict[str, Any], reads: dict[str, Any], lag: dict[str, Any],
    stored: dict[str, Any], targets: dict[str, float], upload_errors: int, latency_limit_passed: bool | None,
    server: dict[str, Any] | None = None, cluster: tuple[dict[str, Any], dict[str, Any]] = NOT_READ,
) -> dict[str, Any]:
    verdicts = target_verdicts(targets, lag, reads["classes"], stored["missing_runs"])
    verdicts["send_latency_limit"] = {"passed": latency_limit_passed}
    read_errors = sum(entry["errors"] for entry in reads["classes"].values())
    failed = (
        any(entry["passed"] is False for entry in verdicts.values())
        or bool(write["run_errors"] or feedback["errors"] or upload_errors or read_errors or stored["error"])
    )
    return {
        "schema": SCHEMA, "test_id": test_id, "project": project, "started_at": started_at, "ended_at": ended_at,
        "profile": profile, "settings": settings, "write": write, "feedback": feedback, "reads": reads, "lag": lag,
        "stored": stored, "errors": {"upload": upload_errors, "reads": read_errors}, "targets": verdicts,
        "server": server or {"app_version": None},
        "metrics": cluster[0], "cluster": cluster[1],
        "passed": not failed,
    }
