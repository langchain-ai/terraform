import unittest

from loadtest import fields
from results_fields import DOC, render, reports


class ResultsFieldsTest(unittest.TestCase):
    def test_every_field_is_described_and_every_description_has_a_field(self) -> None:
        self.assertEqual(fields.problems(fields.paths(reports())), [])

    def test_the_committed_reference_is_what_the_code_writes(self) -> None:
        self.assertEqual(DOC.read_text(), render(), "docs/results-fields.md is stale: run `make reference` in ../langsmith-sizing and commit it")


if __name__ == "__main__":
    unittest.main()
