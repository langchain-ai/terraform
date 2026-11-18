"""langsmith-sizing: the canonical sizing for a self-hosted LangSmith install."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from langsmith_sizing import (
    PLANNED_CHARTS,
    chart,
    citations,
    compare,
    deploy,
    inputs,
    params,
    plan,
    presets,
    profile,
    profile_report,
    values,
    wizard,
)


def _check_citations(a: argparse.Namespace) -> int:
    problems = citations.check(citations.load(), a.ref)
    for p in problems:
        print(p)
    print("citations: ok" if not problems else f"citations: {len(problems)} no longer hold")
    return 1 if problems else 0


def _check_params(a: argparse.Namespace) -> int:
    loaded = params.load()
    problems = [f"{v}: {p}" for v in ([a.chart] if a.chart else PLANNED_CHARTS) for p in params.shadowed(loaded, chart.Chart(v))]
    for p in problems:
        print(p)
    print(f"params: {len(loaded)} ok at {', '.join([a.chart] if a.chart else PLANNED_CHARTS)}" if not problems else f"params: {len(problems)} shadow the chart")
    return 1 if problems else 0


def _chart_info(a: argparse.Namespace) -> int:
    c = chart.Chart(a.chart)
    keys = a.key or ["smithdb.resourceTier", "config.settings.redisRunsExpirySeconds"]
    print(json.dumps({k: c.at(k) for k in keys}, indent=2))
    return 0


def _flags(a: argparse.Namespace) -> dict[str, Any]:
    return {
        "users": a.users, "traces_per_second": a.traces_per_second, "traces_per_month": a.traces_per_month,
        "peak_traces_per_second": a.peak_traces_per_second, "runs_per_trace": a.runs_per_trace, "retention_days": a.retention_days,
        "postgres": a.postgres, "redis": a.redis, "smithdb_metastore": a.smithdb_metastore, "object_store": a.object_store, "clickhouse": a.clickhouse,
        "datastores_on": a.datastores_on, "app_node": a.app_node, "smithdb_node": a.smithdb_node, "datastore_node": a.datastore_node,
        "trace_store": a.trace_store, "survives_node_loss": a.survives_node_loss,
        "backfill_runs": a.backfill_runs, "backfill_days": a.backfill_days,
        "smithdb_tier": a.smithdb_tier, "smithdb_topology": a.smithdb_topology,
    }


def _inputs(a: argparse.Namespace) -> inputs.Inputs:
    """The inputs a command's flags and preset give: the preset first, each flag given replacing its value."""
    flags = {k: v for k, v in _flags(a).items() if v is not None}
    if a.preset:
        return presets.load(a.preset).to_inputs(a.chart, **flags)
    if "users" not in flags:
        raise ValueError("give --preset or --users")
    return inputs.Inputs(chart_version=a.chart, **flags)


def _size(a: argparse.Namespace) -> int:
    print(json.dumps(plan.size(_inputs(a), chart.Chart(a.chart), params.load(), citations.load()), indent=2))
    return 0


def _values(a: argparse.Namespace) -> int:
    print(values.to_yaml(plan.size(_inputs(a), chart.Chart(a.chart), params.load(), citations.load())["values"]), end="")
    return 0


def _stores(a: argparse.Namespace) -> int:
    print(json.dumps(deploy.stores_json(plan.size(_inputs(a), chart.Chart(a.chart), params.load(), citations.load())), indent=2))
    return 0


def _wizard(a: argparse.Namespace) -> int:
    given = {k: v for k, v in _flags(a).items() if v is not None}
    return wizard.run(chart_version=a.chart, preset_name=a.preset, given=given, yes=a.yes, out=Path(a.out), ask=input, say=print)


def _load_profile(a: argparse.Namespace) -> int:
    print(json.dumps(profile.load_profile(_inputs(a), chart.Chart(a.chart), params.load(), citations.load()), indent=2))
    return 0


def _read(path: str) -> dict[str, Any]:
    try:
        doc = json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError) as err:
        raise ValueError(f"cannot read {path}: {err}") from err
    if not isinstance(doc, dict):
        raise ValueError(f"{path} is not a JSON object")
    return doc


def _compare(a: argparse.Namespace) -> int:
    verdicts = compare.compare(_read(a.plan), _read(a.results))
    print(compare.render(verdicts))
    return 1 if compare.failed(verdicts) else 0


def _profile_report(a: argparse.Namespace) -> int:
    root = Path(a.root) if a.root else profile_report.REPO
    c, p, cited = chart.Chart(a.chart), params.load(), citations.load()
    plans = {n: plan.size(presets.load(n).to_inputs(a.chart), c, p, cited) for n in profile_report.PROFILES}
    print(profile_report.report(a.chart, plans, root))
    return 0


def _shape(text: str) -> tuple[float, float]:
    """vCPUxGiB, for example 8x32."""
    cpu, sep, mem = text.lower().partition("x")
    if not sep:
        raise argparse.ArgumentTypeError("vCPUxGiB, for example 8x32")
    return float(cpu), float(mem)


def _size_flags(s: argparse.ArgumentParser, chart_required: bool = True) -> None:
    s.add_argument("--chart", required=chart_required, metavar="X.Y.Z")
    s.add_argument("--preset", choices=presets.names(), help="start from a named load; a flag below replaces its value")
    s.add_argument("--users", type=float, help="concurrent frontend users at the busiest time")
    s.add_argument("--traces-per-second", type=float)
    s.add_argument("--traces-per-month", type=float)
    s.add_argument("--peak-traces-per-second", type=float, help="the busiest hour's rate, when known")
    s.add_argument("--runs-per-trace", type=float)
    s.add_argument("--retention-days", type=float)
    for flag in ("postgres", "redis", "smithdb-metastore", "clickhouse"):
        s.add_argument(f"--{flag}", choices=inputs.PLACEMENTS, help="where this store runs")
    s.add_argument("--object-store", choices=inputs.OBJECT_PLACEMENTS)
    s.add_argument("--datastores-on", choices=inputs.DATASTORES_ON, help="in-cluster stores share the application pool or get their own")
    for flag in ("app-node", "smithdb-node", "datastore-node"):
        s.add_argument(f"--{flag}", type=_shape, metavar="CPUxGIB", help="the node shape the pool is counted in")
    s.add_argument("--trace-store", choices=inputs.TRACE_STORES)
    s.add_argument("--survives-node-loss", action=argparse.BooleanOptionalAction)
    s.add_argument("--smithdb-tier", choices=("small", "medium", "large"), help="SmithDB's tier; default the load's (the regime's for a low one)")
    s.add_argument("--smithdb-topology", choices=("cluster", "unified"), help="SmithDB's layout; unified needs a chart with smithdb.topology")
    s.add_argument("--backfill-runs", type=float, help="ClickHouse history to copy into SmithDB, in runs (with --backfill-days)")
    s.add_argument("--backfill-days", type=float, help="the days the backfill should take")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="langsmith-sizing", description=__doc__)
    sub = p.add_subparsers(dest="command", required=True)
    s = sub.add_parser("check-citations", help="fail when a cited docs quote is gone (network)")
    s.add_argument("--ref", help="a docs commit or branch to check against (default: the pinned commit)")
    s.set_defaults(run=_check_citations)
    s = sub.add_parser("check-params", help="load params.yaml and refuse an entry without its evidence")
    s.add_argument("--chart", metavar="X.Y.Z", help="fail a parameter that gives a chart setting the value the chart already has; default every planned chart in charts.yaml")
    s.set_defaults(run=_check_params)
    s = sub.add_parser("chart-info", help="print chart values at a version (pulls the chart once)")
    s.add_argument("--chart", required=True, metavar="X.Y.Z")
    s.add_argument("--key", action="append", help="a dotted values key; repeatable")
    s.set_defaults(run=_chart_info)
    s = sub.add_parser("size", help="size an install from its load and print the plan as JSON")
    _size_flags(s)
    s.set_defaults(run=_size)
    s = sub.add_parser("values", help="print the chart values that apply a plan (secret names are <placeholders>)")
    _size_flags(s)
    s.set_defaults(run=_values)
    s = sub.add_parser("stores", help="print the spec of each data store to provision, as JSON")
    _size_flags(s)
    s.set_defaults(run=_stores)
    s = sub.add_parser("wizard", help="ask each input, show the plan's headline, write plan, values, stores and the load profile")
    _size_flags(s, chart_required=False)
    s.add_argument("--out", default="langsmith-sizing-out", metavar="DIR", help="where the files go (default: ./langsmith-sizing-out)")
    s.add_argument("--yes", action="store_true", help="ask nothing: every input comes from a flag, the preset or its default")
    s.set_defaults(run=_wizard)
    s = sub.add_parser("load-profile", help="print the load a plan is sized for, as the load test reads it")
    _size_flags(s)
    s.set_defaults(run=_load_profile)
    s = sub.add_parser("compare", help="set a load test's results against the plan; exit 1 on a failed verdict")
    s.add_argument("--plan", required=True, metavar="plan.json", help="the output of size")
    s.add_argument("--results", required=True, metavar="results.json", help="the load test's --results file")
    s.set_defaults(run=_compare)
    s = sub.add_parser("profile-report", help="set each preset's plan beside the modules' hand-written sizing profiles (read-only)")
    s.add_argument("--chart", required=True, metavar="X.Y.Z")
    s.add_argument("--root", metavar="DIR", help="the Terraform repository root (default: the one holding this package)")
    s.set_defaults(run=_profile_report)
    a = p.parse_args(argv)
    try:
        return int(a.run(a))
    except (params.ParamError, chart.ChartError, presets.PresetError, ValueError, KeyError) as err:
        print(f"error: {err}", file=sys.stderr)
        return 1
    except (EOFError, KeyboardInterrupt):
        # a closed stdin or Ctrl-C in the wizard printed a traceback; nothing was written yet
        print("error: input ended before the wizard finished; nothing was written", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
