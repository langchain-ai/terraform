"""The brand's faces and logos are found where their checkouts keep them, so no run names a folder: a
five-hour experiment once had to be started with two scratch paths to draw its last figures in the brand."""

import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from langsmith_sizing import figures


class BrandFiles(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        fonts = self.tmp / "ps-ops-center" / "docs" / "public" / "fonts"
        fonts.mkdir(parents=True)
        (fonts / "TWKLausanne-250.woff2").write_bytes(b"face")
        logos = self.tmp / "content-studio" / "skills" / "langchain-brand-guidelines" / "assets" / "logos" / "company"
        logos.mkdir(parents=True)
        (logos / "LangChain_Lockup_dark_mode_white.svg").write_text("<svg/>")

    def test_a_checkout_named_by_its_variable_is_where_the_files_are_read(self) -> None:
        env = {"PS_OPS_CENTER": str(self.tmp / "ps-ops-center"), "CONTENT_STUDIO": str(self.tmp / "content-studio")}
        with mock.patch.dict(os.environ, env):
            self.assertEqual(figures.brand_file(None, "TWKLausanne-250.woff2", figures.FACE_PLACES),
                             self.tmp / "ps-ops-center" / "docs" / "public" / "fonts" / "TWKLausanne-250.woff2")
            self.assertEqual(figures.logo(None, "dark").name, "LangChain_Lockup_dark_mode_white.svg")  # type: ignore[union-attr]
            self.assertIsNone(figures.brand_file(None, "aeonikmono-medium.otf", figures.FACE_PLACES))

    def test_a_folder_given_is_the_only_place_looked(self) -> None:
        given = self.tmp / "mine"
        given.mkdir()
        (given / "langchain-on-dark.svg").write_text("<svg/>")
        with mock.patch.dict(os.environ, {"CONTENT_STUDIO": str(self.tmp / "content-studio")}):
            self.assertEqual(figures.logo(given, "dark"), given / "langchain-on-dark.svg")
            self.assertIsNone(figures.logo(given, "light"))


if __name__ == "__main__":
    unittest.main()
