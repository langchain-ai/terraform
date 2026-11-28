"""Generate English-like text that compresses like prose.

The first version drew from 24 words, so a 64 KiB document compressed about 7:1 where English
prose compresses about 3:1; storage sized from such payloads came out too small. The vocabulary
is now 10,000 words with a Zipf frequency of exponent 1.0, the measured shape of English word
frequencies. The words after the first 24 are pronounceable pseudo-words from a fixed seed, so
the vocabulary is identical on every machine and no word list has to ship.
"""

import random
from functools import lru_cache

ZIPF_EXPONENT = 1.0
VOCABULARY_SIZE = 10_000
_VOCABULARY_SEED = 20261117

HEAD_WORDS = (
    "agent", "trace", "model", "request", "response", "message", "result", "input",
    "output", "context", "data", "task", "status", "summary", "analysis", "document",
    "project", "session", "workflow", "evaluation", "metric", "event", "record", "value",
)

_ONSETS = ("", "b", "c", "d", "f", "g", "h", "j", "k", "l", "m", "n", "p", "r", "s", "t", "v", "w",
           "st", "tr", "ch", "sh", "th", "pr", "br", "cl", "gr", "pl", "sp", "fl")
_VOWELS = ("a", "e", "i", "o", "u", "ai", "ea", "io", "ou", "oo")
_CODAS = ("", "n", "r", "s", "t", "l", "m", "d", "nt", "st", "ng", "ck", "rt", "nd")


@lru_cache(maxsize=1)
def vocabulary() -> tuple[str, ...]:
    random_source = random.Random(_VOCABULARY_SEED)
    words = list(HEAD_WORDS)
    seen = set(words)
    while len(words) < VOCABULARY_SIZE:
        syllables = random_source.choices((1, 2, 3), weights=(35, 45, 20))[0]
        word = "".join(
            random_source.choice(_ONSETS) + random_source.choice(_VOWELS)
            + (random_source.choice(_CODAS) if position == syllables - 1 else "")
            for position in range(syllables)
        )
        if len(word) >= 2 and word not in seen:
            seen.add(word)
            words.append(word)
    return tuple(words)


@lru_cache(maxsize=1)
def _cumulative_weights() -> tuple[float, ...]:
    cumulative: list[float] = []
    total = 0.0
    for rank in range(1, VOCABULARY_SIZE + 1):
        total += 1.0 / rank**ZIPF_EXPONENT
        cumulative.append(total)
    return tuple(cumulative)


@lru_cache(maxsize=1)
def _average_word_bytes() -> float:
    weights = _cumulative_weights()
    previous = 0.0
    total = 0.0
    for word, cumulative in zip(vocabulary(), weights, strict=True):
        total += (cumulative - previous) * (len(word) + 1)
        previous = cumulative
    return total / weights[-1]


def generate_text(target_bytes: int, random_source: random.Random) -> str:
    """A fresh word sequence of at most `target_bytes` bytes, ending on a whole word.

    The text is ASCII, so its length in characters is its length in bytes. It falls short of the
    target by less than one word.
    """
    if target_bytes <= 0:
        return ""
    cumulative = _cumulative_weights()
    words = vocabulary()
    text = ""
    while len(text) < target_bytes:
        count = int((target_bytes - len(text)) / _average_word_bytes()) + 8
        chunk = " ".join(random_source.choices(words, cum_weights=cumulative, k=count))
        text = f"{text} {chunk}" if text else chunk
    if len(text) > target_bytes:
        text = text[:target_bytes].rsplit(" ", 1)[0]
    return text
