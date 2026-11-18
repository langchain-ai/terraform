"""Namespace totals and node pools: what the plan's pods add up to and how many nodes carry them.

A pod entry is {name, pool, requests, limits, volume_gib, replicas: {min, sized, max}}. The sums are
read at the autoscalers' floors (min), at the replicas the model sized (sized) and at their ceilings
(max). Nodes follow the calculator's rule: whichever of CPU or memory binds after the scheduling
overhead, never below the pool's floor; a pod fits a node only strictly below it, because the
kubelet and system pods take part of every node.
Ported from the PS sizing calculator (formulas.ts section 2, compute.ts), by Dzmitry Dubarau.
"""

from __future__ import annotations

import math
from collections.abc import Mapping, Sequence
from typing import Any

PHASES = {"floor": "min", "sized": "sized", "ceiling": "max"}
"""Each sum's name, and the replica count of an entry that it reads."""


def _zero() -> dict[str, Any]:
    return {"requests": {"cpu": 0.0, "memory_gib": 0.0}, "limits": {"cpu": 0.0, "memory_gib": 0.0}, "volume_gib": 0.0}


def add(a: Mapping[str, Any], b: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "requests": {k: a["requests"][k] + b["requests"][k] for k in ("cpu", "memory_gib")},
        "limits": {k: a["limits"][k] + b["limits"][k] for k in ("cpu", "memory_gib")},
        "volume_gib": a["volume_gib"] + b["volume_gib"],
    }


def pod_sum(entries: Sequence[Mapping[str, Any]], which: str) -> dict[str, Any]:
    """The requests, limits and volumes of every replica of every entry, at one replica count."""
    total = _zero()
    for e in entries:
        n = e["replicas"][which]
        limits = e["limits"] or e["requests"]
        total = add(total, {
            "requests": {k: n * e["requests"][k] for k in ("cpu", "memory_gib")},
            "limits": {k: n * limits[k] for k in ("cpu", "memory_gib")},
            "volume_gib": n * (e["volume_gib"] or 0),
        })
    return total


def node_count(cpu: float, mem_gib: float, node: Mapping[str, float], floor: int, overhead: float) -> int:
    """max(ceil(cpu x overhead / node vCPU), ceil(mem x overhead / node GiB), floor); cpu and mem are
    requests before overhead. Plain ceil, as the calculator's Math.ceil."""
    return max(math.ceil(cpu * overhead / node["cpu"]), math.ceil(mem_gib * overhead / node["memory_gib"]), floor)


def fits(cpu: float, mem_gib: float, node: Mapping[str, float]) -> bool:
    return cpu < node["cpu"] and mem_gib < node["memory_gib"]


def largest(entries: Sequence[Mapping[str, Any]]) -> Mapping[str, Any] | None:
    """The pod with the biggest request, by CPU then memory; the first of equals."""
    big: Mapping[str, Any] | None = None
    for e in entries:
        r = e["requests"]
        if big is None or r["cpu"] > big["requests"]["cpu"] or (r["cpu"] == big["requests"]["cpu"] and r["memory_gib"] > big["requests"]["memory_gib"]):
            big = e
    return big


def clickhouse_node(cpu: float, mem_gib: float, shapes: Sequence[Mapping[str, float]]) -> Mapping[str, float]:
    """The first shape one ClickHouse pod fits, the largest when none does."""
    return next((s for s in shapes if fits(cpu, mem_gib, s)), shapes[-1])


def pool(entries: Sequence[Mapping[str, Any]], node: Mapping[str, float], floor: int, overhead: float, node_from: str) -> dict[str, Any]:
    """One pool: the calculator's figures (`cpu`, `mem_gib`, `nodes` at the sized replicas, `min_*` at
    the floors, all requests x overhead), the largest pod and whether it fits, and every sum."""
    sums = {name: pod_sum(entries, which) for name, which in PHASES.items()}
    nodes = {name: node_count(s["requests"]["cpu"], s["requests"]["memory_gib"], node, floor, overhead) for name, s in sums.items()}
    big = largest(entries)
    sized, low = sums["sized"]["requests"], sums["floor"]["requests"]
    return {
        "present": True, "node_cpu": node["cpu"], "node_mem_gib": node["memory_gib"], "node_floor": floor, "node_from": node_from,
        "cpu": sized["cpu"] * overhead, "mem_gib": sized["memory_gib"] * overhead, "nodes": nodes["sized"],
        "min_cpu": low["cpu"] * overhead, "min_mem_gib": low["memory_gib"] * overhead, "min_nodes": nodes["floor"],
        "largest_pod": big["name"] if big else None,
        "largest_pod_cpu": big["requests"]["cpu"] if big else None, "largest_pod_mem_gib": big["requests"]["memory_gib"] if big else None,
        "largest_pod_fits": fits(big["requests"]["cpu"], big["requests"]["memory_gib"], node) if big else None,
        "applied": {name: s | {"nodes": nodes[name]} for name, s in sums.items()},
        "pods": [e["name"] for e in entries],
    }


def totals(entries: Sequence[Mapping[str, Any]], dbs: Sequence[Mapping[str, Any]], overhead: float) -> dict[str, Any]:
    """The namespace: raw requests of the services and of the in-cluster databases, and both
    after overhead, at the sized replicas and at the floors."""
    svc, db = pod_sum(entries, "sized")["requests"], pod_sum(dbs, "sized")["requests"]
    svc_min, db_min = pod_sum(entries, "min")["requests"], pod_sum(dbs, "min")["requests"]
    return {
        "overhead": overhead,
        "svc_cpu": svc["cpu"], "svc_mem_gib": svc["memory_gib"], "db_cpu": db["cpu"], "db_mem_gib": db["memory_gib"],
        "cpu": (svc["cpu"] + db["cpu"]) * overhead, "mem_gib": (svc["memory_gib"] + db["memory_gib"]) * overhead,
        "min_svc_cpu": svc_min["cpu"], "min_svc_mem_gib": svc_min["memory_gib"],
        "min_cpu": (svc_min["cpu"] + db_min["cpu"]) * overhead, "min_mem_gib": (svc_min["memory_gib"] + db_min["memory_gib"]) * overhead,
    }


def hook_peak(jobs: Sequence[Mapping[str, Any]], base: Mapping[str, Any]) -> dict[str, Any]:
    """The namespace while the chart's hook Jobs run, on top of `base`. Helm runs hooks one at a
    time, in weight order, and waits for each Job to finish before the next, so the peak is the
    largest single Job's pods and not their sum."""
    biggest = max(jobs, key=lambda j: (j["requests"]["cpu"] * j["pods"], j["requests"]["memory_gib"] * j["pods"]), default=None)
    if biggest is None:
        return {"job": None, **base}
    extra = {
        "requests": {k: biggest["pods"] * biggest["requests"][k] for k in ("cpu", "memory_gib")},
        "limits": {k: biggest["pods"] * biggest["limits"][k] for k in ("cpu", "memory_gib")},
        "volume_gib": 0.0,
    }
    return {"job": biggest["name"], **add(base, extra)}
