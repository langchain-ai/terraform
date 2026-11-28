"""A load profile produced by the real `langsmith_sizing.profile.load_profile`, not typed by hand.

The chart is a stub exposing the two methods the profile code reads (`version` and `number`). Its
four numbers are the values of the sizing's default chart (`config.blobStorage.minBlobStorageSizeKb`, the two
ttl periods and `redisRunsExpirySeconds`); a test below compares the result with the real chart
when it is already in the sizing cache. A hand-written fixture drifted: it said 7.5 runs a trace
where the sizing model says 10.
"""

from __future__ import annotations

import copy
from functools import cache
from typing import Any

from langsmith_sizing import PLANNED_CHARTS, citations, inputs, params, profile

CHART_VERSION = PLANNED_CHARTS[0]
CHART_VALUES = {
    "config.blobStorage.minBlobStorageSizeKb": 20.0,
    "config.ttl.ttl_period_seconds.shortlived": 1209600.0,
    "config.ttl.ttl_period_seconds.longlived": 34560000.0,
    "config.settings.redisRunsExpirySeconds": 21600.0,
}


class StubChart:
    version = CHART_VERSION

    def number(self, key: str, values: dict[str, Any] | None = None) -> float:
        return CHART_VALUES[key]

    def at(self, key: str, values: dict[str, Any] | None = None) -> Any:
        return CHART_VALUES.get(key)


def real_document(chart: Any = None) -> dict[str, Any]:
    return profile.load_profile(
        inputs.Inputs(chart_version=CHART_VERSION, users=10, traces_per_second=50),
        chart or StubChart(), params.load(), citations.load(),
    )


@cache
def _cached() -> dict[str, Any]:
    return real_document()


def document() -> dict[str, Any]:
    return copy.deepcopy(_cached())
