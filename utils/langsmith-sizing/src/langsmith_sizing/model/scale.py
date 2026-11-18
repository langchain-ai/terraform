"""How each workload should autoscale, and how much of that the chart can express.

Per workload: the recommended trigger (a table, params.yaml `scale.workloads`), what the chart's
autoscaling block supports at the version planned (read from its values, never assumed), what the
plan applies as exact chart keys, and the gap, the chart ask, where the recommendation cannot be
expressed. The plan applies the best the chart allows (a CPU autoscaler with the plan's floors and
ceilings) and says so; it never pretends a trigger exists.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

MECHANISMS = ("keda", "hpa")
MIN_KEY = {"hpa": "minReplicas", "keda": "minReplicaCount"}
MAX_KEY = {"hpa": "maxReplicas", "keda": "maxReplicaCount"}


def _expresses(autoscaling: Mapping[str, Any], mechanism: str, field: str | None) -> bool:
    block = autoscaling.get(mechanism)
    return field is not None and isinstance(block, dict) and field in block


def supports(autoscaling: Mapping[str, Any] | None, signals: Mapping[str, Mapping[str, Any]], wanted: list[str]) -> dict[str, Any]:
    """What the chart's autoscaling block offers: which mechanisms exist, and which of them express
    each wanted signal."""
    a = autoscaling or {}
    return {
        "hpa": isinstance(a.get("hpa"), dict), "keda": isinstance(a.get("keda"), dict),
        "signals": {s: [m for m in MECHANISMS if _expresses(a, m, signals[s]["field"])] for s in wanted},
    }


def _put(values: dict[str, Any], key: str, value: Any, default: Any) -> None:
    """Set a chart key only when it differs from the chart's default."""
    if value != default:
        values[key] = value


def _ceiling(sized: Mapping[str, Any], default_max: Any) -> int:
    """The plan's ceiling, never below the chart's: an autoscaler pinned at the plan's own count
    could not absorb what the model did not foresee."""
    return int(max(sized["max"], default_max if default_max is not None else sized["max"]))


def _off(values: dict[str, Any], key: str, autoscaling: Mapping[str, Any]) -> None:
    for m in MECHANISMS:
        block = autoscaling.get(m)
        if isinstance(block, dict) and block.get("enabled"):
            values[f"{key}.autoscaling.{m}.enabled"] = False


def _applied(kind: str, signals: list[str], key: str, autoscaling: Mapping[str, Any], sized: Mapping[str, Any] | None) -> dict[str, Any]:
    values: dict[str, Any] = {}
    out: dict[str, Any] = {"kind": kind, "signals": signals, "values": values}
    if kind == "none" or sized is None:
        return out
    block = autoscaling[kind]
    lo, hi = int(sized["min"]), _ceiling(sized, block[MAX_KEY[kind]])
    base = f"{key}.autoscaling"
    _put(values, f"{base}.{kind}.enabled", True, block["enabled"])
    other = autoscaling.get("keda" if kind == "hpa" else "hpa")
    if isinstance(other, dict) and other.get("enabled"):
        values[f"{base}.{'keda' if kind == 'hpa' else 'hpa'}.enabled"] = False
    _put(values, f"{base}.{kind}.{MIN_KEY[kind]}", lo, block[MIN_KEY[kind]])
    _put(values, f"{base}.{kind}.{MAX_KEY[kind]}", hi, block[MAX_KEY[kind]])
    out |= {"min": lo, "max": hi}
    return out


def workload(
    spec: Mapping[str, Any], *, signals: Mapping[str, Mapping[str, Any]], fallback: Mapping[str, str], autoscaling: Mapping[str, Any] | None,
    default_replicas: Any, sized: Mapping[str, Any] | None, autoscalers: bool, fixed_replicas: int | None,
) -> dict[str, Any]:
    """One workload's recommendation, chart support, applied values and gap."""
    a = autoscaling or {}
    key, mech, wanted = spec["values_key"], spec["mechanism"], list(spec["signals"])
    have = supports(autoscaling, signals, wanted)
    ok = [s for s in wanted if mech in have["signals"][s]]
    missing = [s for s in wanted if s not in ok]
    if not autoscalers or mech == "none":
        applied = _applied("none", [], key, a, None)
        if not autoscalers:
            _off(applied["values"], key, a)
            if fixed_replicas is not None and sized is not None and default_replicas is not None:
                _put(applied["values"], f"{key}.deployment.replicas", fixed_replicas, default_replicas)
    elif ok:
        applied = _applied(mech, ok, key, a, sized)
    elif _expresses(a, fallback["mechanism"], signals[fallback["signal"]]["field"]):
        applied = _applied(fallback["mechanism"], [fallback["signal"]], key, a, sized)
    else:
        applied = _applied("none", [], key, a, None)
    asks = [signals[s]["ask"] for s in missing if signals[s]["ask"]]
    if applied["kind"] == mech and spec.get("chart_limit"):
        asks.append(spec["chart_limit"])
    gap = {"signals": missing, "ask": "; ".join(asks), "applied_instead": {"kind": applied["kind"], "signals": applied["signals"]}} if asks and autoscalers else None
    return {
        "recommended": {"mechanism": mech, "signals": wanted, "why": spec["why"]},
        "chart_supports": have, "applied": applied, "gap": gap, "deployed": sized is not None,
        "above_chart_default": _above_default(applied, a),
    }


def _above_default(applied: Mapping[str, Any], autoscaling: Mapping[str, Any]) -> bool:
    kind = applied["kind"]
    return kind != "none" and "max" in applied and applied["max"] > autoscaling[kind][MAX_KEY[kind]]
