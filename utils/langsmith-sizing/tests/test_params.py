import tempfile
import unittest
from pathlib import Path

from helpers import chart_at, needs_helm
from langsmith_sizing import PLANNED_CHARTS, citations, params

GOOD = {"value": 3, "unit": "x", "why": "a reason", "source": {"kind": "field", "ref": "where"}, "by": "someone", "since": "2026-11-13"}


def write(doc: str) -> Path:
    f = tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False)
    f.write(doc)
    f.close()
    return Path(f.name)


class Params(unittest.TestCase):
    def test_the_shipped_file_loads_and_every_entry_carries_its_evidence(self) -> None:
        loaded = params.load()
        self.assertTrue(loaded)
        for p in loaded.values():
            self.assertTrue(p.why and p.source_ref and p.by and p.since, p.id)

    def test_an_entry_without_evidence_is_refused(self) -> None:
        for drop in params.REQUIRED:
            entry = {k: v for k, v in GOOD.items() if k != drop}
            with self.assertRaisesRegex(params.ParamError, drop):
                params._check("x", entry)

    def test_the_docs_and_the_chart_are_not_sources_a_parameter_may_name(self) -> None:
        # a number they give is read there, never restated here
        for kind in ("docs", "chart"):
            with self.assertRaises(params.ParamError):
                params._check("x", GOOD | {"source": {"kind": kind, "ref": "r"}})

    def test_a_chart_has_no_key_reason_must_be_given_and_cannot_sit_beside_a_key(self) -> None:
        for bad in ("", "  ", True):
            with self.assertRaisesRegex(params.ParamError, "must say it"):
                params._check("x", GOOD | {"chart_has_no_key": bad})
        with self.assertRaisesRegex(params.ParamError, "contradict"):
            params._check("x", GOOD | {"chart_has_no_key": "why", "chart_key": "a.b"})
        self.assertEqual(params._check("x", GOOD | {"chart_has_no_key": "why"}).chart_has_no_key, "why")

    def test_an_unknown_schema_is_refused(self) -> None:
        with self.assertRaisesRegex(params.ParamError, "schema"):
            params.load(write("schema: 2\nparams: {}\n"))


class ChartShadows(unittest.TestCase):
    class Fake:
        version = "x"

        def __init__(self, values: dict) -> None:
            self.values = values

        def at(self, key: str):
            return self.values.get(key)

    def shadow(self, value, unit="replicas"):
        return {"p": params.Param("p", value, unit, "w", "decision", "r", "b", "2026-11-13", "a.b")}

    def test_a_parameter_equal_to_the_chart_value_is_a_second_source(self) -> None:
        self.assertEqual(len(params.shadowed(self.shadow(2), self.Fake({"a.b": "2"}))), 1)  # type: ignore[arg-type]
        self.assertEqual(len(params.shadowed(self.shadow(2, "vCPU"), self.Fake({"a.b": "2000m"}))), 1)  # type: ignore[arg-type]
        self.assertEqual(len(params.shadowed(self.shadow(4, "GiB"), self.Fake({"a.b": "4096Mi"}))), 1)  # type: ignore[arg-type]
        self.assertEqual(len(params.shadowed(self.shadow(True, "flag"), self.Fake({"a.b": True}))), 1)  # type: ignore[arg-type]

    def test_a_parameter_that_differs_is_an_override(self) -> None:
        self.assertEqual(params.shadowed(self.shadow(3), self.Fake({"a.b": "2"})), [])  # type: ignore[arg-type]

    def test_a_key_the_chart_lacks_is_a_problem(self) -> None:
        problems = params.shadowed(self.shadow(3), self.Fake({}))  # type: ignore[arg-type]
        self.assertEqual(len(problems), 1)
        self.assertIn("has no a.b", problems[0])

    def test_a_scalar_that_names_no_chart_key_must_say_why_it_has_none(self) -> None:
        bare = params.Param("p", 2, "replicas", "w", "decision", "r", "b", "2026-11-13")
        said = params.Param("p", 2, "replicas", "w", "decision", "r", "b", "2026-11-13", None, "the chart has no such setting")
        chart = self.Fake({"x.replicas": "2"})
        problems = params.shadowed({"p": bare}, chart)  # type: ignore[arg-type]
        self.assertEqual(len(problems), 1)
        self.assertIn("chart_has_no_key", problems[0])
        self.assertIn("x.replicas", problems[0])  # the setting it may be restating is named
        self.assertEqual(params.shadowed({"p": said}, chart), [])  # type: ignore[arg-type]

    def test_a_table_needs_no_chart_key(self) -> None:
        table = params.Param("p", {"cpu": 2}, "vCPU", "w", "decision", "r", "b", "2026-11-13")
        self.assertEqual(params.shadowed({"p": table}, self.Fake({"cpu": 2})), [])  # type: ignore[arg-type]

    @needs_helm
    def test_a_parameter_restating_the_charts_ttl_without_a_key_is_caught(self) -> None:
        # the audit's counter-example: 14 days in seconds, the chart's shortlived TTL, no chart_key
        c = chart_at()
        ttl = c.number("config.ttl.ttl_period_seconds.shortlived")
        restated = params.Param("scratch.ttl", ttl, "seconds", "w", "decision", "r", "b", "2026-11-17")
        problems = params.shadowed(params.load() | {"scratch.ttl": restated}, c)
        self.assertEqual(len(problems), 1)
        self.assertIn("scratch.ttl", problems[0])
        self.assertIn("config.ttl.ttl_period_seconds.shortlived", problems[0])
        keyed = params.Param("scratch.ttl", ttl, "seconds", "w", "decision", "r", "b", "2026-11-17", "config.ttl.ttl_period_seconds.shortlived")
        (problem,) = params.shadowed(params.load() | {"scratch.ttl": keyed}, c)
        self.assertIn("already gives", problem)

    @needs_helm
    def test_no_shipped_parameter_gives_what_the_chart_already_does(self) -> None:
        loaded = params.load()
        self.assertTrue([p for p in loaded.values() if p.chart_key])
        self.assertTrue([p for p in loaded.values() if p.chart_has_no_key])
        for version in PLANNED_CHARTS:
            self.assertEqual(params.shadowed(loaded, chart_at(version)), [], version)

    @needs_helm
    def test_the_overrides_really_are_in_the_chart(self) -> None:
        c = chart_at()
        self.assertEqual(c.number("smithdb.query.deployment.replicas"), 1)
        self.assertEqual(c.number("smithdb.mutations.deployment.replicas"), 1)
        self.assertFalse(c.at("config.blobStorage.enabled"))


class Citations(unittest.TestCase):
    def test_the_shipped_file_loads_with_a_commit_and_values(self) -> None:
        cited = citations.load()
        self.assertEqual(len(cited.commit), 40)
        self.assertEqual(cited["scale.write_anchors"]["high"], 1000)

    def test_a_citation_without_its_quote_is_refused(self) -> None:
        doc = "repo: r\ncommit: c\ncitations:\n  a: {file: f, values: 1}\n"
        with self.assertRaisesRegex(ValueError, "quote"):
            citations.load(write(doc))

    def test_a_quote_gone_from_its_file_is_a_problem(self) -> None:
        from unittest import mock

        cited = citations.load()
        with mock.patch.object(citations, "_text", return_value="the page was rewritten"):
            self.assertEqual(len(citations.check(cited)), len(cited.by_id))
        with mock.patch.object(citations, "_text", side_effect=lambda _r, _ref, _f: " ".join(c.quote for c in cited.by_id.values())):
            self.assertEqual(citations.check(cited), [])


if __name__ == "__main__":
    unittest.main()
