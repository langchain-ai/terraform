"""SmithDB: the tier a load needs, the pods it runs and the metastore under it.

Per-replica CPU, memory and cache come from the chart's tier helper (never copied here); starting
replica counts come from the SmithDB scale guide. This module picks the tier and the counts.
Reads raise the tier (a bigger query pod), never the replica count: each query pod holds its own
cache, so scaling out dilutes it.
First ported from the PS sizing calculator (README, Lineage), by Dzmitry Dubarau; the tier sizes
were first read from the chart by Dariel Dato-on.
"""

from __future__ import annotations

import math
from collections.abc import Mapping, Sequence
from typing import Any


def query_rps(users: float, rps_per_user: float) -> float:
    """Concurrent frontend users -> query requests a second."""
    return users * rps_per_user


def auto_tier(
    peak_runs_per_second: float, users: float, *, tiers: Sequence[str], peak_bands: Mapping[str, float],
    tested_query_qps: Mapping[str, float], rps_per_user: float,
) -> dict[str, Any]:
    """The larger of the tier the peak write rate needs and the first tier whose tested query rate
    covers the reads. Peak, not average: an average rate kept a 1,500 runs/s install on medium."""
    rps = query_rps(users, rps_per_user)
    last = tiers[-1]
    write = next((t for t in tiers if peak_runs_per_second < peak_bands[t]), last)
    read = next((t for t in tiers if rps <= tested_query_qps[t]), last)
    tier = write if tiers.index(write) >= tiers.index(read) else read
    return {
        "tier": tier,
        "by": "both" if write == read else "write" if tier == write else "read",
        "write": {"tier": write, "peak_runs_per_second": peak_runs_per_second, "beyond_tiers": peak_runs_per_second >= peak_bands[last]},
        "read": {"tier": read, "users": users, "query_rps": rps, "tested_qps": tested_query_qps[read], "beyond_largest": rps > tested_query_qps[last]},
    }


def query_replicas(tier: str, tier_start: int, *, tiers: Sequence[str], floor_from_second_tier: int) -> int:
    """The tier's starting count, at least floor_from_second_tier from the second tier up: two keep
    one pod serving through a rollout on nodes that cannot surge."""
    return tier_start if tier == tiers[0] else max(floor_from_second_tier, tier_start)


def splits_on(tier: str, tiers: Sequence[str], from_tier: str) -> bool:
    """Whether the dedicated stats-query and mutations services run: from `from_tier` up."""
    return tiers.index(tier) >= tiers.index(from_tier)


def components(
    tier: str, *, tiers: Sequence[str], pods: Mapping[str, Mapping[str, Any]], starts: Mapping[str, int], hpa_max: Mapping[str, float],
    query_floor: int, split_replicas: Mapping[str, int], splits_from: str,
) -> dict[str, dict[str, Any]]:
    """Each SmithDB component at its starting count: replicas, at-rest floor, autoscaler ceiling
    (reported, never reserved), and the chart's requests, limits and cache for one replica. The
    split services start at their own counts and are sized like the query pod, as the chart does."""
    out: dict[str, dict[str, Any]] = {}
    for name, n in starts.items():
        start = query_replicas(tier, n, tiers=tiers, floor_from_second_tier=query_floor) if name == "query" else n
        out[name] = component(pods[name], start, hpa_max.get(name))
    if splits_on(tier, tiers, splits_from):
        for name, n in split_replicas.items():
            out[name] = component(pods[name], n, hpa_max.get(name))
    return out


def component(pod: Mapping[str, Any], start: int, ceiling: float | None) -> dict[str, Any]:
    return {
        "replicas": start, "min": start, "max": max(start, ceiling) if ceiling is not None else start,
        "requests": pod["requests"], "limits": pod["limits"], "cache_gib": pod["cache_gib"],
    }


def ingest_cores(components_: Mapping[str, Mapping[str, Any]]) -> float:
    """Starting ingestion cores: pod CPU x starting replicas. Reported, not used to pick the tier."""
    c = components_["ingestion"]
    return float(c["requests"]["cpu"] * c["replicas"])



def backfill(runs: float, days: float, *, runs_per_vcpu_day: float, pod: Mapping[str, Any], min_memory_gib: float) -> dict[str, Any]:
    """The migration Job that copies `runs` of ClickHouse history into SmithDB in `days`.

    The docs' estimate gives total vCPUs; the pods follow from the chart's per-pod CPU, and a pod's
    memory never falls below the docs' floor, which does not scale with CPU (Hari Narayan's SmithDB
    guide). The tier does not size a backfill: it runs beside the serving pods until it completes.
    """
    vcpus = runs / runs_per_vcpu_day / days
    memory = max(pod["memory_gib"], min_memory_gib)
    parallelism = max(1, math.ceil(vcpus / pod["cpu"]))
    return {
        "runs": runs, "days": days, "vcpus": vcpus, "parallelism": parallelism,
        "pod": {"cpu": pod["cpu"], "memory_gib": memory},
        "requests_total": {"cpu": parallelism * pod["cpu"], "memory_gib": parallelism * memory},
    }


def low_regime_layout(
    auto: Mapping[str, Any], *, tier: str, tested_query_qps: float, peak_runs_per_second: float, pod_runs_per_second: float,
    unified_allowed: bool,
) -> dict[str, Any]:
    """The layout a low regime runs on its tier: ingestion and query scaled out to the load, at the
    measured runs a pod and the docs' tested query rate a pod, or one unified pod where the chart has
    the layout and one pod carries both. The model's bands once put a 15 traces/s install, and a
    10-user one, on the medium tier: two 28 vCPU query pods where two small pods carry the load. At
    these volumes the data fits one query pod's cache, so scaling query out does not dilute it."""
    ingestion = max(1, math.ceil(peak_runs_per_second / pod_runs_per_second))
    query = max(1, math.ceil(auto["read"]["query_rps"] / tested_query_qps))
    return {"tier": tier, "unified": unified_allowed and ingestion == 1 and query == 1, "ingestion_replicas": ingestion, "query_replicas": query}
