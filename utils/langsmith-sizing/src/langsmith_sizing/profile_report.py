"""The plan against the hand-written profiles the modules ship: where they differ, per cloud.

Each module keeps modules/<cloud>/helm/values/examples/langsmith-values-sizing-<name>.yaml. This
reads them, sizes the preset of the same name, and sets the plan's replicas and requests for each
workload beside every cloud's values. It only reads: nothing is written to a module.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml

from langsmith_sizing import ROOT
from langsmith_sizing.chart import cpu, gib

CLOUDS = ("aws", "gcp", "azure", "baremetal")
PROFILES = ("minimum", "dev", "production", "production-large")
"""The module profile names, each also a preset."""
REPO = ROOT.parents[1]
FIGURES = ("min", "max", "cpu", "memory_gib")
MISSING = "not set"


def values_path(root: Path, cloud: str, profile: str) -> Path:
    return root / "modules" / cloud / "helm" / "values" / "examples" / f"langsmith-values-sizing-{profile}.yaml"


def values_key(workload: str) -> str:
    """The chart's camelCase key for a plan workload name: platform-backend -> platformBackend."""
    head, *rest = workload.split("-")
    return head + "".join(w.title() for w in rest)


def module_figures(doc: dict[str, Any], workload: str) -> dict[str, Any]:
    """What a module's values give a workload: min and max replicas, requests; None where unset.
    An enabled autoscaler gives the range; otherwise deployment.replicas gives both ends."""
    block = doc.get(values_key(workload)) or {}
    deployment = block.get("deployment") or {}
    scaling = block.get("autoscaling") or {}
    lo = hi = deployment.get("replicas")
    for kind, floor, ceiling in (("hpa", "minReplicas", "maxReplicas"), ("keda", "minReplicaCount", "maxReplicaCount")):
        if (scaling.get(kind) or {}).get("enabled"):
            lo, hi = scaling[kind].get(floor), scaling[kind].get(ceiling)
    requests = (deployment.get("resources") or {}).get("requests") or {}
    return {
        "min": lo, "max": hi,
        "cpu": cpu(requests["cpu"]) if "cpu" in requests else None,
        "memory_gib": gib(requests["memory"]) if "memory" in requests else None,
    }


def plan_figures(plan: dict[str, Any], workload: str) -> dict[str, Any]:
    """The plan's replicas and requests for a workload. Where an autoscaler is applied its range is
    what the chart gets (`scale`); otherwise the sizing's own min and max are."""
    entry = plan["workloads"][workload]
    applied = (plan["scale"].get(workload) or {}).get("applied") or {}
    lo, hi = (applied["min"], applied["max"]) if applied.get("kind", "none") != "none" else (entry["min"], entry["max"])
    return {"min": lo, "max": hi, "cpu": entry["requests"]["cpu"], "memory_gib": entry["requests"]["memory_gib"]}


def _read(path: Path) -> dict[str, Any] | None:
    return yaml.safe_load(path.read_text()) if path.is_file() else None


def _cell(have: dict[str, Any] | None, want: dict[str, Any]) -> tuple[str, int]:
    """One table cell and how many of its four figures differ from the plan's."""
    if have is None:
        return "no file", 0

    def show(key: str) -> str:
        value = have[key]
        return f"{MISSING if value is None else f'{value:g}'}{'' if value == want[key] else '*'}"
    differing = sum(have[k] != want[k] for k in FIGURES)
    return f"{show('min')}-{show('max')}, {show('cpu')} / {show('memory_gib')}", differing


def profile_table(profile: str, plan: dict[str, Any], root: Path = REPO) -> tuple[str, dict[str, int]]:
    """A markdown table for one profile and, per cloud, how many figures differ from the plan's."""
    docs: dict[str, dict[str, Any] | None] = {c: _read(values_path(root, c, profile)) for c in CLOUDS}
    rows = ["| workload | plan | " + " | ".join(CLOUDS) + " |", "|:--|:--|" + ":--|" * len(CLOUDS)]
    differing = dict.fromkeys(CLOUDS, 0)
    for name in plan["workloads"]:
        want = plan_figures(plan, name)
        cells = []
        for c in CLOUDS:
            doc = docs[c]
            text, n = _cell(None if doc is None else module_figures(doc, name), want)
            differing[c] += n
            cells.append(text)
        rows.append(f"| {name} | {want['min']:g}-{want['max']:g}, {want['cpu']:g} / {want['memory_gib']:g} | " + " | ".join(cells) + " |")
    return "\n".join(rows), differing


def report(chart_version: str, plans: dict[str, dict[str, Any]], root: Path = REPO) -> str:
    """The tables for each profile in `plans` (profile name -> plan) and the count of differing figures."""
    out = ["Each cell is replicas min-max, then CPU request / memory request in GiB. A * marks a figure that differs from the plan's.", ""]
    for profile, plan in plans.items():
        table, differing = profile_table(profile, plan, root)
        total = len(plan["workloads"]) * len(FIGURES)
        counts = ", ".join(f"{c} {n} of {total}" for c, n in differing.items())
        out += [f"## {profile} (chart {chart_version})", "", table, "", f"Figures that differ from the plan: {counts}.", ""]
    return "\n".join(out)
