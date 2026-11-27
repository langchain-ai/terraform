"""Experiments compared: what each size held and what it took, across every experiment folder given.

    load-test-experiments OUT EXPERIMENT [EXPERIMENT ...] [--fonts DIR] [--logos DIR] [--draft]

An experiment is Lite's `make experiment` folder: a settings file (its LABEL names it in the figures),
then a folder a size, each holding the plan it ran with (plan.json) and a folder a step (`1-1x`, `2-1x`,
`3-2x` ...; `1x`, `2x` from before steps were numbered) with the load test's soak.json and
soak.metrics.jsonl. Each step becomes one row of steps.csv (the load, what it held, what it took, at the
mean of the window after the ramp and at its spread across its minutes), and the figures in OUT/figures
compare every size and every experiment on one scale, in the brand's dark theme.

Every number is read from the runs; nothing is typed. Where a reading is missing (box xs runs no
Prometheus, so its pods' cores are not read) the figure leaves it out and says so.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
import tempfile
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from html import escape
from pathlib import Path
from typing import Any

from langsmith_sizing import figures as fig

SIZES = ("xs", "s", "m", "l")
# The brand's palette (Content Studio's langchain-tokens.json): one colour a size and a workload, the same in
# every figure; queue and backend take the extended palette's lilac and rose, which it allows for data.
SIZE_COLOUR = {"xs": "#FBB0A5", "s": "#8CDB9B", "m": "#F2FAFF", "l": "#7FC8FF"}
WORKLOADS = ("smithdb", "ingest-queue", "rustfs", "postgres", "queue", "platform-backend", "backend", "redis", "frontend")
WORKLOAD_COLOUR = {"smithdb": "#7FC8FF", "ingest-queue": "#006DDD", "rustfs": "#FBB0A5", "postgres": "#8CDB9B",
                   "queue": "#D5C3F7", "platform-backend": "#E3FF8F", "backend": "#C78EAD", "redis": "#DB8C8C", "frontend": "#99D3FF"}
# The plan's pod names (Lite's `terraform output plan`, pods) as the load test names the workloads.
PLAN_NAMES = {"ingestQueue": "ingest-queue", "platformBackend": "platform-backend"}
L1 = "ingest_pending_segment_entry_count{level=L1}"
W = 1472


# ---- the runs ------------------------------------------------------------------------------------


@dataclass
class Step:
    experiment: str
    traces: str
    size: str
    index: int
    multiple: float
    soak: dict[str, Any]
    samples: list[dict[str, Any]]
    label: str = ""
    plan: dict[str, Any] | None = None  # the size's plan as it ran (Lite's plan.json), when recorded
    minute0: float = 0.0  # minutes from the size's first sample to this step's first
    rows: dict[str, Any] = field(default_factory=dict)

    @property
    def window(self) -> tuple[float, float]:
        w = (self.soak.get("cluster") or {}).get("window") or {}
        return float(w.get("from", 0)), float(w.get("to", math.inf))


def _step_folders(size_dir: Path) -> list[tuple[int, float, Path]]:
    found = []
    for folder in size_dir.iterdir():
        if folder.is_dir() and folder.name.endswith("x") and (folder / "soak.json").exists():
            head, _, multiple = folder.name.rpartition("-")
            found.append((int(head) if head else 0, float(multiple[:-1]), folder))
    found.sort(key=lambda f: (f[0], f[1]))
    return [(i, k, f) for i, (_, k, f) in enumerate(found, 1)]


def settings(experiment: Path) -> dict[str, str]:
    """The experiment's settings file, KEY=value a line: SIZES, STEPS, MINUTES, TRACES, LABEL, COMMIT."""
    f = experiment / "settings"
    lines = f.read_text().splitlines() if f.exists() else []
    return {k: v for k, _, v in (line.partition("=") for line in lines) if k}


def load(experiment: Path) -> list[Step]:
    steps: list[Step] = []
    named = settings(experiment).get("LABEL", "")
    for size in SIZES:
        if not (experiment / size).is_dir():
            continue
        plan_file = experiment / size / "plan.json"
        plan = json.loads(plan_file.read_text()) if plan_file.exists() else None
        first = None
        for index, multiple, folder in _step_folders(experiment / size):
            soak = json.loads((folder / "soak.json").read_text())
            samples = [json.loads(x) for x in (folder / "soak.metrics.jsonl").read_text().splitlines() if x.strip()]
            traces = (soak.get("write", {}).get("payload_shape") or {}).get("traces", "simple")
            step = Step(experiment.name, traces, size, index, multiple, soak, samples, named or f"{traces} traces", plan)
            first = first if first is not None else (samples[0]["t"] if samples else 0.0)
            step.minute0 = ((samples[0]["t"] if samples else first) - first) / 60
            steps.append(step)
    return steps


# ---- what each step held and took ---------------------------------------------------------------


# Prometheus's counters move when it scrapes, not every 15 s sample: over one sample's interval a reading
# alternated between nothing and twice the rate, and SmithDB alone read above every pod together. A minute
# spans a scrape at any interval up to it, so spreads and peaks are of minutes.
SPAN_SECONDS = 60.0


def intervals(step: Step) -> list[tuple[dict[str, Any], dict[str, Any], float]]:
    """Inside the window after the ramp, each sample with the first a minute or more after it."""
    lo, hi = step.window
    inside = [s for s in step.samples if lo <= s["t"] <= hi]
    out = []
    for i, a in enumerate(inside):
        b = next((s for s in inside[i + 1 :] if s["t"] - a["t"] >= SPAN_SECONDS), None)
        if b is not None:
            out.append((a, b, b["t"] - a["t"]))
    return out


def workload_seconds(sample: dict[str, Any], workload: str) -> float:
    return float(sum(v["seconds"] for v in (sample.get("cpu") or {}).values() if v.get("workload") == workload))


def workload_memory(sample: dict[str, Any], workload: str) -> float:
    return float(sum(v.get("memory", 0) for v in (sample.get("cpu") or {}).values() if v.get("workload") == workload)) / 2**30


def pods_cores(step: Step) -> list[float]:
    """Every pod together, cores a minute, from k3s's kubepods slice."""
    out = []
    for a, b, dt in intervals(step):
        pa, pb = (a.get("machine") or {}).get("pods"), (b.get("machine") or {}).get("pods")
        if pa and pb:
            out.append((pb["seconds"] - pa["seconds"]) / dt)
    return out


def disk_written(step: Step) -> list[float]:
    """MiB/s written to the busiest disk, a minute at a time."""
    out = []
    for a, b, dt in intervals(step):
        da, db = (a.get("machine") or {}).get("disks") or {}, (b.get("machine") or {}).get("disks") or {}
        moved = [(db[d]["written"] - da[d]["written"]) / dt / 2**20 for d in db if d in da]
        if moved:
            out.append(max(moved))
    return out


def workload_cores(step: Step, workload: str) -> list[float]:
    """One workload's cores, a minute at a time."""
    return [(workload_seconds(b, workload) - workload_seconds(a, workload)) / dt for a, b, dt in intervals(step)]


def missed(soak: dict[str, Any]) -> list[str]:
    """What failed the step, in a few words each: a target it missed, or a read refused."""
    names = {"stored_within_seconds_p99": "stored late", "trace_load_seconds_p99": "reads slow", "no_missing_runs": "runs lost"}
    out = [names.get(k, k) for k, v in (soak.get("targets") or {}).items() if v.get("passed") is False]
    if (soak.get("errors") or {}).get("reads"):
        out.append("reads refused")
    return out


def spread(values: Sequence[float]) -> tuple[float, float, float, float] | None:
    """(mean, p5, p95, max) of the values, or None with too few to say."""
    if len(values) < 3:
        return None
    q = statistics.quantiles(values, n=20)
    return statistics.mean(values), q[0], q[-1], max(values)


def describe(step: Step) -> dict[str, Any]:
    """The step as one row: its load, what it held, what it took."""
    s, c = step.soak, step.soak.get("cluster") or {}
    reads = (s.get("reads") or {}).get("classes") or {}
    coefficients = c.get("coefficients") or {}
    disk = c.get("disk_bytes_per_run") or {}
    row: dict[str, Any] = {
        "experiment": step.experiment, "label": step.label, "traces": step.traces, "size": step.size, "step": step.index, "multiple": step.multiple,
        "runs_per_second": c.get("runs_per_second_sent"), "runs_sent": s["stored"]["runs_sent"], "runs_stored": s["stored"]["runs_stored"],
        "payload_kib_per_run": s["write"].get("payload_kib_per_run"), "passed": s.get("passed"),
        "lag_p50_s": s["lag"].get("p50_seconds"), "lag_p99_s": s["lag"].get("p99_seconds"),
        "read_trace_p99_s": (reads.get("read_trace") or {}).get("p99_seconds"),
        "list_traces_p99_s": (reads.get("list_traces") or {}).get("p99_seconds"),
        "l1_peak": max((float((x.get("smithdb") or {}).get(L1, 0)) for x in step.samples), default=None),
        "fanout_refusals": (s.get("metrics", {}).get("query-fanout") or {}).get("during_run"),
        "storage_bytes_per_run": disk.get("rustfs:/data"), "blobs_bytes_per_run": disk.get("rustfs:/data/langsmith-blobs"),
        "segments_bytes_per_run": disk.get("rustfs:/data/smithdb"),
        "missed": "; ".join(missed(s)), "pods_memory_peak_gib": ((c.get("machine") or {}).get("pods_memory_peak_mib") or 0) / 1024 or None,
    }
    for w in WORKLOADS:
        row[f"{w}_cores"] = (coefficients.get(w) or {}).get("cores_used")
        row[f"{w}_memory_gib"] = ((coefficients.get(w) or {}).get("memory_peak_mib") or 0) / 1024 or None
        busiest = workload_cores(step, w)
        row[f"{w}_cores_max"] = round(max(busiest), 4) if busiest and max(busiest) > 0 else None
    for name, values in (("pods_cores", pods_cores(step)), ("disk_written_mibs", disk_written(step))):
        got = spread(values)
        row.update({f"{name}_{k}": (round(v, 4) if got else None) for k, v in zip(("mean", "p5", "p95", "max"), got or (0, 0, 0, 0), strict=True)})
    return row


# ---- drawing -------------------------------------------------------------------------------------

STYLE = """<style>
svg.x { display: block; overflow: visible; }
svg.x text { fill: var(--text); font: 250 19px var(--font-sans); }
svg.x text.t { font: 600 21px var(--font-sans); }
svg.x text.n { font: 400 16px var(--font-mono); fill: var(--text-2); }
svg.x text.d { font: 400 16px var(--font-mono); fill: var(--muted); }
svg.x text.w { font: 400 16px var(--font-mono); fill: var(--warn); }
.grid { stroke: var(--line); stroke-width: 1; }
.axis { stroke: var(--frame); stroke-width: var(--lc-stroke, 2px); }
.target { stroke: #DB8C8C; stroke-width: 2; stroke-dasharray: 8 6; }
.limit { stroke: var(--text-2); stroke-width: 2; stroke-dasharray: 3 5; }
</style>"""


def text(x: float, y: float, s: str, cls: str = "", anchor: str = "start") -> str:
    """Words in sentence case; a value, a box or a workload as it is named (the brand's casing rule)."""
    named = cls in ("n", "d", "w") or s.split(" ")[0].rstrip(",") in ("box", *WORKLOADS)
    case = ' data-brand-case="explicit"' if named else ""
    s = s if named else s[:1].upper() + s[1:]
    return f'<text x="{x:.1f}" y="{y:.1f}" class="{cls}" text-anchor="{anchor}"{case}>{escape(s)}</text>'


@dataclass
class Plot:
    """A plot area: x and y on linear or log scales."""

    x0: float
    y0: float
    w: float
    h: float
    xr: tuple[float, float]
    yr: tuple[float, float]
    xlog: bool = False
    ylog: bool = False

    def _t(self, v: float, r: tuple[float, float], log: bool) -> float:
        a, b = (math.log10(r[0]), math.log10(r[1])) if log else r
        return ((math.log10(max(v, 1e-9)) if log else v) - a) / (b - a)

    def x(self, v: float) -> float:
        return self.x0 + self._t(v, self.xr, self.xlog) * self.w

    def y(self, v: float) -> float:
        return self.y0 + self.h - self._t(v, self.yr, self.ylog) * self.h

    def frame(self, title: str, xticks: Sequence[float], yticks: Sequence[float], xlabel: str, unit: str) -> list[str]:
        o = [text(self.x0, self.y0 - 36, title, "t"), text(self.x0, self.y0 - 12, unit, "d")]
        for t in yticks:
            o += [f'<line x1="{self.x0}" x2="{self.x0 + self.w}" y1="{self.y(t):.1f}" y2="{self.y(t):.1f}" class="grid"/>',
                  text(self.x0 - 10, self.y(t) + 6, f"{t:g}", "n", "end")]
        o += [text(self.x(t), self.y0 + self.h + 26, f"{t:g}", "n", "middle") for t in xticks]
        o += [f'<line x1="{self.x0}" x2="{self.x0 + self.w}" y1="{self.y0 + self.h}" y2="{self.y0 + self.h}" class="axis"/>',
              text(self.x0 + self.w / 2, self.y0 + self.h + 56, xlabel, "d", "middle")]
        return o

    def hline(self, v: float, cls: str, label: str) -> list[str]:
        y = self.y(v)
        return [f'<line x1="{self.x0}" x2="{self.x0 + self.w}" y1="{y:.1f}" y2="{y:.1f}" class="{cls}"/>',
                text(self.x0 + self.w - 4, y - 8, label, "d", "end")]


# Each experiment's line, newest first: solid and filled; the one before dashed and hollow; older dotted.
DASH = {"line": "", "dashed": "9 7", "dotted": "2 6"}


def dot(p: Plot, x: float, y: float, colour: str, hollow: bool = False, r: float = 7) -> str:
    fill = "var(--bg)" if hollow else colour
    return f'<circle cx="{p.x(x):.1f}" cy="{p.y(y):.1f}" r="{r}" style="fill:{fill};stroke:{colour};stroke-width:2.5"/>'


def path(p: Plot, pts: Sequence[tuple[float, float]], colour: str, kind: str = "line", width: float = 2.5) -> str:
    if len(pts) < 2:
        return ""
    d = " ".join(f"{'M' if i == 0 else 'L'}{p.x(a):.1f},{p.y(b):.1f}" for i, (a, b) in enumerate(pts))
    dash = f";stroke-dasharray:{DASH[kind]}" if DASH[kind] else ""
    return f'<path d="{d}" style="fill:none;stroke:{colour};stroke-width:{width}{dash};stroke-linejoin:round"/>'


def whisker(p: Plot, x: float, lo: float, hi: float, colour: str) -> str:
    return (f'<line x1="{p.x(x):.1f}" x2="{p.x(x):.1f}" y1="{p.y(lo):.1f}" y2="{p.y(hi):.1f}" style="stroke:{colour};stroke-width:2.5"/>'
            f'<line x1="{p.x(x) - 6:.1f}" x2="{p.x(x) + 6:.1f}" y1="{p.y(hi):.1f}" y2="{p.y(hi):.1f}" style="stroke:{colour};stroke-width:2.5"/>')


def legend(x: float, y: float, items: Sequence[tuple[str, str, str]]) -> list[str]:
    """(label, colour, kind): kind is dot, hollow, line, dashed or dotted."""
    o = []
    for label, colour, kind in items:
        if kind in ("dot", "hollow"):
            o.append(f'<circle cx="{x + 8}" cy="{y - 6}" r="7" style="fill:{"var(--bg)" if kind == "hollow" else colour};stroke:{colour};stroke-width:2.5"/>')
        else:
            dash = f";stroke-dasharray:{DASH[kind]}" if DASH[kind] else ""
            o.append(f'<line x1="{x}" x2="{x + 28}" y1="{y - 6}" y2="{y - 6}" style="stroke:{colour};stroke-width:3{dash}"/>')
        o.append(text(x + 38, y, label))
        x += 60 + 10.5 * len(label)
    return o


def page(title: str, sub: str, height: float, body: Sequence[str], source: str) -> str:
    return (f'<div class="canvas">{STYLE}<header><div class="eyebrow"><span data-brand-case="explicit">langsmith-load-test</span>'
            f'<span class="of">Experiments</span></div><h1>{escape(title)}</h1><p class="sub">{escape(sub)}</p><!--flag--></header>'
            f'<svg class="x" width="{W}" height="{height}" viewBox="0 0 {W} {height}">{"".join(body)}</svg>'
            f'<footer><!--logo--><span data-brand-case="explicit">{escape(source)}</span></footer></div>')


def nice(top: float) -> float:
    if top <= 0:
        return 1.0
    mag = 10 ** math.floor(math.log10(top))
    return float(next(m * mag for m in (1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10) if m * mag >= top))


def ticks(top: float, n: int = 4) -> list[float]:
    return [top * i / n for i in range(n + 1)]


def runs(rows: Sequence[dict[str, Any]]) -> list[str]:
    """The experiments, oldest first: their folders are named by the UTC time they started."""
    return sorted({r["experiment"] for r in rows})


def look(rows: Sequence[dict[str, Any]], experiment: str) -> str:
    """The experiment's line: the newest solid, the one before dashed, older ones dotted."""
    order = runs(rows)
    back = len(order) - 1 - order.index(experiment)
    return "line" if back == 0 else "dashed" if back == 1 else "dotted"


def label(rows: Sequence[dict[str, Any]], experiment: str) -> str:
    return str(next(r["label"] for r in rows if r["experiment"] == experiment))


def experiment_legend(x: float, y: float, rows: Sequence[dict[str, Any]]) -> list[str]:
    return legend(x, y, [(label(rows, e), "var(--text-2)", look(rows, e)) for e in runs(rows)[::-1]])


# A figure: its title, its subtitle, its height and its SVG; None when the runs hold nothing it draws.
Figure = tuple[str, str, float, list[str]] | None
# Each size's plan as it ran, by (experiment, size): machine, allocatable, allowed, requested and pods.
Plans = dict[tuple[str, str], dict[str, Any]]


def step_label(row: dict[str, Any], same: Sequence[dict[str, Any]]) -> str:
    """'2x', or '1x again' for a multiple the size ran before."""
    again = any(r["multiple"] == row["multiple"] and r["step"] < row["step"] for r in same)
    return f"{row['multiple']:g}x" + (" again" if again else "")


# ---- the figures ---------------------------------------------------------------------------------


def held(rows: list[dict[str, Any]], _steps: list[Step], _plans: Plans) -> Figure:
    """Lag and trace reads against the rate, every size, every experiment."""
    o: list[str] = []
    for i, (key, title, target) in enumerate((("lag_p99_s", "Sent to readable, p99", 30.0), ("read_trace_p99_s", "Opening a trace, p99", 5.0))):
        p = Plot(80 + i * 740, 70, 640, 470, (0.8, 200), (0.1, 100), xlog=True, ylog=True)
        o += p.frame(title, (1, 2, 5, 10, 25, 50, 100, 150), (0.1, 1, 10, 100), "runs a second sent (log)", "seconds (log)")
        o += p.hline(target, "target", f"target: {target:g} s")
        for size in SIZES:
            for e in runs(rows):
                mine = [r for r in rows if r["size"] == size and r["experiment"] == e and r[key]]
                o.append(path(p, sorted((r["runs_per_second"], r[key]) for r in mine), SIZE_COLOUR[size], look(rows, e)))
                o += [dot(p, r["runs_per_second"], r[key], SIZE_COLOUR[size], look(rows, e) != "line") for r in mine]
    o += legend(80, 640, [(f"box {s}", SIZE_COLOUR[s], "dot") for s in SIZES])
    o += experiment_legend(80, 680, rows)
    newest = [r for r in rows if r["experiment"] == runs(rows)[-1]]
    worst = max(newest, key=lambda r: r["read_trace_p99_s"] or 0)
    stored, sent = sum(r["runs_stored"] for r in rows), sum(r["runs_sent"] for r in rows)
    return (f"Every run of {sent:,} was stored; reads slowed first, worst at box {worst['size']} {worst['multiple']:g}x in {label(rows, runs(rows)[-1])}",
            f"Each dot one step of ten minutes, each size from a fresh install held to its machine; solid the newest experiment. "
            f"{stored:,} of {sent:,} runs stored.", 720, o)


def cores(rows: list[dict[str, Any]], _steps: list[Step], _plans: Plans) -> Figure:
    """Every pod's cores, stacked by workload, at each step: the bar the mean, the whisker p5 to p95, the dot the peak."""
    o: list[str] = []
    shown = [r for r in rows if r.get("pods_cores_mean") is not None]
    sizes = [s for s in SIZES if any(r["size"] == s for r in shown)]
    order = runs(shown)
    top = nice(max(r["pods_cores_max"] for r in shown) * 1.1)
    cw = (W - 100) / max(1, len(sizes))
    for row_i, e in enumerate(order):
        for col_i, size in enumerate(sizes):
            rs = sorted((r for r in shown if r["size"] == size and r["experiment"] == e), key=lambda r: r["step"])
            p = Plot(90 + col_i * cw, 70 + row_i * 330, cw - 70, 230, (0, len(rs) + 1), (0, top))
            o += p.frame(f"box {size}, {label(rows, e)}", [], ticks(top), "", "cores" if col_i == 0 else "")
            for j, r in enumerate(rs, 1):
                base = 0.0
                for w in WORKLOADS:
                    v = r.get(f"{w}_cores") or 0
                    o.append(f'<rect x="{p.x(j) - 22:.1f}" y="{p.y(base + v):.1f}" width="44" height="{p.y(base) - p.y(base + v):.1f}" style="fill:{WORKLOAD_COLOUR[w]}"/>')
                    base += v
                o.append(whisker(p, j + 0.32, r["pods_cores_p5"], r["pods_cores_p95"], "var(--text)"))
                o.append(dot(p, j + 0.32, r["pods_cores_max"], "var(--text)", r=5))
                o.append(text(p.x(j), p.y(0) + 26, step_label(r, rs), "n", "middle"))
    o += legend(90, 70 + len(order) * 330 - 30, [(w, WORKLOAD_COLOUR[w], "dot") for w in WORKLOADS[:6]])
    o += legend(90, 70 + len(order) * 330 + 10, [(w, WORKLOAD_COLOUR[w], "dot") for w in WORKLOADS[6:]])
    peak = max(shown, key=lambda r: r["pods_cores_max"])
    return (f"Every pod together peaked at {peak['pods_cores_max']:.1f} cores, at box {peak['size']} {peak['multiple']:g}x; SmithDB takes the most at every size",
            "Bars: each workload's mean cores over the window after the ramp, stacked. Whisker: every pod together, 5th to 95th "
            "percentile of its minutes; dot: its busiest minute. Box xs runs no Prometheus, so its pods are not read.",
            70 + len(order) * 330 + 30, o)


def memory(rows: list[dict[str, Any]], steps: list[Step], _plans: Plans) -> Figure:
    """SmithDB's memory through each size's run, every experiment, against its limit: does it level off."""
    o: list[str] = []
    sizes = [s for s in SIZES if any(st.size == s and any(workload_memory(x, "smithdb") for x in st.samples) for st in steps)]
    limits = {(st.experiment, st.size): _smithdb_limit_gib(st.plan) for st in steps}
    top = nice(max([workload_memory(x, "smithdb") for st in steps for x in st.samples] + [v for v in limits.values() if v]) * 1.05)
    cw = (W - 100) / max(1, len(sizes))
    for col_i, size in enumerate(sizes):
        p = Plot(90 + col_i * cw, 70, cw - 60, 420, (0, 50), (0, top))
        o += p.frame(f"box {size}", (0, 12, 24, 36, 48), ticks(top), "minutes since its fresh install", "GiB" if col_i == 0 else "")
        for e in runs(rows):
            limit = limits.get((e, size))
            if limit:
                o.append(path(p, [(0, limit), (50, limit)], "var(--muted)", look(rows, e), 1.5))
            for st in (s for s in steps if s.size == size and s.experiment == e):
                t0 = st.samples[0]["t"] if st.samples else 0
                pts = [(st.minute0 + (x["t"] - t0) / 60, workload_memory(x, "smithdb")) for x in st.samples]
                o.append(path(p, [q for q in pts if q[1] > 0], SIZE_COLOUR[size], look(rows, e)))
    o += experiment_legend(90, 580, rows)
    newest = runs(rows)[-1]
    last = {s: max((r["smithdb_memory_gib"] or 0) for r in rows if r["size"] == s and r["experiment"] == newest) for s in sizes}
    return ("SmithDB's memory climbs toward the limit it divides among its parts, nearest at the smallest box",
            "SmithDB's resident memory every 15 s through each size's steps one after another, with its memory limit (grey) as each "
            "experiment ran; in " + label(rows, newest) + ", " + ", ".join(f"box {s} peaked at {v:.1f} GiB" for s, v in last.items() if v) + ".", 620, o)


def _smithdb_limit_gib(plan: dict[str, Any] | None) -> float | None:
    pod = ((plan or {}).get("pods") or {}).get("smithdb") or {}
    return pod["lim_mem_mi"] / 1024 if pod.get("lim_mem_mi") else None


def disk(rows: list[dict[str, Any]], _steps: list[Step], _plans: Plans) -> Figure:
    """What a run costs the disk: bytes kept, and the write rate against the load."""
    o: list[str] = []
    kept = [r for r in rows if r.get("storage_bytes_per_run")]
    sizes = [s for s in SIZES if any(r["size"] == s for r in kept)]
    order = runs(kept)
    top = nice(max(r["storage_bytes_per_run"] for r in kept) / 1000 * 1.1)
    p = Plot(90, 70, 620, 430, (0, len(sizes) * len(order) + 1), (0, top))
    o += p.frame("Kept a run, the object store", [], ticks(top), "", "KB a run, each step's growth")
    x = 1.0
    for size in sizes:
        for n, e in enumerate(order, 1):
            for r in (r for r in kept if r["size"] == size and r["experiment"] == e):
                o.append(dot(p, x + (r["step"] - 2.5) * 0.08, r["storage_bytes_per_run"] / 1000, SIZE_COLOUR[size], look(kept, e) != "line", 6))
            o.append(text(p.x(x), p.y(0) + 26, f"{size} {n}", "n", "middle"))
            x += 1
    q = Plot(820, 70, 600, 430, (0, 160), (0, nice(max(r["disk_written_mibs_p95"] or 0 for r in rows) * 1.1)))
    o += q.frame("Written to the data disk", (0, 50, 100, 150), ticks(q.yr[1]), "runs a second", "MiB/s: mean, whisker p5 to p95")
    for r in (r for r in rows if r.get("disk_written_mibs_mean") is not None):
        o.append(whisker(q, r["runs_per_second"], r["disk_written_mibs_p5"], r["disk_written_mibs_p95"], SIZE_COLOUR[r["size"]]))
        o.append(dot(q, r["runs_per_second"], r["disk_written_mibs_mean"], SIZE_COLOUR[r["size"]], look(rows, r["experiment"]) != "line", 6))
    o += legend(90, 610, [(f"box {s}", SIZE_COLOUR[s], "dot") for s in sizes])
    by = {e: statistics.mean(r["storage_bytes_per_run"] for r in kept if r["experiment"] == e) / 1000 for e in order}
    return ("The object store kept " + "; ".join(f"{by[e]:.0f} KB a run in {label(rows, e)}" for e in order),
            "Left: what the object store grew a run stored, each step a dot, numbered by experiment (" +
            ", ".join(f"{n}: {label(rows, e)}" for n, e in enumerate(order, 1)) + "); a step's window holds segments compaction has not "
            "yet removed. Right: the data disk's write rate, every step; hollow are earlier experiments.", 650, o)


def smithdb(rows: list[dict[str, Any]], steps: list[Step], _plans: Plans) -> Figure:
    """Segments waiting for their L1 merge through each size's run in the newest experiment, and reads against the pile."""
    o: list[str] = []
    newest = runs(rows)[-1]
    mine = [s for s in steps if s.experiment == newest]
    sizes = [s for s in SIZES if any(st.size == s for st in mine)]
    ph = 120
    for i, size in enumerate(sizes):
        p = Plot(160, 70 + i * (ph + 40), 760, ph, (0, 50), (0, 700))
        o += [f'<line x1="{p.x0}" x2="{p.x0 + p.w}" y1="{p.y(t):.1f}" y2="{p.y(t):.1f}" class="grid"/>' for t in (0, 350, 700)]
        o += [text(p.x0 - 10, p.y(t) + 6, f"{t}", "n", "end") for t in (0, 350, 700)]
        o.append(text(0, p.y0 + ph / 2 + 6, f"box {size}", "t"))
        for st in (s for s in mine if s.size == size):
            t0 = st.samples[0]["t"] if st.samples else 0
            pts = [(st.minute0 + (x["t"] - t0) / 60, float((x.get("smithdb") or {}).get(L1, 0))) for x in st.samples]
            o.append(path(p, pts, SIZE_COLOUR[size]))
    o.append(text(160, 70 + len(sizes) * (ph + 40) + 6, f"Segments waiting for their L1 merge in {label(rows, newest)}, against minutes since the fresh install", "d"))
    q = Plot(1030, 90, 400, 520, (0, 700), (0.03, 30), ylog=True)
    o += q.frame("Opening a trace, p99", (0, 350, 700), (0.1, 1, 10), "most segments waiting in the step", "seconds (log)")
    o += q.hline(5, "target", "target 5 s")
    for r in (r for r in rows if r.get("read_trace_p99_s") and r.get("l1_peak") is not None):
        o.append(dot(q, r["l1_peak"], r["read_trace_p99_s"], SIZE_COLOUR[r["size"]], r["experiment"] != newest, 6))
    height = max(70 + len(sizes) * (ph + 40) + 30, 690)
    return ("Reads slow as SmithDB's small segments pile up before their merge, not as the machine fills",
            "Left: each size's pile through its run; it drops when SmithDB merges, on its timer at low rates and at 25,000 rows at high ones. "
            "Right: every step's slowest trace reads against its pile; hollow are earlier experiments.", height, o)


def per_run_cost(rows: list[dict[str, Any]], _steps: list[Step], _plans: Plans) -> Figure:
    """Millicores a run a second for the workloads that follow the rate, a fitted line an experiment."""
    o: list[str] = []
    names = ("ingest-queue", "rustfs", "platform-backend")
    cw = (W - 100) / len(names)
    fits: dict[tuple[str, str], tuple[float, float]] = {}
    for i, w in enumerate(names):
        pts_all = [(r["runs_per_second"], r[f"{w}_cores"]) for r in rows if r.get(f"{w}_cores") is not None and r["step"] > 1]
        top = nice(max((y for _, y in pts_all), default=1) * 1.15)
        p = Plot(90 + i * cw, 70, cw - 80, 400, (0, 160), (0, top))
        o += p.frame(w, (0, 50, 100, 150), ticks(top), "runs a second", "cores" if i == 0 else "")
        for e in runs(rows):
            mine = [r for r in rows if r["experiment"] == e and r.get(f"{w}_cores") is not None and r["step"] > 1]
            pts = [(r["runs_per_second"], r[f"{w}_cores"]) for r in mine]
            if len(pts) >= 3:
                a, b = _line(pts)
                fits[(w, e)] = (b, _r2(pts, a, b))
                o.append(path(p, [(0, a), (160, a + b * 160)], "var(--text-2)", look(rows, e), 2))
                o.append(text(p.x(158), p.y(a + b * 158) - 10, f"{b * 1000:.1f} m", "n", "end"))
            o += [dot(p, r["runs_per_second"], r[f"{w}_cores"], SIZE_COLOUR[r["size"]], look(rows, e) != "line", 6) for r in mine]
    o += legend(90, 570, [(f"box {s}", SIZE_COLOUR[s], "dot") for s in ("s", "m", "l")])
    o += experiment_legend(90, 610, rows)
    iq = [(e, v) for (w, e), v in fits.items() if w == "ingest-queue"]
    return ("Ingest costs " + "; ".join(f"{v[0] * 1000:.1f} millicores a run/s in {label(rows, e)}" for e, v in iq),
            "Each workload's mean cores against the rate it processed, every step after a size's first; the lines least squares, labelled "
            "with their slope in millicores a run a second.", 650, o)


def ceiling(rows: Sequence[dict[str, Any]]) -> float:
    """The highest multiple at and below which every step passed; 0 when the first failed."""
    held_to = 0.0
    for k in sorted({r["multiple"] for r in rows}):
        if not all(r["passed"] for r in rows if r["multiple"] == k):
            break
        held_to = k
    return held_to


def scorecard(rows: list[dict[str, Any]], _steps: list[Step], _plans: Plans) -> Figure:
    """Every step, pass or fail, with what it held and what failed it: each size's ceiling at a glance, newest first."""
    o: list[str] = []
    y = 20.0
    for e in runs(rows)[::-1]:
        mine = [r for r in rows if r["experiment"] == e]
        sizes = [s for s in SIZES if any(r["size"] == s for r in mine)]
        cw = (W - 130) / max(r["step"] for r in mine)
        o.append(text(0, y + 20, label(rows, e), "t"))
        y += 50
        for i, size in enumerate(sizes):
            rs = sorted((r for r in mine if r["size"] == size), key=lambda r: r["step"])
            o.append(text(0, y + i * 104 + 56, f"box {size}", "t"))
            for r in rs:
                x0, y0, good = 130 + (r["step"] - 1) * cw, y + i * 104, bool(r["passed"])
                o.append(f'<rect x="{x0:.1f}" y="{y0:.1f}" width="{cw - 14:.1f}" height="92" rx="6" '
                         f'style="fill:var({"--card" if good else "--warn-fill"});stroke:var({"--good" if good else "--warn-line"});stroke-width:2"/>')
                o.append(text(x0 + 16, y0 + 30, f"{step_label(r, rs)}  {r['runs_per_second']:.0f} runs/s".replace(" 0 runs", " <1 run"), "n"))
                o.append(text(x0 + 16, y0 + 56, f"stored {r['lag_p99_s']:.0f} s, read {r['read_trace_p99_s']:.1f} s", "d"))
                o.append(text(x0 + 16, y0 + 80, r["missed"] or "held", "d" if good else ""))
        y += len(sizes) * 104 + 40
    newest = runs(rows)[-1]
    tops = {s: ceiling([r for r in rows if r["experiment"] == newest and r["size"] == s]) for s in SIZES if any(r["experiment"] == newest and r["size"] == s for r in rows)}
    by: dict[float, list[str]] = {}
    for s, k in tops.items():
        by.setdefault(k, []).append(s)
    said = "; ".join(f"box {' and '.join(ss)} held {k:g}x" if k else f"box {' and '.join(ss)} missed at 1x" for k, ss in sorted(by.items(), reverse=True))
    return (f"In {label(rows, newest)}, {said} its design rate",
            "Each box one step of ten minutes from a fresh install held to its machine, its rate in runs a second; the newest experiment "
            "first. It holds when every run is stored, sent to readable at p99 is within 30 s, opening a trace at p99 within 5 s, and no "
            "read is refused.", y, o)


def _measured(rows: Sequence[dict[str, Any]], experiment: str, size: str) -> dict[str, tuple[float, float, float]]:
    """A workload's busiest step's mean cores, its busiest minute and its peak memory in GiB, in one experiment."""
    rs = [r for r in rows if r["size"] == size and r["experiment"] == experiment]
    out = {}
    for w in WORKLOADS:
        mean = max((r.get(f"{w}_cores") or 0 for r in rs), default=0)
        if mean:
            out[w] = (mean, max((r.get(f"{w}_cores_max") or 0 for r in rs), default=0), max((r.get(f"{w}_memory_gib") or 0 for r in rs), default=0))
    return out


def _asked(plan: dict[str, Any]) -> dict[str, tuple[float, float]]:
    """Each workload's request in the plan: cores and GiB."""
    return {PLAN_NAMES.get(k, k): (v["cpu_m"] / 1000, v["mem_mi"] / 1024) for k, v in plan["pods"].items() if PLAN_NAMES.get(k, k) in WORKLOADS}


def _planned(rows: Sequence[dict[str, Any]], plans: Plans) -> tuple[str, str] | None:
    """The newest experiment with a plan recorded, and the oldest one's, to show what changed between them."""
    with_plans = [e for e in runs(rows) if any(k[0] == e for k in plans)]
    return (with_plans[-1], with_plans[0]) if with_plans else None


def requests(rows: list[dict[str, Any]], _steps: list[Step], plans: Plans) -> Figure:
    """Each workload's request in the plan the newest experiment ran with, against what it used, CPU and memory."""
    picked = _planned(rows, plans)
    if picked is None:
        return None
    e, first = picked
    sizes = [s for s in SIZES if (e, s) in plans and _measured(rows, e, s)]
    if not sizes:
        return None
    o: list[str] = []
    used = {s: _measured(rows, e, s) for s in sizes}
    asked = {s: _asked(plans[(e, s)]) for s in sizes}
    before = {s: _asked(plans[(first, s)]) for s in sizes if (first, s) in plans and first != e}
    names = [w for w in WORKLOADS if any(w in used[s] and w in asked[s] for s in sizes)]
    pairs = [(s, w) for s in sizes for w in names if w in used[s] and w in asked[s]]
    tops = (nice(max(max(asked[s][w][0], used[s][w][1], before.get(s, {}).get(w, (0, 0))[0]) for s, w in pairs) * 1.05),
            nice(max(max(asked[s][w][1], used[s][w][2], before.get(s, {}).get(w, (0, 0))[1]) for s, w in pairs) * 1.05))
    ph = len(names) * 30
    for i, size in enumerate(sizes):
        for j, (unit, top) in enumerate((("cores", tops[0]), ("GiB", tops[1]))):
            p = Plot(190 + j * 650, 70 + i * (ph + 110), 470, ph, (0, top), (0, len(names)))
            o += p.frame(f"box {size}, {'CPU' if j == 0 else 'memory'}", ticks(top) if i == len(sizes) - 1 else [], [], "", unit)
            for n, w in enumerate(names):
                if (size, w) not in pairs:
                    continue
                yc = p.y0 + n * 30 + 15
                if j == 0:
                    o.append(text(p.x0 - 14, yc + 6, w, "", "end"))
                req = asked[size][w][j]
                mean, peak, mem = used[size][w]
                fill, mark = (mean, peak) if j == 0 else (mem, mem)
                if w in before.get(size, {}) and before[size][w][j] != req:
                    old = before[size][w][j]
                    o.append(f'<rect x="{p.x(0):.1f}" y="{yc - 13:.1f}" width="{p.x(old) - p.x(0):.1f}" height="26" style="fill:none;stroke:var(--muted);stroke-width:1.5;stroke-dasharray:{DASH["dashed"]}"/>')
                o.append(f'<rect x="{p.x(0):.1f}" y="{yc - 11:.1f}" width="{p.x(req) - p.x(0):.1f}" height="22" style="fill:none;stroke:var(--text-2);stroke-width:1.5"/>')
                o.append(f'<rect x="{p.x(0):.1f}" y="{yc - 5:.1f}" width="{p.x(fill) - p.x(0):.1f}" height="10" style="fill:{WORKLOAD_COLOUR[w]}"/>')
                if j == 0:
                    o.append(f'<line x1="{p.x(mark):.1f}" x2="{p.x(mark):.1f}" y1="{yc - 11:.1f}" y2="{yc + 11:.1f}" style="stroke:var(--text);stroke-width:2.5"/>')
                share = mark / req if req else 0
                o.append(text(p.x0 + p.w + 12, yc + 6, f"{share:.0%}", "n" if share <= 1 else "w"))
    items = [("request as it ran", "var(--text-2)", "line"), ("used: busiest step's mean, memory its peak", "var(--accent)", "line"), ("busiest minute", "var(--text)", "line")]
    if before:
        items.append((f"request in {label(rows, first)}", "var(--muted)", "dashed"))
    o += legend(190, 70 + len(sizes) * (ph + 110) - 10, items[:3])
    o += legend(190, 70 + len(sizes) * (ph + 110) + 30, items[3:])
    services = ("ingest-queue", "queue", "platform-backend", "backend", "frontend")
    over = min(sum(asked[s][w][0] for w in services if (s, w) in pairs) / max(1e-9, sum(used[s][w][1] for w in services if (s, w) in pairs)) for s in sizes)
    outgrew = [(used[s][w][2] / asked[s][w][1], w, s) for s, w in pairs if used[s][w][2] > asked[s][w][1]]
    tail = "; {1} at box {2} peaked at {0:.0%} of its memory request".format(*max(outgrew)) if outgrew else "; no workload outgrew its memory request"
    return (f"In {label(rows, e)}, the services asked for at least {over:.1f} times the CPU their busiest minute used{tail}",
            "Outline: each workload's request as the experiment ran" + (f"; dashed, as {label(rows, first)} ran" if before else "") +
            ". Bar: what it used in its busiest step; for memory, its peak. Right: the busiest minute's CPU, or the memory peak, as a share "
            "of the request.", 70 + len(sizes) * (ph + 110) + 60, o)


def _cores(block: dict[str, Any]) -> float:
    return float(block["cpu_m"]) / 1000


def _gib(block: dict[str, Any]) -> float:
    return float(block["mem_mi"]) / 1024


def machine(rows: list[dict[str, Any]], _steps: list[Step], plans: Plans) -> Figure:
    """Each size's machine in the newest experiment: the system's reserve, the plan's requests, every pod's use."""
    picked = _planned(rows, plans)
    if picked is None:
        return None
    e, first = picked
    shown = [r for r in rows if r.get("pods_cores_max") is not None and r["experiment"] == e]
    sizes = [s for s in SIZES if (e, s) in plans and any(r["size"] == s for r in shown)]
    if not sizes:
        return None
    o: list[str] = []
    worst = {"cpu": 0.0, "mem": 0.0}
    for i, size in enumerate(sizes):
        pl, rs, old = plans[(e, size)], [r for r in shown if r["size"] == size], plans.get((first, size)) if first != e else None
        o.append(text(0, 70 + i * 150 + 58, f"box {size}", "t"))
        for j, (key, unit, total) in enumerate((("cpu", "vCPU", float(pl["machine"]["cpu"])), ("mem", "GiB", float(pl["machine"]["memory_gi"])))):
            p = Plot(130 + j * 670, 70 + i * 150, 580, 40, (0, total), (0, 1))
            amount = _cores if key == "cpu" else _gib
            allocatable, allowed, requested = amount(pl["allocatable"]), amount(pl["allowed"]), amount(pl["requested"])
            mean = max(r["pods_cores_mean"] for r in rs) if key == "cpu" else None
            peak = max(r["pods_cores_max"] for r in rs) if key == "cpu" else max(r.get("pods_memory_peak_gib") or 0 for r in rs)
            worst[key] = max(worst[key], peak / total)
            o.append(f'<rect x="{p.x(0):.1f}" y="{p.y0:.1f}" width="{p.w:.1f}" height="40" style="fill:var(--shell);stroke:var(--frame);stroke-width:1.5"/>')
            o.append(f'<rect x="{p.x(allocatable):.1f}" y="{p.y0:.1f}" width="{p.x(total) - p.x(allocatable):.1f}" height="40" style="fill:var(--line)"/>')
            o.append(f'<rect x="{p.x(0):.1f}" y="{p.y0 + 8:.1f}" width="{p.x(requested) - p.x(0):.1f}" height="24" style="fill:var(--hl);stroke:var(--accent);stroke-width:1.5"/>')
            if old is not None and amount(old["requested"]) != requested:
                x_old = p.x(amount(old["requested"]))
                o.append(f'<line x1="{x_old:.1f}" x2="{x_old:.1f}" y1="{p.y0 + 2:.1f}" y2="{p.y0 + 38:.1f}" style="stroke:var(--muted);stroke-width:2.5;stroke-dasharray:4 3"/>')
            if mean is not None:
                o.append(f'<rect x="{p.x(0):.1f}" y="{p.y0 + 15:.1f}" width="{p.x(mean) - p.x(0):.1f}" height="10" style="fill:var(--accent)"/>')
            o.append(f'<line x1="{p.x(allowed):.1f}" x2="{p.x(allowed):.1f}" y1="{p.y0 - 6:.1f}" y2="{p.y0 + 46:.1f}" class="limit"/>')
            o.append(f'<line x1="{p.x(peak):.1f}" x2="{p.x(peak):.1f}" y1="{p.y0 - 4:.1f}" y2="{p.y0 + 44:.1f}" style="stroke:var(--text);stroke-width:3"/>')
            o.append(text(p.x0, p.y0 - 14, f"{'CPU' if key == 'cpu' else 'memory'}: {total:g} {unit}", "d"))
            o.append(text(p.x0, p.y0 + 70, f"asked {requested:.1f}, used at most {peak:.1f} ({peak / total:.0%} of the machine)", "n"))
    items = [("requested by the plan", "var(--accent)", "hollow"), ("mean, busiest step", "var(--accent)", "dot"), ("busiest minute or peak", "var(--text)", "line"),
             ("the most pods may ask", "var(--text-2)", "dotted"), ("reserved for the system", "var(--line)", "dot")]
    o += legend(130, 70 + len(sizes) * 150 + 10, items[:3])
    o += legend(130, 70 + len(sizes) * 150 + 50, items[3:] + ([(f"requested in {label(rows, first)}", "var(--muted)", "dashed")] if first != e else []))
    return (f"In {label(rows, e)}, no size's pods used more than {worst['cpu']:.0%} of its machine's vCPU or {worst['mem']:.0%} of its memory",
            "Each bar one machine as the plan sized it: the system's reserve at the right end, the plan's requests, and every pod "
            "together across the experiment's steps, by the minute for CPU and at its peak for memory.", 70 + len(sizes) * 150 + 80, o)


def _line(pts: Sequence[tuple[float, float]]) -> tuple[float, float]:
    n = len(pts)
    mx, my = sum(p[0] for p in pts) / n, sum(p[1] for p in pts) / n
    sxx = sum((x - mx) ** 2 for x, _ in pts)
    b = sum((x - mx) * (y - my) for x, y in pts) / sxx if sxx else 0.0
    return my - b * mx, b


def _r2(pts: Sequence[tuple[float, float]], a: float, b: float) -> float:
    my = sum(y for _, y in pts) / len(pts)
    ss = sum((y - my) ** 2 for _, y in pts)
    return 1 - sum((y - a - b * x) ** 2 for x, y in pts) / ss if ss else 1.0


FIGURES: dict[str, Callable[[list[dict[str, Any]], list[Step], Plans], Figure]] = {
    "scorecard": scorecard, "requests": requests, "machine": machine, "held": held, "cores": cores, "memory": memory, "disk": disk, "smithdb": smithdb, "per-run-cost": per_run_cost,
}


def write_rows(rows: list[dict[str, Any]], path_: Path) -> None:
    keys = list(dict.fromkeys(k for r in rows for k in r))
    with path_.open("w", newline="") as f:
        w = csv.DictWriter(f, keys)
        w.writeheader()
        w.writerows(rows)


def main(argv: list[str] | None = None) -> int:
    a = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    a.add_argument("out", type=Path)
    a.add_argument("experiments", type=Path, nargs="+")
    a.add_argument("--fonts", type=Path)
    a.add_argument("--logos", type=Path)
    a.add_argument("--draft", action="store_true", help="draw without the brand's faces, each figure labelled a draft")
    x = a.parse_args(argv)
    steps = [s for e in x.experiments for s in load(e)]
    if not steps:
        raise SystemExit("no steps found: give experiment folders, each with a folder a size and a step folder a soak")
    rows = [describe(s) for s in steps]
    plans: Plans = {(s.experiment, s.size): s.plan for s in steps if s.plan}
    x.out.mkdir(parents=True, exist_ok=True)
    write_rows(rows, x.out / "steps.csv")
    fonts, missing = fig.faces(x.fonts)
    if missing and not x.draft:
        raise SystemExit(f"the brand faces are missing ({', '.join(missing)}): give --fonts DIR, or --draft")
    note = "Drawn without the brand's faces; not for publishing." if missing else ""
    (x.out / "figures").mkdir(exist_ok=True)
    binary = fig.chrome()
    source = "; ".join(sorted({s.experiment for s in steps}))
    with tempfile.TemporaryDirectory() as tmp:
        for name, make in FIGURES.items():
            drawn = make(rows, steps, plans)
            if drawn is None:
                print(f"skipped figures/{name}.png: nothing in these runs it draws" + ("" if plans else " (no plan.json recorded)"))
                continue
            title, sub, height, body = drawn
            html = Path(tmp) / f"{name}.html"
            logo = x.logos / "langchain-on-dark.svg" if x.logos else None
            html.write_text(fig.document(page(title, sub, height, body, source), "dark", fonts, logo, note))
            fig.shoot(binary, html, x.out / "figures" / f"{name}.png")
            print(f"drew figures/{name}.png: {title}")
    print(f"wrote {x.out / 'steps.csv'}: {len(rows)} steps")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
