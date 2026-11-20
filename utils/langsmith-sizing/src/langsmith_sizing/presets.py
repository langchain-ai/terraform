"""Named loads: presets/<name>.yaml holds a why, the inputs and a note for each input.

A preset is inputs, never a size. One that could not be sized, or that carries a figure Inputs does
not know, is refused at load, so a typo in a preset fails here and not as a silently ignored key.

A sizing the wizard or `plan` saves is the same file, `<out>/inputs.yaml`, with the chart it was
sized on: `--preset <out>/inputs.yaml` sizes it again, so a customer's answers are data that can
be re-sized on a new chart and never have to be typed twice.
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
    chart: str | None = None
    """The chart a saved sizing was made on; a named preset is for any chart and has none."""
    saved: bool = False
    """A sizing's own inputs.yaml, not a named preset: its why and notes are the person's and are kept."""

    def to_inputs(self, chart_version: str, **overrides: Any) -> Inputs:
        """The preset's inputs on a chart, with each given override replacing the preset's value.
        An override of either traces field replaces the preset's average, so the two never collide."""
        merged: dict[str, Any] = {k: tuple(v) if isinstance(v, list) else v for k, v in self.inputs.items()}
        if {"traces_per_second", "traces_per_month"} & overrides.keys():
            merged.pop("traces_per_second", None)
        return Inputs(chart_version=chart_version, **(merged | overrides))


def names(directory: Path = PRESETS) -> list[str]:
    return sorted(f.stem for f in directory.glob("*.yaml"))


def is_file(name: str) -> bool:
    """A path to a saved sizing rather than a preset's name."""
    return name.endswith((".yaml", ".yml")) or "/" in name


def load(name: str, directory: Path = PRESETS) -> Preset:
    """A named preset, or a saved sizing's inputs.yaml when `name` is a path."""
    saved = is_file(name)
    path = Path(name) if saved else directory / f"{name}.yaml"
    if not path.is_file():
        raise PresetError(f"no file {name}" if saved else f"no preset {name!r}; the presets are {', '.join(names(directory))}")
    doc = yaml.safe_load(path.read_text())
    keys = {"why", "inputs", "notes"} | ({"chart"} if saved else set())
    if not isinstance(doc, dict) or not {"why", "inputs", "notes"} <= set(doc) <= keys:
        raise PresetError(f"{name}: a preset has exactly why, inputs and notes" + (", and a saved sizing may add chart" if saved else ""))
    if not str(doc["why"]).strip():
        raise PresetError(f"{name}: why is empty")
    given, notes = doc["inputs"], doc["notes"]
    _check_inputs(name, given, notes, saved)
    return Preset(path.parent.name if saved else name, str(doc["why"]), given, notes, str(doc["chart"]) if doc.get("chart") else None, saved)


def _check_inputs(name: str, given: dict[str, Any], notes: dict[str, Any], saved: bool) -> None:
    known = {f.name for f in fields(Inputs)} - {"chart_version"}
    if unknown := sorted(set(given) - known):
        raise PresetError(f"{name}: inputs Inputs does not have: {', '.join(unknown)}")
    # A saved sizing may give the average alone: the person answered what they knew, and the peak
    # factor fills the rest. A named preset states both, so the default factor never moves it.
    if saved:
        absent = [] if {"traces_per_second", "traces_per_month"} & set(given) else ["traces_per_second"]
    else:
        absent = [k for k in RATES if k not in given]
    if absent:
        raise PresetError(f"{name}: inputs lack {', '.join(absent)}")
    if bare := sorted(set(given) - set(notes)):
        raise PresetError(f"{name}: no note for {', '.join(bare)}")


def save(path: Path, p: Preset) -> None:
    """Write a sizing's inputs where `load` reads them back."""
    doc: dict[str, Any] = {"why": p.why}
    if p.chart:
        doc["chart"] = p.chart
    doc["inputs"] = {k: list(v) if isinstance(v, tuple) else v for k, v in p.inputs.items()}
    doc["notes"] = {k: p.notes[k] for k in p.inputs}
    path.write_text(yaml.safe_dump(doc, sort_keys=False, allow_unicode=True))
