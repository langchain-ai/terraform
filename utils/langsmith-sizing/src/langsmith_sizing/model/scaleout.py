"""Past the docs' largest tier: each component scaled with the run rate at what a load test measured.

The docs' tiers stop at large, and the scale guide at 1,000 traces a second, so a plan past them had
kept SmithDB at the large tier's counts while ingest and Redis grew: at 200,000 runs/s it counted 2
ingestion pods where the test ran 44. Here every figure is a rate the test held (params
scale_out.measured): requested vCPU a 1,000 runs/s for ingest workers and the API, runs/s a pod for
SmithDB ingestion and a worker for compaction, connections a pod
for Postgres, and runs/s a frontend pod proxies.
"""

from __future__ import annotations

import math
from collections.abc import Mapping
from typing import Any

from langsmith_sizing.model.services import ingest_runs_per_core
from langsmith_sizing.units import KILO


def _adjust(entry: dict[str, Any], replicas: int, low: int, high: int) -> dict[str, Any]:
    return entry | {"replicas": replicas, "min": low, "max": max(high, replicas)}


def ingest_cores(runs_per_second: float, runs_per_core_at_mix: float, m: Mapping[str, Any], curve: Any) -> float:
    """Requested ingest vCPU: the test's rate at its run size, moved to this mix by the ingest curve's
    ratio (a larger run holds a worker longer at the same proportion the curve says)."""
    at_reference = ingest_runs_per_core(m["ingest_reference_kib"], curve)
    return float(runs_per_second / KILO * m["ingest_cores_per_1k_runs"] * at_reference / runs_per_core_at_mix)


def api_cores(runs_per_second: float, inline_share: float, m: Mapping[str, Any]) -> float:
    """Requested API vCPU: between the offloaded and the in-Redis rate by the share of runs kept inline."""
    rate = m["api_cores_per_1k_runs"]
    return float(runs_per_second / KILO * (rate["offloaded"] + (rate["inline"] - rate["offloaded"]) * inline_share))


def apply(
    *, peak: float, avg: float, workloads: dict[str, Any], components: dict[str, Any], ingest: Mapping[str, Any],
    inline_share: float, m: Mapping[str, Any], curve: Any, keda_factor: float, floor: int,
) -> dict[str, Any]:
    """Rescale the workloads and SmithDB components in place; return the figures it used."""
    pod, limit = m["ingest_pod"], m["ingest_pod_limit"]
    # The larger of the load test's rate and the field curve the tiers use. The two disagree about 4x
    # (21 vCPU a 1,000 runs/s at 128 KB against the curve's 12.6 to 55 runs/s a core), and the test's
    # alone cut ingest from 358 to 98 vCPU as the peak crossed 10,000 runs/s, a smaller plan for more
    # load. ponytail: conservative until runs that vary the payload shape say which holds; then one curve.
    peak_cores, avg_cores = (max(ingest_cores(r, ingest["runs_per_core"], m, curve), field) for r, field in ((peak, ingest["cpus_peak"]), (avg, ingest["cpus_avg"])))
    hi, lo = math.ceil(peak_cores / pod["cpu"]), max(floor, math.ceil(avg_cores / pod["cpu"]))
    workloads["ingest-queue"] = _adjust(workloads["ingest-queue"], hi, lo, math.ceil(hi * keda_factor)) | {"requests": dict(pod), "limits": dict(limit)}
    pb = workloads["platform-backend"]
    per_pod = pb["requests"]["cpu"]
    api_hi, api_lo = (math.ceil(api_cores(r, inline_share, m) / per_pod) for r in (peak, avg))
    workloads["platform-backend"] = _adjust(pb, api_hi, max(pb["min"], api_lo), math.ceil(api_hi * keda_factor))
    fe, per = workloads.get("frontend"), m["frontend_runs_per_pod"]
    if fe is not None:
        hi = math.ceil(peak / per["expected"])
        workloads["frontend"] = _adjust(fe, max(fe["replicas"], hi), max(fe["min"], math.ceil(avg / per["expected"])), max(fe["max"], math.ceil(peak / per["ceiling"])))
    out = {"frontend_pods": workloads["frontend"]["replicas"]} if fe is not None else {}
    out |= {"ingest_cores": peak_cores, "ingest_cores_by": "field curve" if peak_cores == ingest["cpus_peak"] else "load test", "api_cores": api_cores(peak, inline_share, m)}
    if "ingestion" in components:
        n = math.ceil(peak / m["smithdb_ingestion_runs_per_pod"])
        components["ingestion"] = _adjust(components["ingestion"], n, max(floor, math.ceil(avg / m["smithdb_ingestion_runs_per_pod"])), n)
        out["smithdb_ingestion_pods"] = n
    if "compaction-worker" in components:
        # Sized by the rate a worker kept up at, not the 200k estimate: one per 10,000 ran 12 workers at
        # 114.6k where 3 kept up. The autoscaler keeps that estimate as its ceiling, to drain a backlog.
        per = m["compaction_runs_per_worker"]
        n = math.ceil(peak / per["kept_up"])
        components["compaction-worker"] = _adjust(components["compaction-worker"], n, max(floor, math.ceil(avg / per["kept_up"])), math.ceil(peak / per["drain"]))
        out["compaction_workers"] = n
    return out


def ingest_env(m: Mapping[str, Any]) -> list[dict[str, str]]:
    """ingest-queue's environment for the pod the load test ran: GOMAXPROCS at its CPU limit and the
    workers a CPU it set. Without them the 7-vCPU pod runs the chart's 12 workers a CPU and the rate
    the plan counts on it is not the one measured."""
    return [{"name": k, "value": str(v)} for k, v in m["ingest_env"].items()]


def postgres(pods: int, m: Mapping[str, Any]) -> dict[str, int]:
    """Connections the test saw in use, about one a pod, and the max_connections it ran them under."""
    used = math.ceil(pods * m["postgres_connections_per_pod"])
    return {"in_use": used, "max_connections_needed": math.ceil(used * m["postgres_max_connections_over_used"])}
