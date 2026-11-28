"""What to watch on a healthy install, and what the plan already knows is wrong.

A watch item names the metric, where to read it and what to do; it carries a number only where a
parameter, the chart or the plan gives one. An item with no such number is "observe": no
measurement backs an alarm level, and inventing one would be worse than saying so.
"""

from __future__ import annotations

from collections.abc import Callable, Iterable, Mapping, Sequence
from typing import Any

from langsmith_sizing.chart import same_line
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


def warn(wid: str, severity: str, message: str, **figures: Any) -> dict[str, Any]:
    return {"id": wid, "severity": severity, "message": message, "figures": figures}


def plan_warnings(*, rates: Mapping[str, Any], smithdb: Mapping[str, Any], stores: Mapping[str, Any], scale: Mapping[str, Mapping[str, Any]], p: Mapping[str, Any]) -> list[dict[str, Any]]:
    """What the plan can already say is wrong or unproven, from figures it computed."""
    out = _store_warnings(stores, p) + _range_warnings(rates, smithdb, p)
    high = {n: s["applied"]["max"] for n, s in scale.items() if s["deployed"] and s["above_chart_default"]}
    if high:
        out.append(warn("ceilings-above-chart-default", "info", "autoscaler ceilings above the chart's default: " + ", ".join(f"{n} {m}" for n, m in high.items()), ceilings=high))
    out += [
        warn(f"chart-ask:{n}", "info", f"{n}: the chart cannot express the recommended trigger ({s['gap']['ask']}); applied instead: {s['gap']['applied_instead']['kind']} on {', '.join(s['gap']['applied_instead']['signals']) or 'nothing'}")
        for n, s in scale.items() if s["deployed"] and s["gap"]
    ]
    return out


def _store_warnings(stores: Mapping[str, Any], p: Mapping[str, Any]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    pg, redis = stores["postgres"], stores["redis"]
    if pg["connections"] > pg["budget"]:
        out.append(warn("postgres-connections", "action", f"the pods open {pg['connections']:g} Postgres connections against a budget of {pg['budget']:g} ({pg['max_connections']:g} max_connections): size Postgres for them or lower the pools", connections=pg["connections"], budget=pg["budget"], max_connections=pg["max_connections"]))
    if redis_needs_cluster(redis["memory_gi"], redis["cpu_shards"], p["redis.single_node_max_gb"]):
        where = "the chart's in-cluster Redis is one node" if redis["in_cluster"] else "a single managed node"
        out.append(warn("redis-needs-cluster", "action", f"Redis needs {redis['cpu_shards']} shards and {redis['memory_gi']:g} GiB, past one node ({p['redis.single_node_max_gb']:g} GB at most); {where}: use a Redis cluster with queue partitions", shards=redis["cpu_shards"], memory_gi=redis["memory_gi"], single_node_max_gb=p["redis.single_node_max_gb"]))
    if redis["over_shard_cap"]:
        out.append(warn("redis-over-shard-cap", "action", f"{redis['cpu_shards']} Redis shards pass the managed cap of {p['redis.cluster_shard_cap']:g}: the queue needs partitions and a measured load test", shards=redis["cpu_shards"], cap=p["redis.cluster_shard_cap"]))
    return out


def _range_warnings(rates: Mapping[str, Any], smithdb: Mapping[str, Any], p: Mapping[str, Any]) -> list[dict[str, Any]]:
    """Where the load leaves what the docs published or the payload measurements covered."""
    out: list[dict[str, Any]] = []
    if rates["beyond_published"]:
        out.append(warn("beyond-published", "action", "the load is past the scale guide's highest published configuration; every figure past it is extrapolated"))
    if rates["beyond_payload_tested"]:
        out.append(warn("beyond-payload-tested", "action", f"the peak of {rates['peak_traces_per_second']:g} traces/s is past the {p['payload.tested_traces_per_second']:g} traces/s the payload coefficients were measured at", peak_traces_per_second=rates["peak_traces_per_second"], tested=p["payload.tested_traces_per_second"]))
    if smithdb["auto"]["write"]["beyond_tiers"]:
        out.append(warn("beyond-tiers", "action", f"the peak of {smithdb['auto']['write']['peak_runs_per_second']:g} runs/s is past SmithDB's largest band: queue, Redis CPU and Postgres connections bind, and the object store's request rate becomes a limit", peak_runs_per_second=smithdb["auto"]["write"]["peak_runs_per_second"]))
    return out


def scale_out_warnings(body: dict[str, Any], p: dict[str, Any]) -> list[dict[str, Any]]:
    """What bound the load test past the tiers, said where a plan reaches it."""
    measured = body["regime"].get("measured")
    if not measured:
        return []
    m, out = p["scale_out.measured"], []
    pg = measured["postgres"]
    out.append(warn("postgres-connections-at-scale", "action", (
        f"about {pg['in_use']:,} Postgres connections in use at this many pods (one a pod in the load test, where a default of about 800 ran out near 730 pods): "
        f"set max_connections to at least {pg['max_connections_needed']:,} and put PgBouncer in front"), **pg))
    peak = body["rates"]["runs_per_second_peak"]
    if peak > m["offload_ceiling_runs_per_second"] and body["payload"]["inline_share"] < 1:
        out.append(warn("offload-throttled", "action", (
            f"past about {m['offload_ceiling_runs_per_second']:,} runs/s the load test's object store throttled reads of offloaded payloads (429s near 300,000 requests/s): "
            "keep payloads in Redis (config.blobStorage.minBlobStorageSizeKb above the run size) and size Redis with them inline"), ceiling=m["offload_ceiling_runs_per_second"]))
    out.append(extrapolated(body, m, peak))
    if "smithdb_ingestion_pods" in measured:
        out.append(warn("ingestion-hot-project", "info", (
            "one busy project's runs land on the same ingestion pods: in the load test the busiest reached 162 of 165 GiB and four were OOM-killed at 200k runs/s; "
            "more pods do not spread one project, larger-memory nodes do"), pods=measured["smithdb_ingestion_pods"]))
    return out


def extrapolated(body: dict[str, Any], m: dict[str, Any], peak: float) -> dict[str, Any]:
    """Where a scale-out plan leaves the one load test it rests on: never read, one run size, and a top
    rate held minutes. Said on every such plan, since a figure past a measurement reads like one."""
    pay = body["payload"]
    run_kib = sum(w * b["run_kib"] for w, b in zip(pay["weights"], pay["buckets"], strict=True))
    hold = m["longest_hold"]
    gaps = ["the test sent no reads, so SmithDB query and stats-query pods, the metastore and the API's read path stay at the large tier's counts"]
    ref, spread = m["ingest_reference_kib"], m["ingest_reference_spread"]
    if not ref / spread <= run_kib <= ref * spread:
        gaps.append(f"its runs were about {m['ingest_reference_kib']} KiB and these average {run_kib:.0f} KiB, so ingest workers follow the ingest curve's ratio, not a measurement")
    if not same_line(body["chart"], m["chart"]):
        gaps.append(f"it ran chart {m['chart']} and this plan is for {body['chart']}, another line, whose ingest and compaction may cost differently")
    if peak > hold["runs_per_second"]:
        gaps.append(f"above {hold['runs_per_second']:,} runs/s (held {hold['minutes']} minutes) the test's top rate held 4 minutes, after a backlog drained")
    return warn("scale-out-extrapolated", "info", "past the docs' tiers this plan rests on one synthetic load test: " + "; ".join(gaps) + ": measure reads and the real run size before committing hardware",
                       run_kib=round(run_kib), reference_kib=m["ingest_reference_kib"], gaps=len(gaps))


def product_warnings(body: dict[str, Any]) -> list[dict[str, Any]]:
    pr, out = body["products"], []
    gw = pr.get("gateway")
    if gw:
        pod = next(x for x in pr["pods"].values() if x["product"] == "gateway")
        tested = gw["tested_requests"]
        if pod["requests"]["cpu"] < tested["cpu"] or pod["requests"]["memory_gib"] < tested["memory_gib"]:
            out.append(warn("gateway-below-tested", "action", (
                f"the docs measured {gw['streams_per_replica']:g} streams a replica at {tested['cpu']:g} vCPU, {tested['memory_gib']:g} GiB; this chart's gateway asks "
                f"{pod['requests']['cpu']:g} vCPU, {pod['requests']['memory_gib']:g} GiB: give agentGateway.deployment.resources the tested requests or expect fewer streams a replica"),
                requests=pod["requests"], tested=tested))
    sb = pr.get("sandboxes")
    if sb and sb["cpu_autoscaler_short"]:
        out.append(warn("sandboxes-memory-bound", "action", (
            f"memory sets the sandbox hosts ({sb['hosts']}), but the chart's autoscaler counts committed CPU only and would run fewer: "
            "the values set its minimum to the hosts, so it never goes below them"), hosts=sb["hosts"]))
    if body["inputs"]["survives_node_loss"] and pr["on"] != ["traces"]:
        single = sorted(n for n, x in pr["pods"].items() if x["max"] == 1 and x.get("kind") == "Deployment")
        if single:
            out.append(warn("products-single-replica", "info", f"the products' pods run one replica, so a node loss stops them until rescheduled: {', '.join(single)}", pods=single))
    return out


def pool_warnings(body: Mapping[str, Any], pools: Mapping[str, Any]) -> list[dict[str, Any]]:
    out = []
    for name, pl in pools.items():
        if pl.get("largest_pod_fits") is False:
            out.append(warn("pod-does-not-fit-node", "action", f"The largest pod of the {name} pool, {pl['largest_pod']} ({pl['largest_pod_cpu']:g} vCPU, {pl['largest_pod_mem_gib']:g} GiB), does not fit a {pl['node_cpu']:g} vCPU, {pl['node_mem_gib']:g} GiB node: give the pool a larger node, or move that store out of the cluster", pool=name, pod=pl["largest_pod"]))
    ch = body["stores"]["clickhouse"]
    if ch and ch.get("fits_app_node") is False:
        out.append(warn("clickhouse-does-not-fit-node", "action", f"One ClickHouse pod does not fit the node it is placed on; it fits a {ch['node_cpu']:g} vCPU, {ch['node_mem_gib']:g} GiB node, one a replica", node_cpu=ch["node_cpu"], node_mem_gib=ch["node_mem_gib"]))
    single = pools.get("single_node")
    if single and not single["fits"]:
        out.append(warn("single-node-hook-peak", "action", "Everything plus the largest hook Job does not fit the one node: Helm's hook Jobs run beside the pods and set the peak", requests_cpu=single["requests"]["cpu"], requests_mem_gib=single["requests"]["memory_gib"]))
    return out
