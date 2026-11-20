"""The load a test sends, as the plan sizes it: one description of load for both tools.

`load_profile` turns the same inputs `plan.size` takes into what a load generator needs: the write
rate (average and peak), runs a trace, the payload sizes and mix, feedback, and the read rate and
mix. utils/langsmith-load-test reads it, so a test sends the load a plan was sized for and the
payload mix exists once, in params.yaml.

Schema "langsmith-load-profile/1":
  chart                  the chart version the profile was resolved against
  write.traces_per_second, write.peak_traces_per_second, write.runs_per_trace
  write.payload.mix      % of runs per size (small, medium, large), summing to 100
  write.payload.sizes_kib  {size: {in, out}} KiB per field
  write.payload.single_run_kib  [in, out] when one size replaces the mix, else null
  write.payload.compression     the compression the model sizes storage at
  write.payload.attachment_kib_per_run  attachment KiB each run carries; 0 sends none
  write.payload.fields_per_side, content, send  how the bytes are shaped and sent (params load.payload_shape)
  write.feedback_per_trace
  read.users, read.requests_per_second
  read.mix               {class: {weight, component, what}}
  read.heavy_window_days
  targets                {stored_within_seconds: {p99}, trace_load_seconds: {p99}}
  provenance             each figure's source, as plan.size names them
"""

from __future__ import annotations

from typing import Any

from langsmith_sizing import inputs as inputs_mod
from langsmith_sizing.chart import Chart
from langsmith_sizing.model import load
from langsmith_sizing.params import Param, values
from langsmith_sizing.units import PERCENT

SCHEMA = "langsmith-load-profile/1"


def load_profile(inputs: inputs_mod.Inputs, chart: Chart, params: dict[str, Param], cited: Any) -> dict[str, Any]:
    p = values(params)
    r, src = inputs_mod.resolve(inputs, chart, p)
    runs = load.run_rates(r["traces_per_second"], r["runs_per_trace"], r["peak_factor"], r["peak_traces_per_second"])
    reads = cited["scale.read_anchors"]
    rps_per_user = reads["rps"]["high"] / reads["high"]
    total = sum(r["payload_mix"].values()) or 1
    return {
        "schema": SCHEMA,
        "chart": chart.version,
        "write": {
            "traces_per_second": r["traces_per_second"],
            "peak_traces_per_second": runs["runs_per_second_peak"] / r["runs_per_trace"],
            "runs_per_trace": r["runs_per_trace"],
            "payload": {
                "mix": {k: v * PERCENT / total for k, v in r["payload_mix"].items()},
                "sizes_kib": p["payload.bucket_kib"],
                "single_run_kib": list(r["single_run_kib"]) if r["single_run_kib"] else None,
                "compression": r["compression"],
                "attachment_kib_per_run": r["attachment_kib_per_run"],
                **p["load.payload_shape"],
            },
            "feedback_per_trace": p["load.feedback_per_trace"],
        },
        "read": {
            "users": r["users"],
            "requests_per_second": r["users"] * rps_per_user,
            "mix": p["load.read_mix"],
            "heavy_window_days": p["load.heavy_window_days"],
        },
        "targets": {"stored_within_seconds": p["slo.stored_within_seconds"], "trace_load_seconds": p["slo.trace_load_seconds"]},
        "provenance": {
            **{f"inputs.{k}": v for k, v in src.items()},
            "write.peak_traces_per_second": "derived:inputs.peak_factor",
            "write.payload.sizes_kib": "param:payload.bucket_kib",
            "write.payload.shape": "param:load.payload_shape",
            "write.feedback_per_trace": "param:load.feedback_per_trace",
            "read.requests_per_second": "docs:scale.read_anchors",
            "read.mix": "param:load.read_mix",
            "read.heavy_window_days": "param:load.heavy_window_days",
            "targets": "param:slo.stored_within_seconds,param:slo.trace_load_seconds",
        },
    }
