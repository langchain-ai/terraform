"""The questions make up asks: answers come from the command line, the file, the person, or a default;
a setting nobody gave fails without a terminal; what is given is saved, and replaces what was there."""

import io
import os
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

import settings


def by_key(key: str) -> settings.Question:
    return next(q for q in settings.QUESTIONS if q.key == key)


class Answers(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "t.tfvars")
        env = {k: v for k, v in os.environ.items() if k not in {q.key for q in settings.QUESTIONS}}
        self.env = mock.patch.dict(os.environ, env, clear=True)
        self.env.start()

    def tearDown(self) -> None:
        self.env.stop()
        self.dir.cleanup()

    def settle(self, interactive: bool = False) -> int:
        with redirect_stderr(io.StringIO()):
            return settings.settle(self.path, interactive)

    def test_a_missing_setting_with_no_default_fails_without_a_terminal(self) -> None:
        self.assertEqual(self.settle(), 1)
        self.assertFalse(os.path.exists(self.path))

    def test_command_line_values_are_saved_and_replace_the_file(self) -> None:
        Path(self.path).write_text('box = "s"\n')
        with mock.patch.dict(os.environ, {"ssh_host": "lab1", "box": "m"}):
            self.assertEqual(self.settle(), 0)
        text = Path(self.path).read_text()
        self.assertIn('box = "m"', text)
        self.assertIn('ssh_host = "lab1"', text)
        self.assertEqual(text.count("box ="), 1)

    def test_an_invalid_command_line_value_is_refused(self) -> None:
        with mock.patch.dict(os.environ, {"ssh_host": "lab1", "box": "xl"}):
            self.assertEqual(self.settle(), 1)

    def test_the_file_answers_without_asking(self) -> None:
        Path(self.path).write_text('ssh_host = "lab1"\nshort_ttl_days = 7\n')
        self.assertEqual(self.settle(), 0)
        self.assertEqual(settings.read_tfvars(self.path)["short_ttl_days"], "7")

    def test_at_a_terminal_each_missing_answer_is_asked_and_a_bad_one_again(self) -> None:
        typed = iter(["", "baremetal", "203.0.113.10", "", "zz", "m", "7", "30", "localhost", "ops@example.com"])
        with mock.patch("builtins.input", lambda _: next(typed)):
            self.assertEqual(self.settle(interactive=True), 0)
        saved = settings.read_tfvars(self.path)
        self.assertEqual((saved["box"], saved["short_ttl_days"], saved["ssh_user"]), ("m", "7", ""))

    def test_a_cluster_asks_for_its_storage_classes_and_defaults_the_scratch_one(self) -> None:
        typed = iter(["", "cluster", "gp3", "", "s", "", "", ""])
        with mock.patch("builtins.input", lambda _: next(typed)):
            self.assertEqual(self.settle(interactive=True), 0)
        saved = settings.read_tfvars(self.path)
        self.assertEqual((saved["storage_class"], saved["scratch_storage_class"]), ("gp3", "gp3"))
        self.assertNotIn("access", saved)


class Values(unittest.TestCase):
    def test_each_kind_is_written_as_hcl(self) -> None:
        self.assertEqual(settings.hcl(by_key("short_ttl_days"), "7"), "7")
        self.assertEqual(settings.hcl(by_key("admin_cidrs"), "203.0.113.7/32, 198.51.100.0/24"), '["203.0.113.7/32", "198.51.100.0/24"]')
        self.assertEqual(settings.hcl(by_key("box"), "m"), '"m"')

    def test_choices_and_patterns_are_enforced(self) -> None:
        self.assertFalse(settings.valid(by_key("box"), "xl"))
        self.assertFalse(settings.valid(by_key("name"), "Bad Name"))
        self.assertTrue(settings.valid(by_key("admin_email"), "a@b.co"))

    def test_an_optional_question_accepts_an_empty_answer(self) -> None:
        self.assertTrue(settings.accepted(by_key("ssh_user"), ""))
        self.assertFalse(settings.accepted(by_key("ssh_host"), ""))

    def test_a_long_default_is_cut_in_the_prompt(self) -> None:
        line = settings.prompt(by_key("ssh_public_key"), "ssh-ed25519 " + "A" * 80)
        self.assertIn("...", line)

    def test_the_public_key_is_found_in_the_home_ssh_folder(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            os.makedirs(os.path.join(home, ".ssh"))
            Path(home, ".ssh", "id_ed25519.pub").write_text("ssh-ed25519 AAAA test\n")
            with mock.patch.dict(os.environ, {"HOME": home}):
                self.assertEqual(settings.ssh_key(), "ssh-ed25519 AAAA test")
            with mock.patch.dict(os.environ, {"HOME": os.path.join(home, "none")}):
                self.assertIsNone(settings.ssh_key())


if __name__ == "__main__":
    unittest.main()
