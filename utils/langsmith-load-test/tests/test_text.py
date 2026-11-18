import hashlib
import os
import random
import re
import subprocess
import sys
import unittest
import zlib
from collections import Counter
from pathlib import Path

from loadtest.draw import share_due, weighted_choice
from loadtest.payloads.english_text import generate_text, vocabulary
from loadtest.payloads.generator import KIB, PayloadGenerator


def compression_ratio(text: str) -> float:
    data = text.encode()
    return len(data) / len(zlib.compress(data, 6))


class TextTest(unittest.TestCase):
    def test_vocabulary_is_stable_and_distinct(self) -> None:
        words = vocabulary()
        self.assertEqual(len(words), 10_000)
        self.assertEqual(len(set(words)), 10_000)
        self.assertTrue(all(re.fullmatch(r"[a-z]{2,}", word) for word in words))

    def test_vocabulary_is_the_same_in_every_process(self) -> None:
        # The module promises an identical vocabulary on every machine. A different hash seed per
        # process is what would break it if a set or dict order leaked into the build.
        source = Path(__file__).resolve().parents[1] / "src"
        code = "import hashlib;from loadtest.payloads.english_text import vocabulary;print(hashlib.sha256(' '.join(vocabulary()).encode()).hexdigest())"
        digests = {
            subprocess.run(
                [sys.executable, "-c", code], capture_output=True, text=True, check=True,
                env={**os.environ, "PYTHONHASHSEED": seed, "PYTHONPATH": str(source)},
            ).stdout.strip()
            for seed in ("1", "2", "3")
        }
        self.assertEqual(len(digests), 1)
        self.assertEqual(digests.pop(), hashlib.sha256(" ".join(vocabulary()).encode()).hexdigest())

    def test_word_frequency_follows_zipf_with_exponent_one(self) -> None:
        # Under Zipf (1/rank) the word of rank 1 is ten times as common as the word of rank 10.
        counts = Counter(generate_text(2_000_000, random.Random(4)).split(" "))
        words = vocabulary()
        self.assertAlmostEqual(counts[words[0]] / counts[words[9]], 10, delta=1.5)
        self.assertAlmostEqual(counts[words[0]] / counts[words[1]], 2, delta=0.3)

    def test_size_is_within_one_word_below_the_target(self) -> None:
        for target in (1 * KIB, 4 * KIB, 32 * KIB, 750 * KIB):
            text = generate_text(target, random.Random(1))
            self.assertLessEqual(len(text), target)
            self.assertGreater(len(text), target - 16)
            self.assertFalse(text.endswith(" "))

    def test_text_is_fresh_and_repeatable_by_seed(self) -> None:
        first = generate_text(8 * KIB, random.Random(1))
        self.assertEqual(first, generate_text(8 * KIB, random.Random(1)))
        self.assertNotEqual(first, generate_text(8 * KIB, random.Random(2)))

    def test_large_text_compresses_like_english_prose(self) -> None:
        # zlib level 6 on English prose: Canterbury alice29.txt (152 KB) about 2.8:1, the King James
        # bible (4 MB) about 3.4:1. The old 24-word vocabulary gave about 7:1, which sized storage
        # too small. The band is those two with room either side for a 256 KiB sample.
        ratio = compression_ratio(generate_text(256 * KIB, random.Random(3)))
        self.assertGreater(ratio, 2.4)
        self.assertLess(ratio, 3.6)

    def test_small_text_compresses_less_as_prose_does(self) -> None:
        # A 4 KiB sample has little history to match: prose of that length compresses about 2:1 to 2.6:1.
        ratio = compression_ratio(generate_text(4 * KIB, random.Random(3)))
        self.assertGreater(ratio, 1.9)
        self.assertLess(ratio, 3.0)


class DrawTest(unittest.TestCase):
    def test_weighted_choice_matches_weights(self) -> None:
        weights = {"a": 70.0, "b": 25.0, "c": 5.0}
        random_source = random.Random(7)
        draws = 20000
        counts = {name: 0 for name in weights}
        for _ in range(draws):
            counts[weighted_choice(weights, random_source)] += 1
        for name, weight in weights.items():
            self.assertAlmostEqual(counts[name] / draws, weight / 100, delta=0.015)

    def test_share_due_spreads_a_fraction_evenly(self) -> None:
        self.assertEqual([share_due(0.5, number) for number in range(1, 7)], [0, 1, 0, 1, 0, 1])
        self.assertEqual(sum(share_due(0.29, number) for number in range(1, 101)), 29)
        self.assertEqual({share_due(7.5, number) for number in range(1, 11)}, {7, 8})
        self.assertEqual(sum(share_due(2.0, number) for number in range(1, 11)), 20)


class GeneratorTest(unittest.TestCase):
    def test_runs_follow_the_mix_and_sizes(self) -> None:
        generator = PayloadGenerator({"small": 80, "big": 20}, {"small": (1, 2), "big": (8, 4)}, seed=5)
        runs = [generator.next_run() for _ in range(400)]
        big = [run for run in runs if run.size_name == "big"]
        self.assertAlmostEqual(len(big) / len(runs), 0.2, delta=0.06)
        for run in runs:
            in_kib, out_kib = (8, 4) if run.size_name == "big" else (1, 2)
            # Hand numbers: at most the KiB asked for, and short of it by less than one word.
            self.assertLessEqual(run.input_bytes, in_kib * KIB)
            self.assertGreater(run.input_bytes, in_kib * KIB - 16)
            self.assertLessEqual(run.output_bytes, out_kib * KIB)
            self.assertGreater(run.output_bytes, out_kib * KIB - 16)
            self.assertEqual(run.input_bytes, len(run.inputs["input"].encode()))
            self.assertEqual(run.output_bytes, len(run.outputs["output"].encode()))
        self.assertEqual(len({run.inputs["input"] for run in runs}), len(runs))


if __name__ == "__main__":
    unittest.main()
