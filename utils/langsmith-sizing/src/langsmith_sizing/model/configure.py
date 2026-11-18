"""What to configure beyond replicas: environment, optional services, Redis and the Go pods.

Chart keys are given exactly, and only where they differ from the chart's default. What the chart
cannot set (queue priorities and partitions, per-operation memory limits) is stated as what is
needed, with no environment names made up.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

# The chart has no setting for a per-operation memory limit at 0.17.35, 0.17.56, 0.18.0-rc.57 or 0.18.0-rc.79 (searched
# its values); no replica count saves one query larger than a pod's memory.
OPERATION_MEMORY = {
    "workloads": ["smithdb-query", "smithdb-stats-query"],
    "recommendation": "Cap the memory one query or stats operation may use, below the pod's memory limit, so the operation fails and the pod stays up.",
    "chart_ask": "a setting for the per-operation memory limit; until then set it through the component's extraEnv with the variable name from SmithDB's documentation",
}


def common_env(priorities: Mapping[str, Any], partition_env: list[str], partitions: int, redis_is_cluster: bool) -> list[dict[str, str]]:
    """Run priority over feedback always; partitions only on a Redis cluster, where asynq's one
    queue per shard would otherwise bind."""
    env = [{"name": k, "value": str(v)} for k, v in priorities.items()]
    if redis_is_cluster:
        env += [{"name": n, "value": str(partitions)} for n in partition_env]
    return env


def redis_policy(*, placement: str, policy: str, maxmemory_gi: float) -> dict[str, Any]:
    """noeviction: a refused write is retried by the SDK, an eviction loses the run silently."""
    if placement == "operator":
        return {
            "where": "operator", "policy": policy, "values": {},
            "instruction": f"set maxmemory-policy {policy} and maxmemory {maxmemory_gi:g} GiB in the operator's Redis resource, below each pod's memory limit",
        }
    if placement == "statefulset":
        return {
            "where": "in-cluster", "policy": policy,
            "values": {"redis.statefulSet.command": ["redis-server", "--maxmemory", f"{maxmemory_gi:g}gb", "--maxmemory-policy", policy]},
            "note": "set the Redis container's memory limit above maxmemory; no measurement sizes that margin",
        }
    return {
        "where": "external", "policy": policy, "values": {},
        "instruction": f"set maxmemory-policy {policy} and maxmemory {maxmemory_gi:g} GiB on the managed instance's parameter group",
    }


def splits(on: bool, topology: str, defaults: Mapping[str, Any], feedback_per_second: float, feedback_per_second_peak: float) -> dict[str, Any]:
    """The dedicated SmithDB services: on from the tier the model's splits parameter names, which
    stays the rule. Mutations by feedback rate has no measured threshold: the rate is reported and
    the feedback backlog is the watched signal."""
    unified = topology != "cluster"
    why = "the unified topology runs both in the one pod" if unified else None
    values = {} if unified else {k: on for k, d in defaults.items() if on != d}
    return {
        "stats-query": {"on": on, "why": why or "stats over large projects saturated and OOM-killed shared query pods"},
        "mutations": {
            "on": on, "why": why or "with it off, feedback writes ran on the query pods and failed with them",
            "feedback_per_second": feedback_per_second, "feedback_per_second_peak": feedback_per_second_peak,
            "threshold": "observe", "threshold_why": "no measurement ties a feedback rate to needing the dedicated service; watch the feedback backlog (feedback-backlog)",
        },
        "values": values,
    }


def go_limits(workloads: Mapping[str, Mapping[str, Any]], minimum: float) -> dict[str, Any]:
    """A Go pod's thread count follows its CPU limit with a minimum of two; below it the pod freezes
    for the rest of each window."""
    return {n: {"cpu_limit": workloads[n]["limits"]["cpu"], "minimum": minimum, "ok": workloads[n]["limits"]["cpu"] >= minimum} for n in ("platform-backend", "ingest-queue")}


def inputs_to_change(turns_on: Mapping[str, Any], topology: str, chart_has_topology: bool, one_pod_carries_peak: bool) -> dict[str, str]:
    """Inputs the regime would set differently from the ones this plan was sized with. The regime
    applies the layout itself where the chart allows; what is left is a chart that cannot run it."""
    if turns_on.get("smithdb_unified") and topology == "cluster" and not chart_has_topology and one_pod_carries_peak:
        return {"chart_version": "a chart with smithdb.topology (the 0.18 line), which runs SmithDB here as one unified pod"}
    return {}
