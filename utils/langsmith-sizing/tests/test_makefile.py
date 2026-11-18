"""The Makefile's help says what each target writes, and the targets do what it says."""

import shutil
import subprocess
import tempfile
import unittest

from langsmith_sizing import ROOT

INPUTS = ["USERS=10", "TRACES_PER_SECOND=5", "PEAK_TRACES_PER_SECOND=15"]


def make(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["make", "-C", str(ROOT), *args], capture_output=True, text=True, check=False)


@unittest.skipUnless(shutil.which("make"), "make is not on PATH")
class MakefileTest(unittest.TestCase):
    def test_wizard_writes_all_four_files_and_the_help_says_so(self) -> None:
        self.assertIn("all four files", make("help").stdout)
        self.assertIn(" wizard ", make("-n", "wizard", *INPUTS).stdout)

    def test_plan_writes_only_plan_json_and_the_help_says_each_target_writes_its_own_file(self) -> None:
        text = make("help").stdout
        self.assertIn("each writes only its own file", text)
        self.assertIn("make load needs profile", text)
        dry = make("-n", "plan", "OUT=scratch", *INPUTS).stdout
        self.assertIn("> scratch/plan.json.tmp && mv", dry)
        for other in ("load-profile.json", "values.yaml", "stores.json"):
            self.assertNotIn(other, dry)

    def test_a_failed_plan_leaves_no_plan_for_compare_to_read(self) -> None:
        with tempfile.TemporaryDirectory() as out:
            failed = make("plan", f"OUT={out}", "TRACES_PER_SECOND=50", "PEAK_TRACES_PER_SECOND=10")
            self.assertNotEqual(failed.returncode, 0)
            self.assertFalse((ROOT / out / "plan.json").exists())

    def test_load_without_a_profile_stops_and_says_what_to_run(self) -> None:
        with tempfile.TemporaryDirectory() as empty:
            done = make("load", f"OUT={empty}")
        self.assertEqual(done.returncode, 2)
        self.assertIn("load-profile.json is missing: run make wizard, or make profile", done.stderr)
        self.assertNotIn("load-test", done.stdout)


if __name__ == "__main__":
    unittest.main()
