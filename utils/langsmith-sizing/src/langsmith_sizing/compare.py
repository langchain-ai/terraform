"""A plan against a load test's results: one verdict per promise, never a guess.

The plan (`size`) says what load the install was sized for and what to watch; the results
(utils/langsmith-load-test, schema "langsmith-load-results/1") say what a test measured. A verdict is
"pass", "fail", "not measured" or, for a server-side reading the results carry, "observed": the load test sees what a client sees, so the plan's server-side
watch items are "not measured by the load test" unless the results carry the reading themselves
(`metrics`, keyed by watch item id). Nothing is inferred for a thing nobody measured.
"""

from __future__ import annotations

from typing import Any

PASS, FAIL, NOT_MEASURED, OBSERVED = "pass", "fail", "not measured", "observed"
NOT_MEASURED_NOTE = "not measured by the load test"
OPEN_LOOP = "open-loop"
TARGETS = {
    "stored_within_seconds_p99": "a run sent is readable within the target for 99% of runs",
    "trace_load_seconds_p99": "loading a trace returns within the target for 99% of reads",
}


def _verdict(item: str, passed: bool | None, detail: str) -> dict[str, Any]:
    return {"item": item, "verdict": NOT_MEASURED if passed is None else PASS if passed else FAIL, "detail": detail}


def _rate(plan: dict[str, Any], results: dict[str, Any]) -> dict[str, Any]:
    peak = plan["rates"]["peak_traces_per_second"]
    write = results["write"]
    if write["mode"] != OPEN_LOOP:
        return _verdict("write-rate", None, f"the run was {write['mode']}, which offers no fixed rate to set against the plan's peak of {peak:g} traces/s")
    # Judged on the rate held after the ramp, which offers half the target on average; a run over
    # the whole window failed a test that held its rate. A window of d seconds offers rate x d
    # starts, give or take the one at its edge, so one start short is still the rate.
    steady, duration = write.get("steady_traces_per_second"), results.get("settings", {}).get("duration_seconds")
    if steady is None or not duration:
        achieved = write["achieved_traces_per_second"]
        return _verdict("write-rate", achieved >= peak, f"achieved {achieved:g} traces/s over the whole run, ramp included, against the plan's peak of {peak:g}")
    return _verdict("write-rate", steady * duration + 1 >= peak * duration, f"held {steady:g} traces/s after the ramp against the plan's peak of {peak:g}")


def _target(name: str, entry: dict[str, Any]) -> dict[str, Any]:
    if "observed_seconds" in entry:
        seen = entry["observed_seconds"]
        detail = f"{entry['observed']} {'not measured' if seen is None else f'{seen:g} s'} against {entry['target_seconds']:g} s"
    else:
        detail = f"{TARGETS.get(name, name)}"
    return _verdict(name, entry["passed"], detail)


def _missing(entry: dict[str, Any]) -> dict[str, Any]:
    missing = entry["missing"]
    return _verdict("no_missing_runs", entry["passed"], "the stored count could not be read" if missing is None else f"{missing} runs sent and not stored")


def _reading(entry: dict[str, Any]) -> str:
    unit = entry.get("unit", "")
    if "peak" in entry:
        per = f" ({entry['peak_per_pod']:g} a pod)" if "peak_per_pod" in entry else ""
        return f"peak {entry['peak']:g}{per}, end {entry['end']:g} {unit}"
    for key in ("during_run", "mean", "share"):
        if key in entry:
            return f"{key.replace('_', ' ')} {entry[key]:g} {unit}"
    return ", ".join(f"{k} {v}" for k, v in entry.items())


def _crossed(threshold: Any, entry: dict[str, Any]) -> bool | None:
    """Whether the reading went past the alarm level: a peak (a pod's, where the level is per pod) or a
    count during the run above it, an autoscaler at its ceiling. None when the plan only observes."""
    if not isinstance(threshold, dict):
        return None
    level = threshold["value"]
    if "during_run" in entry:
        return bool(entry["during_run"] > level)
    if "peak" not in entry:
        return None
    if entry.get("unit") == "replicas":
        return bool(entry["peak"] >= level)
    return bool(entry.get("peak_per_pod", entry["peak"]) > level)


def _watch(item: dict[str, Any], metrics: dict[str, Any]) -> dict[str, Any]:
    if item["id"] not in metrics:
        return _verdict(f"watch:{item['id']}", None, f"{item['metric']}: {NOT_MEASURED_NOTE}")
    entry, threshold = metrics[item["id"]], item["threshold"]
    crossed = _crossed(threshold, entry)
    level = "" if crossed is None else f"; {'ABOVE' if crossed else 'within'} the alarm level of {threshold['value']:g} {threshold['unit']}"
    # Observed, not failed: a backlog over the autoscaler's target is what makes it scale, so crossing a
    # level says where to look (the item's action), not that the plan failed.
    return {"item": f"watch:{item['id']}", "verdict": OBSERVED, "detail": f"{item['metric']}: {_reading(entry)}{level}"}


def _app(plan: dict[str, Any], results: dict[str, Any]) -> dict[str, Any]:
    """The install's LangSmith release against the one the planned chart deploys. A difference is
    observed, not failed: images are often pinned apart from the chart, and the plan says which it read."""
    want, have = plan.get("app_version"), (results.get("server") or {}).get("app_version")
    if not have:
        return _verdict("app-version", None, f"the install's version was not read; the plan's chart {plan['chart']} deploys {want}")
    if have == want:
        return _verdict("app-version", True, f"the install runs LangSmith {have}, what chart {plan['chart']} deploys")
    return {"item": "app-version", "verdict": OBSERVED, "detail": f"the install runs LangSmith {have}; the plan read chart {plan['chart']}, which deploys {want}: size again with the chart that ships {have}"}


def run_verdicts(results: dict[str, Any], watch: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """What a run says on its own: the results' targets, then each watch item against its level. The load
    test's judge uses it without a plan, with the levels params.yaml sets itself."""
    targets = results["targets"]
    out = [_target(name, targets[name]) for name in TARGETS]
    out.append(_missing(targets["no_missing_runs"]))
    metrics = results.get("metrics", {})
    return out + [_watch(item, metrics) for item in watch]


def compare(plan: dict[str, Any], results: dict[str, Any]) -> list[dict[str, Any]]:
    """Every verdict, in order: the app version, the rate, the results' targets, then each of the plan's watch items."""
    return [_app(plan, results), _rate(plan, results), *run_verdicts(results, plan["watch"])]


def failed(verdicts: list[dict[str, Any]]) -> bool:
    return any(v["verdict"] == FAIL for v in verdicts)


def render(verdicts: list[dict[str, Any]]) -> str:
    lines = [f"{v['verdict'].upper():<12} {v['item']}: {v['detail']}" for v in verdicts]
    count = {k: sum(v["verdict"] == k for v in verdicts) for k in (PASS, FAIL, NOT_MEASURED, OBSERVED)}
    lines.append(f"{count[PASS]} pass, {count[FAIL]} fail, {count[NOT_MEASURED]} not measured, {count[OBSERVED]} observed")
    return "\n".join(lines)
