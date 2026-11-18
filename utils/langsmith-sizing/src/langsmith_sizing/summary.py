"""A plan as a person reads it: a handful of tables, drawn once for the terminal and once as Markdown.

`sections()` is the one view of a plan; `ui.show_plan` draws it with rich and `markdown()` writes
it as summary.md beside the plan, so the screen and the file a customer is sent never disagree.
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from typing import Any

STORES = ("postgres", "redis", "smithdb_metastore", "object_storage", "clickhouse", "sandboxes_juicefs_redis")
STATES = ("floor", "sized", "ceiling")
DOCS = {
    "how it sizes": "docs/how-it-sizes.md",
    "autoscaling": "docs/autoscaling.md",
    "monitoring": "docs/monitoring.md",
    "every field": "docs/fields.md",
}


@dataclass(frozen=True)
class Table:
    title: str
    columns: tuple[str, ...]
    rows: Sequence[tuple[str, ...]]
    note: str = ""
    level: str = "info"
    """info, or warn when a row needs acting on before deploying."""


@dataclass(frozen=True)
class View:
    facts: list[tuple[str, str]]
    tables: list[Table] = field(default_factory=list)


def n(value: float) -> str:
    """A figure for a person: one decimal at most. The raw :g printed 981.906 GiB from a sum of binary fractions."""
    return f"{round(value, 1):g}"


def _shape(cpu: float, mem: float) -> str:
    return f"{n(cpu)} vCPU, {n(mem)} GiB"


def _facts(body: Mapping[str, Any]) -> list[tuple[str, str]]:
    r, s, i = body["rates"], body["smithdb"], body["inputs"]
    acting = [w["id"] for w in body["warnings"] if w["severity"] != "info"]
    alert = [("Act on first", ", ".join(acting) + " (Before you deploy, below)")] if acting else []
    pr = body["products"]
    extra = [pr["labels"][p] for p in pr["on"] if p != "traces"]
    return alert + [
        ("Chart", f"{body['chart']} (deploys LangSmith {body['app_version']})"),
        ("Products", "Tracing" + (", " + ", ".join(extra) if extra else " only")),
        ("Regime", f"{body['regime']['id']}: {body['regime']['why']}"),
        ("Load", f"{n(i['users'])} users, {n(r['traces_per_second'])} traces/s average, {n(r['peak_traces_per_second'])} at peak ({n(r['runs_per_second_peak'])} runs/s)"),
        ("Retention", f"{n(i['retention_days'])} days base, {n(i['extended_retention_days'])} extended"),
        ("SmithDB", f"{s['tier']} tier, {s['topology']} topology (chosen by {s['tier_by']})"),
        ("Survives a node loss", "yes" if i["survives_node_loss"] else "no"),
    ]


def _capacity(body: Mapping[str, Any]) -> Table:
    t = body["totals"]
    rows = []
    for state in STATES:
        a = t["applied"][state]
        rows.append((state, n(a["requests"]["cpu"]), n(a["requests"]["memory_gib"]), n(a["limits"]["cpu"]), n(a["limits"]["memory_gib"]), n(a["volume_gib"])))
    peak = t["hooks"]["peak"]
    sized = t["applied"]["sized"]["requests"]
    note = (
        f"Floor is every autoscaler at its minimum, ceiling at its maximum. Upgrades add hook Jobs one at a time "
        f"on top: at the ceiling with the largest ({peak['job']}) running, {_shape(peak['requests']['cpu'], peak['requests']['memory_gib'])}. "
        f"Sized with x{t['overhead']:g} node overhead: {_shape(sized['cpu'] * t['overhead'], sized['memory_gib'] * t['overhead'])}."
    )
    return Table("Namespace capacity", ("at", "vCPU requested", "GiB requested", "vCPU limit", "GiB limit", "volumes GiB"), rows, note)


def _pools(body: Mapping[str, Any]) -> Table:
    rows, warn = [], False
    for name, pool in body["pools"].items():
        if name == "single_node":
            rows.append(("single node", f"{pool['node_cpu']:g}x{pool['node_mem_gib']:g}", "1", "", "fits" if pool["fits"] else "does not fit"))
            warn = warn or not pool["fits"]
            continue
        a = pool["applied"]
        fits = pool["largest_pod_fits"]
        warn = warn or not fits
        rows.append((name, f"{pool['node_cpu']:g}x{pool['node_mem_gib']:g}", f"{a['floor']['nodes']} to {a['ceiling']['nodes']}", pool["largest_pod"], "fits" if fits else "DOES NOT FIT"))
    note = "Node shape is vCPU x GiB; set it with --app-node, --smithdb-node or --datastore-node (CPUxGIB) to count your own machines."
    return Table("Node pools", ("pool", "node", "nodes", "largest pod", "largest pod on a node"), rows, note, "warn" if warn else "info")


def _scaled(scale: Mapping[str, Any] | None) -> bool:
    """An autoscaler is applied; a regime that turns autoscalers off applies kind none."""
    return bool(scale and scale.get("applied") and scale["applied"]["kind"] != "none")


def _trigger(scale: Mapping[str, Any] | None) -> str:
    if not scale or not _scaled(scale):
        return "fixed"
    a = scale["applied"]
    return f"{a['kind']} on {', '.join(a['signals'])}"


def _workloads(body: Mapping[str, Any]) -> Table:
    rows = []
    pods = [(w, spec) for w, spec in body["workloads"].items()] + [(f"smithdb-{c}", spec) for c, spec in body["smithdb"]["components"].items()]
    for name, spec in pods:
        scale = body["scale"].get(name)
        lo, hi = (scale["applied"]["min"], scale["applied"]["max"]) if scale and _scaled(scale) else (spec["replicas"], spec["replicas"])
        req = spec["requests"]
        rows.append((name, str(spec["replicas"]), f"{lo} to {hi}", _shape(req["cpu"], req["memory_gib"]), _trigger(scale)))
    return Table("Workloads", ("workload", "replicas", "autoscaled", "requests a pod", "scales on"), rows, "Why each signal: docs/autoscaling.md.")


def _spec(spec: Mapping[str, Any]) -> str:
    if "per_instance" in spec:
        p = spec["per_instance"]
        text = f"{spec['instances']} x ({_shape(p['requests']['cpu'], p['requests']['memory_gib'])}, {n(p['volume_gib'])} GiB volume)"
        return text + "".join(f", plus {e['instances']} x {e['name']}" for e in spec.get("extra", []))
    inst = spec["instance"]
    if "smithdb" in inst:
        rules = ", ".join(f"{r['prefix']} {n(r['expire_days'])} d" for r in inst["langsmith"]["lifecycle_rules"])
        return f"SmithDB {n(inst['smithdb']['tb'])} TB, LangSmith {n(inst['langsmith']['tb'])} TB (expire {rules})"
    if "dedicated" in inst:
        return f"{_shape(inst['vcpu'], inst['memory_gib'])}, {inst['maxmemory_policy']}, its own: never shared"
    if "shards" in inst:
        return f"{inst['shards']} x {n(inst['memory_gib_per_shard'])} GiB, {inst['vcpu_per_shard']:g} vCPU a shard, {inst['maxmemory_policy']}"
    text = f"{_shape(inst['vcpu'], inst['memory_gib'])}, {n(inst['disk_gib'])} GiB disk"
    return text + (f", max_connections {inst['max_connections']} for the pods' pools" if "max_connections" in inst else "")


def _stores(body: Mapping[str, Any]) -> Table:
    rows = []
    for key in STORES:
        store = body["stores"].get(key)
        if store and store.get("spec"):
            rows.append((key.replace("_", " "), store["spec"]["placement"], _spec(store["spec"])))
    return Table("Data stores", ("store", "runs", "provision"), rows, "external: your managed service or your own; statefulset: the chart's; operator: a Kubernetes operator's. Full spec: stores.json.")


def _threshold(item: Mapping[str, Any]) -> str:
    t = item["threshold"]
    return t if isinstance(t, str) else f"{n(t['value'])} {t['unit']}"


CEILING = "autoscaler-at-ceiling:"
CHART_ASK = "chart-ask:"


def _watch(body: Mapping[str, Any]) -> Table:
    """One row an item; the autoscalers' at-ceiling items are one row, since each reads the same metric."""
    items = [w for w in body["watch"] if not w["id"].startswith(CEILING)]
    ceilings = [w for w in body["watch"] if w["id"].startswith(CEILING)]
    rows = [(w["id"], w["metric"], _threshold(w)) for w in items]
    if ceilings:
        rows.append((f"autoscaler at its ceiling ({len(ceilings)} workloads)", ceilings[0]["metric"], "its max replicas, sustained"))
    needs = [f"{w['id']} needs {w['needs']}." for w in items if w.get("needs")]
    return Table("What to watch", ("item", "metric", "alarm at"), rows, " ".join(["Where each is read and what to do: plan.json watch[], docs/monitoring.md.", *needs]))


def _warnings(body: Mapping[str, Any]) -> Table | None:
    """Warnings to act on, one row each; the chart asks are one row, since each is already applied as the nearest trigger."""
    acting = [w for w in body["warnings"] if not w["id"].startswith(CHART_ASK)]
    asks = [w["id"].removeprefix(CHART_ASK) for w in body["warnings"] if w["id"].startswith(CHART_ASK)]
    rows = [(w["severity"], w["id"], w["message"]) for w in acting]
    if asks:
        rows.append(("info", "chart asks", f"{', '.join(asks)} scale on the nearest trigger the chart has; the better one is a chart change (docs/autoscaling.md), nothing to do here"))
    if not rows:
        return None
    return Table("Before you deploy", ("level", "id", "what"), rows, "", "warn" if any(w["severity"] != "info" for w in acting) else "info")


FROM = {"chart": "the chart", "docs": "the docs' table", "params": "params.yaml (chart has none)"}


def _products(body: Mapping[str, Any]) -> list[Table]:
    """The products beside tracing: their pods, then what each needs of the cluster."""
    pr = body["products"]
    if pr["on"] == ["traces"]:
        return []
    labels = pr["labels"]
    rows = []
    for name, x in pr["pods"].items():
        span = str(x["replicas"]) if x["min"] == x["max"] else f"{x['min']} to {x['max']}"
        rows.append((labels[x["product"]], name, span, _shape(x["requests"]["cpu"], x["requests"]["memory_gib"]), FROM[x["from"]]))
    notes = []
    if pr["added"]:
        notes.append("Added because another needs it: " + ", ".join(f"{labels[a]} (for {labels[b]})" for a, b in pr["added"].items()) + ".")
    if "agent_server" in pr:
        a = pr["agent_server"]
        each = ", ".join(f"{k} {v['replicas']} x {_shape(v['cpu'], v['memory_gib'])}" for k, v in a["each"].items())
        notes.append(f"Agent Server: {a['deployments']} deployments at the docs' {a['load']} column; the operator creates their pods, so give each one this resource_spec: {each}, N_JOBS_PER_WORKER {a['n_jobs_per_worker']}.")
    if "sandboxes" in pr:
        s = pr["sandboxes"]
        notes.append(f"Sandboxes: {n(s['concurrent'])} at once x ({n(s['vcpu_each'])} vCPU, {n(s['memory_gib_each'])} GiB) = {n(s['committed_vcpu'])} vCPU, {n(s['guest_memory_gib'])} GiB; {s['hosts']} hosts on {n(s['node']['cpu'])}x{n(s['node']['memory_gib'])} KVM nodes, set by {s['by']}"
                     + (" (the chart's autoscaler counts CPU only and would stop short of it)" if s["cpu_autoscaler_short"] else "") + ".")
    if "gateway" in pr:
        g = pr["gateway"]
        notes.append(f"LLM gateway: {n(g['streams'])} streams need {g['replicas_needed']} replicas at the docs' streams a replica; its autoscaler's ceiling is set to at least that.")
    out = [Table("Products", ("product", "workload", "replicas", "requests a pod", "sized from"), rows, " ".join(notes))]
    need_rows = [(labels[p], x["what"]) for p, needs in pr["needs"].items() for x in needs]
    if need_rows:
        out.append(Table("What the products need", ("product", "the cluster must have"), need_rows, "Each is cited from the public docs (plan.json products.needs names the citation in citations.yaml)."))
    return out


def sections(body: Mapping[str, Any]) -> View:
    tables = [_capacity(body), _pools(body), _workloads(body), *_products(body), _stores(body)]
    if (w := _warnings(body)) is not None:
        tables.append(w)
    tables.append(_watch(body))
    return View(_facts(body), tables)


def _md_row(cells: tuple[str, ...]) -> str:
    return "| " + " | ".join(c.replace("|", "\\|") for c in cells) + " |"


def markdown(name: str, body: Mapping[str, Any], why: str, files: list[str]) -> str:
    """summary.md: the same tables as the screen, for a person who never runs the tool."""
    view = sections(body)
    out = [f"# {name}: LangSmith sizing", "", why, "", f"{body['regime']['about']}", ""]
    out += ["| | |", "|:--|:--|"] + [_md_row((k, v)) for k, v in view.facts] + [""]
    for t in view.tables:
        out += [f"## {t.title}", "", _md_row(t.columns), "|" + "|".join(":--" for _ in t.columns) + "|"]
        out += [_md_row(r) for r in t.rows] + [""]
        if t.note:
            out += [t.note, ""]
    out += ["## Files", ""] + [f"- `{f}`" for f in files] + [""]
    out += ["Made with `langsmith-sizing` from the LangSmith Helm chart, the public docs and the model's parameters. "
            "How each number is derived: " + ", ".join(f"[{k}](https://github.com/langchain-ai/terraform/blob/main/utils/langsmith-sizing/{v})" for k, v in DOCS.items()) + "."]
    return "\n".join(out) + "\n"
