"""Which regime an install is in: the bands are data (params.yaml `regimes`), first match wins.

A regime is the load's kind, not a size: it says what to switch on (autoscalers, the dedicated
SmithDB services, a Redis cluster with partitions, node pools) and when the plan can no longer
claim a tested configuration.
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from typing import Any


def _holds(regime: Mapping[str, Any], tps: float, peak: float, bands: Mapping[str, float], peak_tps: float = 0.0, facts: Mapping[str, Any] | None = None) -> list[str] | None:
    """The reasons a regime's bounds hold, or None when one fails; an unbounded regime has none."""
    why: list[str] = []
    for fact, want in (regime.get("requires") or {}).items():
        if (facts or {}).get(fact) != want:
            return None
        why.append(f"{fact} is {want}")
    ptop = regime.get("peak_traces_per_second_max")
    if ptop is not None:
        if peak_tps > ptop:
            return None
        why.append(f"a peak of {round(peak_tps, 1):g} traces/s is at or below {ptop:g}")
    above = regime.get("peak_runs_per_second_above")
    if above is not None:
        if peak <= above:
            return None
        why.append(f"peak {round(peak, 1):g} runs/s is above {above:g}, the highest a load test held")
    band = regime.get("peak_band_min")
    if band is not None:
        if peak < bands[band]:
            return None
        why.append(f"peak {round(peak, 1):g} runs/s is at or above the {band} band's upper edge, {bands[band]:g} runs/s")
    top = regime.get("traces_per_second_max")
    if top is not None:
        if tps > top:
            return None
        why.append(f"{round(tps, 1):g} traces/s is at or below {top:g}")
    return why


def classify(regimes: Sequence[Mapping[str, Any]], *, traces_per_second: float, peak_runs_per_second: float, peak_bands: Mapping[str, float], peak_traces_per_second: float = 0.0, facts: Mapping[str, Any] | None = None) -> dict[str, Any]:
    for r in regimes:
        why = _holds(r, traces_per_second, peak_runs_per_second, peak_bands, peak_traces_per_second, facts)
        if why is None:
            continue
        reason = "; ".join(why) or f"no tighter regime holds at {round(traces_per_second, 1):g} traces/s and a peak of {round(peak_runs_per_second, 1):g} runs/s"
        return {"id": r["id"], "why": reason, "about": r["about"], "turns_on": dict(r["turns_on"]), "observe": bool(r.get("unmeasured"))}
    raise ValueError("regimes: the last must have no bounds, so every load matches one")
