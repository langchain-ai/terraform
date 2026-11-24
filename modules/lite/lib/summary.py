# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

"""What a plan does, in the form every Lite command prints: read from `terraform show -json` on stdin.

    the box, the load it is sized for, its requests against what it allows, its disk, the versions,
    where LangSmith answers, and the count of changes

Standard library only. Colour as lib/ui.sh decides it: on a terminal, never with NO_COLOR.
"""

import json
import os
import sys

COLOUR = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
DIM, GREEN, YELLOW, RED, OFF = ("\033[2m", "\033[32m", "\033[33m", "\033[31m", "\033[0m") if COLOUR else ("",) * 5


def field(name: str, value: str) -> None:
    print(f"  {DIM}{name:<18}{OFF} {value}")


def share(used: float, allowed: float, unit: str) -> str:
    pct = round(100 * used / allowed) if allowed else 0
    colour = GREEN if pct <= 85 else YELLOW if pct <= 100 else RED
    return f"{used:.1f} of {allowed:.1f} {unit} {colour}({pct}%){OFF}"


def main() -> int:
    plan = json.load(sys.stdin)
    outputs = plan.get("planned_values", {}).get("outputs", {})
    sizing = outputs.get("plan", {}).get("value")
    if sizing is None:
        print(f"  {RED}the plan has no sizing output{OFF}")
        return 1
    m = sizing["machine"]
    host = outputs.get("ssh", {}).get("value", {}).get("host") or "(the instance, once made)"
    url = outputs.get("url", {}).get("value", "")
    req, allowed = sizing["requested"], sizing["allowed"]
    versions = sizing["versions"]

    print()
    field("box", f"{sizing['box']}: {m['cpu']} vCPU, {m['memory_gi']} GiB, {m['disk_gi']} GiB disk, on {host}")
    field("sized for", f"{sizing['runs_per_second']} runs/s, {sizing['readers']} readers")
    field("cpu", share(req["cpu_m"] / 1000, allowed["cpu_m"] / 1000, "vCPU requested"))
    field("memory", share(req["mem_mi"] / 1024, allowed["mem_mi"] / 1024, "GiB requested"))
    disk = sum(sizing["volumes_gi"].values())
    field("volumes", f"{disk} GiB, {sizing['used_pct']['disk']}% of the disk with images")
    data = sizing["data"]
    kb = data["per_run_kb"]
    field("data", f"{data['runs_per_day']:,} runs a day at the average rate, {kb['smithdb'] + kb['blob']:.1f} KB a run stored")
    field("object store", f"{data['object_store_gi']} GiB to keep them for the TTLs below")
    field("redis", f"{data['redis_limit_mi'] / 1024:.1f} GiB limit: {data['redis_stall_hours']} h of stalled ingest at the peak")
    field("retention", "{short} days, extended {long}; metrics {metrics}".format(**sizing["retention_days"]))
    off = [name.replace("_", " ") for name, on in sizing["features"].items() if not on]
    if off:
        field("not running", ", ".join(off) + f"  {DIM}(tracing only){OFF}")
    field("versions", f"langsmith {versions['langsmith']}, k3s {versions['k3s']}, mission-control {versions['mission-control']}")
    field("langsmith at", url + (f"  {DIM}(while make access runs){OFF}" if url.startswith("http://localhost") else ""))

    counts = {"create": 0, "update": 0, "delete": 0}
    for change in plan.get("resource_changes", []):
        for action in change["change"]["actions"]:
            if action in counts:
                counts[action] += 1
    field("changes", f"{counts['create']} to add, {counts['update']} to change, {counts['delete']} to destroy")
    return 0


if __name__ == "__main__":
    sys.exit(main())
