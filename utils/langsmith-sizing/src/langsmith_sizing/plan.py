"""The "size" part of a plan: what a load needs, assembled from the model.

`size` gathers every input the model's pure functions take (the person's inputs, the params, the
cited docs values, the chart's defaults and what it renders to) and returns one versioned dict:
the rates, every workload, SmithDB, the stores and a provenance map naming where each figure came
from. It reads no file itself; the chart is a `Chart`, the rest are loaded and passed in.
No per-environment rules, only the load: the regime is a band of it. After the sizing come the
healthy-install parts: how each workload autoscales (`scale`), what to configure (`configure`),
what to watch (`watch`) and what is already wrong or unproven (`warnings`).
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any

from langsmith_sizing import PLANNED_CHARTS, deploy
from langsmith_sizing import inputs as inputs_mod
from langsmith_sizing.chart import SMITHDB_RENDERABLE, Chart, ChartError, cpu, gib, line_at_least, merge
from langsmith_sizing.model import (
    configure,
    lite,
    load,
    payload,
    products,
    regime,
    scale,
    scaleout,
    services,
    smithdb,
    stores,
    watch,
)
from langsmith_sizing.params import Param, values
from langsmith_sizing.units import KIB, KILO, SECONDS_PER_HOUR
from langsmith_sizing.values import cpu_quantity, memory_quantity, placeholder, resources

SCHEMA = 1

# The chart's names for what the model sizes: a container name keys a rendered pod, and a key in
# values.yaml holds the settings that pod is read from.
SMITHDB_VALUES_KEY = {
    "query": "query", "ingestion": "ingestion", "compaction": "compaction", "compaction-worker": "compactionWorker",
    "cluster-manager": "clusterManager", "stats-query": "statsQuery", "mutations": "mutations",
}
SMITHDB_STARTS = ("ingestion", "query", "compaction", "compaction-worker", "cluster-manager")
SMITHDB_SPLITS = ("stats-query", "mutations")
CHART_FIXED = ("queue", "ace-backend", "playground")
CHART_VALUES_KEY = {"queue": "queue", "ace-backend": "aceBackend", "playground": "playground"}


class _Prov:
    """Where each figure came from: input, chart, docs, param, or derived from several."""

    def __init__(self, params: dict[str, Param]) -> None:
        self.params = params
        self.map: dict[str, dict[str, Any]] = {}

    def __call__(self, path: str, *ids: str) -> None:
        families = {i.split(":", 1)[0] for i in ids}
        entry: dict[str, Any] = {"kind": families.pop() if len(families) == 1 else "derived", "from": list(ids)}
        if entry["kind"] == "param" and len(ids) == 1:
            entry["param_source"] = self.params[ids[0].split(":", 1)[1]].source_kind
        self.map[path] = entry

    def extend(self, path: str, *ids: str) -> None:
        self.__call__(path, *self.map[path]["from"], *ids)


def _dig(node: Any, path: str) -> Any:
    """A dotted path into the plan or a chart value, None where it breaks."""
    for part in path.split("."):
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    return node


def _res(pod: dict[str, Any]) -> dict[str, Any]:
    return {"requests": pod["requests"], "limits": pod["limits"]}


def _ha(entry: dict[str, Any], n: int) -> dict[str, Any]:
    return entry | {"replicas": max(entry["replicas"], n), "min": max(entry["min"], n), "max": max(entry["max"], n)}


def _smithdb_overrides(chart: Chart, tier: str, splits: bool, topology: str | None, store: str) -> dict[str, Any]:
    sdb: dict[str, Any] = {"resourceTier": tier, "statsQuery": {"enabled": splits}, "mutations": {"enabled": splits}}
    if topology is not None:
        sdb["topology"] = topology
    return {"smithdb": merge(SMITHDB_RENDERABLE, sdb), "clickhouse": {"enabled": store != "smithdb"}}


@dataclass
class _Ctx:
    """What every section of a sizing reads: the resolved inputs, the params' values, the chart, the
    cited docs values, and the provenance each section adds to."""

    inputs: inputs_mod.Inputs
    r: dict[str, Any]
    p: dict[str, Any]
    chart: Chart
    cited: Any
    prov: _Prov

    @property
    def reads(self) -> list[float]:
        return load.anchors(self.cited["scale.read_anchors"])

    @property
    def writes(self) -> list[float]:
        return load.anchors(self.cited["scale.write_anchors"])


def size(inputs: inputs_mod.Inputs, chart: Chart, params: dict[str, Param], cited: Any) -> dict[str, Any]:
    """The sizing of one install at one chart version."""
    if inputs.chart_version != chart.version:
        raise ValueError(f"inputs name chart {inputs.chart_version} but the chart given is {chart.version}")
    p = values(params)
    r, src = inputs_mod.resolve(inputs, chart, p)
    c = _Ctx(inputs, r, p, chart, cited, _Prov(params))
    _input_prov(c, src)

    rates = _rates(c)
    grid = load.build_grid(load.published_profiles(cited), p["grid.blend"])
    profile = load.profile_for(r["users"], r["traces_per_second"], grid, c.reads, c.writes)
    c.prov("guide", *GUIDE_IDS, "param:grid.blend", "derived:rates")
    pay = _payload(c)
    # The regime decides SmithDB's layout, so it is read from the load before SmithDB is sized.
    reg = regime.classify(p["regimes"], traces_per_second=r["traces_per_second"], peak_runs_per_second=rates["runs_per_second_peak"], peak_bands=p["smithdb.peak_runs_bands"], peak_traces_per_second=rates["peak_traces_per_second"], facts={"survives_node_loss": r["survives_node_loss"]})
    c.prov("regime", "param:regimes", "param:smithdb.peak_runs_bands", "derived:rates", "input:survives_node_loss")
    sdb, pods = _smithdb(c, rates, reg["turns_on"])
    ingest, workloads = _workloads(c, rates, profile, pay, pods)
    reg["requests_from_measured"] = bool(reg["turns_on"].get("requests_from_measured")) if r["requests_from_measured"] is None else r["requests_from_measured"]
    if reg["requests_from_measured"]:
        _from_measured(c, workloads, rates)
    if r["survives_node_loss"]:
        workloads = _survive_node_loss(c, workloads, sdb)
    out_stores: dict[str, Any] = {"object_storage": _object_storage(c, rates, pay), "redis": _redis(c, rates, profile, pay, pods, floor=not reg["requests_from_measured"])}
    if reg["turns_on"].get("scale_out"):
        reg["measured"] = _scale_out(c, rates, pay, ingest, workloads, sdb)
    out_stores |= {"postgres": _postgres(c, workloads, pods), "clickhouse": _clickhouse(c, profile)}
    if "measured" in reg:
        _postgres_measured(c, out_stores["postgres"], workloads, reg["measured"])
    body: dict[str, Any] = {
        "schema": SCHEMA, "chart": chart.version, "app_version": chart.app_version,
        "inputs": {k: v for k, v in r.items() if k not in ("payload_mix", "single_run_kib")} | {"payload_mix": r["payload_mix"], "single_run_kib": r["single_run_kib"]},
        "rates": rates,
        "guide": {k: profile[k] for k in ("fe", "pb", "iq", "be", "min_fe", "min_pb", "min_iq", "min_be", "redis_gi")},
        "payload": pay, "ingest": ingest, "workloads": workloads, "smithdb": sdb, "stores": out_stores, "regime": reg,
        "products": _products(c),
    }
    _operate(body, r, p, chart, c.prov, pods)
    wkeys = {s["sized_as"].split(".", 1)[1]: s["values_key"] for s in p["scale.workloads"].values() if s["sized_as"].startswith("workloads.")} | CHART_VALUES_KEY
    deploy.assemble(body, p=p, cited=cited, chart=chart, pods=pods, keys=wkeys, prov=c.prov)
    return body | {"provenance": c.prov.map}


def _input_prov(c: _Ctx, src: dict[str, str]) -> None:
    for name, s in src.items():
        c.prov(f"inputs.{name}", s)
    for name in ("runs_per_trace", "peak_factor", "compression", "offload_threshold_kib"):
        c.prov.extend(f"inputs.{name}", "param:inputs.limits")  # a given or defaulted value is clamped to its limits
    if c.r["single_run_kib"]:
        c.prov("inputs.single_run_kib", "input:single_run_kib", "param:inputs.limits")


def _from_measured(c: _Ctx, workloads: dict[str, Any], rates: dict[str, Any]) -> None:
    """Each pod asks what the lab measured it to use at this load (params lite.measured)."""
    lm = c.p["lite.measured"]
    for name, rule in lm["workloads"].items():
        if name in workloads:
            rq = lite.request(rule, runs_per_second=rates["runs_per_second_peak"], readers=c.r["users"], headroom=lm["headroom"], min_cpu=lm["min_cpu"], memory_headroom=lm["memory_headroom"])
            workloads[name] = workloads[name] | {"requests": rq, "limits": lite.at_least(workloads[name]["limits"], rq)}
            c.prov.extend(f"workloads.{name}", "param:lite.measured")


def _survive_node_loss(c: _Ctx, workloads: dict[str, Any], sdb: dict[str, Any]) -> dict[str, Any]:
    n = int(c.p["availability.min_replicas"])
    sdb["components"] = {k: _ha(v, n) for k, v in sdb["components"].items()}
    for path in [f"workloads.{k}" for k in workloads] + ["smithdb"]:
        c.prov.extend(path, "param:availability.min_replicas")
    return {k: _ha(v, n) for k, v in workloads.items()}


def _scale_out(c: _Ctx, rates: dict[str, Any], pay: dict[str, Any], ingest: dict[str, Any], workloads: dict[str, Any], sdb: dict[str, Any]) -> dict[str, Any]:
    """Past the docs' tiers: rescale in place at the load test's rates; return the figures used."""
    p = c.p
    measured = scaleout.apply(
        peak=rates["runs_per_second_peak"], avg=rates["runs_per_second_avg"], workloads=workloads, components=sdb["components"], ingest=ingest,
        inline_share=pay["inline_share"], m=p["scale_out.measured"], curve=p["ingest.runs_per_core_points"], keda_factor=p["keda.max_factor"],
        floor=int(p["availability.min_replicas"]) if c.r["survives_node_loss"] else 1,
    )
    for path in ("workloads.ingest-queue", "workloads.platform-backend", "workloads.frontend", "smithdb"):
        c.prov.extend(path, "param:scale_out.measured", "param:ingest.runs_per_core_points")
    return measured


def _ingest_env(body: dict[str, Any], p: dict[str, Any]) -> dict[str, Any]:
    """Past the tiers ingest-queue runs the load test's pod, so it gets that pod's settings too."""
    if not body["regime"].get("measured"):
        return {}
    return {"ingestQueue.deployment.extraEnv": scaleout.ingest_env(p["scale_out.measured"])}


def _postgres_measured(c: _Ctx, pg: dict[str, Any], workloads: dict[str, Any], measured: dict[str, Any]) -> None:
    measured["postgres"] = scaleout.postgres(sum(w["replicas"] for w in workloads.values()), c.p["scale_out.measured"])
    pg["connections_in_use"] = measured["postgres"]["in_use"]
    pg["max_connections_needed"] = measured["postgres"]["max_connections_needed"]
    c.prov.extend("stores.postgres", "param:scale_out.measured")


GUIDE_IDS = [f"docs:scale.{k}" for k in ("replicas.frontend", "replicas.platform_backend", "replicas.ingest_queue", "replicas.backend", "redis_gib", "clickhouse", "clickhouse_setup")]
"""The scale guide's figures the application replicas are read from."""


def _products(c: _Ctx) -> dict[str, Any]:
    """What runs besides tracing, each product's pods read from a render with it on, and what it needs."""
    cat = products.catalog()
    on, added = products.chosen(c.r["products"], cat)
    vals = products.values(on, cat, c.p, placeholder)
    out: dict[str, Any] = {
        "on": on, "added": added, "labels": {n: cat[n]["label"] for n in on},
        "needs": {n: cat[n]["needs"] for n in on if cat[n].get("needs")}, "render": products.renderable(on, cat),
    }
    c.prov("products", "input:products", "derived:products.yaml", "chart:render")
    if "gateway" in on and c.r["gateway_streams"]:
        out["gateway"], extra = _gateway(c)
        vals = merge(vals, extra)
    if "sandboxes" in on:
        out["sandboxes"], extra = _sandboxes(c)
        vals = merge(vals, extra)
    pods = products.rendered_pods(c.chart.render(merge(vals, out["render"])), on, cat)
    if "sandboxes" in on:
        host_pod = next(n for n, x in pods.items() if x["product"] == "sandboxes")
        sb = out["sandboxes"]
        pods[host_pod].update(replicas=sb["hosts"], min=sb["hosts"] if sb["cpu_autoscaler_short"] else sb["min_hosts"], max=sb["hosts"], pool="sandboxes")
    if "agent_server" in on:
        agents = products.agent_server(int(c.r["agent_deployments"]), c.r["agent_load"], c.cited)
        pods |= agents.pop("pods")
        out["agent_server"] = agents
        c.prov("products.agent_server", "input:agent_deployments", "param:agent_server.load_default", "docs:agent_server.api_servers", "docs:agent_server.queue_workers", "docs:agent_server.postgres", "docs:agent_server.redis", "docs:agent_server.limit_default")
    if any(cat[n].get("unsized") for n in on):
        c.prov.extend("products", "param:products.pods", "param:products.limit_over_request")
    out["pods"], out["values"] = pods, vals
    return out


def _rates(c: _Ctx) -> dict[str, Any]:
    r, p, reads, writes = c.r, c.p, c.reads, c.writes
    tps, users = r["traces_per_second"], r["users"]
    runs = load.run_rates(tps, r["runs_per_trace"], r["peak_factor"], r["peak_traces_per_second"])
    peak_tps = runs["runs_per_second_peak"] / r["runs_per_trace"]
    c.prov("rates", "input:traces", "param:load.runs_per_trace", "param:load.peak_factor", "param:time.seconds_per_month", "param:time.seconds_per_year")
    for name in ("bands", "beyond_published", "extrapolation"):
        c.prov(f"rates.{name}", "docs:scale.read_anchors", "docs:scale.write_anchors")
    c.prov("rates.beyond_payload_tested", "param:payload.tested_traces_per_second")
    return {
        "traces_per_second": tps, "traces_per_month": load.traces_per_month(tps, p["time.seconds_per_month"]),
        "traces_per_year": tps * p["time.seconds_per_year"], **runs, "peak_traces_per_second": peak_tps,
        "bands": load.classify_bands(users, tps, reads, writes), "beyond_published": load.beyond_published(users, tps, reads, writes),
        "extrapolation": load.extrapolation_factors(users, tps, reads, writes), "beyond_payload_tested": peak_tps > p["payload.tested_traces_per_second"],
    }


def _payload(c: _Ctx) -> dict[str, Any]:
    r, p = c.r, c.p
    buckets = payload.buckets_from_params(p)
    keys = [b["key"] for b in buckets]
    c.prov("payload", *(f"param:payload.{k}" for k in ("bucket_kib", "smithdb_kb_per_run", "blob_kb_per_run", "redis_kb_per_run", "platform_backend_pods_at_reference", "reference_traces_per_year", "partial_inline_share")), "input:payload_mix", "chart:config.blobStorage.minBlobStorageSizeKb")
    return payload.resolve(
        [r["payload_mix"][k] for k in keys], buckets, payload.curves_from_params(p), threshold_kib=r["offload_threshold_kib"], blob=r["blob_storage"],
        compression=r["compression"], default_shares=[p["payload.mix_default"][k] for k in keys],
        default_threshold_kib=c.chart.number("config.blobStorage.minBlobStorageSizeKb"), partial_inline_share=p["payload.partial_inline_share"], single=r["single_run_kib"],
    )


def _smithdb_layout(c: _Ctx, rates: dict[str, Any], turns_on: dict[str, Any]) -> tuple[dict[str, Any], str, str, dict[str, Any] | None]:
    """The tier the bands give, the tier and topology to run, and a low regime's layout. A tier or
    topology the person gives is kept."""
    r, p, chart, cited = c.r, c.p, c.chart, c.cited
    tiers = list(cited["smithdb.tested_qps"])
    auto = smithdb.auto_tier(
        rates["runs_per_second_peak"], r["users"], tiers=tiers, peak_bands=p["smithdb.peak_runs_bands"],
        tested_query_qps={t: cited["smithdb.tested_qps"][t]["query"] for t in tiers}, rps_per_user=cited["scale.read_anchors"]["rps"]["high"] / c.reads[-1],
    )
    tier = auto["tier"] if r["smithdb_tier"] == "auto" else r["smithdb_tier"]
    if tier not in tiers:
        raise ValueError(f"smithdb_tier is auto or one of {', '.join(tiers)}")
    topology_key = chart.at("smithdb.topology")
    topology = r["smithdb_topology"] or topology_key or "cluster"
    if topology not in ("cluster", "unified") or (topology == "unified" and topology_key is None):
        raise ChartError(f"chart {chart.version} cannot run SmithDB as {topology}: it has no smithdb.topology")
    if r["smithdb_tier"] != "auto" or not turns_on.get("smithdb_tier"):
        return auto, tier, topology, None
    low = turns_on["smithdb_tier"]
    layout = smithdb.low_regime_layout(
        auto, tier=low, tested_query_qps=cited["smithdb.tested_qps"][low]["query"], peak_runs_per_second=rates["runs_per_second_peak"],
        pod_runs_per_second=p["smithdb.small_ingestion_runs_per_pod"],
        unified_allowed=bool(turns_on.get("smithdb_unified")) and topology_key is not None and r["smithdb_topology"] is None,
    )
    c.prov("smithdb.components", "param:regimes", "param:smithdb.small_ingestion_runs_per_pod", "docs:smithdb.tested_qps", "derived:rates")
    return auto, layout["tier"], "unified" if layout["unified"] else topology, layout


def _smithdb_components(c: _Ctx, tier: str, splits: bool, pods: dict[str, Any], layout: dict[str, Any] | None) -> dict[str, Any]:
    """The cluster layout's components at the tier's starting replicas, raised to a low regime's counts."""
    p, chart, cited = c.p, c.chart, c.cited
    hpa = {
        name: int(chart.number(f"smithdb.{SMITHDB_VALUES_KEY[name]}.autoscaling.hpa.maxReplicas"))
        for name in (*SMITHDB_STARTS, *SMITHDB_SPLITS) if chart.at(f"smithdb.{SMITHDB_VALUES_KEY[name]}.autoscaling.hpa.maxReplicas") is not None
    }
    comps = smithdb.components(
        tier, tiers=list(cited["smithdb.tested_qps"]), pods=pods, starts={name: cited[f"smithdb.replicas.{name}"][tier] for name in SMITHDB_STARTS}, hpa_max=hpa,
        query_floor=p["smithdb.query_floor_replicas"], splits_from=p["smithdb.splits_from_tier"],
        split_replicas={"stats-query": int(chart.number("smithdb.statsQuery.deployment.replicas")), "mutations": p["smithdb.mutations_replicas"]},
    )
    c.prov("smithdb", "chart:smithdb.resourceTier", "chart:smithdb.query.autoscaling.hpa.maxReplicas", *(f"docs:smithdb.replicas.{name}" for name in SMITHDB_STARTS), "param:smithdb.query_floor_replicas", "param:smithdb.mutations_replicas", "param:smithdb.splits_from_tier")
    if layout:
        for name in ("ingestion", "query"):
            comp, n = comps[name], layout[f"{name}_replicas"]
            if n > comp["replicas"]:
                comps[name] = comp | {"replicas": n, "min": n, "max": max(comp["max"], n)}
    return comps


def _smithdb(c: _Ctx, rates: dict[str, Any], turns_on: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    """SmithDB's tier, topology and components, and every pod the chart renders with them."""
    cited = c.cited
    auto, tier, topology, layout = _smithdb_layout(c, rates, turns_on)
    model_tier = auto["tier"] if c.r["smithdb_tier"] == "auto" else c.r["smithdb_tier"]
    splits = topology == "cluster" and smithdb.splits_on(tier, list(cited["smithdb.tested_qps"]), c.p["smithdb.splits_from_tier"])
    pods = c.chart.pods(_smithdb_overrides(c.chart, tier, splits, topology if c.chart.at("smithdb.topology") is not None else None, c.inputs.trace_store))
    if topology == "unified":
        comps = {"smithdb": smithdb.component(pods["smithdb"], int(pods["smithdb"]["replicas"]), None)}
        c.prov("smithdb", "chart:smithdb.topology", "chart:smithdb.resourceTier")
    else:
        comps = _smithdb_components(c, tier, splits, pods, layout)
    c.prov("smithdb.auto", "param:smithdb.peak_runs_bands", "docs:smithdb.tested_qps", "docs:scale.read_anchors", "derived:rates")
    c.prov("smithdb.metastore", "docs:smithdb.metastore", "docs:smithdb.metastore_postgres")
    c.prov("smithdb.cache_volume", "docs:smithdb.cache_volume")
    sdb = {
        "topology": topology, "tier": tier, "tier_by": "regime" if tier != model_tier else auto["by"], "auto": auto, "splits": splits, "components": comps,
        "ingestion_cores": smithdb.ingest_cores(comps) if topology == "cluster" else None,
        "metastore": cited["smithdb.metastore"][tier] | {"postgres_min_major_version": cited["smithdb.metastore_postgres"]["min_major_version"]},
        "cache_volume": cited["smithdb.cache_volume"], "backfill": _backfill(c),
    }
    return sdb, pods


def _backfill(c: _Ctx) -> dict[str, Any] | None:
    if c.r["backfill_runs"] is None:
        return None
    job = c.chart.at("smithdb.migration.job.resources.requests")
    c.prov("smithdb.backfill", "input:backfill_runs", "input:backfill_days", "docs:smithdb.backfill", "docs:smithdb.backfill_pod_memory", "chart:smithdb.migration.job.resources")
    return smithdb.backfill(
        c.r["backfill_runs"], c.r["backfill_days"], runs_per_vcpu_day=c.cited["smithdb.backfill"]["runs_per_vcpu_day"],
        pod={"cpu": float(job["cpu"]), "memory_gib": gib(job["memory"])}, min_memory_gib=c.cited["smithdb.backfill_pod_memory"]["min_memory_gib"],
    )


def _workloads(c: _Ctx, rates: dict[str, Any], profile: dict[str, Any], pay: dict[str, Any], pods: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    """The ingest queue's sizing, and every application workload: the chart's resources, the model's replicas."""
    p, chart = c.p, c.chart
    per_core = [services.ingest_runs_per_core(b["run_kib"], p["ingest.runs_per_core_points"]) for b in pay["buckets"]]
    ingest = services.ingest(
        rates["runs_per_second_peak"], rates["runs_per_second_avg"], services.harmonic_per_worker(pay["weights"], per_core),
        headroom=p["ingest.cpu_headroom"], pod_cpu=p["ingest.pod_cpu"], min_pods=p["ingest.min_pods"], keda_factor=p["keda.max_factor"], keda_round_to=p["keda.round_to"],
    )
    c.prov("ingest", "param:ingest.runs_per_core_points", "param:ingest.cpu_headroom", "param:ingest.pod_cpu", "param:ingest.min_pods", "param:keda.max_factor", "param:keda.round_to", "derived:rates", "derived:payload")
    pb_payload = services.platform_backend_pods(rates["runs_per_second_peak"], pay["blend"]["pb_per_1k"])
    be_chart = int(chart.number("backend.deployment.replicas")) if c.inputs.trace_store == "smithdb" else None
    replicas = services.application_replicas(profile, ingest, pb_payload, int(chart.number("platformBackend.deployment.replicas")), be_chart)
    ingest_pod = {"cpu": p["ingest.pod_cpu"], "memory_gib": p["ingest.pod_memory_gib"]}
    pb_limits = dict(pods["platform-backend"]["limits"])
    pb_limits["cpu"] = max(pb_limits["cpu"], p["go.min_cpu_limit"])
    workloads: dict[str, dict[str, Any]] = {
        "frontend": replicas["frontend"] | _res(pods["frontend"]),
        "backend": replicas["backend"] | _res(pods["backend"]),
        "platform-backend": replicas["platform-backend"] | {"requests": pods["platform-backend"]["requests"], "limits": pb_limits},
        "ingest-queue": replicas["ingest-queue"] | {"requests": ingest_pod, "limits": ingest_pod},
    }
    for name in CHART_FIXED:
        key = CHART_VALUES_KEY[name]
        n = int(chart.number(f"{key}.deployment.replicas"))
        workloads[name] = {"replicas": n, "min": n, "max": n} | _res(pods[name])
        c.prov(f"workloads.{name}", f"chart:{key}.deployment.replicas", f"chart:{key}.deployment.resources")
    c.prov("workloads.frontend", *GUIDE_IDS, "docs:scale.read_anchors", "chart:frontend.deployment.resources")
    c.prov("workloads.backend", *GUIDE_IDS, "chart:backend.deployment.replicas", "chart:backend.deployment.resources")
    c.prov("workloads.platform-backend", *GUIDE_IDS, "derived:payload", "chart:platformBackend.deployment.replicas", "chart:platformBackend.deployment.resources", "param:go.min_cpu_limit")
    c.prov("workloads.ingest-queue", "derived:ingest", "param:ingest.pod_cpu", "param:ingest.pod_memory_gib")
    return ingest, workloads


def _object_storage(c: _Ctx, rates: dict[str, Any], pay: dict[str, Any]) -> dict[str, Any]:
    r, p = c.r, c.p
    c.prov("stores.object_storage", "derived:payload", "input:attachment_kib_per_run", "docs:blob_storage.attachments", "param:headroom.storage", "param:retention.smithdb_delete_lag_days", "chart:config.ttl.ttl_period_seconds")
    return stores.object_storage(
        rates["runs_per_day"], pay["blend"], base_days=r["retention_days"], extended_share_pct=r["extended_share_pct"], extended_days=r["extended_retention_days"],
        lag_days=p["retention.smithdb_delete_lag_days"], headroom=p["headroom.storage"], blob=r["blob_storage"],
        attachment_kb=r["attachment_kib_per_run"] * KIB / KILO,
    )


def redis_trimmed(c: _Ctx) -> bool:
    """Whether ingest trims a stored run's payload from Redis: SmithDB alone, on the line that does it or later."""
    return c.inputs.trace_store == "smithdb" and line_at_least(c.chart.version, str(c.p["redis.payload_trimmed_from"]))


def _redis(c: _Ctx, rates: dict[str, Any], profile: dict[str, Any], pay: dict[str, Any], pods: dict[str, Any], floor: bool = True) -> dict[str, Any]:
    """Redis sized on its payload, with the scale guide's figure as a floor unless the regime sizes from measured use."""
    r, p = c.r, c.p
    peak = rates["runs_per_second_peak"]
    headroom = stores.redis_headroom(p["headroom.redis"], r["redis_expiry_tuned"], p["headroom.redis_untuned_expiry"])
    trimmed = redis_trimmed(c)
    rbytes = stores.redis_bytes(peak, pay["blend"]["redis_kb"], r["redis_expiry_seconds"], headroom,
                                p["redis.trimmed_kb_per_run"] if trimmed else None, p["redis.stall_hours"] * SECONDS_PER_HOUR)
    sizing = stores.redis_sizing(profile["redis_gi"] if floor else 1, stores.bytes_to_gib(rbytes))
    shards = stores.redis_shards_for_cpu(peak, pay["inline_share"], p["redis.runs_per_shard"])
    cluster = r["redis"] == "external" and stores.redis_needs_cluster(sizing["gi"], shards, p["redis.single_node_max_gb"])
    c.prov("stores.redis", "derived:payload", "derived:rates", "param:headroom.redis", "param:headroom.redis_untuned_expiry", "param:redis.runs_per_shard", "param:redis.alarm_pct", "param:redis.queue_partitions", "param:redis.single_node_max_gb", "param:redis.cluster_shard_cap", "param:redis.expiry_retry_hours", "param:redis.payload_trimmed_from", "param:redis.trimmed_kb_per_run", "param:redis.stall_hours", "docs:scale.redis_gib", "chart:config.settings.redisRunsExpirySeconds", "chart:redis.statefulSet.resources")
    return {
        "memory_gi": sizing["gi"], "basis": sizing["basis"], "payload_gi": sizing["payload_gi"], "guide_gi": sizing["profile_gi"],
        "bytes": rbytes, "gb": stores.bytes_to_gb(rbytes), "headroom": headroom, "expiry_seconds": r["redis_expiry_seconds"], "payload_trimmed": trimmed,
        "backlog_tolerance_hours": stores.redis_backlog_tolerance_hours(r["redis_expiry_seconds"], p["redis.expiry_retry_hours"]),
        "expiry_below_chart_default": r["redis_expiry_seconds"] < c.chart.number("config.settings.redisRunsExpirySeconds"),
        "alarm_gib": stores.redis_alarm_gib(sizing["gi"], p["redis.alarm_pct"]), "maxmemory_policy": "noeviction",
        "cpu_shards": shards, "cluster": cluster, "over_shard_cap": shards > p["redis.cluster_shard_cap"],
        "queue_partitions": stores.ingest_queue_partitions(peak, cluster, **p["redis.queue_partitions"]),
        "placement": r["redis"],
        "in_cluster": {"cpu": pods["redis"]["requests"]["cpu"], "memory_gib": sizing["gi"]} if r["redis"] == "statefulset" else None,
    }


def _postgres(c: _Ctx, workloads: dict[str, Any], pods: dict[str, Any]) -> dict[str, Any]:
    r, p, cited = c.r, c.p, c.cited
    n = {k: w["replicas"] for k, w in workloads.items()}
    api_pods = n["platform-backend"] + n["backend"]
    queue_pods = n["queue"] + n["ingest-queue"]
    memory = r["postgres_memory_gib"] if r["postgres_memory_gib"] is not None or r["postgres"] != "external" else cited["scale.postgres"]["memory_gb"]
    max_conn = stores.postgres_max_connections(memory, in_cluster=p["postgres.max_connections_in_cluster"], bytes_per_connection=p["postgres.bytes_per_connection"], cap=p["postgres.max_connections_cap"])
    in_cluster = pods["postgres"] if r["postgres"] == "statefulset" else None
    c.prov("stores.postgres", "param:postgres.pool_api_pod", "param:postgres.connection_budget", "param:postgres.max_connections_in_cluster", "param:postgres.bytes_per_connection", "param:postgres.max_connections_cap", "chart:queue.env.ASYNCPG_POOL_MAX_SIZE", "chart:postgres.statefulSet.resources", "docs:scale.postgres", "derived:workloads")
    return {
        "connections": stores.postgres_connections(api_pods, queue_pods, p["postgres.pool_api_pod"], int(pods["queue"]["env"]["ASYNCPG_POOL_MAX_SIZE"])),
        "max_connections": max_conn, "budget": int(max_conn * p["postgres.connection_budget"]), "api_pods": api_pods, "queue_pods": queue_pods,
        "placement": r["postgres"],
        "max_connections_from": "instance memory" if memory is not None else "image default",
        "in_cluster": {"requests": in_cluster["requests"], "storage_gib": cited["scale.postgres"]["storage_gb"]} if in_cluster else None,
    }


def _clickhouse(c: _Ctx, profile: dict[str, Any]) -> dict[str, Any] | None:
    """ClickHouse when the traces live there, alone or beside SmithDB; None when SmithDB holds them."""
    if c.inputs.trace_store == "smithdb":
        return None
    r, p, cited = c.r, c.p, c.cited
    mode = "replicated" if c.inputs.trace_store == "dual-replicated" else "single"
    rep = mode == "replicated"
    nodes = {m: cited["scale.clickhouse_setup"][m] for m in ("single", "replicated")}
    high = cited["scale.clickhouse_disk.high"]
    per_day = stores.clickhouse_gi_per_day(r["traces_per_second"], high["gi_per_day"] / high["traces_per_second"], p["clickhouse.floor_gi_per_day"], p["clickhouse.floor_up_to_traces_per_second"])
    per_node = stores.clickhouse_storage_gi(True, mode, per_day, r["retention_days"], r["blob_storage"], min_volume_gi=gib(c.chart.at("clickhouse.statefulSet.persistence.size")), inline_factor=p["clickhouse.inline_payload_factor"])
    c.prov("stores.clickhouse", "docs:scale.clickhouse", "docs:scale.clickhouse_setup", "docs:scale.clickhouse_disk.high", "param:clickhouse.inline_payload_factor", "param:clickhouse.floor_gi_per_day", "param:clickhouse.floor_up_to_traces_per_second", "chart:clickhouse.statefulSet.persistence.size")
    return {
        "mode": mode, "nodes": stores.clickhouse_node_count(True, mode, nodes),
        "requests_per_node": {"cpu": profile["ch_rep_cpu" if rep else "ch_cpu"], "memory_gib": profile["ch_rep_mem" if rep else "ch_mem"]},
        "requests_documented": profile["ch_rep_documented"] if rep else True,
        "gi_per_ttl_day": per_day, "storage_gi_per_node": per_node, "storage_gi_total": stores.clickhouse_total_storage_gi(mode, per_node, nodes),
    }


def _gateway(c: _Ctx) -> tuple[dict[str, Any], dict[str, Any]]:
    """The gateway's replicas for its streams, and the autoscaler ceiling that reaches them."""
    per = c.cited["gateway.streams_per_replica"]["streams"]
    need = math.ceil(c.r["gateway_streams"] / per)
    auto = c.chart.at("agentGateway.autoscaling") or {}
    c.prov("products.gateway", "input:gateway_streams", "docs:gateway.streams_per_replica", "chart:agentGateway.autoscaling")
    return (
        {"streams": c.r["gateway_streams"], "replicas_needed": need, "streams_per_replica": per, "tested_requests": c.cited["gateway.tested_requests"]},
        {"agentGateway": {"autoscaling": {"enabled": True, "maxReplicas": max(int(auto.get("maxReplicas", 1)), need)}}},
    )


def _sandboxes(c: _Ctx) -> tuple[dict[str, Any], dict[str, Any]]:
    """The sandbox hosts, their pod, and the values that hold them."""
    given = c.r["sandbox_node"]
    node = {"cpu": given[0], "memory_gib": given[1]} if given else dict(c.p["pools.sandbox_node"])
    mem = c.r["sandbox_memory_gib"] or c.cited["sandboxes.memory"]["memory_gib_each"]
    sb = products.sandbox_hosts(c.r["sandboxes"], c.r["sandbox_vcpu"], mem, node, c.chart, c.cited)
    base = (c.chart.at("sandboxes.sandboxHost.deployment.resources") or {}).get("requests", {})
    host = {"cpu": cpu(base.get("cpu", 0)), "memory_gib": gib(base.get("memory", 0)) + sb["guest_memory_gib_a_host"]}
    c.prov("products.sandboxes", "input:sandboxes", "param:sandboxes.concurrent_default", "param:sandboxes.vcpu_each", "docs:sandboxes.memory", "docs:sandboxes.hosts", "docs:sandboxes.min_hosts", "docs:sandboxes.host_memory", "chart:sandboxes.sandboxHost.autoscaling", "param:pools.sandbox_node", "param:sandboxes.juicefs_redis")
    return sb | {"node": node, "node_from": "input" if given else "param:pools.sandbox_node", "host_pod": host}, {"sandboxes": {"sandboxHost": {
        # memory-bound: the chart's autoscaler counts CPU only, so its floor holds the hosts memory needs
        "autoscaling": {"enabled": True, "minReplicas": sb["hosts"] if sb["cpu_autoscaler_short"] else sb["min_hosts"], "maxReplicas": sb["hosts"]},
        "deployment": {"resources": {"requests": {"cpu": cpu_quantity(host["cpu"]), "memory": memory_quantity(host["memory_gib"])}}},
    }}}


def _serving_replicas(body: dict[str, Any], n: int, prov: _Prov) -> None:
    """A regime that fixes the serving replicas fixes them in the sizing too: the scale section once
    applied 1 while the workloads it is read from still said 3, so the plan said two things."""
    for section, entries in (("workloads", body["workloads"]), ("smithdb.components", body["smithdb"]["components"])):
        for name, entry in entries.items():
            entry.update(replicas=n, min=n, max=n)
            path = f"{section}.{name}"
            if path in prov.map:
                prov.extend(path, "param:regimes")
            else:
                prov(path, "param:regimes")


def _operate(body: dict[str, Any], r: dict[str, Any], p: dict[str, Any], chart: Chart, prov: _Prov, pods: dict[str, Any]) -> None:
    """Add the healthy-install parts to the plan: regime, scale, configure, watch and warnings."""
    rates, sdb, redis = body["rates"], body["smithdb"], body["stores"]["redis"]
    turns_on = body["regime"]["turns_on"]
    if "serving_replicas" in turns_on:
        _serving_replicas(body, turns_on["serving_replicas"], prov)

    fixed = max(turns_on.get("serving_replicas", 0), int(p["availability.min_replicas"]) if r["survives_node_loss"] else 0) or None
    body["scale"] = {}
    for name, spec in p["scale.workloads"].items():
        if spec.get("topology", sdb["topology"]) != sdb["topology"]:
            continue
        key = spec["values_key"]
        body["scale"][name] = scale.workload(
            spec, signals=p["scale.signals"], fallback=p["scale.fallback"], autoscaling=chart.at(f"{key}.autoscaling"), default_replicas=chart.at(f"{key}.deployment.replicas"),
            sized=_dig(body, spec["sized_as"]), autoscalers=turns_on["autoscalers"], fixed_replicas=fixed,
        )
    prov("scale", "param:scale.workloads", "param:scale.signals", "param:scale.fallback", "chart:autoscaling", "derived:workloads", "derived:smithdb", "derived:regime")

    cluster = redis["cluster"]
    feedback = p["load.feedback_per_trace"]
    defaults = {k: bool(chart.at(k)) for k in ("smithdb.statsQuery.enabled", "smithdb.mutations.enabled")}
    split = configure.splits(sdb["splits"], sdb["topology"], defaults, feedback * rates["traces_per_second"], feedback * rates["peak_traces_per_second"])
    policy = configure.redis_policy(placement=redis["placement"], policy=redis["maxmemory_policy"], maxmemory_gi=redis["memory_gi"])
    env = configure.common_env(p["configure.queue_priorities"], p["configure.partition_env"], redis["queue_partitions"], cluster)
    backfill = sdb["backfill"] and {
        "smithdb.migration.job.parallelism": sdb["backfill"]["parallelism"],
        "smithdb.migration.job.resources": resources(sdb["backfill"]["pod"], sdb["backfill"]["pod"]),
    }
    body["configure"] = {
        "values": {"commonEnv": env} | split["values"] | policy["values"] | (backfill or {}) | _ingest_env(body, p),
        "splits": {k: v for k, v in split.items() if k != "values"}, "redis": policy,
        "go": configure.go_limits(body["workloads"], p["go.min_cpu_limit"]), "operation_memory_limit": configure.OPERATION_MEMORY,
        "inputs_to_change": configure.inputs_to_change(turns_on, sdb["topology"], chart.at("smithdb.topology") is not None, rates["runs_per_second_peak"] <= p["smithdb.small_ingestion_runs_per_pod"]),
    }
    prov("configure", "param:smithdb.small_ingestion_runs_per_pod", "param:configure.queue_priorities", "param:configure.partition_env", "param:load.feedback_per_trace", "param:go.min_cpu_limit", "param:redis.queue_partitions", "chart:smithdb.statsQuery.enabled", "chart:smithdb.mutations.enabled", "derived:stores", "derived:regime")

    def resolve(ref: str) -> Any:
        fam, _, key = ref.partition(":")
        return p[key] if fam == "param" else float(chart.at(key)) if fam == "chart" else _dig(body, key)

    body["watch"] = watch.items(p["watch.items"], [*p["watch.metrics_smithdb"]["critical"], *p["watch.metrics_smithdb"]["all_only"], *p["watch.metrics_other"]], resolve=resolve, topology=sdb["topology"], scale=body["scale"])
    prov("watch", "param:watch.items", "param:watch.metrics_smithdb", "param:watch.metrics_other", "param:redis.alarm_pct", "chart:ingestQueue.autoscaling.keda.queueTargetSize", "chart:smithdb.compactionWorker.autoscaling.keda.pendingJobsThreshold", "derived:scale")
    body["warnings"] = watch.plan_warnings(rates=rates, smithdb=sdb, stores=body["stores"], scale=body["scale"], p=p) + watch.product_warnings(body) + watch.scale_out_warnings(body, p)
    if body["chart"] not in PLANNED_CHARTS:
        body["warnings"].append({"id": "chart-not-checked", "severity": "info", "figures": {"planned": list(PLANNED_CHARTS)}, "message": (
            f"chart {body['chart']} is read for every default, but the tests render {', '.join(PLANNED_CHARTS)}: "
            f"make params CHART={body['chart']} checks no parameter restates one of its defaults")})
    prov("warnings", "param:postgres.connection_budget", "param:redis.single_node_max_gb", "param:redis.cluster_shard_cap", "param:payload.tested_traces_per_second", "derived:rates", "derived:smithdb", "derived:stores", "derived:scale")
