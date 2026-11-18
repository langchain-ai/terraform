"""Each data store sized for where it runs: external, the chart's StatefulSet, or an operator.

External is an instance spec to provision (vCPU, GiB, disk, and what a managed Redis or bucket
needs). A StatefulSet is the pod the chart runs, with the model's figure where the model sizes it
(Redis memory, ClickHouse and Postgres disk). An operator runs the same pod as several instances:
three where the install must survive a node's loss, one otherwise. A store the chart does not run
(the SmithDB metastore and an object store in the cluster) is sized from the docs' tier table and
from the lab's measured figures.
"""

from __future__ import annotations

import math
from collections.abc import Mapping, Sequence
from typing import Any

from langsmith_sizing.model.stores import GIB_TO_GB
from langsmith_sizing.units import GIB, KIB, TB

TB_TO_GIB = TB / GIB


def instances(placement: str, survives_node_loss: bool, counts: Mapping[str, int]) -> int:
    """One for a StatefulSet; an operator's primary and two replicas only where a node's loss must
    be survived."""
    if placement != "operator":
        return 1
    return counts["survives_node_loss"] if survives_node_loss else counts["otherwise"]


def limits_for(requests: Mapping[str, float], factor: float) -> dict[str, float]:
    return {k: v * factor for k, v in requests.items()}


def at_least(limits: Mapping[str, float], requests: Mapping[str, float]) -> dict[str, float]:
    """A limit below its request is refused by Kubernetes: raise it to the request."""
    return {k: max(limits[k], requests[k]) for k in requests}


def pod(requests: Mapping[str, float], limits: Mapping[str, float], volume_gib: float) -> dict[str, Any]:
    return {"requests": dict(requests), "limits": dict(limits), "volume_gib": volume_gib}


def in_cluster(placement: str, per_instance: Mapping[str, Any], count: int, extra: Sequence[Mapping[str, Any]] = ()) -> dict[str, Any]:
    """A store the cluster runs: its pod, how many, and any pods that run beside them."""
    return {"placement": placement, "instances": count, "per_instance": dict(per_instance), "extra": [dict(e) for e in extra]}


def external(spec: Mapping[str, Any]) -> dict[str, Any]:
    return {"placement": "external", "instance": dict(spec)}


# Postgres

def postgres_instance(docs: Mapping[str, float], memory_gib: float | None, max_connections: float, budget: int) -> dict[str, Any]:
    """The scale guide's Postgres (2 CPU, 8 GB memory, 10 GB storage; the guide prints GB and every
    pod request is GiB, so it is read as GiB), or the instance the person has, with disk that grows."""
    return {
        "vcpu": docs["cpu"], "memory_gib": memory_gib if memory_gib is not None else docs["memory_gb"], "disk_gib": docs["storage_gb"],
        "disk_autoexpand": True, "max_connections": max_connections, "connection_budget": budget,
    }


def postgres_pod(chart_requests: Mapping[str, float], chart_limits: Mapping[str, float], docs: Mapping[str, float]) -> dict[str, Any]:
    """The chart's StatefulSet, its volume the guide's disk and not the chart's smaller default."""
    return pod(chart_requests, chart_limits, docs["storage_gb"])


# Redis

def redis_shards(cluster: bool, cpu_shards: int, memory_gi: float, single_node_max_gb: float) -> int:
    """One node, or a cluster of as many shards as the busiest limit asks: Redis runs one thread, so
    CPU asks for cpu_shards, and no shard holds more than one managed node does."""
    return max(cpu_shards, math.ceil(memory_gi * GIB_TO_GB / single_node_max_gb)) if cluster else 1


def redis_instance(vcpu: float, memory_gi: float, shards: int, partitions: int, policy: str) -> dict[str, Any]:
    per_shard = math.ceil(memory_gi / shards)
    return {
        "vcpu_per_shard": vcpu, "memory_gib_per_shard": per_shard, "shards": shards, "cluster": shards > 1, "queue_partitions": partitions,
        "maxmemory_policy": policy, "maxmemory_gib_per_shard": per_shard, "memory_gib": memory_gi,
    }


def redis_pod(chart_requests: Mapping[str, float], chart_limits: Mapping[str, float], chart_volume_gib: float, memory_gi: float, maxmemory_share: float) -> dict[str, Any]:
    """The chart's StatefulSet with the model's memory as the request and a limit above maxmemory.
    The volume is never below the dataset: a snapshot or an append-only rewrite of a full Redis fills
    a smaller one, and a full disk stops writes."""
    requests = {"cpu": chart_requests["cpu"], "memory_gib": memory_gi}
    whole_mib = math.ceil(memory_gi / maxmemory_share * KIB) / KIB
    limits = at_least({"cpu": chart_limits["cpu"], "memory_gib": whole_mib}, requests)
    return pod(requests, limits, max(chart_volume_gib, math.ceil(memory_gi)))


def redis_sentinels(sentinel: Mapping[str, float]) -> dict[str, Any]:
    r = {"cpu": sentinel["cpu"], "memory_gib": sentinel["memory_gib"]}
    return {"name": "redis-sentinel", "instances": int(sentinel["replicas"]), "per_instance": pod(r, r, 0)}


# SmithDB metastore and object store

def metastore_instance(tier: Mapping[str, float], disk_gib: float) -> dict[str, Any]:
    return {"vcpu": tier["cpu"], "memory_gib": tier["memory_gib"], "disk_gib": disk_gib, "disk_autoexpand": True}


def metastore_pod(tier: Mapping[str, float], disk_gib: float, limit_factor: float) -> dict[str, Any]:
    requests = {"cpu": tier["cpu"], "memory_gib": tier["memory_gib"]}
    return pod(requests, limits_for(requests, limit_factor), disk_gib)


def bucket_instance(storage: Mapping[str, Any], blob: bool, base_days: float, extended_days: float, extended_share: float) -> dict[str, Any]:
    """The buckets to create. SmithDB deletes its own objects (`steady_state_days` after write); the
    LangSmith bucket needs lifecycle rules on the two prefixes the chart writes, ttl_s/ at the base
    retention and, where any run is upgraded, ttl_l/ at the extended one."""
    sdb = storage["smithdb"]
    out: dict[str, Any] = {"smithdb": {"tb": sdb["tb"], "retention_days": sdb["steady_state_days"], "lifecycle_rules": []}, "langsmith": None}
    if blob and storage["langsmith"]:
        rules = [{"prefix": "ttl_s/", "expire_days": base_days}]
        if extended_share > 0:
            rules.append({"prefix": "ttl_l/", "expire_days": extended_days})
        out["langsmith"] = {"tb": storage["langsmith"]["tb"], "lifecycle_rules": rules}
    return out


def object_store_pod(pod_by_tier: Mapping[str, Any], storage_tb: float) -> dict[str, Any]:
    """An S3-compatible store in the cluster: the lab's pod for the tier, its volume the bytes the
    buckets hold."""
    return pod(pod_by_tier["requests"], pod_by_tier["limits"], math.ceil(storage_tb * TB_TO_GIB))


# ClickHouse, deprecated: only while dual

def clickhouse_instance(nodes: int, requests: Mapping[str, float], storage_gi: float) -> dict[str, Any]:
    return {"nodes": nodes, "vcpu": requests["cpu"], "memory_gib": requests["memory_gib"], "disk_gib": storage_gi}


def clickhouse_pod(requests: Mapping[str, float], chart_limits: Mapping[str, float], storage_gi: float) -> dict[str, Any]:
    """The guide's requests with the chart's limits, raised where the guide asks for more than the
    chart allows."""
    return pod(requests, at_least(chart_limits, requests), storage_gi)
