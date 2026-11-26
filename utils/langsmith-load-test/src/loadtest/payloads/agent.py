"""Agent traces: what an application built on a chat model and tools sends, for --traces agent.

The simple traces (payloads/generator.py) give every run a size drawn on its own, in a flat tree of
ten. Real traces are shaped otherwise, and the shape decides how many runs a trace holds, where its
bytes are and how much of them repeat:

  agent                    chain   the new message                    the answer
    model                  chain   the conversation so far            the model's message
      prompt, ...          chain   the conversation so far            (wrappers: a runnable, middleware)
      chat_model           llm     system prompt + the conversation   the generation, the token usage
    tools                  chain   the conversation so far            the tool messages
      search, fetch, ...   tool    the call's arguments               the tool's result
    model ...                      until the model answers without calling a tool

Most traces are one model call; about one in three is an agent that calls tools for several turns.
Every model call carries the conversation so far, so a large tool result or a long thread is sent
again by every later run; the root holds only the new message and the answer, the thread being the
application's own state. Sizes and counts come from params.yaml's load.agent_trace, calibrated to what
customers send (its source says which measurements).

A trace is planned first, as sizes, then written: the plan alone gives the size distribution and the
mean runs a trace without generating text (`plan`, `runs_per_trace`). Each trace is drawn from its own
random stream, seeded by the test's seed and the trace's number, so trace N has the same structure and
the same text in every run with the same seed, whatever order the worker threads build them in.
"""

from __future__ import annotations

import json
import math
import random
from collections.abc import Iterator, Mapping
from dataclasses import dataclass, field
from typing import Any, Literal

from langsmith_sizing import params as sizing_params

from .english_text import generate_text

KIB = 1024
RunType = Literal["chain", "llm", "tool"]
# The seed when the test is given none: every agent run from the same code sends the same traces.
DEFAULT_SEED = 20261126
TOOLS = ("search", "fetch_document", "query_database", "read_file", "call_api")
WRAPPERS = ("prompt", "middleware", "RunnableSequence", "format_messages")
# What a LangChain chat model adds to its run's metadata, beside the application's own.
MODEL_METADATA = {"ls_provider": "openai", "ls_model_name": "gpt-4.1", "ls_model_type": "chat", "ls_temperature": 0.0, "ls_max_tokens": 4096}
# The bytes JSON adds around a message's text: its role, its keys, an id.
MESSAGE_OVERHEAD_KIB = 0.08


@dataclass(frozen=True)
class Spread:
    """A lognormal size in KiB: half the draws under `median`; `sigma` is the spread of its log."""

    median: float
    sigma: float
    most: float = math.inf

    def draw(self, source: random.Random) -> float:
        return min(self.median * math.exp(source.gauss(0, self.sigma)), self.most)


@dataclass(frozen=True)
class AgentModel:
    """params.yaml's load.agent_trace."""

    agentic_share: float
    tool_turns: float
    tools_per_turn: tuple[float, ...]
    wrappers: float
    history_messages: float
    system: Spread
    user: Spread
    history: Spread
    arguments: Spread
    result: Spread
    call: Spread
    answer: Spread

    @classmethod
    def from_params(cls) -> AgentModel:
        return cls.from_value(sizing_params.values(sizing_params.load())["load.agent_trace"])

    @classmethod
    def from_value(cls, v: Mapping[str, Any]) -> AgentModel:
        def spread(name: str) -> Spread:
            return Spread(float(v[name]["median"]), float(v[name]["sigma"]), float(v[name].get("max", math.inf)))

        return cls(
            agentic_share=float(v["agentic_share"]), tool_turns=float(v["tool_turns"]),
            tools_per_turn=tuple(float(w) for w in v["tools_per_turn"]), wrappers=float(v["wrappers"]),
            history_messages=float(v["history_messages"]), system=spread("system_kib"), user=spread("user_kib"),
            history=spread("history_kib"), arguments=spread("arguments_kib"), result=spread("result_kib"),
            call=spread("call_kib"), answer=spread("answer_kib"),
        )


def geometric(source: random.Random, mean: float) -> int:
    """A count of 0 or more with this mean, each further one as likely as the last, given it."""
    if mean <= 0:
        return 0
    return int(math.log(1.0 - source.random()) / math.log(mean / (mean + 1.0)))


def weighted_count(source: random.Random, weights: tuple[float, ...]) -> int:
    """1, 2, 3 ... drawn by weight."""
    return source.choices(range(1, len(weights) + 1), weights=weights)[0]


# ---- the plan: messages as sizes, runs as which messages they carry --------------------------------


@dataclass
class Message:
    role: str
    kib: float
    calls: list[Message] = field(default_factory=list)  # an assistant's tool calls, as their arguments
    name: str = ""  # a call's tool


@dataclass
class PlannedRun:
    name: str
    run_type: RunType
    inputs: list[Message]
    outputs: list[Message]
    metadata: dict[str, Any] = field(default_factory=dict)
    children: list[PlannedRun] = field(default_factory=list)

    def walk(self) -> Iterator[PlannedRun]:
        yield self
        for child in self.children:
            yield from child.walk()

    def kib(self) -> float:
        """About the bytes the run's inputs and outputs serialize to, in KiB."""
        return sum(m.kib + MESSAGE_OVERHEAD_KIB + sum(c.kib + MESSAGE_OVERHEAD_KIB for c in m.calls) for m in (*self.inputs, *self.outputs))


def plan(model: AgentModel, source: random.Random) -> PlannedRun:
    """One trace as sizes: its tree, and which messages each run carries."""
    system = Message("system", model.system.draw(source))
    state = [Message("user" if n % 2 == 0 else "assistant", model.history.draw(source)) for n in range(geometric(source, model.history_messages))]
    user = Message("user", model.user.draw(source))
    state.append(user)
    turns = 1 + geometric(source, model.tool_turns) if source.random() < model.agentic_share else 0
    root = PlannedRun("agent", "chain", [user], [])
    for step in range(turns + 1):
        last = step == turns
        if last:
            message = Message("assistant", model.answer.draw(source))
        else:
            calls = [Message("call", model.arguments.draw(source), name=TOOLS[source.randrange(len(TOOLS))]) for _ in range(weighted_count(source, model.tools_per_turn))]
            message = Message("assistant", model.call.draw(source), calls)
        root.children.append(_model_node(model, source, system, list(state), message, step))
        state.append(message)
        if not last:
            results = [Message("tool", model.result.draw(source)) for _ in message.calls]
            graph = {"langgraph_step": 2 * step + 2, "langgraph_node": "tools"}
            tools = [PlannedRun(call.name, "tool", [call], [result], dict(graph)) for call, result in zip(message.calls, results, strict=True)]
            root.children.append(PlannedRun("tools", "chain", list(state), results, graph, tools))
            state += results
        else:
            root.outputs = [message]
    return root


def _model_node(model: AgentModel, source: random.Random, system: Message, state: list[Message], message: Message, step: int) -> PlannedRun:
    graph = {"langgraph_step": 2 * step + 1, "langgraph_node": "model"}
    wrappers = [PlannedRun(WRAPPERS[source.randrange(len(WRAPPERS))], "chain", list(state), [], dict(graph)) for _ in range(geometric(source, model.wrappers))]
    call = PlannedRun("chat_model", "llm", [system, *state], [message], {**graph, **MODEL_METADATA})
    return PlannedRun("model", "chain", list(state), [message], graph, [*wrappers, call])


def runs_per_trace(model: AgentModel, seed: int | None = None, traces: int = 4000) -> float:
    """The mean runs an agent trace holds, from plans alone: to turn a rate in runs a second into traces a
    second. The same seed gives the same mean."""
    source = random.Random(f"{DEFAULT_SEED if seed is None else seed}:runs")
    return sum(sum(1 for _ in plan(model, source).walk()) for _ in range(traces)) / traces


# ---- the trace: the plan written as text, as the SDK sends it ------------------------------------


@dataclass
class AgentRun:
    """One run of an agent trace, with its children in the order they ran."""

    name: str
    run_type: RunType
    inputs: dict[str, Any]
    outputs: dict[str, Any]
    metadata: dict[str, Any] = field(default_factory=dict)
    children: list[AgentRun] = field(default_factory=list)

    def walk(self) -> Iterator[AgentRun]:
        yield self
        for child in self.children:
            yield from child.walk()

    def payload_bytes(self) -> int:
        """The bytes of every run's inputs and outputs, as JSON."""
        return sum(len(json.dumps(run.inputs)) + len(json.dumps(run.outputs)) for run in self.walk())


class AgentTraces:
    """Agent traces, trace N the same for every run with the same seed and model."""

    def __init__(self, model: AgentModel, seed: int | None = None) -> None:
        self.model = model
        self.seed = DEFAULT_SEED if seed is None else seed

    def trace(self, number: int) -> AgentRun:
        source = random.Random(f"{self.seed}:{number}")
        planned = plan(self.model, source)
        texts: dict[int, dict[str, Any]] = {}  # one text a message, however many runs carry it
        run = self._write(planned, source, texts, number)
        run.metadata["thread_id"] = f"thread-{self.seed}-{number}"
        return run

    def _message(self, m: Message, source: random.Random, texts: dict[int, dict[str, Any]], number: int) -> dict[str, Any]:
        if id(m) not in texts:
            body: dict[str, Any] = {"role": m.role, "content": generate_text(max(1, int(m.kib * KIB)), source)}
            if m.calls:
                body["tool_calls"] = [{"id": f"call-{number}-{len(texts)}-{n}", "name": c.name, "args": {"query": self._message(c, source, texts, number)["content"]}} for n, c in enumerate(m.calls)]
            texts[id(m)] = body
        return texts[id(m)]

    def _write(self, p: PlannedRun, source: random.Random, texts: dict[int, dict[str, Any]], number: int) -> AgentRun:
        def messages(ms: list[Message]) -> list[dict[str, Any]]:
            return [self._message(m, source, texts, number) for m in ms]

        if p.run_type == "tool":
            inputs: dict[str, Any] = {"input": json.dumps({"query": messages(p.inputs)[0]["content"]})}
            outputs: dict[str, Any] = {"output": messages(p.outputs)[0]["content"]}
        elif p.run_type == "llm":
            out = messages(p.outputs)[0]
            usage = {"prompt_tokens": int(sum(m.kib for m in p.inputs) * KIB / 4), "completion_tokens": int(p.outputs[0].kib * KIB / 4)}
            inputs, outputs = {"messages": messages(p.inputs)}, {"generations": [{"text": out["content"], "message": out}], "llm_output": {"token_usage": usage}}
        else:
            inputs, outputs = {"messages": messages(p.inputs)}, ({"messages": messages(p.outputs)} if p.outputs else {})
        return AgentRun(p.name, p.run_type, inputs, outputs, dict(p.metadata), [self._write(c, source, texts, number) for c in p.children])
