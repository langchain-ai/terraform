"""The data stores: object storage, Redis, Postgres connections, and ClickHouse while dual.

Object storage is bytes a day x retention x headroom. Redis holds every run's payload for the full
expiry, so its memory is sized on the peak run rate and never by shortening the expiry. Both run
queue sizes and partitions follow from the peak. ClickHouse is deprecated and sized only while it
still receives the writes.
First ported from the PS sizing calculator (README, Lineage), by Dzmitry Dubarau.
"""

from __future__ import annotations

import math
from collections.abc import Mapping
from typing import Any

from langsmith_sizing.units import EPSILON, GB, GIB, GIB_TO_GB, KILO, PERCENT, SECONDS_PER_HOUR, TB


def _round(x: float) -> int:
    """Round half up: Python's round() takes halves to even, so 2.5 GiB a day would plan 2."""
    return math.floor(x + 0.5)


# Retention and object storage

def effective_extended_share(share_pct: float, base_days: float, extended_days: float) -> float:
    """The share of runs upgraded to extended retention. Extended no longer than base means nothing
    is upgraded, so there is no second ttl_l/ copy to count."""
    return share_pct / PERCENT if extended_days > base_days else 0.0


def smithdb_retention_days(base: float, ext: float, extended: float, lag: float) -> float:
    """Days a run's bytes live in the SmithDB bucket: SmithDB deletes `lag` days after the TTL."""
    return (1 - ext) * (base + lag) + ext * (extended + lag)


def blob_retention_days(base: float, ext: float, extended: float) -> float:
    """Days an offloaded field lives in the LangSmith bucket. An upgrade adds a ttl_l/ copy beside
    the ttl_s/ one, so the extended share lives base + extended days."""
    return (1 - ext) * base + ext * (extended + base)


def smithdb_steady_state_days(base: float, ext: float, extended: float, lag: float) -> float:
    """The label: any extended share moves it to the extended TTL. Storage uses the weighted days."""
    return (extended if ext > 0 else base) + lag


def storage_tb(runs_per_day: float, kb_per_run: float, days: float, headroom: float) -> float:
    """Decimal TB: runs a day x KB a run x 1,000 B x days x headroom."""
    return runs_per_day * kb_per_run * KILO * days * headroom / TB


def written_tb_per_day(runs_per_day: float, kb_per_run: float) -> float:
    """A rate, not a capacity: no headroom."""
    return runs_per_day * kb_per_run * KILO / TB


def object_storage(
    runs_per_day: float, blend: Mapping[str, float], *, base_days: float, extended_share_pct: float, extended_days: float, lag_days: float,
    headroom: float, blob: bool, attachment_kb: float = 0.0,
) -> dict[str, Any]:
    """Both buckets at steady state. The LangSmith bucket exists only when blob storage is on, and holds
    attachments beside offloaded payloads, at the bytes sent: SmithDB keeps only a pointer to them."""
    extended = max(extended_days, base_days)
    ext = effective_extended_share(extended_share_pct, base_days, extended)
    sdb = {
        "tb": storage_tb(runs_per_day, blend["smithdb_kb"], smithdb_retention_days(base_days, ext, extended, lag_days), headroom),
        "written_tb_per_day": written_tb_per_day(runs_per_day, blend["smithdb_kb"]),
        "steady_state_days": smithdb_steady_state_days(base_days, ext, extended, lag_days),
    }
    ls = None
    if blob:
        days = blob_retention_days(base_days, ext, extended)
        kb = blend["blob_kb"] + attachment_kb
        ls = {
            "tb": storage_tb(runs_per_day, kb, days, headroom),
            "written_tb_per_day": written_tb_per_day(runs_per_day, kb),
            "base_tb": storage_tb(runs_per_day, kb, base_days, headroom),
            "extended_tb": storage_tb(runs_per_day, kb, ext * extended, headroom),
            "attachments_tb": storage_tb(runs_per_day, attachment_kb, days, headroom),
        }
    return {"smithdb": sdb, "langsmith": ls, "total_tb": sdb["tb"] + (ls["tb"] if ls else 0), "extended_share": ext, "extended_days": extended}


# Redis

def redis_headroom(base: float, expiry_tuned: bool, untuned_factor: float) -> float:
    """maxmemory headroom: untuned expiry (no hz 50 / active-expire-effort 5) stacks another factor."""
    return base * (1 if expiry_tuned else untuned_factor)


def redis_bytes(peak_runs_per_second: float, redis_kb_per_run: float, ttl_seconds: float, headroom: float) -> float:
    """Runs stay in Redis for the full expiry, even after ingest, so: peak runs/s x KB x 1,000 x TTL x headroom."""
    return peak_runs_per_second * redis_kb_per_run * KILO * ttl_seconds * headroom


def bytes_to_gb(b: float) -> float:
    return b / GB


def bytes_to_gib(b: float) -> float:
    return b / GIB


def redis_backlog_tolerance_hours(ttl_seconds: float, retry_hours: float) -> float:
    """The longest ingest backlog an expiry tolerates once feedback retries are counted. A backlog
    that outlives the expiry loses runs silently, so the expiry is never lowered to save memory."""
    return max(0.0, ttl_seconds / SECONDS_PER_HOUR - retry_hours)


def redis_alarm_gib(maxmemory_gib: float, alarm_pct: float) -> float:
    """noeviction, alarming at alarm_pct of maxmemory: a refused write is retried by the SDK, an
    eviction loses the run. Steady state sits near 77% at 1.3 headroom, so the alarm fires on a
    fully loaded instance: it is the signal to add memory before a backlog starts."""
    return maxmemory_gib * alarm_pct / PERCENT


def redis_shards_for_cpu(peak_runs_per_second: float, inline_share: float, runs_per_shard: Mapping[str, float]) -> int:
    """Redis is single-threaded: shards = ceil(peak x (inline / R_inline + offloaded / R_offloaded))."""
    off = 1 - inline_share
    need = peak_runs_per_second * (inline_share / runs_per_shard["inline"] + off / runs_per_shard["offloaded"])
    return max(1, math.ceil(need - EPSILON))


def redis_needs_cluster(gi: float, cpu_shards: int, single_node_max_gb: float) -> bool:
    """A cluster when the CPU needs more than one shard or the memory passes what one managed node
    holds."""
    return cpu_shards > 1 or gi > single_node_max_gb / GIB_TO_GB


def ingest_queue_partitions(peak_runs_per_second: float, cluster: bool, runs_per_partition: float, min_on_cluster: int) -> int:
    """One on a single node; on a cluster at least min_on_cluster. asynq hash-tags every key with
    the queue name, so one queue sits on one shard."""
    return max(min_on_cluster, math.ceil(peak_runs_per_second / runs_per_partition)) if cluster else 1


def redis_sizing(profile_gi: float, payload_gib: float | None) -> dict[str, Any]:
    """The Redis memory every consumer reads: the scale guide's figure as a floor, the payload's
    when it is larger."""
    payload_gi = math.ceil(payload_gib) if payload_gib is not None else 0
    return {"gi": max(profile_gi, payload_gi), "basis": "payload" if payload_gi > profile_gi else "load", "payload_gi": payload_gi, "profile_gi": profile_gi}


# Postgres

def postgres_connections(api_pods: float, queue_pods: float, api_pool: float, queue_pool: float) -> float:
    """Connections the pods open: platform-backend and backend pods hold api_pool each, queue and
    ingest-queue pods hold queue_pool each."""
    return api_pods * api_pool + queue_pods * queue_pool


def postgres_max_connections(mem_gib: float | None, *, in_cluster: float, bytes_per_connection: float, cap: float) -> float:
    """max_connections assumed for an instance: the image default in-cluster, else the RDS
    parameter-group formula, used as a stand-in for every cloud. Confirm against the instance."""
    if mem_gib is None:
        return in_cluster
    return min(cap, math.floor(mem_gib * GIB / bytes_per_connection))


# ClickHouse, deprecated: sized only while it receives writes

def clickhouse_node_count(on: bool, mode: str, nodes: Mapping[str, int]) -> int:
    """Off or external: none in the cluster; else the guide's node count for the mode."""
    return 0 if not on or mode == "external" else nodes[mode]


def clickhouse_gi_per_day(tps: float, slope_gi_per_tps: float, floor_gi: float, floor_up_to_tps: float) -> float:
    """Disk a TTL day: the guide's 0.6 GiB per trace/s (600 at 1,000, 60 at 100), and a floor at
    low rates where it publishes nothing."""
    return floor_gi if tps <= floor_up_to_tps else _round(slope_gi_per_tps * tps)


def clickhouse_storage_gi(on: bool, mode: str, gi_per_day: float, ttl_days: float, blob: bool, *, min_volume_gi: float, inline_factor: float) -> float:
    """Disk a node. The guide's figure assumes blob storage on; with payloads inline it is
    inline_factor times that."""
    if not on or mode == "external":
        return 0
    return max(min_volume_gi, _round(gi_per_day * ttl_days * (1 if blob else inline_factor)))


def clickhouse_total_storage_gi(mode: str, per_node_gi: float, nodes: Mapping[str, int]) -> float:
    """Every replica holds the full dataset."""
    return per_node_gi * clickhouse_node_count(True, mode, nodes)
