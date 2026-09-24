"""Generate synthetic text using a small ASCII vocabulary."""

import random
from functools import lru_cache
ZIPF_EXPONENT = 1.07

VOCABULARY = (
    "agent", "trace", "model", "request", "response", "message", "result", "input",
    "output", "context", "data", "task", "status", "summary", "analysis", "document",
    "project", "session", "workflow", "evaluation", "metric", "event", "record", "value",
)


@lru_cache(maxsize=1)
def _cumulative_weights(count: int) -> tuple[float, ...]:
    cumulative: list[float] = []
    total = 0.0
    for rank in range(1, count + 1):
        total += 1.0 / rank**ZIPF_EXPONENT
        cumulative.append(total)
    return tuple(cumulative)


def generate_text(target_bytes: int, random_source: random.Random) -> str:
    """Fill a byte budget with whole words, leaving a few bytes unused."""
    vocabulary = VOCABULARY
    weights = _cumulative_weights(len(vocabulary))
    average_word_bytes = sum(len(word) for word in vocabulary) / len(vocabulary) + 1
    words: list[str] = []
    text_bytes = 0
    while True:
        words_to_sample = int((target_bytes - text_bytes) // average_word_bytes)
        if words_to_sample < 1:
            break
        added_word = False
        for word in random_source.choices(vocabulary, cum_weights=weights, k=words_to_sample):
            word_bytes = len(word) + (1 if words else 0)
            # Skip whole words that do not fit instead of truncating them.
            if text_bytes + word_bytes > target_bytes:
                continue
            words.append(word)
            text_bytes += word_bytes
            added_word = True
        if not added_word:
            break
    return " ".join(words)
