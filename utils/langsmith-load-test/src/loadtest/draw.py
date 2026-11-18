"""Weighted draws and even spreading of a fractional rate over a count."""

import math
import random
from collections.abc import Mapping


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
