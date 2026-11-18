"""The values overlay does what the plan says: the chart rendered with it runs the plan's replicas,
requests and limits, and points at the stores the plan placed outside the cluster.

Two directions, over many plans on both charts. Every figure the plan sized is found in the render
(pods, in-cluster stores, the offload threshold, the Redis cluster flag), and every key the overlay
sets is found there too: a key nothing in the render shows is proved to do something by taking it out
and rendering again, so an overlay key the chart ignores fails. A key no check claims fails as well.
"""

import copy
import re
import unittest
from functools import cache
from typing import Any

from langsmith_sizing import PLANNED_CHARTS, citations, params, plan, presets, values
from langsmith_sizing import chart as chart_mod
from langsmith_sizing.chart import SMITHDB_RENDERABLE, cpu, gib, merge
from langsmith_sizing.model import products
from tests.helpers import CHART, chart_at, chart_or_skip, needs_helm

CHARTS = PLANNED_CHARTS


def _switches(node: Any, path: str, product: str, out: dict[str, str]) -> None:
    for k, v in (node or {}).items():
        here = f"{path}.{k}" if path else k
        if k == "enabled":
            out[here] = product
        elif isinstance(v, dict):
            _switches(v, here, product, out)


PRODUCT_SWITCHES: dict[str, str] = {}
"""Each product's `enabled` key, dotted, to the product it switches."""
for _name, _spec in products.catalog().items():
    _switches(_spec.get("enable"), "", _name, PRODUCT_SWITCHES)
NEXT = CHARTS[1]
SCENARIOS: dict[str, tuple[str, dict[str, Any]]] = {
    **{name: (name, {}) for name in presets.names()},
    "node-loss-and-dual-replicated": ("production", {"trace_store": "dual-replicated", "survives_node_loss": True}),
    "dual": ("production", {"trace_store": "dual"}),
    "dual-replicated": ("production", {"trace_store": "dual-replicated"}),
    "dual-replicated-operator-clickhouse": ("production", {"trace_store": "dual-replicated", "clickhouse": "operator"}),
    "dual-external-clickhouse": ("production", {"trace_store": "dual-replicated", "clickhouse": "external"}),
    "offload-threshold-50": ("production", {"offload_threshold_kib": 50}),
    "blob-storage-off": ("production", {"blob_storage": False}),
    "redis-cluster-external": ("production-large", {}),
    "operators-and-node-loss": ("production", {"redis": "operator", "postgres": "operator", "survives_node_loss": True}),
    "in-cluster-stores": ("production", {"redis": "statefulset", "postgres": "statefulset", "smithdb_metastore": "statefulset", "object_store": "in-cluster"}),
    "extra-lite-unified": ("extra-lite", {"smithdb_topology": "unified"}),
}
ONLY_NEXT = {"extra-lite-unified"}
"""Unified is a chart 0.18 setting."""


def sized(preset: str, version: str, **overrides: Any) -> dict[str, Any]:
    return plan.size(presets.load(preset).to_inputs(version, **overrides), chart_at(version), params.load(), citations.load())


def kebab(key: str) -> str:
    """A values key as the chart names its Deployment: smithdb.statsQuery -> smithdb-stats-query."""
    return re.sub(r"(?<!^)(?=[A-Z])", "-", key.replace(".", "-")).lower()


def leaves(node: Any, path: tuple[str, ...] = ()) -> list[tuple[str, Any]]:
    """The overlay's settings as (dotted key, value); a list is one setting."""
    if isinstance(node, dict):
        return [leaf for k, v in node.items() for leaf in leaves(v, (*path, k))]
    return [(".".join(path), node)]


def without(overlay: dict[str, Any], path: str) -> dict[str, Any]:
    out = copy.deepcopy(overlay)
    *head, last = path.split(".")
    nodes = [out]
    for part in head:
        nodes.append(nodes[-1][part])
    del nodes[-1][last]
    for parent, part in zip(reversed(nodes[:-1]), reversed(head), strict=True):
        if not parent[part]:
            del parent[part]
    return out


@cache
def rendered(version: str, label: str) -> "Render":
    preset, overrides = SCENARIOS[label]
    return Render(version, sized(preset, version, **overrides))


class Render:
    """A plan's overlay rendered on its chart, with the lookups the checks share."""

    def __init__(self, version: str, p: dict[str, Any]) -> None:
        self.version, self.p = version, p
        self.chart = chart_at(version)
        self.docs = self.chart.render(p["values"])
        self.pods = self.chart.pods(p["values"])
        self.scalers = chart_mod.autoscalers(self.docs)
        self.by_workload = {v["workload"]: v for v in self.pods.values()}
        self.sets = {d["metadata"]["name"]: d for d in self.docs if d["kind"] == "StatefulSet"}

    def pod(self, key: str) -> dict[str, Any] | None:
        """The rendered pod for a values key, None where the chart renders none (a switched-off service).
        The unified SmithDB pod is the chart's `smithdb` Deployment."""
        name = "smithdb" if key == "smithdb.unified" else kebab(key)
        return self.by_workload.get(f"langsmith-{name}")

    def env_values(self, name: str) -> set[Any]:
        return {pod["env"][name] for pod in self.pods.values() if name in pod["env"]}

    def claim(self, store: str) -> float:
        claim = self.sets[f"langsmith-{store}"]["spec"]["volumeClaimTemplates"][0]["spec"]["resources"]["requests"]["storage"]
        return gib(claim)

    def figure(self, pod: dict[str, Any], kind: str, resource: str) -> float:
        return float(pod[kind]["cpu" if resource == "cpu" else "memory_gib"])

    def applied(self, path: str, value: Any) -> str | None:
        """None when the render shows the key at its value, a message when it does not, NotImplemented
        when no check here claims the key."""
        m = re.fullmatch(r"(?P<k>.+)\.deployment\.resources\.(?P<kind>requests|limits)\.(?P<res>cpu|memory)", path)
        if m:
            want = cpu(value) if m["res"] == "cpu" else gib(value)
            pod = self.pod(m["k"])
            if pod is None:
                return f"{m['k']} is not rendered"
            got = self.figure(pod, m["kind"], m["res"])
            return None if abs(got - want) < 1e-6 else f"renders {got:g}, overlay says {want:g}"
        m = re.fullmatch(r"(?P<k>.+)\.deployment\.replicas", path)
        if m:
            pod = self.pod(m["k"])
            if pod is None:
                return f"{m['k']} is not rendered"
            return None if pod["replicas"] == value else f"renders {pod['replicas']} replicas, overlay says {value}"
        m = re.fullmatch(r"(?P<k>.+)\.autoscaling\.(?P<kind>hpa|keda)\.(?P<f>enabled|minReplicas|minReplicaCount|maxReplicas|maxReplicaCount)", path)
        if m:
            pod = self.pod(m["k"])
            scaler = pod["scaler"] if pod else None
            if m["f"] == "enabled":
                have = bool(scaler) and scaler["kind"] == m["kind"]
                return None if have == value else f"{m['kind']} is {'on' if have else 'off'} in the render, overlay says {value}"
            if not scaler or scaler["kind"] != m["kind"]:
                return f"no {m['kind']} autoscaler is rendered for it"
            got = scaler["min" if m["f"].startswith("min") else "max"]
            return None if got == value else f"renders {got}, overlay says {value}"
        m = re.fullmatch(r"(?P<s>postgres|redis|clickhouse)\.statefulSet\.resources\.(?P<kind>requests|limits)\.(?P<res>cpu|memory)", path)
        if m:
            want = cpu(value) if m["res"] == "cpu" else gib(value)
            got = self.figure(self.pods[m["s"]], m["kind"], m["res"])
            return None if abs(got - want) < 1e-6 else f"renders {got:g}, overlay says {want:g}"
        m = re.fullmatch(r"(?P<s>postgres|redis|clickhouse)\.statefulSet\.persistence\.size", path)
        if m:
            return None if abs(self.claim(m["s"]) - gib(value)) < 1e-6 else f"renders a {self.claim(m['s']):g} GiB volume, overlay says {value}"
        if path == "redis.statefulSet.command":
            got = self.sets["langsmith-redis"]["spec"]["template"]["spec"]["containers"][0].get("command")
            return None if got == value else f"renders command {got}, overlay says {value}"
        m = re.fullmatch(r"(?P<s>postgres|redis|clickhouse)\.external\.enabled", path)
        if m:
            return None if (m["s"] not in self.pods) == value else f"{m['s']} is {'still' if m['s'] in self.pods else 'not'} rendered in the cluster"
        if path == "clickhouse.enabled":
            return None if ("clickhouse" in self.pods) == value else "the ClickHouse pod is rendered or missing against the switch"
        m = re.fullmatch(r"smithdb\.(?P<c>statsQuery|mutations)\.enabled", path)
        if m:
            name = {"statsQuery": "stats-query", "mutations": "mutations"}[m["c"]]
            return None if (name in self.pods) == value else f"{name} is {'rendered' if name in self.pods else 'missing'} against the switch"
        if path == "redis.external.cluster.enabled":
            return None if self.env_values("REDIS_CLUSTER_ENABLED") == {"true"} else f"REDIS_CLUSTER_ENABLED renders {self.env_values('REDIS_CLUSTER_ENABLED')}"
        if path == "config.blobStorage.enabled":
            return None if self.env_values("FF_BLOB_STORAGE_ENABLED") == {"true"} else f"FF_BLOB_STORAGE_ENABLED renders {self.env_values('FF_BLOB_STORAGE_ENABLED')}"
        if path == "config.blobStorage.minBlobStorageSizeKb":
            return None if self.env_values("MIN_BLOB_STORAGE_SIZE_KB") == {str(value)} else f"MIN_BLOB_STORAGE_SIZE_KB renders {self.env_values('MIN_BLOB_STORAGE_SIZE_KB')}"
        if path == "commonEnv":
            have = [(e["name"], e["value"], {pod["env"].get(e["name"]) for pod in self.pods.values()}) for e in value]
            bad = [(n, v, seen) for n, v, seen in have if v not in seen]
            return None if not bad else f"not in any pod's environment: {bad}"
        if path in PRODUCT_SWITCHES and value is False:
            return self.switched_off(PRODUCT_SWITCHES[path])
        if path == "smithdb.resourceTier":
            topology = self.p["values"]["smithdb"].get("topology")
            alone = self.chart.pods({"smithdb": merge(SMITHDB_RENDERABLE, {"resourceTier": value} | ({"topology": topology} if topology else {}))})
            name = next(iter(self.p["smithdb"]["components"]))
            return None if alone[name]["requests"] == self.pods[name]["requests"] else f"{name} does not render the {value} tier's requests"
        return NotImplemented

    def switched_off(self, product: str) -> str | None:
        """A product's switch set false is shown by the render when on renders its pods and off none.
        The renderer's own stand-ins already turn Insights and Chat off, so taking the key out of the
        overlay proves nothing here; turning the product on does."""
        cat = products.catalog()
        def owned(overlay: dict[str, Any]) -> list[str]:
            return sorted(products.rendered_pods(self.chart.render(overlay), [product], cat))
        with_needs, _ = products.chosen([product], cat)
        on = merge(merge(self.p["values"], products.values(with_needs, cat, params.values(params.load()), values.placeholder)), products.renderable(with_needs, cat))
        if not owned(on):
            return f"{product} on renders none of its pods"
        left = owned(merge(self.p["values"], self.p["products"]["render"]))
        return None if not left else f"{product} is off and still renders {left}"

    def verdict(self, path: str, value: Any, overlay: dict[str, Any] | None = None) -> str | None:
        """None when the key is shown by the render. A key no check claims is shown if taking it out
        of the overlay changes the render, unless it is the chart's own default."""
        overlay = self.p["values"] if overlay is None else overlay
        found = self.applied(path, value)
        if found is not NotImplemented:
            return found
        if self.chart.at(path) == value:
            return None
        try:
            changed = self.chart.render(without(overlay, path)) != self.chart.render(overlay)
        except chart_mod.ChartError:
            return None  # the chart's own validation refuses the overlay without it: it is needed
        return None if changed else "taking it out changes nothing in the render"


@needs_helm
class RenderedMatchesPlan(unittest.TestCase):
    def scenarios(self) -> list[tuple[str, str, str]]:
        return [(f"{label}@{v}", v, label) for label in SCENARIOS for v in CHARTS if v == NEXT or label not in ONLY_NEXT]

    def render(self, version: str, label: str) -> Render:
        chart_or_skip(self, version)
        return rendered(version, label)

    def test_every_pod_the_plan_sizes_renders_at_its_figures(self) -> None:
        for name, version, label in self.scenarios():
            with self.subTest(name):
                r = self.render(version, label)
                sized_pods = {**r.p["workloads"], **r.p["smithdb"]["components"]}
                self.assertGreaterEqual(len(sized_pods), 8)
                for name, want in sized_pods.items():
                    self.assertIn(name, r.pods, name)
                    got = r.pods[name]
                    for kind in ("requests", "limits"):
                        for k in ("cpu", "memory_gib"):
                            self.assertAlmostEqual(got[kind][k], want[kind][k], msg=f"{name} {kind}.{k}")
                    applied = r.p["scale"].get(name, r.p["scale"].get(f"smithdb-{name}", {})).get("applied", {"kind": "none"})
                    if applied["kind"] == "none":
                        self.assertIsNone(got["scaler"], name)
                        self.assertEqual(got["replicas"], want["replicas"], name)
                    else:
                        self.assertEqual((got["scaler"]["kind"], got["scaler"]["min"], got["scaler"]["max"]), (applied["kind"], applied["min"], applied["max"]), name)
                        self.assertEqual(applied["min"], want["min"], name)
                self.assertEqual(set(r.pods) - {"postgres", "redis", "clickhouse"}, set(sized_pods))

    def test_every_store_the_cluster_runs_gets_the_specs_resources_and_volume(self) -> None:
        ran: set[str] = set()
        for name, version, label in self.scenarios():
            with self.subTest(name):
                r = self.render(version, label)
                for store in ("postgres", "redis", "clickhouse"):
                    entry = r.p["stores"][store]
                    if not entry or entry["spec"]["placement"] != "statefulset":
                        self.assertNotIn(store, r.pods, f"{store} is rendered though the plan placed it outside the cluster")
                        continue
                    ran.add(store)
                    pod = entry["spec"]["per_instance"]
                    got = r.pods[store]
                    for kind in ("requests", "limits"):
                        for k in ("cpu", "memory_gib"):
                            self.assertAlmostEqual(got[kind][k], pod[kind][k], msg=f"{store} {kind}.{k}")
                    self.assertAlmostEqual(r.claim(store), pod["volume_gib"], msg=f"{store} volume")
        self.assertEqual(ran, {"postgres", "redis", "clickhouse"})

    def test_the_offload_threshold_and_the_blob_switch_reach_the_environment(self) -> None:
        seen = set()
        for name, version, label in self.scenarios():
            with self.subTest(name):
                r = self.render(version, label)
                inputs = r.p["inputs"]
                # the chart renders the switch only when it is on
                self.assertEqual("true" in r.env_values("FF_BLOB_STORAGE_ENABLED"), inputs["blob_storage"])
                if inputs["blob_storage"]:
                    threshold = r.env_values("MIN_BLOB_STORAGE_SIZE_KB")
                    self.assertEqual(threshold, {str(int(inputs["offload_threshold_kib"]))})
                    seen.add(next(iter(threshold)))
        self.assertGreaterEqual(len(seen), 2)  # the chart's default and a non-default threshold both ran

    def test_a_redis_cluster_is_switched_on_where_the_plan_runs_one(self) -> None:
        flags = []
        for name, version, label in self.scenarios():
            with self.subTest(name):
                r = self.render(version, label)
                redis = r.p["stores"]["redis"]
                cluster = redis["spec"]["placement"] != "statefulset" and bool(redis["spec"].get("instance", {}).get("cluster"))
                got = r.env_values("REDIS_CLUSTER_ENABLED") == {"true"}
                self.assertEqual(got, cluster)
                flags.append(got)
        self.assertIn(True, flags)
        self.assertIn(False, flags)

    def test_the_trace_store_decides_whether_clickhouse_runs(self) -> None:
        for name, version, label in self.scenarios():
            with self.subTest(name):
                r = self.render(version, label)
                dual = r.p["inputs"]["trace_store"] != "smithdb"
                in_cluster = dual and r.p["stores"]["clickhouse"]["spec"]["placement"] == "statefulset"
                self.assertEqual("clickhouse" in r.pods, in_cluster)

    def test_every_key_the_overlay_sets_is_shown_by_the_render(self) -> None:
        checked = 0
        for name, version, label in self.scenarios():
            with self.subTest(name):
                r = self.render(version, label)
                for path, value in leaves(r.p["values"]):
                    verdict = r.verdict(path, value)
                    self.assertIsNone(verdict, f"{path}: {verdict}")
                    checked += 1
        self.assertGreater(checked, 2000)

    def test_a_key_the_render_ignores_is_caught(self) -> None:
        r = self.render(CHARTS[0], "production")
        bogus = merge(r.p["values"], {"frontend": {"deployment": {"nonsense": 3}}})
        self.assertIn("changes nothing", r.verdict("frontend.deployment.nonsense", 3, bogus) or "")
        self.assertIn("renders", r.verdict("frontend.deployment.resources.requests.cpu", "9") or "")
        self.assertIn("renders", r.verdict("platformBackend.autoscaling.hpa.maxReplicas", 99) or "")

    def test_stores_outside_the_cluster_are_switched_on_and_left_to_fill(self) -> None:
        p = sized("production", CHART)
        v = p["values"]
        self.assertTrue(v["postgres"]["external"]["enabled"] and v["redis"]["external"]["enabled"])
        r = Render(CHART, p)
        self.assertFalse({"postgres", "redis"} & set(r.pods))
        todo = values.placeholders(v)
        self.assertIn("postgres.external.existingSecretName", todo)
        self.assertIn("smithdb.config.objectStore.bucket", todo)
        self.assertGreater(len(todo), 8)
        self.assertEqual(len([t for t in todo if t.startswith("smithdb.config.metastore.")]), 4)
        text = values.to_yaml(v)
        self.assertIn("# fill: smithdb.config.objectStore.bucket", text)
        self.assertNotIn("password:", text.lower().replace("passwordsecretkey", ""))
        placeholders_in_overlay = {path for path, value in leaves(v) if isinstance(value, str) and value.startswith("<")}
        self.assertEqual(placeholders_in_overlay, set(todo))

    def test_a_clickhouse_cluster_is_switched_to_external(self) -> None:
        p = sized("production", CHART, trace_store="dual-replicated", clickhouse="external")
        self.assertTrue(p["values"]["clickhouse"]["external"]["enabled"])
        self.assertEqual(p["stores"]["clickhouse"]["spec"]["instance"]["nodes"], 3)
        self.assertNotIn("statefulSet", p["values"]["clickhouse"])
        self.assertNotIn("clickhouse", Render(CHART, p).pods)


class Helpers(unittest.TestCase):
    def test_a_values_key_is_the_charts_deployment_name(self) -> None:
        self.assertEqual([kebab(k) for k in ("platformBackend", "smithdb.statsQuery", "smithdb.clusterManager", "aceBackend")], ["platform-backend", "smithdb-stats-query", "smithdb-cluster-manager", "ace-backend"])

    def test_without_removes_a_key_and_the_empty_branches_above_it(self) -> None:
        self.assertEqual(without({"a": {"b": {"c": 1}}, "d": 2}, "a.b.c"), {"d": 2})
        self.assertEqual(without({"a": {"b": 1, "c": 2}}, "a.b"), {"a": {"c": 2}})

    def test_a_list_is_one_setting(self) -> None:
        self.assertEqual(leaves({"a": {"b": [1, 2]}, "c": 3}), [("a.b", [1, 2]), ("c", 3)])


if __name__ == "__main__":
    unittest.main()
