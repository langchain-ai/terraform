"""Build nested JSON documents that fit within a requested byte budget."""

from __future__ import annotations

import json
import random
from typing import Any

from .english_text import generate_text

# Compact separators keep document size independent of display formatting.
JSON_SEPARATORS = (",", ":")

TOP_LEVEL_KEYS = (
    "messages", "input", "output", "metadata", "data", "content", "documents",
    "answer", "state", "facts", "run", "kwargs", "context", "query", "response",
    "config", "params", "result", "info", "extra",
)

NESTED_KEYS = (
    "content", "id", "type", "role", "name", "value", "text", "source", "title",
    "description", "uuid", "status", "model_name", "tokens", "start_time",
    "end_time", "language", "version", "page_content", "tool_calls",
    "usage_metadata", "response_metadata", "additional_kwargs", "example", "lc",
    "args", "finish_reason", "loc", "priority",
)

MAX_DEPTH = 4
KEY_COUNT = 15

# Path draws are cheap and collisions are rare in a key space this large; the
# multiplier just bounds the loop instead of letting it spin.
_PATH_ATTEMPTS_PER_KEY = 8


def json_size_bytes(payload: Any) -> int:
    """Size of compact JSON in bytes, before any trace-specific wrapping."""
    return len(json.dumps(payload, separators=JSON_SEPARATORS).encode("utf-8"))


def _draw_path(random_source: random.Random) -> tuple[str, ...]:
    depth = random_source.randint(1, MAX_DEPTH)
    parts = [random_source.choice(TOP_LEVEL_KEYS)]
    parts.extend(random_source.choice(NESTED_KEYS) for _ in range(depth - 1))
    return tuple(parts)


def _conflicts(candidate: tuple[str, ...], existing: tuple[str, ...]) -> bool:
    """Prevent a string at one path from being overwritten by a nested object."""
    shared_depth = min(len(candidate), len(existing))
    return candidate[:shared_depth] == existing[:shared_depth]


def _draw_paths(random_source: random.Random, count: int) -> list[tuple[str, ...]]:
    paths: list[tuple[str, ...]] = []
    for _ in range(count * _PATH_ATTEMPTS_PER_KEY):
        if len(paths) == count:
            break
        candidate = _draw_path(random_source)
        if not any(_conflicts(candidate, path) for path in paths):
            paths.append(candidate)
    return paths


def _document_for(paths: list[tuple[str, ...]], values: list[str] | None = None) -> dict[str, Any]:
    document: dict[str, Any] = {}
    for position, path in enumerate(paths):
        node = document
        for key in path[:-1]:
            node = node.setdefault(key, {})
        node[path[-1]] = values[position] if values else ""
    return document


def build_document(target_bytes: int, random_source: random.Random) -> dict[str, Any]:
    """Build one nested JSON document that serializes to at most ``target_bytes``."""
    paths = _draw_paths(random_source, KEY_COUNT)
    # Drop leaves until the empty document fits: a deeply nested 15-key skeleton
    # is several hundred bytes on its own, which a small target cannot afford.
    while len(paths) > 1 and json_size_bytes(_document_for(paths)) > target_bytes:
        paths.pop()

    text_budget_bytes = target_bytes - json_size_bytes(_document_for(paths))
    if text_budget_bytes < 0:
        raise ValueError(f"target_bytes={target_bytes} is too small for a nested document")

    words = generate_text(text_budget_bytes, random_source).split()
    words_per_leaf, remaining_words = divmod(len(words), len(paths))
    values: list[str] = []
    word_offset = 0
    for position in range(len(paths)):
        word_count = words_per_leaf + (1 if position < remaining_words else 0)
        values.append(" ".join(words[word_offset : word_offset + word_count]))
        word_offset += word_count
    return _document_for(paths, values)
