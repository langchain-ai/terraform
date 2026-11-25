"""The docs' figures: HTML pages in the LangChain brand, built from params.yaml and citations.yaml, drawn to
PNG by headless Chrome at twice the device scale, each in a light and a dark theme for a <picture>.

The brand's faces (TWK Lausanne, Aeonik Mono) and logo are licensed or LangChain's own, so they never
enter this repository: `--fonts` and `--logos` name the folders they are read from at render time, and
the pages are written to a temporary folder, so only the PNGs land here. A render without the faces is
refused, since a figure in fallback faces is not a delivery; `--draft` draws one anyway and says so on the
figure. rendered.json holds the hash of each page's markup (faces and logo excluded) at the time it was
drawn, so a test can say a figure is stale without fonts or Chrome.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import html
import json
import os
import re
import shutil
import subprocess
import tempfile
from collections.abc import Callable, Mapping, Sequence
from itertools import pairwise
from pathlib import Path
from typing import Any

from langsmith_sizing import PLANNED_CHARTS, ROOT, citations, params

FIGURES = ROOT / "docs" / "figures"
RENDERED = FIGURES / "rendered.json"
THEMES = ("light", "dark")
CORNERS = {"l": "Low", "m": "Medium", "h": "High"}
FACES = (  # (file, family, weight, format): the brand's two faces at the only weights it allows
    ("TWKLausanne-250.woff2", "TWK Lausanne", 250, "woff2"),
    ("TWKLausanne-600.woff2", "TWK Lausanne", 600, "woff2"),
    ("aeonikmono-regular.otf", "Aeonik Mono", 400, "opentype"),
    ("aeonikmono-medium.otf", "Aeonik Mono", 500, "opentype"),
)
LOGOS = {"light": "langchain-on-light.svg", "dark": "langchain-on-dark.svg"}
# Where each autoscaling signal is read, as the chart wires it (its scaled-object and hpa templates at
# the charts CI renders, charts.yaml). A signal params adds without a row here fails the build.
SIGNAL_SOURCE = {
    "cpu": ("metrics-server", "pod CPU over its request"),
    "memory": ("metrics-server", "pod memory over its request"),
    "run_backlog": ("platform-backend /metrics?format=json", "ingestion_queue.pending"),
    "queue_backlog": ("backend /metrics/queue/default", "queued"),
    "compaction_jobs": ("smithdb-compaction /metrics/jobs", "pending"),
    "admission_queue": ("each SmithDB query pod /metrics", "query_admission_queue_length"),
    "pending_segments": ("each SmithDB ingestion pod /metrics", "ingest_pending_segment_entry_count"),
    "backlog": ("the service's own backlog", "no endpoint the chart reads"),
}

# Light and dark are pairs of the brand's tokens; a rule below never names a literal colour. The warn
# trio is the extended palette's, which the brand allows for real states.
THEME_CSS = {
    "light": """--bg:#F2FAFF;--shell:#E5F4FF;--card:#F2FAFF;--line:#B2DEFF;--frame:#40668D;--text:#030710;--text-2:#161F34;
--muted:#2F4B68;--accent:#006DDD;--accent-ink:#1A5EAA;--hl:#CCE9FF;--connector:#40668D;--good:#3D8C5C;--good-ink:#161F34;
--warn:#634643;--warn-fill:#F8E8E6;--warn-line:#B27D75;""",
    "dark": """--bg:#030710;--shell:#0D1322;--card:#161F34;--line:#2F4B68;--frame:#40668D;--text:#F2FAFF;--text-2:#E5F4FF;
--muted:#99D3FF;--accent:#7FC8FF;--accent-ink:#7FC8FF;--hl:#1A2540;--connector:#5BADDF;--good:#8CDB9B;--good-ink:#8CDB9B;
--warn:#F8E8E6;--warn-fill:#634643;--warn-line:#B27D75;""",
}

CSS = """
:root { --font-sans: 'TWK Lausanne', 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
  --font-mono: 'Aeonik Mono', 'IBM Plex Mono', ui-monospace, 'SF Mono', Menlo, monospace; }
* { box-sizing: border-box; }
html, body { margin: 0; background: var(--bg); }
body { width: 1600px; color: var(--text); font-family: var(--font-sans); -webkit-font-smoothing: antialiased; }
.canvas { position: relative; padding: 56px 64px 40px; }
code, .mono { font-family: var(--font-mono); font-weight: 400; letter-spacing: 0; }
b { font-weight: 600; }
header { margin-bottom: 36px; }
.eyebrow { display: flex; gap: 14px; align-items: baseline; font: 400 19px/1.2 var(--font-mono); color: var(--accent); margin-bottom: 14px; }
.eyebrow .of { color: var(--muted); }
h1 { font: 250 46px/1.08 var(--font-sans); letter-spacing: -0.02em; margin: 0; max-width: 1440px; text-wrap: pretty; }
.sub { font: 250 21px/1.4 var(--font-sans); color: var(--muted); margin: 12px 0 0; max-width: 1340px; }
.flag { display: inline-block; margin-top: 18px; padding: 8px 14px; border: 1px solid var(--warn-line); border-radius: 8px;
  background: var(--warn-fill); color: var(--warn); font: 250 18px/1.3 var(--font-sans); }
footer { display: flex; justify-content: space-between; align-items: center; gap: 24px; margin-top: 36px; padding-top: 18px;
  border-top: 1px solid var(--line); font: 400 15px/1.3 var(--font-mono); color: var(--muted); }
footer img { height: 22px; width: auto; }
.lane { border: 1px solid var(--frame); border-radius: 14px; background: var(--shell); padding: 16px 18px 18px; }
.lane > h2 { font: 600 17px/1.2 var(--font-sans); color: var(--muted); margin: 0 0 14px; }
.card { position: relative; z-index: 3; border: 1px solid var(--line); border-radius: 10px; background: var(--card); padding: 12px 14px; }
.card h3 { font: 600 19px/1.2 var(--font-sans); margin: 0 0 4px; }
.card p { font: 250 16px/1.35 var(--font-sans); color: var(--muted); margin: 0; }
.card .v { font: 400 14px/1.35 var(--font-mono); color: var(--accent-ink); margin-top: 6px; }
.card.key { border: 1.5px solid var(--accent); background: var(--hl); }
.card.gap { border: 1.5px dashed var(--warn-line); background: var(--warn-fill); }
.card.gap h3, .card.gap p, .card.gap .v { color: var(--warn); }
.k { font: 400 14px/1.2 var(--font-mono); color: var(--muted); letter-spacing: 0.02em; }
.label { font: 600 15px/1.25 var(--font-sans); color: var(--muted); }
.chip { display: inline-flex; align-items: center; padding: 3px 10px; margin: 0 6px 6px 0; border-radius: 100px; max-width: 100%;
  overflow-wrap: anywhere; font: 400 14px/1.3 var(--font-mono); border: 1px solid var(--line); color: var(--text-2); background: var(--bg); }
.chip.on { border-color: var(--good); color: var(--good-ink); }
.chip.hot { border: 1.5px solid var(--accent); color: var(--accent-ink); background: var(--hl); }
.chip.gap { border: 1.5px dashed var(--warn-line); color: var(--warn); background: var(--warn-fill); }
svg.wires { position: absolute; left: 0; top: 0; overflow: visible; pointer-events: none; z-index: 2; }
.wire { fill: none; stroke: var(--connector); stroke-width: 1.75; stroke-linecap: round; }
.wire.gap { stroke: var(--warn-line); stroke-dasharray: 6 6; }
.end { fill: var(--connector); }
.end.gap { fill: var(--warn-line); }
"""

# Wires are drawn once the faces have loaded, from where each end actually sits, so a longer label never
# leaves a wire pointing at the old place; the height goes on <body> for the screenshot pass.
SCRIPT = """
function draw() {
  const root = document.querySelector('.canvas'), R = root.getBoundingClientRect();
  const svg = document.querySelector('svg.wires'), spec = document.getElementById('wire-spec');
  if (svg && spec) {
    svg.setAttribute('width', R.width); svg.setAttribute('height', R.height);
    let out = '';
    for (const [a, b, dir, kind] of JSON.parse(spec.textContent)) {
      const kc = kind ? ' ' + kind : '';
      const A = document.getElementById(a), B = document.getElementById(b);
      if (!A || !B) continue;
      const p = A.getBoundingClientRect(), q = B.getBoundingClientRect();
      let x1, y1, x2, y2, d;
      if (dir === 'h') {
        x1 = p.right - R.left; y1 = p.top + p.height / 2 - R.top; x2 = q.left - R.left - 7; y2 = q.top + q.height / 2 - R.top;
        const k = (x2 - x1) * 0.5;
        d = `M${x1},${y1} C${x1 + k},${y1} ${x2 - k},${y2} ${x2},${y2}`;
        out += `<circle class="end${kc}" cx="${x1}" cy="${y1}" r="3.5"/><path class="end${kc}" d="M${x2 + 7},${y2} l-9,-5 v10 z"/>`;
      } else {
        x1 = p.left + p.width / 2 - R.left; y1 = p.bottom - R.top; x2 = x1; y2 = q.top - R.top - 7;
        d = `M${x1},${y1} V${y2}`;
        out += `<path class="end${kc}" d="M${x2},${y2 + 7} l-5,-9 h10 z"/>`;
      }
      out = `<path class="wire${kc}" d="${d}"/>` + out;
    }
    svg.innerHTML = out;
  }
  document.body.dataset.h = Math.ceil(root.getBoundingClientRect().height);
}
document.fonts.ready.then(draw);
"""


def e(x: object) -> str:
    return html.escape(str(x), quote=True)


def _show(v: Any) -> str:
    if isinstance(v, bool):
        return "on" if v else "off"
    return f"{v:g}" if isinstance(v, float) else str(v)


def _page(figure: str, title: str, sub: str, body: str, source: str, wires: Sequence[Sequence[str]] = (), tool: str = "langsmith-sizing") -> str:
    """One figure's markup, theme-free: the theme, faces and logo are added at render time."""
    spec = (
        f'<script type="application/json" id="wire-spec">{json.dumps([list(w) for w in wires])}</script>'
        if wires
        else ""
    )
    return (
        f'<div class="canvas"><svg class="wires"></svg>{spec}'
        f'<header><div class="eyebrow">{name(tool)}<span class="of">{e(figure)}</span></div>'
        f'<h1>{title}</h1><p class="sub">{sub}</p><!--flag--></header>{body}'
        f"<footer><!--logo--><span>{source}</span></footer></div>"
    )


def cap(s: str) -> str:
    """Sentence case for a phrase of words: the brand's casing rule."""
    return s[:1].upper() + s[1:]


PROPER = {"clickhouse": "ClickHouse", "redis": "Redis"}


def _label(key: str) -> str:
    """A params key as a phrase: words, sentence case, product names as they are spelled."""
    return cap(" ".join(PROPER.get(w, w) for w in key.split("_")))


def name(s: str) -> str:
    """A name as its source spells it (a metric, a path, a workload, a file): exempt from sentence case."""
    return f'<span data-brand-case="explicit">{e(s)}</span>'


def _card(cid: str, title: str, text: str = "", value: str = "", cls: str = "") -> str:
    v = f'<div class="v">{value}</div>' if value else ""
    p = f"<p>{cap(text)}</p>" if text else ""
    return f'<div class="card {cls}" id="{cid}"><h3>{title}</h3>{p}{v}</div>'


# -- the figures --------------------------------------------------------------------------------


def _how_it_works(p: Mapping[str, Any], cited: citations.Cited) -> str:
    sources = [
        (
            "s-chart",
            "The Helm chart",
            "every default: requests, limits, replicas, autoscalers, SmithDB tier sizes",
            f"rendered with {name('helm template')} at the version planned",
        ),
        (
            "s-docs",
            "The public docs",
            "the scale guide, SmithDB's tiers, store requirements, the backfill rate",
            f"{len(cited.by_id)} quotes at {name(cited.commit[:7])}, checked",
        ),
        (
            "s-in",
            "Your inputs",
            "users, traces a second or a month, runs a trace, retention, where each store runs",
            "Flags, the wizard or a preset",
        ),
        (
            "s-params",
            "Parameters",
            "the model's own constants, each with unit, reason, source, author and date",
            f"{len(p)} in {name('params.yaml')}",
        ),
    ]
    stages = [
        ("m-rates", "Rates", "average and peak runs a second"),
        ("m-regime", "Regime", "the kind of load, and what it turns on"),
        ("m-guide", "The scale guide's grid", "replicas between the five published configurations"),
        ("m-payload", "Payload", "what a run costs in each store"),
        ("m-smithdb", "SmithDB", "tier, layout, replicas, metastore"),
        ("m-stores", "Stores", "Redis, Postgres, object storage"),
        ("m-operate", "Operate", "autoscaling, settings, what to watch"),
        ("m-totals", "Totals", "requests at floor, sized and ceiling; node pools"),
    ]
    outputs = [
        ("o-plan", name("plan.json"), "the whole plan, with the source of each section"),
        ("o-values", name("values.yaml"), "the chart values that apply it"),
        ("o-stores", name("stores.json"), "each store to provision"),
        ("o-profile", name("load-profile.json"), "the load it was sized for"),
    ]
    model = '<div style="height:26px"></div>'.join(_card(i, t, x) for i, t, x in stages)

    def col(items: Sequence[tuple[str, ...]]) -> str:
        return "".join(_card(i, t, x, v[0] if v else "") + '<div style="height:12px"></div>' for i, t, x, *v in items)

    body = (
        '<div style="display:grid;grid-template-columns:400px 1fr 400px;gap:72px;align-items:start">'
        f'<div class="lane" id="l-src"><h2>Sources: each number has one</h2>{col(sources)}</div>'
        f'<div class="lane" id="l-model" style="align-self:stretch"><h2>The model: pure functions, numbers in and numbers out</h2>{model}</div>'
        f'<div class="lane" id="l-out"><h2>Outputs</h2>{col(outputs)}'
        + _card(
            "o-verify",
            "Verify",
            "the load test sends the profile at the install; <code>compare</code> judges its results against the plan",
            "",
            "key",
        )
        + "</div></div>"
    )
    wires = [
        ("l-src", "l-model", "h", ""),
        *((a[0], b[0], "v", "") for a, b in pairwise(stages)),
        ("l-model", "l-out", "h", ""),
        ("o-profile", "o-verify", "v", ""),
    ]
    return _page(
        "How a plan is made",
        "Every number in a plan has one source, and only the parameters are the model's own",
        "The chart and the public docs are canon: the plan reads the chart at the version you install and quotes the docs by commit, and CI fails when either moves.",
        body,
        "Generated from params.yaml and citations.yaml",
        wires,
    )


def _scale_grid(p: Mapping[str, Any], cited: citations.Cited) -> str:
    reads, writes, blend = cited["scale.read_anchors"], cited["scale.write_anchors"], p["grid.blend"]
    published = set(cited["scale.replicas.frontend"])
    blended = {
        "lm": ("ll", "mm", blend["ll_mm"]),
        "ml": ("ll", "hl", blend["ll_hl"]),
        "mh": ("mm", "hh", blend["mm_hh"]),
        "hm": ("hl", "hh", blend["hl_hh"]),
    }
    rows_of = (
        ("frontend", "frontend"),
        ("platform-backend", "platform_backend"),
        ("ingest-queue", "ingest_queue"),
        ("backend", "backend"),
    )

    def cell(k: str) -> str:
        if k in published:
            lines = "".join(
                f'<div class="mono" style="display:flex;justify-content:space-between;font-size:17px;line-height:1.55"><span>{name(label)}</span><b class="mono" style="font-weight:500">{cited[f"scale.replicas.{key}"][k]}</b></div>'
                for label, key in rows_of
            )
            lines += f'<div class="mono" style="display:flex;justify-content:space-between;font-size:17px;line-height:1.55"><span>Redis</span><b class="mono" style="font-weight:500">{cited["scale.redis_gib"][k]} GiB</b></div>'
            return f'<div class="card key" style="min-height:220px"><div class="label" style="color:var(--accent-ink);margin-bottom:10px">Published</div>{lines}</div>'
        a, b, t = blended[k]
        return (
            f'<div class="card" style="min-height:220px;border-style:dashed"><div class="label" style="margin-bottom:10px">Blended</div>'
            f"<p>Starts {t:g} of the way from <b>{CORNERS[a[0]]}/{CORNERS[a[1]]}</b> to <b>{CORNERS[b[0]]}/{CORNERS[b[1]]}</b>, then is held between its neighbors, so no count falls as the load rises</p></div>"
        )

    head = "".join(
        f'<div style="text-align:center"><div style="font:600 18px var(--font-sans)">{CORNERS[w]} writes</div><div class="k" style="margin-top:4px" data-brand-case="explicit">{writes[CORNERS[w].lower()]:,} traces/s</div></div>'
        for w in "lmh"
    )
    rows = "".join(
        f'<div style="align-self:center"><div style="font:600 18px var(--font-sans)">{CORNERS[r]} reads</div><div class="k" style="margin-top:4px" data-brand-case="explicit">{reads[CORNERS[r].lower()]:g} users, {reads["rps"][CORNERS[r].lower()]:g} req/s</div></div>'
        + "".join(cell(r + w) for w in "lmh")
        for r in "lmh"
    )
    body = (
        '<div style="display:grid;grid-template-columns:190px repeat(3,minmax(0,1fr));gap:16px">'
        + f"<div></div>{head}{rows}</div>"
    )
    return _page(
        "The scale guide's grid",
        "The docs publish five of the grid's nine configurations, and the plan blends the other four",
        "A load between them takes the bilinear blend of the four configurations around it, each count rounded up once at the end. Below Low it takes Low; past High it scales with the axis it passes.",
        body,
        f"Generated from citations.yaml (docs self-host-scale.mdx at {cited.commit[:7]}) and params.yaml grid.blend",
    )


def _regimes(p: Mapping[str, Any], cited: citations.Cited) -> str:
    bands, rpt = p["smithdb.peak_runs_bands"], p["load.runs_per_trace"]
    order = sorted(
        p["regimes"],
        key=lambda r: (
            r.get("peak_runs_per_second_above") is not None,
            r.get("peak_band_min") is not None,
            bands.get(r.get("peak_band_min"), 0),
            r.get("peak_traces_per_second_max") is None,
            r.get("peak_traces_per_second_max") or 0,
        ),
    )

    def edge(r: Mapping[str, Any]) -> tuple[str, str]:
        if "peak_traces_per_second_max" in r:
            return f"Peak up to {r['peak_traces_per_second_max']:g} traces/s", ""
        if "peak_runs_per_second_above" in r:
            runs = r["peak_runs_per_second_above"]
            return f"Peak above {runs:,} runs/s", "the highest rate a load test held"
        if "peak_band_min" in r:
            runs = bands[r["peak_band_min"]]
            return f"Peak from {runs:,} runs/s", f"{runs / rpt:,.0f} traces/s at {rpt:g} runs a trace"
        return "Everything between", ""

    def smithdb(t: Mapping[str, Any], r: Mapping[str, Any]) -> str:
        if t.get("scale_out"):
            return "SmithDB large, its ingestion and compaction scaled with the run rate a load test measured"
        if t.get("smithdb_tier"):
            return f"SmithDB {t['smithdb_tier']}, scaled out; one unified pod on 0.18 where one pod carries the load"
        return (
            "SmithDB's tier from the load"
            if not t.get("splits")
            else "SmithDB large, with its dedicated stats-query and mutations services"
        )

    cols = ""
    for r in order:
        t, (big, small) = r["turns_on"], edge(r)
        warn = r.get("unmeasured") or t.get("warn_beyond_tested")
        chips = "".join(
            f'<span class="chip{" on" if v is True else ""}">{e(_label(k))}{"" if v is True else ": " + e(_show(v))}</span>'
            for k, v in t.items()
            if not k.startswith("smithdb_")
        )
        note = (
            '<div class="k" style="color:var(--warn);margin-top:10px">Unmeasured: every figure is to observe</div>'
            if r.get("unmeasured")
            else ""
        )
        note += (
            '<div class="k" style="color:var(--warn);margin-top:10px">Past any load test</div>'
            if t.get("warn_beyond_tested")
            else ""
        )
        cols += (
            f'<div class="card{" gap" if warn else ""}" style="padding:16px"><div class="k" style="color:var(--accent-ink);margin-bottom:8px">{name(r["id"])}</div>'
            f'<h3 style="font-weight:250;font-size:24px">{big}</h3><div class="k" style="min-height:18px" data-brand-case="explicit">{small}</div>'
            f'<p style="margin:10px 0 12px">{smithdb(t, r)}</p>{chips}{note}</div>'
        )
    axis = (
        '<div style="display:flex;align-items:center;gap:14px;margin-bottom:16px">'
        '<span class="label">Smaller peak write rate</span>'
        '<div style="flex:1;border-top:3px solid var(--accent)"></div>'
        '<span class="label" style="color:var(--accent-ink)">Larger</span></div>'
    )
    body = (
        f"{axis}"
        f'<div style="display:grid;grid-template-columns:repeat({len(order)},minmax(0,1fr));gap:14px;align-items:stretch">{cols}</div>'
    )
    return _page(
        "Regimes",
        "A regime is the kind of load, and it decides what the plan turns on",
        "The bands are data in params.yaml. The plan tests them from the largest down and takes the first that holds, so a few huge traces a second is still a large write rate.",
        body,
        "Generated from params.yaml regimes and smithdb.peak_runs_bands",
    )


def _autoscaling(p: Mapping[str, Any], cited: citations.Cited) -> str:
    sig = p["scale.signals"]
    groups: dict[str, list[str]] = {}
    for workload, w in p["scale.workloads"].items():
        for s in w["signals"]:
            groups.setdefault(s, []).append(workload)
    rows, wires = "", []
    for i, (s, names) in enumerate(groups.items()):
        field, (where, metric) = sig[s]["field"], SIGNAL_SOURCE[s]
        cls = "" if field else "gap"
        mech = " and ".join(
            sorted({"HPA" if p["scale.workloads"][n]["mechanism"] == "hpa" else "KEDA metrics-api" for n in names})
        )
        act = (
            (mech, f"<code>{name(field)}</code>")
            if field
            else ("No trigger field yet", "the plan applies CPU and reports a chart ask")
        )
        rows += (
            _card(
                f"a{i}",
                name(where) if "/" in where or "-" in where else e(cap(where)),
                "",
                name(metric) if " " not in metric else e(cap(metric)),
                cls,
            )
            + _card(f"b{i}", act[0], act[1], "", cls)
            + f'<div class="card {cls}" id="c{i}">'
            + "".join(f'<span class="chip{" gap" if not field else ""}">{name(n)}</span>' for n in names)
            + "</div>"
        )
        wires += [(f"a{i}", f"b{i}", "h", cls), (f"b{i}", f"c{i}", "h", cls)]
    body = (
        '<div style="display:grid;grid-template-columns:minmax(0,1.15fr) minmax(0,1fr) minmax(0,1fr);column-gap:84px;row-gap:14px;align-items:stretch">'
        '<div class="label">The signal, and where it is read</div><div class="label">What acts on it</div><div class="label">Workloads</div>'
        f"{rows}</div>"
        '<div style="display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:16px;margin-top:30px">'
        + _card(
            "f1",
            "Floor",
            "The autoscaler's minimum: what runs at rest and what you pay for all the time. Size node pools here, with a cluster autoscaler able to reach the ceiling.",
        )
        + _card(
            "f2",
            "Sized",
            "The replicas the model sized for the peak: the scale guide's counts, raised by the payload model where the load needs more.",
        )
        + _card(
            "f3",
            "Ceiling",
            "The autoscaler's maximum, never below the chart's. Set the namespace quota here plus the largest hook Job, or the quota blocks the autoscaler when it acts.",
            "",
            "key",
        )
        + "</div>"
    )
    return _page(
        "Autoscaling",
        "Each workload scales on the signal that shows its work waiting",
        "CPU lags a backlog and hides a memory-bound pod: SmithDB query pods were OOM-killed at about 7% CPU while a CPU autoscaler sat at its floor. Dashed rows are triggers no chart field expresses yet.",
        body,
        f"Generated from params.yaml scale.signals and scale.workloads; endpoints from the chart's templates at {' and '.join(PLANNED_CHARTS)}",
        wires,
    )


def _metrics(p: Mapping[str, Any], cited: citations.Cited) -> str:
    critical, hidden = p["watch.metrics_smithdb"]["critical"], p["watch.metrics_smithdb"]["all_only"]
    serves = [
        (
            "platform-backend",
            "/metrics?format=json",
            "pending, active, scheduled and retry for every Go queue",
            "KEDA for ingest-queue",
        ),
        ("backend", "/metrics/queue/default", "queued, active and scheduled for the Python queue", "KEDA for queue"),
        ("smithdb-compaction", "/metrics/jobs", "pending compaction jobs", "KEDA for compaction-worker"),
        (
            "every SmithDB pod",
            "/metrics on its http port",
            "Prometheus text; annotated prometheus.io/scrape, port and path",
            "your Prometheus; LangSmith's own telemetry",
        ),
        (
            "Redis",
            "INFO",
            "The used_memory, maxmemory and evicted_keys fields",
            "A redis_exporter, or the cloud's monitoring",
        ),
        (
            "Kubernetes",
            "metrics-server, kube-state-metrics, cAdvisor",
            "pod CPU and memory, autoscaler replicas, OOM kills, CPU throttling",
            "HPAs; your Prometheus",
        ),
    ]
    workloads = {"platform-backend", "backend", "smithdb-compaction"}
    head = '<div class="label">Serves</div><div class="label">Endpoint</div><div class="label">What it gives</div><div class="label">Read by</div>'
    grid = "".join(
        f'<div class="card"><h3>{name(a) if a in workloads else e(a)}</h3></div><div class="card"><div class="v" style="margin:0;font-size:16px">{name(b)}</div></div>'
        f'<div class="card"><p>{e(cap(c))}</p></div><div class="card"><p>{e(cap(d))}</p></div>'
        for a, b, c, d in serves
    )

    def chips(xs: Sequence[str], cls: str) -> str:
        return "".join(f'<span class="chip {cls}">{name(x)}</span>' for x in xs)

    body = (
        f'<div style="display:grid;grid-template-columns:230px 330px minmax(0,1fr) 330px;gap:10px">{head}{grid}</div>'
        '<div style="display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:16px;margin-top:30px">'
        f'<div class="lane"><h2>SmithDB, exported at the chart default</h2>{chips(critical, "on")}'
        '<p class="k" style="margin:8px 0 0">The chart sets <span data-brand-case="explicit">SMITHDB_&lt;COMPONENT&gt;__METRICS__MODE=critical</span> on every SmithDB pod.</p></div>'
        f'<div class="lane" style="border-style:dashed;border-color:var(--warn-line)"><h2>Only with <code data-brand-case="explicit">SMITHDB_&lt;COMPONENT&gt;__METRICS__MODE=all</code></h2>{chips(hidden, "gap")}'
        '<p class="k" style="margin:8px 0 0">A family appears only once its pod has seen it: an idle ingestion pod serves no <span data-brand-case="explicit">ingest_*</span> family.</p></div></div>'
    )
    return _page(
        "Monitoring",
        "Three JSON endpoints feed the autoscalers, and every SmithDB pod serves Prometheus",
        "Each endpoint here was read from a running install on 2026-11-18. A watch item that reads a SmithDB metric outside the default export says what to set.",
        body,
        "Generated from params.yaml watch.metrics_smithdb; endpoints from the chart's templates and a running install",
    )


PAGES: dict[str, Callable[[Mapping[str, Any], citations.Cited], str]] = {
    "how-it-works": _how_it_works,
    "scale-grid": _scale_grid,
    "regimes": _regimes,
    "autoscaling": _autoscaling,
    "metrics": _metrics,
}


def pages() -> dict[str, str]:
    """Every figure's theme-free markup, by name."""
    p, cited = params.values(params.load()), citations.load()
    return {fig: fn(p, cited) for fig, fn in PAGES.items()}


def digest(markup: str) -> str:
    return hashlib.sha256((markup + CSS + SCRIPT + json.dumps(THEME_CSS)).encode()).hexdigest()


def stale(built: Mapping[str, str]) -> list[str]:
    """Figures whose PNGs are missing or were drawn from other markup."""
    drawn = json.loads(RENDERED.read_text()) if RENDERED.is_file() else {}
    return [
        n
        for n, m in built.items()
        if drawn.get(n) != digest(m) or not all((FIGURES / f"{n}-{t}.png").is_file() for t in THEMES)
    ]


# -- drawing ------------------------------------------------------------------------------------


def faces(folder: Path | None) -> tuple[str, list[str]]:
    rules, missing = [], []
    for file, family, weight, fmt in FACES:
        path = folder / file if folder else None
        if path is None or not path.is_file():
            missing.append(file)
            continue
        mime = "font/woff2" if fmt == "woff2" else "font/otf"
        rules.append(
            f"@font-face {{ font-family: '{family}'; font-weight: {weight}; src: url(data:{mime};base64,{base64.b64encode(path.read_bytes()).decode()}) format('{fmt}'); }}"
        )
    return "\n".join(rules), missing


def document(markup: str, theme: str, fonts: str, logo: Path | None, draft: str) -> str:
    mark = (
        f'<img alt="LangChain" src="data:image/svg+xml;base64,{base64.b64encode(logo.read_bytes()).decode()}">'
        if logo and logo.is_file()
        else "<span>LangChain</span>"
    )
    flag = f'<div class="flag"><b>Draft render.</b> {e(draft)}</div>' if draft else ""
    body = markup.replace("<!--logo-->", mark).replace("<!--flag-->", flag)
    return f'<!doctype html><html lang="en"><head><meta charset="utf-8"><style>{fonts}:root{{{THEME_CSS[theme]}}}{CSS}</style></head><body>{body}<script>{SCRIPT}</script></body></html>'


def chrome() -> str:
    found = os.environ.get("CHROME") or next(
        (
            c
            for c in (
                "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                *map(shutil.which, ("google-chrome", "chromium", "chromium-browser")),
            )
            if c and Path(c).is_file()
        ),
        None,
    )
    if not found:
        raise SystemExit("no Chrome found: install Chrome or Chromium, or set CHROME to its binary")
    return found


def shoot(binary: str, page: Path, png: Path) -> None:
    """Two passes: the first lays the page out and reports its height, the second draws exactly that."""
    base = [
        binary,
        "--headless=new",
        "--disable-gpu",
        "--no-sandbox",
        "--hide-scrollbars",
        "--virtual-time-budget=5000",
    ]
    dom = subprocess.run(
        [*base, "--window-size=1600,1000", "--dump-dom", page.as_uri()],
        capture_output=True,
        text=True,
        timeout=120,
        check=True,
    ).stdout
    m = re.search(r'data-h="(\d+)"', dom)
    if not m:
        raise SystemExit(f"{page.name} never finished drawing (its script did not report a height)")
    subprocess.run(
        [*base, "--force-device-scale-factor=2", f"--window-size=1600,{m[1]}", f"--screenshot={png}", page.as_uri()],
        capture_output=True,
        timeout=120,
        check=True,
    )


def draw(fonts_dir: Path | None, logos_dir: Path | None, draft: bool, only_stale: bool = True) -> list[str]:
    fonts, missing = faces(fonts_dir)
    if missing and not draft:
        raise SystemExit(
            f"the brand faces are missing ({', '.join(missing)}): give --fonts DIR (make figures FONTS=DIR), or --draft for a labelled draft"
        )
    note = f"Drawn without the brand faces ({', '.join(missing)} missing); not for publishing." if missing else ""
    built, binary = pages(), chrome()
    drawn = json.loads(RENDERED.read_text()) if RENDERED.is_file() else {}
    names = stale(built) if only_stale else list(built)
    FIGURES.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for fig in names:
            for theme in THEMES:
                page = Path(tmp) / f"{fig}-{theme}.html"
                page.write_text(
                    document(built[fig], theme, fonts, logos_dir / LOGOS[theme] if logos_dir else None, note)
                )
                shoot(binary, page, FIGURES / f"{fig}-{theme}.png")
            if not note:
                drawn[fig] = digest(built[fig])
    RENDERED.write_text(json.dumps({n: drawn[n] for n in sorted(drawn) if n in built}, indent=2) + "\n")
    return names


if __name__ == "__main__":
    a = argparse.ArgumentParser(description=__doc__)
    a.add_argument("--fonts", type=Path, help="the folder holding the brand's four font files")
    a.add_argument("--logos", type=Path, help="the folder holding langchain-on-light.svg and langchain-on-dark.svg")
    a.add_argument(
        "--draft", action="store_true", help="draw without the faces, labelled as a draft and not recorded as drawn"
    )
    a.add_argument("--all", action="store_true", help="redraw every figure, not only the stale ones")
    x = a.parse_args()
    for n in draw(x.fonts, x.logos, x.draft, not x.all):
        print(f"drew docs/figures/{n}-light.png and {n}-dark.png")
