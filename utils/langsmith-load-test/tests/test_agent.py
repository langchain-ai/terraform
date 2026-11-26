"""Agent traces: the same trace for the same seed, an agent's structure, its context resent, and sizes on
the calibration params.yaml states (load.agent_trace)."""

import json
import random
import statistics
import unittest

from loadtest.payloads.agent import AgentModel, AgentRun, AgentTraces, plan, runs_per_trace

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


if __name__ == "__main__":
    unittest.main()
