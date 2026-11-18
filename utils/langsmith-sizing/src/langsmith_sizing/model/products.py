"""The products beside tracing: which run, what each adds to the cluster, and what it needs.

Every pod the chart renders for a product is read from a render with the product on, at the version
planned, so a chart that resizes one is followed without an edit here. Three things the chart cannot
say are sized here: the pods it ships with `resources: {}` (params products.pods sets their requests,
and the values apply them, so what runs is what was counted); each Agent Server deployment's pods,
which the operator creates at run time from the docs' table; and how many sandbox hosts the load
needs, by the docs' formula with the target and headroom the chart's autoscaler uses.
"""

from __future__ import annotations

import math
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

import yaml

from langsmith_sizing.chart import Chart, _pod_request, autoscalers, merge
from langsmith_sizing.units import PERCENT
from langsmith_sizing.values import resources

CATALOG = Path(__file__).resolve().parent.parent.parent.parent / "products.yaml"
TRACES = "traces"
UNSIZED = {"apiServer": "deployment", "queue": "deployment", "postgres": "statefulSet", "redis": "statefulSet"}
"""Within a product's values prefix, each pod the chart leaves unsized, and the block its resources sit in."""
LOADS = ("ll", "lh", "hl", "mm", "hh")
"""The docs' Agent Server table columns: read load then write load, low, medium or high."""


def catalog(path: Path = CATALOG) -> dict[str, dict[str, Any]]:
    doc = yaml.safe_load(path.read_text())
    out: dict[str, dict[str, Any]] = doc["products"]
    return out


def chosen(requested: Sequence[str], cat: Mapping[str, Mapping[str, Any]]) -> tuple[list[str], dict[str, str]]:
    """The products that run, in catalog order: those asked for and everything they require.
    Each one added is returned with the product that required it, so the plan can say why."""
    unknown = sorted(set(requested) - set(cat))
    if unknown:
        raise ValueError(f"products: no {', '.join(unknown)}; the products are {', '.join(cat)}")
    on, added = set(requested) | {TRACES}, {}
    queue = list(on)
    while queue:
        name = queue.pop()
        for need in cat[name]["requires"]:
            if need not in on:
                on.add(need)
                added[need] = name
                queue.append(need)
    return [n for n in cat if n in on], added


def _switch(enable: Any, on: bool) -> Any:
    """A product's enable values, or the same keys with every `enabled` false and nothing else."""
    if not isinstance(enable, dict):
        return enable
    out = {}
    for k, v in enable.items():
        if k == "enabled":
            out[k] = v if on else False
        elif isinstance(v, dict):
            sub = _switch(v, on)
            if on or sub:
                out[k] = sub
        elif on:
            out[k] = v
    return out


def _resources(cpu: float, mem: float, factor: float) -> dict[str, Any]:
    return resources({"cpu": cpu, "memory_gib": mem}, {"cpu": cpu * factor, "memory_gib": mem * factor})


def values(on: Sequence[str], cat: Mapping[str, Mapping[str, Any]], p: Mapping[str, Any], placeholder: Any) -> dict[str, Any]:
    """The values that run exactly the products chosen: each one switched on or off, the unsized
    pods given their requests, and a <placeholder> for each value only the person can give."""
    out: dict[str, Any] = {}
    for name, spec in cat.items():
        if spec.get("enable"):
            out = merge(out, _switch(spec["enable"], name in on))
    for name in on:
        spec = cat[name]
        prefix = spec.get("unsized")
        if prefix:
            sizes = p["products.pods"][prefix]
            block = {pod: {where: {"resources": _resources(sizes[pod]["cpu"], sizes[pod]["memory_gib"], p["products.limit_over_request"])}} for pod, where in UNSIZED.items()}
            out = merge(out, {prefix: block})
        for path in spec.get("fill", []):
            node = out
            *head, last = path.split(".")
            for part in head:
                node = node.setdefault(part, {})
            node[last] = placeholder(path.rsplit(".", 1)[-1])
    return out


def renderable(on: Sequence[str], cat: Mapping[str, Mapping[str, Any]]) -> dict[str, Any]:
    """Stand-ins for the placeholders, so `helm template` renders the products; never in values.yaml."""
    out: dict[str, Any] = {}
    for name in on:
        out = merge(out, cat[name].get("render") or {})
    return out


def rendered_pods(docs: list[dict[str, Any]], on: Sequence[str], cat: Mapping[str, Mapping[str, Any]]) -> dict[str, dict[str, Any]]:
    """Each Deployment and StatefulSet a chosen product renders, by workload name, with its pod's
    requests and limits (a limit left unset counts as the request) and its replicas: fixed, or the
    floor and ceiling of the autoscaler that owns it."""
    scalers = autoscalers(docs)
    out: dict[str, dict[str, Any]] = {}
    for d in docs:
        if d.get("kind") not in ("Deployment", "StatefulSet"):
            continue
        name = d["metadata"]["name"]
        owner = next((n for n in on if any(name.startswith(pre) for pre in cat[n].get("pods", []))), None)
        if owner is None or name in out:
            continue
        pod = d["spec"]["template"]["spec"]
        scaler = scalers.get(name)
        fixed = d["spec"].get("replicas", 1)
        lo, hi = (scaler["min"] or 1, scaler["max"]) if scaler else (fixed, fixed)
        out[name] = {"product": owner, "kind": d["kind"], "replicas": lo, "min": lo, "max": hi,
                     "requests": _pod_request(pod, "requests"), "limits": _pod_request(pod, "limits"),
                     "from": "params" if any(name.startswith(pre) for pre in cat[owner].get("unsized_pods", [])) else "chart"}
    return out


def agent_server(deployments: int, load: str, cited: Any) -> dict[str, Any]:
    """Each Agent Server deployment's pods by the docs' table at its load column, times the count.
    The operator creates these at run time, so no render shows them."""
    if load not in LOADS:
        raise ValueError(f"agent_load is one of {', '.join(LOADS)} (read then write: low, medium or high)")
    factor = cited["agent_server.limit_default"]["limit_over_request"]
    api, queue, pg, redis = (cited[f"agent_server.{k}"] for k in ("api_servers", "queue_workers", "postgres", "redis"))
    rows = {
        "api-server": (api["replicas"][load], api["cpu"], api["memory_gib"]),
        "queue": (queue["replicas"][load], queue["cpu"], queue["memory_gib"]),
        "postgres": (1, pg["cpu"][load], pg["memory_gib"][load]),
        "redis": (1, redis["cpu"], redis["memory_gib"]),
    }
    pods = {}
    for pod, (n, c, m) in rows.items():
        total = n * deployments
        pods[f"agent-deployment-{pod}"] = {"product": "agent_server", "kind": "per deployment", "replicas": total, "min": total, "max": total,
                                           "requests": {"cpu": c, "memory_gib": m}, "limits": {"cpu": c * factor, "memory_gib": m * factor}, "from": "docs"}
    spec = {pod: {"replicas": n, "cpu": c, "memory_gib": m} for pod, (n, c, m) in rows.items()}
    return {"deployments": deployments, "load": load, "n_jobs_per_worker": cited["agent_server.n_jobs_per_worker"][load], "each": spec, "pods": pods}


def sandbox_hosts(concurrent: float, vcpu_each: float, mem_each: float, node: Mapping[str, float], chart: Chart, cited: Any) -> dict[str, Any]:
    """Hosts for the sandboxes running at once: ceil(committed vCPU / (host vCPU x target)) plus
    headroom, the docs' formula, with the target and headroom the chart's autoscaler uses. The
    autoscaler counts CPU only, so memory is checked beside it: a host must hold its guests."""
    auto = chart.at("sandboxes.sandboxHost.autoscaling") or {}
    target = float(auto.get("targetUtilizationPercent", cited["sandboxes.target"]["pct"])) / PERCENT
    headroom = int(auto.get("headroomHosts", cited["sandboxes.headroom"]["hosts"]))
    vcpu, mem = concurrent * vcpu_each, concurrent * mem_each
    by_cpu = math.ceil(vcpu / (node["cpu"] * target)) + headroom
    by_mem = math.ceil(mem / (node["memory_gib"] * target)) + headroom
    floor = int(cited["sandboxes.min_hosts"]["hosts"])
    hosts = max(by_cpu, by_mem, floor)
    busy = max(hosts - headroom, 1)
    return {
        "concurrent": concurrent, "vcpu_each": vcpu_each, "memory_gib_each": mem_each, "committed_vcpu": vcpu, "guest_memory_gib": mem,
        "target": target, "headroom": headroom, "hosts": hosts, "min_hosts": floor, "by": "memory" if by_mem > by_cpu else "cpu",
        "guest_memory_gib_a_host": math.ceil(mem / busy), "cpu_autoscaler_short": by_mem > by_cpu,
    }
