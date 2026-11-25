# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

"""What a plan does, in the form every Lite command prints: read from `terraform show -json` on stdin.

Standard library only. Colour as lib/ui.sh decides it: on a terminal, never with NO_COLOR.
"""

import json
import os
import sys

COLOUR = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
DIM, GREEN, YELLOW, RED, BOLD, OFF = ("\033[2m", "\033[32m", "\033[33m", "\033[31m", "\033[1m", "\033[0m") if COLOUR else ("",) * 6


def field(name: str, value: str) -> None:
    print(f"  {DIM}{name:<18}{OFF} {value}")


def share(used: float, allowed: float, unit: str) -> str:
    pct = round(100 * used / allowed) if allowed else 0
    colour = GREEN if pct <= 85 else YELLOW if pct <= 100 else RED
    return f"{used:.1f} of {allowed:.1f} {unit} {colour}({pct}%){OFF}"


def machine(p: dict, outputs: dict, cloud: str) -> None:
    """Where it runs, the load it is sized for, and its requests against what the machine allows."""
    m, req, allowed = p["machine"], p["requested"], p["allowed"]
    if cloud == "cluster":
        field("install", f"{p['box']} sizes on a cluster of one's own: its scheduler places the pods")
    else:
        host = outputs.get("ssh", {}).get("value", {}).get("host") or "(the instance, once made)"
        field("box", f"{p['box']}: {m['cpu']} vCPU, {m['memory_gi']} GiB, on {host}")
    field("sized for", f"{p['runs_per_second']} runs/s at peak, {p['readers']} readers; {p['data']['runs_a_day']:,} runs a day")
    if cloud == "cluster":
        field("requests", f"{req['cpu_m'] / 1000:.1f} vCPU, {req['mem_mi'] / 1024:.1f} GiB")
        return
    field("cpu", share(req["cpu_m"] / 1000, allowed["cpu_m"] / 1000, "vCPU requested"))
    field("memory", share(req["mem_mi"] / 1024, allowed["mem_mi"] / 1024, "GiB requested"))


def stores(p: dict, cloud: str) -> None:
    """The volumes, the disk they fill, and the bounds on Redis and Postgres."""
    disks, data, vols = p["disks"], p["data"], p["volumes_gi"]
    prometheus = f", Prometheus {vols['prometheus']}" if vols["prometheus"] else ""
    field("volumes", f"{disks['volumes_gi']} GiB: object store {vols['object_store']}, SmithDB cache {vols['smithdb_cache']}, "
          f"Postgres {vols['postgres']}, Redis {vols['redis']}{prometheus}")
    if cloud != "cluster":
        where = f"a data disk of {disks['data_gi']} GiB at {disks['data_mount']}" if disks["data_separate"] else f"the system's {p['machine']['disk_gi']} GiB disk"
        snap = f"; daily snapshots kept {disks['snapshot_days']} days" if disks["snapshot_days"] else ""
        field("disk", f"on {where}, {disks['used_pct']}% used{snap}")
    field("redis", f"{data['redis_maxmemory_mi'] / 1024:.1f} GiB maxmemory, reserved: {data['redis_stall_hours']} h of stalled ingest at the peak")
    field("postgres", f"max_connections {data['postgres_max_connections']}")


def retention(ret: dict) -> None:
    """The TTLs, loudly when they are still the defaults: they size the disk more than anything else."""
    text = f"{ret['short_days']} days, {ret['long_days']} for the {ret['extended_pct']}% on extended retention; metrics {ret['metrics_days']}"
    if ret["set_by_person"]:
        field("retention", text)
        return
    field("retention", f"{BOLD}{YELLOW}{text}: the defaults{OFF}")
    field("", f"{YELLOW}set short_ttl_days and long_ttl_days in infra/terraform.tfvars to what you must keep: they size the disk{OFF}")


def the_rest(p: dict, outputs: dict, cloud: str) -> None:
    """The cost on AWS, what is not running, the versions, and where LangSmith answers."""
    cost = p.get("cost_usd_a_month")
    if cost:
        field("cost", f"about ${cost['total']:,} a month: {cost['instance_type']} ${cost['instance']:.0f}, disks ${cost['disks']:.0f}, "
              f"snapshots ${cost['snapshots']:.0f}, address ${cost['address']:.0f}  {DIM}(us-east-1 on-demand list prices){OFF}")
    off = [name.replace("_", " ") for name, on in p["features"].items() if not on and name not in ("tunnel", "k3s")]
    if off:
        field("not running", ", ".join(off))
    v = p["versions"]
    mission_control = f", mission-control {v['mission-control']}" if "mission-control" in p["releases"] else ""
    field("versions", f"langsmith {v['langsmith']}, k3s {v['k3s']}{mission_control}")
    url = outputs.get("url", {}).get("value", "")
    if cloud != "cluster":
        field("langsmith at", url + (f"  {DIM}(while make access runs){OFF}" if url.startswith("http://localhost") else ""))


def changes(plan: dict) -> dict:
    """What the plan adds, changes and destroys, and how many outputs change. The outputs count: the
    Helm values and the bundle are outputs, and a plan that changed only them read as nothing to apply,
    so make up sent the bundle of the last apply (magus, 2026-11-24)."""
    counts = {"create": 0, "update": 0, "delete": 0}
    for change in plan.get("resource_changes", []):
        for action in change["change"]["actions"]:
            if action in counts:
                counts[action] += 1
    counts["outputs"] = sum(o["actions"] != ["no-op"] for o in plan.get("output_changes", {}).values())
    return counts


def main() -> int:
    plan = json.load(sys.stdin)
    outputs = plan.get("planned_values", {}).get("outputs", {})
    p = outputs.get("plan", {}).get("value")
    if p is None:
        print(f"  {RED}the plan has no sizing output{OFF}")
        return 1
    cloud = outputs.get("instance", {}).get("value", {}).get("cloud", "")
    print()
    machine(p, outputs, cloud)
    stores(p, cloud)
    retention(p["retention"])
    the_rest(p, outputs, cloud)
    counts = changes(plan)
    outputs = f"; {counts['outputs']} outputs change (the install's values)" if counts["outputs"] else ""
    field("changes", f"{counts['create']} to add, {counts['update']} to change, {counts['delete']} to destroy{outputs}")
    return 0


def count() -> int:
    """make up's question: the number of changes to apply, outputs included."""
    print(sum(changes(json.load(sys.stdin)).values()))
    return 0


if __name__ == "__main__":
    sys.exit(count() if sys.argv[1:] == ["--count"] else main())
