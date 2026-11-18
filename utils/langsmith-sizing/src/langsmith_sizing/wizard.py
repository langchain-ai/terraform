"""The wizard: ask what the load and the install are, size it, save a folder a deployment needs.

Each question says what the input is, the default and where the default comes from (the preset's
note when a preset gave it). An input a flag, the preset or a saved sizing already settles is not
asked with --yes. A sizing is a folder (`save`):

  inputs.yaml        the answers and where each came from; `--preset <dir>/inputs.yaml` sizes it again
  plan.json          everything the plan says, every figure with its source (docs/fields.md)
  values.yaml        the chart values that apply it; `# fill:` lines name what only you know
  stores.json        what to provision for each data store
  load-profile.json  the load the plan was sized for, as the load test reads it
  summary.md         the tables the terminal shows, to send to whoever deploys it
"""

from __future__ import annotations

import datetime as dt
import json
from collections.abc import Callable, Mapping
from dataclasses import dataclass, fields
from pathlib import Path
from typing import Any

from langsmith_sizing import chart as chart_mod
from langsmith_sizing import citations, deploy, inputs, params, plan, presets, profile, summary, ui
from langsmith_sizing import values as values_mod
from langsmith_sizing.model import products as products_mod
from langsmith_sizing.units import KILO

PLACEMENTS = (
    ("external", "a managed service, or one you run outside the cluster"),
    ("statefulset", "the chart runs it in the cluster"),
    ("operator", "a Kubernetes operator's instances in the cluster"),
)
INPUTS_FILE = "inputs.yaml"
FILES = (
    (INPUTS_FILE, "your answers; size again with make plan NAME="),
    ("plan.json", "the whole plan, every figure with its source"),
    ("values.yaml", "chart values; fill the # fill: lines, then helm upgrade -f"),
    ("stores.json", "what to provision for each data store"),
    ("load-profile.json", "the load the plan was sized for, for make load"),
    ("summary.md", "these tables, to send to whoever deploys it"),
)


IN_CLUSTER = ("statefulset", "operator")


def _value(answers: Mapping[str, Any], name: str) -> Any:
    return answers.get(name, inputs.Inputs.__dataclass_fields__[name].default)


def _dual(a: Mapping[str, Any]) -> bool:
    return bool(_value(a, "trace_store") != "smithdb")


def _any_in_cluster(a: Mapping[str, Any]) -> bool:
    """A store the cluster runs; datastores_on means nothing when every store is outside it."""
    stores = ["postgres", "redis", "smithdb_metastore"] + (["clickhouse"] if _dual(a) else [])
    return any(_value(a, k) in IN_CLUSTER or (k == "postgres" and _value(a, k) is None) for k in stores) or _value(a, "object_store") == "in-cluster"


CATALOG = products_mod.catalog()


def _runs(name: str) -> Callable[[Mapping[str, Any]], bool]:
    """Asked only when the product runs, chosen or required by one chosen (Engine brings Sandboxes)."""
    def check(a: Mapping[str, Any]) -> bool:
        return name in products_mod.chosen(list(a.get("products") or ()), CATALOG)[0]
    return check


def _dedicated(a: Mapping[str, Any]) -> bool:
    return bool(_any_in_cluster(a) and _value(a, "datastores_on") == "dedicated")


@dataclass(frozen=True)
class Question:
    name: str
    kind: str
    what: str
    section: str
    choices: tuple[tuple[str, str], ...] = ()
    when: Callable[[Mapping[str, Any]], bool] | None = None
    """Asked only when this holds on the answers so far: ClickHouse only while the trace store is dual."""


REQUIRED = ("users", "traces_per_second")
"""The inputs nothing defaults: a preset or the person gives them."""

LOAD, INSTALL, PRODUCTS, STORES, NODES = "Load", "Install", "Products", "Data stores", "Nodes"
AGENT_LOADS = (
    ("ll", "low reads, low writes: about 5 requests a second each"),
    ("lh", "low writes, high reads: about 500 reads a second"),
    ("hl", "high writes, low reads: about 500 writes a second"),
    ("mm", "medium both: about 50 a second each"),
    ("hh", "high both: about 500 a second each"),
)
QUESTIONS = (
    Question("users", "float", "People looking at traces at the same time, at the busiest hour", LOAD),
    Question("traces_per_second", "rate", "Average traces a second, or a month's count as 20M/month", LOAD),
    Question("peak_traces_per_second", "float", "Traces a second at the busiest hour; Enter takes the average times the peak factor", LOAD),
    Question("runs_per_trace", "float", "Runs in one trace (each LLM call, tool call or step is a run)", LOAD),
    Question("retention_days", "float", "Days a trace is kept before it expires (the base TTL)", LOAD),
    Question("trace_store", "choice", "Where traces are stored", INSTALL, (
        ("smithdb", "SmithDB alone, for a new install"),
        ("dual", "SmithDB beside ClickHouse while history migrates"),
        ("dual-replicated", "the same, with a 3-node ClickHouse"),
    )),
    Question("survives_node_loss", "bool", "Must it keep serving when a node is lost (yes: at least two of every pod, three of each operator-run store)", INSTALL),
    Question("products", "multi", "What runs besides tracing: numbers or names, comma separated; Enter for tracing only", PRODUCTS,
             tuple((n, f"{s['label']}" + (f", brings {', '.join(r for r in s['requires'] if r != 'traces')}" if [r for r in s["requires"] if r != "traces"] else "")) for n, s in CATALOG.items() if n != "traces")),
    Question("agent_deployments", "int", "Agent Server deployments the operator will run", PRODUCTS, when=_runs("agent_server")),
    Question("agent_load", "choice", "Each deployment's load, as the docs' Agent Server table", PRODUCTS, AGENT_LOADS, when=_runs("agent_server")),
    Question("gateway_streams", "float", "LLM gateway: concurrent streams at the busiest time; Enter keeps the chart's autoscaler", PRODUCTS, when=_runs("gateway")),
    Question("sandboxes", "float", "Sandboxes running at once at the busiest time", PRODUCTS, when=_runs("sandboxes")),
    Question("sandbox_vcpu", "float", "vCPU each sandbox is given", PRODUCTS, when=_runs("sandboxes")),
    Question("sandbox_memory_gib", "float", "GiB each sandbox is given", PRODUCTS, when=_runs("sandboxes")),
    Question("sandbox_node", "shape", "Your KVM node for sandboxes, as vCPUxGiB (x86-64 with /dev/kvm; one host a node)", PRODUCTS, when=_runs("sandboxes")),
    Question("postgres", "choice", "LangSmith's Postgres", STORES, PLACEMENTS),
    Question("redis", "choice", "Redis, the queue every run passes through", STORES, PLACEMENTS),
    Question("smithdb_metastore", "choice", "SmithDB's metastore, a Postgres 18 of its own", STORES, PLACEMENTS),
    Question("object_store", "choice", "Where trace bytes live", STORES, (
        ("external", "a bucket: S3, GCS, Azure Blob or your own S3 API"),
        ("in-cluster", "an S3-compatible store the install runs"),
    )),
    Question("clickhouse", "choice", "ClickHouse, while the trace store is dual", STORES, PLACEMENTS, when=_dual),
    Question("datastores_on", "choice", "Where in-cluster stores run", NODES, (
        ("app", "on the application nodes"),
        ("dedicated", "on a node pool of their own"),
    ), when=_any_in_cluster),
    Question("app_node", "shape", "Your application node, as vCPUxGiB, to count nodes", NODES),
    Question("smithdb_node", "shape", "Your SmithDB node, as vCPUxGiB", NODES),
    Question("datastore_node", "shape", "Your data-store node, as vCPUxGiB", NODES, when=_dedicated),
)


SCALE = {"k": KILO, "m": KILO * KILO, "b": KILO * KILO * KILO}
MONTH = "/month"


def number(text: str) -> float:
    """A count as a person writes it: 3000000, 3M or 2.5k."""
    text = text.strip().lower().replace(",", "").replace("_", "")
    if text[-1:] in SCALE:
        return float(text[:-1]) * SCALE[text[-1]]
    return float(text)


def parse(q: Question, text: str) -> Any:
    """An answer's value, or ValueError saying what is accepted. A choice takes its number or its name;
    a rate takes traces a second, or a month's count as 20M/month (returned as ("month", count))."""
    text = text.strip()
    if q.kind == "rate":
        if text.lower().endswith(MONTH):
            return ("month", number(text[: -len(MONTH)]))
        return number(text)
    if q.kind == "float":
        return number(text)
    if q.kind == "int":
        return int(number(text))
    if q.kind == "multi":
        names = [c[0] for c in q.choices]
        if text.lower() in ("none", "traces"):
            return ("traces",)
        picked = [names[int(t) - 1] if t.isdigit() and 1 <= int(t) <= len(names) else t.replace("-", "_") for t in (x.strip() for x in text.split(",")) if t]
        bad = [t for t in picked if t not in names]
        if bad:
            raise ValueError(f"numbers or names from the list; not {', '.join(bad)}")
        return tuple(dict.fromkeys(["traces", *picked]))
    if q.kind == "bool":
        if text.lower() in ("y", "yes", "true"):
            return True
        if text.lower() in ("n", "no", "false"):
            return False
        raise ValueError("answer yes or no")
    if q.kind == "choice":
        names = [c[0] for c in q.choices]
        if text.isdigit() and 1 <= int(text) <= len(names):
            return names[int(text) - 1]
        if text not in names:
            raise ValueError(f"a number, or one of {', '.join(names)}")
        return text
    cpu, sep, mem = text.lower().partition("x")
    if not sep:
        raise ValueError("vCPUxGiB, for example 8x32")
    return (float(cpu), float(mem))


def _applies(q: Question, answers: Mapping[str, Any]) -> bool:
    return q.when is None or q.when(answers)


def plain(source: str) -> str:
    """Where a default comes from, in words: param:x is params.yaml, chart:k the chart's value."""
    kind, _, ref = source.partition(":")
    if kind == "param" and ref:
        return f"the model's default, params.yaml {ref}"
    if kind == "chart" and ref:
        return f"the chart's default, {ref}"
    return source


def show_value(value: Any) -> str:
    if isinstance(value, (tuple, list)) and value and isinstance(value[0], str):
        return ", ".join(v for v in value if v != "traces") or "tracing only"
    if isinstance(value, (tuple, list)):
        return f"{value[0]:g}x{value[1]:g}"
    return "yes" if value is True else "no" if value is False else f"{value:g}" if isinstance(value, float) else str(value)


def defaults(answers: Mapping[str, Any], preset: presets.Preset | None, chart: chart_mod.Chart, p: dict[str, params.Param]) -> dict[str, tuple[Any, str]]:
    """Each input's default and where it comes from, given the answers so far."""
    out: dict[str, tuple[Any, str]] = {}
    have = set(answers) | set(preset.inputs if preset else {})
    if "traces_per_month" in have:
        have.add("traces_per_second")
    if all(k in have for k in REQUIRED):
        merged: dict[str, Any] = {k: tuple(v) if isinstance(v, list) else v for k, v in (preset.inputs if preset else {}).items()} | dict(answers)
        known = {f.name for f in fields(inputs.Inputs)}
        resolved, src = inputs.resolve(inputs.Inputs(chart_version=chart.version, **{k: v for k, v in merged.items() if k in known}), chart, params.values(p))
        for name in ("runs_per_trace", "retention_days", "peak_factor"):
            out[name] = (resolved[name], src[name])
    for f in fields(inputs.Inputs):
        if f.name in ("redis", "smithdb_metastore", "object_store", "clickhouse", "datastores_on", "trace_store", "survives_node_loss") and f.name not in out:
            out[f.name] = (f.default, "the model's default")
    out["postgres"] = ("statefulset", "the model's default")
    pv = params.values(p)
    out["products"] = (("traces",), "tracing only")
    out["agent_deployments"] = (1, "the model's default")
    out["agent_load"] = (pv["agent_server.load_default"], "param:agent_server.load_default")
    out["gateway_streams"] = ("the chart's autoscaler", "chart:agentGateway.autoscaling")
    out["sandboxes"] = (pv["sandboxes.concurrent_default"], "param:sandboxes.concurrent_default")
    out["sandbox_vcpu"] = (pv["sandboxes.vcpu_each"], "param:sandboxes.vcpu_each")
    out["sandbox_memory_gib"] = (citations.load()["sandboxes.memory"]["memory_gib_each"], "the docs' example, self-host-sandbox-scaling")
    out["sandbox_node"] = ((pv["pools.sandbox_node"]["cpu"], pv["pools.sandbox_node"]["memory_gib"]), "param:pools.sandbox_node")
    for name, param in (("app_node", "pools.app_node"), ("smithdb_node", "pools.smithdb_node"), ("datastore_node", "pools.app_node")):
        value = params.values(p)[param]
        if param == "pools.smithdb_node":
            out[name] = ("by the SmithDB tier", f"param:{param}")
        else:
            out[name] = ((value["cpu"], value["memory_gib"]), f"param:{param}")
    if preset:
        for k, v in preset.inputs.items():
            out[k] = (tuple(v) if isinstance(v, list) else v, f"{'saved' if preset.saved else 'preset'} {preset.name}: {preset.notes[k]}")
    return out


def _ask(q: Question, have: tuple[Any, str] | None, ask: Callable[[str], str]) -> Any:
    """One question until it is understood; None keeps the default."""
    required = have is None and q.name in REQUIRED
    ui.question(q.name, q.what, "" if have is None else show_value(have[0]), "" if have is None else plain(have[1]), q.choices)
    blank = False
    while True:
        reply = ask("  > ").strip()
        if not reply:
            if not required:
                return None
            if blank:
                raise ValueError(f"{q.name} has no default and was left blank twice; nothing was written")
            blank = True
            ui.warn(f"{q.name} has no default: give a number")
            continue
        try:
            return parse(q, reply)
        except ValueError as err:
            ui.warn(f"not understood: {err}")


def _pick_preset(ask: Callable[[str], str]) -> presets.Preset | None:
    """Start from a named load, or from nothing."""
    loaded = [presets.load(n) for n in presets.names()]
    q = Question("start", "choice", "Start from a preset (every answer stays yours to change), or from nothing", "", (("none", "answer every question"),) + tuple((p.name, p.why) for p in loaded))
    ui.question(q.name, q.what, "none", "", q.choices)
    while True:
        reply = ask("  > ").strip() or "none"
        try:
            choice = parse(q, reply)
        except ValueError as err:
            ui.warn(f"not understood: {err}")
            continue
        return None if choice == "none" else presets.load(choice)


def _confirm(ask: Callable[[str], str]) -> bool:
    while True:
        reply = ask("  Size it and save the folder? [Y/n] > ").strip().lower()
        if reply in ("", "y", "yes"):
            return True
        if reply in ("n", "no"):
            return False


def notes_for(answers: Mapping[str, Any], preset: presets.Preset | None, given: Mapping[str, Any], how: str) -> dict[str, str]:
    """Where each saved input came from, so the folder says who decided what."""
    def same(a: Any, b: Any) -> bool:
        return (list(a) if isinstance(a, tuple) else a) == (list(b) if isinstance(b, tuple) else b)

    out = {}
    for k in answers:
        if k in given:
            out[k] = f"Given as --{k.replace('_', '-')} ({how})."
        elif preset and k in preset.inputs and same(answers[k], preset.inputs[k]):
            out[k] = preset.notes[k]
        else:
            out[k] = f"Answered in the wizard ({how})."
    return out


def save(out: Path, body: Mapping[str, Any], load_profile: Mapping[str, Any], saved: presets.Preset) -> list[tuple[str, str]]:
    """Write the sizing folder; each file is written whole, then moved, so a reader never sees half of one."""
    out.mkdir(parents=True, exist_ok=True)
    names = [f for f, _ in FILES]
    texts = {
        "plan.json": json.dumps(body, indent=2), "values.yaml": values_mod.to_yaml(body["values"]).rstrip("\n"),
        "stores.json": json.dumps(deploy.stores_json(body), indent=2), "load-profile.json": json.dumps(load_profile, indent=2),
        "summary.md": summary.markdown(out.name, body, saved.why, names).rstrip("\n"),
    }
    presets.save(out / f"{INPUTS_FILE}.tmp", saved)
    (out / f"{INPUTS_FILE}.tmp").replace(out / INPUTS_FILE)
    for name, text in texts.items():
        (out / f"{name}.tmp").write_text(text + "\n")
        (out / f"{name}.tmp").replace(out / name)
    return [(str(out / f), what) for f, what in FILES]


def size_and_save(out: Path, preset: presets.Preset | None, answers: Mapping[str, Any], given: Mapping[str, Any], chart_version: str, how: str) -> dict[str, Any]:
    """Size the answers on the chart, save the folder, draw the plan. The plan's body is returned."""
    chart, loaded, cited = chart_mod.Chart(chart_version), params.load(), citations.load()
    merged: dict[str, Any] = {k: tuple(v) if isinstance(v, list) else v for k, v in (preset.inputs if preset else {}).items()}
    if {"traces_per_second", "traces_per_month"} & set(answers):
        merged.pop("traces_per_second", None)
        merged.pop("traces_per_month", None)
    merged |= dict(answers)
    inp = inputs.Inputs(chart_version, **merged)
    body = plan.size(inp, chart, loaded, cited)
    why = preset.why if preset and preset.saved else f"Sized from preset {preset.name}: {preset.why}" if preset else "Sized from answers given in the wizard."
    saved = presets.Preset(out.name, why, merged, notes_for(merged, preset, given, how), chart_version)
    written = save(out, body, profile.load_profile(inp, chart, loaded, cited), saved)
    ui.show(summary.sections(body), f"{out.name} on chart {chart_version}")
    ui.files(written)
    next_steps(out, body)
    return body


def next_steps(out: Path, body: Mapping[str, Any]) -> None:
    fills = sum(line.startswith("# fill:") for line in values_mod.to_yaml(body["values"]).splitlines())
    tested = (out / "results.json").exists()
    ui.steps([
        (f"make show NAME={out.name}", "these tables again"),
        (f"{out}/values.yaml", f"fill its {fills} # fill: lines (secret names, hosts), then helm upgrade --install -f it"),
        (f"{out}/stores.json", "provision each external store to its spec before the install"),
        (f"make load NAME={out.name}", "once it runs: send the planned load (needs ../langsmith-load-test/.env)" + (", again" if tested else "")),
        (f"make compare NAME={out.name}", "the load test's results against this plan"),
    ])


def run(
    *, chart_version: str | None, preset_name: str | None, given: Mapping[str, Any], yes: bool, out: Path,
    ask: Callable[[str], str],
) -> int:
    """Ask what is not given, size, show the plan, save the folder."""
    saved_file = out / INPUTS_FILE
    preset = presets.load(preset_name) if preset_name else presets.load(str(saved_file)) if saved_file.is_file() else None
    chart_version = chart_mod.resolve(chart_version) if chart_version else preset.chart if preset and preset.chart else chart_mod.resolve(None)
    if yes and preset is None and "users" not in given:
        raise ValueError(f"nothing to size: give PRESET= or USERS= with a rate, or size {out.name} once with make wizard NAME={out.name}")
    ui.banner(f"LangSmith sizing: {out.name}", f"chart {chart_version}, saving to {out}/" + ("" if yes else "\nEnter keeps the default shown. Ctrl-C stops; nothing is written until you confirm."))
    if preset and preset.saved:
        ui.note(f"Sizing {out.name} again from its saved answers ({saved_file})" + ("." if yes else "; each default below is what was saved."))
    if preset is None and not yes and not ({"users"} & set(given)):
        preset = _pick_preset(ask)
    chart, loaded = chart_mod.Chart(chart_version), params.load()
    answers: dict[str, Any] = dict(given)
    section = ""
    for q in QUESTIONS:
        if yes or q.name in given or (q.name == "traces_per_second" and "traces_per_month" in given) or not _applies(q, {**(preset.inputs if preset else {}), **answers}):
            continue
        if q.section != section:
            section = q.section
            ui.heading(section)
        reply = _ask(q, defaults(answers, preset, chart, loaded).get(q.name), ask)
        if isinstance(reply, tuple) and reply[0] == "month":
            answers["traces_per_month"] = reply[1]
        elif reply is not None:
            answers[q.name] = reply
    if preset is None and "users" not in answers:
        raise ValueError("give PRESET, USERS, or a NAME with a saved inputs.yaml")
    if not yes:
        ui.heading("Your answers")
        ui.facts([(k, show_value(v)) for k, v in ({**(preset.inputs if preset else {}), **answers}).items()])
        if not _confirm(ask):
            ui.note("Nothing written.")
            return 1
    size_and_save(out, preset, answers, given, chart_version, f"{'wizard' if not yes else 'make plan'}, {dt.date.today().isoformat()}")
    return 0
