"""Prepare reusable JSON documents and sample from the configured size mix."""

import random
import threading
from dataclasses import dataclass
from typing import Any

from .json_documents import build_document, json_size_bytes
from .sizes import PAYLOAD_SIZES


@dataclass(frozen=True)
class TracePayload:
    inputs: dict[str, Any]
    outputs: dict[str, Any]
    size_name: str
    input_bytes: int


class PayloadGenerator:
    """Prepare the cache first, then share it between the runner and fake model."""

    def __init__(self, seed: int | None = None) -> None:
        self.random_source = random.Random(seed)
        self.cached_payloads: dict[str, list[TracePayload]] = {}
        self.next_indexes: dict[str, int] = {}
        self.lock = threading.Lock()

    def prepare(self) -> None:
        # Two document pairs per size keep memory bounded during long tests.
        for size in PAYLOAD_SIZES:
            documents = []
            for _ in range(2):
                inputs = build_document(
                    self.random_source.randint(size.min_bytes, size.max_bytes), self.random_source,
                )
                outputs = build_document(
                    self.random_source.randint(size.min_bytes, size.max_bytes), self.random_source,
                )
                documents.append(TracePayload(inputs, outputs, size.name, json_size_bytes(inputs)))
            self.cached_payloads[size.name] = documents
            self.next_indexes[size.name] = 0

    def next_payload(self) -> TracePayload:
        # Model replies run in worker threads while inputs are drawn on the event loop.
        with self.lock:
            size = self.random_source.choices(PAYLOAD_SIZES, weights=[size.weight for size in PAYLOAD_SIZES])[0]
            index = self.next_indexes[size.name]
            self.next_indexes[size.name] = index + 1
            documents = self.cached_payloads[size.name]
            return documents[index % len(documents)]
