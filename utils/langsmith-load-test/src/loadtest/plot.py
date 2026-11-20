"""Draw a run's install metrics over time: one HTML page, one chart per signal, no dependency.

`load-test-plot results.json` reads the results and the samples beside them (results.metrics.jsonl,
written when the run had --namespace) and writes results.html. Each chart shades the window after the
ramp, the only one coefficients come from; with --plan, a watch item's alarm level is drawn as a line.
Inline SVG built here, so a run on any machine draws without a plotting library.
"""

from __future__ import annotations

import argparse
import html
import json
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from loadtest.cluster import smithdb_value

Sample = dict[str, Any]
Series = dict[str, list[tuple[float, float]]]
WIDTH, HEIGHT, PAD = 720, 200, 40
COLORS = ("var(--c1)", "var(--c2)", "var(--c3)", "var(--c4)", "var(--c5)", "var(--c6)")


@dataclass(frozen=True)
class Panel:
    title: str
    unit: str
    series: Callable[[Sequence[Sample]], Series]
    alarm_item: str | None = None


def _pick(samples: Sequence[Sample], section: str, keys: Sequence[str]) -> Series:
    out: Series = {}
    for s in samples:
        for k in keys:
            if k in s[section]:
                out.setdefault(k, []).append((s["t"], s[section][k]))
    return out


def _smithdb(samples: Sequence[Sample], family: str, **match: str) -> Series:
    pts = [(s["t"], v) for s in samples if (v := smithdb_value(s, family, **match)) is not None]
    return {family: pts} if pts else {}


def _redis_pct(samples: Sequence[Sample]) -> Series:
    pts = [(s["t"], s["redis"]["used_memory"] / s["redis"]["maxmemory"] * 100) for s in samples if s["redis"].get("maxmemory")]
    return {"used_memory": pts} if pts else {}


def _replicas(samples: Sequence[Sample]) -> Series:
    out: Series = {}
    for s in samples:
        for w, (current, _) in s["hpa"].items():
            out.setdefault(w, []).append((s["t"], current))
    return out


def _cores(samples: Sequence[Sample]) -> Series:
    """Cores each workload used between one sample and the next."""
    out: Series = {}
    for before, after in zip(samples, samples[1:], strict=False):
        span = after["t"] - before["t"]
        per: dict[str, float] = {}
        for key, entry in after["cpu"].items():
            prior = before["cpu"].get(key)
            if span > 0 and prior and "seconds" in entry and "seconds" in prior and entry["seconds"] >= prior["seconds"]:
                per[entry["workload"]] = per.get(entry["workload"], 0.0) + (entry["seconds"] - prior["seconds"]) / span
        for w, v in per.items():
            out.setdefault(w, []).append((after["t"], v))
    return out


PANELS = (
    Panel("Runs waiting for ingest", "pending", lambda s: _pick(s, "queues", ("ingestion_queue.pending", "feedback_queue.pending"))),
    Panel("Oldest queued task", "seconds", lambda s: _pick(s, "queues", ("oldest_task_seconds",)), "oldest-queued-task"),
    Panel("Compaction jobs waiting", "pending jobs", lambda s: _pick(s, "queues", ("compaction.pending",)) | _smithdb(s, "compaction_queue_job_count", status="pending")),
    Panel("SmithDB ingestion segments waiting to flush (l0)", "entries", lambda s: _smithdb(s, "ingest_pending_segment_entry_count", level="l0")),
    Panel("SmithDB queries waiting for admission", "queries", lambda s: _pick(s, "smithdb", ("query_admission_queue_length",)), "admission-queue"),
    Panel("Redis memory", "% of maxmemory", _redis_pct, "redis-memory"),
    Panel("Replicas by autoscaler", "replicas", _replicas),
    Panel("CPU cores used by workload", "cores", _cores),
)


def _chart(panel: Panel, series: Series, t0: float, window: tuple[float, float] | None, alarm: float | None) -> str:
    if not series:
        return f"<section><h2>{html.escape(panel.title)}</h2><p class=none>Not read in this run.</p></section>"
    t1 = max(t for pts in series.values() for t, _ in pts)
    top = max([v for pts in series.values() for _, v in pts] + ([alarm] if alarm is not None else [])) or 1.0
    span = max(t1 - t0, 1.0)

    def x(t: float) -> float:
        return PAD + (t - t0) / span * (WIDTH - 2 * PAD)

    def y(v: float) -> float:
        return HEIGHT - PAD / 2 - v / (top * 1.1) * (HEIGHT - PAD)

    parts = [f'<svg viewBox="0 0 {WIDTH} {HEIGHT}" role="img" aria-label="{html.escape(panel.title)}">']
    if window:
        parts.append(f'<rect class=window x="{x(window[0]):.1f}" y="0" width="{x(window[1]) - x(window[0]):.1f}" height="{HEIGHT - PAD / 2}"/>')
    parts.append(f'<line class=axis x1="{PAD}" y1="{y(0):.1f}" x2="{WIDTH - PAD}" y2="{y(0):.1f}"/>')
    parts.append(f'<text x="{PAD}" y="12">{top * 1.1:,.4g} {html.escape(panel.unit)}</text><text x="{WIDTH - PAD}" y="{HEIGHT - 4}" text-anchor="end">{span:,.0f} s</text>')
    if alarm is not None:
        parts.append(f'<line class=alarm x1="{PAD}" y1="{y(alarm):.1f}" x2="{WIDTH - PAD}" y2="{y(alarm):.1f}"/><text class=alarm x="{WIDTH - PAD}" y="{y(alarm) - 4:.1f}" text-anchor="end">alarm {alarm:g}</text>')
    legend = []
    for n, (name, pts) in enumerate(sorted(series.items())):
        color = COLORS[n % len(COLORS)]
        points = " ".join(f"{x(t):.1f},{y(v):.1f}" for t, v in pts)
        parts.append(f'<polyline points="{points}" style="stroke:{color}"/>')
        legend.append(f'<span style="color:{color}">{html.escape(name)}</span>')
    parts.append("</svg>")
    return f"<section><h2>{html.escape(panel.title)}</h2>{''.join(parts)}<p class=legend>{' '.join(legend)}</p></section>"


STYLE = """
:root{--bg:#fff;--fg:#1a1a1a;--muted:#666;--window:#0000000d;--alarm:#c0392b;--c1:#1f6feb;--c2:#d4762c;--c3:#2e8b57;--c4:#8e44ad;--c5:#b8860b;--c6:#555}
@media (prefers-color-scheme: dark){:root{--bg:#141414;--fg:#eee;--muted:#999;--window:#ffffff12;--alarm:#ff6b5b;--c1:#6ea8ff;--c2:#f0a35e;--c3:#5fd38d;--c4:#c39bd3;--c5:#e0c060;--c6:#bbb}}
body{background:var(--bg);color:var(--fg);font:14px/1.4 system-ui,sans-serif;margin:16px;max-width:760px}
svg{width:100%;height:auto}polyline{fill:none;stroke-width:1.8}.axis{stroke:var(--muted)}.alarm{stroke:var(--alarm);fill:var(--alarm);stroke-dasharray:4 3}
.window{fill:var(--window)}text{fill:var(--muted);font-size:11px}h2{font-size:15px;margin:20px 0 4px}.legend span{margin-right:12px}.none{color:var(--muted)}
"""


def _alarms(plan: dict[str, Any] | None) -> dict[str, float]:
    if not plan:
        return {}
    return {w["id"]: float(w["threshold"]["value"]) for w in plan.get("watch", []) if isinstance(w.get("threshold"), dict)}


def render(results: dict[str, Any], samples: Sequence[Sample], plan: dict[str, Any] | None = None) -> str:
    t0 = samples[0]["t"] if samples else 0.0
    section = results.get("cluster") or {}
    window = (section["window"]["from"], section["window"]["to"]) if section.get("window") else None
    alarms = _alarms(plan)
    charts = [_chart(p, p.series(samples), t0, window, alarms.get(p.alarm_item) if p.alarm_item else None) for p in PANELS]
    rate = section.get("runs_per_second_sent")
    head = f"Load test {html.escape(str(results.get('test_id')))}: {rate:g} runs/s sent after the ramp (shaded)." if rate else f"Load test {html.escape(str(results.get('test_id')))}."
    return f"<!doctype html><html lang=en><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><title>Load test metrics</title><style>{STYLE}</style><h1>The install under the load</h1><p>{head}</p>{''.join(charts)}</html>\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="load-test-plot", description=__doc__.splitlines()[0])
    parser.add_argument("results", type=Path, help="a langsmith-load-results/1 file from a run with --namespace")
    parser.add_argument("--plan", type=Path, help="the plan the run was sized from (langsmith-sizing size), to draw the alarm levels")
    parser.add_argument("--out", type=Path, help="where to write the page; results.html beside the results by default")
    a = parser.parse_args(argv)
    series = a.results.with_suffix(".metrics.jsonl")
    if not series.exists():
        parser.error(f"{series} is missing: the run reads the install only with --namespace and --results")
    samples = [json.loads(line) for line in series.read_text().splitlines() if line.strip()]
    plan = json.loads(a.plan.read_text()) if a.plan else None
    out = a.out or a.results.with_suffix(".html")
    out.write_text(render(json.loads(a.results.read_text()), samples, plan))
    sys.stdout.write(f"wrote {out}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
