"""The docs' tables, generated from params.yaml and citations.yaml.

A table typed by hand goes stale the day a parameter moves, and nothing says so. Each table here sits
between `<!-- generated:NAME -->` markers in a doc (the citations and parameters in docs/parameters.md, the
rest beside the prose that reads them); `python -m langsmith_sizing.docs_gen` rewrites them,
and a test fails a committed table that differs from what this writes. The figures are figures.py.
"""

from __future__ import annotations

import json
import re
from collections.abc import Callable, Mapping
from typing import Any

from langsmith_sizing import ROOT, citations, params
from langsmith_sizing.figures import SIGNAL_SOURCE

DOCS = ROOT / "docs"
MARKER = re.compile(r"(<!-- generated:([a-z-]+) -->\n)(.*?)(<!-- /generated:\2 -->)", re.S)
CORNERS = {"l": "Low", "m": "Medium", "h": "High"}


def _data() -> tuple[dict[str, Any], citations.Cited, dict[str, params.Param]]:
    loaded = params.load()
    return params.values(loaded), citations.load(), loaded


def _fmt(v: Any) -> str:
    if isinstance(v, bool):
        return "on" if v else "off"
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    if isinstance(v, (int, float)):
        return f"{v:,}"
    if isinstance(v, (dict, list)):
        return json.dumps(v, separators=(", ", ": ")).replace('"', "")
    return str(v)


def _table(head: list[str], rows: list[list[Any]]) -> str:
    def cell(v: Any) -> str:
        return _fmt(v).replace("|", "\\|").replace("\n", " ")

    lines = ["| " + " | ".join(head) + " |", "|" + "|".join(":--" for _ in head) + "|"]
    return "\n".join(lines + ["| " + " | ".join(cell(v) for v in r) + " |" for r in rows]) + "\n"


# -- tables ------------------------------------------------------------------------------------


def _scale_guide(p: Mapping[str, Any], cited: citations.Cited) -> str:
    reads, writes = cited["scale.read_anchors"], cited["scale.write_anchors"]
    rows = []
    for k in cited["scale.replicas.frontend"]:
        r, w = CORNERS[k[0]], CORNERS[k[1]]
        rk, wk = r.lower(), w.lower()
        rows.append(
            [
                f"{r} reads ({reads[rk]:g} users), {w} writes ({writes[wk]:,} traces/s)",
                *(cited[f"scale.replicas.{s}"][k] for s in ("frontend", "platform_backend", "ingest_queue", "backend")),
                cited["scale.redis_gib"][k],
                f"{cited['scale.clickhouse']['cpu'][k]} vCPU, {cited['scale.clickhouse']['mem_gib'][k]} GiB",
            ]
        )
    return _table(
        [
            "Published configuration",
            "frontend",
            "platform-backend",
            "ingest-queue",
            "backend",
            "Redis GiB",
            "ClickHouse",
        ],
        rows,
    )


def _smithdb_tiers(p: Mapping[str, Any], cited: citations.Cited) -> str:
    qps, meta = cited["smithdb.tested_qps"], cited["smithdb.metastore"]
    parts = ("ingestion", "query", "compaction", "compaction-worker", "cluster-manager")
    rows = [
        [
            t,
            f"{qps[t]['ingest']:,} / {qps[t]['query']:,}",
            f"below {p['smithdb.peak_runs_bands'][t]:,}",
            *(cited[f"smithdb.replicas.{c}"][t] for c in parts),
            f"{meta[t]['cpu']} vCPU, {meta[t]['memory_gib']} GiB",
        ]
        for t in qps
    ]
    return _table(
        ["Tier", "Tested ingest / query QPS (docs)", "Peak runs/s (model's band)", *parts, "Metastore (docs)"], rows
    )


def _regimes(p: Mapping[str, Any], cited: citations.Cited) -> str:
    bands = p["smithdb.peak_runs_bands"]

    def bound(r: Mapping[str, Any]) -> str:
        if "peak_band_min" in r:
            return f"peak at or above {bands[r['peak_band_min']]:,} runs/s"
        out = []
        if "peak_traces_per_second_max" in r:
            out.append(f"peak at or below {r['peak_traces_per_second_max']:g} traces/s")
        out += [f"{k} is {_fmt(v).lower()}" for k, v in (r.get("requires") or {}).items()]
        return ", ".join(out) or "everything else"

    rows = [
        [
            f"`{r['id']}`",
            bound(r),
            ", ".join(f"{k}: {_fmt(v)}" for k, v in r["turns_on"].items()),
            "yes" if r.get("unmeasured") else "",
        ]
        for r in p["regimes"]
    ]
    return _table(["Regime (tested in this order)", "Holds when", "Turns on", "Unmeasured"], rows)


def _autoscaling(p: Mapping[str, Any], cited: citations.Cited) -> str:
    sig = p["scale.signals"]
    rows = []
    for name, w in p["scale.workloads"].items():
        reads = "; ".join(": ".join(SIGNAL_SOURCE[s]) for s in w["signals"]) or "none"
        field = (
            ", ".join(f"`{sig[s]['field']}`" if sig[s]["field"] else "no field (a chart ask)" for s in w["signals"])
            or "-"
        )
        rows.append([f"`{name}`", w["mechanism"], reads, field, w["why"]])
    return _table(["Workload", "Mechanism", "Signal, and where it is read", "Chart field", "Why this signal"], rows)


def _watch(p: Mapping[str, Any], cited: citations.Cited) -> str:
    def level(spec: Any) -> str:
        if spec is None:
            return "observe"
        if spec.get("per") == "autoscaled":
            return "the plan's ceiling, per autoscaler"
        if "from" in spec:
            return f"`{spec['from']}`"
        return f"{_fmt(spec['value'])} ({spec['unit']})"

    rows = [
        [
            f"`{i['id']}`",
            f"`{i['metric']}`",
            i["where"] + (f". Needs {i['needs']}" if i.get("needs") else ""),
            level(i["threshold"]),
            i["action"],
        ]
        for i in p["watch.items"]
    ]
    return _table(["Item", "Metric", "Where it is read", "Alarm level", "Action"], rows)


def _citations(p: Mapping[str, Any], cited: citations.Cited) -> str:
    rows = [[f"`{c.id}`", f"`{c.file.removeprefix('src/langsmith/')}`", _fmt(c.values)] for c in cited.by_id.values()]
    return _table(["Citation", "Docs page", "Values it gives"], rows)


def _params(p: Mapping[str, Any], cited: citations.Cited, loaded: Mapping[str, params.Param]) -> str:
    rows = [
        [
            f"`{x.id}`",
            x.value
            if not isinstance(x.value, (dict, list)) or len(_fmt(x.value)) < 60
            else "(a table: see params.yaml)",
            x.unit,
            x.source_kind,
            x.by,
        ]
        for x in loaded.values()
    ]
    return _table(["Parameter", "Value", "Unit", "Source", "By"], rows)


TABLES: dict[str, Callable[..., str]] = {
    "scale-guide": _scale_guide,
    "smithdb-tiers": _smithdb_tiers,
    "regimes": _regimes,
    "autoscaling": _autoscaling,
    "watch": _watch,
    "citations": _citations,
    "params": _params,
}


def table(name: str) -> str:
    p, cited, loaded = _data()
    fn = TABLES[name]
    return fn(p, cited, loaded) if name == "params" else fn(p, cited)


def fill(text: str) -> str:
    """A doc with every generated block rewritten; an unknown block name raises KeyError."""
    return MARKER.sub(lambda m: m[1] + table(m[2]) + m[4], text)


def write() -> None:
    for doc in [ROOT / "README.md", ROOT / "CONTRIBUTING.md", *sorted(DOCS.glob("*.md")), ROOT / "presets" / "README.md"]:
        text = doc.read_text()
        if MARKER.search(text):
            doc.write_text(fill(text))


if __name__ == "__main__":
    write()
