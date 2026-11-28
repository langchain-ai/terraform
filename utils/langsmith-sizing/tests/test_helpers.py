import io
import unittest

from langsmith_sizing import chart
from tests.helpers import chart_or_skip, helm_gate


def _run(gate) -> unittest.TestResult:  # type: ignore[no-untyped-def]
    @gate
    class OnClass(unittest.TestCase):
        def test_a(self) -> None: ...

    class OnMethod(unittest.TestCase):
        @gate
        def test_b(self) -> None: ...

    suite = unittest.TestSuite([*unittest.defaultTestLoader.loadTestsFromTestCase(OnClass), *unittest.defaultTestLoader.loadTestsFromTestCase(OnMethod)])
    return unittest.TextTestRunner(stream=io.StringIO()).run(suite)


class HelmGate(unittest.TestCase):
    def test_helm_present_runs_the_tests(self) -> None:
        r = _run(helm_gate(True, True))
        self.assertEqual((r.testsRun, len(r.skipped), len(r.errors), len(r.failures)), (2, 0, 0, 0))

    def test_helm_missing_skips_on_a_laptop(self) -> None:
        r = _run(helm_gate(False, False))
        self.assertEqual((len(r.skipped), len(r.errors) + len(r.failures)), (2, 0))

    def test_helm_missing_fails_when_required(self) -> None:
        r = _run(helm_gate(False, True))
        self.assertEqual(len(r.skipped), 0)
        self.assertEqual(len(r.errors) + len(r.failures), 2)


class ChartGate(unittest.TestCase):
    @staticmethod
    def _missing(_version: str) -> chart.Chart:
        raise chart.ChartError("no network")

    def test_an_unavailable_chart_skips_on_a_laptop(self) -> None:
        with self.assertRaises(unittest.SkipTest):
            chart_or_skip(self, "9.9.9", self._missing, required=False)

    def test_an_unavailable_chart_fails_when_required(self) -> None:
        with self.assertRaisesRegex(AssertionError, "LANGSMITH_SIZING_REQUIRE_HELM=1 and chart 9.9.9"):
            chart_or_skip(self, "9.9.9", self._missing, required=True)


if __name__ == "__main__":
    unittest.main()
