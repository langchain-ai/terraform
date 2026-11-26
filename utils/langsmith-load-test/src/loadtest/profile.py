"""The load to send: a load profile from the sizing package, or the model's defaults.

`langsmith-sizing load-profile` writes schema "langsmith-load-profile/1" for a plan, so a test sends
the load the plan was sized for. Without a file the same numbers come from params.yaml
(`langsmith_sizing.params`), which needs neither helm nor a chart. The payload mix exists there
once; this tool keeps no table of its own.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from langsmith_sizing import params as sizing_params
from langsmith_sizing.profile import SCHEMA

READ_CLASSES = ("list_traces", "read_trace", "project_stats", "feedback_stats", "heavy_filter")
SINGLE = "single"
CONTENTS = ("text", "json", "base64")
SENDS = ("post_then_patch", "post_once")
TRACES = ("simple", "agent")


@dataclass(frozen=True)
class Shape:
    """How a run's bytes are shaped and sent, beyond their size (params load.payload_shape)."""

    traces: str = "simple"
    fields_per_side: int = 1
    content: str = "text"
    send: str = "post_then_patch"
    attachment_kib_per_run: float = 0.0
    projects: int = 1
    project_skew: float = 1.0
    metadata_keys: int = 0
    batch_runs: int = 100

    def __post_init__(self) -> None:
        for name in ("fields_per_side", "projects", "batch_runs"):
            value = getattr(self, name)
            if isinstance(value, bool) or not isinstance(value, int) or value < 1:
                raise ProfileError(f"{name} must be a whole number of at least 1, got {value!r}")
        if isinstance(self.metadata_keys, bool) or not isinstance(self.metadata_keys, int) or self.metadata_keys < 0:
            raise ProfileError(f"metadata_keys must be a whole number of 0 or more, got {self.metadata_keys!r}")
        _number(self.project_skew, "project_skew")
        if self.content not in CONTENTS:
            raise ProfileError(f"content is one of {', '.join(CONTENTS)}, got {self.content!r}")
        if self.traces not in TRACES:
            raise ProfileError(f"traces is one of {', '.join(TRACES)}, got {self.traces!r}")
        if self.send not in SENDS:
            raise ProfileError(f"send is one of {', '.join(SENDS)}, got {self.send!r}")
        _number(self.attachment_kib_per_run, "attachment_kib_per_run")


class ProfileError(ValueError):
    pass


@dataclass(frozen=True)
class Profile:
    traces_per_second: float | None
    peak_traces_per_second: float | None
    runs_per_trace: float
    mix: dict[str, float]
    sizes_kib: dict[str, tuple[float, float]]
    feedback_per_trace: float
    read_requests_per_second: float | None
    read_mix: dict[str, dict[str, Any]]
    heavy_window_days: float
    targets: dict[str, float]
    shape: Shape = field(default_factory=Shape)
    document: dict[str, Any] = field(default_factory=dict)


def _get(document: dict[str, Any], *path: str) -> Any:
    node: Any = document
    for key in path:
        if not isinstance(node, dict) or key not in node:
            raise ProfileError(f"profile is missing {'.'.join(path)}")
        node = node[key]
    return node


def _number(value: Any, name: str, *, positive: bool = False) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0 or (positive and value == 0):
        raise ProfileError(f"{name} must be a {'positive' if positive else 'non-negative'} number, got {value!r}")
    return float(value)


def _payload(mix: dict[str, Any], sizes: dict[str, Any], single: Any) -> tuple[dict[str, float], dict[str, tuple[float, float]]]:
    if single:
        in_kib, out_kib = single
        return {SINGLE: 100.0}, {SINGLE: (_number(in_kib, "single_run_kib[0]", positive=True), _number(out_kib, "single_run_kib[1]", positive=True))}
    if not mix:
        raise ProfileError("write.payload.mix is empty")
    weights = {name: _number(weight, f"mix.{name}") for name, weight in mix.items()}
    if sum(weights.values()) <= 0:
        raise ProfileError("write.payload.mix sums to zero")
    missing = [name for name in weights if name not in sizes]
    if missing:
        raise ProfileError(f"write.payload.sizes_kib has no size for {', '.join(missing)}")
    return weights, {
        name: (_number(sizes[name]["in"], f"sizes_kib.{name}.in", positive=True), _number(sizes[name]["out"], f"sizes_kib.{name}.out", positive=True))
        for name in weights
    }


def _shape(payload: dict[str, Any]) -> Shape:
    return Shape(
        traces=_get(payload, "traces"), fields_per_side=_get(payload, "fields_per_side"), content=_get(payload, "content"), send=_get(payload, "send"),
        attachment_kib_per_run=_number(_get(payload, "attachment_kib_per_run"), "write.payload.attachment_kib_per_run"),
        projects=_get(payload, "projects"), project_skew=_number(_get(payload, "project_skew"), "write.payload.project_skew"),
        metadata_keys=_get(payload, "metadata_keys"), batch_runs=_get(payload, "batch_runs"),
    )


def _read_mix(raw: dict[str, Any]) -> dict[str, dict[str, Any]]:
    unknown = [name for name in raw if name not in READ_CLASSES]
    if unknown:
        raise ProfileError(f"read.mix names classes this tool cannot send: {', '.join(unknown)}")
    for name, entry in raw.items():
        _number(entry["weight"], f"read.mix.{name}.weight")
    if sum(entry["weight"] for entry in raw.values()) <= 0:
        raise ProfileError("read.mix sums to zero")
    return {name: dict(entry) for name, entry in raw.items()}


def _targets(raw: dict[str, Any]) -> dict[str, float]:
    return {
        "stored_within_seconds": _number(_get(raw, "stored_within_seconds", "p99"), "targets.stored_within_seconds.p99", positive=True),
        "trace_load_seconds": _number(_get(raw, "trace_load_seconds", "p99"), "targets.trace_load_seconds.p99", positive=True),
    }


def from_document(document: dict[str, Any]) -> Profile:
    if not isinstance(document, dict) or document.get("schema") != SCHEMA:
        found = document.get("schema") if isinstance(document, dict) else type(document).__name__
        raise ProfileError(f"profile schema is {found!r}, this tool reads {SCHEMA!r}")
    mix, sizes = _payload(
        _get(document, "write", "payload", "mix"), _get(document, "write", "payload", "sizes_kib"),
        _get(document, "write", "payload", "single_run_kib"),
    )
    return Profile(
        traces_per_second=_number(_get(document, "write", "traces_per_second"), "write.traces_per_second", positive=True),
        peak_traces_per_second=_number(_get(document, "write", "peak_traces_per_second"), "write.peak_traces_per_second", positive=True),
        runs_per_trace=_number(_get(document, "write", "runs_per_trace"), "write.runs_per_trace", positive=True),
        mix=mix,
        sizes_kib=sizes,
        feedback_per_trace=_number(_get(document, "write", "feedback_per_trace"), "write.feedback_per_trace"),
        read_requests_per_second=_number(_get(document, "read", "requests_per_second"), "read.requests_per_second"),
        read_mix=_read_mix(_get(document, "read", "mix")),
        heavy_window_days=_number(_get(document, "read", "heavy_window_days"), "read.heavy_window_days", positive=True),
        targets=_targets(_get(document, "targets")),
        shape=_shape(_get(document, "write", "payload")),
        document=document,
    )


def from_file(path: Path) -> Profile:
    try:
        document = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ProfileError(f"cannot read profile {path}: {error}") from error
    return from_document(document)


def from_params() -> Profile:
    """The model's defaults, with no rate: the rate comes from the command line."""
    p = sizing_params.values(sizing_params.load())
    mix, sizes = _payload(p["payload.mix_default"], p["payload.bucket_kib"], None)
    return Profile(
        traces_per_second=None,
        peak_traces_per_second=None,
        runs_per_trace=_number(p["load.runs_per_trace"], "load.runs_per_trace", positive=True),
        mix=mix,
        sizes_kib=sizes,
        feedback_per_trace=_number(p["load.feedback_per_trace"], "load.feedback_per_trace"),
        read_requests_per_second=None,
        read_mix=_read_mix(p["load.read_mix"]),
        heavy_window_days=_number(p["load.heavy_window_days"], "load.heavy_window_days", positive=True),
        targets=_targets({"stored_within_seconds": p["slo.stored_within_seconds"], "trace_load_seconds": p["slo.trace_load_seconds"]}),
        shape=_shape({**p["load.payload_shape"], "attachment_kib_per_run": 0.0}),
        document={"schema": SCHEMA, "source": "langsmith_sizing params defaults"},
    )
