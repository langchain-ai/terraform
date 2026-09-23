"""Byte ranges apply to each input/output document, before the trace wrapper."""

from dataclasses import dataclass

KIB = 1024
MIB = 1024 * KIB


@dataclass(frozen=True)
class PayloadSize:
    name: str
    min_bytes: int
    max_bytes: int
    weight: int


PAYLOAD_SIZES = (
    PayloadSize("small", 1 * KIB, 20 * KIB, 10),
    PayloadSize("medium", 50 * KIB, 250 * KIB, 40),
    PayloadSize("large", 250 * KIB, 750 * KIB, 40),
    PayloadSize("extra_large", 1 * MIB, 2 * MIB, 10),
)
