"""Application replicas: the guide's services, the ingest queue and the Go pods.

The scale guide sizes frontend, platform-backend, ingest-queue and backend replicas by load. The
payload model replaces its ingest-queue column (which counted 1-CPU pods) with CPUs from the peak
run rate, and floors platform-backend by what the payload needs; the guide's figure stays the
floor under both, never a cap.
First ported from the PS sizing calculator (README, Lineage), by Dzmitry Dubarau.
"""

from __future__ import annotations

import math
from collections.abc import Mapping, Sequence
from typing import Any

from langsmith_sizing.model.load import ceil
from langsmith_sizing.model.payload import Pt, loglog
from langsmith_sizing.units import KILO


def ingest_runs_per_core(run_kb: float, pts: Sequence[Pt]) -> float:
    """Runs a second one ingest-queue core sustains at this run size: log-log between two
    measured points, held flat outside them. The curve between them is not measured."""
    return loglog(run_kb, pts, "value", "value")


def harmonic_per_worker(weights: Sequence[float], per_worker: Sequence[float]) -> float:
    """Run-weighted harmonic mean of a rate. A large-payload run holds a core longer, so the times
    add, not the rates; an arithmetic mean over-states throughput."""
    return 1 / sum(w / k for w, k in zip(weights, per_worker, strict=True))


def ingest_queue_cpus(runs_per_second: float, runs_per_core: float, headroom: float) -> float:
    return runs_per_second / runs_per_core * headroom


def ingest_queue_pods(runs_per_second: float, runs_per_core: float, headroom: float, pod_cpu: float, min_pods: int) -> int:
    """2-CPU pods, at least min_pods so one survives a restart."""
    return max(min_pods, ceil(ingest_queue_cpus(runs_per_second, runs_per_core, headroom) / pod_cpu))


def keda_max(max_pods: int, factor: float, round_to: float) -> float:
    """KEDA's maxReplicaCount: the nearest multiple of round_to to pods x factor, never below the
    peak pod count. Nearest, with halves up: rounding up gives 30 for 25.5 and no longer
    reproduces the measurement tables."""
    return max(max_pods, math.floor(max_pods * factor / round_to + 0.5) * round_to)


def platform_backend_pods(peak_runs_per_second: float, pods_per_1k: float) -> int:
    """A floor under the guide's figure, never a cap."""
    return ceil(peak_runs_per_second / KILO * pods_per_1k)


def ingest_queue_replicas(min_pods: int, max_pods: int, keda: float) -> dict[str, float]:
    """rep = pods at peak; min = pods at the average; max = the larger of rep and the KEDA ceiling.
    Totals count rep: the ceiling is reported, not reserved."""
    return {"replicas": max_pods, "min": min(max_pods, min_pods), "max": max(max_pods, keda)}


def ingest(peak: float, avg: float, runs_per_core: float, *, headroom: float, pod_cpu: float, min_pods: int, keda_factor: float, keda_round_to: float) -> dict[str, float]:
    """The ingest queue at a peak and an average run rate."""
    max_pods = ingest_queue_pods(peak, runs_per_core, headroom, pod_cpu, min_pods)
    return {
        "runs_per_core": runs_per_core,
        "cpus_peak": ingest_queue_cpus(peak, runs_per_core, headroom),
        "cpus_avg": ingest_queue_cpus(avg, runs_per_core, headroom),
        "min_pods": ingest_queue_pods(avg, runs_per_core, headroom, pod_cpu, min_pods),
        "max_pods": max_pods,
        "keda_max": keda_max(max_pods, keda_factor, keda_round_to),
    }


def application_replicas(
    profile: Mapping[str, Any], ingest_pods: Mapping[str, float], pb_payload_pods: int, pb_floor: int, backend_reads_on_smithdb: int | None,
) -> dict[str, dict[str, float]]:
    """Replicas, the at-rest floor and the ceiling of the four services the guide sizes.

    platform-backend: the guide's figure, raised to what the payload needs, never below the chart's
    default. backend: when SmithDB serves reads (ClickHouse off) the Python backend is off the read
    path, so it holds the chart default; the guide's curve was measured with ClickHouse serving reads."""
    pb = max(profile["pb"], pb_payload_pods, pb_floor)
    be = profile["be"] if backend_reads_on_smithdb is None else backend_reads_on_smithdb
    return {
        "frontend": {"replicas": profile["fe"], "min": profile["min_fe"], "max": profile["fe"]},
        "platform-backend": {"replicas": pb, "min": max(profile["min_pb"], pb_floor), "max": pb},
        "backend": {"replicas": be, "min": be if backend_reads_on_smithdb is not None else profile["min_be"], "max": be},
        "ingest-queue": ingest_queue_replicas(int(ingest_pods["min_pods"]), int(ingest_pods["max_pods"]), ingest_pods["keda_max"]),
    }
