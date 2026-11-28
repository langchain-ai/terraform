"""Percentiles of a sample, by the nearest rank over the sorted values."""


def summarize(values: list[float]) -> dict[str, float | int | None]:
    ordered = sorted(values)
    count = len(ordered)

    def at(percent: int) -> float | None:
        return ordered[round(percent / 100 * (count - 1))] if count else None

    return {"count": count, "p50": at(50), "p95": at(95), "p99": at(99), "max": ordered[-1] if count else None}
