"""Past the docs' tiers the plan is held to what a load test ran (cases/scale-test.yaml): at each rate,
every component at least 0.9x what ran and at most 1.6x, so a plan covers the load without doubling it,
and crossing into scale-out never shrinks a plan."""

import math
import unittest
from pathlib import Path
from typing import Any

import yaml
from langsmith_sizing import PLANNED_CHARTS, params
from langsmith_sizing.chart import same_line
from tests.helpers import needs_helm, size

CASES = yaml.safe_load((Path(__file__).resolve().parent.parent / "cases" / "scale-test.yaml").read_text())["cases"]
LOW, HIGH = 0.9, 1.6
# Held to the floor only, each for the reason beside it.
FLOOR_ONLY = {
    "ingest_vcpu": "the field curve the tiers use sits about 4x above this test, and the plan takes the larger until runs that vary the payload shape settle which holds",
}


def figures(p: dict[str, Any]) -> dict[str, float]:
    w, s, r = p["workloads"], p["smithdb"]["components"], p["stores"]["redis"]
    return {
        "ingest_vcpu": w["ingest-queue"]["replicas"] * w["ingest-queue"]["requests"]["cpu"],
        "api_vcpu": w["platform-backend"]["replicas"] * w["platform-backend"]["requests"]["cpu"],
        "smithdb_ingestion_pods": s["ingestion"]["replicas"],
        "redis_shards": r["spec"]["instance"]["shards"],
        "partitions": r["queue_partitions"],
        "compaction_workers": s["compaction-worker"]["replicas"],
        "compaction_vcpu": s["compaction-worker"]["replicas"] * s["compaction-worker"]["requests"]["cpu"],
        "compaction_max": s["compaction-worker"]["max"],
    }


@needs_helm
class ScaleTest(unittest.TestCase):
    def test_every_rate_the_load_test_held_is_covered_without_doubling_it(self) -> None:
        for case in CASES:
            inputs = {k: tuple(v) if isinstance(v, list) else v for k, v in case["inputs"].items()}
            p = size(**inputs)
            got = figures(p)
            with self.subTest(case["name"]):
                self.assertEqual(p["regime"]["id"], "scale-out")
                for key, ran in case["measured"].items():
                    if key.startswith("compaction"):
                        continue
                    self.assertGreaterEqual(got[key], LOW * ran, f"{key}: plan {got[key]:g}, ran {ran}")
                    if key in FLOOR_ONLY:
                        continue
                    self.assertLessEqual(got[key], math.ceil(HIGH * ran), f"{key}: plan {got[key]:g}, ran {ran}")
                ran = case["measured"]
                if "compaction_cores_p95" in ran:
                    self.assertGreaterEqual(got["compaction_vcpu"], ran["compaction_cores_p95"])
                if "compaction_workers_kept_up" in ran:
                    self.assertLessEqual(got["compaction_workers"], math.ceil(HIGH * ran["compaction_workers_kept_up"]))
                if "compaction_workers_fell_behind" in ran:
                    self.assertGreater(got["compaction_workers"], ran["compaction_workers_fell_behind"])
                    self.assertGreaterEqual(got["compaction_max"], ran["compaction_workers_to_drain"])

    def test_crossing_into_scale_out_never_shrinks_the_plan(self) -> None:
        # The load test's ingest rate alone once cut ingest from 358 to 98 vCPU, and the plan from 971 to
        # 661, as the peak went from 9,990 to 10,010 runs/s.
        def at(peak_runs: float) -> dict[str, Any]:
            return size(users=50, traces_per_second=peak_runs / 30, peak_traces_per_second=peak_runs / 10, postgres="external", redis="external", smithdb_metastore="external", object_store="external")

        below, above = at(9990), at(10010)
        self.assertEqual((below["regime"]["id"], above["regime"]["id"]), ("large", "scale-out"))
        for name, get in (("total vCPU", lambda p: p["totals"]["sized"]["requests"]["cpu"]), ("ingest vCPU", lambda p: figures(p)["ingest_vcpu"])):
            with self.subTest(name):
                self.assertGreaterEqual(get(above), get(below))

    def test_past_the_tiers_the_frontend_grows_with_the_rate_and_ingest_runs_the_tests_pod(self) -> None:
        # The frontend proxies every ingest request: the test's guide planned 36 frontend pods at 200k
        # runs/s, and its 7-vCPU ingest pods ran GOMAXPROCS 8 with 16 workers a CPU.
        inputs = {k: tuple(v) if isinstance(v, list) else v for k, v in CASES[-1]["inputs"].items()}
        p = size(**inputs)
        self.assertGreaterEqual(p["workloads"]["frontend"]["replicas"], 36)
        self.assertGreaterEqual(p["workloads"]["frontend"]["max"], 100)
        env = {e["name"]: e["value"] for e in p["values"]["ingestQueue"]["deployment"]["extraEnv"]}
        self.assertEqual(env, {"GOMAXPROCS": "8", "GO_INGESTION_CONCURRENCY_PER_CPU": "16"})
        below = size(users=50, traces_per_second=333, peak_traces_per_second=999, postgres="external", redis="external", smithdb_metastore="external", object_store="external")
        self.assertNotIn("extraEnv", below["values"].get("ingestQueue", {}).get("deployment", {}))

    def test_a_plan_on_another_chart_line_than_the_test_ran_says_so(self) -> None:
        inputs = {k: tuple(v) if isinstance(v, list) else v for k, v in CASES[0]["inputs"].items()}
        ran = params.values(params.load())["scale_out.measured"]["chart"]
        for version in PLANNED_CHARTS:
            message = next(w["message"] for w in size(chart_version=version, **inputs)["warnings"] if w["id"] == "scale-out-extrapolated")
            with self.subTest(version):
                self.assertEqual("another line" in message, not same_line(version, ran))

    def test_past_the_highest_rate_held_the_plan_says_it_is_untested(self) -> None:
        top = CASES[-1]["inputs"] | {"traces_per_second": 12000, "peak_traces_per_second": 12000}
        p = size(**{k: tuple(v) if isinstance(v, list) else v for k, v in top.items()})
        self.assertEqual(p["regime"]["id"], "beyond-tested")
        self.assertIn("measured", p["regime"])


if __name__ == "__main__":
    unittest.main()
