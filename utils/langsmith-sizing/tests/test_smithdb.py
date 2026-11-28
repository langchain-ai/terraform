import re
import unittest

from helpers import CITED, P, chart_at, needs_helm, size
from langsmith_sizing import inputs
from langsmith_sizing.chart import SMITHDB_RENDERABLE, merge
from langsmith_sizing.model import smithdb

TIERS = list(CITED["smithdb.tested_qps"])
RPS = CITED["scale.read_anchors"]["rps"]["high"] / CITED["scale.read_anchors"]["high"]
QUERY = {t: CITED["smithdb.tested_qps"][t]["query"] for t in TIERS}
SMALL_TO_LARGE = ["small", "medium", "large"]  # the order the tier rules below are written for


def auto(users: float, tps: float, runs: float = 10, peak: float = 3) -> dict:
    return smithdb.auto_tier(tps * runs * peak, users, tiers=TIERS, peak_bands=P["smithdb.peak_runs_bands"], tested_query_qps=QUERY, rps_per_user=RPS)


class Tier(unittest.TestCase):
    def test_query_rate_is_users_times_the_rate_per_user(self) -> None:
        self.assertEqual(smithdb.query_rps(10, 2.0), 20)
        self.assertEqual(smithdb.query_rps(0, 2.0), 0)

    def test_the_tiers_run_smallest_first(self) -> None:
        # the tier rules below compare by position: a docs reorder must fail here, not silently flip them
        self.assertEqual(TIERS, SMALL_TO_LARGE)
        self.assertEqual(sorted(QUERY.values()), list(QUERY.values()))

    def test_write_bands_by_peak_runs(self) -> None:
        self.assertEqual(auto(1, 50)["write"]["tier"], "large")  # 1,500 peak runs/s
        self.assertEqual(auto(1, 10)["write"]["tier"], "medium")  # 300
        self.assertEqual(auto(1, 0.5)["write"]["tier"], "small")

    def test_reads_raise_the_tier(self) -> None:
        a = auto(10, 0.5)  # 20 req/s: above small's 10
        self.assertEqual((a["tier"], a["by"]), ("medium", "read"))

    def test_the_larger_of_write_and_read_wins(self) -> None:
        a = auto(10, 50)
        self.assertEqual((a["tier"], a["by"], a["read"]["tier"]), ("large", "write", "medium"))
        self.assertEqual(auto(5, 10)["tier"], "medium")
        self.assertEqual(auto(20, 100)["tier"], "large")

    def test_beyond_the_tiers(self) -> None:
        a = auto(200, 5000)
        self.assertEqual((a["tier"], a["write"]["beyond_tiers"], a["read"]["beyond_largest"]), ("large", True, True))
        self.assertFalse(auto(50, 1000)["read"]["beyond_largest"])


class Replicas(unittest.TestCase):
    def test_query_replicas(self) -> None:
        kw = {"tiers": TIERS, "floor_from_second_tier": P["smithdb.query_floor_replicas"]}
        self.assertEqual([smithdb.query_replicas(t, n, **kw) for t, n in (("small", 1), ("medium", 1), ("large", 4))], [1, 2, 4])

    def test_splits_run_from_large(self) -> None:
        self.assertEqual([smithdb.splits_on(t, TIERS, P["smithdb.splits_from_tier"]) for t in TIERS], [False, False, True])


@needs_helm
class FromTheChart(unittest.TestCase):
    def pods(self, tier: str) -> dict:
        return chart_at().pods({"smithdb": merge(SMITHDB_RENDERABLE, {"resourceTier": tier})})

    def test_starting_ingestion_cores(self) -> None:
        for tier, cores in (("small", 4), ("medium", 16), ("large", 112)):
            comp = {"ingestion": {"requests": self.pods(tier)["ingestion"]["requests"], "replicas": CITED["smithdb.replicas.ingestion"][tier]}}
            self.assertEqual(smithdb.ingest_cores(comp), cores, tier)

    def test_the_chart_tier_helper_agrees_with_the_docs_table(self) -> None:
        # a drift between the chart's tierResources and the docs' baseline table is a contradiction to report
        for tier in TIERS:
            pods = self.pods(tier)
            for comp in ("ingestion", "query", "compaction", "compaction-worker", "cluster-manager"):
                cell = CITED.by_id[f"smithdb.replicas.{comp}"].quote.split(" | ")[1 + TIERS.index(tier)]
                cpu = re.search(r"([\d.]+)(m?) CPU", cell)
                mem = re.search(r"([\d.]+) (Mi|Gi) memory", cell)
                want_cpu = float(cpu[1]) / (1000 if cpu[2] else 1)  # type: ignore[index]
                want_mem = float(mem[1]) / (1024 if mem[2] == "Mi" else 1)  # type: ignore[index]
                req = pods[comp]["requests"]
                self.assertEqual((req["cpu"], req["memory_gib"]), (want_cpu, want_mem), (tier, comp))
                self.assertEqual(pods[comp]["limits"], req, (tier, comp))
                cache = re.search(r"([\d.]+) Gi cache", cell)
                self.assertEqual(pods[comp]["cache_gib"], float(cache[1]) if cache else None, (tier, comp))  # type: ignore[index]


class Backfill(unittest.TestCase):
    PER_VCPU_DAY = CITED["smithdb.backfill"]["runs_per_vcpu_day"]
    FLOOR = CITED["smithdb.backfill_pod_memory"]["min_memory_gib"]

    def backfill(self, runs: float, days: float, cpu: float = 8, memory: float = 32) -> dict:
        return smithdb.backfill(runs, days, runs_per_vcpu_day=self.PER_VCPU_DAY, pod={"cpu": cpu, "memory_gib": memory}, min_memory_gib=self.FLOOR)

    def test_the_docs_example_100_million_runs_in_a_day_is_20_vcpus_in_three_default_pods(self) -> None:
        b = self.backfill(100e6, 1)
        self.assertEqual((b["vcpus"], b["parallelism"], b["requests_total"]), (20, 3, {"cpu": 24, "memory_gib": 96}))

    def test_memory_never_falls_below_the_floor_and_a_small_history_still_runs_one_pod(self) -> None:
        b = self.backfill(1e6, 30, cpu=4, memory=8)
        self.assertEqual((b["parallelism"], b["pod"]["memory_gib"]), (1, self.FLOOR))

    def test_a_backfill_needs_both_its_runs_and_its_days(self) -> None:
        for kw in ({"backfill_runs": 1e8}, {"backfill_days": 1}, {"backfill_runs": 1e8, "backfill_days": 0}):
            with self.subTest(kw=kw), self.assertRaises(ValueError):
                inputs.validate(inputs.Inputs("0", 10, traces_per_second=5, **kw))

    @needs_helm
    def test_the_plan_sets_the_migration_jobs_parallelism_and_resources_and_leaves_totals_alone(self) -> None:
        with_backfill = size(backfill_runs=100e6, backfill_days=1)
        job = with_backfill["values"]["smithdb"]["migration"]["job"]
        self.assertEqual(job["parallelism"], with_backfill["smithdb"]["backfill"]["parallelism"])
        self.assertEqual(job["resources"]["requests"]["memory"], f"{self.FLOOR}Gi")
        self.assertNotIn("migration", size()["values"]["smithdb"])
        self.assertEqual(with_backfill["totals"]["sized"], size()["totals"]["sized"])

    @needs_helm
    def test_every_plan_names_the_cache_volume_and_the_metastore_postgres_the_docs_require(self) -> None:
        p = size()
        self.assertEqual(p["smithdb"]["cache_volume"], CITED["smithdb.cache_volume"])
        self.assertEqual(p["stores"]["smithdb_metastore"]["postgres_min_major_version"], CITED["smithdb.metastore_postgres"]["min_major_version"])


if __name__ == "__main__":
    unittest.main()
