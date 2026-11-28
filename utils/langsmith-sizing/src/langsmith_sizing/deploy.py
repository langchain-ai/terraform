"""The deployable half of a plan: each store's spec for where it runs, the namespace totals, the
node pools and the chart values that apply it.

`assemble` adds to a plan that has been sized: the stores' `placement` and `spec`, `totals`, `pools`
and `values`. Totals and pools are what the chart values run, at the autoscalers' floors, at the
sized replicas and at their ceilings, with the hook Jobs' peak on top.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from langsmith_sizing import values as values_mod
from langsmith_sizing.chart import Chart, gib, hook_jobs, merge
from langsmith_sizing.model import datastores as ds
from langsmith_sizing.model import lite, watch
from langsmith_sizing.model import totals as tot
from langsmith_sizing.model.watch import warn


def _entry(name: str, pool: str, e: Mapping[str, Any], volume_gib: float | None = None) -> dict[str, Any]:
    return {
        "name": name, "pool": pool, "requests": e["requests"], "limits": e["limits"], "volume_gib": volume_gib or 0,
        "replicas": {"min": e["min"], "sized": e["replicas"], "max": e["max"]},
    }


def _shape(given: tuple[float, float] | None, default: Mapping[str, float], param: str) -> tuple[dict[str, float], str]:
    if given is None:
        return {"cpu": default["cpu"], "memory_gib": default["memory_gib"]}, f"param:{param}"
    return {"cpu": given[0], "memory_gib": given[1]}, "input"


def _stores(body: dict[str, Any], r: Mapping[str, Any], p: Mapping[str, Any], cited: Any, chart: Chart, pods: Mapping[str, Any], node: Mapping[str, float]) -> None:
    """Each store's placement and spec. In the extra-lite regime an in-cluster store asks what it was
    measured to use (params lite.measured), not the managed service's size."""
    st, survives, counts = body["stores"], r["survives_node_loss"], p["datastores.operator_instances"]
    docs = cited["scale.postgres"]
    lm = p["lite.measured"] if body["regime"]["requests_from_measured"] else None

    def measured(store: str, spec: dict[str, Any]) -> dict[str, Any]:
        if lm is None or "per_instance" not in spec:
            return spec
        rq = lite.request(lm["stores"][store], runs_per_second=body["rates"]["runs_per_second_peak"], readers=r["users"], headroom=lm["headroom"], min_cpu=lm["min_cpu"], memory_headroom=lm["memory_headroom"])
        one = spec["per_instance"]
        return spec | {"per_instance": one | {"requests": rq, "limits": lite.at_least(one["limits"], rq)}}

    pg, place = st["postgres"], r["postgres"]
    pg["placement"] = place
    pg["spec"] = (
        ds.external(ds.postgres_instance(docs, r["postgres_memory_gib"], pg["max_connections"], pg["budget"])) if place == "external"
        else measured("postgres", ds.in_cluster(place, ds.postgres_pod(pods["postgres"]["requests"], pods["postgres"]["limits"], docs), ds.instances(place, survives, counts)))
    )

    rd, place = st["redis"], r["redis"]
    mem = rd["memory_gi"]
    if place == "external":
        shards = ds.redis_shards(rd["cluster"], rd["cpu_shards"], mem, p["redis.single_node_max_gb"])
        rd["spec"] = ds.external(ds.redis_instance(pods["redis"]["requests"]["cpu"], mem, shards, rd["queue_partitions"], rd["maxmemory_policy"]))
    else:
        n = ds.instances(place, survives, counts)
        pod = ds.redis_pod(pods["redis"]["requests"], pods["redis"]["limits"], gib(chart.at("redis.statefulSet.persistence.size")), mem, p["datastores.redis_maxmemory_share"])
        rd["spec"] = ds.in_cluster(place, pod, n, [ds.redis_sentinels(p["datastores.redis_sentinel"])] if place == "operator" and n > 1 else [])

    tier = body["smithdb"]["tier"]
    place = r["smithdb_metastore"]
    row, disk = cited["smithdb.metastore"][tier], p["smithdb.metastore_disk_gib"]
    st["smithdb_metastore"] = {
        "placement": place, "tier": tier, "postgres_min_major_version": body["smithdb"]["metastore"]["postgres_min_major_version"],
        "spec": ds.external(ds.metastore_instance(row, disk)) if place == "external"
        else measured("smithdb_metastore", ds.in_cluster(place, ds.metastore_pod(row, disk, p["datastores.limit_factor"]), ds.instances(place, survives, counts))),
    }

    obj = st["object_storage"]
    obj["placement"] = r["object_store"]
    buckets = ds.bucket_instance(obj, r["blob_storage"], r["retention_days"], obj["extended_days"], obj["extended_share"])
    obj["spec"] = ds.external(buckets) if r["object_store"] == "external" else measured("object_store", ds.in_cluster("in-cluster", ds.object_store_pod(p["datastores.object_store_pod"][tier], obj["total_tb"]), 1)) | {"buckets": buckets}

    ch = st["clickhouse"]
    if ch:
        place = r["clickhouse"]
        ch["placement"] = place
        ch["spec"] = (
            ds.external(ds.clickhouse_instance(ch["nodes"], ch["requests_per_node"], ch["storage_gi_per_node"])) if place == "external"
            else ds.in_cluster(place, ds.clickhouse_pod(ch["requests_per_node"], pods["clickhouse"]["limits"], ch["storage_gi_per_node"]), ch["nodes"])
        )
        if place != "external":
            rq = ch["requests_per_node"]
            fit = tot.clickhouse_node(rq["cpu"], rq["memory_gib"], p["pools.clickhouse_node_shapes"])
            ch |= {"fits_app_node": tot.fits(rq["cpu"], rq["memory_gib"], node), "node_cpu": fit["cpu"], "node_mem_gib": fit["memory_gib"]}
        else:
            ch |= {"fits_app_node": None, "node_cpu": None, "node_mem_gib": None}


def _store_pods(st: Mapping[str, Any], datastores_on: str) -> list[dict[str, Any]]:
    """Every pod the cluster runs for a store: the store's own, then its extras (Redis Sentinel)."""
    out, pool = [], "app" if datastores_on == "app" else "datastores"
    for key, store in st.items():
        if not store or store["spec"]["placement"] == "external":
            continue
        spec = store["spec"]
        for name, count, pod in [(key.replace("_", "-"), spec["instances"], spec["per_instance"])] + [(e["name"], e["instances"], e["per_instance"]) for e in spec["extra"]]:
            out.append({"name": name, "pool": pool, "requests": pod["requests"], "limits": pod["limits"], "volume_gib": pod["volume_gib"], "replicas": dict.fromkeys(("min", "sized", "max"), count)})
    return out


def _entries(body: Mapping[str, Any]) -> list[dict[str, Any]]:
    """Every pod the plan sizes with the pool it runs on."""
    out = [_entry(n, "app", w) for n, w in body["workloads"].items()]
    unified = body["smithdb"]["topology"] == "unified"
    for n, c in body["smithdb"]["components"].items():
        out.append(_entry(n if unified else f"smithdb-{n}", "smithdb", c, c["cache_gib"]))
    for n, x in body["products"]["pods"].items():
        out.append(_entry(n, x.get("pool", "app"), x))
    return out + _store_pods(body["stores"], body["inputs"]["datastores_on"])


def _pools(entries: list[dict[str, Any]], floors: Mapping[str, int], nodes: Mapping[str, tuple[dict[str, float], str]], overhead: float) -> dict[str, Any]:
    """Each pool that holds a pod."""
    return {name: tot.pool(held, node, floors[name], overhead, node_from)
            for name, (node, node_from) in nodes.items() if (held := [e for e in entries if e["pool"] == name])}


def assemble(body: dict[str, Any], *, p: Mapping[str, Any], cited: Any, chart: Chart, pods: Mapping[str, Any], keys: Mapping[str, str], prov: Any) -> None:
    r = body["inputs"]
    overhead, tier = p["pools.overhead"], body["smithdb"]["tier"]
    app_node, app_from = _shape(r["app_node"], p["pools.app_node"], "pools.app_node")
    sdb_node, sdb_from = _shape(r["smithdb_node"], p["pools.smithdb_node"][tier], f"pools.smithdb_node.{tier}")
    ds_node, ds_from = _shape(r["datastore_node"], app_node, "pools.app_node")
    landing = ds_node if r["datastores_on"] == "dedicated" else app_node
    _stores(body, r, p, cited, chart, pods, landing)

    prov("stores", "param:datastores.operator_instances", "param:datastores.limit_factor", "param:datastores.redis_maxmemory_share", "param:datastores.redis_sentinel", "param:datastores.object_store_pod", "docs:scale.postgres", "chart:postgres.statefulSet.resources", "chart:redis.statefulSet.resources", "chart:redis.statefulSet.persistence.size", "chart:clickhouse.statefulSet.resources")
    prov("stores.smithdb_metastore", "docs:smithdb.metastore", "param:smithdb.metastore_disk_gib", "param:datastores.limit_factor", "input:smithdb_metastore")
    values = values_mod.overlay(body, chart, keys)
    body["values"] = values
    prov("values", "derived:workloads", "derived:smithdb", "derived:scale", "derived:configure", "derived:stores", "chart:autoscaling")

    entries = _entries(body)
    stored = [e for e in entries if e["pool"] == "datastores"]
    floors = {"app": p["pools.app_min_nodes"], "smithdb": p["pools.smithdb_min_nodes"], "datastores": max(p["pools.datastores_min_nodes"], *(e["replicas"]["sized"] for e in stored), 0)}
    nodes = {"app": (app_node, app_from), "smithdb": (sdb_node, sdb_from), "datastores": (ds_node, ds_from)}
    sandboxes = body["products"].get("sandboxes")
    if sandboxes:
        nodes["sandboxes"] = (sandboxes["node"], sandboxes["node_from"])
        floors["sandboxes"] = sandboxes["min_hosts"]
    pools = _pools(entries, floors, nodes, overhead)
    if sandboxes:
        # One host pod a node (pod anti-affinity): the pool is as many nodes as hosts, whatever they ask.
        sb = pools["sandboxes"]
        for phase, n in (("floor", sandboxes["min_hosts"]), ("sized", sandboxes["hosts"]), ("ceiling", sandboxes["hosts"])):
            sb[phase]["nodes"] = n
        sb["one_pod_a_node"] = True
        juicefs = p["sandboxes.juicefs_redis"]
        body["stores"]["sandboxes_juicefs_redis"] = {"placement": "external", "spec": {"placement": "external", "instance": {
            "vcpu": juicefs["cpu"], "memory_gib": juicefs["memory_gib"], "maxmemory_policy": cited["sandboxes.juicefs_redis"]["maxmemory_policy"], "dedicated": True}}}
        prov("stores.sandboxes_juicefs_redis", "param:sandboxes.juicefs_redis", "docs:sandboxes.juicefs_redis")

    sums = {name: tot.pod_sum(entries, which) for name, which in tot.PHASES.items()}
    # The products' keys and URLs are <placeholders> in the values; their stand-ins let the chart render.
    jobs = hook_jobs(chart.render(merge(values, body["products"]["render"])))
    body["totals"] = {"overhead": overhead, **sums, "hooks": {"base": "ceiling", "jobs": jobs, "peak": tot.hook_peak(jobs, sums["ceiling"])}}
    if body["regime"]["turns_on"].get("one_node"):
        peak = tot.hook_peak(jobs, sums["sized"])
        rq = peak["requests"]
        pools["single_node"] = {
            "node_cpu": app_node["cpu"], "node_mem_gib": app_node["memory_gib"], "hook_job": peak["job"], "requests": rq,
            "cpu": rq["cpu"] * overhead, "mem_gib": rq["memory_gib"] * overhead, "fits": tot.fits(rq["cpu"] * overhead, rq["memory_gib"] * overhead, app_node),
        }
    body["pools"] = pools
    body["warnings"] += watch.pool_warnings(body, pools)
    measured = p["datastores.object_store_measured_traces_per_second"]
    if r["object_store"] == "in-cluster" and body["rates"]["peak_traces_per_second"] > measured:
        body["warnings"].append(warn("object-store-unmeasured", "action", f"The in-cluster object store was measured only up to {measured:g} traces/s; past it no figure sizes it: use an external bucket or measure first"))
    prov("totals", "param:pools.overhead", "derived:workloads", "derived:smithdb", "derived:stores", "chart:hook-jobs")
    prov.extend("warnings", "param:datastores.object_store_measured_traces_per_second")
    prov("pools", "param:pools.overhead", "param:pools.app_node", "param:pools.smithdb_node", "param:pools.app_min_nodes", "param:pools.smithdb_min_nodes", "param:pools.datastores_min_nodes", "param:pools.clickhouse_node_shapes", "derived:totals")


def stores_json(body: Mapping[str, Any]) -> dict[str, Any]:
    """What to provision: each store's placement and spec, in-cluster instances included."""
    out = {k: {"placement": s["placement"], "spec": s["spec"]} for k, s in body["stores"].items() if s}
    return {"schema": 1, "chart": body["chart"], "stores": out, "smithdb_cache_volume": body["smithdb"]["cache_volume"], "warnings": [w for w in body["warnings"] if w["id"].startswith(("redis", "postgres", "object-store", "clickhouse"))]}
