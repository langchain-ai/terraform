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
from loadtest.profile import CONTENTS, SENDS, TRACES, Profile, ProfileError, Shape, from_file, from_params
from loadtest.results import NOT_READ, short_error
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
    shape.add_argument("--traces", choices=TRACES, help="simple (a flat tree of runs, each a size from the mix), agent (an application's model and tool calls, its context resent every call) or coding (a coding agent: every trace tools for dozens of turns, its context grown to hundreds of KB and then compacted)")
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
    cluster.add_argument("--prometheus", metavar="NS/SERVICE:PORT", help="read CPU from this Prometheus's cAdvisor series instead of each node's kubelet, for a kubeconfig without nodes/proxy")
    cluster.add_argument("--sample-seconds", type=float, default=15, help="seconds between samples; raise it on a cluster of hundreds of nodes, where each sample reads every node's cAdvisor")
    output = parser.add_argument_group("output")
    output.add_argument("--results", type=Path, help="write the langsmith-load-results/1 JSON here")
    output.add_argument("--latency-limit-seconds", type=float, help="fail if the p95 time to hand a trace to the SDK exceeds this limit")
    output.add_argument("--progress-seconds", type=float, default=defaults.progress_seconds, help="seconds between progress updates; 0 turns them off")
    output.add_argument("--feedback-drain-seconds", type=float, default=defaults.feedback_drain_seconds, help="after the load, how long to wait for feedback still in flight; the rest count as errors")
    output.add_argument("--json", action="store_true", help="print the results document to stdout; logs go to stderr")
    return parser


CLUSTER_OPTIONS = ("namespace", "data_namespace", "release", "kube_context", "sample_seconds", "prometheus")


def cluster_options(arguments: dict[str, Any]) -> dict[str, Any]:
    """Take the options for reading the install out of the parsed arguments; the rest are the load's."""
    return {name: arguments.pop(name) for name in CLUSTER_OPTIONS}


SHAPE_FLAGS = {
    "traces": "traces", "fields_per_side": "fields_per_side", "content": "content", "send": "send", "attachment_kib": "attachment_kib_per_run",
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

    total = settings.ramp_up_seconds + settings.duration_seconds
    last_line = [0.0]

    # One line rewritten in place at a terminal; a line a minute in a log. A line every 10 s made a
    # 10-minute soak 72 lines long (magus, 2026-11-25).
    def report_progress(traces: int, errors: int, elapsed_seconds: float) -> None:
        errors += upload_errors.qsize()
        line = f"  {elapsed_seconds:>4.0f} of {total:g} s   {traces:,} traces   {traces / elapsed_seconds:.2f} traces/s   {errors:,} errors"
        style = "warn" if errors else "muted"
        if ui.console.is_terminal:
            ui.console.print(line.ljust(PROGRESS_WIDTH), style=style, end="\r")
        elif elapsed_seconds - last_line[0] >= PROGRESS_LOG_SECONDS:
            last_line[0] = elapsed_seconds
            ui.console.print(line, style=style)

    client = None
    projects = Projects(project_names(project_name, profile.shape.projects), tuple(uuid4() for _ in range(profile.shape.projects)), profile.shape.project_skew)
    app_version = None
    try:
        if tracing_enabled:
            client, projects, app_version = _connect(profile, project_name, workspace_id, upload_errors)
        else:
            ui.note("tracing is off: payloads are generated locally and nothing is uploaded")
        outcome, samples = _load_while_reading(watch, results_path, lambda: asyncio.run(run_load_test(settings, profile, client, projects, report_progress)))
        if ui.console.is_terminal:
            ui.console.print()
    except Exception as error:  # noqa: BLE001 - turn setup and flush failures into CLI errors
        logger.error(f"Load test failed: Reason: {' '.join(str(error).splitlines())}")
        return SETUP_ERROR
    finally:
        if client is not None:
            client.close(timeout=0)

    upload_count = upload_errors.qsize()
    first_upload_error = short_error(str(upload_errors.get())) if upload_count else None
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
    mode = f"open loop at {settings.traces_per_second:g} traces/s" if settings.traces_per_second else f"closed loop, {settings.users} user{'s' if settings.users != 1 else ''}"
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
    return cluster.Collector(kube, watch["namespace"], watch["release"], watch["sample_seconds"], series, data_namespace=watch["data_namespace"], prometheus=watch["prometheus"])


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


def _s(value: float | None) -> str:
    return "n/a" if value is None else f"{value:.2f} s"


VERDICT = {None: "not measured", True: "pass", False: "fail"}


PROGRESS_WIDTH = 78
PROGRESS_LOG_SECONDS = 60
TARGET_NAMES = {
    "stored_within_seconds_p99": "readable in time", "trace_load_seconds_p99": "traces load in time",
    "no_missing_runs": "nothing lost", "send_latency_limit": "send latency",
}


def print_summary(report: dict[str, Any]) -> None:
    """One panel of what was sent and what came of it, the reads, the install under the load, then one
    verdict a promise. A table of one row (send to readable) and a second list of the same targets made
    a 10-minute run's summary longer than its progress (magus, 2026-11-26)."""
    write, lag, stored, fb = report["write"], report["lag"], report["stored"], report["feedback"]
    ui.facts([
        ("Install", f"LangSmith {(report.get('server') or {}).get('app_version') or 'version not read'}, project {report['project']}"),
        ("Sent", _sent(write, fb)),
        ("Stored", _stored(stored)),
        ("Errors", _errors(write, fb, report["errors"])),
        ("Readable", _readable(lag)),
        *([("Schedule", f"starts p99 {_s(write['schedule_lag_seconds']['p99'])} late against the rate")] if write["mode"] == "open-loop" else []),
    ], f"Load test {report['test_id']}")
    classes = report["reads"]["classes"]
    if classes:
        read_rows = [(name, f"{e['count']:,}", f"{e['errors']:,}", _s(e["p50_seconds"]), _s(e["p95_seconds"]), _s(e["p99_seconds"]), e["component"]) for name, e in classes.items()]
        ui.table(Table("Reads", ("class", "n", "errors", "p50", "p95", "p99", "served by"), read_rows))
    _print_cluster(report["cluster"])
    ui.heading("Verdict")
    every = target_rows(report)
    # A promise this run could not measure (reads off in a verify, one reading of the queue) is named once,
    # not given a row that says nothing.
    rows = [r for r in every if r["verdict"] != "not measured"]
    ui.verdicts(rows)
    unmeasured = [r["item"] for r in every if r["verdict"] == "not measured"]
    if unmeasured:
        ui.note("not measured in this run: " + ", ".join(unmeasured))
    if report["passed"]:
        ui.ok("every promise kept")
    else:
        broken = [r["item"] for r in rows if r["verdict"] == "fail"]
        ui.error("the run FAILED: " + (", ".join(broken) if broken else "errors during the run, counted under Errors"))
    ui.console.print()


def target_rows(report: dict[str, Any]) -> list[dict[str, Any]]:
    """The promises as verdicts; a send-latency limit only when one was set."""
    rows = [{"item": TARGET_NAMES.get(name, name), "verdict": VERDICT[e["passed"]], "detail": _target_detail(e)}
            for name, e in report["targets"].items() if not (name == "send_latency_limit" and e["passed"] is None)]
    kept = (report["cluster"].get("kept_up") or {}).get("ingestion_queue") if report["cluster"].get("read") else None
    if report["cluster"].get("read"):
        rows.append({"item": "ingestion kept up", "verdict": VERDICT[kept],
                     "detail": "the backlog at the window's end no larger than in its first half" if kept is not False else "the backlog still climbing at the window's end"})
    return rows


def _sent(write: dict[str, Any], fb: dict[str, Any]) -> str:
    rate = (f"{write['steady_traces_per_second']:.2f} traces/s after the ramp, target {write['target_traces_per_second']:g}"
            if write["mode"] == "open-loop" and write.get("steady_traces_per_second") is not None
            else f"{write['achieved_traces_per_second']:.2f} traces/s, {write['mode']}")
    return f"{write['traces_sent']:,} traces, {write['runs_sent']:,} runs, {fb['sent']:,} feedback; {rate}"


def _stored(stored: dict[str, Any]) -> str:
    if stored["runs_stored"] is None:
        return f"not read of {stored['runs_sent']:,} runs" + (f" ({stored['error']})" if stored["error"] else "")
    missing = stored["missing_runs"]
    return f"{stored['runs_stored']:,} of {stored['runs_sent']:,} runs" + (f": {missing:,} never stored" if missing else "")


def _errors(write: dict[str, Any], fb: dict[str, Any], errors: dict[str, Any]) -> str:
    counts = [(write["run_errors"], "traces refused"), (errors["upload"], "batches refused"), (fb["errors"], "feedback refused"),
              (errors["reads"], "reads failed"), (write["dropped_starts"], "starts dropped")]
    said = ", ".join(f"{n:,} {what}" for n, what in counts if n)
    if not said:
        return "none"
    cause = (write["first_error"] or "").split(" in LangSmith API.")[0]
    return said + (f"; first: {cause[:160]}" if cause else "")


def _readable(lag: dict[str, Any]) -> str:
    if not lag["sampled"]:
        return "no trace followed"
    never = f", {lag['never_readable']:,} never" if lag["never_readable"] else ""
    return (f"p50 {_s(lag['p50_seconds'])}, p95 {_s(lag['p95_seconds'])}, p99 {_s(lag['p99_seconds'])}: "
            f"{lag['readable']:,} of {lag['sampled']:,} traces followed ({lag['sample_share']:.0%}, up to {lag['deadline_seconds']:g} s){never}")


def _yes(value: bool | None) -> str:
    return "not read" if value is None else "yes" if value else "NO: still climbing at the window's end"


def _print_cluster(section: dict[str, Any]) -> None:
    if not section.get("read"):
        ui.note(f"install metrics: {section.get('why')}")
        return
    flushed = section["smithdb_rows_flushed_per_second"]
    rows = cluster_rows(section["coefficients"])
    if section["steady_samples"] < 2 and not rows:
        return
    # No per-pod reading (xs runs without Prometheus) printed the table's header over no rows (magus, 2026-11-25).
    note = (f"Averaged over {section['steady_samples']} readings after the ramp, at {section['runs_per_second_sent'] or 0:.1f} runs/s sent"
            + (f"; SmithDB flushed {flushed:.1f} rows/s" if flushed is not None else "")
            + f"; compaction kept up: {_yes(section['kept_up']['compaction'])}.")
    if rows:
        ui.table(Table("The install under the load", ("workload", "cores used", "runs/s per core", "memory peak"), rows, note))
    else:
        ui.note(note)
    for line in machine_lines(section.get("machine")):
        ui.note(line)
    if section["unread"]:
        ui.warn("not read: " + "; ".join(section["unread"]))


def machine_lines(m: dict[str, Any] | None) -> list[str]:
    """Every pod together against its machine, and each disk that moved: the hardware in one place."""
    if not m:
        return []
    def pct(v: float | None) -> str:
        return "not read" if v is None else f"{v:.0%}"
    cores = "not read" if m["pods_cores"] is None else f"{m['pods_cores']:.2f} cores"
    memory = "not read" if m["pods_memory_peak_mib"] is None else f"{m['pods_memory_peak_mib'] / 1024:.1f} GiB"
    lines = [f"Every pod together: {cores}, CPU throttled in {pct(m['pods_throttled_share'])} of periods, memory peak {memory}."]
    for device, d in m["disks"].items():
        written = "not read" if d["written_mib_per_second"] is None else f"{d['written_mib_per_second']:.1f} MiB/s"
        read = "not read" if d["read_mib_per_second"] is None else f"{d['read_mib_per_second']:.1f} MiB/s"
        busy = "" if d["busy_share"] is None else f", busy {d['busy_share']:.0%} of the time"
        lines.append(f"Disk {device}: {written} written, {read} read{busy}.")
    return lines


def cluster_rows(coefficients: dict[str, dict[str, Any]]) -> list[tuple[str, ...]]:
    """One row a workload. A workload seen only in the memory series has no CPU reading (a verify's 60 s
    window can hold too few samples for a rate), and formatting that None stopped verify's summary."""
    def num(value: float | None, fmt: str, unit: str = "") -> str:
        return "not read" if value is None else f"{value:{fmt}}{unit}"
    return [(w, num(c.get("cores_used"), ".2f"), num(c["runs_per_core"], ".1f") if "runs_per_core" in c else "",
             num(c.get("memory_peak_mib"), ".0f", " MiB")) for w, c in coefficients.items()]


def _target_detail(entry: dict[str, Any]) -> str:
    if "observed_seconds" in entry:
        return f"{entry['observed'].replace('_', ' ')} {_s(entry['observed_seconds'])}, against {entry['target_seconds']:g} s"
    if "missing" in entry:
        return "the stored count could not be read" if entry["missing"] is None else f"{entry['missing']:,} runs sent and not stored"
    return "set with --latency-limit-seconds" if entry["passed"] is None else "p95 time to hand a trace to the SDK"


if __name__ == "__main__":
    raise SystemExit(main())
