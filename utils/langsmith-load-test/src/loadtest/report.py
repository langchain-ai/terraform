"""What a set of runs showed, as figures for a deck and the numbers behind them.

`load-test-report OUT RUN_DIR...` reads every finished run in the folders (a results file and the
install's samples beside it), and writes OUT/report.html, OUT/figures/<figure>-light.png and -dark.png,
OUT/stats.json and OUT/stats.csv (every number a figure shows, per run) and OUT/runs/ (each run's own
files and logs, copied as they were). A figure's title is computed from the runs, never typed: rerun the
same runs and the same figures come back.

The figures are the sizing package's pages: the LangChain brand's tokens in light and dark, its faces and
logo read from --fonts and --logos at render time (never copied here), drawn by headless Chrome. Without
the faces the figures are drawn as labelled drafts.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import shutil
import statistics
import tempfile
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from langsmith_sizing import figures as fig
from langsmith_sizing import params as sizing_params
from langsmith_sizing import ui
from langsmith_sizing.summary import Table
from loadtest.cluster import smithdb_counter, smithdb_read

Sample = dict[str, Any]
Point = tuple[float, float]
TOOL = "langsmith-load-test"
# The brand allows about three categorical colours: the accent for the series a figure is about, the
# warn tokens for a real failure state, and a muted blue for the rest (its data-viz rules).
ACCENT, WARN, MUTED, RAMP = "var(--accent)", "var(--warn-line)", "var(--line)", ("var(--line)", "var(--frame)", "var(--accent)")
KIB = 1024


@dataclass
class Run:
    label: str
    folder: Path
    results: dict[str, Any]
    samples: list[Sample]
    stats: dict[str, Any] = field(default_factory=dict)

    @property
    def rate(self) -> float:
        """Runs a second sent after the ramp."""
        cluster = self.results.get("cluster") or {}
        if cluster.get("runs_per_second_sent"):
            return float(cluster["runs_per_second_sent"])
        w = self.results["write"]
        per_trace = w["runs_sent"] / w["traces_sent"] if w.get("traces_sent") else 1
        return float(w.get("steady_traces_per_second") or w.get("target_traces_per_second") or 0) * per_trace

    def minutes(self, s: Sample) -> float:
        return float(s["t"] - self.samples[0]["t"]) / 60


def load(folders: Sequence[Path]) -> list[Run]:
    """Every finished run in the folders, oldest first: a results file with its samples beside it."""
    runs = []
    for folder in folders:
        for res in sorted(folder.glob("*.json")):
            series = res.with_suffix(".metrics.jsonl")
            if not series.exists():
                continue
            samples = [json.loads(line) for line in series.read_text().splitlines() if line.strip()]
            results = json.loads(res.read_text())
            if samples and "write" in results:
                # Named by the folder and its parent (xs/2x): an experiment's sizes each have a 2x.
                runs.append(Run(f"{folder.parent.name}/{folder.name}", folder, results, samples))
    runs.sort(key=lambda r: r.results["started_at"])
    for r in runs:
        r.stats = stats(r)
    return runs


# -- the numbers --------------------------------------------------------------------------------


def _slope(points: Sequence[Point]) -> float | None:
    if len(points) < 3:
        return None
    mx, my = statistics.fmean(p[0] for p in points), statistics.fmean(p[1] for p in points)
    d = sum((x - mx) ** 2 for x, _ in points)
    return sum((x - mx) * (y - my) for x, y in points) / d if d else None


def series(run: Run, get: Callable[[Sample], float | None]) -> list[Point]:
    return [(run.minutes(s), v) for s in run.samples if (v := get(s)) is not None]


def redis_mib(s: Sample) -> float | None:
    v = s["redis"].get("used_memory")
    return None if v is None else v / KIB**2


def pending(level: str) -> Callable[[Sample], float | None]:
    return lambda s: s["smithdb"].get(f"ingest_pending_segment_entry_count{{level={level}}}")


def counter(key: str) -> Callable[[Sample], float | None]:
    """A SmithDB counter by family, or one series by its full key; 0 where SmithDB was read without it."""
    if "{" not in key:
        return lambda s: smithdb_counter(s, key)
    return lambda s: s["smithdb"].get(key, 0.0) if smithdb_read(s) else None


def drops(points: Sequence[Point], share: float = 0.5) -> list[float]:
    """The minutes at which a gauge fell by more than share of its value: a compaction merging segments."""
    return [b[0] for a, b in zip(points, points[1:], strict=False) if a[1] and b[1] < a[1] * (1 - share)]


def lead(events: Sequence[float], after: Sequence[float]) -> float | None:
    """The mean minutes from each event to the next one in after; None when no event has one."""
    gaps = [min(f - m for f in after if f >= m) for m in events if any(f >= m for f in after)]
    return statistics.fmean(gaps) if gaps else None


def rises(points: Sequence[Point]) -> list[float]:
    """The minutes at which a counter went up: one entry a sample it rose in."""
    return [b[0] for a, b in zip(points, points[1:], strict=False) if b[1] > a[1]]


def _delta(points: Sequence[Point]) -> float | None:
    return points[-1][1] - points[0][1] if len(points) > 1 else None


def stats(run: Run) -> dict[str, Any]:
    r, w = run.results, run.results["write"]
    redis = series(run, redis_mib)
    slope = _slope(redis)
    reads = (r.get("reads") or {}).get("classes", {})
    cores = {k: v.get("cores_used") for k, v in ((r.get("cluster") or {}).get("coefficients") or {}).items()}
    feedback = series(run, counter("compaction_jobs_executed{status=success,job_kind=feedback_compaction}"))
    fanout = series(run, counter("query_fanout_limit_exceeded_total"))
    l1 = series(run, pending("L1"))
    maxmem = [s["redis"]["maxmemory"] for s in run.samples if s["redis"].get("maxmemory")]
    return {
        "run": run.label, "started_at": r["started_at"], "app_version": (r.get("server") or {}).get("app_version"),
        "runs_per_second": round(run.rate, 2), "minutes": round(run.minutes(run.samples[-1]), 1),
        "runs_sent": w["runs_sent"], "runs_stored": (r.get("stored") or {}).get("runs_stored"),
        "lag_p50_s": r["lag"].get("p50_seconds"), "lag_p95_s": r["lag"].get("p95_seconds"), "lag_p99_s": r["lag"].get("p99_seconds"),
        "read_p99_s": {k: v.get("p99_seconds") for k, v in reads.items()},
        "read_errors": {k: v.get("errors", 0) for k, v in reads.items()},
        "cores": cores,
        "redis_mib_per_min": slope,
        "redis_kib_per_run": None if slope is None or not run.rate else slope * KIB / (run.rate * 60),
        "redis_maxmemory_mib": max(maxmem) / KIB**2 if maxmem else None,
        "pending_l1_peak": max((v for _, v in l1), default=None),
        "compactions_at_min": [round(m, 1) for m in drops(l1)],
        "feedback_compactions_at_min": [round(m, 1) for m in rises(feedback)],
        "fanout_refusals": _delta(fanout),
        "fanout_refusals_at_min": [round(m, 1) for m in rises(fanout)],
        "refusal_to_compaction_min": lead(rises(fanout), drops(l1)),
        "kept_up": ((r.get("cluster") or {}).get("kept_up") or {}).get("ingestion_queue"),
        "passed": r.get("passed"),
        "memory_peak_mib": {k: v.get("memory_peak_mib") for k, v in ((r.get("cluster") or {}).get("coefficients") or {}).items()},
        "redis_memory_peak_pct": ((r.get("metrics") or {}).get("redis-memory") or {}).get("peak"),
        "postgres_connections_peak": ((r.get("metrics") or {}).get("postgres-connections") or {}).get("peak"),
        "machine": (r.get("cluster") or {}).get("machine"),
    }


# -- drawing ------------------------------------------------------------------------------------

CHART_CSS = """
.chart text { font: 400 15px var(--font-mono); fill: var(--muted); }
.chart .strong { fill: var(--text); }
.chart .grid { stroke: var(--line); stroke-width: 1; opacity: 0.7; }
.chart .axis { stroke: var(--frame); stroke-width: 1.25; }
.chart .limit { stroke: var(--warn-line); stroke-width: 2.5; stroke-dasharray: 8 6; }
.legend { display: flex; flex-wrap: wrap; gap: 6px 22px; margin: 4px 0 12px; font: 400 15px var(--font-mono); color: var(--text-2); }
.legend i { display: inline-block; width: 14px; height: 14px; border-radius: 3px; margin-right: 8px; vertical-align: -2px; }
.note { font: 250 18px/1.4 var(--font-sans); color: var(--muted); margin: 12px 0 0; max-width: 1340px; }
"""
# What a person does in the UI, for each read the load test makes.
READS = {"read_trace": "open a trace", "list_traces": "list traces", "heavy_filter": "filter by metadata",
         "project_stats": "project stats", "feedback_stats": "feedback stats"}
STEPS = (1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10)


def nice(top: float) -> float:
    """The smallest 1, 1.5, 2, 2.5, 3, 4, 5, 6 or 8 times a power of ten at or above top."""
    if top <= 0:
        return 1.0
    power = 10.0 ** math.floor(math.log10(top))
    return float(next(k * power for k in STEPS if k * power >= top * 0.999))


@dataclass
class Frame:
    """A plot area: data to pixel, and its grid, ticks and labels."""

    w: float
    h: float
    xmax: float
    ymax: float
    left: float = 84
    bottom: float = 52
    top: float = 18
    right: float = 24
    x_scale: bool = True

    def __post_init__(self) -> None:
        """ymax (and xmax, on a scale axis) arrive as the data's top and are rounded up to a whole step."""
        self.ystep = nice(self.ymax / 4)
        self.ymax = math.ceil(self.ymax / self.ystep - 1e-9) * self.ystep
        if self.x_scale:
            self.xstep = nice(self.xmax / 4)
            self.xmax = math.ceil(self.xmax / self.xstep - 1e-9) * self.xstep

    def x(self, v: float) -> float:
        return self.left + v / (self.xmax or 1) * (self.w - self.left - self.right)

    def y(self, v: float) -> float:
        return self.h - self.bottom - v / (self.ymax or 1) * (self.h - self.bottom - self.top)

    def grid(self, y_label: str, fmt: str = "{:g}") -> str:
        out = []
        for i in range(round(self.ymax / self.ystep) + 1):
            v = i * self.ystep
            out.append(f'<line class="grid" x1="{self.left}" x2="{self.w - self.right}" y1="{self.y(v):.1f}" y2="{self.y(v):.1f}"/>')
            out.append(f'<text x="{self.left - 12}" y="{self.y(v) + 5:.1f}" text-anchor="end">{fmt.format(v)}</text>')
        out.append(f'<line class="axis" x1="{self.left}" x2="{self.w - self.right}" y1="{self.y(0):.1f}" y2="{self.y(0):.1f}"/>')
        out.append(f'<text transform="translate(20,{(self.h - self.bottom + self.top) / 2:.0f}) rotate(-90)" text-anchor="middle">{fig.e(y_label)}</text>')
        return "".join(out)

    def x_ticks(self, ticks: Sequence[tuple[float, Sequence[str]]], x_label: str = "") -> str:
        out = []
        for v, lines in ticks:
            spans = "".join(f'<tspan x="{self.x(v):.1f}" dy="{0 if i == 0 else 19}"{" class=strong" if i == 0 else ""}>{fig.e(t)}</tspan>' for i, t in enumerate(lines))
            out.append(f'<text y="{self.y(0) + 26:.1f}" text-anchor="middle">{spans}</text>')
        if x_label:
            out.append(f'<text x="{(self.left + self.w - self.right) / 2:.0f}" y="{self.h - 6}" text-anchor="middle">{fig.e(x_label)}</text>')
        return "".join(out)

    def scale_ticks(self, x_label: str) -> str:
        return self.x_ticks([(i * self.xstep, [f"{i * self.xstep:g}"]) for i in range(round(self.xmax / self.xstep) + 1)], x_label)

    def limit(self, v: float) -> str:
        """A limit as a dashed line; the legend names it, so no label sits on the bars."""
        return f'<line class="limit" x1="{self.left}" x2="{self.w - self.right}" y1="{self.y(v):.1f}" y2="{self.y(v):.1f}"/>'



def svg(frame: Frame, inner: Sequence[str]) -> str:
    return f'<svg class="chart" width="{frame.w:.0f}" height="{frame.h:.0f}" viewBox="0 0 {frame.w:.0f} {frame.h:.0f}">{"".join(inner)}</svg>'


def line(frame: Frame, points: Sequence[Point], colour: str, width: float = 3) -> str:
    d = " ".join(f"{'M' if i == 0 else 'L'}{frame.x(x):.1f},{frame.y(y):.1f}" for i, (x, y) in enumerate(points))
    return f'<path d="{d}" fill="none" stroke="{colour}" stroke-width="{width}" stroke-linejoin="round" stroke-linecap="round"/>'


def dot(frame: Frame, x: float, y: float, colour: str, r: float = 7) -> str:
    return f'<circle cx="{frame.x(x):.1f}" cy="{frame.y(y):.1f}" r="{r}" fill="{colour}"/>'


def bar(frame: Frame, x0: float, x1: float, v: float, colour: str) -> str:
    return f'<rect x="{frame.x(x0):.1f}" y="{frame.y(v):.1f}" width="{frame.x(x1) - frame.x(x0):.1f}" height="{max(frame.y(0) - frame.y(v), 0):.1f}" rx="3" fill="{colour}"/>'


LIMIT = "limit"


def legend(items: Sequence[tuple[str, str]]) -> str:
    """Each series by its colour; a LIMIT entry is drawn as the dashed line it names."""
    def key(c: str) -> str:
        return ('<i style="height:0;border-top:2.5px dashed var(--warn-line);border-radius:0;width:22px"></i>' if c == LIMIT
                else f'<i style="background:{c}"></i>')
    return '<div class="legend">' + "".join(f"<span>{key(c)}{fig.e(t)}</span>" for t, c in items) + "</div>"


def run_ticks(runs: Sequence[Run], stored: bool = False) -> list[tuple[float, list[str]]]:
    """Each run under its group: its rate, what kind of run it was, and optionally what it stored."""
    out = []
    for i, r in enumerate(runs):
        lines = [f"{r.rate:g} runs/s", r.label.rsplit("/", 1)[-1]]
        if stored:
            lines.append(f"{r.stats['runs_stored']:,} of {r.stats['runs_sent']:,}")
        out.append((i + 0.5, lines))
    return out


def target(runs: Sequence[Run], promise: str) -> float | None:
    return next((t["target_seconds"] for r in runs if (t := (r.results.get("targets") or {}).get(promise))), None)


def times(rate: float, design: float | None) -> str:
    return f", {round(rate / design, 1):g} times the design rate" if design else ""


# -- the figures --------------------------------------------------------------------------------
# Each returns (title, subtitle, body), or None when its runs did not measure what it shows. A title
# states what the runs found, computed from them.

Made = tuple[str, str, str] | None


def held(runs: Sequence[Run], design: float | None) -> Made:
    lost = [r for r in runs if r.stats["runs_stored"] != r.stats["runs_sent"]]
    top = max(runs, key=lambda r: r.rate)
    title = (f"Every run was stored at every rate tried, up to {top.rate:g} runs/s{times(top.rate, design)}" if not lost
             else f"Runs went missing at {', '.join(f'{r.rate:g}' for r in lost)} runs/s")
    goal = target(runs, "stored_within_seconds_p99")
    frame = Frame(1472, 470, len(runs), max([r.stats["lag_p99_s"] or 0 for r in runs] + [(goal or 0) * 1.1]), bottom=100, x_scale=False)
    inner = [frame.grid("seconds from send to readable"), frame.x_ticks(run_ticks(runs, stored=True))]
    for i, r in enumerate(runs):
        for j, key in enumerate(("lag_p50_s", "lag_p95_s", "lag_p99_s")):
            inner.append(bar(frame, i + 0.2 + j * 0.2, i + 0.37 + j * 0.2, r.stats[key] or 0, RAMP[j]))
    if goal:
        inner.append(frame.limit(goal))
    sub = (f"{len(runs)} runs on one install, in the order they were made. Each bar is how long a run took from being sent "
           "to being returned by the query API; under each rate, the runs stored of the runs sent.")
    items = [("p50", RAMP[0]), ("p95", RAMP[1]), ("p99", RAMP[2])] + ([(f"target: p99 under {goal:g} s", LIMIT)] if goal else [])
    return title, sub, legend(items) + svg(frame, inner)


def cpu(runs: Sequence[Run], design: float | None) -> Made:
    measured = [r for r in runs if r.stats["cores"]]
    if not measured:
        return None
    run = max(measured, key=lambda r: r.rate)
    lite = sizing_params.values(sizing_params.load())["lite.measured"]
    planned = {w: c["base"] + c["per_unit"] * run.rate for w, c in lite["workloads"].items() if c["work"] in ("offered", "processed")}
    rows = sorted(((w, c or 0) for w, c in run.stats["cores"].items() if (c or 0) >= 0.02 or w in planned), key=lambda x: -max(x[1], planned.get(x[0], 0)))
    frame = Frame(1472, 120 + 70 * len(rows), len(rows), max([c for _, c in rows] + [planned.get(w, 0) for w, _ in rows]) * 1.1, bottom=70, x_scale=False)
    inner = [frame.grid("cores"), frame.x_ticks([(i + 0.5, [w]) for i, (w, _) in enumerate(rows)])]
    for i, (w, used) in enumerate(rows):
        inner.append(bar(frame, i + 0.18, i + 0.48, used, ACCENT))
        if w in planned:
            inner.append(bar(frame, i + 0.52, i + 0.82, planned[w], MUTED))
            inner.append(f'<text x="{frame.x(i + 0.67):.1f}" y="{frame.y(planned[w]) - 10:.1f}" text-anchor="middle">{planned[w]:.2f}</text>')
        inner.append(f'<text class="strong" x="{frame.x(i + 0.33):.1f}" y="{frame.y(used) - 10:.1f}" text-anchor="middle">{used:.2f}</text>')
    used_sum = sum(c for w, c in rows if w in planned)
    plan_sum = sum(planned[w] for w, _ in rows if w in planned)
    total = sum(c for _, c in rows)
    title = (f"At {run.rate:g} runs/s{times(run.rate, design)}, the install used {total:.1f} cores; the services the plan sizes "
             f"by rate used {used_sum:.1f} of the {plan_sum:.1f} it budgets them")
    sub = (f"Cores each workload used over the window after the ramp, beside the plan's cores for the same rate "
           f"(base plus cores per run/s, before its {lite['headroom']:g}x headroom). SmithDB has no per-run coefficient: "
           "the plan sizes it by its tier.")
    return title, sub, legend([("used", ACCENT), ("planned, before headroom", MUTED)]) + svg(frame, inner)


def redis_cost(runs: Sequence[Run], _design: float | None) -> Made:
    with_redis = sorted((r for r in runs if r.stats["redis_kib_per_run"]), key=lambda r: r.rate)
    if len(with_redis) < 2:
        return None
    per_run = [r.stats["redis_kib_per_run"] for r in with_redis]
    mean = statistics.fmean(per_run)
    frame = Frame(1472, 430, with_redis[-1].rate * 1.15, max(per_run) * 1.6)
    inner = [frame.grid("KiB a run in Redis"), frame.scale_ticks("runs/s sent")]
    inner.append(line(frame, [(0, mean), (frame.xmax, mean)], MUTED, 2))
    by_rate: dict[float, list[float]] = {}
    for r in with_redis:
        inner.append(dot(frame, r.rate, r.stats["redis_kib_per_run"], ACCENT, 9))
        by_rate.setdefault(r.rate, []).append(r.stats["redis_kib_per_run"])
    for rate, values in by_rate.items():
        inner.append(f'<text class="strong" x="{frame.x(rate):.1f}" y="{frame.y(max(values)) - 18:.1f}" text-anchor="middle">{", ".join(f"{v:.2f}" for v in values)}</text>')
    spread = 100 * (max(per_run) - min(per_run)) / mean
    title = f"Redis keeps {mean:.1f} KiB for each run, at every rate from {with_redis[0].rate:g} to {with_redis[-1].rate:g} runs/s"
    sub = (f"The slope of Redis's memory over each run, divided by the run's rate; {len(with_redis)} runs agree within {spread:.0f}%. "
           "So Redis holds the rate times this cost times how long runs are kept.")
    return title, sub, legend([("one run", ACCENT), (f"mean, {mean:.2f} KiB", MUTED)]) + svg(frame, inner)


def redis_sustained(runs: Sequence[Run], design: float | None, expiry_hours: float = 6) -> Made:
    with_redis = [r for r in runs if r.stats["redis_kib_per_run"] and r.stats["redis_maxmemory_mib"]]
    if not with_redis:
        return None
    kib = statistics.fmean(r.stats["redis_kib_per_run"] for r in with_redis)
    maxmem_gib = with_redis[-1].stats["redis_maxmemory_mib"] / KIB
    gib_per_rate = kib * expiry_hours * 3600 / KIB**2
    ceiling = maxmem_gib / gib_per_rate
    frame = Frame(1472, 430, ceiling * 1.2, maxmem_gib * 1.25)
    inner = [frame.grid("GiB Redis holds, sustained"), frame.scale_ticks("runs/s, sustained")]
    inner.append(line(frame, [(0, 0), (frame.xmax, frame.xmax * gib_per_rate)], ACCENT))
    inner.append(frame.limit(maxmem_gib))
    for r in with_redis:
        inner.append(dot(frame, r.rate, r.rate * gib_per_rate, ACCENT))
    if design:
        inner.append(dot(frame, design, design * gib_per_rate, "var(--good)", 9))
    title = f"Sustained, Redis would reach its maxmemory at about {ceiling:,.0f} runs/s{times(ceiling, design)}"
    sub = (f"A projection, not a run: the measured {kib:.2f} KiB a run times the rate, kept {expiry_hours:g} hours (the default expiry) "
           "before Redis lets a run go. Dots mark the rates the runs held; maxmemory is the install's own, as it reported it. "
           "Runs left unprocessed during a stall cost more than this, which is what maxmemory's margin is for.")
    items = [("projected", ACCENT), (f"maxmemory, {maxmem_gib:.1f} GiB", LIMIT)] + ([("design rate", "var(--good)")] if design else [])
    return title, sub, legend(items) + svg(frame, inner)


def segments(runs: Sequence[Run], _design: float | None) -> Made:
    with_l1 = [r for r in runs if r.stats["pending_l1_peak"] is not None]
    if not with_l1:
        return None
    run = max(with_l1, key=lambda r: (r.stats["fanout_refusals"] or 0, r.stats["minutes"]))
    l1 = series(run, pending("L1"))
    refused = rises(series(run, counter("query_fanout_limit_exceeded_total")))
    # A refusal is counted by the first sample after it, so it is drawn where the interval began.
    before = {b[0]: a for a, b in zip(l1, l1[1:], strict=False)}
    frame = Frame(1472, 440, l1[-1][0], max(v for _, v in l1) * 1.1)
    inner = [frame.grid("segments waiting for compaction"), frame.scale_ticks("minutes into the run")]
    inner.append(line(frame, l1, ACCENT))
    inner.extend(dot(frame, *before[m], WARN, 9) for m in refused if m in before)
    gap = run.stats["refusal_to_compaction_min"]
    if refused and gap is not None:
        title = f"Queries were refused only at the top of the segment pile, {gap:.1f} minutes before compaction merged it"
    else:
        title = f"Segments waiting for compaction climb and are merged on a cycle, peaking at {max(v for _, v in l1):,.0f}"
    sub = (f"{run.rate:g} runs/s for {run.stats['minutes']:g} minutes. SmithDB writes small segments as runs arrive and compaction "
           "merges them; a query that would scan more than SmithDB's partition limit is refused with a 429, "
           "\"Too many concurrent partitions\".")
    items = [("segments waiting (L1)", ACCENT)] + ([(f"a query refused ({run.stats['fanout_refusals']:g} in all)", WARN)] if refused else [])
    return title, sub, legend(items) + svg(frame, inner)


def reads(runs: Sequence[Run], _design: float | None) -> Made:
    classes = [c for c in READS if any(c in r.stats["read_p99_s"] for r in runs)]
    if not classes:
        return None
    colour = {c: ACCENT if c == "read_trace" else WARN if c == "feedback_stats" else MUTED for c in classes}
    frame = Frame(1472, 470, len(runs), max((v or 0) for r in runs for v in r.stats["read_p99_s"].values()) * 1.1, bottom=80, x_scale=False)
    inner = [frame.grid("p99 seconds"), frame.x_ticks(run_ticks(runs))]
    width = 0.8 / len(classes)
    for i, r in enumerate(runs):
        for j, c in enumerate(classes):
            inner.append(bar(frame, i + 0.1 + j * width, i + 0.1 + (j + 0.82) * width, r.stats["read_p99_s"].get(c) or 0, colour[c]))
    goal = target(runs, "trace_load_seconds_p99")
    if goal:
        inner.append(frame.limit(goal))
    over = [r for r in runs if (r.stats["read_p99_s"].get("read_trace") or 0) > (goal or math.inf)]
    failed = sum(r.stats["read_errors"].get("feedback_stats", 0) for r in runs)
    title = ("Opening a trace stayed under its target in every run; feedback stats is the slowest read and the only one refused"
             if not over and failed else "Opening a trace stayed under its target in every run" if not over
             else f"Opening a trace missed its target at {', '.join(f'{r.rate:g}' for r in over)} runs/s")
    sub = (f"The 99th percentile of each read a person makes in the UI, made at {statistics.fmean(r.results['reads'].get('target_requests_per_second') or 0 for r in runs):g} "
           f"a second while the load ran. Feedback stats was refused {failed:,} times in all: SmithDB refusing a query over too many partitions.")
    items = [(READS[c], colour[c]) for c in classes] + ([(f"target to open a trace: p99 under {goal:g} s", LIMIT)] if goal else [])
    return title, sub, legend(items) + svg(frame, inner)


FIGURES: dict[str, Callable[[Sequence[Run], float | None], Made]] = {
    "held": held, "cpu": cpu, "redis-cost": redis_cost, "redis-sustained": redis_sustained, "segments": segments, "reads": reads,
}


def pages(runs: Sequence[Run], design: float | None) -> dict[str, str]:
    source = f"{len(runs)} runs, {runs[0].stats['started_at'][:10]}, LangSmith {runs[-1].stats['app_version']}; load-test-report"
    out: dict[str, str] = {}
    for name, make in FIGURES.items():
        made = make(runs, design)
        if made:
            title, sub, body = made
            out[name] = fig._page(f"Figure {len(out) + 1}", fig.e(title), fig.e(sub), f"<style>{CHART_CSS}</style>{body}", fig.e(source), tool=TOOL)
    return out


# -- writing ------------------------------------------------------------------------------------

FLAT = ("run", "started_at", "runs_per_second", "minutes", "runs_sent", "runs_stored", "lag_p50_s", "lag_p95_s", "lag_p99_s",
        "redis_kib_per_run", "redis_maxmemory_mib", "pending_l1_peak", "fanout_refusals", "kept_up", "passed")


def write_stats(runs: Sequence[Run], out: Path) -> None:
    (out / "stats.json").write_text(json.dumps([r.stats for r in runs], indent=2) + "\n")
    with (out / "stats.csv").open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(FLAT)
        writer.writerows([r.stats.get(k) for k in FLAT] for r in runs)


def copy_runs(runs: Sequence[Run], out: Path) -> None:
    for folder in dict.fromkeys(r.folder for r in runs):
        dest = out / "runs" / folder.name
        shutil.copytree(folder, dest, dirs_exist_ok=True, ignore=shutil.ignore_patterns("kubeconfig", "*.env"))


def render(built: dict[str, str], out: Path, fonts_dir: Path | None, logos_dir: Path | None, draft: bool) -> None:
    fonts, missing = fig.faces(fonts_dir)
    if missing and not draft:
        raise SystemExit(f"the brand faces are missing ({', '.join(missing)}): check out ps-ops-center and content-studio beside this repository (or set PS_OPS_CENTER and CONTENT_STUDIO), give --fonts DIR, or --draft for a labelled draft")
    note = f"Drawn without the brand faces ({', '.join(missing)} missing); not for publishing." if missing else ""
    binary = fig.chrome()
    (out / "figures").mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for name, markup in built.items():
            for theme in fig.THEMES:
                page = Path(tmp) / f"{name}-{theme}.html"
                page.write_text(fig.document(markup, theme, fonts, fig.logo(logos_dir, theme), note))
                fig.shoot(binary, page, out / "figures" / f"{name}-{theme}.png")


def index(runs: Sequence[Run], built: dict[str, str], out: Path) -> None:
    rows = "".join(
        f"<tr><td>{fig.name(r.label)}</td><td>{r.stats['runs_per_second']:g}</td><td>{r.stats['minutes']:g}</td>"
        f"<td>{r.stats['runs_stored']:,} of {r.stats['runs_sent']:,}</td><td>{r.stats['lag_p99_s'] or 0:.1f}</td>"
        f"<td>{(r.stats['redis_kib_per_run'] or 0):.2f}</td><td>{r.stats['fanout_refusals'] or 0:g}</td><td>{'yes' if r.stats['passed'] else 'no'}</td></tr>"
        for r in runs
    )
    pictures = "".join(
        f'<picture><source srcset="figures/{n}-dark.png" media="(prefers-color-scheme: dark)"><img src="figures/{n}-light.png" alt="{fig.e(n)}"></picture>'
        for n in built
    )
    css = (f":root{{{fig.THEME_CSS['light']}}}@media (prefers-color-scheme: dark){{:root{{{fig.THEME_CSS['dark']}}}}}"
           "body{background:var(--bg);color:var(--text);font:250 17px/1.45 'TWK Lausanne',Inter,sans-serif;margin:0 auto;max-width:1200px;padding:40px 16px}"
           "h1{font-weight:250;font-size:40px;margin:0 0 8px}table{border-collapse:collapse;width:100%;margin:24px 0;font:400 14px 'Aeonik Mono',ui-monospace,monospace}"
           "th,td{border-bottom:1px solid var(--line);padding:8px;text-align:right}th:first-child,td:first-child{text-align:left}"
           "img{width:100%;height:auto;border:1px solid var(--line);border-radius:12px;margin:18px 0}a{color:var(--accent-ink)}")
    page = (f'<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
            f"<title>Load test report</title><style>{css}</style></head><body><h1>Load test report</h1>"
            f"<p>{len(runs)} runs. Every number is in <a href=\"stats.json\">stats.json</a> and <a href=\"stats.csv\">stats.csv</a>; each run's own files and logs are under <a href=\"runs/\">runs/</a>.</p>"
            f"<table><tr><th>run</th><th>runs/s</th><th>minutes</th><th>stored</th><th>lag p99 s</th><th>Redis KiB a run</th><th>queries refused</th><th>passed</th></tr>{rows}</table>"
            f"{pictures}</body></html>")
    (out / "report.html").write_text(page)


def _cell(value: float | None, fmt: str, unit: str = "") -> str:
    return "" if value is None else f"{value:{fmt}}{unit}"


def held_rows(runs: Sequence[Run]) -> list[tuple[str, ...]]:
    """A row a run: the rate, whether it held, what was lost and how fast traces and reads came back."""
    rows: list[tuple[str, ...]] = []
    for r in runs:
        st = r.stats
        reads = {k: v for k, v in st["read_p99_s"].items() if v is not None}
        slowest = max(reads, key=lambda k: reads[k]) if reads else None
        lost = (st["runs_sent"] - st["runs_stored"]) if st["runs_stored"] is not None else None
        rows.append((r.label, _cell(st["runs_per_second"], ".0f"), "yes" if st["passed"] else "NO", _cell(lost, ",.0f"),
                     _cell(st["lag_p99_s"], ".1f", " s"), f"{reads[slowest]:.1f} s ({slowest})" if slowest else ""))
    return rows


def took_rows(runs: Sequence[Run]) -> list[tuple[str, ...]]:
    """A row a run: what the hardware gave to hold it, every pod together and the workloads that matter."""
    rows: list[tuple[str, ...]] = []
    for r in runs:
        st, m = r.stats, r.stats.get("machine") or {}
        disk = sum((d.get("written_mib_per_second") or 0) for d in m["disks"].values()) if m.get("disks") else None
        rows.append((r.label, _cell(m.get("pods_cores"), ".2f"), _cell(m.get("pods_throttled_share"), ".0%"),
                     _cell(st["cores"].get("smithdb"), ".2f"), _cell(st["cores"].get("postgres"), ".2f"),
                     _cell(st["redis_memory_peak_pct"], ".1f", "%"), _cell(disk, ".1f")))
    return rows


def main(argv: Sequence[str] | None = None) -> int:
    a = argparse.ArgumentParser(prog="load-test-report", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    a.add_argument("out", type=Path, help="the folder to write the report to")
    a.add_argument("runs", type=Path, nargs="+", help="folders holding finished runs (a results file and its .metrics.jsonl)")
    a.add_argument("--design", type=float, help="the install's design rate in runs/s, to say a rate as a multiple of it")
    a.add_argument("--fonts", type=Path, help="the folder holding the brand's four font files")
    a.add_argument("--logos", type=Path, help="the folder holding langchain-on-light.svg and langchain-on-dark.svg")
    a.add_argument("--draft", action="store_true", help="draw without the faces, each figure labelled as a draft")
    x = a.parse_args(argv)
    runs = load(x.runs)
    if not runs:
        a.error(f"no finished run in {', '.join(map(str, x.runs))}: a results file with its .metrics.jsonl beside it")
    x.out.mkdir(parents=True, exist_ok=True)
    built = pages(runs, x.design)
    write_stats(runs, x.out)
    copy_runs(runs, x.out)
    render(built, x.out, x.fonts, x.logos, x.draft)
    index(runs, built, x.out)
    ui.table(Table("What each run held", ("run", "runs/s", "held", "runs lost", "readable p99", "slowest read p99"), held_rows(runs)))
    ui.table(Table("What it took", ("run", "all pods, cores", "throttled", "SmithDB", "Postgres", "Redis peak", "disk MiB/s"), took_rows(runs),
                   "Cores are averages after the ramp; throttled is the share of the pods' CPU periods held back by the size's cap; "
                   "disk is written across every disk."))
    ui.note(f"Figures, every number and each run's files: {x.out / 'report.html'}")
    ui.console.print()
    return 0
