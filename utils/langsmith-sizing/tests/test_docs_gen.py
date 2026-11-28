"""The docs' tables and figures are generated from params.yaml and citations.yaml: a committed table that
differs from what the code writes, a figure drawn from older data or missing a theme, and a link or image
to a file or anchor that does not exist all fail here. None of it needs helm, Chrome or the brand faces."""

import re
import unittest

from langsmith_sizing import ROOT, docs_gen, figures

DOCS = [ROOT / "README.md", ROOT / "CONTRIBUTING.md", *sorted((ROOT / "docs").glob("*.md")), ROOT / "presets" / "README.md"]


def anchors(text: str) -> set[str]:
    """GitHub's heading anchors: lower case, punctuation dropped, spaces to hyphens."""
    return {re.sub(r"[^a-z0-9 -]", "", h.strip().lower()).replace(" ", "-") for h in re.findall(r"^#+ (.+)$", text, re.M)}


class DocsGenTest(unittest.TestCase):
    def test_every_generated_table_is_what_the_code_writes(self) -> None:
        for doc in DOCS:
            text = doc.read_text()
            self.assertEqual(text, docs_gen.fill(text), f"{doc.name} is stale: run `make reference` and commit it")

    def test_every_table_the_generator_knows_is_used_once(self) -> None:
        used = [m[2] for doc in DOCS for m in docs_gen.MARKER.finditer(doc.read_text())]
        self.assertEqual(sorted(used), sorted(docs_gen.TABLES))

    def test_the_citation_and_parameter_tables_live_in_parameters_md_alone(self) -> None:
        homes = {name: doc.name for doc in DOCS for m in docs_gen.MARKER.finditer(doc.read_text()) for name in [m[2]]}
        self.assertEqual({homes["citations"], homes["params"]}, {"parameters.md"})

    def test_every_figure_was_drawn_from_the_current_data_in_both_themes(self) -> None:
        self.assertEqual(figures.stale(figures.pages()), [], "a figure was drawn from older data: run `make figures`")

    def test_every_figure_is_in_the_docs_with_its_dark_variant(self) -> None:
        text = "".join(doc.read_text() for doc in DOCS)
        for name in figures.PAGES:
            self.assertIn(f"{name}-dark.png", text)
            self.assertIn(f"{name}-light.png", text)

    def test_every_signal_has_a_source_and_every_link_resolves(self) -> None:
        p = docs_gen.params.values(docs_gen.params.load())
        self.assertEqual(set(p["scale.signals"]), set(figures.SIGNAL_SOURCE))
        link = r"(?:\]\(|srcset=\"|src=\")((?:\.\./|docs/|figures/)?[\w./-]+\.(?:png|md|yaml))(?:#([\w-]+))?"
        for doc in DOCS:
            for target, anchor in re.findall(link, doc.read_text()):
                path = (doc.parent / target).resolve()
                self.assertTrue(path.is_file(), f"{doc.name} links {target}, which does not exist")
                if anchor:
                    self.assertIn(anchor, anchors(path.read_text()), f"{doc.name} links {target}#{anchor}, which has no such heading")

    def test_the_docs_cite_only_functions_the_model_has(self) -> None:
        text = (ROOT / "docs" / "how-it-sizes.md").read_text()
        for module, names in re.findall(r"`model/(\w+)\.py: ([\w, \n]+)`", text):
            source = (ROOT / "src" / "langsmith_sizing" / "model" / f"{module}.py").read_text()
            for name in re.split(r",\s*", names.strip()):
                self.assertTrue(f"def {name}(" in source, f"how-it-sizes.md cites model/{module}.py: {name}, which is not there")


if __name__ == "__main__":
    unittest.main()
