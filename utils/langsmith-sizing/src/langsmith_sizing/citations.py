"""Numbers the public docs publish (citations.yaml), each tied to the text that states it.

The docs are prose and tables, not data, so their numbers cannot be read at run time the way the
chart's are. Each one is written here once with the docs commit, the file and a short exact quote,
and `langsmith-sizing check-citations` fetches the file and fails when the quote is gone: the docs
changed, and the number must be read again. `--ref main` asks whether the docs moved since.
"""

from __future__ import annotations

import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

from langsmith_sizing import ROOT

CITATIONS = ROOT / "citations.yaml"


@dataclass(frozen=True)
class Citation:
    id: str
    repo: str
    file: str
    quote: str
    values: Any


@dataclass(frozen=True)
class Cited:
    commit: str
    by_id: dict[str, Citation]

    def __getitem__(self, cid: str) -> Any:
        return self.by_id[cid].values

    def __contains__(self, cid: object) -> bool:
        return cid in self.by_id


def load(path: Path = CITATIONS) -> Cited:
    doc = yaml.safe_load(path.read_text())
    repo, commit = doc["repo"], doc["commit"]
    out = {}
    for cid, c in (doc.get("citations") or {}).items():
        if not c.get("file") or not c.get("quote") or "values" not in c:
            raise ValueError(f"{cid}: a citation needs a file, a quote and the values it gives")
        out[cid] = Citation(cid, repo, c["file"], " ".join(c["quote"].split()), c["values"])
    return Cited(commit, out)


def _text(repo: str, ref: str, file: str) -> str:
    url = f"https://raw.githubusercontent.com/{repo}/{ref}/{file}"
    with urllib.request.urlopen(url, timeout=30) as r:  # noqa: S310 (a fixed https host)
        return " ".join(r.read().decode().split())


def check(cited: Cited, ref: str | None = None) -> list[str]:
    """Each citation whose quote is no longer in its file at ref (the pinned commit by default)."""
    ref = ref or cited.commit
    texts: dict[str, str] = {}
    problems = []
    for c in cited.by_id.values():
        if c.file not in texts:
            texts[c.file] = _text(c.repo, ref, c.file)
        if c.quote not in texts[c.file]:
            problems.append(f"{c.id}: {c.file} at {ref[:12]} no longer says: {c.quote[:90]}")
    return problems
