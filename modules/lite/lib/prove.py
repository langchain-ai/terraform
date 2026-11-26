# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

"""make verify and make soak: the load test's own verify, soak and step, with what only Lite knows.

    python3 prove.py verify|soak --endpoint URL --namespace NS --data-namespace NS --loadtest DIR --out DIR
                     [--runs-per-second R --duration S --ramp S] [--step]

What hops a trace crosses, whether a load held and what saturated are decided in
utils/langsmith-load-test (load-test-verify, load-test-judge, load-test-step), the same for every
install. Lite adds the API key: it logs in as the first admin (LITE_ADMIN_EMAIL, LITE_ADMIN_PASSWORD,
which Terraform generated), makes a key for the run and revokes it after, pass or fail; and the rate:
the plan sizes in runs/s, the load test sends traces/s.

kubectl reaches the install through KUBECONFIG, which bin/lite sets. Standard library only.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional


class LangSmith:
    """The first admin's login, and an API key for one run. The calls are the bare-metal bootstrap's
    (lsb/client.py), which found that /tenants names the workspace from the login token alone, 2026-10-21."""

    def __init__(self, endpoint: str) -> None:
        self.api = endpoint.rstrip("/") + "/api/v1"
        self.headers: Dict[str, str] = {}
        self.key_id: Optional[str] = None

    def call(self, method: str, path: str, body: Optional[dict] = None, headers: Optional[Dict[str, str]] = None) -> Any:
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.api + path, data=data, method=method, headers={"Content-Type": "application/json", **self.headers, **(headers or {})})
        with urllib.request.urlopen(req, timeout=30) as r:
            text = r.read()
        return json.loads(text) if text else None

    def key(self, email: str, password: str, description: str) -> str:
        basic = base64.b64encode(f"{email}:{password}".encode()).decode()
        token = self.call("POST", "/login", headers={"Authorization": f"Basic {basic}"})["access_token"]
        self.headers = {"Authorization": f"Bearer {token}"}
        self.headers["X-Tenant-Id"] = self.call("GET", "/tenants")[0]["id"]
        body = self.call("POST", "/api-key", {"description": description})
        self.key_id = str(body["id"])
        return str(body["key"])

    def revoke(self) -> None:
        if self.key_id:
            try:
                self.call("DELETE", f"/api-key/{self.key_id}")
            except (urllib.error.URLError, OSError):
                print(f"  warning  the run's API key {self.key_id} was not revoked: delete it in Settings, API Keys", file=sys.stderr)
            self.key_id = None


def load_test(a: argparse.Namespace, env: Dict[str, str], command: str, *args: str) -> int:
    """One of the load test's commands, run in the run's own folder: the load test reads a .env from
    where it runs, and one there would aim it at another install."""
    cmd = ["uv", "run", "--quiet", "--project", a.loadtest, command, *args]
    return subprocess.run(cmd, cwd=a.out, env=env, check=False).returncode


# A reader is a person in the UI: three reads (the trace list, a filtered query, opening a trace) every
# 5 s, as in the lab bench that measured the frontend's and backend's cores per reader (sizing params,
# lite.measured). Without a rate the soak's --read refused to start (magus, 2026-11-25).
READS_PER_READER = 3 / 5


def runs_per_trace(a: argparse.Namespace) -> float:
    """The mean runs a trace holds in the traces sent, to turn a rate in runs a second into traces a second:
    the profile's for simple traces, the agent model's own for agent traces, which vary in length."""
    code = ("from loadtest.payloads.agent import AgentModel, runs_per_trace; print(runs_per_trace(AgentModel.from_params()))"
            if a.traces == "agent" else "from loadtest.profile import from_params; print(from_params().runs_per_trace)")
    return float(subprocess.run(["uv", "run", "--quiet", "--project", a.loadtest, "python", "-c", code],
                                capture_output=True, text=True, check=True).stdout)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("mode", choices=("verify", "soak"))
    for flag in ("--endpoint", "--namespace", "--data-namespace", "--loadtest", "--out"):
        p.add_argument(flag, required=True)
    p.add_argument("--runs-per-second", type=float, default=0)
    p.add_argument("--readers", type=int, default=1)
    p.add_argument("--duration", type=int, default=900)
    p.add_argument("--ramp", type=int, default=120)
    p.add_argument("--step", action="store_true")
    p.add_argument("--traces", choices=("simple", "agent"), default="simple", help="the load test's --traces: simple, or an agent's realistic ones")
    p.add_argument("--prometheus", help="NS/SERVICE:PORT of the install's Prometheus, for CPU")
    # Anything else is the load test's own (TRACES: --content, --fields-per-side, ...), passed through as
    # given, so a flag it adds needs nothing here.
    a, passed = p.parse_known_args()
    Path(a.out).mkdir(parents=True, exist_ok=True)

    ls = LangSmith(a.endpoint)
    try:
        key = ls.key(os.environ["LITE_ADMIN_EMAIL"], os.environ["LITE_ADMIN_PASSWORD"], f"langsmith-lite {a.mode}, {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}")
    except (urllib.error.URLError, OSError, KeyError, IndexError) as e:
        print(f"\n  ERROR  could not log in as the first admin and make a key: {e}\n         make access prints the login\n", file=sys.stderr)
        return 1
    env = {**os.environ, "LANGSMITH_TRACING": "true", "LANGSMITH_ENDPOINT": a.endpoint.rstrip("/") + "/api/v1", "LANGSMITH_API_KEY": key,
           "LANGSMITH_PROJECT": f"lite-{a.mode}"}
    env.pop("LANGSMITH_WORKSPACE_ID", None)
    where = ["--namespace", a.namespace, "--data-namespace", a.data_namespace, "--traces", a.traces, *(["--prometheus", a.prometheus] if a.prometheus else [])]
    try:
        if a.mode == "verify":
            return load_test(a, env, "load-test-verify", *where, *passed, "--results", "verify.json")
        load: List[str] = [*where, "--traces-per-second", f"{a.runs_per_second / runs_per_trace(a):.4f}", "--read",
                           "--reads-per-second", f"{a.readers * READS_PER_READER:.2f}", "--duration-seconds", str(a.duration), "--ramp-up-seconds", str(a.ramp), *passed]
        if a.step:
            return load_test(a, env, "load-test-step", *load, "--results", "step.json")
        code = load_test(a, env, "load-test", *load, "--results", "soak.json")
        # A run that did not hold still writes its results, and the judge says why; one that never
        # started has none to judge, and its own error is the reason.
        return load_test(a, env, "load-test-judge", "soak.json") if Path(a.out, "soak.json").exists() else code
    finally:
        ls.revoke()


if __name__ == "__main__":
    sys.exit(main())
