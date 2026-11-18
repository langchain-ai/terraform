"""The extra-lite regime's requests: what each pod was measured to use at the plan's load.

On one node the floor was the chart's requests and the docs' managed-store sizes, not what runs: 17 vCPU
and 63 GiB for an install a lab ran on under 2 cores. Each rule is idle cores plus cores a unit of the
pod's work (runs/s offered or processed, concurrent readers), times headroom, and memory at the pod's
sampled peak x 1.5 (params lite.measured).
"""

from __future__ import annotations

import math
from collections.abc import Mapping
from typing import Any

from langsmith_sizing.units import KIB, KILO


def request(rule: Mapping[str, Any], *, runs_per_second: float, readers: float, headroom: float, min_cpu: float) -> dict[str, float]:
    work = {"offered": runs_per_second, "processed": runs_per_second, "readers": readers, "fixed": 0}[rule["work"]]
    # whole millicores and MiB, so the request the values set is the one the chart renders
    cpu = math.ceil(max(min_cpu, (rule["base"] + rule["per_unit"] * work) * headroom) * KILO) / KILO
    return {"cpu": cpu, "memory_gib": math.ceil(rule["memory_gib"] * KIB) / KIB}


def at_least(limits: Mapping[str, float], requests: Mapping[str, float]) -> dict[str, float]:
    return {k: max(limits[k], requests[k]) for k in ("cpu", "memory_gib")}
