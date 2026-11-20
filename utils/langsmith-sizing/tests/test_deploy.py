"""Totals, node pools, the stores' placements and the wizard, each held to a worked example."""

import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from typing import Any

from langsmith_sizing import cli, inputs, summary, wizard
from langsmith_sizing.chart import hook_jobs
from langsmith_sizing.model import datastores, totals
from tests.helpers import CHART, CITED, P, chart_at, needs_helm, size

NODE = {"cpu": 32, "memory_gib": 128}


def entry(name: str, cpu: float, mem: float, n: tuple[int, int, int], volume: float = 0) -> dict[str, Any]:
    r = {"cpu": cpu, "memory_gib": mem}
    return {"name": name, "requests": r, "limits": {"cpu": cpu * 2, "memory_gib": mem * 2}, "volume_gib": volume, "replicas": dict(zip(("min", "sized", "max"), n, strict=True))}


class Pools(unittest.TestCase):
    def test_nodes_are_the_binding_resource_after_overhead_never_below_the_floor(self) -> None:
        # the calculator's example: 64.25 vCPU of medium-tier pods on 32 / 128 nodes is 3
        self.assertEqual(totals.node_count(64.25, 100, NODE, 2, P["pools.overhead"]), 3)
        self.assertEqual(totals.node_count(1, 300, NODE, 2, P["pools.overhead"]), 3)
        self.assertEqual(totals.node_count(1, 1, NODE, 2, P["pools.overhead"]), 2)

    def test_a_pod_fits_only_strictly_below_the_node(self) -> None:
        self.assertTrue(totals.fits(31.9, 127, NODE))
        self.assertFalse(totals.fits(32, 10, NODE))
        self.assertFalse(totals.fits(1, 128, NODE))

    def test_sums_read_the_floor_the_sized_count_and_the_ceiling(self) -> None:
        e = [entry("a", 2, 4, (1, 3, 5), volume=10)]
        got = {k: totals.pod_sum(e, w) for k, w in totals.PHASES.items()}
        self.assertEqual([got[k]["requests"]["cpu"] for k in ("floor", "sized", "ceiling")], [2, 6, 10])
        self.assertEqual(got["ceiling"]["limits"]["memory_gib"], 40)
        self.assertEqual(got["ceiling"]["volume_gib"], 50)

    def test_the_largest_pod_is_by_cpu_then_memory_and_the_first_of_equals(self) -> None:
        big = totals.largest([entry("a", 2, 4, (1, 1, 1)), entry("b", 2, 8, (1, 1, 1)), entry("c", 2, 8, (1, 1, 1))])
        self.assertEqual(big["name"], "b") if big else self.fail("no pod")

    def test_hooks_run_one_at_a_time_so_the_peak_adds_the_largest_job(self) -> None:
        jobs = [{"name": "x", "pods": 1, "requests": {"cpu": 1, "memory_gib": 1}, "limits": {"cpu": 1, "memory_gib": 1}},
                {"name": "y", "pods": 2, "requests": {"cpu": 1, "memory_gib": 1}, "limits": {"cpu": 1, "memory_gib": 1}}]
        base = totals.pod_sum([entry("a", 2, 4, (1, 1, 1))], "sized")
        peak = totals.hook_peak(jobs, base)
        self.assertEqual((peak["job"], peak["requests"]["cpu"]), ("y", 4))

    def test_clickhouse_takes_the_first_node_it_fits_else_the_largest(self) -> None:
        shapes = P["pools.clickhouse_node_shapes"]
        self.assertEqual(totals.clickhouse_node(8, 19, shapes)["cpu"], shapes[0]["cpu"])
        self.assertEqual(totals.clickhouse_node(16, 24, shapes)["cpu"], shapes[1]["cpu"])
        self.assertEqual(totals.clickhouse_node(500, 24, shapes)["cpu"], shapes[1]["cpu"])


class HandCase(unittest.TestCase):
    """Three services and one database, small enough to add up by hand."""

    SERVICES = [entry("web", 2, 4, (1, 3, 5)), entry("api", 1, 8, (2, 2, 4), volume=10)]
    DBS = [entry("pg", 4, 16, (1, 1, 1), volume=100)]

    def test_the_namespace_is_the_pods_times_replicas(self) -> None:
        # sized: 3 x 2 + 2 x 1 + 4 = 12 vCPU, 3 x 4 + 2 x 8 + 16 = 44 GiB
        # floors: 1 x 2 + 2 x 1 + 4 = 8 vCPU, 1 x 4 + 2 x 8 + 16 = 36 GiB
        everything = [*self.SERVICES, *self.DBS]
        sized, low = totals.pod_sum(everything, "sized")["requests"], totals.pod_sum(everything, "min")["requests"]
        self.assertEqual((sized["cpu"], sized["memory_gib"], low["cpu"], low["memory_gib"]), (12, 44, 8, 36))

    def test_a_pool_counts_nodes_of_the_binding_resource_at_each_replica_count(self) -> None:
        node = {"cpu": 4, "memory_gib": 16}
        everything = [*self.SERVICES, *self.DBS]
        pool = totals.pool(everything, node, 1, 1.5, "input")
        # sized: 12 vCPU and 44 GiB; x 1.5 is 18 and 66; 18 / 4 -> 5 nodes, 66 / 16 -> 5 nodes
        self.assertEqual(pool["sized"]["nodes"], 5)
        # floors: 8 vCPU, 36 GiB; x 1.5 is 12 and 54; 12 / 4 -> 3, 54 / 16 -> 4: memory binds
        self.assertEqual(pool["floor"]["nodes"], 4)
        # ceilings: 5 x 2 + 4 x 1 + 4 = 18 vCPU, 5 x 4 + 4 x 8 + 16 = 68 GiB; x 1.5 is 27 and 102: 7 and 7
        self.assertEqual(pool["ceiling"]["nodes"], 7)
        self.assertEqual(pool["ceiling"]["volume_gib"], 4 * 10 + 100)
        # the biggest pod is the database (4 vCPU) and it does not fit a 4 vCPU node: strictly below
        self.assertEqual((pool["largest_pod"], pool["largest_pod_fits"]), ("pg", False))


class Placements(unittest.TestCase):
    def test_an_operator_runs_three_instances_only_where_a_node_loss_is_survived(self) -> None:
        counts = P["datastores.operator_instances"]
        self.assertEqual([datastores.instances("operator", s, counts) for s in (True, False)], [3, 1])
        self.assertEqual(datastores.instances("statefulset", True, counts), 1)

    def test_a_redis_in_the_cluster_has_a_limit_above_maxmemory_and_a_volume_for_the_dataset(self) -> None:
        pod = datastores.redis_pod({"cpu": 2, "memory_gib": 4}, {"cpu": 4, "memory_gib": 8}, 8, 213, P["datastores.redis_maxmemory_share"])
        self.assertEqual(pod["requests"]["memory_gib"], 213)
        self.assertGreater(pod["limits"]["memory_gib"], 213)
        self.assertEqual(pod["volume_gib"], 213)

    def test_a_clickhouse_limit_is_never_below_its_request(self) -> None:
        pod = datastores.clickhouse_pod({"cpu": 16, "memory_gib": 24}, {"cpu": 8, "memory_gib": 32}, 100)
        self.assertEqual(pod["limits"], {"cpu": 16, "memory_gib": 32})


@needs_helm
class PlanDeploy(unittest.TestCase):
    def test_floor_is_below_sized_is_below_ceiling_in_every_namespace_sum(self) -> None:
        p = size(users=20, traces_per_second=33, peak_traces_per_second=100)
        a = p["totals"]
        for kind in ("requests", "limits"):
            self.assertLessEqual(a["floor"][kind]["cpu"], a["sized"][kind]["cpu"])
            self.assertLessEqual(a["sized"][kind]["cpu"], a["ceiling"][kind]["cpu"])
        self.assertGreaterEqual(p["totals"]["hooks"]["peak"]["requests"]["cpu"], a["ceiling"]["requests"]["cpu"])

    def test_hook_jobs_are_read_from_the_render_never_copied(self) -> None:
        p = size()
        names = {j["name"] for j in p["totals"]["hooks"]["jobs"]}
        self.assertIn("langsmith-smithdb-metastore-migration", names)
        rendered = {j["name"] for j in hook_jobs(chart_at().render(p["values"]))}
        self.assertEqual(names, rendered)

    def test_the_in_cluster_stores_are_counted_beside_the_services(self) -> None:
        p = size(redis="statefulset")
        app = p["pools"]["app"]
        self.assertLessEqual({"postgres", "redis"}, set(app["pods"]))
        stores = sum(p["stores"][k]["spec"]["instances"] * p["stores"][k]["spec"]["per_instance"]["requests"]["cpu"] for k in ("postgres", "redis"))
        services = sum(w["replicas"] * w["requests"]["cpu"] for w in p["workloads"].values())
        self.assertGreaterEqual(app["sized"]["requests"]["cpu"], services + stores)

    def test_the_node_shape_is_an_input(self) -> None:
        small, large = size(app_node=(4, 16)), size(app_node=(64, 256))
        self.assertGreater(small["pools"]["app"]["sized"]["nodes"], large["pools"]["app"]["sized"]["nodes"])
        self.assertEqual(large["pools"]["app"]["node_from"], "input")
        self.assertEqual(size()["pools"]["app"]["node_from"], "param:pools.app_node")

    def test_a_pod_bigger_than_its_node_is_a_warning(self) -> None:
        p = size(smithdb_node=(8, 16))
        self.assertFalse(p["pools"]["smithdb"]["largest_pod_fits"])
        self.assertIn("pod-does-not-fit-node", {w["id"] for w in p["warnings"]})

    def test_dedicated_data_store_pool_takes_the_stores_off_the_application_pool(self) -> None:
        shared, own = size(), size(datastores_on="dedicated")
        self.assertNotIn("datastores", shared["pools"])
        self.assertEqual(set(own["pools"]["datastores"]["pods"]), {"postgres", "redis"})
        self.assertLess(own["pools"]["app"]["sized"]["requests"]["cpu"], shared["pools"]["app"]["sized"]["requests"]["cpu"])
        self.assertAlmostEqual(own["totals"]["sized"]["requests"]["cpu"], shared["totals"]["sized"]["requests"]["cpu"])

    def test_external_stores_are_instance_specs(self) -> None:
        p = size(postgres="external", redis="external", users=20, traces_per_second=33, peak_traces_per_second=100)
        pg = p["stores"]["postgres"]["spec"]["instance"]
        self.assertEqual((pg["vcpu"], pg["memory_gib"], pg["disk_gib"]), (CITED["scale.postgres"]["cpu"], CITED["scale.postgres"]["memory_gb"], CITED["scale.postgres"]["storage_gb"]))
        rd = p["stores"]["redis"]["spec"]["instance"]
        self.assertEqual(rd["maxmemory_policy"], "noeviction")
        self.assertGreaterEqual(rd["memory_gib_per_shard"] * rd["shards"], p["stores"]["redis"]["memory_gi"])
        self.assertNotIn("postgres", p["pools"]["app"]["pods"])

    def test_operator_stores_are_instances_times_the_pod_and_redis_gets_sentinels(self) -> None:
        p = size(postgres="operator", redis="operator", survives_node_loss=True)
        spec = {k: p["stores"][k]["spec"] for k in ("postgres", "redis")}
        self.assertEqual((spec["postgres"]["instances"], spec["redis"]["instances"], spec["redis"]["extra"][0]["instances"]), (3, 3, 3))
        one = size(postgres="operator", redis="operator")
        self.assertEqual((one["stores"]["postgres"]["spec"]["instances"], one["stores"]["redis"]["spec"]["extra"]), (1, []))
        self.assertIn("operator", p["configure"]["redis"]["instruction"])

    def test_the_metastore_and_the_object_store_follow_the_tier_and_the_bytes(self) -> None:
        p = size(smithdb_metastore="statefulset", object_store="in-cluster")
        tier = p["smithdb"]["tier"]
        pod = p["stores"]["smithdb_metastore"]["spec"]["per_instance"]
        self.assertEqual((pod["requests"]["cpu"], pod["requests"]["memory_gib"]), (CITED["smithdb.metastore"][tier]["cpu"], CITED["smithdb.metastore"][tier]["memory_gib"]))
        obj = p["stores"]["object_storage"]["spec"]["per_instance"]
        self.assertGreaterEqual(obj["volume_gib"], p["stores"]["object_storage"]["total_tb"] * 1e12 / 2**30)
        self.assertEqual(p["values"]["smithdb"]["config"]["objectStore"]["s3"]["endpoint"], "<in-cluster object store endpoint>")

    def test_an_in_cluster_object_store_warns_past_the_load_it_was_measured_at(self) -> None:
        # The warning once fired on the payload's tested rate (300 traces/s) while saying the store was measured to 80.
        measured = P["datastores.object_store_measured_traces_per_second"]
        def warned(peak: float) -> bool:
            p = size(traces_per_second=peak / 2, peak_traces_per_second=peak, object_store="in-cluster")
            return "object-store-unmeasured" in {w["id"] for w in p["warnings"]}
        self.assertEqual((warned(measured), warned(measured + 20)), (False, True))
        self.assertFalse("object-store-unmeasured" in {w["id"] for w in size(traces_per_second=200, peak_traces_per_second=400)["warnings"]})

    def test_the_bucket_spec_has_the_lifecycle_rules_of_the_ttl_prefixes(self) -> None:
        rules = size()["stores"]["object_storage"]["spec"]["instance"]["langsmith"]["lifecycle_rules"]
        self.assertEqual([r["prefix"] for r in rules], ["ttl_s/", "ttl_l/"])

    def test_clickhouse_is_placed_only_while_dual(self) -> None:
        self.assertIsNone(size()["stores"]["clickhouse"])
        ch = size(trace_store="dual-replicated", clickhouse="operator")["stores"]["clickhouse"]
        self.assertEqual((ch["placement"], ch["spec"]["instances"], ch["fits_app_node"]), ("operator", 3, False))

    def test_the_old_internal_redis_is_refused(self) -> None:
        with self.assertRaisesRegex(ValueError, "redis is one of external, statefulset, operator"):
            size(redis="internal")
        with self.assertRaisesRegex(ValueError, "object_store is one of"):
            size(object_store="statefulset")


@needs_helm
class Outputs(unittest.TestCase):
    def run_cli(self, *argv: str) -> str:
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(cli.main(list(argv)), 0)
        return out.getvalue()

    def test_values_prints_yaml_opening_with_what_to_fill(self) -> None:
        text = self.run_cli("values", "--chart", CHART, "--preset", "production")
        self.assertTrue(text.startswith("# langsmith-sizing"))
        self.assertIn("# fill: postgres.external.existingSecretName", text)

    def test_stores_prints_each_placement_and_spec(self) -> None:
        doc = json.loads(self.run_cli("stores", "--chart", CHART, "--preset", "production", "--redis", "operator", "--survives-node-loss"))
        self.assertEqual(doc["stores"]["redis"]["placement"], "operator")
        self.assertEqual(doc["stores"]["redis"]["spec"]["instances"], 3)

    def scripted(self, answers: list[str], **kw: Any) -> tuple[int, list[str], str]:
        asked: list[str] = []
        queue = iter(answers)
        shown = io.StringIO()

        def ask(prompt: str) -> str:
            # what the screen held when the question was put: the block above the prompt
            asked.append(shown.getvalue()[sum(len(a) for a in asked):])
            return next(queue)

        with tempfile.TemporaryDirectory() as d, redirect_stdout(shown):
            out = Path(d) / "acme"
            code = wizard.run(chart_version=CHART, preset_name=kw.get("preset"), given=kw.get("given", {}), yes=kw.get("yes", False), out=out, ask=ask)
            self.files = sorted(f.name for f in out.iterdir()) if out.exists() else []
            self.plan = json.loads((out / "plan.json").read_text()) if out.exists() else {}
            self.saved = (out / "inputs.yaml").read_text() if out.exists() else ""
        return code, asked, shown.getvalue()

    # preset production: users, average, peak, runs, retention, trace store, node loss, products, 4 stores, 2 nodes, confirm.
    # Every store is external, so where in-cluster stores run, and their node, are not asked.
    PRODUCTION = ["25", "33", "100", "", "", "1", "yes", "", "external", "external", "external", "external", "", "", "y"]
    # no preset: the picker, users, average, peak, runs, retention, trace store, node loss, products, 4 stores, where, 2 nodes, confirm
    SCRATCH = ["none", "5", "3", "10", "", "", "smithdb", "no", "", "statefulset", "statefulset", "statefulset", "external", "app", "", "", "y"]

    def test_the_wizard_asks_each_input_with_its_default_and_source_and_saves_the_folder(self) -> None:
        code, asked, _ = self.scripted(self.PRODUCTION, preset="production")
        self.assertEqual(code, 0)
        self.assertEqual(self.files, ["inputs.yaml", "load-profile.json", "plan.json", "stores.json", "summary.md", "values.yaml"])
        self.assertIn("preset production", asked[0])
        self.assertIn("The scale guide's Medium read load", asked[0])
        runs = next(a for a in asked if "runs_per_trace" in a)
        self.assertRegex(runs, r"default +10 +preset production: The model's default of 10 runs a trace")
        days = next(a for a in asked if "retention_days" in a)
        self.assertRegex(days, r"default +14 +the chart's default, config.ttl.ttl_period_seconds.shortlived")
        self.assertEqual(self.plan["inputs"]["users"], 25)
        self.assertEqual(self.plan["inputs"]["trace_store"], "smithdb")

    def test_products_are_asked_by_number_and_bring_their_own_questions(self) -> None:
        names = [n for n in wizard.CATALOG if n != "traces"]
        engine = str(names.index("engine") + 1)
        # Engine brings Sandboxes, so the four sandbox questions follow it: how many, vCPU, GiB, node
        answers = self.SCRATCH[:8] + [engine, "30", "", "4", ""] + self.SCRATCH[9:]
        _, asked, _ = self.scripted(answers, given={})
        self.assertTrue(any("sandbox_node" in a for a in asked))
        self.assertEqual(self.plan["products"]["on"], [n for n in wizard.CATALOG if n in ("traces", "engine", "sandboxes")])
        self.assertEqual(self.plan["products"]["sandboxes"]["concurrent"], 30)
        self.assertIn("products:", self.saved)

    def test_a_months_count_is_taken_as_the_average(self) -> None:
        answers = self.SCRATCH[:2] + ["3M/month"] + self.SCRATCH[3:]
        self.scripted(answers, given={})
        self.assertEqual(self.plan["rates"]["traces_per_month"], 3_000_000)

    def test_a_note_the_person_wrote_survives_a_re_plan(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "acme"
            out.mkdir()
            (out / "inputs.yaml").write_text("why: Their words.\ninputs:\n  users: 8\n  traces_per_month: 3000000\n  app_node: [16, 64]\nnotes:\n  users: Their lead said 8.\n  traces_per_month: October dashboard.\n  app_node: n2-standard-16.\n")
            with redirect_stdout(io.StringIO()):
                self.assertEqual(cli.main(["plan", "--out", str(out)]), 0)
            saved = (out / "inputs.yaml").read_text()
        for kept in ("why: Their words.", "users: Their lead said 8.", "traces_per_month: October dashboard.", "app_node: n2-standard-16."):
            self.assertIn(kept, saved)

    def test_a_blank_required_answer_twice_stops_without_writing(self) -> None:
        with self.assertRaisesRegex(ValueError, "left blank twice"):
            self.scripted(["none", "", ""], given={})

    def test_the_saved_inputs_size_the_same_plan_again(self) -> None:
        self.scripted(self.PRODUCTION, preset="production")
        first = self.plan
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "acme"
            out.mkdir()
            (out / "inputs.yaml").write_text(self.saved)
            with redirect_stdout(io.StringIO()):
                self.assertEqual(cli.main(["plan", "--out", str(out)]), 0)
            again = json.loads((out / "plan.json").read_text())
        self.assertEqual(again, first)
        self.assertIn("chart: " + CHART, self.saved)
        self.assertIn("users: Answered in the wizard", self.saved)
        self.assertNotIn("datastores_on", self.saved)

    def test_saying_no_at_the_end_writes_nothing(self) -> None:
        code, _, _ = self.scripted(self.PRODUCTION[:-1] + ["n"], preset="production")
        self.assertEqual((code, self.files), (1, []))

    def test_a_bad_answer_is_asked_again(self) -> None:
        answers = self.SCRATCH[:1] + ["lots"] + self.SCRATCH[1:]
        _, _, shown = self.scripted(answers, given={})
        self.assertIn("not understood", shown)
        self.assertEqual(self.plan["inputs"]["redis"], "statefulset")

    def test_a_choice_takes_its_number(self) -> None:
        answers = list(self.SCRATCH)
        answers[10] = "3"  # redis: the third placement
        self.scripted(answers, given={})
        self.assertEqual(self.plan["inputs"]["redis"], "operator")

    def test_an_empty_answer_to_a_required_input_is_asked_again(self) -> None:
        answers = self.SCRATCH[:1] + [""] + self.SCRATCH[1:]
        _, asked, shown = self.scripted(answers, given={})
        self.assertIn("users has no default", shown)
        self.assertEqual(self.plan["inputs"]["users"], 5)

    def test_every_input_given_with_yes_asks_nothing(self) -> None:
        code, asked, _ = self.scripted([], preset="production", yes=True, given={"users": 10.0})
        self.assertEqual((code, asked), (0, []))
        self.assertEqual(self.plan["inputs"]["users"], 10)

    def test_the_overhead_line_is_the_sized_requests_times_overhead(self) -> None:
        plan_ = size(users=2, traces_per_second=1, peak_traces_per_second=3)
        sized, overhead = plan_["totals"]["sized"]["requests"]["cpu"], plan_["totals"]["overhead"]
        note = summary.sections(plan_).tables[0].note
        self.assertIn(f"overhead: {round(sized * overhead, 1):g} vCPU", note)

    def test_parse_refuses_what_the_input_does_not_take(self) -> None:
        q = next(x for x in wizard.QUESTIONS if x.name == "redis")
        with self.assertRaises(ValueError):
            wizard.parse(q, "internal")
        self.assertEqual(wizard.parse(q, "2"), "statefulset")
        with self.assertRaises(ValueError):
            wizard.parse(q, "4")
        self.assertEqual(wizard.parse(next(x for x in wizard.QUESTIONS if x.name == "app_node"), "8x32"), (8.0, 32.0))
        self.assertEqual(inputs.PLACEMENTS, ("external", "statefulset", "operator"))


if __name__ == "__main__":
    unittest.main()
