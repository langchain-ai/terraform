"""The Makefile's help says what each target does, a sizing is a folder named for who it is for,
and a target that needs a folder says what to run when it is missing."""

import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from langsmith_sizing import ROOT


def make(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["make", "-C", str(ROOT), *args], capture_output=True, text=True, check=False)


def dry(*args: str) -> str:
    """The commands a target would run, with make's runs of spaces from unset inputs closed up."""
    return " ".join(make("-n", *args).stdout.split())


@unittest.skipUnless(shutil.which("make"), "make is not on PATH")
class MakefileTest(unittest.TestCase):
    def test_the_help_walks_size_deploy_prove_and_lists_every_target(self) -> None:
        text = make("help").stdout
        for step in ("1  size", "2  deploy", "3  prove", "make wizard NAME=acme", "make plan NAME=acme PRESET=lite", "make compare NAME=acme"):
            self.assertIn(step, text)
        targets = {line.split(":")[0] for line in (ROOT / "Makefile").read_text().splitlines() if "## " in line and line[:1].isalpha()}
        for t in targets:
            self.assertIn(t, text)

    def test_a_sizing_lands_in_a_folder_named_for_it(self) -> None:
        self.assertIn("plan --preset lite --out out/acme", dry("plan", "NAME=acme", "PRESET=lite"))
        self.assertIn("--out elsewhere/acme", dry("plan", "NAME=acme", "OUT=elsewhere/acme"))

    def test_the_preset_names_the_folder_when_no_name_is_given(self) -> None:
        self.assertIn("--out out/lite", dry("plan", "PRESET=lite"))

    def test_a_target_that_needs_a_folder_refuses_without_a_name(self) -> None:
        for target in ("wizard", "plan", "show", "load", "compare"):
            done = make(target)
            self.assertEqual(done.returncode, 2, target)
            self.assertIn("give NAME=<customer>", done.stderr)

    def test_load_without_a_profile_stops_and_says_what_to_run(self) -> None:
        with tempfile.TemporaryDirectory() as empty:
            done = make("load", "NAME=x", f"OUT={Path(empty) / 'x'}")
        self.assertEqual(done.returncode, 2)
        self.assertIn("load-profile.json is missing: run make wizard NAME=x or make plan NAME=x first", done.stderr)
        self.assertNotIn("load-test", done.stdout)


class DocsNameRealTargetsTest(unittest.TestCase):
    """A doc or the Claude skill that names a target the Makefile lacks sends a reader to an error."""

    def test_every_make_target_a_doc_names_exists(self) -> None:
        targets = {m.group(1) for m in re.finditer(r"^([a-z-]+):", (ROOT / "Makefile").read_text(), re.M)}
        skill = ROOT.parent.parent / ".claude" / "skills" / "langsmith-sizing" / "SKILL.md"
        agent = ROOT.parent.parent / ".claude" / "agents" / "langsmith-sizing.md"
        docs = [ROOT / "README.md", *sorted((ROOT / "docs").glob("*.md")), ROOT / "presets" / "README.md", skill, agent]
        for doc in docs:
            for name in re.findall(r"(?:`|^)make ([a-z][a-z-]*)\b", doc.read_text(), re.M):
                self.assertIn(name, targets, f"{doc.relative_to(ROOT.parent.parent)} names make {name}")


if __name__ == "__main__":
    unittest.main()
