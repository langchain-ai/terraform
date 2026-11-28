"""Agent traces: the same trace for the same seed, an agent's structure, its context resent, and sizes on
the calibration params.yaml states (load.agent_trace)."""

import dataclasses
import json
import random
import statistics
import unittest

from loadtest.payloads.agent import KIB, WRAPPERS, AgentModel, AgentRun, AgentTraces, plan, runs_per_trace

MODEL = AgentModel.from_params()


def model_calls(trace: AgentRun) -> list[AgentRun]:
    return [run for run in trace.walk() if run.run_type == "llm"]


class AgentTraceTest(unittest.TestCase):
    def test_trace_n_is_the_same_for_the_same_seed_and_differs_for_another(self) -> None:
        def body(trace: AgentRun) -> str:
            return json.dumps([(r.name, r.inputs, r.outputs, r.metadata) for r in trace.walk()])

        self.assertEqual(body(AgentTraces(MODEL, 3).trace(41)), body(AgentTraces(MODEL, 3).trace(41)))
        self.assertNotEqual(body(AgentTraces(MODEL, 3).trace(41)), body(AgentTraces(MODEL, 4).trace(41)))
        self.assertNotEqual(body(AgentTraces(MODEL, 3).trace(41)), body(AgentTraces(MODEL, 3).trace(42)))

    def test_every_turn_is_a_model_node_and_every_tool_call_a_tool_run_until_an_answer(self) -> None:
        traces = AgentTraces(MODEL, 1)
        agentic = 0
        for number in range(1, 200):
            trace = traces.trace(number)
            self.assertEqual((trace.name, trace.run_type), ("agent", "chain"))
            nodes = trace.children
            self.assertEqual([n.name for n in nodes[::2]], ["model"] * len(nodes[::2]))
            self.assertEqual([n.name for n in nodes[1::2]], ["tools"] * len(nodes[1::2]))
            for model, tools in zip(nodes[::2], nodes[1::2], strict=False):
                message = model.outputs["messages"][0]
                self.assertEqual(len(tools.children), len(message["tool_calls"]))
                self.assertEqual({t.run_type for t in tools.children}, {"tool"})
            self.assertNotIn("tool_calls", nodes[-1].outputs["messages"][0])  # it ends on an answer
            self.assertEqual(trace.outputs["messages"], nodes[-1].outputs["messages"])
            agentic += len(nodes) > 1
        self.assertGreater(agentic, 30)

    def test_every_model_call_resends_the_conversation_so_far(self) -> None:
        traces = AgentTraces(MODEL, 1)
        trace = next(t for t in (traces.trace(n) for n in range(1, 500)) if len(model_calls(t)) >= 3)
        calls = model_calls(trace)
        for earlier, later in zip(calls, calls[1:], strict=False):
            sent = earlier.inputs["messages"]
            self.assertEqual(later.inputs["messages"][: len(sent)], sent)
            self.assertGreater(len(later.inputs["messages"]), len(sent))
        self.assertEqual(calls[0].inputs["messages"][0]["role"], "system")

    def test_payload_bytes_are_every_run_as_json(self) -> None:
        trace = AgentTraces(MODEL, 1).trace(9)
        self.assertEqual(trace.payload_bytes(), sum(len(json.dumps(r.inputs)) + len(json.dumps(r.outputs)) for r in trace.walk()))

    def test_the_mean_runs_a_trace_is_the_same_every_time(self) -> None:
        self.assertEqual(runs_per_trace(MODEL), runs_per_trace(MODEL))


class CalibrationTest(unittest.TestCase):
    """The bands params.yaml's load.agent_trace says the model lands in, over 4,000 planned traces: a change
    to its numbers that moves the traces off what customers send fails here."""

    @classmethod
    def setUpClass(cls) -> None:
        source = random.Random(1)
        cls.plans = [plan(MODEL, source) for _ in range(4000)]
        cls.runs = [run for p in cls.plans for run in p.walk()]

    def test_runs_a_trace_are_mostly_few_with_a_long_tail(self) -> None:
        per = [sum(1 for _ in p.walk()) for p in self.plans]
        self.assertTrue(3 <= statistics.median(per) <= 5, statistics.median(per))
        self.assertTrue(9 <= statistics.mean(per) <= 11.5, statistics.mean(per))
        self.assertTrue(50 <= statistics.quantiles(per, n=100)[98] <= 100)

    def test_most_traces_call_the_model_once(self) -> None:
        calls = [sum(r.run_type == "llm" for r in p.walk()) for p in self.plans]
        self.assertEqual(statistics.median(calls), 1)
        self.assertTrue(2.0 <= statistics.mean(calls) <= 2.6, statistics.mean(calls))

    def test_run_sizes_and_where_the_bytes_are(self) -> None:
        sizes = [r.kib() for r in self.runs]
        self.assertTrue(12 <= statistics.median(sizes) <= 22, statistics.median(sizes))
        self.assertTrue(30 <= statistics.mean(sizes) <= 55, statistics.mean(sizes))
        chains = sum(r.kib() for p in self.plans for r in list(p.walk())[1:] if r.run_type == "chain")
        models = sum(r.kib() for r in self.runs if r.run_type == "llm")
        self.assertTrue(0.6 <= chains / sum(sizes) <= 0.8)
        self.assertTrue(0.2 <= models / sum(sizes) <= 0.35)


class CodingTest(unittest.TestCase):
    """load.coding_trace lands on what LangChain's production coding agent sent (params.yaml's source): traces
    of about 1,300 runs, nearly all tiny middleware chains, model calls of hundreds of KB, about 13 KB a run."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.model = AgentModel.from_params("coding")
        source = random.Random(1)
        cls.plans = [plan(cls.model, source) for _ in range(600)]
        cls.runs = [r for p in cls.plans for r in p.walk()]

    def test_traces_hold_about_1300_runs_nearly_all_chains(self) -> None:
        per = [sum(1 for _ in p.walk()) for p in self.plans]
        self.assertTrue(1000 <= statistics.mean(per) <= 1600, statistics.mean(per))
        self.assertGreater(sum(r.run_type == "chain" for r in self.runs) / len(self.runs), 0.95)

    def test_model_calls_carry_hundreds_of_kb_and_a_run_about_13(self) -> None:
        calls = [r.kib() * KIB for r in self.runs if r.run_type == "llm"]
        self.assertTrue(250_000 <= statistics.median(calls) <= 450_000, statistics.median(calls))
        self.assertTrue(10_000 <= statistics.mean(r.kib() * KIB for r in self.runs) <= 20_000)

    def test_middleware_carries_its_own_bytes_not_the_conversation(self) -> None:
        wrappers = [r.kib() for r in self.runs if r.name in WRAPPERS]
        self.assertLess(statistics.median(wrappers), 1)

    def test_compaction_replaces_the_conversation_with_a_summary(self) -> None:
        small = dataclasses.replace(self.model, context_kib=300.0)
        calls = [r.kib() for p in (plan(small, random.Random(n)) for n in range(200)) for r in p.walk() if r.run_type == "llm"]
        self.assertLess(statistics.median(calls), statistics.median(r.kib() for r in self.runs if r.run_type == "llm"))

if __name__ == "__main__":
    unittest.main()
