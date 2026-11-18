"""Past the docs' tiers the plan is held to what a load test ran (cases/scale-test.yaml): at each rate,
every component at least 0.9x what ran and at most 1.6x, so a plan covers the load without doubling it."""

import math
import unittest
from pathlib import Path
from typing import Any

import yaml
from tests.helpers import needs_helm, size

CASES = yaml.safe_load((Path(__file__).resolve().parent.parent / "cases" / "scale-test.yaml").read_text())["cases"]
LOW, HIGH = 0.9, 1.6


def figures(p: dict[str, Any]) -> dict[str, float]:
    w, s, r = p["workloads"], p["smithdb"]["components"], p["stores"]["redis"]
    return {
        "ingest_vcpu": w["ingest-queue"]["replicas"] * w["ingest-queue"]["requests"]["cpu"],
        "api_vcpu": w["platform-backend"]["replicas"] * w["platform-backend"]["requests"]["cpu"],
        "smithdb_ingestion_pods": s["ingestion"]["replicas"],
        "redis_shards": r["spec"]["instance"]["shards"],
        "partitions": r["queue_partitions"],
        "compaction_workers": s["compaction-worker"]["replicas"],
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
                    self.assertLessEqual(got[key], math.ceil(HIGH * ran), f"{key}: plan {got[key]:g}, ran {ran}")
                least = case["measured"].get("compaction_workers_needed") or case["measured"]["compaction_workers_kept_up"]
                self.assertGreaterEqual(got["compaction_workers"], least)

    def test_past_the_highest_rate_held_the_plan_says_it_is_untested(self) -> None:
        top = CASES[-1]["inputs"] | {"traces_per_second": 12000, "peak_traces_per_second": 12000}
        p = size(**{k: tuple(v) if isinstance(v, list) else v for k, v in top.items()})
        self.assertEqual(p["regime"]["id"], "beyond-tested")
        self.assertIn("measured", p["regime"])


if __name__ == "__main__":
    unittest.main()
