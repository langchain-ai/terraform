"""Weighted draws and even spreading of a fractional rate over a count."""

import math
import random
from collections.abc import Mapping
from dataclasses import dataclass
from uuid import UUID


def weighted_choice(weights: Mapping[str, float], random_source: random.Random) -> str:
    names = list(weights)
    return random_source.choices(names, weights=[weights[name] for name in names])[0]


def share_due(per_item: float, number: int) -> int:
    """How many of a fractional per-item count fall on item `number` (1-based).

    The counts sum to floor(number * per_item) and are spread evenly, so 0.5 feedback per trace is
    one every second trace rather than whatever chance gives; the epsilon keeps 0.29 * 100 from
    rounding down to 28.
    """
    return math.floor(number * per_item + 1e-9) - math.floor((number - 1) * per_item + 1e-9)


@dataclass(frozen=True)
class Projects:
    """The projects a test writes to, busiest first, each drawn by Zipf weight over its rank.

    SmithDB partitions by project, and one busy project concentrates its runs on the same ingestion
    pods, so a test that writes everything to one project measures the hot-project case, not the
    install's capacity (Ben Nagengast's load test spread 200 projects with a skew of 1).
    """

    names: tuple[str, ...]
    ids: tuple[UUID, ...]
    skew: float = 1.0

    def __post_init__(self) -> None:
        if not self.names or len(self.names) != len(self.ids):
            raise ValueError("a test writes to at least one project, each with its id")

    def pick(self, random_source: random.Random) -> int:
        """The index of the project the next trace goes to."""
        weights = [1 / (rank + 1) ** self.skew for rank in range(len(self.names))]
        return random_source.choices(range(len(self.names)), weights=weights)[0]

    @property
    def id_strings(self) -> list[str]:
        return [str(i) for i in self.ids]


def project_names(base: str, count: int) -> tuple[str, ...]:
    return (base,) if count == 1 else tuple(f"{base}-{n:03d}" for n in range(count))
