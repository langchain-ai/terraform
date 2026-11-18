"""The chart values a plan applies: one overlay that makes the chart run what the plan says.

Every workload's replicas, requests, limits and autoscaler, SmithDB's tier, topology and services,
the configuration the plan asks for (commonEnv, Redis's policy) and the switches that point the chart
at the stores that run outside it. Values the plan does not know (a secret's name, a bucket, an
endpoint) are left as `<placeholders>` to fill in, never invented. Credentials are never in it.
"""

from __future__ import annotations

import re
from collections.abc import Mapping
from typing import Any

import yaml

from langsmith_sizing.chart import Chart, merge
from langsmith_sizing.units import KIB, KILO

PLACEHOLDER = re.compile(r"^<[^<>]+>$")
SMITHDB_KEYS = {
    "query": "query", "ingestion": "ingestion", "compaction": "compaction", "compaction-worker": "compactionWorker",
    "cluster-manager": "clusterManager", "stats-query": "statsQuery", "mutations": "mutations", "smithdb": "unified",
}
SECRET_NOTE = "Credentials are not in this file: the license key, the API key salt, the auth secrets and the stores' passwords and access keys come from the install's own secrets."


def _set(values: dict[str, Any], path: str, value: Any) -> None:
    *head, last = path.split(".")
    node = values
    for part in head:
        node = node.setdefault(part, {})
    node[last] = value


def cpu_quantity(cores: float) -> str:
    return str(int(cores)) if cores == int(cores) else f"{round(cores * KILO)}m"


def memory_quantity(gib: float) -> str:
    return f"{int(gib)}Gi" if gib == int(gib) else f"{round(gib * KIB)}Mi"


def resources(requests: Mapping[str, float], limits: Mapping[str, float]) -> dict[str, Any]:
    return {k: {"cpu": cpu_quantity(v["cpu"]), "memory": memory_quantity(v["memory_gib"])} for k, v in (("requests", requests), ("limits", limits))}


def placeholder(what: str) -> str:
    """A value to fill in. No colon: the chart reads some values back as YAML, where `a: b` is a mapping."""
    return f"<{what}>"


_ph = placeholder


def placeholders(values: Any, path: str = "") -> list[str]:
    """The dotted paths whose value is a <placeholder> still to fill."""
    if isinstance(values, dict):
        return [p for k, v in values.items() for p in placeholders(v, f"{path}.{k}" if path else k)]
    if isinstance(values, list):
        return [p for i, v in enumerate(values) for p in placeholders(v, f"{path}[{i}]")]
    return [path] if isinstance(values, str) and PLACEHOLDER.match(values) else []


def to_yaml(values: Mapping[str, Any]) -> str:
    """The overlay as YAML, opening with what is left to fill."""
    todo = placeholders(values)
    head = ["# langsmith-sizing: chart values for this plan.", f"# {SECRET_NOTE}"]
    head += [f"# fill: {p}" for p in todo] or ["# nothing to fill"]
    return "\n".join(head) + "\n" + yaml.safe_dump(dict(values), sort_keys=True)


def _workloads(body: Mapping[str, Any], values: dict[str, Any], keys: Mapping[str, str], smithdb_keys: Mapping[str, str]) -> None:
    scale = body["scale"]
    for name, w in body["workloads"].items():
        key = keys[name]
        _set(values, f"{key}.deployment.resources", resources(w["requests"], w["limits"]))
        if scale.get(name, {}).get("applied", {}).get("kind", "none") == "none":
            _set(values, f"{key}.deployment.replicas", int(w["replicas"]))
    for name, c in body["smithdb"]["components"].items():
        if scale.get(f"smithdb-{name}", scale.get(name, {})).get("applied", {}).get("kind", "none") == "none":
            _set(values, f"smithdb.{smithdb_keys[name]}.deployment.replicas", int(c["replicas"]))
    for spec in scale.values():
        for path, value in spec["applied"]["values"].items():
            _set(values, path, value)


def _smithdb(body: Mapping[str, Any], values: dict[str, Any], chart: Chart) -> None:
    sdb, inp = body["smithdb"], body["inputs"]
    _set(values, "smithdb.enabled", True)
    _set(values, "smithdb.langsmith.ingestion.enabled", True)
    _set(values, "smithdb.langsmith.query.enabled", True)
    _set(values, "smithdb.resourceTier", sdb["tier"])
    if chart.at("smithdb.topology") is not None:
        _set(values, "smithdb.topology", sdb["topology"])
    if inp["trace_store"] == "smithdb":
        _set(values, "clickhouse.enabled", False)
    _set(values, "smithdb.config.existingSecretName", _ph("secret holding the SmithDB metastore and object store credentials"))
    for field in ("host", "database", "username", "password"):
        _set(values, f"smithdb.config.metastore.{field}SecretKey", _ph(f"secret key of the metastore {field}"))
    _set(values, "smithdb.config.objectStore.type", "s3")
    _set(values, "smithdb.config.objectStore.bucket", _ph("SmithDB bucket"))
    _set(values, "smithdb.config.objectStore.s3.region", _ph("bucket region"))
    if body["stores"]["object_storage"]["placement"] == "in-cluster":
        _set(values, "smithdb.config.objectStore.s3.endpoint", _ph("in-cluster object store endpoint"))


def _stores(body: Mapping[str, Any], values: dict[str, Any], chart: Chart) -> None:
    st, inp = body["stores"], body["inputs"]
    for store, key in (("postgres", "postgres"), ("redis", "redis")):
        spec = st[store]["spec"]
        if spec["placement"] == "external" or spec["placement"] == "operator":
            _set(values, f"{key}.external.enabled", True)
            # the chart reads a Redis cluster's node URIs and password from this same secret, under
            # redis.external.cluster.nodeUrisSecretKey and passwordSecretKey: it has no cluster secret
            # of its own, and a key it does not read once sat here and rendered nothing
            holds = "the Redis cluster node URIs and password" if store == "redis" and spec.get("instance", {}).get("cluster") else f"the {store} connection"
            _set(values, f"{key}.external.existingSecretName", _ph(f"secret holding {holds}"))
            continue
        pod = spec["per_instance"]
        _set(values, f"{key}.statefulSet.resources", resources(pod["requests"], pod["limits"]))
        _set(values, f"{key}.statefulSet.persistence.size", f"{int(pod['volume_gib'])}Gi")
    if spec_redis := st["redis"]["spec"]:
        if spec_redis["placement"] != "statefulset" and spec_redis.get("instance", {}).get("cluster"):
            _set(values, "redis.external.cluster.enabled", True)
    ch = st["clickhouse"]
    if ch:
        spec = ch["spec"]
        if spec["placement"] == "statefulset":
            pod = spec["per_instance"]
            _set(values, "clickhouse.statefulSet.resources", resources(pod["requests"], pod["limits"]))
            _set(values, "clickhouse.statefulSet.persistence.size", f"{int(pod['volume_gib'])}Gi")
        else:
            _set(values, "clickhouse.external.enabled", True)
            _set(values, "clickhouse.external.existingSecretName", _ph("secret holding the ClickHouse connection"))
    if inp["blob_storage"]:
        _set(values, "config.blobStorage.enabled", True)
        _set(values, "config.blobStorage.bucketName", _ph("LangSmith bucket"))
        _set(values, "config.blobStorage.apiURL", _ph("object store API URL"))
        if inp["offload_threshold_kib"] != chart.number("config.blobStorage.minBlobStorageSizeKb"):
            _set(values, "config.blobStorage.minBlobStorageSizeKb", str(inp["offload_threshold_kib"]))


def overlay(body: Mapping[str, Any], chart: Chart, keys: Mapping[str, str]) -> dict[str, Any]:
    """The values for a plan at a chart version. `keys` maps each workload's name to its chart key."""
    values: dict[str, Any] = {}
    _smithdb(body, values, chart)
    _workloads(body, values, keys, SMITHDB_KEYS)
    for path, value in body["configure"]["values"].items():
        _set(values, path, value)
    _stores(body, values, chart)
    # Every product switched on or off: Insights and Chat are on in the chart by default, and an
    # install that set their keys ran eight pods no plan had counted.
    return merge(values, body["products"]["values"])
