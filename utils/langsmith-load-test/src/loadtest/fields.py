"""The meaning and unit of every field of the results document (schema "langsmith-load-results/1").

`paths` walks a results document into its field paths with their types; `render` writes the table
for docs/results-fields.md. Walked from documents the real `runner.build_report` produces, so a
field added there without a row here, or a row for a field that is gone, fails the test.
`<class>` stands for a read class's name; `[]` for a list's item.
"""

from __future__ import annotations

from typing import Any

WILD = {"reads.classes": "<class>", "cluster.coefficients": "<workload>", "cluster.machine.disks": "<device>"}
OPAQUE = {
    "profile": "the load profile the run used, as langsmith-sizing writes it (its fields are in langsmith-sizing/docs/fields.md)",
    "metrics": "each of the plan's watch items the run read, keyed by its id (langsmith-sizing params watch.items; an autoscaler's is autoscaler-at-ceiling:<workload>): peak and end, or a mean, a share or a count during the run, with its unit; `langsmith-sizing compare` sets each against the plan's alarm level. Empty when the install was not read",
}

PERCENTILES = {"p50": "median", "p95": "95th percentile", "p99": "99th percentile", "max": "largest"}


def _distribution(table: dict[str, tuple[str, str]], prefix: str, what: str) -> None:
    table[prefix] = ("", what)
    for k, name in PERCENTILES.items():
        table[f"{prefix}.{k}"] = ("seconds", f"{name}; null when nothing was measured")


DESCRIPTIONS: dict[str, tuple[str, str]] = {
    "schema": ("", "langsmith-load-results/1; it changes only when a field's name, place or meaning does"),
    "test_id": ("", "the unique id in every run's metadata; the stored count filters on it"),
    "project": ("", "the LangSmith project the run wrote to"),
    "server": ("", "what the install said about itself"),
    "server.app_version": ("", "the LangSmith release it serves (its /info version), the images' version, not the chart's; null when tracing was off or the read failed"),
    "started_at": ("", "when the load started, ISO 8601 UTC"),
    "ended_at": ("", "when the load and the stored count finished, ISO 8601 UTC"),
    "profile": ("", OPAQUE["profile"]),
    "settings": ("", "the options the run used"),
    "settings.users": ("users", "closed-loop users"),
    "settings.duration_seconds": ("seconds", "how long to send, including the ramp"),
    "settings.ramp_up_seconds": ("seconds", "time to raise the rate from zero"),
    "settings.run_limit": ("traces", "stop after this many traces, or null for no limit"),
    "settings.pause_seconds": ("seconds", "a closed-loop user's pause between traces"),
    "settings.simulated_delay_ms": ("milliseconds", "added delay inside each run, to model a slow agent"),
    "settings.traces_per_second": ("traces/s", "the open-loop rate, or null in users mode"),
    "settings.max_in_flight": ("traces", "unfinished traces allowed before a start is dropped"),
    "settings.data_seed": ("", "the seed of the generated text, or null for a random one"),
    "settings.latency_limit_seconds": ("seconds", "the limit on the 95th-percentile send latency, or null for none"),
    "settings.progress_seconds": ("seconds", "how often progress is printed"),
    "settings.feedback_drain_seconds": ("seconds", "how long to wait for feedback in flight after the load"),
    "settings.read": ("", "whether reads were sent"),
    "settings.reads_per_second": ("requests/s", "the read rate, or null when no reads were sent"),
    "settings.read_min_age_seconds": ("seconds", "a trace is read only this long after it was sent"),
    "settings.lag_sample": ("fraction", "the share of traces polled for send-to-readable lag"),
    "settings.lag_deadline_seconds": ("seconds", "a sampled trace not readable by now is never readable"),
    "settings.lag_poll_seconds": ("seconds", "how often a sampled trace is polled"),
    "settings.settle_seconds": ("seconds", "how long to wait for the stored count to reach the sent count"),
    "write": ("", "what was sent"),
    "write.mode": ("", "open-loop (a rate) or closed-loop (users)"),
    "write.tracing_enabled": ("", "false means payloads were generated and nothing was uploaded"),
    "write.target_traces_per_second": ("traces/s", "the rate asked for, or null in closed-loop mode"),
    "write.achieved_traces_per_second": ("traces/s", "traces sent over the whole duration, ramp included"),
    "write.steady_traces_per_second": ("traces/s", "traces sent after the ramp over its duration; null outside open-loop mode"),
    "write.duration_seconds": ("seconds", "wall time of the load"),
    "write.traces_started": ("traces", "starts the schedule made, open-loop only"),
    "write.traces_sent": ("traces", "traces handed to the SDK"),
    "write.runs_sent": ("runs", "runs in those traces"),
    "write.payload_bytes_sent": ("bytes", "the inputs and outputs of those runs as generated, before the SDK serialises them; the denominator of every per-run store cost"),
    "write.payload_kib_per_run": ("KiB", "the same over the runs sent; null when none were"),
    "write.run_errors": ("errors", "runs the SDK reported an error for"),
    "write.dropped_starts": ("traces", "starts dropped for being over max_in_flight, never delayed"),
    "write.first_error": ("", "the first error message, or null"),
    "write.payload_shape": ("", "how each run's bytes were shaped and sent, after any flag replaced the profile's"),
    "write.payload_shape.fields_per_side": ("count", "fields the input and the output each split into, the size spread evenly"),
    "write.payload_shape.content": ("", "text (prose), json (a message list) or base64 (incompressible bytes)"),
    "write.payload_shape.send": ("", "post_then_patch (a create, then an update) or post_once (a finished run in one request)"),
    "write.payload_shape.attachment_kib_per_run": ("KiB", "attachment bytes sent with every run; 0 sent none"),
    "write.payload_shape.projects": ("count", "projects the traces spread over, the first the busiest"),
    "write.payload_shape.project_skew": ("exponent", "Zipf exponent of that spread; 0 is even"),
    "write.payload_shape.metadata_keys": ("count", "metadata keys a run carried beyond the test's own"),
    "write.payload_shape.batch_runs": ("runs", "the most runs the SDK sent in one request"),
    "feedback": ("", "feedback writes"),
    "feedback.per_trace": ("feedback/trace", "the rate the profile asks for"),
    "feedback.sent": ("feedback", "writes made"),
    "feedback.errors": ("errors", "writes that failed or were still pending after the drain"),
    "reads": ("", "reads sent"),
    "reads.enabled": ("", "reads were sent"),
    "reads.target_requests_per_second": ("requests/s", "the rate asked for, or null"),
    "reads.achieved_requests_per_second": ("requests/s", "reads made (errors included) over the duration"),
    "reads.dropped": ("requests", "reads dropped for being over max_in_flight"),
    "reads.classes": ("", "one entry per read class"),
    "reads.classes.<class>": ("", "one class: list_traces, read_trace, project_stats, feedback_stats or heavy_filter"),
    "reads.classes.<class>.component": ("", "the SmithDB component it exercises"),
    "reads.classes.<class>.count": ("requests", "reads that succeeded and were timed"),
    "reads.classes.<class>.errors": ("errors", "reads that failed"),
    "reads.classes.<class>.skipped": ("requests", "reads not made for want of a trace old enough"),
    "reads.classes.<class>.p50_seconds": ("seconds", "median latency; null when none succeeded"),
    "reads.classes.<class>.p95_seconds": ("seconds", "95th-percentile latency; null when none succeeded"),
    "reads.classes.<class>.p99_seconds": ("seconds", "99th-percentile latency; null when none succeeded"),
    "reads.classes.<class>.first_error": ("", "the first error message, or null"),
    "lag": ("", "how long a sampled trace took to become readable, measured from the start of its send"),
    "lag.sample_share": ("fraction", "the share of traces sampled"),
    "lag.sampled": ("traces", "traces sampled"),
    "lag.readable": ("traces", "sampled traces that became readable"),
    "lag.never_readable": ("traces", "sampled traces not readable by the deadline"),
    "lag.deadline_seconds": ("seconds", "the deadline"),
    "lag.poll_errors": ("errors", "polls that failed"),
    "lag.p50_seconds": ("seconds", "median lag; null when none was readable"),
    "lag.p95_seconds": ("seconds", "95th-percentile lag; null when none was readable"),
    "lag.p99_seconds": ("seconds", "99th-percentile lag; null when none was readable"),
    "lag.max_seconds": ("seconds", "largest lag; null when none was readable"),
    "stored": ("", "runs sent against runs the project holds for this test's id"),
    "stored.settle_seconds": ("seconds", "how long the count was given to settle"),
    "stored.traces_sent": ("traces", "traces handed to the SDK"),
    "stored.traces_stored": ("traces", "root runs stored; null when the count could not be read"),
    "stored.traces_missing": ("traces", "sent minus stored, never below zero; null when unread"),
    "stored.runs_sent": ("runs", "runs handed to the SDK"),
    "stored.runs_stored": ("runs", "runs stored; null when the count could not be read"),
    "stored.missing_runs": ("runs", "sent minus stored, never below zero; null when unread, which fails the run"),
    "stored.error": ("", "why the stored count could not be read, or null"),
    "errors": ("", "error totals"),
    "errors.upload": ("errors", "upload errors the SDK reported"),
    "errors.reads": ("errors", "read errors over all classes"),
    "targets": ("", "one verdict per promise; passed is null when nothing was measured, which neither passes nor fails the run"),
    "targets.stored_within_seconds_p99": ("", "the lag's 99th percentile against the profile's target; over 1% never readable fails it"),
    "targets.stored_within_seconds_p99.target_seconds": ("seconds", "the target"),
    "targets.stored_within_seconds_p99.observed": ("", "what was observed: lag_p99"),
    "targets.stored_within_seconds_p99.observed_seconds": ("seconds", "the observed 99th percentile; null when not measured"),
    "targets.stored_within_seconds_p99.passed": ("", "true, false, or null when not measured"),
    "targets.trace_load_seconds_p99": ("", "the read_trace 99th percentile against the profile's target"),
    "targets.trace_load_seconds_p99.target_seconds": ("seconds", "the target"),
    "targets.trace_load_seconds_p99.observed": ("", "what was observed: read_trace_p99"),
    "targets.trace_load_seconds_p99.observed_seconds": ("seconds", "the observed 99th percentile; null without reads"),
    "targets.trace_load_seconds_p99.passed": ("", "true, false, or null when not measured"),
    "targets.no_missing_runs": ("", "every run sent is stored"),
    "targets.no_missing_runs.missing": ("runs", "runs missing; null when the count could not be read"),
    "targets.no_missing_runs.passed": ("", "true, false, or null when unread"),
    "targets.send_latency_limit": ("", "the optional limit on the send latency"),
    "targets.send_latency_limit.passed": ("", "true, false, or null when no limit was set"),
    "metrics": ("", OPAQUE["metrics"]),
    "cluster": ("", "what the install itself did under the load, read through kubectl (--namespace)"),
    "cluster.read": ("", "whether the install was read; false leaves every other field out but why"),
    "cluster.why": ("", "why it was not read"),
    "cluster.namespace": ("", "the namespace read"),
    "cluster.release": ("", "the Helm release, the prefix of every workload's name"),
    "cluster.sample_seconds": ("seconds", "time between samples"),
    "cluster.samples": ("samples", "samples taken from the load's start until the stored count settled"),
    "cluster.steady_samples": ("samples", "samples inside the window after the ramp, the only ones coefficients come from"),
    "cluster.window": ("", "the window after the ramp"),
    "cluster.window.from": ("seconds", "its start, Unix time"),
    "cluster.window.to": ("seconds", "its end, Unix time"),
    "cluster.runs_per_second_sent": ("runs/s", "runs sent a second in the window, the numerator of every runs-per-core figure; null when none were"),
    "cluster.smithdb_rows_flushed_per_second": ("rows/s", "rows SmithDB ingestion flushed a second in the window (ingest_flush_rows); null when not read"),
    "cluster.kept_up": ("", "whether a backlog was still climbing at the window's end"),
    "cluster.kept_up.ingestion_queue": ("", "ingestion_queue.pending at the end no larger than the largest in the window's first half; null when not read"),
    "cluster.kept_up.compaction": ("", "the same for pending compaction jobs"),
    "cluster.coefficients": ("", "each workload's CPU in the window and its memory peak, from its containers' cAdvisor series"),
    "cluster.disk_bytes_per_run": ("bytes", "bytes each persistent volume gained a run sent across the window, keyed workload:mount path, read with du in its pod every few samples; null with fewer than two readings"),
    "cluster.coefficients.<workload>": ("", "one workload"),
    "cluster.coefficients.<workload>.cores_used": ("cores", "CPU cores it used on average, not requested"),
    "cluster.coefficients.<workload>.memory_peak_mib": ("MiB", "the most working-set memory its containers held together in any one sample"),
    "cluster.coefficients.<workload>.runs_per_core": ("runs/s per core", "runs sent a second over the cores it used; on the ingest path only, the figure sizing's ingest model rests on"),
    "cluster.machine": ("", "every pod together and each disk across the window, from Prometheus; null without one"),
    "cluster.machine.pods_cores": ("cores", "CPU cores every pod used together: the cgroup k3s runs them in, where a size's machine cap (emulate_machine) applies"),
    "cluster.machine.pods_throttled_share": ("share", "the share of the pods' CPU periods throttled: how often they met their cap"),
    "cluster.machine.pods_memory_peak_mib": ("MiB", "the most memory every pod held together in any one sample"),
    "cluster.machine.disks": ("", "each disk that read or wrote in the window, from node-exporter"),
    "cluster.machine.disks.<device>": ("", "one disk"),
    "cluster.machine.disks.<device>.read_mib_per_second": ("MiB/s", "read from it a second"),
    "cluster.machine.disks.<device>.written_mib_per_second": ("MiB/s", "written to it a second"),
    "cluster.machine.disks.<device>.busy_share": ("share", "the share of time it had a request in flight; near 1, the disk is what the stores wait on"),
    "cluster.unread": ("list", "what could not be read in some sample; a missing reading is unknown, never zero"),
    "passed": ("", "every measured target met, nothing missing, and no run, feedback, upload, read or stored-count error"),
}
for _prefix, _what in (("write.send_latency_seconds", "the time to hand a trace to the SDK"), ("write.schedule_lag_seconds", "how late each open-loop start was")):
    _distribution(DESCRIPTIONS, _prefix, _what)


def _kind(v: Any) -> str:
    if v is None:
        return "null"
    for t, name in ((bool, "boolean"), ((int, float), "number"), (str, "string"), (list, "list")):
        if isinstance(v, t):
            return name
    return "object"


def paths(documents: list[dict[str, Any]]) -> dict[str, set[str]]:
    """Every field path of the documents with the types it takes."""
    out: dict[str, set[str]] = {}

    def walk(v: Any, path: str) -> None:
        out.setdefault(path, set()).add(_kind(v))
        if path in OPAQUE or not isinstance(v, dict):
            return
        for k, child in v.items():
            walk(child, f"{path}.{WILD[path] if path in WILD else k}" if path else k)

    for document in documents:
        for k, v in document.items():
            walk(v, k)
    return out


def problems(found: dict[str, set[str]]) -> list[str]:
    """A field with no row, a row with no field, a number with no unit."""
    return (
        [f"no description for {p}" for p in sorted(found.keys() - DESCRIPTIONS.keys())]
        + [f"an entry for {p}, which no results document has" for p in sorted(DESCRIPTIONS.keys() - found.keys())]
        + [f"{p} is a number with no unit" for p in sorted(found.keys() & DESCRIPTIONS.keys()) if "number" in found[p] and not DESCRIPTIONS[p][0]]
    )


def render(found: dict[str, set[str]]) -> str:
    if bad := problems(found):
        raise ValueError("\n".join(bad))
    sections = list(dict.fromkeys(p.split(".")[0] for p in found))
    lines = [
        "# Results fields", "",
        "Generated by `make reference` (in `langsmith-sizing`) from the results documents the load test's own report builder writes.",
        "Do not edit it; a test fails when it differs from the code. The schema is `langsmith-load-results/1`: adding a field does not",
        "change that number, renaming or moving one does. `<class>` repeats once per read class.", "",
        "| Path | Type | Unit | Meaning |", "|:--|:--|:--|:--|",
    ]
    for path in sorted(found, key=lambda p: (sections.index(p.split(".")[0]), p)):
        unit, meaning = DESCRIPTIONS[path]
        kinds = " or ".join(sorted(found[path] - {"null"}) + ["null"] * ("null" in found[path]))
        lines.append(f"| `{path}` | {kinds} | {unit or '-'} | {meaning} |")
    return "\n".join(lines) + "\n"
