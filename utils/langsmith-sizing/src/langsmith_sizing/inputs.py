"""What a person says about their install: load, shape and the choices the plan depends on.

Everything optional defaults from a parameter or from the chart at the version planned, never from
a literal here: `resolve` fills each default and says which one it used, so a plan can name the
source of every figure, including the ones the person never typed.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from langsmith_sizing.chart import Chart
from langsmith_sizing.model.payload import clamp
from langsmith_sizing.units import PERCENT, SECONDS_PER_DAY

TRACE_STORES = ("smithdb", "dual", "dual-replicated")
"""SmithDB alone, or SmithDB beside the deprecated ClickHouse as one instance or a 3-node cluster."""
PRODUCTS = ("traces",)
PLACEMENTS = ("external", "statefulset", "operator")
"""Where a data store runs: a managed or self-run instance outside the chart, the chart's own
StatefulSet, or a Kubernetes operator's instances."""
OBJECT_PLACEMENTS = ("external", "in-cluster")
DATASTORES_ON = ("app", "dedicated")
NODE_SHAPE = ("vCPU", "GiB")
"""In-cluster stores share the application pool (as the calculator counts them) or get a pool."""


@dataclass(frozen=True)
class Inputs:
    chart_version: str
    users: float
    """Concurrent frontend users at the busiest time."""
    traces_per_second: float | None = None
    traces_per_month: float | None = None
    """The average rate, as one of the two; a person quotes whichever they know."""
    peak_traces_per_second: float | None = None
    """The busiest hour's rate when it is known; replaces the average times the peak factor."""
    runs_per_trace: float | None = None
    peak_factor: float | None = None
    payload_mix: dict[str, float] | None = None
    """% of runs by size: small, medium, large."""
    single_run_kib: tuple[float, float] | None = None
    """One run size (input KiB, output KiB) in place of the mix."""
    compression: float | None = None
    blob_storage: bool | None = None
    offload_threshold_kib: float | None = None
    retention_days: float | None = None
    extended_retention_days: float | None = None
    extended_share_pct: float | None = None
    redis_expiry_seconds: float | None = None
    redis_expiry_tuned: bool | None = None
    postgres: str | None = None
    """The placement of LangSmith's Postgres; None is external when postgres_memory_gib is given, else the chart's StatefulSet."""
    redis: str = "statefulset"
    smithdb_metastore: str = "external"
    """The SmithDB metastore's Postgres: it is never the chart's, so a StatefulSet here is a Postgres the install runs beside it."""
    object_store: str = "external"
    """external (a bucket) or in-cluster (an S3-compatible store the install runs)."""
    clickhouse: str = "statefulset"
    """Only read while the trace store is dual."""
    postgres_memory_gib: float | None = None
    """Memory of an external Postgres instance, when it is known; None takes the scale guide's."""
    datastores_on: str = "app"
    app_node: tuple[float, float] | None = None
    smithdb_node: tuple[float, float] | None = None
    datastore_node: tuple[float, float] | None = None
    """Node shapes (vCPU, GiB) the pools are counted in; None takes the params'. The data-store pool defaults to the application node."""
    trace_store: str = "smithdb"
    smithdb_tier: str = "auto"
    smithdb_topology: str | None = None
    """cluster or unified; None takes the chart's default, and the chart must have the key."""
    products: tuple[str, ...] = ("traces",)
    survives_node_loss: bool = False
    backfill_runs: float | None = None
    backfill_days: float | None = None
    """ClickHouse history to copy into SmithDB, in runs, and the days to copy it in; both or neither."""


def _validate_backfill(runs: float | None, days: float | None) -> None:
    if runs is None and days is None:
        return
    if runs is None or days is None or runs <= 0 or days <= 0:
        raise ValueError("a backfill needs both backfill_runs and backfill_days, each above zero")


def validate(i: Inputs) -> None:
    if (i.traces_per_second is None) == (i.traces_per_month is None):
        raise ValueError("give exactly one of traces_per_second and traces_per_month")
    if i.users < 0 or (i.traces_per_second or i.traces_per_month or 0) < 0:
        raise ValueError("users and traces cannot be negative")
    if i.trace_store not in TRACE_STORES:
        raise ValueError(f"trace_store is one of {', '.join(TRACE_STORES)}")
    for name in ("postgres", "redis", "smithdb_metastore", "clickhouse"):
        if getattr(i, name) not in (*PLACEMENTS, None):
            raise ValueError(f"{name} is one of {', '.join(PLACEMENTS)}")
    if i.object_store not in OBJECT_PLACEMENTS:
        raise ValueError(f"object_store is one of {', '.join(OBJECT_PLACEMENTS)}")
    if i.datastores_on not in DATASTORES_ON:
        raise ValueError(f"datastores_on is one of {', '.join(DATASTORES_ON)}")
    for shape in (i.app_node, i.smithdb_node, i.datastore_node):
        if shape is not None and (len(shape) != len(NODE_SHAPE) or min(shape) <= 0):
            raise ValueError("a node shape is (vCPU, GiB), both above zero")
    _validate_backfill(i.backfill_runs, i.backfill_days)
    if tuple(i.products) != PRODUCTS:
        raise ValueError(f"products: only {', '.join(PRODUCTS)} is sized so far")


def resolve(i: Inputs, chart: Chart, p: dict[str, Any]) -> tuple[dict[str, Any], dict[str, str]]:
    """The inputs with every default filled and clamped, and where each value came from
    ("input:<name>", "param:<id>" or "chart:<key>")."""
    validate(i)
    lim = p["inputs.limits"]
    out: dict[str, Any] = {}
    src: dict[str, str] = {}

    def pick(name: str, given: Any, default: Any, default_src: str) -> Any:
        out[name], src[name] = (given, f"input:{name}") if given is not None else (default, default_src)
        return out[name]

    out["users"], src["users"] = i.users, "input:users"
    tps = (
        i.traces_per_second if i.traces_per_second is not None
        else i.traces_per_month / p["time.seconds_per_month"]
    )
    if i.peak_traces_per_second is not None and i.peak_traces_per_second < tps:
        # A flag that replaces a preset's average left the preset's own peak below it, and the plan was sized for the lower.
        raise ValueError(f"the peak of {i.peak_traces_per_second:g} traces/s is below the average of {tps:g}: give --peak-traces-per-second at least the average (a flag that replaces a preset's rate leaves its peak behind)")
    out["traces_per_second"] = tps
    src["traces_per_second"] = "input:traces_per_second" if i.traces_per_second is not None else "input:traces_per_month"
    out["peak_traces_per_second"], src["peak_traces_per_second"] = i.peak_traces_per_second, "input:peak_traces_per_second"
    rpt = pick("runs_per_trace", i.runs_per_trace, p["load.runs_per_trace"], "param:load.runs_per_trace")
    out["runs_per_trace"] = clamp(rpt, lim["runs_per_trace"], p["load.runs_per_trace"])
    peak = pick("peak_factor", i.peak_factor, p["load.peak_factor"], "param:load.peak_factor")
    out["peak_factor"] = clamp(peak, lim["peak_factor"], p["load.peak_factor"])
    mix = pick("payload_mix", i.payload_mix, p["payload.mix_default"], "param:payload.mix_default")
    out["payload_mix"] = {k: clamp(mix.get(k, 0), {"min": 0, "max": PERCENT}, 0) for k in p["payload.mix_default"]}
    out["single_run_kib"] = i.single_run_kib and tuple(clamp(v, lim["field_kib"], lim["field_kib"]["min"]) for v in i.single_run_kib)
    comp = pick("compression", i.compression, p["defaults.compression"], "param:defaults.compression")
    out["compression"] = clamp(comp, lim["compression"], p["defaults.compression"])
    pick("blob_storage", i.blob_storage, p["defaults.blob_storage"], "param:defaults.blob_storage")
    thr = pick("offload_threshold_kib", i.offload_threshold_kib, chart.number("config.blobStorage.minBlobStorageSizeKb"), "chart:config.blobStorage.minBlobStorageSizeKb")
    out["offload_threshold_kib"] = round(clamp(thr, lim["threshold_kib"], chart.number("config.blobStorage.minBlobStorageSizeKb")))
    pick("retention_days", i.retention_days, chart.number("config.ttl.ttl_period_seconds.shortlived") / SECONDS_PER_DAY, "chart:config.ttl.ttl_period_seconds.shortlived")
    pick("extended_retention_days", i.extended_retention_days, chart.number("config.ttl.ttl_period_seconds.longlived") / SECONDS_PER_DAY, "chart:config.ttl.ttl_period_seconds.longlived")
    share = pick("extended_share_pct", i.extended_share_pct, p["retention.extended_share_default_pct"], "param:retention.extended_share_default_pct")
    out["extended_share_pct"] = clamp(share, {"min": 0, "max": PERCENT}, p["retention.extended_share_default_pct"])
    pick("redis_expiry_seconds", i.redis_expiry_seconds, chart.number("config.settings.redisRunsExpirySeconds"), "chart:config.settings.redisRunsExpirySeconds")
    pick("redis_expiry_tuned", i.redis_expiry_tuned, p["defaults.redis_expiry_tuned"], "param:defaults.redis_expiry_tuned")
    for name in ("redis", "smithdb_metastore", "object_store", "clickhouse", "datastores_on", "postgres_memory_gib", "trace_store", "smithdb_tier", "smithdb_topology", "survives_node_loss", "app_node", "smithdb_node", "datastore_node", "backfill_runs", "backfill_days"):
        out[name], src[name] = getattr(i, name), f"input:{name}"
    out["postgres"] = i.postgres or ("external" if i.postgres_memory_gib is not None else "statefulset")
    src["postgres"] = "input:postgres" if i.postgres else "input:postgres_memory_gib" if i.postgres_memory_gib is not None else "input:default"
    return out, src
