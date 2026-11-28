"""What the tests share: the shipped params and citations, and the chart at the version the
examples were written for. Tests that need the chart skip only when helm is missing."""

from __future__ import annotations

import os
import shutil
import unittest
from collections.abc import Callable
from functools import cache
from typing import Any, TypeVar

from langsmith_sizing import PLANNED_CHARTS, chart, citations, inputs, params, plan
from langsmith_sizing.model import payload

CHART = PLANNED_CHARTS[0]
P = params.values(params.load())
CITED = citations.load()
REQUIRE_HELM = "LANGSMITH_SIZING_REQUIRE_HELM"
NO_HELM = "helm is not on PATH: sizing reads the chart through it"
T = TypeVar("T")


def helm_gate(have_helm: bool, required: bool) -> Callable[[T], T]:
    """Without helm a chart test skips on a laptop but fails where `required` is set: CI sets it, so a
    missing helm cannot turn the chart tests into a green run that tested nothing."""
    if have_helm:
        return lambda target: target
    if not required:
        return unittest.skip(NO_HELM)  # type: ignore[return-value]

    def fail(target: Any) -> Any:
        if isinstance(target, type):
            def set_up_class(cls: type) -> None:
                raise AssertionError(f"{REQUIRE_HELM}=1 and {NO_HELM}")

            target.setUpClass = classmethod(set_up_class)
            return target

        def failing(*_: Any, **__: Any) -> None:
            raise AssertionError(f"{REQUIRE_HELM}=1 and {NO_HELM}")

        failing.__name__ = target.__name__
        return failing

    return fail


needs_helm = helm_gate(bool(shutil.which("helm")), os.environ.get(REQUIRE_HELM) == "1")


def chart_or_skip(case: unittest.TestCase, version: str, at: Callable[[str], chart.Chart] | None = None, required: bool | None = None) -> chart.Chart:
    """The chart at `version` for a test that needs a second chart. A chart that cannot be pulled
    skips on a laptop but fails where REQUIRE_HELM is set: CI must not go green having tested one chart."""
    have = at or chart_at
    must = os.environ.get(REQUIRE_HELM) == "1" if required is None else required
    try:
        c = have(version)
        c.values  # noqa: B018  (pulls the chart)
    except chart.ChartError as err:
        if must:
            raise AssertionError(f"{REQUIRE_HELM}=1 and chart {version} is not cached and cannot be pulled: {err}") from err
        case.skipTest(f"chart {version} is not cached and cannot be pulled: {err}")
    return c


@cache
def chart_at(version: str = CHART) -> chart.Chart:
    return chart.Chart(version)


def size(**kw: Any) -> dict[str, Any]:
    """A plan for the 10 users, 50 traces/s defaults unless the arguments say otherwise."""
    kw = {"users": 10} | ({} if {"traces_per_second", "traces_per_month"} & kw.keys() else {"traces_per_second": 50}) | kw
    version = kw.pop("chart_version", CHART)
    return plan.size(inputs.Inputs(chart_version=version, **kw), chart_at(version), params.load(), CITED)


def coeffs(in_kib: float, out_kib: float, **kw: Any) -> dict[str, Any]:
    """One bucket's per-run KB at the shipped anchors."""
    opts: dict[str, Any] = {"threshold_kib": 20, "blob": True, "compression": 1.0, "default_threshold_kib": 20} | kw
    return payload.bucket_coeff(in_kib, out_kib, payload.curves_from_params(P), **opts)


def blend(**kw: Any) -> dict[str, float]:
    """The blend across the default mix."""
    keys = [b["key"] for b in payload.buckets_from_params(P)]
    mix = list(P["payload.mix_default"].values())
    opts: dict[str, Any] = {"threshold_kib": 20, "blob": True, "compression": 1.0, "default_threshold_kib": 20, "partial_inline_share": P["payload.partial_inline_share"]} | kw
    res = payload.resolve(mix, payload.buckets_from_params(P), payload.curves_from_params(P), default_shares=mix, **opts)
    assert keys == list(P["payload.mix_default"])
    return res["blend"]
