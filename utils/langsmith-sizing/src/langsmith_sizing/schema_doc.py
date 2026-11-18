"""The field reference, generated from real outputs so it cannot drift from the code.

`collect` sizes a fixed set of representative plans (every store placement, each trace store, the
one-node regime, a load past every band, both chart lines), walks the JSON they produce and
gathers every field path that appears in any of them with its type. `render` writes one row per
path: type, unit and meaning, the last two from the single table in `fields.py`. A path without
an entry fails the test, and so does an entry for a path no output has, so a field cannot be
added or removed without its documentation. `make reference` rewrites docs/fields.md, and a test
compares the file with `render()`.
"""

from __future__ import annotations

import json
import re
from typing import Any

import yaml

from langsmith_sizing import PLANNED_CHARTS, ROOT, chart, citations, deploy, inputs, params, plan, profile
from langsmith_sizing.fields import DESCRIPTIONS, LOAD_PROFILE_DESCRIPTIONS

FIELDS = ROOT / "docs" / "fields.md"
CHARTS = PLANNED_CHARTS
"""Every chart the package plans for: a field one of them adds must be documented."""

SAMPLES = ROOT / "cases" / "field-samples.yaml"
"""The plans the reference is walked from, as inputs: a name and the flags of each, in a file so the
sizing code stays free of literals."""

WILD = {
    "workloads": "<workload>", "smithdb.components": "<component>", "scale": "<workload>", "dbs": "<instance>",
    "configure.splits": "<split>", "configure.go": "<workload>", "scale.<workload>.chart_supports.signals": "<signal>",
    "provenance": "<path>", "regime.turns_on": "<switch>", "configure.inputs_to_change": "<input>",
    "warnings[ceilings-above-chart-default].figures.ceilings": "<workload>",
    "products.labels": "<product>", "products.needs": "<product>", "products.pods": "<workload>", "products.added": "<product>", "products.agent_server.each": "<pod>",
    "read.mix": "<class>", "write.payload.mix": "<size>", "write.payload.sizes_kib": "<size>",
}
"""Maps whose keys are data (a workload's name, a signal): their children are walked under a placeholder."""
OPAQUE = {"values", "configure.values", "configure.redis.values", "scale.<workload>.applied.values", "products.values", "products.render"}
"""Chart values: the chart owns their shape, not this reference."""
POOLS = {"app", "smithdb", "datastores", "sandboxes"}
"""The pools that share one shape; `single_node` has its own."""
STORE_FIELDS = re.compile(r"^stores\.[a-z_]+\.(placement|spec)(?=\.|$)")
"""A store's placement and spec have one shape whichever store they belong to; its figures do not."""


def _kind(v: Any) -> str:
    if v is None:
        return "null"
    for t, name in ((bool, "boolean"), ((int, float), "number"), (str, "string"), (list, "list")):
        if isinstance(v, t):
            return name
    return "object"


def _walk(v: Any, path: str, out: dict[str, set[str]]) -> None:
    """Add `path` and everything under it to `out`."""
    path = STORE_FIELDS.sub(lambda m: f"stores.<store>.{m[1]}", path)
    out.setdefault(path, set()).add(_kind(v))
    if path in OPAQUE:
        return
    if isinstance(v, dict):
        for k, child in v.items():
            name = "<pool>" if path == "pools" and k in POOLS else WILD[path] if path in WILD else k
            _walk(child, f"{path}.{name}" if path else name, out)
    elif isinstance(v, list):
        for item in v:
            if path == "warnings" and isinstance(item, dict):
                _warning(item, out)
            else:
                _walk(item, f"{path}[]", out)


def _warning(w: dict[str, Any], out: dict[str, set[str]]) -> None:
    """A warning's figures differ per id, so they are listed under the id (`chart-ask:<workload>` for all the chart asks)."""
    wid = re.sub(r"^chart-ask:.*", "chart-ask:<workload>", w["id"])
    _walk({k: v for k, v in w.items() if k != "figures"}, "warnings[]", out)
    out.setdefault("warnings[].figures", set()).add("object")
    _walk(w["figures"], f"warnings[{wid}].figures", out)


def samples() -> list[dict[str, Any]]:
    """Each sample's inputs; a node shape is a pair, which YAML spells as a list."""
    doc = yaml.safe_load(SAMPLES.read_text())
    return [{k: tuple(v) if isinstance(v, list) else v for k, v in entry["inputs"].items()} for entry in doc]


def collect() -> dict[str, dict[str, set[str]]]:
    """Every field path of plan.json, stores.json and load-profile.json across the samples."""
    p, cited = params.load(), citations.load()
    paths: dict[str, dict[str, set[str]]] = {"plan.json": {}, "stores.json": {}, "load-profile.json": {}}
    for version in CHARTS:
        c = chart.Chart(version)
        for kw in samples():
            i = inputs.Inputs(chart_version=version, **kw)
            body = json.loads(json.dumps(plan.size(i, c, p, cited)))
            _walk(body, "", paths["plan.json"])
            _walk(json.loads(json.dumps(deploy.stores_json(body))), "", paths["stores.json"])
            _walk(json.loads(json.dumps(profile.load_profile(i, c, p, cited))), "", paths["load-profile.json"])
    for doc in paths.values():
        doc.pop("", None)
    return paths


def _table(rows: dict[str, set[str]], descriptions: dict[str, tuple[str, str]]) -> list[str]:
    out = ["| Path | Type | Unit | Meaning |", "|:--|:--|:--|:--|"]
    sections = list(dict.fromkeys(re.split(r"[.\[]", p)[0] for p in rows))
    for path in sorted(rows, key=lambda p: (sections.index(re.split(r"[.\[]", p)[0]), p)):
        unit, meaning = descriptions[path]
        kinds = " or ".join(sorted(rows[path] - {"null"}) + ["null"] * ("null" in rows[path]))
        out.append(f"| `{path}` | {kinds} | {unit or '-'} | {meaning} |")
    return out


def undocumented(paths: dict[str, dict[str, set[str]]]) -> list[str]:
    """Problems with the descriptions table: a path without an entry, an entry for no path, or a number with no unit."""
    problems = []
    for doc, descriptions in (("plan.json", DESCRIPTIONS), ("stores.json", DESCRIPTIONS), ("load-profile.json", LOAD_PROFILE_DESCRIPTIONS)):
        problems += [f"{doc}: no description for {p}" for p in sorted(set(paths[doc]) - descriptions.keys())]
        for p in sorted(set(paths[doc]) & descriptions.keys()):
            if "number" in paths[doc][p] and not descriptions[p][0]:
                problems.append(f"{doc}: {p} is a number with no unit")
    for name, descriptions in (("plan.json", DESCRIPTIONS), ("load-profile.json", LOAD_PROFILE_DESCRIPTIONS)):
        known = set(paths[name]) | (set(paths["stores.json"]) if name == "plan.json" else set())
        problems += [f"{name}: an entry for {p}, which no output has" for p in sorted(descriptions.keys() - known)]
    return problems


def render(paths: dict[str, dict[str, set[str]]] | None = None) -> str:
    found = paths or collect()
    if problems := undocumented(found):
        raise ValueError("\n".join(problems))
    lines = [
        "# Fields", "",
        "Generated by `make reference` from the outputs of representative plans: every field that appears in any of them,",
        "with its type, its unit and its meaning. Do not edit it; a test fails when it differs from the code. What each",
        "output is for, and its stability, is in [reference.md](reference.md).", "",
        "A path with `<workload>`, `<component>`, `<instance>`, `<signal>`, `<split>`, `<store>`, `<pool>`, `<switch>`, `<input>`, `<class>`, `<size>` or `<path>` repeats once per",
        "key of that map. `[]` is one item of a list. A type of `null` means the field is `null` in some plans: the meaning says when.",
        "Chart values (`values`, `configure.values`, `scale.<workload>.applied.values`) are the chart's own keys and are not listed.", "",
        "## plan.json (`size`)", "", *_table(found["plan.json"], DESCRIPTIONS), "",
        "## stores.json (`stores`)", "",
        "The same fields as the plan's `stores`, `dbs` and `warnings`, written for provisioning.", "",
        *_table(found["stores.json"], DESCRIPTIONS), "",
        "## load-profile.json (`load-profile`)", "", *_table(found["load-profile.json"], LOAD_PROFILE_DESCRIPTIONS), "",
    ]
    return "\n".join(lines)


if __name__ == "__main__":
    FIELDS.write_text(render())
    print(f"wrote {FIELDS.relative_to(ROOT)}")
