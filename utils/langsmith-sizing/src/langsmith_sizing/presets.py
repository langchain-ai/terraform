"""Named loads: presets/<name>.yaml holds a why, the inputs and a note for each input.

A preset is inputs, never a size. One that could not be sized, or that carries a figure Inputs does
not know, is refused at load, so a typo in a preset fails here and not as a silently ignored key.
"""

from __future__ import annotations

from dataclasses import dataclass, fields
from pathlib import Path
from typing import Any

import yaml

from langsmith_sizing import ROOT
from langsmith_sizing.inputs import Inputs

PRESETS = ROOT / "presets"
RATES = ("peak_traces_per_second", "traces_per_second")
"""Both are required: the model's default peak factor and runs a trace move a plan severalfold, so a preset says its busiest rate and its average."""


class PresetError(ValueError):
    pass


@dataclass(frozen=True)
class Preset:
    name: str
    why: str
    inputs: dict[str, Any]
    notes: dict[str, str]

    def to_inputs(self, chart_version: str, **overrides: Any) -> Inputs:
        """The preset's inputs on a chart, with each given override replacing the preset's value.
        An override of either traces field replaces the preset's average, so the two never collide."""
        merged: dict[str, Any] = {k: tuple(v) if isinstance(v, list) else v for k, v in self.inputs.items()}
        if {"traces_per_second", "traces_per_month"} & overrides.keys():
            merged.pop("traces_per_second", None)
        return Inputs(chart_version=chart_version, **(merged | overrides))


def names(directory: Path = PRESETS) -> list[str]:
    return sorted(f.stem for f in directory.glob("*.yaml"))


def load(name: str, directory: Path = PRESETS) -> Preset:
    path = directory / f"{name}.yaml"
    if not path.is_file():
        raise PresetError(f"no preset {name!r}; the presets are {', '.join(names(directory))}")
    doc = yaml.safe_load(path.read_text())
    if not isinstance(doc, dict) or set(doc) != {"why", "inputs", "notes"}:
        raise PresetError(f"{name}: a preset has exactly why, inputs and notes")
    if not str(doc["why"]).strip():
        raise PresetError(f"{name}: why is empty")
    given, notes = doc["inputs"], doc["notes"]
    known = {f.name for f in fields(Inputs)} - {"chart_version"}
    if unknown := sorted(set(given) - known):
        raise PresetError(f"{name}: inputs Inputs does not have: {', '.join(unknown)}")
    if absent := [k for k in RATES if k not in given]:
        raise PresetError(f"{name}: inputs lack {', '.join(absent)}")
    if bare := sorted(set(given) - set(notes)):
        raise PresetError(f"{name}: no note for {', '.join(bare)}")
    return Preset(name, str(doc["why"]), given, notes)
