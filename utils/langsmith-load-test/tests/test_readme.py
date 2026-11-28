import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src" / "loadtest"


class FilesListTest(unittest.TestCase):
    def test_the_readme_lists_every_module_and_nothing_else(self) -> None:
        readme = (ROOT / "README.md").read_text()
        section = readme.split("\n## Files\n", 1)[1].split("\n## ", 1)[0]
        listed = set(re.findall(r"^- `([\w/]+(?:\.py)?)`", section, re.M))
        on_disk = {p.name for p in SRC.glob("*.py")} | {f"{p.name}/" for p in SRC.iterdir() if p.is_dir() and p.name != "__pycache__"}
        self.assertEqual({name.rstrip("/") for name in listed}, {name.rstrip("/") for name in on_disk})


if __name__ == "__main__":
    unittest.main()
