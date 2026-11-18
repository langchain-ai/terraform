"""The payload model: where a run's bytes land and what that costs, per run and across a mix.

Every run lands in the SmithDB bucket. The offload threshold decides only whether a field is also
written to the LangSmith bucket and whether Redis holds its body or a pointer; the backend compares
each field's uncompressed length against the threshold. Per-run costs are power-law (log-log)
curves through LangChain's measurements at three run sizes. Field sizes and the threshold are KiB,
per-run coefficients and every output are decimal KB.
Ported from the PS sizing calculator (payload.ts, formulas.ts section 4), by Dzmitry Dubarau.
"""

from __future__ import annotations

import math
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any

from langsmith_sizing.units import EPSILON, KIB, KILO, PERCENT

Pt = tuple[float, float]


def loglog(x: float, pts: Sequence[Pt], below: str, above: str) -> float:
    """Power-law interpolation through measured points. Outside them 'value' holds the end's y and
    'ratio' holds the end's y over x, so y keeps growing with x. Between points, log-log not
    linear: linear gives SmithDB 77.6 TB where the log-log reading gives 87.0 TB."""
    (x0, y0), (xn, yn) = pts[0], pts[-1]
    if x <= x0:
        return y0 if below == "value" else y0 / x0 * x
    if x >= xn:
        return yn if above == "value" else yn / xn * x
    for (xa, ya), (xb, yb) in zip(pts, pts[1:], strict=False):
        if xa <= x <= xb:
            t = (math.log(x) - math.log(xa)) / (math.log(xb) - math.log(xa))
            return math.exp(math.log(ya) + t * (math.log(yb) - math.log(ya)))
    return yn


def clamp(v: float, lim: Mapping[str, float], fallback: float) -> float:
    """v inside [min, max]; anything not finite falls back."""
    return min(lim["max"], max(lim["min"], v)) if math.isfinite(v) else fallback


@dataclass(frozen=True)
class Curves:
    """The per-run curves, built once from the measured buckets."""

    smithdb: tuple[Pt, ...]
    blob: tuple[Pt, ...]
    base: tuple[Pt, ...]
    inline: tuple[Pt, ...]
    pb: tuple[Pt, ...]
    floor_kb: float
    run_range: tuple[float, float]
    offload_min_kib: float
    inline_max_kib: float
    anchors: tuple[tuple[float, float], ...]  # (in_kib, out_kib) of each measured bucket

    def smithdb_per_run(self, s: float) -> float:
        return loglog(s, self.smithdb, "value", "ratio")

    def blob_ratio(self, s: float) -> float:
        return loglog(s, self.blob, "ratio", "ratio") / s

    def base_kb(self, s: float) -> float:
        """Redis cost of a run once every field is a pointer."""
        return loglog(s, self.base, "value", "value")

    def inline_ratio(self, s: float) -> float:
        return loglog(s, self.inline, "ratio", "ratio") / s

    def pb_per_1k(self, s: float) -> float:
        """platform-backend pods per 1,000 peak runs a second."""
        return loglog(s, self.pb, "value", "value")


def make_curves(buckets: Sequence[Mapping[str, float]], pb_reference_peak_runs: float) -> Curves:
    """Curves from the measured buckets (small to large): per-bucket field KiB, SmithDB, blob and
    Redis KB a run, and platform-backend pods at the reference volume, whose peak runs/s is
    pb_reference_peak_runs."""
    run = [b["in_kib"] + b["out_kib"] for b in buckets]
    offloaded = [(r, b) for r, b in zip(run, buckets, strict=True) if b["blob_kb"] > 0]
    inline = [(r, b) for r, b in zip(run, buckets, strict=True) if b["blob_kb"] == 0]
    blob = tuple((r, b["blob_kb"]) for r, b in offloaded)
    base = tuple((r, b["redis_kb"]) for r, b in offloaded)
    # Inline Redis bytes: the small run's Redis cost minus the pointer-only base, then the blob
    # curve. Assumes Redis's Brotli compresses about as well as the blob side's zstd; nothing
    # measures inline above the small run.
    inline_pts = tuple(sorted([(r, b["redis_kb"] - loglog(r, base, "value", "value")) for r, b in inline] + list(blob)))
    return Curves(
        smithdb=tuple((r, b["smithdb_kb"]) for r, b in zip(run, buckets, strict=True)),
        blob=blob,
        base=base,
        inline=inline_pts,
        pb=tuple((r, b["pb_pods_at_reference"] / (pb_reference_peak_runs / KILO)) for r, b in zip(run, buckets, strict=True)),
        floor_kb=buckets[0]["smithdb_kb"],
        run_range=(run[0], run[-1]),
        offload_min_kib=min(r for r, _ in offloaded),
        inline_max_kib=max(r for r, _ in inline),
        anchors=tuple((b["in_kib"], b["out_kib"]) for b in buckets),
    )


def buckets_from_params(p: Mapping[str, Any]) -> list[dict[str, Any]]:
    """The measured buckets, small to large, as the curves take them."""
    return [
        {
            "key": k, "in_kib": p["payload.bucket_kib"][k]["in"], "out_kib": p["payload.bucket_kib"][k]["out"],
            "smithdb_kb": p["payload.smithdb_kb_per_run"][k], "blob_kb": p["payload.blob_kb_per_run"][k],
            "redis_kb": p["payload.redis_kb_per_run"][k], "pb_pods_at_reference": p["payload.platform_backend_pods_at_reference"][k],
        }
        for k in p["payload.smithdb_kb_per_run"]
    ]


def curves_from_params(p: Mapping[str, Any]) -> Curves:
    """The curves from params. The platform-backend pod counts were stated at a reference volume;
    its peak runs a second is taken at the default runs a trace and peak factor."""
    ref_peak = p["payload.reference_traces_per_year"] / p["time.seconds_per_year"] * p["load.runs_per_trace"] * p["load.peak_factor"]
    return make_curves(buckets_from_params(p), ref_peak)


def bucket_coeff(
    in_kib: float, out_kib: float, curves: Curves, *, threshold_kib: float, blob: bool, compression: float, default_threshold_kib: float,
) -> dict[str, Any]:
    """KB a run costs in each store for runs of this size. A field offloads when its uncompressed
    size is at or above the threshold; compression can shrink bytes but never past the raw run."""
    s = in_kib + out_kib
    t = threshold_kib * KIB

    def off(f: float) -> bool:
        return blob and f * KIB >= t

    off_raw = (in_kib if off(in_kib) else 0) + (out_kib if off(out_kib) else 0)
    inl_raw = s - off_raw
    offloaded = (off(in_kib), off(out_kib))
    measured = blob and (in_kib, out_kib) in curves.anchors and threshold_kib == default_threshold_kib and compression == 1
    lo, hi = curves.run_range
    extrapolated = s < lo or s > hi or (off_raw > 0 and s < curves.offload_min_kib) or inl_raw > curves.inline_max_kib
    return {
        "in_kib": in_kib, "out_kib": out_kib, "run_kib": s,
        "placement": "offloaded" if all(offloaded) else "partial" if any(offloaded) else "inline",
        "smithdb_kb": smithdb_kb_per_run(curves.smithdb_per_run(s), compression, s, curves.floor_kb),
        "blob_kb": blob_kb_per_run(off_raw, curves.blob_ratio(s), compression),
        "redis_kb": redis_kb_per_run(curves.base_kb(s), inl_raw, curves.inline_ratio(s), compression),
        "pb_per_1k": curves.pb_per_1k(s),
        "basis": "measured" if measured else "extrapolated" if extrapolated else "interpolated",
    }


def mix_weights(shares: Sequence[float], default_shares: Sequence[float]) -> dict[str, Any]:
    """Run-weighted shares normalized by their sum. An all-zero mix falls back to the guide's blend
    rather than dividing by zero."""
    total = sum(shares)
    weights = [d / sum(default_shares) for d in default_shares] if total <= 0 else [s / total for s in shares]
    return {"weights": weights, "sum_pct": total, "normalized": abs(total - PERCENT) > EPSILON}


def resolve(
    shares: Sequence[float], buckets: Sequence[Mapping[str, float]], curves: Curves, *,
    threshold_kib: float, blob: bool, compression: float, default_shares: Sequence[float], default_threshold_kib: float,
    partial_inline_share: float, single: tuple[float, float] | None = None,
) -> dict[str, Any]:
    """The blend across the mix, or one run size when `single` (in KiB, out KiB) is given."""
    kw: dict[str, Any] = {"threshold_kib": threshold_kib, "blob": blob, "compression": compression, "default_threshold_kib": default_threshold_kib}
    mix: dict[str, Any]
    if single is not None:
        coeffs, mix = [bucket_coeff(single[0], single[1], curves, **kw)], {"weights": [1.0], "sum_pct": float(PERCENT), "normalized": False}
    else:
        coeffs = [bucket_coeff(b["in_kib"], b["out_kib"], curves, **kw) for b in buckets]
        mix = mix_weights(shares, default_shares)
    w = mix["weights"]

    def blend(f: str) -> float:
        return float(sum(wi * c[f] for wi, c in zip(w, coeffs, strict=True)))

    share = {"inline": 1, "partial": partial_inline_share, "offloaded": 0}
    inline_share = sum(wi * share[c["placement"]] for wi, c in zip(w, coeffs, strict=True))
    return {
        "buckets": coeffs, "weights": w, "mix_sum_pct": mix["sum_pct"], "mix_normalized": mix["normalized"] and single is None,
        "blend": {"smithdb_kb": blend("smithdb_kb"), "blob_kb": blend("blob_kb"), "redis_kb": blend("redis_kb"), "pb_per_1k": blend("pb_per_1k")},
        "inline_share": inline_share,
    }


def smithdb_kb_per_run(curve_kb: float, compression: float, run_kib: float, floor_kb: float) -> float:
    """SmithDB KB a run: min(curve x compression, raw KiB x 1.024 + the metadata floor)."""
    return min(curve_kb * compression, run_kib * KIB / KILO + floor_kb)


def blob_kb_per_run(offloaded_kib: float, ratio: float, compression: float) -> float:
    """LangSmith-bucket KB a run for the offloaded fields: KiB x min(1.024, ratio x compression)."""
    return offloaded_kib * min(KIB / KILO, ratio * compression)


def redis_kb_per_run(base_kb: float, inline_kib: float, ratio: float, compression: float) -> float:
    """Redis KB a run: a pointer-only base plus the inline field bodies."""
    return base_kb + inline_kib * min(KIB / KILO, ratio * compression)
