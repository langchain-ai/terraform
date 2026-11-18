"""The terminal: every command a person reads draws through here, so they all look the same.

rich drops colour on its own when stdout is not a terminal or NO_COLOR is set, so a piped or
logged run is plain text with the same layout.
"""

from __future__ import annotations

from collections.abc import Iterable
from typing import Any

from rich import box
from rich.console import Console
from rich.padding import Padding
from rich.panel import Panel
from rich.table import Table as RichTable
from rich.text import Text
from rich.theme import Theme

from langsmith_sizing.summary import Table, View

THEME = Theme({
    "accent": "bold cyan", "muted": "dim", "ok": "bold green", "bad": "bold red", "warn": "bold yellow",
    "key": "bold", "cmd": "cyan", "title": "bold",
})
VERDICT_STYLE = {"pass": "ok", "fail": "bad", "not measured": "muted", "observed": "accent"}
LEVEL_STYLE = {"info": "muted", "warn": "warn", "action": "bad"}

console = Console(theme=THEME, highlight=False)


def banner(title: str, subtitle: str = "") -> None:
    body = Text(title, style="title")
    if subtitle:
        body.append("\n" + subtitle, style="muted")
    console.print(Panel(body, box=box.ROUNDED, border_style="accent", padding=(0, 1)))


def heading(text: str) -> None:
    console.print()
    console.rule(Text(text, style="title"), align="left", style="muted")


def note(text: str) -> None:
    console.print(Padding(Text(text, style="muted"), (0, 0, 0, 2)))


def facts(rows: Iterable[tuple[str, str]], title: str = "") -> None:
    grid = RichTable.grid(padding=(0, 2))
    grid.add_column(style="key", no_wrap=True)
    grid.add_column()
    for k, v in rows:
        grid.add_row(k, v, style="bad" if k == "Act on first" else None)
    console.print(Panel(grid, title=Text(title, style="title") if title else None, title_align="left", box=box.ROUNDED, border_style="muted", padding=(0, 1)))


def table(t: Table) -> None:
    heading(t.title)
    out = RichTable(box=box.SIMPLE_HEAD, header_style="muted", pad_edge=False, show_edge=False)
    for i, c in enumerate(t.columns):
        out.add_column(c, style="key" if i == 0 else None, overflow="fold", no_wrap=i == 0)
    for r in t.rows:
        style = None
        if t.title == "Before you deploy":
            style = LEVEL_STYLE.get(r[0])
        elif any("NOT FIT" in c or c == "does not fit" for c in r):
            style = "bad"
        out.add_row(*r, style=style)
    console.print(Padding(out, (0, 0, 0, 2)))
    if t.note:
        note(t.note)


def show(view: View, title: str) -> None:
    facts(view.facts, title)
    for t in view.tables:
        table(t)


def steps(rows: Iterable[tuple[str, str]], title: str = "Next") -> None:
    heading(title)
    grid = RichTable.grid(padding=(0, 2))
    grid.add_column(style="cmd", no_wrap=True)
    grid.add_column(style="muted")
    for cmd, what in rows:
        grid.add_row(cmd, what)
    console.print(Padding(grid, (0, 0, 0, 2)))
    console.print()


def files(paths: Iterable[tuple[str, str]], title: str = "Saved") -> None:
    steps(paths, title)


def verdicts(rows: list[dict[str, Any]]) -> None:
    out = RichTable(box=box.SIMPLE_HEAD, header_style="muted", pad_edge=False, show_edge=False)
    out.add_column("verdict", no_wrap=True)
    out.add_column("promise", style="key", no_wrap=True)
    out.add_column("detail", overflow="fold")
    for v in rows:
        out.add_row(Text(v["verdict"].upper(), style=VERDICT_STYLE[v["verdict"]]), v["item"], v["detail"])
    console.print(Padding(out, (0, 0, 0, 2)))


def ok(text: str) -> None:
    console.print(Text.assemble(("  ok  ", "ok"), text))


def warn(text: str) -> None:
    console.print(Text.assemble(("  !   ", "warn"), text))


def error(text: str) -> None:
    Console(theme=THEME, stderr=True, highlight=False).print(Text.assemble(("error ", "bad"), text))


def question(label: str, what: str, default: str, source: str, choices: Iterable[tuple[str, str]] = ()) -> None:
    """One question as a small block: what it is, the choices with what each means, the default and why."""
    grid = RichTable.grid(padding=(0, 2))
    grid.add_column(style="accent", no_wrap=True, justify="right")
    grid.add_column(style="key", no_wrap=True)
    grid.add_column(style="muted")
    for i, (value, meaning) in enumerate(choices, start=1):
        grid.add_row(str(i), value, meaning)
    if default:
        grid.add_row("", Text("default", style="muted"), Text.assemble((default, "accent"), (f"  {source}" if source else "", "muted")))
    console.print()
    console.print(Text.assemble((label, "key"), ("  " + what, "")))
    console.print(Padding(grid, (0, 0, 0, 2)))
