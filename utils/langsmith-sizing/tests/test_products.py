"""The products beside tracing: which run, that the values run exactly those, and that every pod they
add is counted, on both chart lines."""

import unittest
from typing import Any

from langsmith_sizing import PLANNED_CHARTS, values
from langsmith_sizing.chart import merge
from langsmith_sizing.model import products
from tests.helpers import CITED, P, chart_at, chart_or_skip, needs_helm, size

CAT = products.catalog()
ALL = tuple(CAT)


class Chosen(unittest.TestCase):
    def test_tracing_always_runs_and_a_product_brings_what_it_requires(self) -> None:
        on, added = products.chosen(["engine"], CAT)
        self.assertEqual(on, [n for n in CAT if n in ("traces", "engine", "sandboxes")])
        self.assertEqual(added, {"sandboxes": "engine"})

    def test_an_unknown_product_is_refused_with_the_known_ones(self) -> None:
        with self.assertRaisesRegex(ValueError, "no agents; the products are traces"):
            products.chosen(["agents"], CAT)

    def test_every_product_not_chosen_is_switched_off_since_insights_and_chat_default_on(self) -> None:
        v = products.values(["traces"], CAT, P, values.placeholder)
        self.assertEqual(v["insights"], {"enabled": False})
        self.assertEqual(v["polly"], {"enabled": False})
        self.assertEqual(v["config"], {"deployment": {"enabled": False}})
        self.assertEqual(v["sandboxes"], {"enabled": False})

    def test_a_chosen_product_is_switched_on_its_unsized_pods_sized_and_its_keys_left_to_fill(self) -> None:
        v = products.values(["traces", "fleet"], CAT, P, values.placeholder)
        self.assertTrue(v["fleet"]["enabled"])
        self.assertEqual(v["fleet"]["encryptionKey"], "<encryptionKey>")
        want = P["products.pods"]["fleet"]["queue"]
        self.assertEqual(v["fleet"]["queue"]["deployment"]["resources"]["requests"], {"cpu": f"{want['cpu']:g}", "memory": f"{want['memory_gib']:g}Gi"})
        self.assertIn("fleet.encryptionKey", values.placeholders(v))


class Formulas(unittest.TestCase):
    def test_sandbox_hosts_are_the_docs_formula_with_the_charts_target_and_headroom(self) -> None:
        c = chart_at()
        # 100 sandboxes of 1 vCPU on 16 vCPU hosts at 70%: ceil(100 / 11.2) = 9, plus 1 headroom
        h = products.sandbox_hosts(100, 1, 2, {"cpu": 16, "memory_gib": 64}, c, CITED)
        self.assertEqual((h["hosts"], h["by"], h["cpu_autoscaler_short"]), (10, "cpu", False))

    def test_memory_sets_the_hosts_when_guests_outgrow_the_nodes(self) -> None:
        # 20 x 16 GiB = 320 GiB on 64 GiB hosts at 70%: ceil(320 / 44.8) = 8, plus 1; CPU needs 2
        h = products.sandbox_hosts(20, 0.5, 16, {"cpu": 16, "memory_gib": 64}, chart_at(), CITED)
        self.assertEqual((h["hosts"], h["by"], h["cpu_autoscaler_short"]), (9, "memory", True))

    def test_a_small_pool_keeps_the_docs_two_hosts(self) -> None:
        self.assertEqual(products.sandbox_hosts(1, 1, 2, {"cpu": 64, "memory_gib": 256}, chart_at(), CITED)["hosts"], 2)

    def test_agent_server_deployments_are_the_docs_table_times_the_count(self) -> None:
        a = products.agent_server(3, "mm", CITED)
        self.assertEqual(a["pods"]["agent-deployment-api-server"]["replicas"], 3 * CITED["agent_server.api_servers"]["replicas"]["mm"])
        self.assertEqual(a["pods"]["agent-deployment-postgres"]["requests"], {"cpu": 4, "memory_gib": 16})
        self.assertEqual(a["n_jobs_per_worker"], 10)
        with self.assertRaisesRegex(ValueError, "agent_load is one of"):
            products.agent_server(1, "xx", CITED)


@needs_helm
class Plans(unittest.TestCase):
    def plan(self, version: str, **kw: Any) -> dict[str, Any]:
        chart_or_skip(self, version)
        base: dict[str, Any] = {"users": 10, "traces_per_second": 5, "peak_traces_per_second": 15, "chart_version": version}
        return size(**(base | kw))

    def test_every_product_on_both_charts_is_counted_in_the_pools_and_the_totals(self) -> None:
        for version in PLANNED_CHARTS:
            with self.subTest(version):
                p = self.plan(version, products=ALL, agent_deployments=2, gateway_streams=300, sandboxes=40)
                pooled = {n for pl in p["pools"].values() if isinstance(pl, dict) and "pods" in pl for n in pl["pods"]}
                self.assertLessEqual(set(p["products"]["pods"]), pooled)
                self.assertEqual(p["pools"]["sandboxes"]["sized"]["nodes"], p["products"]["sandboxes"]["hosts"])
                alone = self.plan(version)
                self.assertGreater(p["totals"]["sized"]["requests"]["cpu"], alone["totals"]["sized"]["requests"]["cpu"])

    def test_the_values_render_exactly_the_product_pods_the_plan_counts(self) -> None:
        for version in PLANNED_CHARTS:
            with self.subTest(version):
                p = self.plan(version, products=("traces", "fleet", "insights", "polly", "gateway", "agent_server"))
                c = chart_at(version)
                cat = products.catalog()
                rendered = products.rendered_pods(c.render(merge(p["values"], p["products"]["render"])), p["products"]["on"], cat)
                counted = {n: x for n, x in p["products"]["pods"].items() if x["from"] != "docs"}
                self.assertEqual(set(rendered), set(counted))
                for n, x in rendered.items():
                    self.assertEqual(x["requests"], counted[n]["requests"], n)

    def test_a_tracing_only_plan_renders_no_product_pod(self) -> None:
        for version in PLANNED_CHARTS:
            with self.subTest(version):
                p = self.plan(version)
                c = chart_at(version)
                # Without our switches, keys set the way the docs say would run Insights and Chat.
                keys = {"insights": {"encryptionKey": "YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWE="}, "polly": {"encryptionKey": "YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWE="}}
                docs = c.render(merge(merge(p["values"], keys), {"insights": {"enabled": p["values"]["insights"]["enabled"]}}))
                self.assertEqual(products.rendered_pods(docs, list(CAT), CAT), {})

    def test_the_gateway_below_the_docs_tested_size_is_said(self) -> None:
        older = PLANNED_CHARTS[0]
        p = self.plan(older, products=("traces", "gateway"), gateway_streams=300)
        ids = [w["id"] for w in p["warnings"]]
        pod = next(x for x in p["products"]["pods"].values() if x["product"] == "gateway")
        tested = CITED["gateway.tested_requests"]
        self.assertEqual("gateway-below-tested" in ids, pod["requests"]["cpu"] < tested["cpu"])
        self.assertGreaterEqual(p["values"]["agentGateway"]["autoscaling"]["maxReplicas"], 3)

    def test_memory_bound_sandboxes_hold_their_hosts_as_the_autoscalers_floor(self) -> None:
        p = self.plan(PLANNED_CHARTS[0], products=("traces", "sandboxes"), sandboxes=20, sandbox_vcpu=0.5, sandbox_memory_gib=16)
        auto = p["values"]["sandboxes"]["sandboxHost"]["autoscaling"]
        self.assertEqual(auto["minReplicas"], p["products"]["sandboxes"]["hosts"])
        self.assertIn("sandboxes-memory-bound", [w["id"] for w in p["warnings"]])
        self.assertIn("sandboxes_juicefs_redis", p["stores"])


if __name__ == "__main__":
    unittest.main()
