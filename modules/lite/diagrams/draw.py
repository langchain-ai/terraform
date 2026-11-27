"""Lite's figures, for its README, ARCHITECTURE.md, SIZING.md and OPERATE.md: each drawn as an SVG on a
brand page and shot to PNG by headless Chrome at twice the device scale, in the dark theme. The page, the theme tokens and the shot are the sizing package's (utils/langsmith-sizing,
figures.py), so every figure in this repository shares one palette and one renderer:

    uv run --project ../../utils/langsmith-sizing python diagrams/draw.py --fonts DIR --logos DIR [name ...]

The faces and the logo are read where they are and never copied here; without them a figure is drawn as
a labelled draft and not recorded. Every number on a figure is read from where the docs keep it (SIZING.md's
tables, the load test's steps, the soak's defaults) and every install step is checked against
box/install.sh, so a figure whose source moved fails here rather than drifting. rendered.json holds the
hash of each page as last drawn.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import tempfile
from collections.abc import Callable, Sequence
from html import escape
from pathlib import Path

from langsmith_sizing.figures import chrome, document, faces, logo, shoot

HERE = Path(__file__).resolve().parent
LITE = HERE.parent
ROOT = LITE.parent.parent
RENDERED = HERE / "rendered.json"
THEMES = ("dark",)  # dark only (Reed, 2026-11-26): one image a figure, the same on every reader's page
W = 1472  # the page's content width: 1600 less the canvas's padding
MONO = 7.9  # Aeonik Mono's advance at 13 px, for sizing chips and placing labels

# Four tenants, told apart by colour and by letter, from the theme's own tokens.
TENANTS = ("var(--accent)", "var(--good)", "var(--text-2)", "var(--warn-line)")

STYLE = """<style>
:root { --lc-grid: 8px; --lc-stroke: calc(var(--lc-grid) / 4); }
svg.fig { display: block; overflow: visible; margin-top: 8px; }
svg.fig text { fill: var(--text); font: 250 15px var(--font-sans); }
svg.fig text.h { font: 600 17px var(--font-sans); }
svg.fig text.hs { font: 600 15px var(--font-sans); }
svg.fig text.hl { font: 250 26px var(--font-sans); letter-spacing: -0.01em; }
svg.fig text.b { fill: var(--muted); }
svg.fig text.m { font: 400 13px var(--font-mono); fill: var(--accent-ink); }
svg.fig text.mm { font: 400 13px var(--font-mono); fill: var(--muted); }
svg.fig text.cap { font: 600 14px var(--font-sans); fill: var(--muted); letter-spacing: 0.01em; }
svg.fig text.gt { fill: var(--warn); }
svg.fig text.on { fill: var(--bg); font: 600 14px var(--font-sans); }
.frame { fill: var(--shell); stroke: var(--frame); }
.card { fill: var(--card); stroke: var(--line); }
.key { fill: var(--hl); stroke: var(--accent); stroke-width: var(--lc-stroke); }
.gap { fill: var(--warn-fill); stroke: var(--warn-line); stroke-width: var(--lc-stroke); stroke-dasharray: 6 5; }
.track { fill: var(--bg); stroke: var(--line); }
.rule { stroke: var(--line); }
.w, .wa, .wr, .wg { fill: none; stroke-width: var(--lc-stroke); stroke-linecap: round; stroke-linejoin: round; }
.w { stroke: var(--connector); }
.wa { stroke: var(--accent); }
.wr { stroke: var(--connector); stroke-dasharray: 7 6; }
.wg { stroke: var(--warn-line); stroke-dasharray: 6 5; }
.mark { stroke: var(--text); stroke-width: var(--lc-stroke); }
.no { stroke: var(--warn-line); stroke-width: var(--lc-stroke); stroke-linecap: round; }
.ball { stroke: var(--bg); stroke-width: var(--lc-stroke); }
.edge { stroke-width: var(--lc-stroke); }
</style>"""

# One arrowhead for every connector, coloured by the line it ends (the brand's connector rules).
DEFS = """<defs><marker id="a" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="4.5" markerHeight="4.5"
markerUnits="strokeWidth" orient="auto-start-reverse"><path d="M0,0.6 L10,5 L0,9.4 z" fill="context-stroke"/></marker></defs>"""


# ---- drawing primitives: each returns SVG markup -------------------------------------------------


def rect(x: float, y: float, w: float, h: float, cls: str = "card", r: float = 10, style: str = "") -> str:
    s = f' style="{style}"' if style else ""
    return f'<rect x="{x:g}" y="{y:g}" width="{w:g}" height="{h:g}" rx="{r:g}" class="{cls}"{s}/>'


# A label that starts with code (a service, a command, a file, a setting) keeps its source casing, as the
# brand's casing rule asks; any other label starts with a capital. Both are marked on the element that holds
# the words, where brand-lint reads them: a wrapped line as a continuation, code as explicit.
CODE = re.compile(r"^(<|k3s|kubeconfig|kube-system|frontend|backend|platform-backend|ingest-queue|queue|nginx|"
                  r"cloudflared|terraform|make |cloud =|checks\.sh|emulate_machine)")


def text(x: float, y: float, lines: str | Sequence[str], cls: str = "", anchor: str = "start", lh: float = 20,
         code: bool = False) -> str:
    rows = [lines] if isinstance(lines, str) else list(lines)
    code = code or cls in ("m", "mm") or bool(CODE.match(rows[0]))
    if not code:
        rows[0] = rows[0][:1].upper() + rows[0][1:]
    spans = "".join(
        f'<tspan x="{x:g}" dy="{0 if i == 0 else lh:g}"'
        f'{case(code, i)}>{escape(t)}</tspan>'
        for i, t in enumerate(rows)
    )
    return f'<text x="{x:g}" y="{y:g}" class="{cls}" text-anchor="{anchor}">{spans}</text>'


def case(code: bool, line: int) -> str:
    if code:
        return ' data-brand-case="explicit"'
    return ' data-brand-case="continuation"' if line else ""


def path(d: str, cls: str = "w", arrow: str = "") -> str:
    end = ' marker-end="url(#a)"' if arrow else ""
    return f'<path d="{d}" class="{cls}"{end}/>'


def line(x1: float, y1: float, x2: float, y2: float, cls: str = "w", arrow: str = "") -> str:
    return path(f"M{x1:g},{y1:g} L{x2:g},{y2:g}", cls, arrow)


def circle(cx: float, cy: float, r: float, cls: str = "", style: str = "") -> str:
    s = f' style="{style}"' if style else ""
    return f'<circle cx="{cx:g}" cy="{cy:g}" r="{r:g}" class="{cls}"{s}/>'


def badge(cx: float, cy: float, label: str, r: float = 12) -> str:
    return circle(cx, cy, r, "", "fill:var(--accent)") + text(cx, cy + 5, label, "on", "middle")


def cross(cx: float, cy: float, s: float = 9) -> str:
    return line(cx - s, cy - s, cx + s, cy + s, "no") + line(cx - s, cy + s, cx + s, cy - s, "no")


def cylinder(x: float, y: float, w: float, h: float, fills: Sequence[str], opacity: float = 0.35) -> str:
    """A database, its body striped one band a fill: tenants sharing one store show as interleaved rows."""
    ry = 9
    clip = f"c{int(x)}x{int(y)}"
    body = f"M{x:g},{y + ry:g} v{h - 2 * ry:g} a{w / 2:g},{ry} 0 0 0 {w:g},0 v{-(h - 2 * ry):g}"
    band = (h - ry) / len(fills)
    stripes = "".join(
        f'<rect x="{x:g}" y="{y + ry + i * band:g}" width="{w:g}" height="{band + 0.5:g}" '
        f'style="fill:{f};fill-opacity:{opacity}"/>'
        for i, f in enumerate(fills)
    )
    return (
        f'<clipPath id="{clip}"><path d="{body} z"/></clipPath>'
        f'<path d="{body} z" style="fill:var(--card)"/><g clip-path="url(#{clip})">{stripes}</g>'
        f'<path d="{body}" style="fill:none;stroke:var(--frame)"/>'
        f'<ellipse cx="{x + w / 2:g}" cy="{y + ry:g}" rx="{w / 2:g}" ry="{ry}" style="fill:var(--card);stroke:var(--frame)"/>'
    )


def chip_width(label: str, letter: str = "") -> float:
    return (38 if letter else 14) + MONO * len(label) + 14


def chip(x: float, y: float, label: str, colour: str, letter: str = "", cls: str = "mm") -> str:
    out = rect(x, y, chip_width(label, letter), 34, "card", 17, f"stroke:{colour};stroke-width:var(--lc-stroke)")
    if letter:
        out += circle(x + 19, y + 17, 11, "", f"fill:{colour}") + text(x + 19, y + 22, letter, "on", "middle")
    return out + text(x + (38 if letter else 14), y + 22, label, cls)


def svg(height: float, body: str) -> str:
    return f'<svg class="fig" width="{W}" height="{height:g}" viewBox="0 0 {W} {height:g}">{DEFS}{body}</svg>'


def page(eyebrow: str, title: str, sub: str, body: str, source: str) -> str:
    return (
        f'<div class="canvas">{STYLE}<header><div class="eyebrow"><span data-brand-case="explicit">modules/lite</span>'
        f'<span class="of">{escape(eyebrow)}</span></div><h1>{escape(title)}</h1><p class="sub">{escape(sub)}</p>'
        f'<!--flag--></header>{body}<footer><!--logo--><span data-brand-case="explicit">{escape(source)}</span></footer></div>'
    )


# ---- sources: every number comes from where the docs or the code keep it --------------------------


def doc(name: str) -> str:
    return (LITE / name).read_text()


def md_table(name: str, after: str) -> list[list[str]]:
    """The first markdown table at or after the line holding `after`, without its header and rule."""
    body = doc(name)
    rows: list[list[str]] = []
    for raw in body[body.index(after) :].splitlines():
        if raw.startswith("|"):
            rows.append([c.strip() for c in raw.strip("|").split("|")])
        elif rows:
            break
    return [r for r in rows[1:] if not set(r[0]) <= set(":-")]


def number(cell: str) -> float:
    return float(re.sub(r"[^\d.]", "", cell.split()[0]))


def mib(cell: str) -> float:
    m = re.match(r"([\d.,]+)\s*(MiB|GiB)", cell.replace("*", ""))
    if not m:
        raise SystemExit(f"no memory in {cell!r}")
    return float(m[1].replace(",", "")) * (1024 if m[2] == "GiB" else 1)


def millicores(cell: str) -> float:
    m = re.match(r"([\d.]+)(m| vCPU)", cell.replace("*", ""))
    if not m:
        raise SystemExit(f"no CPU in {cell!r}")
    return float(m[1]) * (1 if m[2] == "m" else 1000)


SIZES_HEAD = "| `box` | Machine | Peak runs/s | Runs a day"


def sizes() -> list[dict[str, float | str]]:
    """SIZING.md, The sizes: each box's machine, rate, requests of allowed and volumes."""
    out: list[dict[str, float | str]] = []
    for row in md_table("SIZING.md", SIZES_HEAD):
        cpu, mem, disk = (float(v.replace(",", "")) for v in re.findall(r"([\d.,]+) (?:vCPU|GiB)", row[1]))
        (cpu_req, cpu_allowed), (mem_req, mem_allowed) = re.findall(r"([\d.]+) of ([\d.]+)", row[4])
        out.append({
            "box": row[0].strip("`"), "machine": row[1], "cpu": cpu, "mem": mem, "disk": disk, "rate": number(row[2]),
            "cpu_req": float(cpu_req), "cpu_allowed": float(cpu_allowed), "mem_req": float(mem_req),
            "mem_allowed": float(mem_allowed), "volumes": number(row[5]), "object_store": number(row[6]),
        })
    return out


def system_gi() -> float:
    m = re.search(r"volumes \+ (\d+) GiB system", doc("SIZING.md"))
    if not m:
        raise SystemExit("SIZING.md no longer says what the system keeps of a one-disk box")
    return float(m[1])


def default_ttls() -> str:
    m = re.search(r"At the default TTLs \((\d+) days, (\d+) extended\)", doc("SIZING.md"))
    if not m:
        raise SystemExit("SIZING.md no longer names the default TTLs")
    return f"{m[1]} / {m[2]}"


def step_multiples() -> list[float]:
    m = re.search(r"^STEPS = \(([^)]*)\)", (ROOT / "utils/langsmith-load-test/src/loadtest/judge.py").read_text(), re.M)
    if not m:
        raise SystemExit("judge.py no longer has STEPS")
    return [float(v) for v in m[1].split(",") if v.strip()]


def shell_default(name: str) -> str:
    m = re.search(rf"\${{{name}:-([^}}]+)}}", doc("lib/prove.sh"))
    if not m:
        raise SystemExit(f"lib/prove.sh no longer defaults {name}")
    return m[1]


def install_step(label: str) -> str:
    """A box step's label, refused if box/install.sh no longer runs a step by that name."""
    if not re.search(rf"^\s*run {label} ", doc("box/install.sh"), re.M):
        raise SystemExit(f"box/install.sh has no step {label}: the install figure is out of date")
    return label


def release_order() -> list[str]:
    src = doc("infra/releases.tf")
    return re.findall(r'"([a-z-]+)"', src[src.index("release_order = concat(") :].split("\n  )")[0])


# ---- where Lite fits -----------------------------------------------------------------------------


def full_deployment() -> list[str]:
    o = [rect(0, 0, 716, 720, "frame", 16), text(24, 40, "A full deployment", "hl"),
         text(24, 66, "The cloud modules; the bare-metal module on a cluster", "b")]
    for i, c in enumerate(TENANTS):
        o += [chip(24 + i * 168, 96, "Organization", c, "ABCD"[i], ""),
              line(100 + i * 168, 130, 100 + i * 168, 178, "w", "w")]
    o += [rect(24, 184, 668, 196, "card", 12), text(44, 214, "One LangSmith install, shared by every tenant", "cap")]
    services = [("platform-backend", "2 to 10, HPA"), ("ingest-queue", "3 to 10, KEDA"),
                ("backend", "3 to 10, HPA"), ("SmithDB", "a pod per role")]
    for i, (name, n) in enumerate(services):
        x = 44 + i * 162
        o += [rect(x + 10, 238, 150, 104, "card", 8), rect(x + 5, 243, 150, 104, "card", 8),
              rect(x, 248, 150, 104, "card", 8), text(x + 14, 280, name, "hs"), text(x + 14, 306, n, "mm")]
    o += [line(x, 380, x, 432, "w", "w") for x in (130, 358, 586)]
    o += [rect(24, 438, 668, 196, "card", 12), text(44, 466, "Managed stores, outside the cluster, shared", "cap")]
    for i, (name, where) in enumerate((("Postgres", "RDS, Cloud SQL"), ("Redis", "ElastiCache, Memorystore"),
                                       ("Object storage", "S3, GCS, Azure Blob"))):
        x = 60 + i * 222
        o += [cylinder(x, 484, 150, 90, list(TENANTS) * 3), text(x, 600, name, "hs"), text(x, 620, where, "b")]
    return o + [text(24, 668, "Separation is logical: each tenant's rows sit beside the others' in one database.", "b"),
                text(24, 694, "Scales out, highly available, managed backups, every product.", "b")]


def lite_silos(x0: float) -> list[str]:
    o = [rect(x0, 0, 716, 720, "frame", 16), text(x0 + 24, 40, "LangSmith Lite", "hl"),
         text(x0 + 24, 66, "modules/lite: an install a tenant", "mm")]
    for i, c in enumerate(TENANTS):
        sx, letter = x0 + 24 + i * 171, "ABCD"[i]
        o += [rect(sx, 96, 155, 538, "card", 12, f"stroke:{c};stroke-width:var(--lc-stroke)"),
              circle(sx + 24, 124, 12, "", f"fill:{c}"), text(sx + 24, 129, letter, "on", "middle"),
              text(sx + 44, 130, f"Tenant {letter}", "h"), rect(sx + 12, 152, 131, 112, "card", 8),
              text(sx + 24, 180, "LangSmith", "hs"), text(sx + 24, 204, ["Tracing only,", "a pod a service,", "sized to its load"], "b", lh=19)]
        for j, name in enumerate(("Postgres", "Redis", "RustFS")):
            o += [cylinder(sx + 12, 284 + j * 82, 131, 64, [c], 0.3), text(sx + 77, 330 + j * 82, name, "", "middle")]
        o += [rect(sx + 12, 540, 131, 28, "", 6, f"fill:{c};fill-opacity:0.45"),
              text(sx + 77, 559, "Its own disk", "", "middle"), text(sx + 77, 604, "Its own keys", "b", "middle")]
    return o + [text(x0 + 24, 668, "Separation is physical: its own processes, databases, disk and credentials.", "b"),
                text(x0 + 24, 694, "Up to 50 runs/s an install, tracing only; each install is one failure domain.", "b")]


def standard_vs_lite() -> str:
    return page(
        "Where Lite fits",
        "A full deployment keeps every tenant in one set of stores; Lite gives each install stores of its own",
        "Both run the same LangSmith chart and images. They differ in where the data lives, and so in what one "
        "tenant's data shares with another's.",
        svg(720, "".join(full_deployment() + lite_silos(756))),
        "ARCHITECTURE.md, Beside the other modules",
    )


def machine_per_install() -> list[str]:
    o = [rect(0, 0, 716, 760, "frame", 16), text(24, 40, "A machine an install", "hl"),
         text(24, 66, "cloud = baremetal or aws; make up", "mm")]
    for i, (what, note) in enumerate((("your server", "or a VM in any cloud"), ("a VM", "on a laptop: Lima, UTM"),
                                      ("an EC2 instance", "a gp3 data volume"))):
        x, c, n = 24 + i * 228, TENANTS[i], "abc"[i]
        o += [rect(x, 96, 212, 400, "card", 12, f"stroke:{c};stroke-width:var(--lc-stroke)"), text(x + 16, 126, what, "h"),
              text(x + 16, 148, note, "b"), rect(x + 14, 166, 184, 34, "key", 6), text(x + 26, 189, "k3s, one node", "cap")]
        for j, (ns, holds) in enumerate(((n, "LangSmith, SmithDB"), (f"{n}-data", "Postgres, Redis, RustFS"),
                                          (f"{n}-observe", "Prometheus, Grafana"))):
            y = 214 + j * 70
            o += [rect(x + 14, y, 184, 60, "card", 6), text(x + 26, y + 24, ns, "m"), text(x + 26, y + 46, holds, "b")]
        o += [cylinder(x + 14, 428, 184, 54, [c], 0.3), text(x + 106, 466, "The data disk", "", "middle"),
              line(x + 106, 560, x + 106, 504, "wr", "w")]
    return o + [rect(24, 564, 668, 84, "card", 12), text(44, 594, "Your laptop: a checkout, or a state, an install", "h"),
                text(44, 620, "make up plans, ssh carries the bundle, and the box installs itself", "b"),
                text(24, 694, "Nothing shared: a machine, a k3s and a disk an install.", "b"),
                text(24, 720, "The machine is the install's failure domain, and its bill.", "b")]


def namespace_per_install(x0: float) -> list[str]:
    o = [rect(x0, 0, 716, 760, "frame", 16), text(x0 + 24, 40, "A namespace an install", "hl"),
         text(x0 + 24, 66, "cloud = cluster; make export, then your Helm or Argo CD", "mm"),
         rect(x0 + 24, 90, 668, 556, "card", 14), text(x0 + 44, 118, "Your Kubernetes cluster", "cap"),
         rect(x0 + 44, 134, 628, 44, "key", 8),
         text(x0 + 60, 162, "Your ingress controller, its namespace named in each install's ingress_namespaces", "b")]
    for i in range(3):
        x, c, n = x0 + 44 + i * 216, TENANTS[i], "abc"[i]
        o += [line(x + 98, 178, x + 98, 216, "w", "w"),
              rect(x, 220, 196, 76, "card", 8, f"stroke:{c};stroke-width:var(--lc-stroke)"), text(x + 14, 246, n, "m"),
              text(x + 14, 270, "LangSmith, a pod each", "b"), line(x + 98, 296, x + 98, 322, "w", "w"),
              rect(x, 326, 196, 92, "card", 8, f"stroke:{c};stroke-width:var(--lc-stroke)"), text(x + 14, 352, f"{n}-data", "m"),
              text(x + 14, 376, ["Postgres, Redis, RustFS", "on storage_class"], "b", lh=19)]
        if i:
            o += [line(x - 10, 214, x - 10, 424, "wg"), cross(x - 10, 319, 7)]
    for k in range(4):
        x = x0 + 44 + k * 160
        o += [rect(x, 470, 148, 52, "track", 8), text(x + 74, 502, f"Node {k + 1}", "b", "middle")]
    return o + [
        text(x0 + 44, 446, "Each namespace refuses another install's traffic (NetworkPolicy).", "b"),
        text(x0 + 44, 546, "Every install schedules on the same nodes today.", "b"),
        rect(x0 + 44, 562, 628, 70, "gap", 8),
        text(x0 + 60, 588, "Not built: an install on a node pool of its own. The chart takes a nodeSelector", "gt"),
        text(x0 + 60, 610, "and tolerations a component; the datastores chart and one Lite setting would carry them.", "gt"),
        text(x0 + 24, 694, "Separate stores, credentials and namespaces an install; the nodes are shared.", "b"),
        text(x0 + 24, 720, "No observability or Mission Control an install: one stack serves the cluster.", "b")]


def two_shapes() -> str:
    return page(
        "Many installs",
        "One sizing, two shapes: a machine an install, or a namespace an install on a cluster you run",
        "The same releases, values and Secrets either way. On a machine Lite installs k3s and everything on it; "
        "on a cluster it writes the files and your cluster's operator applies them.",
        svg(760, "".join(machine_per_install() + namespace_per_install(756))),
        "ARCHITECTURE.md, Many installs; infra/releases.tf",
    )


# ---- what one box runs ---------------------------------------------------------------------------

POD_NS = {
    "platform-backend": 0, "ingest-queue": 0, "queue": 0, "backend": 0, "frontend": 0, "SmithDB": 0,
    "Mission Control (2 pods)": 0, "Redis": 1, "Postgres": 1, "RustFS": 1, "Prometheus, Grafana, 4 collectors": 2,
    "CoreDNS, metrics-server": 3,
}
NS_NAMES = ("<name>: LangSmith", "<name>-data: the stores", "<name>-observe", "kube-system: k3s's own")
NS_FILL = ("var(--accent)", "var(--good)", "var(--text-2)", "var(--frame)")
SHORT = {"Mission Control (2 pods)": "Mission Control", "Prometheus, Grafana, 4 collectors": "observability",
         "CoreDNS, metrics-server": "k3s"}


def box_pods() -> tuple[list[tuple[str, float, float]], tuple[float, float]]:
    """SIZING.md, What runs on box s: each pod's CPU and memory request, and the table's own total."""
    pods, total = [], (0.0, 0.0)
    for row in md_table("SIZING.md", "## What runs on box `s`"):
        name = row[0].strip("*")
        if name == "Total":
            total = (millicores(row[2]) / 1000, mib(row[3]) / 1024)
        elif name != "ace-backend":
            if name not in POD_NS:
                raise SystemExit(f"SIZING.md lists {name!r}, which the box figure does not place")
            pods.append((name, millicores(row[2]), mib(row[3])))
    return sorted(pods, key=lambda p: POD_NS[p[0]]), total


def budget_bar(y: float, title: str, total: float, allowed: float, allowed_label: str,
               parts: Sequence[tuple[str, float, int]], note: str) -> list[str]:
    """One of the box's budgets, to scale: a segment a part, the allowance a mark. A part too narrow for its
    name gets it on one row below, packed left to right, with a leader that bends from the part to its name;
    each bend at its own depth, so two leaders never run along each other."""
    k = W / total
    o = [text(0, y, title, "h"), text(W, y, note, "mm", "end"), rect(0, y + 14, W, 52, "track", 6)]
    x, edge, narrow = 0.0, -1e9, 0
    for name, v, ns in parts:
        w = v * k
        o.append(rect(x, y + 14, max(w, 1.5), 52, "", 0, f"fill:{NS_FILL[ns]};fill-opacity:0.55;stroke:var(--bg)"))
        cx = x + w / 2
        if w > 9 * len(name) + 14:
            o.append(text(cx, y + 46, name, "", "middle"))
        else:
            half = (MONO * len(name) + 14) / 2
            lx = max(cx, edge + half)
            edge = lx + half
            bend = y + 74 + (narrow % 4) * 7
            o += [path(f"M{cx:.1f},{y + 66} V{bend} H{lx:.1f} V{y + 108}", "w"), text(lx, y + 124, name, "mm", "middle")]
            narrow += 1
        x += w
    ax = allowed * k
    right = ax > W - 320
    return o + [line(ax, y + 6, ax, y + 74, "mark"), text(ax + (-8 if right else 8), y + 2, allowed_label, "m",
                                                          "end" if right else "start")]


def the_box() -> str:
    row = next(r for r in sizes() if r["box"] == "s")
    pods, (cpu_total, mem_total) = box_pods()
    mem, cpu, disk = float(row["mem"]), float(row["cpu"]), float(row["disk"])
    sysg, obj, vols = system_gi(), float(row["object_store"]), float(row["volumes"])
    o = budget_bar(30, "Memory: every pod's request", mem, float(row["mem_allowed"]), f"{row['mem_allowed']:g} GiB allowed",
                   [(SHORT.get(n, n), m / 1024, POD_NS[n]) for n, _, m in pods], f"{mem_total:g} of {mem:g} GiB requested")
    o += budget_bar(230, "CPU: every pod's request", cpu, float(row["cpu_allowed"]), f"{row['cpu_allowed']:g} vCPU allowed",
                    [(SHORT.get(n, n), c / 1000, POD_NS[n]) for n, c, _ in pods], f"{cpu_total:g} of {cpu:g} vCPU requested")
    o += budget_bar(430, "Disk: the system and every volume", disk, disk * 0.8, f"{disk * 0.8:g} GiB: the plan fills to 80%",
                    [("system", sysg, 3), ("object store: SmithDB's segments, the payloads", obj, 1),
                     ("the other volumes", vols - obj, 1)], f"{sysg + vols:g} of {disk:g} GiB")
    lx = 0.0
    for i, ns in enumerate(NS_NAMES):
        o += [rect(lx, 560, 18, 18, "", 4, f"fill:{NS_FILL[i]};fill-opacity:0.55"), text(lx + 28, 575, ns, "mm")]
        lx += 28 + MONO * len(ns) + 40
    o.append(text(0, 614, "A mark is the most the plan lets requests reach: 85% of what k3s leaves allocatable. Every bar is to scale.", "b"))
    return page(
        "What one box runs",
        f"Box s, to scale: {len(pods)} workloads ask {mem_total:g} of its {mem:g} GiB and {cpu_total:g} of its {cpu:g} vCPU",
        f"At its design rate of {row['rate']:g} runs/s, with 14 and 30 days of retention. The stores' memory is reserved "
        "(request equals limit), so a node short of memory reclaims it from the app first; every volume is a folder on one disk.",
        svg(630, "".join(o)),
        "SIZING.md, The sizes and What runs on box s",
    )


# ---- how it installs -----------------------------------------------------------------------------

LAPTOP = [("Ask what the settings lack", "lib/settings.py; NAME=value answers one", "card"),
          ("Resolve each chart line", "live Helm repos -> an exact version each", "card"),
          ("terraform plan", "size every pod and volume, check the fit, render the bundle", "card"),
          ("Show the plan, and ask once", "make plan stops here", "key"),
          ("terraform apply", "the credentials; on AWS the instance, its volume, its snapshots", "card")]


def laptop_lane() -> list[str]:
    o = [text(0, 20, "On your laptop: bin/lite", "cap")]
    for i, (title, note, cls) in enumerate(LAPTOP):
        y = 44 + i * 96
        o += [rect(0, y, 600, 78, cls, 10), badge(34, y + 39, str(i + 1), 16), text(66, y + 33, title, "h"),
              text(66, y + 58, note, "mm" if note.startswith(("lib/", "make ")) else "b")]
        if i:
            o.append(line(34, y - 18, 34, y, "w"))
    return o + [
        path("M600,467 H668 Q680,467 680,455 V108 Q680,96 692,96 H770", "wa", "wa"),
        text(612, 506, ["One ssh session,", "sudo asked once:", "the bundle, the", "datastores chart", "and box/"], "b", lh=19),
        rect(0, 600, 600, 116, "card", 10), text(24, 632, "Nothing on the laptop talks to Kubernetes", "h"),
        text(24, 658, ["Terraform has no Kubernetes or Helm provider. The box installs itself", "with k3s's own controllers, and keeps running without the laptop."], "b", lh=21),
        rect(0, 736, 600, 82, "card", 10), text(24, 768, "cloud = cluster: no machine, no ssh", "h"),
        text(24, 794, "make export writes the same releases for your Helm or Argo CD", "b")]


BOX_STEPS = [("data", "AWS: the data volume, mounted at k3s's storage folder", "aws only"),
             ("k3s", "k3s at the pinned version", ""),
             ("node", "the node Ready", ""),
             ("machine", "every pod held to the size's machine", "emulate_machine"),
             ("fresh", "this install's releases, namespaces and volumes removed", "FRESH=1"),
             ("base", "namespaces, their policies, storage class, Traefik", ""),
             ("secrets", "every credential, applied server-side", ""),
             ("kubeconfig", "the ssh user's: the operator's, not admin", ""),
             ("datastores", "each release's HelmChart, in order:", ""),
             ("available", "every LangSmith deployment available", ""),
             ("retire", "what an earlier install had and this one lacks, removed", "")]


def releases_block(tx: float, y: float) -> tuple[list[str], float]:
    rels = release_order()
    rows = math.ceil(len(rels) / 3)
    height = 30 + rows * 50 + 30
    o = [rect(tx + 20, y - 10, W - tx - 20, height, "card", 10)]
    for i, rel in enumerate(rels):
        cx, cy = tx + 40 + (i % 3) * 214, y + 14 + (i // 3) * 50
        o += [rect(cx, cy, 184, 34, "key" if i < 2 else "card", 17), text(cx + 92, cy + 22, rel, "mm", "middle")]
        if i % 3:
            o.append(line(cx - 28, cy + 17, cx - 4, cy + 17, "w", "w"))
    o.append(text(tx + 40, y + height - 22, "the stores first; k3s's helm-controller runs each one's install Job", "b"))
    return o, height


def box_lane() -> list[str]:
    tx, y = 800, 96
    o = [text(780, 20, "On the box: box/install.sh, as root", "cap"), circle(tx, 50, 7, "", "fill:var(--connector)"),
         text(tx + 24, 55, "checks.sh again: the preflight's checks", "")]
    for label, what, cond in BOX_STEPS:
        o += [line(tx, y - 38, tx, y - 10, "w"),
              circle(tx, y, 9, "", "fill:var(--bg);stroke:var(--connector);stroke-width:var(--lc-stroke);stroke-dasharray:3 3" if cond
                     else "fill:var(--accent)"),
              text(tx + 24, y + 5, what, ""), text(W, y + 5, install_step(label), "mm", "end")]
        if cond:
            o.append(chip(tx + 24 + 7.3 * len(what) + 16, y - 17, cond, "var(--warn-line)"))
        if label == "datastores":
            block, height = releases_block(tx, y + 34)
            o += block
            y += height + 34
        y += 58
    return o


def install() -> str:
    return page(
        "From make up to a running box",
        "The laptop plans and sends one bundle; the box installs itself, with root only for k3s",
        "Every step on the box is idempotent: a second make up changes only what differs, and one that stopped "
        "picks up where it did. A dashed step runs only when its setting asks.",
        svg(980, "".join(laptop_lane() + box_lane())),
        "lib/deploy.sh; box/install.sh; infra/releases.tf",
    )


# ---- how a trace moves ---------------------------------------------------------------------------

# x, y, radius, name, role, where the name goes (above or below)
NODES = {
    "sdk": (50, 110, 26, "An SDK", "sends runs", "above"), "ui": (50, 520, 26, "A reader", "the UI, the SDK", "below"),
    "traefik": (200, 320, 28, "Traefik", "the ingress", "below"), "frontend": (350, 320, 28, "frontend", "nginx", "below"),
    "pb": (500, 110, 32, "platform-backend", "answers 202", "above"), "backend": (500, 520, 32, "backend", "the API", "below"),
    "redis": (660, 110, 40, "Redis", "runs until ingested", "above"), "iq": (830, 110, 32, "ingest-queue", "drains Redis", "above"),
    "queue": (660, 320, 22, "queue", "the worker", "left"), "smithdb": (840, 330, 48, "SmithDB", "one pod", "below"),
    "rustfs": (1000, 110, 40, "RustFS", "two buckets", "above"), "pg": (660, 520, 40, "Postgres", "two databases", "below"),
    "cache": (1000, 520, 26, "query cache", "local disk", "below"),
}
STORES = {"redis", "pg", "rustfs", "cache"}
BADGE_AT = {"6": 0.3}
WRITES = [("1", "sdk", "traefik", 0), ("2", "traefik", "frontend", 0), ("3", "frontend", "pb", 0), ("4", "pb", "redis", 0),
          ("5", "redis", "iq", 0), ("6", "iq", "smithdb", 0), ("7", "smithdb", "pg", 0), ("8", "smithdb", "rustfs", 0)]
READS = [("ui", "traefik", 0), ("frontend", "backend", 0), ("backend", "smithdb", 30), ("backend", "pg", 0),
         ("smithdb", "cache", 0)]
KEY = [("1, 2", "An SDK sends a run through Traefik to frontend, the nginx in front of every request."),
       ("3", "On /runs, platform-backend accepts it and answers 202 at once."),
       ("4", "It keeps the run and a task in Redis, and a payload of 20 KiB or more in RustFS's blob bucket."),
       ("5, 6", "ingest-queue takes the task, writes the run to SmithDB, and deletes its payload from Redis, keeping a small record for late feedback."),
       ("7, 8", "SmithDB writes small segments, merges them into one every few minutes, records each in its metastore in Postgres, and stores its file in RustFS.")]


def edge(a: str, b: str, bend: float = 0) -> tuple[str, float, float]:
    x1, y1, r1 = NODES[a][:3]
    x2, y2, r2 = NODES[b][:3]
    dx, dy = x2 - x1, y2 - y1
    d = math.hypot(dx, dy)
    sx, sy, ex, ey = x1 + dx / d * r1, y1 + dy / d * r1, x2 - dx / d * (r2 + 4), y2 - dy / d * (r2 + 4)
    mx, my = (sx + ex) / 2 - dy / d * bend, (sy + ey) / 2 + dx / d * bend
    return f"M{sx:.1f},{sy:.1f} Q{mx:.1f},{my:.1f} {ex:.1f},{ey:.1f}", (sx + 2 * mx + ex) / 4, (sy + 2 * my + ey) / 4


def node_label(x: float, y: float, r: float, name: str, role: str, where: str) -> list[str]:
    if where == "left":
        return [text(x - r - 12, y - 2, name, "hs", "end"), text(x - r - 12, y + 16, role, "b", "end")]
    if where == "above":
        return [text(x, y - r - 30, name, "hs", "middle"), text(x, y - r - 12, role, "b", "middle")]
    return [text(x, y + r + 24, name, "hs", "middle"), text(x, y + r + 42, role, "b", "middle")]


def trace_key(x0: float) -> list[str]:
    o, y = [text(x0, 20, "A run written, in order", "cap")], 56
    for num, what in KEY:
        words, rows, cur = what.split(), [], ""
        for w in words:
            if len(cur) + len(w) > 44:
                rows.append(cur)
                cur = w
            else:
                cur = f"{cur} {w}".strip()
        rows.append(cur)
        o += [rect(x0, y - 17, 10 + MONO * len(num) + 10, 24, "", 12, "fill:var(--accent)"),
              text(x0 + 10, y, num, "on"), text(x0 + 70, y, rows, "", lh=20)]
        y += 20 * len(rows) + 22
    o += [text(x0, y + 14, "A read", "cap"),
          text(x0, y + 44, ["A reader reaches backend on /api, which asks SmithDB", "for runs (recent segments from its query cache)",
                            "and Postgres for orgs, projects and keys."], "b", lh=20),
          text(x0, y + 124, ["queue, LangSmith's background worker, reads Redis", "and Postgres beside the path."], "b", lh=20)]
    return o


def trace_path() -> str:
    o = [path("M532,124 C640,240 900,240 962,124", "wa", "wa"),
         text(745, 246, ["Payloads of", "20 KiB and more"], "b", "middle", lh=19)]
    o += [path(edge(a, b, bend)[0], "w") for a, b, bend in (("queue", "redis", 0), ("queue", "pg", 0))]
    o += [path(edge(a, b, bend)[0], "wr", "w") for a, b, bend in READS]
    o += [path(edge(a, b, bend)[0], "wa", "wa") for _, a, b, bend in WRITES]
    for num, a, b, bend in WRITES:
        _, mx, my = edge(a, b, bend)
        if num in BADGE_AT:  # a straight edge another crosses at its middle: its badge sits along it instead
            (x1, y1), (x2, y2), f = NODES[a][:2], NODES[b][:2], BADGE_AT[num]
            mx, my = x1 + (x2 - x1) * f, y1 + (y2 - y1) * f
        o.append(badge(mx, my, num))
    o.append(badge(712, 207, "4"))
    for key, (x, y, r, name, role, where) in NODES.items():
        fill = "var(--good)" if key in STORES else "var(--text-2)" if key in ("sdk", "ui") else "var(--accent)"
        o += [circle(x, y, r, "ball", f"fill:{fill};fill-opacity:{0.85 if key == 'smithdb' else 0.6}"),
              *node_label(x, y, r, name, role, where)]
    lg = 640
    o += [line(0, lg, 40, lg, "wa", "wa"), text(52, lg + 5, "a run written", "b"), line(200, lg, 240, lg, "wr", "w"),
          text(252, lg + 5, "a read", "b"), line(360, lg, 400, lg, "w"), text(412, lg + 5, "the worker", "b"),
          circle(560, lg, 10, "", "fill:var(--accent);fill-opacity:0.6"), text(578, lg + 5, "a service", "b"),
          circle(700, lg, 10, "", "fill:var(--good);fill-opacity:0.6"), text(718, lg + 5, "a store", "b")]
    return page(
        "How a trace moves",
        "A run is accepted at once, waits in Redis, and SmithDB writes it to RustFS; reads go to SmithDB and Postgres",
        "Every hop is inside one box, and each store holds one kind of data with one bound on it. make verify follows "
        "ten traces along the numbered path and names the hop where they stop.",
        svg(670, "".join(o + trace_key(1090))),
        "ARCHITECTURE.md, How a trace moves",
    )


# ---- security ------------------------------------------------------------------------------------

NS_BOXES = {
    "ingress": (0, 50, 250, 96, "kube-system", ["Traefik, k3s's ingress"]),
    "tunnel": (0, 196, 250, 96, "<ns>-tunnel", ["cloudflared, with", "access = tunnel"]),
    "ns": (330, 50, 250, 242, "<ns>", ["LangSmith's pods,", "SmithDB,", "Mission Control"]),
    "observe": (330, 372, 250, 110, "<ns>-observe", ["Prometheus, Grafana,", "the exporters"]),
    "data": (660, 50, 220, 242, "<ns>-data", ["Postgres, Redis,", "RustFS"]),
    "other": (660, 372, 220, 110, "another install", ["on the same cluster"]),
}


def network() -> list[str]:
    o = [text(0, 20, "The network: what each namespace admits", "cap")]
    for key, (x, y, w, bh, name, rows) in NS_BOXES.items():
        o += [rect(x, y, w, bh, "key" if key == "data" else "card", 10), text(x + 18, y + 30, name, "m"),
              text(x + 18, y + 56, rows, "b", lh=20)]
    admitted = ["M250,98 L326,98", "M250,244 L326,244", "M580,171 L656,171", "M455,372 L455,296",
                "M580,427 C630,427 630,250 656,250"]
    o += [path(d, "wa", "wa") for d in admitted]
    o += [path("M125,292 V508 Q125,520 137,520 H896 Q908,520 908,508 V184 Q908,172 896,172 H886", "wg", "wg"),
          cross(520, 520), path("M770,372 L770,296", "wg", "wg"), cross(770, 334)]
    return o + [line(0, 580, 40, 580, "wa", "wa"), text(52, 585, "admitted", "b"), line(160, 580, 200, 580, "wg", "wg"),
                text(212, 585, "refused: the tunnel reaches no store, and no install another's", "b")]


def access(x0: float) -> list[str]:
    return [
        text(x0, 20, "Access: three rings, root the smallest", "cap"),
        rect(x0, 50, W - x0, 470, "card", 14), text(x0 + 24, 84, "Your laptop", "h"),
        text(x0 + 24, 110, ["Terraform and its local state, which holds every", "generated credential; the license key, mode 600"], "b", lh=20),
        rect(x0 + 24, 168, W - x0 - 48, 328, "card", 12), text(x0 + 48, 200, "The ssh user on the box", "h"),
        text(x0 + 48, 226, ["The operator's kubeconfig: read the install, its", "logs, tunnels, exec in its own namespaces. Not",
                            "cluster-admin; not nodes/proxy."], "b", lh=20),
        rect(x0 + 48, 314, W - x0 - 96, 158, "key", 10), text(x0 + 72, 346, "root, by sudo, asked once a command", "h"),
        text(x0 + 72, 372, ["k3s and its config, the data disk's mount,", "k3s's manifests folder; make down and",
                            "FRESH=1 remove volumes. Every other verb", "reads through the operator's kubeconfig."], "b", lh=20)]


def isolation() -> str:
    return page(
        "Security",
        "Each namespace admits only what needs it, and root is asked for only to install or remove k3s",
        "Grafana, Prometheus, Mission Control and the stores have no port on the box. A tunnel takes requests from "
        "the internet, so it runs in a namespace no store admits.",
        svg(600, "".join(network() + access(950))),
        "ARCHITECTURE.md, Security; infra/bundle.tf",
    )


# ---- the sizes and the retention -----------------------------------------------------------------


def join(names: list[str]) -> str:
    return names[0] if len(names) == 1 else ", ".join(names[:-1]) + " and " + names[-1]


def size_bars(r: dict[str, float | str], y: float, label_w: float, bar_w: float) -> list[str]:
    sysg = system_gi()
    bars = [("CPU", float(r["cpu_req"]), float(r["cpu_allowed"]), float(r["cpu"]), "vCPU"),
            ("memory", float(r["mem_req"]), float(r["mem_allowed"]), float(r["mem"]), "GiB"),
            ("disk", float(r["volumes"]) + sysg, float(r["disk"]) * 0.8, float(r["disk"]), "GiB")]
    o = []
    for j, (name, used, allowed, total, unit) in enumerate(bars):
        by, k = y + 8 + j * 34, bar_w / total
        o += [text(label_w - 14, by + 19, name, "b", "end"), rect(label_w, by + 4, bar_w, 22, "track", 4),
              rect(label_w, by + 4, used * k, 22, "", 4, "fill:var(--accent);fill-opacity:0.6"),
              line(label_w + allowed * k, by, label_w + allowed * k, by + 30, "mark"),
              text(label_w + bar_w + 14, by + 20, f"{used:,g} of {allowed:,g} {unit}", "m")]
    return o


def size_rows() -> str:
    rows = sizes()
    label_w, bar_w = 300, W - 300 - 230
    o, y = [], 0.0
    for r in rows:
        rate = float(r["rate"])
        o += [text(0, y + 40, str(r["box"]), "hl"), text(60, y + 36, f"{rate:g} run{'' if rate == 1 else 's'}/s", "m"),
              text(0, y + 68, str(r["machine"]), "mm"), *size_bars(r, y, label_w, bar_w)]
        y += 140
        o.append(line(0, y - 20, W, y - 20, "rule"))
    o += [rect(label_w, y + 4, 40, 18, "", 4, "fill:var(--accent);fill-opacity:0.6"),
          text(label_w + 52, y + 18, f"requested (disk: the volumes and the system's {system_gi():g} GiB)", "b"),
          line(label_w + 560, y, label_w + 560, y + 26, "mark"),
          text(label_w + 576, y + 18, "the most the plan allows: 85% of allocatable; 80% of the disk", "b")]
    cpu_first = [str(r["box"]) for r in rows
                 if float(r["cpu_req"]) / float(r["cpu_allowed"]) > float(r["mem_req"]) / float(r["mem_allowed"])]
    mem_first = [str(r["box"]) for r in rows if str(r["box"]) not in cpu_first]
    title = f"Each size against its machine: CPU comes nearest its allowance at {join(cpu_first)}"
    return page(
        "The sizes",
        title + (f", memory at {join(mem_first)}" if mem_first else ""),
        "At each size's design rate and the default retention. Requests may reach 85% of what k3s leaves; the "
        "volumes and the system may fill 80% of the disk, the rest kept for images and so k3s never evicts.",
        svg(y + 40, "".join(o)),
        "SIZING.md, The sizes",
    )


def retention() -> str:
    body = doc("SIZING.md")
    heads = [c.strip() for c in body.split("| TTLs, days (short / extended) |")[1].splitlines()[0].strip(" |").split("|")]
    values = [number(c) for c in md_table("SIZING.md", "| TTLs, days (short / extended)")[0][1:]]
    default = default_ttls()
    top, plot_h, bw = max(values), 380, 150
    gap, k = (W - 80 - bw * len(values)) / (len(values) - 1), plot_h / (math.ceil(max(values) / 100) * 100)
    o = []
    for t in range(0, math.ceil(top / 100) * 100 + 1, 100):
        ty = 40 + plot_h - t * k
        o += [line(60, ty, W, ty, "rule"), text(50, ty + 5, f"{t}", "mm", "end")]
    for i, (head, v) in enumerate(zip(heads, values, strict=True)):
        x, bh, is_default = 80 + i * (bw + gap), v * k, head == default
        o += [rect(x, 40 + plot_h - bh, bw, bh, "", 6, f"fill:var(--accent);fill-opacity:{0.8 if is_default else 0.35}"),
              text(x + bw / 2, 30 + plot_h - bh, f"{v:g} GiB", "m", "middle"),
              text(x + bw / 2, 70 + plot_h, head.replace(" / ", " and "), "h", "middle"),
              text(x + bw / 2, 92 + plot_h, "Days, the default" if is_default else "Days", "b", "middle")]
    o.append(text(0, 26, "GiB", "mm"))
    lo, hi = min(values), max(values)
    return page(
        "The retention",
        f"Retention sizes the disk: at box s the object store runs from {lo:g} to {hi:g} GiB, {hi / lo:.0f} times over",
        "The object store at box s's design rate for each pair of TTLs: the short, and the extended for 5% of traces. "
        "m is five times each, l ten. make up asks for the TTLs because nothing else moves the disk as much.",
        svg(plot_h + 110, "".join(o)),
        "SIZING.md, The retention",
    )


# ---- proving it works ----------------------------------------------------------------------------

LANE_H = 150


def rate_y(y: float, m: float, top: float) -> float:
    return y + LANE_H - 26 - (LANE_H - 52) * m / top


def verify_lane(x0: float) -> list[str]:
    o = []
    for j, hop in enumerate(("accepted", "drained from Redis", "flushed by SmithDB", "readable by a query")):
        cx = x0 + 40 + j * 290
        o += [badge(cx, 62, str(j + 1), 14), text(cx, 104, hop, "", "middle")]
        if j:
            o.append(line(cx - 276, 62, cx - 18, 62, "wa", "wa"))
    return o


def soak_lane(x0: float, xw: float, y: float) -> list[str]:
    duration, ramp = int(shell_default("DURATION")), int(shell_default("RAMP"))
    kx = (xw - 40) / (duration + ramp)
    top, design = rate_y(y, 1, 1.4), rate_y(y, 0, 1.4)
    return [path(f"M{x0},{design} L{x0 + ramp * kx},{top} L{x0 + (duration + ramp) * kx},{top}", "wa"),
            text(x0 + ramp * kx / 2 + 10, design - 8, f"A {ramp // 60}-minute ramp", "b"),
            text(x0 + ramp * kx + 12, top - 12, f"The design rate with its readers for {duration // 60} minutes; every target judged", "b")]


def step_lane(x0: float, xw: float, y: float) -> list[str]:
    steps = step_multiples()
    seg, top = (xw - 40) / len(steps), max(steps)
    d, o = f"M{x0},{rate_y(y, 0, top)}", []
    for j, s in enumerate(steps):
        d += f" L{x0 + j * seg},{rate_y(y, s, top)} L{x0 + (j + 1) * seg},{rate_y(y, s, top)}"
        o.append(text(x0 + j * seg + seg / 2, rate_y(y, s, top) - 10, f"{s:g}x", "m", "middle"))
    return [path(d, "wa"), *o]


def experiment_lane(x0: float, xw: float, y: float) -> list[str]:
    steps = [float(s) for s in shell_default("STEPS").split()]
    per, top, o = (xw - 40) / 4, max(steps) * 1.3, []
    for j, box in enumerate(shell_default("SIZES").split()):
        bx = x0 + j * per
        sw = (per - 150) / len(steps)
        d = f"M{bx + 124},{rate_y(y, 0, top)}"
        for k, s in enumerate(steps):
            d += f" L{bx + 124 + k * sw},{rate_y(y, s, top)} L{bx + 124 + (k + 1) * sw},{rate_y(y, s, top)}"
            o.append(text(bx + 124 + k * sw + sw / 2, rate_y(y, s, top) - 8, f"{s:g}x", "mm", "middle"))
        o += [rect(bx, y + 18, 82, 30, "gap", 15), text(bx + 41, y + 38, "FRESH=1", "mm", "middle"),
              circle(bx + 104, y + 33, 8, "", "fill:var(--accent)"), text(bx + 104, y + 64, "verify", "mm", "middle"),
              path(d, "wa"), text(bx + per / 2, y + LANE_H - 6, f"box {box}", "h", "middle")]
    return o


def proving() -> str:
    x0, xw, gap = 330, W - 330, 16
    lanes = [("make verify", "Do traces flow?", "about 2 minutes"),
             ("make soak", "Does it hold its design load?",
              f"About {(int(shell_default('DURATION')) + int(shell_default('RAMP'))) // 60} minutes, the ramp included"),
             ("STEP=1 make soak", "What does it hold?", "until a step does not hold"),
             ("make experiment", "What does each size hold?", "About an hour and a quarter a size")]
    o = []
    for i, (verb, q, takes) in enumerate(lanes):
        y = i * (LANE_H + gap)
        o += [rect(0, y, W, LANE_H, "card", 12), text(24, y + 40, verb, "m"), text(24, y + 70, q, "h"), text(24, y + 96, takes, "b")]
    o += verify_lane(x0) + soak_lane(x0, xw, LANE_H + gap) + step_lane(x0, xw, 2 * (LANE_H + gap))
    o += experiment_lane(x0, xw, 3 * (LANE_H + gap))
    steps = shell_default("STEPS").split()
    return page(
        "Proving it works",
        "Four questions, each a command: do traces flow, does it hold its load, what does it hold, what does each size hold",
        f"Each runs the load test from the laptop through ssh, with an API key it makes and revokes. The experiment "
        f"starts each size from no data and holds it {shell_default('MINUTES')} minutes at {join(steps)} times its design rate.",
        svg(4 * LANE_H + 3 * gap, "".join(o)),
        "OPERATE.md, Proving it works; lib/prove.sh; the load test's judge.py",
    )


FIGURES: dict[str, Callable[[], str]] = {
    "standard-vs-lite": standard_vs_lite,
    "two-shapes": two_shapes,
    "the-box": the_box,
    "install": install,
    "trace-path": trace_path,
    "isolation": isolation,
    "sizes": size_rows,
    "retention": retention,
    "proving": proving,
}


def draw(fonts_dir: Path | None, logos_dir: Path | None, draft: bool, only: list[str], keep: Path | None = None) -> list[str]:
    unknown = set(only) - set(FIGURES)
    if unknown:
        raise SystemExit(f"no figure {', '.join(sorted(unknown))}; the figures: {', '.join(FIGURES)}")
    fonts, missing = faces(fonts_dir)
    if missing and not draft:
        raise SystemExit(f"the brand faces are missing ({', '.join(missing)}): check out ps-ops-center and content-studio beside this repository (or set PS_OPS_CENTER and CONTENT_STUDIO), give --fonts DIR, or --draft")
    note = f"Drawn without the brand faces ({', '.join(missing)} missing); not for publishing." if missing else ""
    drawn = json.loads(RENDERED.read_text()) if RENDERED.is_file() else {}
    binary, names = chrome(), only or list(FIGURES)
    with tempfile.TemporaryDirectory() as tmp:
        for name in names:
            markup = FIGURES[name]()
            for theme in THEMES:
                html = Path(tmp) / f"{name}-{theme}.html"
                html.write_text(document(markup, theme, fonts, logo(logos_dir, theme), note))
                shoot(binary, html, HERE / f"{name}.png")
                if keep:
                    keep.mkdir(parents=True, exist_ok=True)
                    (keep / html.name).write_text(html.read_text())
            if not note:
                drawn[name] = hashlib.sha256(markup.encode()).hexdigest()
    RENDERED.write_text(json.dumps({n: drawn[n] for n in sorted(drawn) if n in FIGURES}, indent=2) + "\n")
    return names


def stale() -> list[str]:
    """The figures whose page no longer matches the one last drawn: a number or a step the docs or the
    code changed since. Needs no fonts and no Chrome, so make check runs it."""
    drawn = json.loads(RENDERED.read_text()) if RENDERED.is_file() else {}
    return [name for name, page_of in FIGURES.items() if drawn.get(name) != hashlib.sha256(page_of().encode()).hexdigest()]


if __name__ == "__main__":
    a = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    a.add_argument("--fonts", type=Path, help="the folder holding the brand's four font files")
    a.add_argument("--logos", type=Path, help="the folder holding langchain-on-dark.svg")
    a.add_argument("--draft", action="store_true", help="draw without the faces, labelled, and not recorded")
    a.add_argument("--keep-html", type=Path, help="also keep each page here, for the brand linter")
    a.add_argument("--check", action="store_true", help="draw nothing: fail if a figure no longer matches its sources")
    a.add_argument("names", nargs="*", help="the figures to draw; every one by default")
    x = a.parse_args()
    if x.check:
        behind = stale()
        if behind:
            raise SystemExit(f"stale figures: {', '.join(behind)}; draw them again (diagrams/draw.py, with the faces)")
        print(f"all {len(FIGURES)} figures match their sources")
        raise SystemExit(0)
    for n in draw(x.fonts, x.logos, x.draft, x.names, x.keep_html):
        print(f"drew diagrams/{n}.png")
