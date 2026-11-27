"""A plan's provenance names the right sources for the figures it cites, on several plans.

Two checks. Specific figures name specific sources, written out here by hand from what the figure
is made of (Redis memory is the peak run rate, the payload, the expiry and the Redis parameters), so
a figure whose provenance is swapped for another source fails. And every parameter the sizing reads
is cited by some figure of the plan that read it, so a read that leaves no trace fails.
"""

import unittest
from typing import Any
from unittest import mock

from helpers import size
from langsmith_sizing import params, plan
from tests.helpers import needs_helm

REDIS = {
    "derived:payload", "derived:rates", "param:headroom.redis", "param:headroom.redis_untuned_expiry", "param:redis.runs_per_shard",
    "param:redis.alarm_pct", "param:redis.queue_partitions", "param:redis.single_node_max_gb", "param:redis.cluster_shard_cap",
    "param:redis.expiry_retry_hours", "param:redis.payload_trimmed_from", "param:redis.trimmed_kb_per_run", "param:redis.stall_hours", "docs:scale.redis_gib", "chart:config.settings.redisRunsExpirySeconds", "chart:redis.statefulSet.resources",
}
EVERY_PLAN = {
    "stores.redis": REDIS,
    "stores.postgres": {"param:postgres.pool_api_pod", "param:postgres.connection_budget", "param:postgres.max_connections_in_cluster", "chart:queue.env.ASYNCPG_POOL_MAX_SIZE", "docs:scale.postgres", "derived:workloads"},
    "stores.object_storage": {"derived:payload", "param:headroom.storage", "param:retention.smithdb_delete_lag_days", "chart:config.ttl.ttl_period_seconds"},
    "stores.smithdb_metastore": {"docs:smithdb.metastore", "input:smithdb_metastore"},
    "workloads.platform-backend": {"derived:payload", "param:go.min_cpu_limit", "chart:platformBackend.deployment.replicas", "chart:platformBackend.deployment.resources", "docs:scale.replicas.platform_backend"},
    "workloads.ingest-queue": {"derived:ingest", "param:ingest.pod_cpu", "param:ingest.pod_memory_gib"},
    "workloads.frontend": {"docs:scale.replicas.frontend", "docs:scale.read_anchors", "chart:frontend.deployment.resources"},
    "workloads.queue": {"chart:queue.deployment.replicas", "chart:queue.deployment.resources"},
    "ingest": {"param:ingest.runs_per_core_points", "param:ingest.cpu_headroom", "param:ingest.min_pods", "param:keda.max_factor", "param:keda.round_to", "derived:rates", "derived:payload"},
    "payload": {"param:payload.bucket_kib", "param:payload.smithdb_kb_per_run", "param:payload.blob_kb_per_run", "param:payload.redis_kb_per_run", "param:payload.partial_inline_share", "input:payload_mix", "chart:config.blobStorage.minBlobStorageSizeKb"},
    "rates": {"input:traces", "param:load.runs_per_trace", "param:load.peak_factor", "param:time.seconds_per_month", "param:time.seconds_per_year"},
    "rates.beyond_payload_tested": {"param:payload.tested_traces_per_second"},
    "smithdb.auto": {"param:smithdb.peak_runs_bands", "docs:smithdb.tested_qps", "docs:scale.read_anchors", "derived:rates"},
    "regime": {"param:regimes", "param:smithdb.peak_runs_bands", "derived:rates", "input:survives_node_loss"},
    "pools": {"param:pools.overhead", "param:pools.app_node", "param:pools.app_min_nodes", "derived:totals"},
    "inputs.runs_per_trace": {"param:load.runs_per_trace", "param:inputs.limits"},
    "inputs.retention_days": {"chart:config.ttl.ttl_period_seconds.shortlived"},
    "inputs.extended_retention_days": {"chart:config.ttl.ttl_period_seconds.longlived"},
    "inputs.redis_expiry_seconds": {"chart:config.settings.redisRunsExpirySeconds"},
    "inputs.offload_threshold_kib": {"chart:config.blobStorage.minBlobStorageSizeKb", "param:inputs.limits"},
}
TIME = {"param:time.seconds_per_month", "param:time.seconds_per_year"}
PLANS: dict[str, dict[str, Any]] = {
    "default": {},
    "dual": {"trace_store": "dual"},
    "dual-replicated": {"trace_store": "dual-replicated"},
    "external-stores": {"redis": "external", "postgres": "external", "smithdb_metastore": "external", "object_store": "external"},
    "operators-and-node-loss": {"redis": "operator", "postgres": "operator", "survives_node_loss": True},
    "extra-lite": {"users": 2, "traces_per_second": 1, "peak_traces_per_second": 3, "object_store": "in-cluster"},
    "given-inputs": {"retention_days": 30, "offload_threshold_kib": 40, "redis_expiry_seconds": 7200, "runs_per_trace": 20},
}


def refs(p: dict[str, Any], path: str) -> set[str]:
    return set(p["provenance"][path]["from"])


@needs_helm
class Named(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.plans = {name: size(**kw) for name, kw in PLANS.items()}

    def test_the_figures_name_what_they_are_made_of_on_every_plan(self) -> None:
        for name, p in self.plans.items():
            for path, want in EVERY_PLAN.items():
                with self.subTest(plan=name, figure=path):
                    got = refs(p, path)
                    if name == "given-inputs" and path.startswith("inputs."):
                        want = want - {"chart:config.ttl.ttl_period_seconds.shortlived", "chart:config.settings.redisRunsExpirySeconds", "chart:config.blobStorage.minBlobStorageSizeKb", "param:load.runs_per_trace"}
                    self.assertLessEqual(want, got, f"missing {sorted(want - got)}")

    def test_redis_does_not_name_the_calendar(self) -> None:
        # the audit's counter-example pointed stores.redis at the seconds in a month
        for name, p in self.plans.items():
            self.assertFalse(TIME & refs(p, "stores.redis"), name)
            self.assertEqual(refs(p, "stores.redis"), REDIS, name)

    def test_a_given_input_names_the_input_and_a_defaulted_one_names_its_source(self) -> None:
        given = self.plans["given-inputs"]["provenance"]
        for field in ("retention_days", "offload_threshold_kib", "redis_expiry_seconds", "runs_per_trace"):
            self.assertIn(f"input:{field}", given[f"inputs.{field}"]["from"], field)
        for field, source in (("retention_days", "chart:config.ttl.ttl_period_seconds.shortlived"), ("redis_expiry_seconds", "chart:config.settings.redisRunsExpirySeconds")):
            self.assertEqual(self.plans["default"]["provenance"][f"inputs.{field}"]["from"], [source])
            self.assertNotIn(source, given[f"inputs.{field}"]["from"])

    def test_clickhouse_names_the_guide_and_the_chart_only_while_it_runs(self) -> None:
        self.assertNotIn("stores.clickhouse", self.plans["default"]["provenance"])
        for name in ("dual", "dual-replicated"):
            self.assertEqual(
                refs(self.plans[name], "stores.clickhouse"),
                {"docs:scale.clickhouse", "docs:scale.clickhouse_setup", "docs:scale.clickhouse_disk.high", "param:clickhouse.inline_payload_factor", "param:clickhouse.floor_gi_per_day", "param:clickhouse.floor_up_to_traces_per_second", "chart:clickhouse.statefulSet.persistence.size"},
                name,
            )

    def test_surviving_a_node_loss_adds_the_availability_floor_to_every_workload_and_smithdb(self) -> None:
        floor = "param:availability.min_replicas"
        for path in [f"workloads.{w}" for w in self.plans["operators-and-node-loss"]["workloads"]] + ["smithdb"]:
            self.assertIn(floor, refs(self.plans["operators-and-node-loss"], path), path)
            self.assertNotIn(floor, refs(self.plans["default"], path), path)

    def test_a_regime_that_fixes_the_replicas_names_the_regimes_on_each_workload_it_changed(self) -> None:
        small = self.plans["extra-lite"]
        self.assertEqual(small["regime"]["id"], "extra-lite")
        changed = [f"workloads.{w}" for w in small["workloads"]] + [f"smithdb.components.{c}" for c in small["smithdb"]["components"]]
        self.assertGreaterEqual(len(changed), 8)
        for path in changed:
            self.assertIn("param:regimes", refs(small, path), path)
            if path in self.plans["default"]["provenance"]:
                self.assertNotIn("param:regimes", refs(self.plans["default"], path), path)

    def test_smithdb_names_its_topology_by_what_decided_it(self) -> None:
        d = refs(self.plans["default"], "smithdb")
        self.assertEqual(self.plans["default"]["smithdb"]["topology"], "cluster")
        self.assertLessEqual({"chart:smithdb.resourceTier", "docs:smithdb.replicas.ingestion", "docs:smithdb.replicas.query", "param:smithdb.query_floor_replicas", "param:smithdb.splits_from_tier"}, d)
        self.assertNotIn("chart:smithdb.topology", d)

    def test_the_kind_and_the_parameter_source_follow_from_the_references(self) -> None:
        loaded = params.load()
        for name, p in self.plans.items():
            for path, entry in p["provenance"].items():
                families = {r.split(":", 1)[0] for r in entry["from"]}
                self.assertEqual(entry["kind"], families.pop() if len(families) == 1 else "derived", (name, path))
                if entry["kind"] == "param" and len(entry["from"]) == 1:
                    self.assertEqual(entry["param_source"], loaded[entry["from"][0].split(":", 1)[1]].source_kind, (name, path))
                else:
                    self.assertNotIn("param_source", entry, (name, path))

    def test_every_figure_of_a_given_single_run_size_has_a_source(self) -> None:
        p = size(single_run_kib=(4, 4))
        self.assertEqual(refs(p, "inputs.single_run_kib"), {"input:single_run_kib", "param:inputs.limits"})


@needs_helm
class Read(unittest.TestCase):
    def test_every_parameter_the_sizing_reads_is_cited_by_the_plan_that_read_it(self) -> None:
        seen: set[str] = set()

        class Reads(dict):  # type: ignore[type-arg]
            def __getitem__(self, key: str) -> Any:
                seen.add(key)
                return super().__getitem__(key)

        for name, kw in PLANS.items():
            seen.clear()
            with mock.patch.object(plan, "values", lambda loaded: Reads(params.values(loaded))):
                p = size(**kw)
            cited = {r.split(":", 1)[1] for e in p["provenance"].values() for r in e["from"] if r.startswith("param:")}
            self.assertGreater(len(seen), 40, name)
            self.assertEqual(seen - cited, set(), f"{name}: read and never cited")

    def test_the_instrument_sees_a_read_that_is_not_cited(self) -> None:
        seen: set[str] = set()

        class Reads(dict):  # type: ignore[type-arg]
            def __getitem__(self, key: str) -> Any:
                seen.add(key)
                return super().__getitem__(key)

        with mock.patch.object(plan, "values", lambda loaded: Reads(params.values(loaded))):
            p = size()
        p["provenance"]["stores.redis"]["from"] = ["param:time.seconds_per_month"]
        cited = {r.split(":", 1)[1] for e in p["provenance"].values() for r in e["from"] if r.startswith("param:")}
        self.assertIn("redis.runs_per_shard", seen - cited)


if __name__ == "__main__":
    unittest.main()
