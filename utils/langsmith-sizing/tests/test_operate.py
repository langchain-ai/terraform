"""The healthy-install parts of a plan: regime, scale, configure, watch and warnings."""

import unittest
from typing import Any

from helpers import CHART, P, chart_at, chart_or_skip, needs_helm, size
from langsmith_sizing import PLANNED_CHARTS, params
from langsmith_sizing.model import configure, regime, scale, watch

NEXT = PLANNED_CHARTS[-1]
VERSIONS = (CHART, NEXT)


def ids(items: list[dict[str, Any]]) -> list[str]:
    return [i["id"] for i in items]


def bands(peak_tps: float, peak: float, survives: bool = False) -> str:
    return regime.classify(P["regimes"], traces_per_second=peak_tps, peak_runs_per_second=peak, peak_bands=P["smithdb.peak_runs_bands"], peak_traces_per_second=peak_tps, facts={"survives_node_loss": survives})["id"]


class Regimes(unittest.TestCase):
    def test_boundaries(self) -> None:
        edge = P["smithdb.peak_runs_bands"]
        self.assertEqual([bands(t, 1) for t in (0, 5)], ["extra-lite"] * 2)
        self.assertEqual([bands(t, 1) for t in (5.01, 15)], ["lite"] * 2)
        self.assertEqual(bands(15.01, edge["medium"] - 1), "standard")
        self.assertEqual(bands(15.01, edge["medium"]), "large")
        self.assertEqual(bands(15.01, edge["large"] - 1), "large")
        self.assertEqual(bands(15.01, edge["large"]), "scale-out")
        self.assertEqual(bands(15.01, P["regimes"][0]["peak_runs_per_second_above"]), "scale-out")
        self.assertEqual(bands(15.01, P["regimes"][0]["peak_runs_per_second_above"] + 1), "beyond-tested")
        # one replica cannot survive a node's loss: that install is never extra-lite
        self.assertEqual(bands(1, 1, survives=True), "lite")

    def test_a_few_huge_traces_are_still_large(self) -> None:
        self.assertEqual(bands(1, P["smithdb.peak_runs_bands"]["medium"]), "large")

    def test_the_last_regime_has_no_bounds(self) -> None:
        last = P["regimes"][-1]
        self.assertEqual(set(last) & {"peak_band_min", "traces_per_second_max"}, set())

    def test_every_load_matches_a_regime_and_says_why(self) -> None:
        for tps in (0.1, 7, 12, 25, 80, 5000):
            r = regime.classify(P["regimes"], traces_per_second=tps, peak_runs_per_second=tps * 30, peak_bands=P["smithdb.peak_runs_bands"])
            self.assertTrue(r["why"] and r["about"] and "autoscalers" in r["turns_on"], tps)

    def test_only_the_lite_band_says_to_observe(self) -> None:
        # the lite regime's about says "not measured"; the others have a load test or the guide behind them
        def observe(peak_tps: float, peak_runs: float) -> bool:
            r = regime.classify(P["regimes"], traces_per_second=peak_tps, peak_runs_per_second=peak_runs, peak_bands=P["smithdb.peak_runs_bands"], peak_traces_per_second=peak_tps, facts={"survives_node_loss": False})
            return bool(r["observe"])

        self.assertEqual([observe(t, 10 * t) for t in (3, 10, 15)], [False, True, True])
        self.assertEqual([observe(t, 10 * t) for t in (50, 5000)], [False, False])
        self.assertFalse(observe(3, P["smithdb.peak_runs_bands"]["large"]))


@needs_helm
class InThePlan(unittest.TestCase):
    def test_regime_by_load(self) -> None:
        # the low regimes are read on the busiest rate, as their figures are
        got = {t: size(users=2, traces_per_second=t / 3, peak_traces_per_second=t)["regime"]["id"] for t in (3, 15, 50, 150)}
        self.assertEqual(got, {3: "extra-lite", 15: "lite", 50: "standard", 150: "large"})
        self.assertEqual(size(users=200, traces_per_second=5000)["regime"]["id"], "scale-out")
        self.assertEqual(size(users=200, traces_per_second=21000)["regime"]["id"], "beyond-tested")
        self.assertTrue(size(users=2, traces_per_second=3, peak_traces_per_second=10)["regime"]["observe"])


@needs_helm
class Scale(unittest.TestCase):
    def setUp(self) -> None:
        self.plans = {}
        for v in VERSIONS:
            chart_or_skip(self, v)
            self.plans[v] = size(chart_version=v)

    def test_smithdb_query_scales_on_cpu_only_and_the_gap_is_recorded(self) -> None:
        for v, p in self.plans.items():
            q = p["scale"]["smithdb-query"]
            self.assertEqual(q["chart_supports"]["signals"], {"admission_queue": []}, v)
            self.assertEqual((q["applied"]["kind"], q["applied"]["signals"]), ("hpa", ["cpu"]), v)
            self.assertEqual(q["gap"]["signals"], ["admission_queue"], v)
            self.assertIn("admission queue", q["gap"]["ask"])
            self.assertEqual(q["applied"]["values"], {"smithdb.query.autoscaling.hpa.minReplicas": 4}, v)

    def test_every_smithdb_split_and_ingestion_has_a_gap(self) -> None:
        for v, p in self.plans.items():
            for n in ("smithdb-stats-query", "smithdb-mutations", "smithdb-ingestion"):
                self.assertTrue(p["scale"][n]["gap"], (v, n))
        self.assertEqual(self.plans[CHART]["scale"]["smithdb-ingestion"]["gap"]["signals"], ["memory", "pending_segments"])

    def test_compaction_worker_gets_keda_and_gives_up_its_hpa(self) -> None:
        for v, p in self.plans.items():
            w = p["scale"]["smithdb-compaction-worker"]
            self.assertEqual((w["applied"]["kind"], w["gap"]), ("keda", None), v)
            self.assertIs(w["applied"]["values"]["smithdb.compactionWorker.autoscaling.keda.enabled"], True)
            self.assertIs(w["applied"]["values"]["smithdb.compactionWorker.autoscaling.hpa.enabled"], False)

    def test_ingest_queue_keda_values_are_the_calculators_worked_figures(self) -> None:
        # 1,500 peak runs/s at 34.9 runs per core and 1.25 headroom is 53.7 cores, 27 two-core pods; the
        # average of 500 runs/s is 8.96, 9 pods; KEDA's ceiling is 27 x 1.5 = 40.5, nearest five 40
        for v, p in self.plans.items():
            s = p["scale"]["ingest-queue"]
            base = "ingestQueue.autoscaling.keda"
            self.assertEqual(s["applied"]["values"], {f"{base}.enabled": True, f"{base}.minReplicaCount": 9, f"{base}.maxReplicaCount": 40}, v)
            self.assertEqual(s["chart_supports"]["signals"], {"run_backlog": ["keda"]})
            self.assertIn("feedback", s["gap"]["ask"])
            self.assertTrue(s["above_chart_default"])

    def test_a_key_is_set_only_when_it_differs_from_the_chart(self) -> None:
        for p in self.plans.values():
            pb = p["scale"]["platform-backend"]["applied"]
            self.assertEqual(pb["values"], {"platformBackend.autoscaling.hpa.enabled": True})
            self.assertEqual((pb["min"], pb["max"]), (3, 10))

    def test_a_ceiling_is_never_below_the_charts(self) -> None:
        top = {"hpa": "maxReplicas", "keda": "maxReplicaCount"}
        for v, p in self.plans.items():
            c = chart_at(v)
            scaled = {n: s["applied"] for n, s in p["scale"].items() if s["deployed"] and s["applied"]["kind"] != "none"}
            self.assertEqual(len(scaled), 10, v)
            for n, a in scaled.items():
                chart_max = c.number(f"{P['scale.workloads'][n]['values_key']}.autoscaling.{a['kind']}.{top[a['kind']]}")
                self.assertGreaterEqual(a["max"], chart_max, (v, n))
                self.assertGreaterEqual(a["max"], a["min"], (v, n))

    def test_undeployed_services_are_listed_but_set_nothing(self) -> None:
        for p in self.plans.values():
            r = p["scale"]["smithdb-run-rules"]
            self.assertEqual((r["deployed"], r["applied"]["values"]), (False, {}))

    def test_every_table_workload_names_signals_and_a_chart_key_that_exist(self) -> None:
        for v in VERSIONS:
            c = chart_at(v)
            for n, spec in P["scale.workloads"].items():
                self.assertTrue(set(spec["signals"]) <= set(P["scale.signals"]), n)
                if spec["mechanism"] != "none":
                    self.assertIn(spec["mechanism"], c.at(f"{spec['values_key']}.autoscaling"), (v, n))

    def test_the_unified_topology_has_no_autoscaler(self) -> None:
        p = size(chart_version=NEXT, smithdb_topology="unified", users=2, traces_per_second=20)
        self.assertEqual([n for n in p["scale"] if n.startswith("smithdb")], ["smithdb"])
        s = p["scale"]["smithdb"]
        self.assertEqual((s["chart_supports"]["hpa"], s["chart_supports"]["keda"], s["applied"]["kind"], s["gap"]), (False, False, "none", None))

    def test_extra_lite_turns_autoscalers_off_and_serves_from_one_pod(self) -> None:
        p = size(users=2, traces_per_second=1, peak_traces_per_second=3)
        self.assertEqual(p["regime"]["id"], "extra-lite")
        for n, s in p["scale"].items():
            self.assertEqual(s["applied"]["kind"], "none", n)
            self.assertIsNone(s["gap"], n)
        self.assertIs(p["scale"]["smithdb-query"]["applied"]["values"]["smithdb.query.autoscaling.hpa.enabled"], False)
        self.assertEqual(p["scale"]["platform-backend"]["applied"]["values"], {"platformBackend.deployment.replicas": 1})
        # the sizing says what the scale applies
        self.assertEqual({n: w["replicas"] for n, w in p["workloads"].items()}, dict.fromkeys(("frontend", "backend", "platform-backend", "ingest-queue", "queue", "ace-backend", "playground"), 1))

    def test_an_install_that_survives_a_node_loss_is_never_extra_lite(self) -> None:
        # this once asserted 2 pods under the extra-lite label, encoding a plan that said both
        p = size(users=2, traces_per_second=1, peak_traces_per_second=3, survives_node_loss=True)
        self.assertNotEqual(p["regime"]["id"], "extra-lite")
        self.assertEqual(len(p["workloads"]), 7)
        self.assertEqual(min(w["replicas"] for w in p["workloads"].values()), 2)


class ScaleUnit(unittest.TestCase):
    """The pure function on a made-up autoscaling block, so it needs no helm."""

    SPEC = {"values_key": "svc", "mechanism": "keda", "signals": ["compaction_jobs", "memory"], "why": "w"}
    BLOCK = {"hpa": {"enabled": True, "minReplicas": 1, "maxReplicas": 10, "targetCPUUtilizationPercentage": 40}, "keda": {"enabled": False, "minReplicaCount": 1, "maxReplicaCount": 10, "pendingJobsThreshold": "60"}}

    def run_it(self, spec: dict[str, Any] | None = None, **kw: Any) -> dict[str, Any]:
        args: dict[str, Any] = {"signals": P["scale.signals"], "fallback": P["scale.fallback"], "autoscaling": self.BLOCK, "default_replicas": 1, "sized": {"min": 3, "max": 4}, "autoscalers": True, "fixed_replicas": None} | kw
        return scale.workload(spec or self.SPEC, **args)

    def test_a_supported_subset_is_applied_and_the_rest_is_the_gap(self) -> None:
        w = self.run_it()
        self.assertEqual((w["applied"]["kind"], w["applied"]["signals"], w["gap"]["signals"]), ("keda", ["compaction_jobs"], ["memory"]))
        self.assertEqual((w["applied"]["min"], w["applied"]["max"]), (3, 10))
        self.assertEqual(w["applied"]["values"], {"svc.autoscaling.keda.enabled": True, "svc.autoscaling.hpa.enabled": False, "svc.autoscaling.keda.minReplicaCount": 3})

    def test_nothing_supported_falls_back_to_cpu(self) -> None:
        w = self.run_it(self.SPEC | {"signals": ["admission_queue"]})
        self.assertEqual((w["applied"]["kind"], w["applied"]["signals"]), ("hpa", ["cpu"]))

    def test_no_autoscaler_at_all_applies_nothing(self) -> None:
        w = self.run_it(autoscaling=None)
        self.assertEqual((w["applied"], w["chart_supports"]["hpa"]), ({"kind": "none", "signals": [], "values": {}}, False))


@needs_helm
class Configure(unittest.TestCase):
    def test_priorities_always_partitions_only_on_a_redis_cluster(self) -> None:
        names = lambda p: {e["name"]: e["value"] for e in p["configure"]["values"]["commonEnv"]}  # noqa: E731
        internal, cluster = size(), size(redis="external")
        self.assertEqual(names(internal), {"GO_INGESTION_QUEUE_PRIORITY": "6", "GO_FEEDBACK_QUEUE_PRIORITY": "1"})
        self.assertEqual(names(cluster), names(internal) | {"GO_INGESTION_WORKER_PARTITIONS": "2", "GO_INGESTION_QUEUE_PARTITIONS": "2"})
        self.assertEqual(cluster["stores"]["redis"]["queue_partitions"], 2)

    def test_the_splits_follow_the_tier_and_mutations_stay_observe_only(self) -> None:
        big, small = size()["configure"], size(users=5, traces_per_second=10)["configure"]
        self.assertEqual((big["values"]["smithdb.statsQuery.enabled"], big["values"]["smithdb.mutations.enabled"]), (True, True))
        self.assertNotIn("smithdb.statsQuery.enabled", small["values"])
        self.assertFalse(small["splits"]["mutations"]["on"])
        self.assertEqual(big["splits"]["mutations"]["threshold"], "observe")
        self.assertEqual((big["splits"]["mutations"]["feedback_per_second"], big["splits"]["mutations"]["feedback_per_second_peak"]), (25, 75))

    def test_redis_never_evicts(self) -> None:
        internal, external = size()["configure"]["redis"], size(redis="external")["configure"]["redis"]
        self.assertEqual(internal["values"]["redis.statefulSet.command"][-2:], ["--maxmemory-policy", "noeviction"])
        self.assertEqual(external["values"], {})
        self.assertIn("noeviction", external["instruction"])

    def test_the_go_cpu_limit_is_at_least_two_on_both_go_pods(self) -> None:
        for v in VERSIONS:
            go = size(chart_version=v)["configure"]["go"]
            self.assertEqual(go, {"platform-backend": {"cpu_limit": 2, "minimum": 2, "ok": True}, "ingest-queue": {"cpu_limit": 2, "minimum": 2, "ok": True}}, v)

    def test_a_go_pod_below_the_minimum_is_not_ok(self) -> None:
        got = configure.go_limits({"platform-backend": {"limits": {"cpu": 1}}, "ingest-queue": {"limits": {"cpu": 3}}}, 2)
        self.assertEqual({n: g["ok"] for n, g in got.items()}, {"platform-backend": False, "ingest-queue": True})

    def test_per_operation_memory_limits_name_no_variable(self) -> None:
        m = size()["configure"]["operation_memory_limit"]
        self.assertEqual(m["workloads"], ["smithdb-query", "smithdb-stats-query"])
        self.assertNotRegex(m["recommendation"] + m["chart_ask"], r"[A-Z]{3,}_[A-Z_]+")

    def test_a_low_regime_keeps_smithdb_small_and_scales_ingestion_and_query_out(self) -> None:
        # 10 users read at 20 requests/s, twice the small tier's tested query rate; a 15 traces/s peak is
        # 150 runs/s, past one small ingestion pod. The model's bands gave medium for both.
        p = size(users=10, traces_per_second=5, peak_traces_per_second=15)
        s = p["smithdb"]
        self.assertEqual((p["regime"]["id"], s["tier"], s["auto"]["tier"]), ("lite", "small", "medium"))
        self.assertEqual((s["components"]["ingestion"]["min"], s["components"]["query"]["min"]), (2, 2))

    def test_a_tier_or_layout_the_person_gives_is_kept(self) -> None:
        load = {"users": 10, "traces_per_second": 5, "peak_traces_per_second": 15}
        self.assertEqual(size(smithdb_tier="medium", **load)["smithdb"]["tier"], "medium")
        self.assertNotEqual(size(smithdb_tier="medium", **load)["smithdb"]["tier_by"], "regime")
        self.assertEqual(size(chart_version=NEXT, smithdb_topology="cluster", users=2, traces_per_second=1, peak_traces_per_second=3)["smithdb"]["topology"], "cluster")

    def test_unified_only_where_the_chart_has_it_and_one_pod_carries_the_load(self) -> None:
        tiny = size(chart_version=NEXT, users=2, traces_per_second=1, peak_traces_per_second=3)["smithdb"]
        self.assertEqual((tiny["topology"], list(tiny["components"])), ("unified", ["smithdb"]))
        # 150 peak runs/s is more than one measured pod: the cluster layout, scaled out, even on a chart with unified.
        self.assertEqual(size(chart_version=NEXT, users=5, traces_per_second=5, peak_traces_per_second=15)["smithdb"]["topology"], "cluster")
        self.assertEqual(size(users=2, traces_per_second=1, peak_traces_per_second=3)["smithdb"]["topology"], "cluster")

    def test_a_chart_without_the_unified_layout_is_the_input_left_to_change(self) -> None:
        tiny = {"users": 2, "traces_per_second": 1, "peak_traces_per_second": 3}
        self.assertEqual(size(chart_version=NEXT, **tiny)["configure"]["inputs_to_change"], {})
        has_topology = chart_at(CHART).at("smithdb.topology") is not None
        self.assertEqual(list(size(**tiny)["configure"]["inputs_to_change"]), [] if has_topology else ["chart_version"])


@needs_helm
class Watch(unittest.TestCase):
    def test_an_item_without_a_number_is_observe(self) -> None:
        p = size()
        got = {i["id"]: i["threshold"] for i in p["watch"]}
        bare = [item["id"] for item in P["watch.items"] if item["threshold"] is None]
        self.assertGreaterEqual(len(bare), 6)
        for wid in bare:
            self.assertEqual(got[wid], "observe", wid)
        for n in ("feedback-backlog", "pending-segments", "metastore-flush", "object-store-latency", "compaction-oldest-pending", "go-cpu-throttling"):
            self.assertEqual(got[n], "observe", n)

    def test_numbers_come_from_a_parameter_the_chart_or_the_plan(self) -> None:
        p = size()
        got = {i["id"]: i for i in p["watch"]}
        self.assertEqual(got["redis-memory"]["threshold"]["value"], P["redis.alarm_pct"])
        self.assertEqual(got["redis-evictions"]["threshold"]["value"], 0)
        self.assertEqual(got["run-backlog-at-ceiling"]["threshold"]["value"], chart_at().number("ingestQueue.autoscaling.keda.queueTargetSize"))
        self.assertEqual(got["run-backlog-at-ceiling"]["while"]["value"], p["scale"]["ingest-queue"]["applied"]["max"])
        self.assertEqual(got["compaction-jobs"]["threshold"]["value"], chart_at().number("smithdb.compactionWorker.autoscaling.keda.pendingJobsThreshold"))
        numbered = [i for i in p["watch"] if i["threshold"] != "observe"]
        self.assertGreaterEqual(len(numbered), 10)
        for i in numbered:
            self.assertTrue(i["threshold"]["from"] and i["threshold"]["unit"], i["id"])

    def test_one_autoscaler_item_for_each_autoscaler_at_its_ceiling(self) -> None:
        # the ceilings the default plan applies: the chart's own where the load needs no more (frontend
        # 5, backend 6, platform-backend 10, the SmithDB HPAs 5 or 10), the model's for the ingest queue
        p = size()
        pinned = {i["workload"]: i["threshold"]["value"] for i in p["watch"] if i["id"].startswith("autoscaler-at-ceiling:")}
        self.assertEqual(
            pinned,
            {"frontend": 5, "backend": 6, "platform-backend": 10, "ingest-queue": 40, "queue": 10, "smithdb-query": 10, "smithdb-stats-query": 5, "smithdb-mutations": 5, "smithdb-ingestion": 10, "smithdb-compaction-worker": 10},
        )
        self.assertNotIn("smithdb-run-rules", pinned)  # not deployed

    def test_nothing_to_compare_with_is_observe_not_a_zero(self) -> None:
        p = size(users=2, traces_per_second=1, peak_traces_per_second=3)
        got = {i["id"]: i for i in p["watch"]}
        self.assertEqual(got["run-backlog-at-ceiling"]["while"], "observe")
        self.assertFalse([i for i in p["watch"] if i["id"].startswith("autoscaler-at-ceiling:")])

    def test_compaction_items_belong_to_the_cluster_topology(self) -> None:
        p = size(chart_version=NEXT, smithdb_topology="unified", users=2, traces_per_second=20)
        self.assertFalse({"compaction-jobs", "compaction-oldest-pending"} & set(ids(p["watch"])))

    def test_every_metric_is_a_known_one(self) -> None:
        known = {*P["watch.metrics_smithdb"]["critical"], *P["watch.metrics_smithdb"]["all_only"], *P["watch.metrics_other"]}
        self.assertTrue({i["metric"] for i in P["watch.items"]} <= known)
        with self.assertRaises(ValueError):
            watch.items([{"id": "x", "metric": "made_up", "threshold": None}], known, resolve=lambda r: None, topology="cluster", scale={})

    def test_an_item_on_a_metric_the_chart_does_not_export_says_what_to_set(self) -> None:
        hidden = set(P["watch.metrics_smithdb"]["all_only"])
        self.assertFalse(hidden & set(P["watch.metrics_smithdb"]["critical"]))
        for item in P["watch.items"]:
            self.assertEqual(item["metric"] in hidden, "METRICS__MODE=all" in (item.get("needs") or ""), item["id"])
        p = size(users=10, traces_per_second=5)
        self.assertIn("METRICS__MODE=all", next(i for i in p["watch"] if i["id"] == "metastore-flush")["needs"])

    def test_the_metric_names_cite_what_the_images_expose(self) -> None:
        loaded = params.load()
        self.assertEqual(loaded["watch.metrics_smithdb"].source_kind, "lab")
        self.assertIn("0.17.62", loaded["watch.metrics_smithdb"].source_ref)
        self.assertIn("0.18.20rc1", loaded["watch.metrics_smithdb"].source_ref)


@needs_helm
class Warnings(unittest.TestCase):
    def test_the_ten_users_fifty_traces_case(self) -> None:
        w = {x["id"]: x for x in size()["warnings"]}
        self.assertEqual(w["postgres-connections"]["figures"], {"connections": 334, "budget": 80, "max_connections": 100})
        self.assertIn("redis-needs-cluster", w)
        self.assertIn("ceilings-above-chart-default", w)
        self.assertNotIn("beyond-payload-tested", w)

    def test_past_what_was_published_and_tested(self) -> None:
        w = ids(size(users=200, traces_per_second=5000)["warnings"])
        for n in ("beyond-published", "beyond-payload-tested", "beyond-tiers"):
            self.assertIn(n, w)
        self.assertIn("redis-over-shard-cap", ids(size(users=200, traces_per_second=50_000)["warnings"]))

    def test_a_small_install_has_nothing_to_warn_about_in_stores(self) -> None:
        w = ids(size(users=2, traces_per_month=10_000, postgres_memory_gib=32)["warnings"])
        self.assertFalse({"postgres-connections", "redis-needs-cluster", "beyond-published"} & set(w))

    def test_every_recommended_trigger_the_chart_lacks_is_a_warning(self) -> None:
        # the signals with no autoscaling field (admission queue, pending segments, backlog) belong to
        # these four SmithDB services; the ingest queue's KEDA scaler also fires on the feedback backlog.
        # Compaction scales on its job backlog the chart can express, and run-rules is not deployed.
        for v in VERSIONS:
            got = {i for i in ids(size(chart_version=v)["warnings"]) if i.startswith("chart-ask:")}
            self.assertEqual(got, {"chart-ask:ingest-queue", "chart-ask:smithdb-query", "chart-ask:smithdb-stats-query", "chart-ask:smithdb-mutations", "chart-ask:smithdb-ingestion"}, v)

    def test_no_chart_ask_when_autoscalers_are_off(self) -> None:
        self.assertFalse([i for i in ids(size(users=2, traces_per_second=1, peak_traces_per_second=3)["warnings"]) if i.startswith("chart-ask:")])


@needs_helm
class Provenance(unittest.TestCase):
    def test_each_new_part_names_its_sources(self) -> None:
        prov = size()["provenance"]
        for part, want in {
            "regime": "param:regimes", "scale": "param:scale.workloads", "configure": "param:configure.queue_priorities",
            "watch": "param:watch.items", "warnings": "param:postgres.connection_budget",
        }.items():
            self.assertIn(want, prov[part]["from"], part)

    def test_every_new_param_is_used(self) -> None:
        used = {r.split(":", 1)[1] for e in size()["provenance"].values() for r in e["from"] if r.startswith("param:")}
        for pid in ("regimes", "scale.signals", "scale.fallback", "scale.workloads", "configure.queue_priorities", "configure.partition_env", "watch.items", "watch.metrics_smithdb", "watch.metrics_other"):
            self.assertIn(pid, used)


if __name__ == "__main__":
    unittest.main()
