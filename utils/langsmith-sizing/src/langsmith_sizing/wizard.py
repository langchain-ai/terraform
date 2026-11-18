"""The wizard: ask each input in turn, show the plan's headline, write the files a deployment needs.

Each question says what the input is, the default and where the default comes from (the preset's
note when a preset gave it). An input a flag or the preset already settles with --yes is not asked.
The files are plan.json, values.yaml, stores.json and load-profile.json.
"""

from __future__ import annotations

import json
from collections.abc import Callable, Mapping
from dataclasses import dataclass, fields
from pathlib import Path
from typing import Any

from langsmith_sizing import DEFAULT_CHART, citations, deploy, inputs, params, plan, presets, profile
from langsmith_sizing import chart as chart_mod
from langsmith_sizing import values as values_mod

PLACEMENT_HELP = "external (managed or self-run outside the chart), statefulset (the chart's own), or operator (a Kubernetes operator's instances)"


@dataclass(frozen=True)
class Question:
    name: str
    kind: str
    what: str
    choices: tuple[str, ...] = ()
    when: str = ""
    """A condition on the answers so far: `trace_store!=smithdb` asks only while ClickHouse is sized."""


REQUIRED = ("users", "traces_per_second")
"""The inputs nothing defaults: a preset or the person gives them."""

QUESTIONS = (
    Question("users", "float", "Concurrent frontend users looking at traces at the busiest time"),
    Question("peak_traces_per_second", "float", "Traces a second at the busiest hour (leave blank to use the average times the peak factor)"),
    Question("traces_per_second", "float", "Average traces a second (or give --traces-per-month)"),
    Question("runs_per_trace", "float", "Runs in one trace"),
    Question("retention_days", "float", "Days a trace is kept (the base TTL)"),
    Question("trace_store", "choice", "SmithDB alone, or beside the deprecated ClickHouse during a migration", inputs.TRACE_STORES),
    Question("survives_node_loss", "bool", "Must the install keep serving when a node is lost"),
    Question("postgres", "choice", f"Where LangSmith's Postgres runs: {PLACEMENT_HELP}", inputs.PLACEMENTS),
    Question("redis", "choice", f"Where Redis runs: {PLACEMENT_HELP}", inputs.PLACEMENTS),
    Question("smithdb_metastore", "choice", f"Where the SmithDB metastore's Postgres runs: {PLACEMENT_HELP}", inputs.PLACEMENTS),
    Question("object_store", "choice", "Where trace bytes live: external (a bucket) or in-cluster (an S3-compatible store the install runs)", inputs.OBJECT_PLACEMENTS),
    Question("clickhouse", "choice", f"Where ClickHouse runs while the trace store is dual: {PLACEMENT_HELP}", inputs.PLACEMENTS, when="trace_store!=smithdb"),
    Question("datastores_on", "choice", "Do in-cluster stores share the application nodes (app) or get a pool of their own (dedicated)", inputs.DATASTORES_ON),
    Question("app_node", "shape", "The application node as vCPUxGiB, for counting nodes"),
    Question("smithdb_node", "shape", "The SmithDB node as vCPUxGiB, for counting nodes"),
    Question("datastore_node", "shape", "The data-store node as vCPUxGiB (only a dedicated pool uses it)"),
)


def parse(q: Question, text: str) -> Any:
    """An answer's value, or ValueError saying what is accepted."""
    text = text.strip()
    if q.kind == "float":
        return float(text)
    if q.kind == "bool":
        if text.lower() in ("y", "yes", "true"):
            return True
        if text.lower() in ("n", "no", "false"):
            return False
        raise ValueError("answer yes or no")
    if q.kind == "choice":
        if text not in q.choices:
            raise ValueError(f"one of {', '.join(q.choices)}")
        return text
    cpu, sep, mem = text.lower().partition("x")
    if not sep:
        raise ValueError("vCPUxGiB, for example 8x32")
    return (float(cpu), float(mem))


def _applies(q: Question, answers: Mapping[str, Any]) -> bool:
    if not q.when:
        return True
    name, _, value = q.when.partition("!=")
    return str(answers.get(name, inputs.Inputs.__dataclass_fields__[name].default)) != value


def _show(value: Any) -> str:
    if isinstance(value, tuple):
        return f"{value[0]:g}x{value[1]:g}"
    return "yes" if value is True else "no" if value is False else f"{value:g}" if isinstance(value, float) else str(value)


def defaults(answers: Mapping[str, Any], preset: presets.Preset | None, chart: chart_mod.Chart, p: dict[str, params.Param]) -> dict[str, tuple[Any, str]]:
    """Each input's default and where it comes from, given the answers so far."""
    out: dict[str, tuple[Any, str]] = {}
    if all(k in answers or (preset and k in preset.inputs) for k in REQUIRED):
        merged: dict[str, Any] = {k: tuple(v) if isinstance(v, list) else v for k, v in (preset.inputs if preset else {}).items()} | dict(answers)
        known = {f.name for f in fields(inputs.Inputs)}
        resolved, src = inputs.resolve(inputs.Inputs(chart_version=chart.version, **{k: v for k, v in merged.items() if k in known}), chart, params.values(p))
        for name in ("runs_per_trace", "retention_days", "peak_factor"):
            out[name] = (resolved[name], src[name])
    for f in fields(inputs.Inputs):
        if f.name in ("redis", "smithdb_metastore", "object_store", "clickhouse", "datastores_on", "trace_store", "survives_node_loss") and f.name not in out:
            out[f.name] = (f.default, "the model's default")
    out["postgres"] = ("external if a Postgres memory is given, else statefulset", "the model's default")
    for name, param in (("app_node", "pools.app_node"), ("smithdb_node", "pools.smithdb_node"), ("datastore_node", "pools.app_node")):
        value = params.values(p)[param]
        if param == "pools.smithdb_node":
            out[name] = ("by the SmithDB tier", f"param:{param}")
        else:
            out[name] = ((value["cpu"], value["memory_gib"]), f"param:{param}")
    if preset:
        for k, v in preset.inputs.items():
            out[k] = (tuple(v) if isinstance(v, list) else v, f"preset {preset.name}: {preset.notes[k]}")
    return out


def _n(value: float) -> str:
    """A figure for a person: one decimal at most. The raw :g printed 981.906 GiB from a sum of binary fractions."""
    return f"{round(value, 1):g}"


def headline(body: Mapping[str, Any]) -> str:
    """The plan in a screenful: regime, totals, pools, stores and what needs attention."""
    t, pools = body["totals"], body["pools"]
    ap = t["applied"]
    lines = [
        f"regime {body['regime']['id']}: {body['regime']['why']}",
        f"smithdb tier {body['smithdb']['tier']} ({body['smithdb']['topology']}), peak {body['rates']['peak_traces_per_second']:g} traces/s",
        "namespace requests (vCPU, GiB) before overhead",
    ]
    for name in ("floor", "sized", "ceiling"):
        r = ap[name]["requests"]
        lines.append(f"  at {name:<8} {_n(r['cpu'])} vCPU, {_n(r['memory_gib'])} GiB, volumes {_n(ap[name]['volume_gib'])} GiB")
    peak = t["hooks"]["peak"]
    lines.append(f"  with hook Jobs {_n(peak['requests']['cpu'])} vCPU, {_n(peak['requests']['memory_gib'])} GiB (largest: {peak['job']})")
    # The applied sized requests, not totals.cpu: that is the calculator's figure at the model's own
    # replicas, and printed here it disagreed with the lines above whenever a regime adjusted them.
    sized = ap["sized"]["requests"]
    lines.append(f"  sized x{t['overhead']:g} overhead: {_n(sized['cpu'] * t['overhead'])} vCPU, {_n(sized['memory_gib'] * t['overhead'])} GiB")
    lines.append("node pools")
    for name, pool in pools.items():
        if name == "single_node":
            lines.append(f"  single node {pool['node_cpu']:g}x{pool['node_mem_gib']:g}: {'fits' if pool['fits'] else 'does not fit'} with the hook Jobs")
            continue
        lines.append(f"  {name:<10} {pool['applied']['floor']['nodes']}-{pool['applied']['ceiling']['nodes']} nodes of {pool['node_cpu']:g}x{pool['node_mem_gib']:g}; largest pod {pool['largest_pod']} {'fits' if pool['largest_pod_fits'] else 'DOES NOT FIT'}")
    lines.append("stores")
    for key in ("postgres", "redis", "smithdb_metastore", "object_storage", "clickhouse"):
        store = body["stores"].get(key)
        if store:
            spec = store["spec"]
            what = f"{spec['instances']} x" if "instances" in spec else "instance"
            lines.append(f"  {key:<18} {spec['placement']}, {what}")
    for w in body["warnings"]:
        lines.append(f"warning {w['id']}: {w['message']}")
    return "\n".join(lines)


def write(out: Path, body: Mapping[str, Any], load_profile: Mapping[str, Any]) -> list[Path]:
    out.mkdir(parents=True, exist_ok=True)
    files = {
        "plan.json": json.dumps(body, indent=2), "values.yaml": values_mod.to_yaml(body["values"]),
        "stores.json": json.dumps(deploy.stores_json(body), indent=2), "load-profile.json": json.dumps(load_profile, indent=2),
    }
    paths = []
    for name, text in files.items():
        (out / name).write_text(text + "\n")
        paths.append(out / name)
    return paths


def _ask(q: Question, have: tuple[Any, str] | None, ask: Callable[[str], str], say: Callable[[str], None]) -> Any:
    """One question until it is understood; None keeps the default."""
    required = have is None and q.name in REQUIRED
    note = f" [{_show(have[0])}, from {have[1]}]" if have else " [required]" if required else ""
    while True:
        reply = ask(f"{q.name}: {q.what}{note}\n> ").strip()
        if not reply:
            if not required:
                return None
            say(f"{q.name} has no default")
            continue
        try:
            return parse(q, reply)
        except ValueError as err:
            say(f"not understood: {err}")


def run(
    *, chart_version: str | None, preset_name: str | None, given: Mapping[str, Any], yes: bool, out: Path,
    ask: Callable[[str], str], say: Callable[[str], None],
) -> int:
    """Ask what is not given, size, show the headline, write the files."""
    preset = presets.load(preset_name) if preset_name else None
    if chart_version is None:
        if yes:
            raise ValueError("give --chart")
        chart_version = ask(f"chart version (for example {DEFAULT_CHART}): ").strip()
    chart, loaded = chart_mod.Chart(chart_version), params.load()
    answers: dict[str, Any] = dict(given)
    for q in QUESTIONS:
        if yes or q.name in given or (q.name == "traces_per_second" and "traces_per_month" in given) or not _applies(q, answers):
            continue
        reply = _ask(q, defaults(answers, preset, chart, loaded).get(q.name), ask, say)
        if reply is not None:
            answers[q.name] = reply
    if preset is None and "users" not in answers:
        raise ValueError("give --preset or --users")
    inp = preset.to_inputs(chart_version, **answers) if preset else inputs.Inputs(chart_version, **answers)
    cited = citations.load()
    body = plan.size(inp, chart, loaded, cited)
    say(headline(body))
    paths = write(out, body, profile.load_profile(inp, chart, loaded, cited))
    say("wrote " + ", ".join(str(x) for x in paths))
    return 0
