"""The model's own constants (params.yaml): the only numbers this package owns.

A parameter exists because no chart value, docs page or input gives the number. Each one carries
what makes it reviewable: its unit, why it is that value, where the value came from, who
established it and since when. A parameter that overrides a chart setting names it in `chart_key`,
and a test fails when the two agree: the chart then owns the number and the parameter is dead. A
scalar parameter that overrides none says why in `chart_has_no_key`, so a number the chart already
gives cannot slip in as a second source by leaving the key out. A parameter without that evidence
is refused at load, so a number cannot enter the model unexplained.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

from langsmith_sizing import ROOT
from langsmith_sizing.chart import Chart, cpu, gib

PARAMS = ROOT / "params.yaml"

# Where a value can come from. docs and chart are absent on purpose: a number either of them gives
# is read there (citations.py, chart.py), never restated as a parameter.
SOURCE_KINDS = ("measurement", "load-test", "field", "lab", "derived", "decision")
REQUIRED = ("value", "unit", "why", "source", "by", "since")


class ParamError(ValueError):
    pass


@dataclass(frozen=True)
class Param:
    id: str
    value: Any
    unit: str
    why: str
    source_kind: str
    source_ref: str
    by: str
    since: str
    chart_key: str | None = None
    chart_has_no_key: str | None = None


def _check(pid: str, entry: dict[str, Any]) -> Param:
    missing = [k for k in REQUIRED if k not in entry]
    if missing:
        raise ParamError(f"{pid}: missing {', '.join(missing)}")
    source = entry["source"]
    if not isinstance(source, dict) or source.get("kind") not in SOURCE_KINDS or not source.get("ref"):
        raise ParamError(f"{pid}: source needs a kind ({', '.join(SOURCE_KINDS)}) and a ref")
    if not str(entry["why"]).strip():
        raise ParamError(f"{pid}: why is empty")
    no_key = entry.get("chart_has_no_key")
    if no_key is not None and (not isinstance(no_key, str) or not no_key.strip()):
        raise ParamError(f"{pid}: chart_has_no_key is the reason no chart setting gives this number, so it must say it")
    if no_key is not None and entry.get("chart_key"):
        raise ParamError(f"{pid}: chart_key and chart_has_no_key contradict each other")
    return Param(pid, entry["value"], str(entry["unit"]), str(entry["why"]), source["kind"], str(source["ref"]), str(entry["by"]), str(entry["since"]), entry.get("chart_key"), no_key)


def load(path: Path = PARAMS) -> dict[str, Param]:
    doc = yaml.safe_load(path.read_text())
    if doc.get("schema") != 1:
        raise ParamError(f"{path.name}: schema {doc.get('schema')!r}, this package reads 1")
    return {pid: _check(pid, entry) for pid, entry in (doc.get("params") or {}).items()}


def values(loaded: dict[str, Param]) -> dict[str, Any]:
    """The loaded parameters as id -> value, the shape the model's functions are handed."""
    return {pid: p.value for pid, p in loaded.items()}


def _chart_value(chart: Chart, p: Param) -> Any:
    raw = chart.at(p.chart_key or "")
    if raw is None:
        return None
    if p.unit == "vCPU":
        return cpu(raw)
    if p.unit == "GiB":
        return gib(raw)
    return float(raw) if isinstance(raw, str) else raw


def _is_scalar(value: Any) -> bool:
    return not isinstance(value, (dict, list))


def _leaves(node: Any, path: str = "") -> list[tuple[str, Any]]:
    """Each scalar setting of the chart's values as (dotted key, value); lists are skipped."""
    if isinstance(node, dict):
        return [leaf for k, v in node.items() for leaf in _leaves(v, f"{path}.{k}" if path else str(k))]
    return [] if isinstance(node, list) else [(path, node)]


def _same(raw: Any, p: Param) -> bool:
    try:
        have = cpu(raw) if p.unit == "vCPU" else gib(raw) if p.unit == "GiB" else raw if isinstance(raw, bool) or isinstance(p.value, bool) else float(raw)
    except (TypeError, ValueError):
        return False
    return bool(have == p.value)


def shadowed(loaded: dict[str, Param], chart: Chart) -> list[str]:
    """Each parameter that gives a chart setting a number the chart already gives: the chart then
    owns the number and the parameter is a second source for it. A key the chart lacks is a
    problem too, so a renamed setting is noticed. A scalar parameter that names no key must say
    `chart_has_no_key`; where the chart holds its value somewhere the message names the keys, so
    the author sees which setting it may be restating."""
    problems = []
    settings = _leaves(chart.values)
    for p in loaded.values():
        if p.chart_key:
            have = _chart_value(chart, p)
            if have is None:
                problems.append(f"{p.id}: chart {chart.version} has no {p.chart_key}")
            elif have == p.value:
                problems.append(f"{p.id}: chart {chart.version} already gives {p.chart_key} = {have}; read it there")
        elif _is_scalar(p.value) and not p.chart_has_no_key:
            same = [k for k, raw in settings if _same(raw, p)][:3]
            seen = f"; chart {chart.version} holds {p.value!r} at {', '.join(same)}" if same else ""
            problems.append(f"{p.id}: names no chart_key and does not say chart_has_no_key{seen}")
    return problems
