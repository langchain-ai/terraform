import json
import unittest

from helpers import CHART, CITED, chart_at, chart_or_skip, needs_helm, size
from langsmith_sizing import PLANNED_CHARTS, chart, inputs, params, plan


def leaves(node, path=()):
    if isinstance(node, dict):
        for k, v in node.items():
            yield from leaves(v, (*path, str(k)))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from leaves(v, (*path, str(i)))
    elif isinstance(node, (int, float)) and not isinstance(node, bool):
        yield ".".join(path)


@needs_helm
class Defaults(unittest.TestCase):
    """10 users, 50 traces/s, 10 runs a trace, peak x3: the calculator's worked case."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.p = size()

    def test_versioned(self) -> None:
        self.assertEqual((self.p["schema"], self.p["chart"]), (1, CHART))
        json.dumps(self.p)

    def test_rates(self) -> None:
        r = self.p["rates"]
        self.assertEqual((r["runs_per_second_avg"], r["runs_per_second_peak"], r["runs_per_day"]), (500, 1500, 43_200_000))
        self.assertEqual(r["bands"], {"r": "m", "w": "m"})
        self.assertFalse(r["beyond_published"] or r["beyond_payload_tested"])

    def test_smithdb_is_large_on_the_peak_write_rate(self) -> None:
        s = self.p["smithdb"]
        self.assertEqual((s["topology"], s["tier"], s["tier_by"], s["splits"]), ("cluster", "large", "write", True))
        self.assertEqual(s["ingestion_cores"], 112)
        c = s["components"]
        self.assertEqual({k: v["replicas"] for k, v in c.items()}, {"ingestion": 2, "query": 4, "compaction": 1, "compaction-worker": 4, "cluster-manager": 1, "stats-query": 1, "mutations": 2})
        self.assertEqual(c["query"]["requests"], {"cpu": 28, "memory_gib": 50})
        self.assertEqual(c["mutations"]["requests"], c["query"]["requests"])
        self.assertEqual((c["query"]["max"], c["stats-query"]["max"]), (10, 5))
        self.assertEqual(s["metastore"], {"cpu": 8, "memory_gib": 64, "postgres_min_major_version": 18})

    def test_ingest_queue_replaces_the_guides_column(self) -> None:
        w = self.p["workloads"]["ingest-queue"]
        self.assertEqual((w["replicas"], w["min"], w["max"]), (27, 9, 40))
        self.assertEqual((w["requests"], w["limits"]), ({"cpu": 2, "memory_gib": 4}, {"cpu": 2, "memory_gib": 4}))
        self.assertEqual(self.p["guide"]["iq"], 5)

    def test_smithdb_serving_reads_leaves_the_backend_at_the_chart_default(self) -> None:
        self.assertEqual(self.p["workloads"]["backend"]["replicas"], 2)
        self.assertEqual(self.p["guide"]["be"], 8)

    def test_every_workload_has_requests_and_limits_from_the_chart(self) -> None:
        w = self.p["workloads"]
        self.assertEqual(set(w), {"frontend", "backend", "platform-backend", "ingest-queue", "queue", "ace-backend", "playground"})
        self.assertEqual(w["frontend"]["requests"], {"cpu": 0.5, "memory_gib": 1})
        self.assertEqual(w["playground"]["limits"], {"cpu": 1, "memory_gib": 8})
        for name, v in w.items():
            self.assertTrue(v["requests"] and v["limits"], name)

    def test_go_pods_never_run_a_cpu_limit_below_two(self) -> None:
        self.assertGreaterEqual(self.p["workloads"]["platform-backend"]["limits"]["cpu"], 2)

    def test_object_storage(self) -> None:
        o = self.p["stores"]["object_storage"]
        self.assertAlmostEqual(o["smithdb"]["tb"], 23.78, places=2)
        self.assertAlmostEqual(o["langsmith"]["tb"], 24.15, places=2)
        self.assertAlmostEqual(o["total_tb"], 47.9, places=1)

    def test_redis_is_sized_on_the_peak_and_the_chart_expiry(self) -> None:
        r = self.p["stores"]["redis"]
        self.assertEqual((r["memory_gi"], r["basis"], r["cpu_shards"], r["queue_partitions"], r["expiry_seconds"]), (319, "payload", 2, 1, 21600))
        self.assertAlmostEqual(r["gb"], 341.8, places=1)
        self.assertAlmostEqual(r["alarm_gib"], 223.3, places=1)
        self.assertEqual(r["backlog_tolerance_hours"], 2.5)
        self.assertEqual(r["in_cluster"], {"cpu": 2, "memory_gib": 319})

    def test_postgres_connections(self) -> None:
        pg = self.p["stores"]["postgres"]
        self.assertEqual((pg["connections"], pg["api_pods"], pg["queue_pods"], pg["max_connections"], pg["max_connections_from"]), (334, 5, 28, 100, "image default"))
        self.assertEqual(pg["in_cluster"]["storage_gib"], 10)

    def test_no_clickhouse_when_smithdb_serves_alone(self) -> None:
        self.assertIsNone(self.p["stores"]["clickhouse"])

    def test_every_figure_has_a_source(self) -> None:
        prov = self.p["provenance"]
        figures = list(leaves({k: v for k, v in self.p.items() if k not in ("provenance", "schema")}))
        self.assertGreater(len(figures), 200)
        for path in figures:
            parts = path.split(".")
            self.assertTrue(any(".".join(parts[:n]) in prov for n in range(1, len(parts) + 1)), path)
        for path, entry in prov.items():
            self.assertIn(entry["kind"], ("input", "chart", "docs", "param", "derived"), path)
            self.assertTrue(entry["from"], path)

    def test_provenance_ids_name_real_sources(self) -> None:
        known = {"param": set(params.load()), "docs": set(CITED.by_id)}
        for path, entry in self.p["provenance"].items():
            for ref in entry["from"]:
                fam, _, ident = ref.partition(":")
                if fam in known:
                    self.assertIn(ident, known[fam], (path, ref))
                self.assertIn(fam, ("param", "docs", "chart", "input", "derived"), (path, ref))

    def test_the_same_inputs_give_the_same_plan(self) -> None:
        self.assertEqual(size(), self.p)


@needs_helm
class Loads(unittest.TestCase):
    def test_five_users_ten_traces_a_second(self) -> None:
        p = size(users=5, traces_per_second=10)
        self.assertEqual((p["smithdb"]["tier"], p["stores"]["redis"]["memory_gi"], p["rates"]["bands"]), ("medium", 64, {"r": "l", "w": "l"}))
        self.assertFalse(p["smithdb"]["splits"])
        self.assertEqual({k: v["replicas"] for k, v in p["smithdb"]["components"].items()}, {"ingestion": 1, "query": 2, "compaction": 1, "compaction-worker": 1, "cluster-manager": 1})

    def test_a_small_install_stays_small(self) -> None:
        p = size(users=2, traces_per_month=10_000)
        self.assertEqual((p["smithdb"]["tier"], p["regime"]["id"]), ("small", "extra-lite"))
        # extra-lite takes the serving pods to one replica on one node
        self.assertEqual(p["workloads"]["platform-backend"]["replicas"], 1)

    def test_past_the_highest_published_configuration(self) -> None:
        p = size(users=200, traces_per_second=5000)
        self.assertTrue(p["rates"]["beyond_published"] and p["rates"]["beyond_payload_tested"])
        self.assertTrue(p["smithdb"]["auto"]["write"]["beyond_tiers"])
        self.assertEqual(p["smithdb"]["tier"], "large")
        self.assertEqual(p["rates"]["extrapolation"], {"rx": 4, "wx": 5})
        self.assertEqual(p["stores"]["redis"]["queue_partitions"], 1)
        self.assertGreater(p["stores"]["redis"]["cpu_shards"], 100)

    def test_per_month_is_per_second(self) -> None:
        month = size(traces_per_month=131_328_000)
        self.assertEqual(month["rates"]["traces_per_second"], 50)
        self.assertEqual(month["workloads"], size()["workloads"])

    def test_a_measured_peak_replaces_the_factor(self) -> None:
        p = size(traces_per_second=20, peak_traces_per_second=40)
        self.assertEqual(p["rates"]["runs_per_second_peak"], 400)
        self.assertEqual(p["smithdb"]["tier"], "medium")

    def test_external_redis_over_one_node_is_a_cluster(self) -> None:
        r = size(redis="external")["stores"]["redis"]
        self.assertTrue(r["cluster"])
        self.assertEqual(r["queue_partitions"], 2)
        self.assertIsNone(r["in_cluster"])

    def test_external_postgres_assumes_connections_from_memory(self) -> None:
        pg = size(postgres_memory_gib=32)["stores"]["postgres"]
        self.assertEqual((pg["max_connections"], pg["budget"], pg["max_connections_from"], pg["in_cluster"]), (3604, 2883, "instance memory", None))

    def test_a_fixed_tier_is_honored(self) -> None:
        p = size(smithdb_tier="small")
        self.assertEqual((p["smithdb"]["tier"], p["smithdb"]["components"]["query"]["requests"]["cpu"]), ("small", 4))

    def test_trace_store_dual_keeps_the_guides_backend_curve_and_sizes_clickhouse(self) -> None:
        p = size(trace_store="dual")
        self.assertEqual(p["workloads"]["backend"]["replicas"], p["guide"]["be"])
        ch = p["stores"]["clickhouse"]
        self.assertEqual((ch["mode"], ch["nodes"], ch["storage_gi_per_node"], ch["gi_per_ttl_day"]), ("single", 1, 420, 30))
        self.assertEqual(ch["requests_per_node"], {"cpu": 8, "memory_gib": 19})  # the calculator's own example: 8 vCPU / 19 GiB at 10 users, 50 traces/s

    def test_replicated_clickhouse_is_three_nodes_each_holding_the_dataset(self) -> None:
        ch = size(trace_store="dual-replicated")["stores"]["clickhouse"]
        self.assertEqual((ch["nodes"], ch["storage_gi_total"], ch["requests_documented"]), (3, 1260, False))

    def test_blob_storage_off(self) -> None:
        p = size(blob_storage=False)
        self.assertIsNone(p["stores"]["object_storage"]["langsmith"])
        self.assertGreater(p["stores"]["redis"]["memory_gi"], 319)

    def test_blob_storage_off_is_refused_from_the_chart_line_that_requires_it(self) -> None:
        with self.assertRaisesRegex(ValueError, "blob storage is required from chart 0.18"):
            size(blob_storage=False, chart_version=PLANNED_CHARTS[-1])
        self.assertEqual(inputs.BLOB_REQUIRED_FROM, CITED["blob_storage.required_from"]["line"])

    def test_attachments_go_to_the_langsmith_bucket_at_the_bytes_sent(self) -> None:
        base, more = (size(attachment_kib_per_run=k)["stores"]["object_storage"]["langsmith"] for k in (0, 100))
        self.assertEqual(base["attachments_tb"], 0)
        # 500 runs/s x 86,400 s x 102.4 KB x the bucket's retention, the same days payloads are kept
        self.assertAlmostEqual(more["tb"] - base["tb"], more["attachments_tb"])
        self.assertAlmostEqual(more["written_tb_per_day"] - base["written_tb_per_day"], 500 * 86_400 * 102.4 * 1000 / 1e12)
        with self.assertRaisesRegex(ValueError, "needs blob storage"):
            size(attachment_kib_per_run=10, blob_storage=False)

    def test_untuned_expiry_stacks_headroom(self) -> None:
        self.assertAlmostEqual(size(redis_expiry_tuned=False)["stores"]["redis"]["headroom"], 1.69)

    def test_a_shorter_expiry_is_flagged_not_silently_accepted(self) -> None:
        r = size(redis_expiry_seconds=3600)["stores"]["redis"]
        self.assertTrue(r["expiry_below_chart_default"])
        self.assertEqual(r["backlog_tolerance_hours"], 0)

    def test_surviving_a_node_loss_runs_every_workload_at_least_twice(self) -> None:
        p = size(users=2, traces_per_month=10_000, survives_node_loss=True)
        for name, w in p["workloads"].items():
            self.assertGreaterEqual(w["replicas"], 2, name)
        for name, c in p["smithdb"]["components"].items():
            self.assertGreaterEqual(c["replicas"], 2, name)
        self.assertIn("param:availability.min_replicas", p["provenance"]["workloads.queue"]["from"])

    def test_the_mix_changes_what_the_payload_costs(self) -> None:
        big = size(payload_mix={"small": 0, "medium": 0, "large": 100})
        self.assertGreater(big["stores"]["object_storage"]["total_tb"], size()["stores"]["object_storage"]["total_tb"])
        self.assertLess(big["ingest"]["runs_per_core"], size()["ingest"]["runs_per_core"])

    def test_a_single_run_size(self) -> None:
        p = size(single_run_kib=(4, 4))
        self.assertEqual(p["payload"]["buckets"][0]["basis"], "measured")
        self.assertAlmostEqual(p["payload"]["blend"]["smithdb_kb"], 3.75)


@needs_helm
class Refusals(unittest.TestCase):
    def test_bad_inputs(self) -> None:
        for kw, message in (
            ({"traces_per_second": None}, "give exactly one of traces_per_second and traces_per_month"),
            ({"traces_per_second": 1, "traces_per_month": 5}, "give exactly one of traces_per_second and traces_per_month"),
            ({"trace_store": "x"}, "trace_store is one of smithdb, dual, dual-replicated"),
            ({"redis": "x"}, "redis is one of external, statefulset, operator"),
            ({"products": ("traces", "agents")}, "products: no agents"),
            ({"users": -1}, "users and traces cannot be negative"),
            ({"app_node": (0, 32)}, "a node shape is"),
        ):
            with self.subTest(kw), self.assertRaisesRegex(ValueError, message):
                size(**kw)

    def test_a_peak_below_the_average_is_refused(self) -> None:
        with self.assertRaisesRegex(ValueError, "the peak of 100 traces/s is below the average of 200: give --peak-traces-per-second"):
            size(traces_per_second=200, peak_traces_per_second=100)
        self.assertEqual(size(traces_per_second=200, peak_traces_per_second=200)["rates"]["peak_traces_per_second"], 200)

    def test_a_tier_the_docs_do_not_name(self) -> None:
        with self.assertRaisesRegex(ValueError, "smithdb_tier is auto or one of small, medium, large"):
            size(smithdb_tier="huge")

    def test_inputs_must_name_the_chart_given(self) -> None:
        with self.assertRaisesRegex(ValueError, f"inputs name chart 0.18.0 but the chart given is {CHART}"):
            plan.size(inputs.Inputs(chart_version="0.18.0", users=1, traces_per_second=1), chart_at(), params.load(), CITED)

    def test_unified_needs_a_chart_that_has_it(self) -> None:
        with self.assertRaisesRegex(chart.ChartError, f"chart {CHART} cannot run SmithDB as unified: it has no smithdb.topology"):
            size(smithdb_topology="unified")

    def test_out_of_range_inputs_are_clamped(self) -> None:
        p = size(runs_per_trace=5000, peak_factor=0.1, compression=99)
        self.assertEqual((p["inputs"]["runs_per_trace"], p["inputs"]["peak_factor"], p["inputs"]["compression"]), (200, 1, 10))


@needs_helm
class OnTheNextChart(unittest.TestCase):
    V = PLANNED_CHARTS[-1]

    def setUp(self) -> None:
        chart_or_skip(self, self.V)

    def test_topology_comes_from_the_chart(self) -> None:
        self.assertEqual(size(chart_version=self.V)["smithdb"]["topology"], "cluster")
        self.assertEqual(size(chart_version=CHART)["smithdb"]["topology"], "cluster")

    def test_redis_holds_a_record_a_run_on_018_with_smithdb_alone_and_every_payload_otherwise(self) -> None:
        trimmed = size(chart_version=self.V)["stores"]["redis"]
        dual = size(chart_version=self.V, trace_store="dual")["stores"]["redis"]
        before = size(chart_version=CHART)["stores"]["redis"]
        self.assertEqual((trimmed["payload_trimmed"], dual["payload_trimmed"]), (True, False))
        self.assertEqual(before["payload_trimmed"], chart.line_at_least(CHART, "0.18"))
        self.assertLess(trimmed["bytes"], dual["bytes"])

    def test_unified_is_one_pod_sized_by_the_tier(self) -> None:
        s = size(chart_version=self.V, smithdb_topology="unified", users=2, traces_per_month=10_000)["smithdb"]
        self.assertEqual((s["topology"], s["tier"], s["splits"], s["ingestion_cores"]), ("unified", "small", False, None))
        self.assertEqual(s["components"]["smithdb"]["replicas"], 1)
        self.assertEqual(s["components"]["smithdb"]["requests"], {"cpu": 4, "memory_gib": 16})


class Inputs(unittest.TestCase):
    def test_defaults_come_from_params_and_the_chart(self) -> None:
        r, src = inputs.resolve(inputs.Inputs(chart_version=CHART, users=1, traces_per_second=1), _Fake(), _P)  # type: ignore[arg-type]
        self.assertEqual(src["runs_per_trace"], "param:load.runs_per_trace")
        self.assertEqual(src["offload_threshold_kib"], "chart:config.blobStorage.minBlobStorageSizeKb")
        self.assertEqual((r["retention_days"], r["extended_retention_days"], r["redis_expiry_seconds"]), (14, 400, 21600))


class _Fake:
    """A chart with only the values the defaults read, so this test needs no helm."""

    version = CHART
    VALUES = {"config.blobStorage.minBlobStorageSizeKb": "20", "config.ttl.ttl_period_seconds.shortlived": "1209600", "config.ttl.ttl_period_seconds.longlived": "34560000", "config.settings.redisRunsExpirySeconds": "21600"}

    def number(self, key: str) -> float:
        return float(self.VALUES[key])


_P = params.values(params.load())


if __name__ == "__main__":
    unittest.main()
