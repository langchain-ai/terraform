"""Verify a sizing plan: send the load it was sized for, read it back, measure lag and loss."""

from __future__ import annotations

import argparse
import asyncio
import dataclasses
import json
import logging
import os
import sys
from pathlib import Path
from queue import SimpleQueue
from typing import Any
from uuid import UUID

import structlog
from dotenv import load_dotenv
from langsmith import Client
from langsmith.utils import tracing_is_enabled
from loadtest.profile import Profile, ProfileError, from_file, from_params
from loadtest.runner import LoadSettings, build_report, run_load_test

SETUP_ERROR = 2


def _configure_logging() -> None:
    structlog.configure(
        processors=[
            structlog.processors.TimeStamper(fmt="iso"),
            structlog.processors.add_log_level,
            structlog.dev.ConsoleRenderer(pad_event_to=0, pad_level=False),
        ],
        wrapper_class=structlog.make_filtering_bound_logger(logging.INFO),
        logger_factory=structlog.PrintLoggerFactory(file=sys.stderr),
        cache_logger_on_first_use=True,
    )


def build_parser(defaults: LoadSettings) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="load-test", description=__doc__, formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    load = parser.add_argument_group("load")
    load.add_argument("--profile", type=Path, help="a langsmith-load-profile/1 JSON file from `langsmith-sizing load-profile`; without it, the sizing model's defaults")
    load.add_argument("--traces-per-second", type=float, help="start traces at this rate whatever happens to earlier ones (open loop); the profile's rate when --profile is given")
    load.add_argument("--peak", action="store_true", help="use the profile's peak rate instead of its average")
    load.add_argument("--users", type=int, help="closed loop: concurrent simulated users, each starting its next trace when the last finishes (the mode when no rate is given; default 10)")
    load.add_argument("--duration-seconds", type=float, default=defaults.duration_seconds, help="how long to run after ramp-up")
    load.add_argument("--ramp-up-seconds", type=float, default=defaults.ramp_up_seconds, help="spread user starts, or raise the rate from zero, over this many seconds")
    load.add_argument("--run-limit", type=int, help="maximum total traces; otherwise unlimited")
    load.add_argument("--max-in-flight", type=int, default=defaults.max_in_flight, help="open loop: starts due while this many traces are unfinished are dropped and counted")
    load.add_argument("--pause-seconds", type=float, default=defaults.pause_seconds, help="closed loop: each user's pause between traces")
    load.add_argument("--simulated-delay-ms", type=float, default=defaults.simulated_delay_ms, help="add this many milliseconds of local work before each trace")
    load.add_argument("--feedback-per-trace", type=float, help="feedback writes per trace; the profile's or the model's default (load.feedback_per_trace) when omitted; 0 disables")
    load.add_argument("--data-seed", type=int, help="seed for repeatable text and size draws")
    reads = parser.add_argument_group("reads")
    reads.add_argument("--read", action="store_true", help="send read load across the profile's read mix")
    reads.add_argument("--reads-per-second", type=float, help="read rate; the profile's read.requests_per_second when --profile is given")
    reads.add_argument("--read-min-age-seconds", type=float, default=defaults.read_min_age_seconds, help="read_trace picks traces sent at least this long ago, so it does not read what is still being ingested")
    verify = parser.add_argument_group("lag and loss")
    verify.add_argument("--lag-sample", type=float, default=defaults.lag_sample, help="share of traces polled until readable to measure send-to-readable lag; 0 disables")
    verify.add_argument("--lag-deadline-seconds", type=float, default=defaults.lag_deadline_seconds, help="a sampled run not readable by then counts as never readable")
    verify.add_argument("--lag-poll-seconds", type=float, default=defaults.lag_poll_seconds, help="seconds between readable checks; the resolution of a lag")
    verify.add_argument("--settle-seconds", type=float, default=defaults.settle_seconds, help="after the load, how long to wait for stored runs to reach runs sent")
    output = parser.add_argument_group("output")
    output.add_argument("--results", type=Path, help="write the langsmith-load-results/1 JSON here")
    output.add_argument("--latency-limit-seconds", type=float, help="fail if the p95 time to hand a trace to the SDK exceeds this limit")
    output.add_argument("--progress-seconds", type=float, default=defaults.progress_seconds, help="seconds between progress updates; 0 turns them off")
    output.add_argument("--feedback-drain-seconds", type=float, default=defaults.feedback_drain_seconds, help="after the load, how long to wait for feedback still in flight; the rest count as errors")
    output.add_argument("--json", action="store_true", help="print the results document to stdout; logs go to stderr")
    return parser


def resolve(arguments: dict[str, Any], profile: Profile | None) -> tuple[Profile, dict[str, Any]]:
    """Fold the profile and the command line into settings; raises ValueError on a contradiction."""
    base = profile or from_params()
    peak = arguments.pop("peak")
    users = arguments.pop("users")
    feedback = arguments.pop("feedback_per_trace")
    if feedback is not None:
        base = dataclasses.replace(base, feedback_per_trace=feedback)
    if peak and profile is None:
        raise ValueError("--peak needs a --profile")
    rate = arguments["traces_per_second"]
    if rate is None and profile is not None:
        rate = base.peak_traces_per_second if peak else base.traces_per_second
    if rate is not None and users is not None:
        raise ValueError("--users is the closed-loop mode; give it or a rate (--traces-per-second, --profile), not both")
    arguments["traces_per_second"] = rate
    if users is not None:
        arguments["users"] = users
    if arguments["reads_per_second"] is None and profile is not None and base.read_requests_per_second:
        arguments["reads_per_second"] = base.read_requests_per_second
    return base, arguments


def _workspace(parser: argparse.ArgumentParser) -> str | None:
    """The workspace to write to, after checking the connection settings tracing needs."""
    for name in ("LANGSMITH_ENDPOINT", "LANGSMITH_API_KEY"):
        if not os.getenv(name, "").strip():
            parser.error(f"Set {name} in .env and run with uv run load-test")
    workspace_id = os.getenv("LANGSMITH_WORKSPACE_ID", "").strip()
    if not workspace_id:
        return None
    try:
        return str(UUID(workspace_id))
    except ValueError:
        parser.error("LANGSMITH_WORKSPACE_ID must be a UUID; leave it empty unless the API key can access multiple workspaces")


def main(argv: list[str] | None = None) -> int:
    # The local file selects the target even when a shell exports another endpoint.
    load_dotenv(dotenv_path=Path(".env"), override=True)
    parser = build_parser(LoadSettings())
    arguments = vars(parser.parse_args(argv))
    json_output = arguments.pop("json")
    results_path = arguments.pop("results")
    profile_path = arguments.pop("profile")
    try:
        profile, arguments = resolve(arguments, from_file(profile_path) if profile_path else None)
        settings = LoadSettings(**arguments)
    except (ValueError, ProfileError) as error:
        parser.error(str(error))

    # "local" traces without uploading: nothing reaches an instance, so nothing can be counted or read.
    tracing_enabled = tracing_is_enabled() is True
    if not tracing_enabled and settings.read:
        parser.error("--read needs tracing: set LANGSMITH_TRACING=true in .env")
    workspace_id = _workspace(parser) if tracing_enabled else None
    project_name = os.getenv("LANGSMITH_PROJECT") or "load-test"
    _configure_logging()
    logger = structlog.get_logger("loadtest.load_test")
    mode = f"open loop at {settings.traces_per_second:g} traces/s" if settings.traces_per_second else f"closed loop, {settings.users} users"
    logger.info(
        f"Load test started: {mode}   Duration: {settings.duration_seconds:g}s   Ramp: {settings.ramp_up_seconds:g}s   "
        f"Run limit: {settings.run_limit if settings.run_limit is not None else 'none'}   "
        f"Reads: {f'{settings.reads_per_second:g}/s' if settings.read else 'off'}"
    )
    upload_errors: SimpleQueue[Exception] = SimpleQueue()

    def report_progress(traces: int, errors: int, elapsed_seconds: float) -> None:
        errors += upload_errors.qsize()
        log = logger.warning if errors else logger.info
        log(f"Progress after {elapsed_seconds:.0f}s: Traces: {traces:,}   Errors: {errors:,}   Rate: {traces / elapsed_seconds:.2f} traces/s")

    client = None
    project_id = None
    try:
        if tracing_enabled:
            client = Client(
                api_url=os.environ["LANGSMITH_ENDPOINT"], api_key=os.environ["LANGSMITH_API_KEY"],
                workspace_id=workspace_id, max_batch_size_bytes=6 * 1024 * 1024, tracing_error_callback=upload_errors.put,
            )
            project = client.create_project(project_name=project_name, upsert=True)
            project_id = project.id
            logger.info(f"Project: {project_name}   Workspace: {project.tenant_id}")
        else:
            logger.info("Tracing disabled: payloads are generated locally and nothing is uploaded")
        outcome = asyncio.run(run_load_test(settings, profile, client, project_name, project_id, report_progress))
    except Exception as error:  # noqa: BLE001 - turn setup and flush failures into CLI errors
        logger.error(f"Load test failed: Reason: {' '.join(str(error).splitlines())}")
        return SETUP_ERROR
    finally:
        if client is not None:
            client.close(timeout=0)

    upload_count = upload_errors.qsize()
    first_upload_error = str(upload_errors.get()) if upload_count else None
    report = build_report(outcome, settings, profile, project_name, tracing_enabled, upload_count, first_upload_error)
    _emit(report, results_path, json_output)
    (logger.info if report["passed"] else logger.error)(f"Load test {'passed' if report['passed'] else 'FAILED'}")
    return 0 if report["passed"] else 1


def _emit(report: dict[str, Any], results_path: Path | None, json_output: bool) -> None:
    if results_path is not None:
        results_path.write_text(json.dumps(report, indent=2) + "\n")
    if json_output:
        json.dump(report, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        print_summary(report)


def _fmt(value: object) -> str:
    return "n/a" if value is None else f"{value:.3f}" if isinstance(value, float) else str(value)


def print_summary(report: dict[str, Any]) -> None:
    write, lag, stored = report["write"], report["lag"], report["stored"]
    print(f"write    {write['mode']}: {_fmt(write['achieved_traces_per_second'])} traces/s achieved"
          f" (target {_fmt(write['target_traces_per_second'])}), {write['traces_sent']} traces, {write['runs_sent']} runs,"
          f" {write['run_errors']} errors, {write['dropped_starts']} dropped starts,"
          f" schedule lag p99 {_fmt(write['schedule_lag_seconds']['p99'])} s")
    print(f"feedback {report['feedback']['sent']} sent, {report['feedback']['errors']} errors")
    for name, entry in report["reads"]["classes"].items():
        print(f"read     {name:<14} n={entry['count']} errors={entry['errors']} skipped={entry['skipped']}"
              f" p50={_fmt(entry['p50_seconds'])} p95={_fmt(entry['p95_seconds'])} p99={_fmt(entry['p99_seconds'])} s ({entry['component']})")
    print(f"lag      {lag['readable']}/{lag['sampled']} readable, {lag['never_readable']} never readable,"
          f" p50 {_fmt(lag['p50_seconds'])} p95 {_fmt(lag['p95_seconds'])} p99 {_fmt(lag['p99_seconds'])} max {_fmt(lag['max_seconds'])} s")
    print(f"stored   runs sent {stored['runs_sent']}, stored {_fmt(stored['runs_stored'])}, missing {_fmt(stored['missing_runs'])}"
          f"{' (' + stored['error'] + ')' if stored['error'] else ''}")
    for name, entry in report["targets"].items():
        print(f"target   {name:<26} {'not measured' if entry['passed'] is None else 'pass' if entry['passed'] else 'FAIL'}")
    if write["first_error"]:
        print(f"first error: {write['first_error']}")


if __name__ == "__main__":
    raise SystemExit(main())
