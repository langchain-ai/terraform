"""Draw a run's size from the profile's mix and build its fields in the profile's shape."""

import base64
import json
import random
import threading
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

from langsmith.schemas import Attachment, Attachments
from loadtest.draw import weighted_choice

from .english_text import generate_text

KIB = 1024
BASE64_RATIO = 4 / 3  # encoded bytes a raw byte becomes
# A JSON field is a message list, the shape a chat model's input takes; each message carries about
# this much text, so a large field is many messages rather than one long string.
MESSAGE_KIB = 1


@dataclass(frozen=True)
class RunPayload:
    size_name: str
    inputs: dict[str, Any]
    outputs: dict[str, Any]
    input_bytes: int
    output_bytes: int
    attachments: Attachments


def _text(size: int, source: random.Random) -> str:
    return generate_text(size, source)


def _base64(size: int, source: random.Random) -> str:
    # Random bytes encoded: what an inlined image or audio clip looks like, and it does not compress.
    return base64.b64encode(source.randbytes(max(1, int(size / BASE64_RATIO)))).decode()[:size]


def _messages(size: int, source: random.Random) -> list[dict[str, str]]:
    step = MESSAGE_KIB * KIB
    return [{"role": ("user", "assistant")[n % 2], "content": generate_text(min(step, size - start), source)} for n, start in enumerate(range(0, max(size, 1), step))]


CONTENT = {"text": _text, "base64": _base64, "json": _messages}


def _side(prefix: str, size: int, fields: int, content: str, source: random.Random) -> tuple[dict[str, Any], int]:
    """size bytes spread evenly over fields: offload to the bucket is decided per field, so ten 4 KiB
    fields stay inline where one 40 KiB field is offloaded."""
    each = max(1, size // fields)
    values = {(prefix if fields == 1 else f"{prefix}_{n}"): CONTENT[content](each, source) for n in range(fields)}
    return values, sum(len(v.encode()) if isinstance(v, str) else len(json.dumps(v).encode()) for v in values.values())


class PayloadGenerator:
    """Every run gets fresh text: a reused document would compress far better than real traces."""

    def __init__(
        self, mix: Mapping[str, float], sizes_kib: Mapping[str, tuple[float, float]], seed: int | None = None, *,
        fields_per_side: int = 1, content: str = "text", attachment_kib: float = 0.0,
    ) -> None:
        self.mix = dict(mix)
        self.sizes_kib = dict(sizes_kib)
        self.fields_per_side = fields_per_side
        self.content = content
        self.attachment_bytes = int(attachment_kib * KIB)
        self.random_source = random.Random(seed)
        self.lock = threading.Lock()

    def next_run(self) -> RunPayload:
        # Only the draw is serialized; the text, the expensive part, is built from a private
        # generator so worker threads generate in parallel (the order of draws still varies).
        with self.lock:
            size_name = weighted_choice(self.mix, self.random_source)
            source = random.Random(self.random_source.getrandbits(64))
        in_kib, out_kib = self.sizes_kib[size_name]
        inputs, in_bytes = _side("input", int(in_kib * KIB), self.fields_per_side, self.content, source)
        outputs, out_bytes = _side("output", int(out_kib * KIB), self.fields_per_side, self.content, source)
        # Random bytes: an image or a file compresses little, and the bucket stores what was sent.
        attachments: Attachments = {"file": Attachment("application/octet-stream", source.randbytes(self.attachment_bytes))} if self.attachment_bytes else {}
        return RunPayload(size_name, inputs, outputs, in_bytes, out_bytes, attachments)
