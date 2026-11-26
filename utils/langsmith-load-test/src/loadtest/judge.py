"""Whether an install works, and what it holds: verify, step and judge, for any install the test can reach.

    load-test-verify --namespace NS [--data-namespace NS] [--results F]
        ten traces, each polled until readable, the install read as they go; then one line a hop a
        trace crosses (accepted, Redis drained, SmithDB flushed, readable), and on the first that
        fails, that workload's last log lines. Exit 1 on a failed hop.
    load-test-judge RESULTS [--plan plan.json]
        a finished run: its targets, whether ingestion kept up, and each watch item against its alarm
        level (the plan's, or without one the levels params.yaml sets itself); what crossed is what
        saturated. Exit 1 when the run did not hold its load.
    load-test-step --traces-per-second X [load-test flags]
        the load at X x 0.5, 1, 1.5, 2, 3 and 4 in turn, each judged, until one does not hold: the
        rate the install holds, and what crossed first at the rate it did not.

A run holds its load when every target passed, nothing was lost and the ingestion backlog was not
still climbing at the window's end. A watch item past its level is observed, never failed (an
autoscaler scales on a backlog over its target): it says where to look.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import Any

from langsmith_sizing import compare, ui
from langsmith_sizing import params as sizing_params
from langsmith_sizing.model import watch
from langsmith_sizing.summary import Table
from loadtest import cluster

VERIFY_ARGS = ("--users", "1", "--run-limit", "10", "--duration-seconds", "60", "--pause-seconds", "0.5", "--lag-sample", "1",
               "--lag-deadline-seconds", "180", "--settle-seconds", "180", "--feedback-per-trace", "0")
STEPS = (0.5, 1.0, 1.5, 2.0, 3.0, 4.0)
# The workload whose logs explain a hop that failed.
HOP_WORKLOAD = {"accepted": "platform-backend", "drained": "ingest-queue", "flushed": "smithdb", "readable": "smithdb"}

Hop = tuple[str, str, bool | None, str]


def samples(results_path: Path) -> list[dict[str, Any]]:
    """The install's readings beside a results file (`<results>.metrics.jsonl`); empty when none were taken."""
    series = results_path.with_suffix(".metrics.jsonl")
    return [json.loads(line) for line in series.read_text().splitlines() if line.strip()] if series.exists() else []


def _seconds(value: float | None) -> str:
    return "n/a" if value is None else f"{value:.2f} s"


def _flushed(series: Sequence[dict[str, Any]]) -> float | None:
    """Rows SmithDB flushed between the first and the last reading that had the counter."""
    read = [rows for rows in map(cluster.flushed_rows, series) if rows is not None]
    return read[-1] - read[0] if len(read) >= 2 else None


def hops(results: dict[str, Any], series: Sequence[dict[str, Any]]) -> list[Hop]:
    """Each hop a trace crosses, in order: (hop, what, verdict, detail). A hop not read is None, never ok."""
    write, stored, lag = results["write"], results["stored"], results["lag"]
    refused = write["run_errors"] + results["errors"]["upload"]
    pending = series[-1].get("queues", {}).get("ingestion_queue.pending") if series else None
    flushed = _flushed(series)
    missing = stored.get("missing_runs")
    readable = None if missing is None else missing == 0 and lag["never_readable"] == 0
    return [
        ("accepted", f"{write['runs_sent']} runs sent to the API", refused == 0, write.get("first_error") or f"{refused} refused"),
        ("drained", "Redis's ingestion queue emptied", None if pending is None else pending == 0, "not read" if pending is None else f"{pending:g} pending"),
        ("flushed", "SmithDB wrote them", None if flushed is None else flushed > 0, "not read" if flushed is None else f"{flushed:g} rows"),
        ("readable", "every run sent can be queried", readable,
         stored.get("error") or f"{stored.get('runs_stored')} of {stored['runs_sent']} stored, {lag['never_readable']} never readable, p95 {_seconds(lag.get('p95_seconds'))}"),
    ]


def held(results: dict[str, Any]) -> bool:
    return bool(results["passed"]) and results.get("cluster", {}).get("kept_up", {}).get("ingestion_queue") is not False


def _topology(series: Sequence[dict[str, Any]]) -> str:
    """cluster when SmithDB runs as separate services, unified when one pod: the watch list differs."""
    workloads = {w for s in series for w in s.get("replicas", {})}
    return "cluster" if any(w.startswith("smithdb-") for w in workloads) else "unified"


def watch_items(plan: dict[str, Any] | None, topology: str) -> list[dict[str, Any]]:
    """The plan's watch list, or without a plan the one params.yaml makes with only its own levels:
    a level read from a chart or a plan is unknown here, so that item is observed."""
    if plan is not None:
        return list(plan["watch"])
    p = sizing_params.values(sizing_params.load())
    known = [*p["watch.metrics_smithdb"]["critical"], *p["watch.metrics_smithdb"]["all_only"], *p["watch.metrics_other"]]
    return watch.items(p["watch.items"], known, resolve=lambda ref: p.get(ref.removeprefix("param:")) if ref.startswith("param:") else None,
                       topology=topology, scale={})


def signals(results: dict[str, Any], plan: dict[str, Any] | None, series: Sequence[dict[str, Any]]) -> list[dict[str, Any]]:
    """Every verdict for the run: its targets, then each watch item, as sizing's compare words them."""
    kept = results.get("cluster", {}).get("kept_up", {}).get("ingestion_queue")
    backlog = {"item": "kept-up", "verdict": compare.NOT_MEASURED if kept is None else compare.PASS if kept else compare.FAIL,
               "detail": "the ingestion backlog at the window's end against its largest in the first half"}
    return [backlog, *compare.run_verdicts(results, watch_items(plan, _topology(series)))]


def crossed(verdicts: Sequence[dict[str, Any]]) -> list[dict[str, Any]]:
    return [v for v in verdicts if "ABOVE the alarm level" in v["detail"]]


def show_logs(results: dict[str, Any], workload: str, context: str | None) -> None:
    where = results.get("cluster", {})
    if not where.get("namespace"):
        return
    kube = cluster.kubectl(context, timeout_seconds=30)
    text = kube(["logs", "-n", where["namespace"], "-l", f"{cluster.COMPONENT}={where.get('release', 'langsmith')}-{workload}", "--tail=15", "--prefix"])
    ui.heading(f"{workload}'s last log lines")
    for line in (text or "(could not read them)\n").splitlines()[-15:]:
        ui.note(line[:200])


def run_load(argv: Sequence[str]) -> int:
    """One run of the load test, in its own process: a run keeps state (its logging, the SDK's client)
    a second run in the same process would inherit."""
    return subprocess.run([sys.executable, "-c", "from loadtest.cli import main; raise SystemExit(main())", *argv], check=False).returncode


def _option(argv: Sequence[str], flag: str) -> str | None:
    return argv[argv.index(flag) + 1] if flag in argv and argv.index(flag) + 1 < len(argv) else None


def verify_main(argv: Sequence[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if "--namespace" not in args:
        ui.error("load-test-verify needs --namespace: it reads the install to say where traces stop")
        return 2
    results_path = Path(_option(args, "--results") or "out/verify.json")
    results_path.parent.mkdir(parents=True, exist_ok=True)
    if "--results" not in args:
        args += ["--results", str(results_path)]
    if run_load([*VERIFY_ARGS, *args]) not in (0, 1) or not results_path.exists():
        ui.error(f"the load test wrote no results to {results_path}")
        return 1
    results = json.loads(results_path.read_text())
    ui.heading("Where a trace goes")
    failed = None
    for hop, what, ok, detail in hops(results, samples(results_path)):
        line = f"{hop:<10} {what}  ({detail})"
        if ok:
            ui.ok(line)
        else:
            ui.warn(("NOT READ  " if ok is None else "FAILED  ") + line)
            failed = failed or (hop if ok is False else None)
    if failed:
        show_logs(results, HOP_WORKLOAD[failed], _option(args, "--kube-context"))
        ui.error(f"traces stop at {failed}; the run's results and log are beside {results_path}")
        return 1
    ui.ok(f"traces flow end to end: {results['stored']['runs_stored']} runs stored, readable in {_seconds(results['lag'].get('p95_seconds'))} (p95)")
    return 0


def judge_main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="load-test-judge", description="Whether a finished run held its load, and what saturated.")
    parser.add_argument("results", type=Path)
    parser.add_argument("--plan", type=Path, help="a sizing's plan.json: its watch list and levels; without it, params.yaml's own levels")
    a = parser.parse_args(argv)
    if not a.results.exists():
        parser.error(f"no results at {a.results}: the run did not finish, and its own output says why")
    results = json.loads(a.results.read_text())
    plan = json.loads(a.plan.read_text()) if a.plan else None
    series = samples(a.results)
    verdicts = signals(results, plan, series)
    over = {v["item"].removeprefix("watch:") for v in crossed(verdicts)}
    rows, unread = watch_table(results.get("metrics", {}), watch_items(plan, _topology(series)), over)
    # The targets are the run summary's verdict table; repeated here, every soak printed them twice
    # (magus, 2026-11-26). This is what the install showed while it held, or did not.
    if rows:
        ui.table(Table("Watched", ("item", "reading", "alarm at", ""), rows))
    if unread:
        ui.note("not read in this run: " + ", ".join(unread))
    if over:
        ui.warn("past its alarm level, where to look first: " + ", ".join(sorted(over)))
    (ui.ok if held(results) else ui.error)("held its load" if held(results) else "did not hold its load")
    return 0 if held(results) else 1


def _number(value: float) -> str:
    """Three significant figures, thousands grouped: 0.0134, 3.28, 76, 20,114."""
    return f"{value:,.0f}" if abs(value) >= 100 else f"{value:.3g}"


def reading_text(entry: dict[str, Any]) -> str:
    """One watch reading as a person reads it, its unit once at the end."""
    unit = entry.get("unit", "")
    if "completed_in_window" in entry:
        kinds = {key.rsplit("job_kind=", 1)[-1].rstrip("}"): n for key, n in entry["completed_in_window"].items()}
        return f"{_number(sum(kinds.values()))} {unit} ({', '.join(f'{k.removesuffix('_compaction')} {_number(n)}' for k, n in kinds.items())})"
    if "peak" in entry:
        return f"peak {_number(entry['peak'])}, end {_number(entry['end'])} {unit}"
    for key, words in (("during_run", "during the run"), ("mean", "mean"), ("share", "share")):
        if key in entry:
            return f"{_number(entry[key])} {unit} during the run" if key == "during_run" else f"{words} {_number(entry[key])} {unit}"
    return ", ".join(f"{k} {v}" for k, v in entry.items())


def watch_table(metrics: dict[str, Any], items: Sequence[dict[str, Any]], over: set[str]) -> tuple[list[tuple[str, ...]], list[str]]:
    """(a row a watch item read, the ids not read): the reading, the level it alarms at, and ABOVE when crossed."""
    rows: list[tuple[str, ...]] = []
    unread: list[str] = []
    for item in items:
        if item["id"] not in metrics:
            unread.append(item["id"])
            continue
        level = item["threshold"]
        at = f"{_number(level['value'])} {level['unit']}" if isinstance(level, dict) else "observed"
        rows.append((item["id"], reading_text(metrics[item["id"]]), at, "ABOVE" if item["id"] in over else ""))
    return rows, unread


def step_main(argv: Sequence[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    rate_text = _option(args, "--traces-per-second")
    if rate_text is None:
        ui.error("load-test-step needs --traces-per-second: the rate the steps multiply")
        return 2
    i = args.index("--traces-per-second")
    del args[i:i + 2]
    out = Path(_option(args, "--results") or "out/step.json")
    if "--results" in args:
        j = args.index("--results")
        del args[j:j + 2]
    out.parent.mkdir(parents=True, exist_ok=True)
    holds, last = None, None
    for factor in STEPS:
        rate = float(rate_text) * factor
        path = out.with_name(f"{out.stem}-{factor:g}x.json")
        ui.heading(f"step {factor:g}x: {rate:g} traces/s")
        if run_load([*args, "--traces-per-second", str(rate), "--results", str(path)]) not in (0, 1) or not path.exists():
            ui.error(f"the load test wrote no results to {path}")
            return 1
        last = json.loads(path.read_text())
        if not held(last):
            verdicts = signals(last, None, samples(path))
            ui.verdicts([v for v in verdicts if v["verdict"] == compare.FAIL] + crossed(verdicts))
            break
        holds = rate
    ui.heading("What it holds")
    ui.note(f"{holds:g} traces/s held" if holds is not None else f"not even {float(rate_text) * STEPS[0]:g} traces/s held")
    return 0
