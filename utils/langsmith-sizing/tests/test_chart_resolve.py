"""Which chart a command sizes on: an exact version as given, a line's newest, or the newest release."""

import unittest

from langsmith_sizing import chart

INDEX = """
entries:
  langsmith:
    - version: 0.19.0-rc.1
    - version: 0.18.0-rc.82
    - version: 0.18.0-rc.9
    - version: 0.17.60
    - version: 0.17.59
    - version: 0.17.9
  langgraph-dataplane:
    - version: 9.9.9
"""


class Resolve(unittest.TestCase):
    def test_no_version_is_the_newest_release_never_a_candidate(self) -> None:
        self.assertEqual(chart.resolve(None, INDEX), "0.17.60")
        self.assertEqual(chart.resolve("latest", INDEX), "0.17.60")

    def test_a_line_is_its_newest_release_else_its_newest_candidate(self) -> None:
        self.assertEqual(chart.resolve("0.17", INDEX), "0.17.60")
        self.assertEqual(chart.resolve("0.18", INDEX), "0.18.0-rc.82")  # rc.82 after rc.9: by number, not text
        self.assertEqual(chart.resolve("0.19", INDEX), "0.19.0-rc.1")

    def test_an_exact_version_is_itself_without_the_index(self) -> None:
        self.assertEqual(chart.resolve("0.17.35", "not: read"), "0.17.35")

    def test_a_line_the_repository_lacks_and_a_malformed_spec_are_refused(self) -> None:
        with self.assertRaisesRegex(chart.ChartError, "no langsmith chart in line 0.20"):
            chart.resolve("0.20", INDEX)
        with self.assertRaisesRegex(chart.ChartError, "exact version"):
            chart.resolve("newest", INDEX)

    def test_only_the_langsmith_chart_is_read(self) -> None:
        self.assertNotIn("9.9.9", chart.published(INDEX))


if __name__ == "__main__":
    unittest.main()
