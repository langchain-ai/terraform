"""The model reproduces the calculator it ports, case by case, field by field.

The expected numbers in cases/calculator-<commit>.json were computed by the sizing calculator's own
compute(), run unchanged; nothing here derives them from this package, so a porting error cannot
agree with itself. Two fields are compared on purpose no further, each for the reason beside it.
Totals, pools, in-cluster database rows and the ClickHouse node fit are compared too. Where a regime departs from the model (extra-lite's single replicas), the model's own figures are
read from `regime_adjusted`; where it runs SmithDB on a smaller tier than the calculator's band, the case is
sized again with the model's tier given, which a regime keeps. Both departures are tested in test_operate.
"""

import dataclasses
import json
import math
import unittest
from pathlib import Path
from typing import Any

from langsmith_sizing import citations, inputs, params, plan
from tests.helpers import chart_at, needs_helm

CASES = sorted((Path(__file__).resolve().parent.parent / "cases").glob("calculator-*.json"))
# Calculator input name -> the port's, for the inputs a case may carry.
INPUTS = (("peak", "peak_factor"), ("rpt", "runs_per_trace"), ("tier", "smithdb_tier"), ("peakTps", "peak_traces_per_second"), ("comp", "compression"), ("thr", "offload_threshold_kib"), ("extDays", "extended_retention_days"), ("extShare", "extended_share_pct"), ("redisTtl", "redis_expiry_seconds"), ("tuned", "redis_expiry_tuned"))
STORE = {"none": "smithdb", "single": "dual", "replicated": "dual-replicated"}
REDIS = {"internal": "statefulset", "external": "external"}
NOT_COMPARED = {
    "smithdb.auto.reason": "a sentence in the calculator; the plan gives the same facts as fields, compared below",
    "workloads.ace-backend.memory_gib": "the chart sets 2000Mi: 1.953125 GiB here, rounded to 2 there",
    "payload.platform_backend_pods": "carried in workloads.platform-backend.replicas, compared below",
}
# Fields the calculator returns that canon deliberately leaves out of the plan.
NOT_IN_CANON = {
    "payload.batching_cascade": "an advisory about S3/GCS batching, not a figure the plan carries",
    "payload.batching_cascade_between": "part of the batching advisory",
    "payload.batching_cascade_crossing": "part of the batching advisory",
    "payload.over_standalone_gcp_redis": "a calculator warning about GCP standalone Redis; the plan's own warnings cover memory limits",
    "smithdb.metastore_instance_class": "a cloud database instance class; canon sizes the metastore in the module, not here",
    "smithdb.metastore_storage_gi": "the same cloud metastore choice as the instance class",
    "smithdb.tier_is_auto": "the plan records the tier and tier_by, which say the same",
    "rows.count": "a sanity count of the calculator's own service rows, which the plan does not hold as a list",
}
# The chart sets ace-backend memory at 2000Mi: 1.953125 GiB here, 2 GiB in the calculator.
ACE_GIB_DIFF = 2 - 2000 / 1024
# Memory fields that carry that difference, as (pod counted, scaled by the overhead).
ACE_MEMORY = {
    "totals.svc_mem_gib": ("replicas", False),
    "totals.min_svc_mem_gib": ("min", False),
    "totals.mem_gib": ("replicas", True),
    "totals.min_mem_gib": ("min", True),
    "pools.app.mem_gib": ("replicas", True),
    "pools.app.min_mem_gib": ("min", True),
}
# Figures with a fractional nature are compared at a relative 1e-6; the rest exactly.
FRACTIONAL = ("_kb", "_tb", "_per_1k", "share", "headroom", "gb", "bytes", "rps", "runs_per_core", "cpus_", "per_day", "per_year", "per_second", "_gib", "_gi", "cpu", "days")


def _model(entry: dict[str, Any]) -> dict[str, Any]:
    return entry | entry.get("regime_adjusted", {})


def flat(o: dict[str, Any]) -> dict[str, Any]:
    f: dict[str, Any] = {}
    r, pay = o["rates"], o["payload"]
    for k in ("runs_per_second_avg", "runs_per_second_peak", "runs_per_day", "traces_per_year", "peak_traces_per_second", "beyond_tested"):
        f[f"rates.{k}"] = r[k]
    f["rates.band_read"], f["rates.band_write"] = r["bands"]["r"], r["bands"]["w"]
    f |= {f"guide.{k}": v for k, v in o["guide"].items()}
    names = ["small", "medium", "large"] if len(pay["buckets"]) == 3 else ["single"]
    for n, b in zip(names, pay["buckets"], strict=True):
        for k in ("smithdb_kb", "blob_kb", "redis_kb", "pb_per_1k", "placement", "basis"):
            f[f"payload.{n}.{k}"] = b[k]
    f |= {f"payload.blend.{k}": pay["blend"][k] for k in ("smithdb_kb", "blob_kb", "redis_kb", "pb_per_1k")}
    f["payload.inline_share"] = pay["inline_share"]
    f["payload.blend.runs_per_core"] = o["ingest"]["runs_per_core"]
    f |= {f"ingest.{k}": o["ingest"][k] for k in ("runs_per_core", "cpus_peak", "cpus_avg", "min_pods", "max_pods", "keda_max")}
    for w, v in o["workloads"].items():
        v = _model(v)
        f |= {f"workloads.{w}.{k}": v[k] for k in ("replicas", "min", "max")}
        f[f"workloads.{w}.cpu"], f[f"workloads.{w}.memory_gib"] = v["requests"]["cpu"], v["requests"]["memory_gib"]
    s = o["smithdb"]
    a = s["auto"]
    f |= {"smithdb.tier": s["tier"], "smithdb.tier_by": s["tier_by"], "smithdb.splits": s["splits"], "smithdb.ingestion_cores": s["ingestion_cores"]}
    f |= {"smithdb.auto.write_tier": a["write"]["tier"], "smithdb.auto.read_tier": a["read"]["tier"], "smithdb.auto.peak_runs_per_second": a["write"]["peak_runs_per_second"], "smithdb.auto.beyond_tiers": a["write"]["beyond_tiers"], "smithdb.auto.query_rps": a["read"]["query_rps"], "smithdb.auto.tested_qps": a["read"]["tested_qps"], "smithdb.auto.beyond_largest": a["read"]["beyond_largest"]}
    total = 0.0
    for n, c in s["components"].items():
        c = _model(c)
        f |= {f"smithdb.{n}.{k}": c[k] for k in ("replicas", "min", "max", "cache_gib")}
        f[f"smithdb.{n}.cpu"], f[f"smithdb.{n}.memory_gib"] = c["requests"]["cpu"], c["requests"]["memory_gib"]
        total += c["replicas"] * (c["cache_gib"] or 0)
    f["smithdb.cache_gib_total"] = total
    f["smithdb.cache_volumes"] = sum(c["replicas"] for c in (_model(c) for c in s["components"].values()) if c["cache_gib"] is not None)
    st = o["stores"]
    os_ = st["object_storage"]
    f |= {f"stores.object_storage.smithdb_{k}": os_["smithdb"][k] for k in ("tb", "written_tb_per_day", "steady_state_days")}
    f |= {f"stores.object_storage.langsmith_{k}": os_["langsmith"][k] if os_["langsmith"] else None for k in ("tb", "written_tb_per_day", "base_tb", "extended_tb")}
    f["stores.object_storage.total_tb"] = os_["total_tb"]
    rd = st["redis"]
    f |= {f"stores.redis.{k}": rd[k] for k in ("memory_gi", "basis", "payload_gi", "guide_gi", "bytes", "gb", "headroom", "alarm_gib", "cpu_shards", "cluster", "queue_partitions")}
    # The calculator reports the bytes written per day as one figure; the plan splits it by store.
    f["payload.written_tb_per_day"] = os_["smithdb"]["written_tb_per_day"] + (os_["langsmith"]["written_tb_per_day"] if os_["langsmith"] else 0)
    f["payload.extended_share_effective_pct"] = os_["extended_share"] * 100
    f["payload.threshold_kib"] = o["inputs"]["offload_threshold_kib"] if o["inputs"]["blob_storage"] else None
    f["payload.mix_normalized"] = pay["mix_normalized"]
    f["stores.redis.in_cluster_memory_gi"] = rd["in_cluster"]["memory_gib"] if rd["in_cluster"] else None
    pg = st["postgres"]
    f |= {f"stores.postgres.{k}": pg[k] for k in ("connections", "max_connections", "budget", "api_pods", "queue_pods", "max_connections_from")}
    ch = st["clickhouse"]
    f["stores.clickhouse.nodes"] = ch["nodes"] if ch else 0
    if ch:
        f |= {"stores.clickhouse.cpu_per_node": ch["requests_per_node"]["cpu"], "stores.clickhouse.memory_gib_per_node": ch["requests_per_node"]["memory_gib"], "stores.clickhouse.storage_gi_per_node": ch["storage_gi_per_node"], "stores.clickhouse.storage_gi_total": ch["storage_gi_total"]}
    for grp in ("totals", "pools", "dbs"):
        for k, v in o[grp].items():
            for sub, x in (v.items() if isinstance(v, dict) else [("", v)]):
                if not isinstance(x, (dict, list)):
                    f[f"{grp}.{k}.{sub}" if sub else f"{grp}.{k}"] = x
    f |= dict.fromkeys(("clickhouse.fits_app_node", "clickhouse.node_cpu", "clickhouse.node_mem_gib"))
    if ch:
        f |= {"clickhouse.fits_app_node": ch["fits_app_node"], "clickhouse.node_cpu": ch["node_cpu"], "clickhouse.node_mem_gib": ch["node_mem_gib"]}
    return f


def _ace_tolerance(field: str, expected: dict[str, Any]) -> float:
    """Allowed absolute gap on a memory total: the ace-backend difference times the pods counted, from the calculator's own case."""
    if field not in ACE_MEMORY:
        return 0.0
    count, scaled = ACE_MEMORY[field]
    return ACE_GIB_DIFF * expected[f"workloads.ace-backend.{count}"] * (expected["totals.overhead"] if scaled else 1)


def _same(field: str, want: Any, got: Any, abs_tol: float = 0.0) -> bool:
    if isinstance(want, (bool, str)) or want is None or isinstance(got, (bool, str)) or got is None:
        return bool(want == got)
    if any(m in field for m in FRACTIONAL):
        return math.isclose(got, want, rel_tol=1e-6, abs_tol=1e-9 + abs_tol)
    return bool(got == want)


def _inputs(s: dict[str, Any], chart_version: str) -> inputs.Inputs:
    kw: dict[str, Any] = dict(users=s["users"], traces_per_second=s["traces"], trace_store=STORE[s["ch"]], redis=REDIS[s["redis"]], retention_days=s["ttl"], postgres_memory_gib=s["postgres_memory_gib"])
    kw |= {k2: s[k1] for k1, k2 in INPUTS if k1 in s}
    if s.get("blob") is False:
        kw["blob_storage"] = False
    if "mix" in s:
        kw["payload_mix"] = dict(zip(("small", "medium", "large"), s["mix"], strict=True))
    if "single" in s:
        kw["single_run_kib"] = tuple(s["single"])
    return inputs.Inputs(chart_version, **kw)


def mismatches(golden: dict[str, Any], p: dict[str, Any], cited: Any, cases: slice = slice(None)) -> tuple[int, list[str]]:
    """Fields compared, and each field where the model and the calculator differ."""
    chart = chart_at(golden["chart"])
    compared, wrong = 0, []
    for i, case in list(enumerate(golden["cases"]))[cases]:
        sized = plan.size(_inputs(case["input"], golden["chart"]), chart, p, cited)
        if "regime_adjusted" in sized["smithdb"]:
            # A low regime ran SmithDB smaller than the calculator's band; the model's own tier, given
            # as an input the regime keeps, reproduces the calculator's figures.
            model = sized["smithdb"]["regime_adjusted"]
            sized = plan.size(dataclasses.replace(_inputs(case["input"], golden["chart"]), smithdb_tier=model["tier"]), chart, p, cited)
        got = flat(sized)
        for field, want in case["expected"].items():
            if field in NOT_COMPARED or field in NOT_IN_CANON:
                continue
            compared += 1
            if field not in got or not _same(field, want, got[field], _ace_tolerance(field, case["expected"])):
                wrong.append(f"case {i} ({case['input'].get('note')}) {field}: calculator {want!r}, model {got.get(field, '<missing>')!r}")
    return compared, wrong


@needs_helm
class Conformance(unittest.TestCase):
    def test_every_case_matches_the_calculator(self) -> None:
        self.assertTrue(CASES, "no cases/calculator-*.json: the oracle is missing")
        p, cited = params.load(), citations.load()
        for path in CASES:
            golden = json.loads(path.read_text())
            self.assertGreaterEqual(len(golden["cases"]), 180, f"{path.name}: the oracle shrank")
            compared, wrong = mismatches(golden, p, cited)
            self.assertEqual(wrong, [], "\n".join(wrong[:20]))
            self.assertGreater(compared, 36_000, f"{path.name}: too few fields compared to mean anything")

    def test_a_one_percent_change_to_a_parameter_is_caught(self) -> None:
        # The oracle is only worth its pass if it can fail: a parameter moved by 1% must break it.
        import dataclasses

        golden = json.loads(CASES[0].read_text())
        cited = citations.load()
        for pid in ("pools.overhead", "headroom.redis"):
            p = params.load()
            p[pid] = dataclasses.replace(p[pid], value=p[pid].value * 1.01)
            _, wrong = mismatches(golden, p, cited, slice(0, 20))
            with self.subTest(param=pid):
                self.assertTrue(wrong, f"{pid} moved by 1% and the oracle did not notice")

if __name__ == "__main__":
    unittest.main()
