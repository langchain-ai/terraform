"""Load-test a local echo agent with no model-provider calls or model charges."""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
from pathlib import Path
from queue import SimpleQueue
from uuid import UUID

import structlog
from dotenv import load_dotenv
from langsmith import Client
from langsmith.utils import tracing_is_enabled

from loadtest.runner import LoadSettings, run_load_test


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


def main(argv: list[str] | None = None) -> int:
    # The local file selects the target even when a shell exports another endpoint.
    load_dotenv(dotenv_path=Path(".env"), override=True)
    defaults = LoadSettings()
    parser = argparse.ArgumentParser(
        prog="load-test", description=__doc__,
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--users", type=int, default=defaults.users,
                        help="number of concurrent simulated users")
    parser.add_argument("--duration-seconds", type=float, default=defaults.duration_seconds,
                        help="how long to run after ramp-up")
    parser.add_argument("--ramp-up-seconds", type=float, default=defaults.ramp_up_seconds,
                        help="spread user starts over this many seconds")
    parser.add_argument("--run-limit", type=int,
                        help="maximum total traces across all users; otherwise unlimited")
    parser.add_argument("--pause-seconds", type=float, default=defaults.pause_seconds,
                        help="each user's pause between traces")
    parser.add_argument("--simulated-delay-ms", type=float, default=defaults.simulated_delay_ms,
                        help="add this many milliseconds of local work before each trace")
    parser.add_argument("--feedback-percent", type=float, default=defaults.feedback_percent,
                        help="percentage of traces given a synthetic rating, from 0 to 100")
    parser.add_argument("--data-seed", type=int, help="seed for repeatable sample documents")
    parser.add_argument("--latency-limit-seconds", type=float,
                        help="fail if the local 95th-percentile run time exceeds this limit")
    parser.add_argument("--progress-seconds", type=float, default=defaults.progress_seconds,
                        help="seconds between progress updates; 0 turns them off")
    parser.add_argument("--json", action="store_true", help="print final results as JSON")
    arguments = vars(parser.parse_args(argv))
    json_output = arguments.pop("json")
    try:
        settings = LoadSettings(**arguments)
    except ValueError as error:
        parser.error(str(error))

    tracing_enabled = tracing_is_enabled()
    workspace_id = None
    if tracing_enabled:
        for name in ("LANGSMITH_ENDPOINT", "LANGSMITH_API_KEY"):
            if not os.getenv(name, "").strip():
                parser.error(f"Set {name} in .env and run with uv run load-test")
        workspace_id = os.getenv("LANGSMITH_WORKSPACE_ID", "").strip() or None
        if workspace_id is not None:
            try:
                workspace_id = str(UUID(workspace_id))
            except ValueError:
                parser.error(
                    "LANGSMITH_WORKSPACE_ID must be a UUID; leave it empty unless the API key "
                    "can access multiple workspaces"
                )
    project_name = os.getenv("LANGSMITH_PROJECT") or "load-test"
    _configure_logging()
    logger = structlog.get_logger("loadtest.load_test")
    logger.info(
        f"Load test started: Target: inprocess   "
        f"Model: echo   Users: {settings.users}   "
        f"Duration: {settings.duration_seconds:g}s   "
        f"Run limit: {settings.run_limit if settings.run_limit is not None else 'none'}   "
        f"Ramp: {settings.ramp_up_seconds:g}s"
    )
    upload_errors: SimpleQueue[Exception] = SimpleQueue()

    def report_progress(runs: int, errors: int, elapsed_seconds: float) -> None:
        errors += upload_errors.qsize()
        log = logger.warning if errors else logger.info
        log(
            f"Progress after {elapsed_seconds:.0f}s: Runs: {runs:,}"
            f"{' / ' + format(settings.run_limit, ',') if settings.run_limit is not None else ''}   "
            f"Errors: {errors:,}   "
            f"Rate: {runs / elapsed_seconds:.2f} runs/s"
        )

    client = None
    project_id = None
    try:
        if tracing_enabled:
            client = Client(
                api_url=os.environ["LANGSMITH_ENDPOINT"],
                api_key=os.environ["LANGSMITH_API_KEY"],
                workspace_id=workspace_id,
                max_batch_size_bytes=6 * 1024 * 1024,
                tracing_error_callback=upload_errors.put,
            )
            project = client.create_project(project_name=project_name, upsert=True)
            project_id = project.id
            logger.info(f"Project: {project_name}   Workspace: {project.tenant_id}")
        else:
            logger.info("Tracing disabled: the agent runs locally without uploading traces or feedback")
        result = asyncio.run(run_load_test(settings, client, project_name, project_id, report_progress))
        if client is not None:
            logger.info("Waiting for pending uploads")
            client.flush()
    except Exception as error:  # noqa: BLE001 - turn setup and flush failures into CLI errors
        reason = " ".join(str(error).splitlines())
        logger.error(f"Load test failed: Reason: {reason}")
        return 2
    finally:
        if client is not None:
            client.close(timeout=0)

    report = result.report()
    report["tracing_enabled"] = tracing_enabled
    report["upload_errors"] = upload_errors.qsize()
    if not upload_errors.empty():
        report["first_error"] = report["first_error"] or str(upload_errors.get())
    failed = bool(result.run_errors or result.feedback_errors or report["upload_errors"])
    if settings.latency_limit_seconds is not None:
        latency = report["latency_p95_seconds"]
        report["latency_limit_seconds"] = settings.latency_limit_seconds
        report["latency_limit_passed"] = latency is not None and latency <= settings.latency_limit_seconds
        failed = failed or not report["latency_limit_passed"]
    log = logger.warning if result.run_errors or result.feedback_errors or report["upload_errors"] else logger.info
    log("Load test completed")
    if json_output:
        json.dump(report, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        print(f"target=inprocess model=echo concurrency={settings.users}")
        for name, value in report.items():
            if isinstance(value, float):
                value = round(value, 2 if name in ("duration_seconds", "runs_per_second") else 4)
            print(f"  {name:<24} {value}")
    if settings.latency_limit_seconds is not None and not report["latency_limit_passed"]:
        logger.error(
            f"Load test failed SLO: P95 latency: {round(latency, 4) if latency is not None else None}s   "
            f"Limit: {settings.latency_limit_seconds}s"
        )
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
