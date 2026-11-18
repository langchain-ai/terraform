"""docs/fields.md is generated from real outputs: a field with no description, a description with no
field, and a committed file that differs from the code all fail here."""

import re
import unittest

from langsmith_sizing import ROOT, schema_doc
from tests.helpers import needs_helm


@needs_helm
class SchemaDocTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.paths = schema_doc.collect()

    def test_every_field_is_described_and_every_description_has_a_field(self) -> None:
        self.assertEqual(schema_doc.undocumented(self.paths), [])

    def test_the_committed_reference_is_what_the_code_writes(self) -> None:
        self.assertEqual(
            schema_doc.FIELDS.read_text(), schema_doc.render(self.paths),
            "docs/fields.md is stale: run `make reference` and commit it",
        )

    def test_every_warning_id_the_plans_emit_is_in_the_reference(self) -> None:
        emitted = {re.match(r"warnings\[([^\]]+)\]", p)[1] for p in self.paths["plan.json"] if p.startswith("warnings[") and not p.startswith("warnings[]")}  # type: ignore[index]
        documented = set(re.findall(r"^\| `([a-z:<>-]+)` \| (?:action|info) \|", (ROOT / "docs" / "reference.md").read_text(), re.M))
        self.assertEqual(emitted, documented)


if __name__ == "__main__":
    unittest.main()
