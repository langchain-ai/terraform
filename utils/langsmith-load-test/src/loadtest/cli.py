"""Verify a sizing plan: send the load it was sized for, read it back, measure lag and loss."""

from __future__ import annotations

import argparse
import asyncio
import dataclasses
import json
import logging
import os
import sys
from collections.abc import Callable
from pathlib import Path
from queue import SimpleQueue
from typing import Any
from uuid import UUID, uuid4

import structlog
from dotenv import load_dotenv
from langsmith import Client
from langsmith.utils import tracing_is_enabled
from langsmith_sizing import ui
from langsmith_sizing.summary import Table
from loadtest import cluster
from loadtest.draw import Projects, project_names
from loadtest.profile import CONTENTS, SENDS, Profile, ProfileError, Shape, from_file, from_params
from loadtest.results import NOT_READ
from loadtest.runner import LoadOutcome, LoadSettings, build_report, run_load_test
from rich.console import Console

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
    shape = parser.add_argument_group("payload shape (each replaces the profile's; vary one at a time to measure what it costs)")
    shape.add_argument("--fields-per-side", type=int, help="fields an input and an output each split into, the size spread evenly")
    shape.add_argument("--content", choices=CONTENTS, help="text (prose), json (a message list) or base64 (incompressible bytes)")
    shape.add_argument("--send", choices=SENDS, help="post_then_patch (a create, then an update) or post_once (a finished run in one request)")
    shape.add_argument("--attachment-kib", type=float, help="attachment KiB sent with every run; 0 sends none")
    shape.add_argument("--projects", type=int, help="projects the traces spread over (named <LANGSMITH_PROJECT>-000 on), the first the busiest")
    shape.add_argument("--project-skew", type=float, help="Zipf exponent of that spread: 0 is even, 1 puts a third of 10 projects' traces on the first")
    shape.add_argument("--metadata-keys", type=int, help="metadata keys a run carries beyond the test's own, every fifth a per-trace id")
    shape.add_argument("--batch-runs", type=int, help="the most runs the SDK sends in one request (its default 100)")
    reads = parser.add_argument_group("reads")
    reads.add_argument("--read", action="store_true", help="send read load across the profile's read mix")
    reads.add_argument("--reads-per-second", type=float, help="read rate; the profile's read.requests_per_second when --profile is given")
    reads.add_argument("--read-min-age-seconds", type=float, default=defaults.read_min_age_seconds, help="read_trace picks traces sent at least this long ago, so it does not read what is still being ingested")
    verify = parser.add_argument_group("lag and loss")
    verify.add_argument("--lag-sample", type=float, default=defaults.lag_sample, help="share of traces polled until readable to measure send-to-readable lag; 0 disables")
    verify.add_argument("--lag-deadline-seconds", type=float, default=defaults.lag_deadline_seconds, help="a sampled run not readable by then counts as never readable")
    verify.add_argument("--lag-poll-seconds", type=float, default=defaults.lag_poll_seconds, help="seconds between readable checks; the resolution of a lag")
    verify.add_argument("--settle-seconds", type=float, default=defaults.settle_seconds, help="after the load, how long to wait for stored runs to reach runs sent")
    cluster = parser.add_argument_group("the install's own metrics (read through kubectl while the load runs)")
    cluster.add_argument("--namespace", help="the namespace LangSmith runs in; without it only the client side is measured")
    cluster.add_argument("--data-namespace", help="the namespace Redis and Postgres run in, when not LangSmith's (the datastores chart can run them apart)")
    cluster.add_argument("--release", default="langsmith", help="the Helm release name, the prefix of every workload's name")
    cluster.add_argument("--kube-context", help="the kubectl context; the current one when omitted")
    cluster.add_argument("--sample-seconds", type=float, default=15, help="seconds between samples; raise it on a cluster of hundreds of nodes, where each sample reads every node's cAdvisor")
    output = parser.add_argument_group("output")
    output.add_argument("--results", type=Path, help="write the langsmith-load-results/1 JSON here")
    output.add_argument("--latency-limit-seconds", type=float, help="fail if the p95 time to hand a trace to the SDK exceeds this limit")
    output.add_argument("--progress-seconds", type=float, default=defaults.progress_seconds, help="seconds between progress updates; 0 turns them off")
    output.add_argument("--feedback-drain-seconds", type=float, default=defaults.feedback_drain_seconds, help="after the load, how long to wait for feedback still in flight; the rest count as errors")
    output.add_argument("--json", action="store_true", help="print the results document to stdout; logs go to stderr")
    return parser


CLUSTER_OPTIONS = ("namespace", "data_namespace", "release", "kube_context", "sample_seconds")


def cluster_options(arguments: dict[str, Any]) -> dict[str, Any]:
    """Take the options for reading the install out of the parsed arguments; the rest are the load's."""
    return {name: arguments.pop(name) for name in CLUSTER_OPTIONS}


SHAPE_FLAGS = {
    "fields_per_side": "fields_per_side", "content": "content", "send": "send", "attachment_kib": "attachment_kib_per_run",
    "projects": "projects", "project_skew": "project_skew", "metadata_keys": "metadata_keys", "batch_runs": "batch_runs",
}


def _with_shape_flags(base: Profile, arguments: dict[str, Any]) -> Profile:
    """The profile's payload shape with each shape flag given replacing its part."""
    given = {field: value for flag, field in SHAPE_FLAGS.items() if (value := arguments.pop(flag)) is not None}
    return dataclasses.replace(base, shape=dataclasses.replace(base.shape, **given))


def resolve(arguments: dict[str, Any], profile: Profile | None) -> tuple[Profile, dict[str, Any]]:
    """Fold the profile and the command line into settings; raises ValueError on a contradiction."""
    base = profile or from_params()
    peak = arguments.pop("peak")
    users = arguments.pop("users")
    feedback = arguments.pop("feedback_per_trace")
    if feedback is not None:
        base = dataclasses.replace(base, feedback_per_trace=feedback)
    base = _with_shape_flags(base, arguments)
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
    watch = cluster_options(arguments)
    results_path = arguments.pop("results")
    profile_path = arguments.pop("profile")
    profile, settings = _settings(parser, arguments, profile_path)

    # "local" traces without uploading: nothing reaches an instance, so nothing can be counted or read.
    tracing_enabled = tracing_is_enabled() is True
    if not tracing_enabled and settings.read:
        parser.error("--read needs tracing: set LANGSMITH_TRACING=true in .env")
    workspace_id = _workspace(parser) if tracing_enabled else None
    project_name = os.getenv("LANGSMITH_PROJECT") or "load-test"
    _configure_logging()
    logger = structlog.get_logger("loadtest.load_test")
    if json_output:
        # stdout carries the results document alone; everything a person reads goes to stderr
        ui.console = Console(theme=ui.THEME, stderr=True, highlight=False)
    _banner(settings, profile_path)
    upload_errors: SimpleQueue[Exception] = SimpleQueue()

    def report_progress(traces: int, errors: int, elapsed_seconds: float) -> None:
        errors += upload_errors.qsize()
        line = f"{elapsed_seconds:>6.0f} s   {traces:>10,} traces   {traces / elapsed_seconds:>8.2f} traces/s   {errors:,} errors"
        (ui.warn if errors else ui.note)(line)

    client = None
    projects = Projects(project_names(project_name, profile.shape.projects), tuple(uuid4() for _ in range(profile.shape.projects)), profile.shape.project_skew)
    app_version = None
    try:
        if tracing_enabled:
            client, projects, app_version = _connect(profile, project_name, workspace_id, upload_errors)
        else:
            ui.note("tracing is off: payloads are generated locally and nothing is uploaded")
        outcome, samples = _load_while_reading(watch, results_path, lambda: asyncio.run(run_load_test(settings, profile, client, projects, report_progress)))
    except Exception as error:  # noqa: BLE001 - turn setup and flush failures into CLI errors
        logger.error(f"Load test failed: Reason: {' '.join(str(error).splitlines())}")
        return SETUP_ERROR
    finally:
        if client is not None:
            client.close(timeout=0)

    upload_count = upload_errors.qsize()
    first_upload_error = str(upload_errors.get()) if upload_count else None
    report = build_report(outcome, settings, profile, project_name, tracing_enabled, upload_count, first_upload_error, app_version, _cluster(samples, watch, outcome, settings, profile))
    _emit(report, results_path, json_output)
    return 0 if report["passed"] else 1


BATCH_RUNS_ENV = "LANGSMITH_BATCH_INGEST_SIZE_LIMIT"


def _settings(parser: argparse.ArgumentParser, arguments: dict[str, Any], profile_path: Path | None) -> tuple[Profile, LoadSettings]:
    """The profile and the run's settings, from the profile file and the flags; a contradiction is a usage error."""
    try:
        profile, rest = resolve(arguments, from_file(profile_path) if profile_path else None)
        return profile, LoadSettings(**rest)
    except (ValueError, ProfileError) as error:
        parser.error(str(error))


def _connect(profile: Profile, project_name: str, workspace_id: str | None, upload_errors: SimpleQueue[Exception]) -> tuple[Client, Projects, str | None]:
    """The SDK client, the test's projects, and the version the install reports."""
    # The SDK reads its cap on runs a request from here once, when it first sends.
    os.environ[BATCH_RUNS_ENV] = str(profile.shape.batch_runs)
    client = Client(
        api_url=os.environ["LANGSMITH_ENDPOINT"], api_key=os.environ["LANGSMITH_API_KEY"],
        workspace_id=workspace_id, max_batch_size_bytes=6 * 1024 * 1024, tracing_error_callback=upload_errors.put,
    )
    projects = _projects(client, project_name, profile.shape)
    app_version = _app_version(client)
    ui.note(f"{len(projects.names)} project(s) from {projects.names[0]}, LangSmith {app_version or 'version not read'}")
    return client, projects, app_version


def _projects(client: Client, base: str, shape: Shape) -> Projects:
    names = project_names(base, shape.projects)
    ids = tuple(client.create_project(project_name=name, upsert=True).id for name in names)
    return Projects(names, ids, shape.project_skew)


def _banner(settings: LoadSettings, profile_path: Path | None) -> None:
    mode = f"open loop at {settings.traces_per_second:g} traces/s" if settings.traces_per_second else f"closed loop, {settings.users} users"
    ui.banner("LangSmith load test", f"{os.getenv('LANGSMITH_ENDPOINT', '(no endpoint: local only)')}\n{mode}, {settings.duration_seconds:g} s after a {settings.ramp_up_seconds:g} s ramp; "
              f"reads {f'{settings.reads_per_second:g}/s' if settings.read else 'off'}; run limit {settings.run_limit if settings.run_limit is not None else 'none'}"
              + (f"\nprofile {profile_path}" if profile_path else ""))


def _load_while_reading(watch: dict[str, Any], results_path: Path | None, run: Callable[[], LoadOutcome]) -> tuple[LoadOutcome, list[dict[str, Any]]]:
    """The load, with the install read on its own thread from before it starts until it has settled."""
    collector = _collector(watch, results_path)
    if collector is None:
        return run(), []
    collector.start()
    try:
        outcome = run()
    finally:
        samples = collector.stop()
    return outcome, samples


def _collector(watch: dict[str, Any], results_path: Path | None) -> cluster.Collector | None:
    if not watch["namespace"]:
        return None
    series = results_path.with_suffix(".metrics.jsonl") if results_path else None
    if series is not None:
        series.unlink(missing_ok=True)
    kube = cluster.kubectl(watch["kube_context"], timeout_seconds=max(10.0, watch["sample_seconds"]))
    ui.note(f"reading the install's metrics in namespace {watch['namespace']} every {watch['sample_seconds']:g} s" + (f" into {series}" if series else ""))
    return cluster.Collector(kube, watch["namespace"], watch["release"], watch["sample_seconds"], series, data_namespace=watch["data_namespace"])


def _cluster(samples: list[dict[str, Any]], watch: dict[str, Any], outcome: Any, settings: LoadSettings, profile: Profile) -> tuple[dict[str, Any], dict[str, Any]]:
    if not watch["namespace"]:
        return NOT_READ
    if not samples:
        return {}, {"read": False, "why": "no sample was taken"}
    start = outcome.started_at.timestamp() + settings.ramp_up_seconds
    write = outcome.write
    traces = write.steady_traces_sent / settings.duration_seconds if write.mode == "open-loop" else write.traces_sent / (write.duration_seconds or 1)
    metrics, section = cluster.summarize(samples, (start, start + settings.duration_seconds), traces * profile.runs_per_trace if traces else None)
    return metrics, {"namespace": watch["namespace"], "release": watch["release"], "sample_seconds": watch["sample_seconds"], **section}


def _app_version(client: Client) -> str | None:
    """The LangSmith release the install serves. A failed read is unknown, never a version: compare
    then says the version was not measured instead of judging it."""
    try:
        return str(client.info.version) or None
    except Exception:  # noqa: BLE001 - an older or locked-down /info must not stop the run
        return None


def _emit(report: dict[str, Any], results_path: Path | None, json_output: bool) -> None:
    if results_path is not None:
        results_path.write_text(json.dumps(report, indent=2) + "\n")
        ui.note(f"results written to {results_path}")
    if json_output:
        json.dump(report, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        print_summary(report)


def _fmt(value: object) -> str:
    return "n/a" if value is None else f"{value:.3f}" if isinstance(value, float) else str(value)


def _s(value: float | None) -> str:
    return "n/a" if value is None else f"{value:.2f} s"


VERDICT = {None: "not measured", True: "pass", False: "fail"}


def print_summary(report: dict[str, Any]) -> None:
    """The results as the sizing package draws a plan: facts, then a table each for reads, lag and the targets."""
    write, lag, stored, fb = report["write"], report["lag"], report["stored"], report["feedback"]
    target = write["target_traces_per_second"]
    held = write.get("steady_traces_per_second")
    ui.facts([
        ("Install", f"LangSmith {(report.get('server') or {}).get('app_version') or 'version not read'}, project {report['project']}"),
        ("Write", f"{write['mode']}: {_fmt(write['achieved_traces_per_second'])} traces/s over the run" + (f", {_fmt(held)} held after the ramp" if held is not None else "") + (f", target {target:g}" if target else "")),
        ("Sent", f"{write['traces_sent']:,} traces, {write['runs_sent']:,} runs, {fb['sent']:,} feedback"),
        ("Errors", f"{write['run_errors']} runs, {fb['errors']} feedback, {report['errors']['upload']} uploads, {report['errors']['reads']} reads; {write['dropped_starts']} starts dropped"),
        ("Stored", f"{stored['runs_stored'] if stored['runs_stored'] is not None else 'not read'} of {stored['runs_sent']:,} runs" + (f", {stored['missing_runs']} missing" if stored["missing_runs"] else "") + (f" ({stored['error']})" if stored["error"] else "")),
        ("Schedule lag", f"p99 {_s(write['schedule_lag_seconds']['p99'])}: how late starts were against the rate"),
    ], f"Load test {report['test_id']}")
    classes = report["reads"]["classes"]
    if classes:
        rows = [(name, str(e["count"]), str(e["errors"]), str(e["skipped"]), _s(e["p50_seconds"]), _s(e["p95_seconds"]), _s(e["p99_seconds"]), e["component"]) for name, e in classes.items()]
        ui.table(Table("Reads", ("class", "n", "errors", "skipped", "p50", "p95", "p99", "served by"), rows))
    ui.table(Table("Send to readable", ("readable", "never readable", "p50", "p95", "p99", "max"),
                   [(f"{lag['readable']} of {lag['sampled']}", str(lag["never_readable"]), _s(lag["p50_seconds"]), _s(lag["p95_seconds"]), _s(lag["p99_seconds"]), _s(lag["max_seconds"]))],
                   f"A {lag['sample_share']:g} share of traces polled until readable, up to {lag['deadline_seconds']:g} s."))
    _print_cluster(report["cluster"])
    ui.heading("Targets")
    ui.verdicts([{"item": name, "verdict": VERDICT[e["passed"]], "detail": _target_detail(e)} for name, e in report["targets"].items()])
    if write["first_error"]:
        ui.warn(f"first error: {write['first_error']}")
    (ui.ok if report["passed"] else ui.error)("the run passed" if report["passed"] else "the run FAILED")
    ui.console.print()


def _yes(value: bool | None) -> str:
    return "not read" if value is None else "yes" if value else "NO: still climbing at the window's end"


def _print_cluster(section: dict[str, Any]) -> None:
    if not section.get("read"):
        ui.note(f"install metrics: {section.get('why')}")
        return
    rows = [(w, f"{c['cores_used']:.2f}", f"{c['runs_per_core']:.1f}" if "runs_per_core" in c else "") for w, c in section["coefficients"].items()]
    flushed = section["smithdb_rows_flushed_per_second"]
    ui.table(Table("The install under the load", ("workload", "cores used", "runs/s per core"), rows,
                   f"Over the {section['steady_samples']} samples after the ramp, at {section['runs_per_second_sent'] or 0:g} runs/s sent"
                   + (f"; SmithDB flushed {flushed:g} rows/s" if flushed is not None else "")
                   + f". Ingestion queue kept up: {_yes(section['kept_up']['ingestion_queue'])}; compaction kept up: {_yes(section['kept_up']['compaction'])}."))
    for what in section["unread"]:
        ui.warn(f"not read: {what}")


def _target_detail(entry: dict[str, Any]) -> str:
    if "observed_seconds" in entry:
        return f"{entry['observed']} {_s(entry['observed_seconds'])} against {entry['target_seconds']:g} s"
    if "missing" in entry:
        return "the stored count could not be read" if entry["missing"] is None else f"{entry['missing']} runs sent and not stored"
    return "set with --latency-limit-seconds" if entry["passed"] is None else "p95 time to hand a trace to the SDK"


if __name__ == "__main__":
    raise SystemExit(main())
