"""Draw a run's size from the profile's mix and generate its input and output text."""

import random
import threading
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

from loadtest.draw import weighted_choice

from .english_text import generate_text

KIB = 1024


@dataclass(frozen=True)
class RunPayload:
    size_name: str
    inputs: dict[str, Any]
    outputs: dict[str, Any]
    input_bytes: int
    output_bytes: int


class PayloadGenerator:
    """Every run gets fresh text: a reused document would compress far better than real traces."""

    def __init__(self, mix: Mapping[str, float], sizes_kib: Mapping[str, tuple[float, float]], seed: int | None = None) -> None:
        self.mix = dict(mix)
        self.sizes_kib = dict(sizes_kib)
        self.random_source = random.Random(seed)
        self.lock = threading.Lock()

    def next_run(self) -> RunPayload:
        # Only the draw is serialized; the text, the expensive part, is built from a private
        # generator so worker threads generate in parallel (the order of draws still varies).
        with self.lock:
            size_name = weighted_choice(self.mix, self.random_source)
            text_source = random.Random(self.random_source.getrandbits(64))
        in_kib, out_kib = self.sizes_kib[size_name]
        input_text = generate_text(int(in_kib * KIB), text_source)
        output_text = generate_text(int(out_kib * KIB), text_source)
        return RunPayload(size_name, {"input": input_text}, {"output": output_text}, len(input_text), len(output_text))
