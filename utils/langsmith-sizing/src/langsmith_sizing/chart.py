"""The LangSmith Helm chart at the version planned: every default sizing reads, never a copy of it.

Defaults come from the chart's values.yaml; what a setting turns into (SmithDB's tier sizes, which
live in a template helper, not in values) comes from rendering the chart with that setting. A
chart is pulled once per version into a cache, so planning works offline after the first pull.
Where an install already runs, a caller passes that release's values instead of a version.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from functools import cached_property
from pathlib import Path
from typing import Any

import yaml

from langsmith_sizing.units import GIB, KIB, KILO, MIB, SECONDS_PER_DAY, TIB

REPO = "https://langchain-ai.github.io/helm"
CACHE = Path(os.environ.get("LANGSMITH_SIZING_CACHE", Path.home() / ".cache" / "langsmith-sizing"))


class ChartError(RuntimeError):
    pass


# What the chart's validation refuses to render without. Placeholders only: none of them sizes
# anything. Insights and Polly are off because they ask for encryption keys and the model sizes
# the Traces product; their pods set no resources in the chart.
RENDERABLE: dict[str, Any] = {
    "config": {
        "apiKeySalt": "placeholder",
        "langsmithLicenseKey": "placeholder",
        "authType": "mixed",
        "basicAuth": {"enabled": True, "initialOrgAdminEmail": "a@example.com", "initialOrgAdminPassword": "placeholder-Passw0rd!", "jwtSecret": "placeholder"},
    },
    "insights": {"enabled": False},
    "polly": {"enabled": False},
}
SMITHDB_RENDERABLE: dict[str, Any] = {
    "enabled": True,
    "langsmith": {"ingestion": {"enabled": True}, "query": {"enabled": True}},
    "config": {
        "existingSecretName": "placeholder",
        "metastore": {"hostSecretKey": "h", "databaseSecretKey": "d", "usernameSecretKey": "u", "passwordSecretKey": "p"},
        "objectStore": {"type": "s3", "bucket": "placeholder"},
    },
}

_UNITS = {"Ki": KIB, "Mi": MIB, "Gi": GIB, "Ti": TIB}


def cpu(q: Any) -> float:
    """A Kubernetes CPU quantity ("500m", "28", 2) in cores."""
    s = str(q)
    return float(s[:-1]) / KILO if s.endswith("m") else float(s)


def gib(q: Any) -> float:
    """A Kubernetes memory or storage quantity ("2Gi", "2000Mi") in GiB."""
    s = str(q)
    for suffix, factor in _UNITS.items():
        if s.endswith(suffix):
            return float(s[: -len(suffix)]) * factor / GIB
    return float(s) / GIB


def merge(base: dict[str, Any], top: dict[str, Any]) -> dict[str, Any]:
    out = dict(base)
    for k, v in top.items():
        out[k] = merge(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else v
    return out


def _helm(*args: str) -> str:
    try:
        p = subprocess.run(["helm", *args], capture_output=True, text=True, timeout=300, check=False)
    except FileNotFoundError as err:
        raise ChartError("helm is not on PATH: sizing reads the chart through it") from err
    if p.returncode:
        raise ChartError(f"helm {args[0]} failed ({p.returncode}): {p.stderr.strip()[-500:]}")
    return p.stdout


INDEX = CACHE / "index.yaml"
LATEST = "latest"
_VERSION = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:-(?P<pre>.+))?$")
_LINE = re.compile(r"^\d+\.\d+$")


def _read_index() -> str:
    """The repository's index, fetched at most once a day; offline, the last one fetched."""
    fresh = INDEX.exists() and time.time() - INDEX.stat().st_mtime < SECONDS_PER_DAY
    if not fresh:
        try:
            with urllib.request.urlopen(f"{REPO}/index.yaml", timeout=30) as r:
                text: str = r.read().decode()
            INDEX.parent.mkdir(parents=True, exist_ok=True)
            INDEX.write_text(text)
            return text
        except (urllib.error.URLError, TimeoutError) as err:
            if not INDEX.exists():
                raise ChartError(f"cannot read the chart index at {REPO} ({err}) and none is cached: give an exact --chart") from err
    return INDEX.read_text()


def _order(version: str) -> tuple[int, int, int, int, int]:
    """Semantic order: a release after its candidates, candidates by their number."""
    m = _VERSION.match(version)
    if not m:
        return (-1, -1, -1, -1, -1)
    major, minor, patch, pre = m.groups()
    n = re.search(r"(\d+)$", pre or "")
    return (int(major), int(minor), int(patch), 0 if pre else 1, int(n.group(1)) if n else 0)


def _line(version: str) -> tuple[int, int]:
    """major.minor: the line a version is on (0.17.48 and 0.17.60 are both 0.17)."""
    major, minor, *_ = _order(version)
    return major, minor


def line_at_least(version: str, line: str) -> bool:
    """Whether version is on line (such as 0.18) or a later one."""
    return _line(version) >= _line(f"{line}.0")


def same_line(a: str, b: str) -> bool:
    """Whether two versions share major.minor (0.17.48 and 0.17.60 do; 0.18.0-rc.82 does not)."""
    return _line(a) == _line(b)


def is_release(version: str) -> bool:
    """A release, not a candidate: no pre-release part after the patch number."""
    m = _VERSION.match(version)
    return bool(m and m.group("pre") is None)


def published(index_text: str | None = None) -> list[str]:
    """Every langsmith chart version the repository publishes, newest first."""
    doc = yaml.safe_load(index_text if index_text is not None else _read_index())
    return sorted({str(e["version"]) for e in doc["entries"]["langsmith"]}, key=_order, reverse=True)


def resolve(spec: str | None, index_text: str | None = None) -> str:
    """The chart version a spec names. None or "latest": the newest release. A line such as "0.18":
    its newest release, else its newest candidate, so a line with only candidates still resolves.
    An exact version is itself, unchecked against the index, so a pinned plan never needs the network."""
    if spec and _VERSION.match(spec):
        return spec
    versions = published(index_text)
    if spec in (None, "", LATEST):
        releases = [v for v in versions if is_release(v)]
        if not releases:
            raise ChartError("the chart index has no release")
        return releases[0]
    if not _LINE.match(spec):
        raise ChartError(f"--chart {spec}: give an exact version (0.17.60), a line (0.18) or latest")
    line = [v for v in versions if v.startswith(spec + ".")]
    if not line:
        raise ChartError(f"no langsmith chart in line {spec}; the newest is {versions[0]}")
    releases = [v for v in line if is_release(v)]
    return (releases or line)[0]


def pull(version: str) -> Path:
    """The chart's directory at version, pulled into the cache on first use."""
    dest = CACHE / "charts" / version
    if not (dest / "langsmith" / "Chart.yaml").exists():
        dest.mkdir(parents=True, exist_ok=True)
        _helm("pull", "langsmith", "--repo", REPO, "--version", version, "--untar", "--untardir", str(dest))
    return dest / "langsmith"


@dataclass
class Chart:
    version: str
    _rendered: dict[str, list[dict[str, Any]]] = field(default_factory=dict, init=False, repr=False, compare=False)

    @cached_property
    def path(self) -> Path:
        return pull(self.version)

    @cached_property
    def app_version(self) -> str:
        """The LangSmith release the chart deploys (Chart.yaml appVersion): the images' version, not the chart's."""
        meta = yaml.safe_load((self.path / "Chart.yaml").read_text())
        return str(meta.get("appVersion", ""))

    @cached_property
    def values(self) -> dict[str, Any]:
        values: dict[str, Any] = yaml.safe_load((self.path / "values.yaml").read_text())
        return values

    def at(self, key: str, values: dict[str, Any] | None = None) -> Any:
        """A dotted key's value in the chart's values (or in values given), None when absent."""
        node: Any = self.values if values is None else values
        for part in key.split("."):
            if not isinstance(node, dict) or part not in node:
                return None
            node = node[part]
        return node

    def number(self, key: str, values: dict[str, Any] | None = None) -> float:
        """A dotted key's value as a number: the chart writes many of them as strings ("21600")."""
        v = self.at(key, values)
        if v is None:
            raise ChartError(f"chart {self.version} has no {key}")
        return float(v)

    def render(self, overrides: dict[str, Any]) -> list[dict[str, Any]]:
        """The manifests the chart makes with overrides on top of its defaults and RENDERABLE.
        One render per distinct overrides: a plan renders the same chart several times."""
        merged = merge(RENDERABLE, overrides)
        key = json.dumps(merged, sort_keys=True)
        if key not in self._rendered:
            with tempfile.NamedTemporaryFile("w", suffix=".yaml") as f:
                yaml.safe_dump(merged, f)
                f.flush()
                out = _helm("template", "langsmith", str(self.path), "--namespace", "langsmith", "-f", f.name)
            self._rendered[key] = [d for d in yaml.safe_load_all(out) if d]
        return self._rendered[key]

    def pods(self, overrides: dict[str, Any]) -> dict[str, dict[str, Any]]:
        """Each Deployment and StatefulSet the overrides render, keyed by its first container's name:
        replicas (None when an autoscaler owns them), the container's requests and limits as cores
        and GiB, the cache volume's GiB, the autoscaler that owns the replicas (kind, min, max) and its env."""
        docs = self.render(overrides)
        scalers = autoscalers(docs)
        out = {}
        for d in docs:
            if d.get("kind") not in ("Deployment", "StatefulSet"):
                continue
            pod = d["spec"]["template"]["spec"]
            c = pod["containers"][0]
            res = c.get("resources", {})
            vol = next((v for v in pod.get("volumes", []) if "ephemeral" in v or "emptyDir" in v), None)
            size = None
            if vol and "ephemeral" in vol:
                size = vol["ephemeral"]["volumeClaimTemplate"]["spec"]["resources"]["requests"]["storage"]
            elif vol:
                size = vol["emptyDir"].get("sizeLimit")
            out[c["name"]] = {
                "workload": d["metadata"]["name"],
                "replicas": d["spec"].get("replicas"),
                "requests": {"cpu": cpu(res["requests"]["cpu"]), "memory_gib": gib(res["requests"]["memory"])} if "requests" in res else None,
                "limits": {"cpu": cpu(res["limits"]["cpu"]), "memory_gib": gib(res["limits"]["memory"])} if "limits" in res else None,
                "cache_gib": gib(size) if size else None,
                "scaler": scalers.get(d["metadata"]["name"]),
                "env": {e["name"]: e.get("value") for e in c.get("env", [])},
            }
        return out


def autoscalers(docs: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """The HorizontalPodAutoscaler or KEDA ScaledObject of each workload, by workload name."""
    out: dict[str, dict[str, Any]] = {}
    for d in docs:
        spec = d.get("spec", {})
        if d.get("kind") == "HorizontalPodAutoscaler":
            out[spec["scaleTargetRef"]["name"]] = {"kind": "hpa", "min": spec.get("minReplicas"), "max": spec["maxReplicas"]}
        elif d.get("kind") == "ScaledObject":
            out[spec["scaleTargetRef"]["name"]] = {"kind": "keda", "min": spec.get("minReplicaCount"), "max": spec.get("maxReplicaCount")}
    return out


def _pod_request(spec: dict[str, Any], kind: str) -> dict[str, float]:
    """A pod's effective request or limit: the sum of its containers, or its largest init container
    when that is bigger, which is how the scheduler counts it."""
    def one(c: dict[str, Any]) -> dict[str, float]:
        r = c.get("resources", {}).get(kind) or c.get("resources", {}).get("requests") or {}
        return {"cpu": cpu(r.get("cpu", 0)), "memory_gib": gib(r.get("memory", 0))}

    run = [one(c) for c in spec.get("containers", [])]
    init = [one(c) for c in spec.get("initContainers", [])]
    return {k: max(sum(c[k] for c in run), *(c[k] for c in init), 0.0) for k in ("cpu", "memory_gib")}


def hook_jobs(docs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """The Jobs the chart runs as Helm hooks, with the pod each one asks for. Read from the render,
    never copied: the chart adds and resizes them between versions. A limit a Job leaves unset counts
    as its request."""
    out = []
    for d in docs:
        hook = ((d.get("metadata") or {}).get("annotations") or {}).get("helm.sh/hook")
        if d.get("kind") != "Job" or not hook:
            continue
        pod = d["spec"]["template"]["spec"]
        out.append({
            "name": d["metadata"]["name"], "hooks": [h.strip() for h in hook.split(",")],
            "weight": int(d["metadata"]["annotations"].get("helm.sh/hook-weight", 0)),
            "pods": int(d["spec"].get("parallelism") or 1),
            "requests": _pod_request(pod, "requests"), "limits": _pod_request(pod, "limits"),
        })
    return sorted(out, key=lambda j: (j["weight"], j["name"]))
