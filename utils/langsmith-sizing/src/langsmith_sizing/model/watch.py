"""What to watch on a healthy install, and what the plan already knows is wrong.

A watch item names the metric, where to read it and what to do; it carries a number only where a
parameter, the chart or the plan gives one. An item with no such number is "observe": no
measurement backs an alarm level, and inventing one would be worse than saying so.
"""

from __future__ import annotations

from collections.abc import Callable, Iterable, Mapping, Sequence
from typing import Any

from langsmith_sizing.model.stores import redis_needs_cluster

OBSERVE = "observe"


def _threshold(spec: Mapping[str, Any] | None, resolve: Callable[[str], Any]) -> Any:
    if spec is None:
        return OBSERVE
    if "from" in spec:
        value = resolve(spec["from"])
        return OBSERVE if value is None else {"value": value, "unit": spec["unit"], "from": spec["from"]}
    return {"value": spec["value"], "unit": spec["unit"], "from": "param:watch.items"}


def items(
    table: Sequence[Mapping[str, Any]], metrics: Iterable[str], *, resolve: Callable[[str], Any], topology: str, scale: Mapping[str, Mapping[str, Any]],
) -> list[dict[str, Any]]:
    """The watch list for this plan: items for another topology are dropped, the per-autoscaler item
    is expanded to one per deployed autoscaler at its ceiling."""
    known = set(metrics)
    out: list[dict[str, Any]] = []
    for it in table:
        if it["metric"] not in known:
            raise ValueError(f"watch item {it['id']}: metric {it['metric']} is in neither watch.metrics list")
        if it.get("topology", topology) != topology:
            continue
        base = {k: it[k] for k in ("id", "workload", "metric", "where", "meaning", "action")}
        spec = it["threshold"]
        if spec and spec.get("per") == "autoscaled":
            out += [
                base | {"id": f"{it['id']}:{name}", "workload": name, "threshold": {"value": s["applied"]["max"], "unit": spec["unit"], "from": f"scale.{name}.applied.max"}}
                for name, s in scale.items() if s["deployed"] and s["applied"]["kind"] != "none"
            ]
            continue
        entry = base | {"threshold": _threshold(spec, resolve)}
        if it.get("needs"):
            entry["needs"] = it["needs"]
        if it.get("while"):
            entry["while"] = _threshold(it["while"], resolve)
        out.append(entry)
    return out


def _warn(wid: str, severity: str, message: str, **figures: Any) -> dict[str, Any]:
    return {"id": wid, "severity": severity, "message": message, "figures": figures}


def plan_warnings(*, rates: Mapping[str, Any], smithdb: Mapping[str, Any], stores: Mapping[str, Any], scale: Mapping[str, Mapping[str, Any]], p: Mapping[str, Any]) -> list[dict[str, Any]]:
    """What the plan can already say is wrong or unproven, from figures it computed."""
    out: list[dict[str, Any]] = []
    pg, redis = stores["postgres"], stores["redis"]
    if pg["connections"] > pg["budget"]:
        out.append(_warn("postgres-connections", "action", f"the pods open {pg['connections']:g} Postgres connections against a budget of {pg['budget']:g} ({pg['max_connections']:g} max_connections): size Postgres for them or lower the pools", connections=pg["connections"], budget=pg["budget"], max_connections=pg["max_connections"]))
    if redis_needs_cluster(redis["memory_gi"], redis["cpu_shards"], p["redis.single_node_max_gb"]):
        where = "the chart's in-cluster Redis is one node" if redis["in_cluster"] else "a single managed node"
        out.append(_warn("redis-needs-cluster", "action", f"Redis needs {redis['cpu_shards']} shards and {redis['memory_gi']:g} GiB, past one node ({p['redis.single_node_max_gb']:g} GB at most); {where}: use a Redis cluster with queue partitions", shards=redis["cpu_shards"], memory_gi=redis["memory_gi"], single_node_max_gb=p["redis.single_node_max_gb"]))
    if redis["over_shard_cap"]:
        out.append(_warn("redis-over-shard-cap", "action", f"{redis['cpu_shards']} Redis shards pass the managed cap of {p['redis.cluster_shard_cap']:g}: the queue needs partitions and a measured load test", shards=redis["cpu_shards"], cap=p["redis.cluster_shard_cap"]))
    if rates["beyond_published"]:
        out.append(_warn("beyond-published", "action", "the load is past the scale guide's highest published configuration; every figure past it is extrapolated"))
    if rates["beyond_tested"]:
        out.append(_warn("beyond-tested", "action", f"the peak of {rates['peak_traces_per_second']:g} traces/s is past the {p['payload.tested_traces_per_second']:g} traces/s the payload coefficients were measured at", peak_traces_per_second=rates["peak_traces_per_second"], tested=p["payload.tested_traces_per_second"]))
    if smithdb["auto"]["write"]["beyond_tiers"]:
        out.append(_warn("beyond-tiers", "action", f"the peak of {smithdb['auto']['write']['peak_runs_per_second']:g} runs/s is past SmithDB's largest band: queue, Redis CPU and Postgres connections bind, and the object store's request rate becomes a limit", peak_runs_per_second=smithdb["auto"]["write"]["peak_runs_per_second"]))
    high = {n: s["applied"]["max"] for n, s in scale.items() if s["deployed"] and s["above_chart_default"]}
    if high:
        out.append(_warn("ceilings-above-chart-default", "info", "autoscaler ceilings above the chart's default: " + ", ".join(f"{n} {m}" for n, m in high.items()), ceilings=high))
    out += [
        _warn(f"chart-ask:{n}", "info", f"{n}: the chart cannot express the recommended trigger ({s['gap']['ask']}); applied instead: {s['gap']['applied_instead']['kind']} on {', '.join(s['gap']['applied_instead']['signals']) or 'nothing'}")
        for n, s in scale.items() if s["deployed"] and s["gap"]
    ]
    return out
