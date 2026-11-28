"""Load: run rates, the scale guide's read and write bands, and the grid between its corners.

The guide publishes five configurations (Low, Medium and High on each axis, in five of the nine
combinations). The sizing between them is a bilinear blend over a 3 x 3 grid whose four unpublished
nodes start from the ratios in params and are clamped between their published neighbors.
First ported from the PS sizing calculator (README, Lineage), by Dzmitry Dubarau.
"""

from __future__ import annotations

import math
from collections.abc import Mapping, Sequence
from typing import Any

from langsmith_sizing.units import EPSILON, SECONDS_PER_DAY

Profile = dict[str, Any]

# A profile is one published configuration: replicas, the replicas the guide's autoscaler floors
# sit at, Redis GiB and ClickHouse requests. The numeric fields blend; the other two combine by rule.
NUMERIC = ("fe", "pb", "iq", "be", "min_fe", "min_pb", "min_iq", "min_be", "redis_gi", "ch_cpu", "ch_mem", "ch_rep_cpu", "ch_rep_mem")


def ceil(x: float) -> int:
    """Ceil that ignores float noise: 20.000000001 pods is 20, not 21."""
    return math.ceil(x - EPSILON)


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def anchors(cited: Mapping[str, float]) -> list[float]:
    """The guide's Low, Medium and High points of one axis, from a citation's values."""
    return [cited["low"], cited["medium"], cited["high"]]


def classify_bands(users: float, tps: float, reads: Sequence[float], writes: Sequence[float]) -> dict[str, str]:
    """Low, medium or high on each axis. Advisory: the sizing itself is continuous."""
    r = "l" if users <= reads[0] else "m" if users <= reads[1] else "h"
    w = "l" if tps <= writes[0] else "m" if tps <= writes[1] else "h"
    return {"r": r, "w": w}


def band_coord(v: float, pts: Sequence[float]) -> float:
    """Position on the 0..2 grid axis. Pinned at 0 below Low: the smallest published
    configuration is a floor, never scaled down."""
    if v <= pts[0]:
        return 0.0
    if v >= pts[-1]:
        return float(len(pts) - 1)
    if v <= pts[1]:
        return (v - pts[0]) / (pts[1] - pts[0])
    return 1 + (v - pts[1]) / (pts[-1] - pts[1])


def extrapolation_factors(users: float, tps: float, reads: Sequence[float], writes: Sequence[float]) -> dict[str, float]:
    """Linear scale-up past the highest published configuration: reads drive the frontend and
    backend, writes drive platform-backend, ingest-queue and Redis."""
    return {"rx": max(1.0, users / reads[-1]), "wx": max(1.0, tps / writes[-1])}


def beyond_published(users: float, tps: float, reads: Sequence[float], writes: Sequence[float]) -> bool:
    return users > reads[-1] or tps > writes[-1]


def scale_up(n: float, factor: float) -> int:
    return math.ceil(n * factor)


def run_rates(tps: float, runs_per_trace: float, peak_factor: float, peak_tps: float | None = None) -> dict[str, float]:
    """Average and peak runs a second, and runs a day. Storage reads the average, Redis and ingest
    the peak; a measured busiest-hour rate replaces the factor when the person has one."""
    avg = tps * runs_per_trace
    peak = peak_tps * runs_per_trace if peak_tps is not None else avg * peak_factor
    return {"runs_per_second_avg": avg, "runs_per_second_peak": peak, "runs_per_day": avg * SECONDS_PER_DAY}


def traces_per_second(per_month: float, seconds_per_month: float) -> float:
    return per_month / seconds_per_month


def traces_per_month(tps: float, seconds_per_month: float) -> float:
    return tps * seconds_per_month


def published_profiles(cited: Any) -> dict[str, Profile]:
    """The guide's five configurations by key (ll, lh, hl, mm, hh), from its summary table and its
    example values. The autoscaler floor of the Low/Low corner is the default replica count it lists."""
    out: dict[str, Profile] = {}
    ch, per_replica, setup = cited["scale.clickhouse"], cited["scale.clickhouse"]["per_replica"], cited["scale.clickhouse_setup"]
    # The guide sizes each replica of a replicated cluster only for its two high-read
    # configurations; elsewhere a replica takes the smallest documented figure.
    fallback = min(per_replica, key=lambda k: ch["cpu"][k])
    for k in cited["scale.replicas.frontend"]:
        fe, pb, iq, be = (cited[f"scale.replicas.{s}"][k] for s in ("frontend", "platform_backend", "ingest_queue", "backend"))
        # The guide gives an autoscaler floor only for the examples that show one; elsewhere it runs the published count.
        mins = {s: cited[f"scale.min_replicas.{s}.{k}"] if f"scale.min_replicas.{s}.{k}" in cited else None for s in ("frontend", "platform_backend", "ingest_queue", "backend")}
        rep = k if k in per_replica else fallback
        out[k] = {
            "fe": fe, "pb": pb, "iq": iq, "be": be,
            "min_fe": mins["frontend"] or fe, "min_pb": mins["platform_backend"] or pb,
            "min_iq": mins["ingest_queue"] or iq, "min_be": mins["backend"] or be,
            "redis_gi": cited["scale.redis_gib"][k],
            "ch_cpu": ch["cpu"][k], "ch_mem": ch["mem_gib"][k],
            "ch_rep_cpu": ch["cpu"][rep], "ch_rep_mem": ch["mem_gib"][rep],
            "ch_n": setup["replicated"] if k in setup["replicated_in"] else setup["single"], "ch_rep_documented": k in per_replica,
        }
    return out


def interpolate_profile(a: Profile, b: Profile, t: float) -> Profile:
    """A blend of two profiles, every count rounded up."""
    out: Profile = {f: math.ceil(lerp(a[f], b[f], t)) for f in NUMERIC}
    return out | {"ch_n": max(a["ch_n"], b["ch_n"]), "ch_rep_documented": a["ch_rep_documented"] and b["ch_rep_documented"]}


def _fold(ps: Sequence[Profile], pick: Any) -> Profile:
    out: Profile = {f: pick([p[f] for p in ps]) for f in NUMERIC}
    return out | {"ch_n": pick([p["ch_n"] for p in ps]), "ch_rep_documented": all(p["ch_rep_documented"] for p in ps)}


def _clamp(candidate: Profile, below: Sequence[Profile], above: Sequence[Profile]) -> Profile:
    """Holds an unpublished node inside the box its neighbors imply, so a field never falls as
    load rises (the guide's Med/Med runs 3 platform-backend replicas where Low/High runs 20).
    Where the bounds cross the floor wins."""
    return _fold([*below, _fold([candidate, *above], min)], max)


def build_grid(p: Mapping[str, Profile], blend: Mapping[str, float]) -> list[list[Profile]]:
    """The read x write grid: the five published nodes unaltered, the four edges blended and clamped."""
    ll, lh, hl, mm, hh = (p[k] for k in ("ll", "lh", "hl", "mm", "hh"))
    return [
        [ll, _clamp(interpolate_profile(ll, mm, blend["ll_mm"]), [ll], [lh, mm]), lh],
        [_clamp(interpolate_profile(ll, hl, blend["ll_hl"]), [ll], [hl, mm]), mm, _clamp(interpolate_profile(mm, hh, blend["mm_hh"]), [lh, mm], [hh])],
        [hl, _clamp(interpolate_profile(hl, hh, blend["hl_hh"]), [hl, mm], [hh]), hh],
    ]


def grid_profile(users: float, tps: float, grid: Sequence[Sequence[Profile]], reads: Sequence[float], writes: Sequence[float]) -> Profile:
    """Bilinear over the four nodes around the load. Every count rounds up once, at the end."""
    rc, wc = band_coord(users, reads), band_coord(tps, writes)
    i, j = min(1, int(rc)), min(1, int(wc))
    fr, fw = rc - i, wc - j
    nw, ne, sw, se = grid[i][j], grid[i][j + 1], grid[i + 1][j], grid[i + 1][j + 1]
    out: Profile = {f: math.ceil(lerp(lerp(nw[f], ne[f], fw), lerp(sw[f], se[f], fw), fr)) for f in NUMERIC}
    # A blended figure is only as documented as every node that carries weight in it.
    weighted = [(nw, (1 - fr) * (1 - fw)), (ne, (1 - fr) * fw), (sw, fr * (1 - fw)), (se, fr * fw)]
    return out | {
        "ch_n": max(n["ch_n"] for n in (nw, ne, sw, se)),
        "ch_rep_documented": all(w < EPSILON or n["ch_rep_documented"] for n, w in weighted),
    }


def profile_for(users: float, tps: float, grid: Sequence[Sequence[Profile]], reads: Sequence[float], writes: Sequence[float]) -> Profile:
    """The scale guide's figures at this load, scaled linearly past its highest configuration.
    ClickHouse is not scaled (deprecated, no curve)."""
    base = grid_profile(users, tps, grid, reads, writes)
    f = extrapolation_factors(users, tps, reads, writes)
    rx, wx = f["rx"], f["wx"]
    if rx == 1 and wx == 1:
        return base
    scaled = {"fe": rx, "be": rx, "pb": wx, "iq": wx, "min_fe": rx, "min_be": rx, "min_pb": wx, "min_iq": wx, "redis_gi": wx}
    return base | {k: scale_up(base[k], v) for k, v in scaled.items()}
