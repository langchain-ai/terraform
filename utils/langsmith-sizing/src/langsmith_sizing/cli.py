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
    summary,
    ui,
    values,
    wizard,
)
from langsmith_sizing.model import products


def _check_citations(a: argparse.Namespace) -> int:
    problems = citations.check(citations.load(), a.ref)
    for p in problems:
        print(p)
    print("citations: ok" if not problems else f"citations: {len(problems)} no longer hold")
    return 1 if problems else 0


def _check_params(a: argparse.Namespace) -> int:
    loaded = params.load()
    versions = [chart.resolve(a.chart)] if a.chart else list(PLANNED_CHARTS)
    problems = [f"{v}: {p}" for v in versions for p in params.shadowed(loaded, chart.Chart(v))]
    for p in problems:
        print(p)
    print(f"params: {len(loaded)} ok at {', '.join(versions)}" if not problems else f"params: {len(problems)} shadow the chart")
    return 1 if problems else 0


def _chart_info(a: argparse.Namespace) -> int:
    c = chart.Chart(chart.resolve(a.chart))
    keys = a.key or ["smithdb.resourceTier", "config.settings.redisRunsExpirySeconds"]
    print(json.dumps({k: c.at(k) for k in keys}, indent=2))
    return 0


def _flags(a: argparse.Namespace) -> dict[str, Any]:
    return {
        "users": a.users, "traces_per_second": a.traces_per_second, "traces_per_month": a.traces_per_month,
        "peak_traces_per_second": a.peak_traces_per_second, "runs_per_trace": a.runs_per_trace, "retention_days": a.retention_days,
        "postgres": a.postgres, "redis": a.redis, "smithdb_metastore": a.smithdb_metastore, "object_store": a.object_store, "clickhouse": a.clickhouse,
        "datastores_on": a.datastores_on, "app_node": a.app_node, "smithdb_node": a.smithdb_node, "datastore_node": a.datastore_node,
        "trace_store": a.trace_store, "survives_node_loss": a.survives_node_loss, "requests_from_measured": a.requests_from_measured,
        "backfill_runs": a.backfill_runs, "backfill_days": a.backfill_days, "attachment_kib_per_run": a.attachment_kib_per_run,
        "smithdb_tier": a.smithdb_tier, "smithdb_topology": a.smithdb_topology,
        "products": a.products, "agent_deployments": a.agent_deployments, "agent_load": a.agent_load, "gateway_streams": a.gateway_streams,
        "sandboxes": a.sandboxes, "sandbox_vcpu": a.sandbox_vcpu, "sandbox_memory_gib": a.sandbox_memory_gib, "sandbox_node": a.sandbox_node,
    }


def _chart(a: argparse.Namespace) -> str:
    """The chart a command sizes on: the flag, else the one a saved sizing was made on, else the newest release."""
    if a.chart:
        return chart.resolve(a.chart)
    if a.preset and presets.is_file(a.preset):
        saved = presets.load(a.preset).chart
        if saved:
            return saved
    return chart.resolve(None)


def _inputs(a: argparse.Namespace) -> inputs.Inputs:
    """The inputs a command's flags and preset give: the preset first, each flag given replacing its value."""
    flags = {k: v for k, v in _flags(a).items() if v is not None}
    a.chart = _chart(a)
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


def _given(a: argparse.Namespace) -> dict[str, Any]:
    return {k: v for k, v in _flags(a).items() if v is not None}


def _wizard(a: argparse.Namespace) -> int:
    return wizard.run(chart_version=a.chart, preset_name=a.preset, given=_given(a), yes=a.yes, out=Path(a.out), ask=input)


def _plan(a: argparse.Namespace) -> int:
    """The wizard asking nothing: size from the flags, the preset or the folder's saved inputs, and save the folder."""
    return wizard.run(chart_version=a.chart, preset_name=a.preset, given=_given(a), yes=True, out=Path(a.out), ask=input)


def _show(a: argparse.Namespace) -> int:
    out = Path(a.out)
    if not (out / "plan.json").is_file():
        raise ValueError(f"no sizing at {out}/: make list shows the saved ones, make wizard NAME={out.name} makes one")
    body = _read(str(out / "plan.json"))
    ui.show(summary.sections(body), f"{out.name} on chart {body['chart']}")
    ui.files([(str(out / f), what) for f, what in wizard.FILES if (out / f).exists()], "In the folder")
    wizard.next_steps(out, body)
    return 0


def _list(a: argparse.Namespace) -> int:
    root = Path(a.root)
    rows = []
    for plan_file in sorted(root.glob("*/plan.json")):
        body = _read(str(plan_file))
        r = body["rates"]
        sized = body["totals"]["sized"]["requests"]
        rows.append((plan_file.parent.name, str(body["chart"]), body["regime"]["id"], f"{r['peak_traces_per_second']:g}", f"{summary.n(sized['cpu'])} vCPU, {summary.n(sized['memory_gib'])} GiB", "yes" if (plan_file.parent / "results.json").exists() else ""))
    if not rows:
        ui.note(f"No sizings under {root}/ yet. Start one: make wizard NAME=<customer>")
        return 0
    ui.table(summary.Table(f"Sizings in {root}/", ("name", "chart", "regime", "peak traces/s", "sized requests", "load tested"), rows, "make show NAME=<name> for one."))
    return 0


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


def _presets(a: argparse.Namespace) -> int:
    rows = []
    for name in presets.names():
        p = presets.load(name)
        rows.append((name, f"{p.inputs['users']:g}", f"{p.inputs['peak_traces_per_second']:g}", p.why))
    ui.table(summary.Table("Presets", ("preset", "users", "peak traces/s", "for"), rows, "Every preset is unmeasured until a load test reads it: presets/README.md says what each leaves open."))
    return 0


def _compare(a: argparse.Namespace) -> int:
    verdicts = compare.compare(_read(a.plan), _read(a.results))
    ui.heading("The load test against the plan")
    ui.verdicts(verdicts)
    ui.note(compare.render(verdicts).splitlines()[-1])
    if a.save:
        Path(a.save).write_text(json.dumps(verdicts, indent=2) + "\n")
        ui.note(f"saved {a.save}")
    return 1 if compare.failed(verdicts) else 0


def _profile_report(a: argparse.Namespace) -> int:
    root = Path(a.root) if a.root else profile_report.REPO
    a.chart = chart.resolve(a.chart)
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


def _products(text: str) -> tuple[str, ...]:
    """A comma list of products besides tracing, or `all`; tracing always runs."""
    names = list(products.catalog())
    picked = names if text.strip() == "all" else [n.strip().replace("-", "_") for n in text.split(",") if n.strip()]
    unknown = [n for n in picked if n not in names]
    if unknown:
        raise argparse.ArgumentTypeError(f"no product {', '.join(unknown)}; the products are {', '.join(names)}")
    return tuple(dict.fromkeys(["traces", *picked]))


def _size_flags(s: argparse.ArgumentParser) -> None:
    s.add_argument("--chart", metavar="VERSION", help="an exact version (0.17.60), a line (0.18: its newest) or latest (the default; a saved sizing keeps its own)")
    s.add_argument("--preset", metavar="NAME|FILE", help=f"start from a named load ({', '.join(presets.names())}) or a saved sizing's inputs.yaml; a flag below replaces its value")
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
    s.add_argument("--requests-from-measured", action=argparse.BooleanOptionalAction, help="pods ask what they were measured to use; default the regime's (on in extra-lite)")
    s.add_argument("--smithdb-tier", choices=("small", "medium", "large"), help="SmithDB's tier; default the load's (the regime's for a low one)")
    s.add_argument("--smithdb-topology", choices=("cluster", "unified"), help="SmithDB's layout; unified needs a chart with smithdb.topology")
    s.add_argument("--products", type=_products, metavar="LIST", help="what runs besides tracing, comma separated or all: agent_server, fleet, insights, polly, engine, gateway, sandboxes (Engine brings Sandboxes)")
    s.add_argument("--agent-deployments", type=int, help="Agent Server: how many deployments (default 1)")
    s.add_argument("--agent-load", choices=products.LOADS, help="Agent Server: each deployment's read then write load, l(ow) m(edium) h(igh), as the docs' table (default ll)")
    s.add_argument("--gateway-streams", type=float, help="LLM gateway: concurrent streams at the busiest time")
    s.add_argument("--sandboxes", type=float, help="Sandboxes: how many run at once at the busiest time")
    s.add_argument("--sandbox-vcpu", type=float, help="Sandboxes: vCPU each (default 1)")
    s.add_argument("--sandbox-memory-gib", type=float, help="Sandboxes: GiB each (default the docs' 2)")
    s.add_argument("--sandbox-node", type=_shape, metavar="CPUxGIB", help="Sandboxes: the KVM node, one host a node")
    s.add_argument("--backfill-runs", type=float, help="ClickHouse history to copy into SmithDB, in runs (with --backfill-days)")
    s.add_argument("--backfill-days", type=float, help="the days the backfill should take")
    s.add_argument("--attachment-kib-per-run", type=float, help="attachment KiB a run carries on average (images, audio, files); they go to the LangSmith bucket")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="langsmith-sizing", description=__doc__)
    sub = p.add_subparsers(dest="command", required=True)
    s = sub.add_parser("check-citations", help="fail when a cited docs quote is gone (network)")
    s.add_argument("--ref", help="a docs commit or branch to check against (default: the pinned commit)")
    s.set_defaults(run=_check_citations)
    s = sub.add_parser("check-params", help="load params.yaml and refuse an entry without its evidence")
    s.add_argument("--chart", metavar="VERSION", help="fail a parameter that gives a chart setting the value the chart already has; default every planned chart in charts.yaml")
    s.set_defaults(run=_check_params)
    s = sub.add_parser("chart-info", help="print chart values at a version (pulls the chart once)")
    s.add_argument("--chart", metavar="VERSION", help="exact, a line, or latest (default)")
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
    s = sub.add_parser("wizard", help="ask each input, show the plan, save the sizing folder (inputs, plan, values, stores, load profile, summary)")
    _size_flags(s)
    s.add_argument("--out", required=True, metavar="DIR", help="the sizing folder; its name is the sizing's (a saved inputs.yaml there is the starting point)")
    s.add_argument("--yes", action="store_true", help="ask nothing: every input comes from a flag, the preset, the saved inputs or its default")
    s.set_defaults(run=_wizard)
    s = sub.add_parser("plan", help="the wizard asking nothing: size and save the folder")
    _size_flags(s)
    s.add_argument("--out", required=True, metavar="DIR", help="the sizing folder")
    s.set_defaults(run=_plan)
    s = sub.add_parser("show", help="draw a saved sizing's plan again")
    s.add_argument("--out", required=True, metavar="DIR", help="the sizing folder")
    s.set_defaults(run=_show)
    s = sub.add_parser("presets", help="the named loads a sizing can start from")
    s.set_defaults(run=_presets)
    s = sub.add_parser("list", help="every saved sizing under a folder")
    s.add_argument("--root", default="out", metavar="DIR")
    s.set_defaults(run=_list)
    s = sub.add_parser("load-profile", help="print the load a plan is sized for, as the load test reads it")
    _size_flags(s)
    s.set_defaults(run=_load_profile)
    s = sub.add_parser("compare", help="set a load test's results against the plan; exit 1 on a failed verdict")
    s.add_argument("--plan", required=True, metavar="plan.json", help="the output of size")
    s.add_argument("--results", required=True, metavar="results.json", help="the load test's --results file")
    s.add_argument("--save", metavar="verdicts.json", help="also write the verdicts here")
    s.set_defaults(run=_compare)
    s = sub.add_parser("profile-report", help="set each preset's plan beside the modules' hand-written sizing profiles (read-only)")
    s.add_argument("--chart", metavar="VERSION", help="exact, a line, or latest (default)")
    s.add_argument("--root", metavar="DIR", help="the Terraform repository root (default: the one holding this package)")
    s.set_defaults(run=_profile_report)
    a = p.parse_args(argv)
    try:
        return int(a.run(a))
    except (params.ParamError, chart.ChartError, presets.PresetError, ValueError, KeyError) as err:
        ui.error(str(err))
        return 1
    except (EOFError, KeyboardInterrupt):
        # a closed stdin or Ctrl-C in the wizard printed a traceback; nothing was written yet
        ui.error("input ended before the wizard finished; nothing was written")
        return 1


if __name__ == "__main__":
    sys.exit(main())
