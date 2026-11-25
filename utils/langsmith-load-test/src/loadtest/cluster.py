"""Read the install while the load runs, so a run says what the server did, not only what a client saw.

Every reading goes through the Kubernetes API with kubectl, the access a person running a load test
against their own install already has; nothing needs a Prometheus. Each sample reads:

- the queue depths the chart's KEDA autoscalers read: platform-backend `/metrics?format=json`, backend
  `/metrics/queue/default`, SmithDB compaction `/metrics/jobs`;
- every SmithDB pod's `/metrics` (Prometheus text), the families the sizing plan watches
  (params watch.metrics_smithdb);
- Redis INFO, by exec in the Redis pod when Redis runs in the cluster;
- each autoscaler's current and maximum replicas, and each pod's restarts and OOM kills;
- each container's CPU seconds and CFS throttling from its node's cAdvisor.

What is watched and what it is called comes from the sizing package's params (watch.items), so the plan
and the test read one list. A read that fails is left out of its sample and named in `unread`; a
missing reading is unknown, never zero (the bootstrap's bench once read an unreadable cAdvisor as idle).
"""

from __future__ import annotations

import json
import re
import subprocess
import threading
import time
from collections.abc import Callable, Iterable, Sequence
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any
from urllib.parse import urlencode

from langsmith_sizing import params as sizing_params

Kube = Callable[[Sequence[str]], str | None]
Sample = dict[str, Any]

COMPONENT = "app.kubernetes.io/component"
# The datastores chart (modules/baremetal/charts/datastores, which LangSmith Lite also runs) labels its
# pods by name, not component, and can run them in a namespace of their own: read by component alone,
# its Redis and Postgres were never found, and the results said "not measured" as if they were managed.
NAME = "app.kubernetes.io/name"
STORES = ("redis", "postgres")
QUEUES = ("ingestion_queue", "feedback_queue", "adhoc_queue")
REDIS_FIELDS = ("used_memory", "maxmemory", "evicted_keys", "connected_clients")
QUEUE_LATENCY = "langsmith_asynq_queue_latency_seconds"
EXPIRED_LINE = "Skipping run as it has expired"
POSTGRES_QUERY = "select count(*), current_setting('max_connections') from pg_stat_activity"
# The image's own user and database: the chart's Postgres runs as postgres, the datastores chart's as the
# user it was given, and psql -U postgres failed there.
POSTGRES_COMMAND = 'psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -tAc "' + POSTGRES_QUERY + '"'
# Labels a reading keeps apart: a pending compaction job is not an in-flight one, and an l1 segment
# waits up to 13 minutes for its flush by design where an l0 one waiting says ingestion is behind
# (Ben Nagengast's load test watched l0 only).
KEPT_LABELS = ("status", "level", "job_kind", "kind")
# Workloads whose CPU a run's rate passes through, each counted per run: the coefficient sizing
# argues about (ingest-queue runs/s per core) is read here instead of inferred from requests.
INGEST_PATH = ("platform-backend", "ingest-queue", "smithdb-ingestion", "smithdb-compaction-worker", "smithdb")
OLDEST = "compaction_queue_oldest_pending_created_at_seconds"
BY_KIND = "compaction_jobs_executed"
SERIES = re.compile(r'^([A-Za-z_:][A-Za-z0-9_:]*)(?:\{(.*)\})?\s+(\S+)')
LABEL = re.compile(r'(\w+)="((?:[^"\\]|\\.)*)"')
CPU, THROTTLED, PERIODS = "container_cpu_usage_seconds_total", "container_cpu_cfs_throttled_periods_total", "container_cpu_cfs_periods_total"
MEMORY = "container_memory_working_set_bytes"
# Every DISK_EVERY samples, the bytes each store's volume holds: du over a large volume is not free, and
# disk grows slowly enough that once a minute at the default interval resolves it.
DISK_EVERY = 4


def kubectl(context: str | None, timeout_seconds: float) -> Kube:
    def run(args: Sequence[str]) -> str | None:
        command = ["kubectl", *(["--context", context] if context else []), *args]
        try:
            done = subprocess.run(command, capture_output=True, text=True, timeout=timeout_seconds, check=False)
        except (OSError, subprocess.TimeoutExpired):
            return None
        return done.stdout if done.returncode == 0 else None
    return run


def parse_prometheus(text: str, families: Iterable[str]) -> list[tuple[str, dict[str, str], float]]:
    """(name, labels, value) for each series of the named families, their _sum, _count and _total included."""
    wanted = set(families)
    out = []
    for line in text.splitlines():
        m = SERIES.match(line)
        if not m:
            continue
        name = m.group(1)
        if name not in wanted and re.sub(r"_(sum|count|total)$", "", name) not in wanted:
            continue
        try:
            value = float(m.group(3))
        except ValueError:
            continue
        out.append((name, dict(LABEL.findall(m.group(2) or "")), value))
    return out


def _smithdb_key(name: str, labels: dict[str, str]) -> str:
    kept = [f"{k}={labels[k]}" for k in KEPT_LABELS if k in labels]
    return f"{name}{{{','.join(kept)}}}" if kept else name


def family_sum(values: dict[str, float], family: str, **match: str) -> float | None:
    """The sum of a family's series whose kept labels include every match; None when none was read."""
    found = None
    for key, value in values.items():
        name, _, labels = key.partition("{")
        if name.removesuffix("_total") != family.removesuffix("_total"):
            continue
        # Values compare without case: SmithDB 0.17 labelled a level l0 and 0.18 labels it L0, and an exact
        # match read the pending-segments item as not measured on every 0.18 run (magus, 2026-11-25).
        kept = labels.rstrip("}").lower().split(",")
        if all(f"{k}={v}".lower() in kept for k, v in match.items()):
            found = (found or 0.0) + value
    return found


def merge_smithdb(per_pod: Iterable[list[tuple[str, dict[str, str], float]]]) -> dict[str, float]:
    """One value a series across pods: the oldest pending job is the earliest, every other one the sum."""
    out: dict[str, float] = {}
    for series in per_pod:
        for name, labels, value in series:
            key = _smithdb_key(name, labels)
            out[key] = min(out.get(key, value), value) if name == OLDEST else out.get(key, 0.0) + value
    return out


def parse_redis_info(text: str) -> dict[str, float]:
    out = {}
    for line in text.splitlines():
        key, _, value = line.strip().partition(":")
        if key in REDIS_FIELDS:
            out[key] = float(value)
    return out


CONTAINER_FIELD = {CPU: "seconds", THROTTLED: "throttled", PERIODS: "periods", MEMORY: "memory"}


def _claim_mounts(spec: dict[str, Any]) -> list[tuple[str, str]]:
    """(container, mount path) for each persistent volume claim the pod mounts."""
    claims = {v["name"] for v in spec.get("volumes", []) if "persistentVolumeClaim" in v}
    return [(c["name"], m["mountPath"]) for c in spec.get("containers", []) for m in c.get("volumeMounts", []) if m["name"] in claims]


def prometheus_federate(where: str, namespace: str) -> str:
    """The API path to a Prometheus's /federate for one namespace's cAdvisor CPU series. It serves the
    counters cAdvisor does, in the same text, through services/proxy: a kubeconfig without nodes/proxy
    (Lite's operator, by design) read no CPU at all, and every soak's cores table was empty (magus,
    2026-11-25)."""
    ns, _, service = where.partition("/")
    names = "|".join(CONTAINER_FIELD)
    query = urlencode({"match[]": f'{{namespace="{namespace}",__name__=~"{names}"}}'})
    return f"/api/v1/namespaces/{ns}/services/{service}/proxy/federate?{query}"


def _add_container(out: dict[str, dict[str, Any]], text: str, marker: str, owners: dict[str, str]) -> None:
    """Each of the namespace's containers' CPU counters from one node's cAdvisor, keyed pod/container."""
    # Filter before parsing: a node's cAdvisor holds every namespace's containers.
    lines = "\n".join(line for line in text.splitlines() if marker in line)
    for name, labels, value in parse_prometheus(lines, CONTAINER_FIELD):
        pod, container = labels.get("pod"), labels.get("container")
        if pod in owners and container and container != "POD":
            out.setdefault(f"{pod}/{container}", {"workload": owners[pod]})[CONTAINER_FIELD[name]] = value


class Collector:
    """Samples the install on a thread until stopped; each sample is also appended to series_path."""

    def __init__(self, kube: Kube, namespace: str, release: str, interval_seconds: float, series_path: Path | None = None,
                 clock: Callable[[], float] = time.time, data_namespace: str | None = None, prometheus: str | None = None) -> None:
        self.kube, self.ns, self.release, self.prometheus = kube, namespace, release, prometheus
        self.data_ns = data_namespace or namespace
        self.interval = interval_seconds
        self.series_path = series_path
        self.clock = clock
        p = sizing_params.values(sizing_params.load())
        self.families = [*p["watch.metrics_smithdb"]["critical"], *p["watch.metrics_smithdb"]["all_only"]]
        self.samples: list[Sample] = []
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._services: dict[str, int] | None = None

    def workload(self, component: str) -> str:
        prefix = f"{self.release}-"
        return component[len(prefix):] if component.startswith(prefix) else component

    def _json(self, *args: str) -> Any:
        text = self.kube(list(args))
        try:
            return json.loads(text) if text is not None else None
        except json.JSONDecodeError:
            return None

    def services(self) -> dict[str, int]:
        if self._services is None:
            doc = self._json("get", "services", "-n", self.ns, "-o", "json")
            if doc is None:
                return {}
            self._services = {s["metadata"]["name"]: s["spec"]["ports"][0]["port"] for s in doc.get("items", []) if s.get("spec", {}).get("ports")}
        return self._services

    def _proxy(self, service: str, path: str) -> Any:
        port = self.services().get(service)
        return None if port is None else self._json("get", "--raw", f"/api/v1/namespaces/{self.ns}/services/{service}:{port}/proxy{path}")

    def _queues(self, sample: Sample) -> None:
        """Every backlog an autoscaler reads, and the age of the oldest queued task."""
        self._ingest_queues(sample)
        self._oldest_task(sample)
        self._backend_queue(sample)
        self._compaction_jobs(sample)

    def _ingest_queues(self, sample: Sample) -> None:
        go = self._proxy(f"{self.release}-platform-backend", "/metrics?format=json")
        if go is None:
            sample["unread"].append("platform-backend queues")
            return
        sample["queues"].update({f"{q}.pending": float(go[q]["pending"]) for q in QUEUES if q in go})

    def _oldest_task(self, sample: Sample) -> None:
        port = self.services().get(f"{self.release}-platform-backend")
        if not port:
            return
        text = self.kube(["get", "--raw", f"/api/v1/namespaces/{self.ns}/services/{self.release}-platform-backend:{port}/proxy/metrics"])
        ages = [v for _, _, v in parse_prometheus(text or "", (QUEUE_LATENCY,))]
        if ages:
            sample["queues"]["oldest_task_seconds"] = max(ages)

    def _backend_queue(self, sample: Sample) -> None:
        py = self._proxy(f"{self.release}-backend", "/metrics/queue/default")
        if py is not None and "queued" in py:
            sample["queues"]["queue.queued"] = float(py["queued"])

    def _compaction_jobs(self, sample: Sample) -> None:
        compaction = next((s for s in self.services() if s.endswith("smithdb-compaction")), None)
        jobs = self._proxy(compaction, "/metrics/jobs") if compaction else None
        if jobs is not None and "pending" in jobs:
            sample["queues"]["compaction.pending"] = float(jobs["pending"])

    def _pods(self, sample: Sample) -> list[dict[str, Any]]:
        pods: list[dict[str, Any]] = []
        oom = restarts = 0
        for ns in dict.fromkeys((self.ns, self.data_ns)):
            doc = self._json("get", "pods", "-n", ns, "-o", "json")
            if doc is None:
                sample["unread"].append("pods" if ns == self.ns else f"pods in {ns}")
                continue
            for item in doc.get("items", []):
                labels = item["metadata"].get("labels", {})
                component = labels.get(COMPONENT) or (labels.get(NAME) if labels.get(NAME) in STORES else None)
                if not component:
                    continue
                statuses = item.get("status", {}).get("containerStatuses", [])
                restarts += sum(c.get("restartCount", 0) for c in statuses)
                oom += sum(c.get("lastState", {}).get("terminated", {}).get("reason") == "OOMKilled" for c in statuses)
                ports = {p.get("name"): p["containerPort"] for c in item["spec"].get("containers", []) for p in c.get("ports", [])}
                running = item.get("status", {}).get("phase") == "Running"
                workload = self.workload(component)
                pods.append({"name": item["metadata"]["name"], "namespace": ns, "workload": workload, "node": item["spec"].get("nodeName"),
                             "http": ports.get("http"), "running": running, "mounts": _claim_mounts(item["spec"])})
                sample["replicas"][workload] = sample["replicas"].get(workload, 0) + running
        sample["oom_killed"], sample["restarts"] = oom, restarts
        return pods

    def _disk(self, sample: Sample, pods: list[dict[str, Any]]) -> None:
        """KiB in each persistent volume a running pod mounts, read with du inside it (needs pods/exec): local
        volumes report no usage to the kubelet, so this is the one reading that works on every class."""
        for pod in (p for p in pods if p["running"] and p["mounts"]):
            for container, mount in pod["mounts"]:
                text = self.kube(["exec", "-n", pod["namespace"], pod["name"], "-c", container, "--", "du", "-sk", mount])
                kib = text.split()[0] if text else ""
                if kib.isdigit():
                    sample["disk"][f"{pod['workload']}:{mount}"] = int(kib)
                else:
                    sample["unread"].append(f"disk of {pod['workload']} {mount}")

    def _smithdb(self, sample: Sample, pods: list[dict[str, Any]]) -> None:
        targets = [p for p in pods if p["workload"].startswith("smithdb") and p["http"] and p["running"]]
        if not targets:
            return
        def read(pod: dict[str, Any]) -> list[tuple[str, dict[str, str], float]] | None:
            text = self.kube(["get", "--raw", f"/api/v1/namespaces/{self.ns}/pods/{pod['name']}:{pod['http']}/proxy/metrics"])
            return None if text is None else parse_prometheus(text, self.families)
        with ThreadPoolExecutor(max_workers=min(16, len(targets))) as pool:
            got = list(pool.map(read, targets))
        unread = [p["name"] for p, g in zip(targets, got, strict=True) if g is None]
        if unread:
            sample["unread"].append(f"smithdb metrics from {len(unread)} of {len(targets)} pods")
        sample["smithdb"] = merge_smithdb(g for g in got if g is not None)

    def _redis(self, sample: Sample, pods: list[dict[str, Any]]) -> None:
        pod = next((p for p in pods if p["workload"] == "redis" and p["running"]), None)
        if pod is None:
            return  # an external Redis: its cloud's monitoring reads it, and the results say not measured
        text = self.kube(["exec", "-n", pod["namespace"], pod["name"], "--", "redis-cli", "INFO"])
        if text is None:
            sample["unread"].append("redis INFO")
        else:
            sample["redis"] = parse_redis_info(text)

    def _postgres(self, sample: Sample, pods: list[dict[str, Any]]) -> None:
        pod = next((p for p in pods if p["workload"] == "postgres" and p["running"]), None)
        if pod is None:
            return  # a managed Postgres: its cloud's monitoring reads it
        text = self.kube(["exec", "-n", pod["namespace"], pod["name"], "--", "sh", "-c", POSTGRES_COMMAND])
        used, _, top = (text or "").strip().partition("|")
        if used.isdigit() and top.isdigit():
            sample["postgres"] = {"connections": float(used), "max_connections": float(top)}
        else:
            sample["unread"].append("postgres connections")

    def expired_runs(self, since_seconds: float) -> int | None:
        """Runs ingest-queue skipped as expired over the run, counted in its logs; None when unread.
        ponytail: one log read of every ingest-queue pod at the end; at hundreds of pods read the
        line from a log store instead."""
        text = self.kube(["logs", "-n", self.ns, "-l", f"{COMPONENT}={self.release}-ingest-queue", f"--since={max(1, int(since_seconds))}s",
                          "--tail=-1", "--max-log-requests=1000"])
        return None if text is None else text.count(EXPIRED_LINE)

    def _autoscalers(self, sample: Sample) -> None:
        doc = self._json("get", "hpa", "-n", self.ns, "-o", "json")
        if doc is None:
            sample["unread"].append("autoscalers")
            return
        for item in doc.get("items", []):
            target = self.workload(item["spec"]["scaleTargetRef"]["name"])
            sample["hpa"][target] = [item.get("status", {}).get("currentReplicas", 0), item["spec"]["maxReplicas"]]

    def _cpu(self, sample: Sample, pods: list[dict[str, Any]]) -> None:
        owners = {p["name"]: p["workload"] for p in pods}
        marker = f'namespace="{self.ns}"'
        if self.prometheus:
            text = self.kube(["get", "--raw", prometheus_federate(self.prometheus, self.ns)])
            if text is None:
                sample["unread"].append(f"CPU from Prometheus {self.prometheus}")
            _add_container(sample["cpu"], text or "", marker, owners)
            return
        nodes = sorted({p["node"] for p in pods if p["node"]})
        def read(node: str) -> str | None:
            return self.kube(["get", "--raw", f"/api/v1/nodes/{node}/proxy/metrics/cadvisor"])
        with ThreadPoolExecutor(max_workers=min(16, len(nodes) or 1)) as pool:
            texts = list(pool.map(read, nodes))
        if any(t is None for t in texts):
            sample["unread"].append(f"cAdvisor on {sum(t is None for t in texts)} of {len(nodes)} nodes")
        for text in texts:
            _add_container(sample["cpu"], text or "", marker, owners)

    def sample(self) -> Sample:
        s: Sample = {"t": self.clock(), "queues": {}, "smithdb": {}, "redis": {}, "postgres": {}, "hpa": {}, "replicas": {}, "cpu": {}, "disk": {}, "unread": []}
        pods = self._pods(s)
        if len(self.samples) % DISK_EVERY == 0:
            self._disk(s, pods)
        self._queues(s)
        self._smithdb(s, pods)
        self._redis(s, pods)
        self._postgres(s, pods)
        self._autoscalers(s)
        self._cpu(s, pods)
        return s

    def _record(self) -> None:
        s = self.sample()
        self.samples.append(s)
        if self.series_path is not None:
            with self.series_path.open("a") as out:
                out.write(json.dumps(s) + "\n")

    def _loop(self) -> None:
        # One more reading once stopped, so a run shorter than the interval still has two to compare:
        # verify's ten traces were stored in seconds, and its flushed hop read nothing (magus, 2026-11-25).
        while True:
            started = self.clock()
            self._record()
            if self._stop.wait(max(0.0, self.interval - (self.clock() - started))):
                self._record()
                return

    def start(self) -> None:
        self._thread = threading.Thread(target=self._loop, name="cluster-collector", daemon=True)
        self._thread.start()

    def stop(self) -> list[Sample]:
        """Stop sampling, and count the runs ingest-queue skipped as expired since the first sample."""
        self._stop.set()
        if self._thread is not None:
            self._thread.join()
        if self.samples:
            last = self.samples[-1]
            expired = self.expired_runs(self.clock() - self.samples[0]["t"] + self.interval)
            if expired is None:
                last["unread"].append("ingest-queue logs")
            else:
                last["expired_runs"] = expired
        return self.samples


# Reading the samples

def _values(samples: Sequence[Sample], get: Callable[[Sample], float | None]) -> list[tuple[float, float]]:
    out = []
    for s in samples:
        v = get(s)
        if v is not None:
            out.append((s["t"], v))
    return out


def _key(section: str, key: str) -> Callable[[Sample], float | None]:
    def get(s: Sample) -> float | None:
        value = s[section].get(key)
        return None if value is None else float(value)
    return get


def _hpa_current(name: str) -> Callable[[Sample], float | None]:
    def get(s: Sample) -> float | None:
        return float(s["hpa"][name][0]) if name in s["hpa"] else None
    return get


def _oldest_age(s: Sample) -> float | None:
    created = s["smithdb"].get(OLDEST)
    return float(s["t"] - created) if created else None


def _peak_end(points: list[tuple[float, float]], unit: str, **extra: Any) -> dict[str, Any] | None:
    if not points:
        return None
    return {"peak": max(v for _, v in points), "end": points[-1][1], "unit": unit, "samples": len(points), **extra}


def flushed_rows(sample: Sample) -> float | None:
    """Rows SmithDB has flushed since it started; None when its metrics were not read.

    ingest_flush_rows is a histogram, so its _sum is the rows. Its series appears only at the first
    flush, so a sample that read SmithDB without it has flushed none: on magus the first sample came
    before any flush, and a delta over the samples that had the series measured 0 of 100 rows
    (2026-11-25).
    """
    return smithdb_counter(sample, "ingest_flush_rows_sum")


def smithdb_counter(sample: Sample, family: str) -> float | None:
    """A SmithDB counter's value, 0 when SmithDB was read without it (a series appears at its first
    increment), None when SmithDB was not read."""
    return (family_sum(sample["smithdb"], family) or 0.0) if smithdb_read(sample) else None


def smithdb_read(sample: Sample) -> bool:
    """Whether the sample read SmithDB's metrics: a family missing from a read sample is absent, not unknown."""
    return bool(sample["smithdb"]) and not any(u.startswith("smithdb metrics") for u in sample["unread"])


def _delta(points: list[tuple[float, float]]) -> float | None:
    return points[-1][1] - points[0][1] if len(points) > 1 else None


def _mean_seconds(window: Sequence[Sample], family: str) -> dict[str, Any] | None:
    total = _delta(_values(window, lambda s: s["smithdb"].get(f"{family}_sum")))
    count = _delta(_values(window, lambda s: s["smithdb"].get(f"{family}_count")))
    if not total or not count:
        return None
    return {"mean": total / count, "unit": "seconds", "operations": count}


def kept_up(window: Sequence[Sample], get: Callable[[Sample], float | None]) -> bool | None:
    """The backlog at the window's end is no larger than the largest in its first half: a queue still
    climbing at the end did not keep up, whatever it peaked at."""
    points = _values(window, get)
    if len(points) < 2:
        return None
    first_half = [v for t, v in points if t <= (points[0][0] + points[-1][0]) / 2]
    return points[-1][1] <= max(first_half)


def cores(window: Sequence[Sample]) -> dict[str, float]:
    """CPU cores each workload used across the window: every container's CPU seconds over the time it
    was seen in the window. A pod started inside the window counts from its first sample."""
    seen: dict[str, tuple[float, float, float, float, str]] = {}
    for s in window:
        for key, entry in s["cpu"].items():
            if "seconds" not in entry:
                continue
            first = seen.get(key)
            seen[key] = (first[0], first[1], s["t"], entry["seconds"], entry["workload"]) if first else (s["t"], entry["seconds"], s["t"], entry["seconds"], entry["workload"])
    span = (window[-1]["t"] - window[0]["t"]) if len(window) > 1 else 0
    out: dict[str, float] = {}
    if span <= 0:
        return out
    for t0, v0, t1, v1, workload in seen.values():
        if t1 > t0 and v1 >= v0:
            out[workload] = out.get(workload, 0.0) + (v1 - v0) / span
    return out


def memory_peaks(samples: Sequence[Sample]) -> dict[str, float]:
    """The most memory each workload's containers held together in any one sample, in MiB."""
    peaks: dict[str, float] = {}
    for s in samples:
        now: dict[str, float] = {}
        for entry in s["cpu"].values():
            if "memory" in entry:
                now[entry["workload"]] = now.get(entry["workload"], 0.0) + entry["memory"] / 2**20
        for w, mib in now.items():
            peaks[w] = max(peaks.get(w, 0.0), mib)
    return peaks


def disk_kib(sample: Sample) -> float | None:
    """KiB every store volume held at this sample; None where the sample did not read the disks."""
    return float(sum(sample["disk"].values())) if sample.get("disk") else None


def disk_per_run(window: Sequence[Sample], runs_per_second: float | None) -> dict[str, float] | None:
    """Bytes each store volume gained a run sent, between the first and last disk reading in the window."""
    read = [s for s in window if s.get("disk")]
    if len(read) < 2 or not runs_per_second:
        return None
    runs = runs_per_second * (read[-1]["t"] - read[0]["t"])
    if runs <= 0:
        return None
    first, last = read[0]["disk"], read[-1]["disk"]
    return {k: (last[k] - first[k]) * 1024 / runs for k in sorted(first.keys() & last.keys())}


def _throttled_share(window: Sequence[Sample], workload: str) -> dict[str, Any] | None:
    first: dict[str, dict[str, float]] = {}
    last: dict[str, dict[str, float]] = {}
    for s in window:
        for key, entry in s["cpu"].items():
            if entry["workload"] == workload and "periods" in entry:
                first.setdefault(key, entry)
                last[key] = entry
    periods = sum(last[k]["periods"] - first[k]["periods"] for k in last)
    throttled = sum(last[k].get("throttled", 0) - first[k].get("throttled", 0) for k in last)
    return {"share": throttled / periods, "unit": "throttled periods over periods", "periods": periods} if periods > 0 else None


def _pct(s: Sample) -> float | None:
    used, top = s["redis"].get("used_memory"), s["redis"].get("maxmemory")
    return used / top * 100 if used is not None and top else None


def _per_pod(peak: dict[str, Any] | None, samples: Sequence[Sample], workload: str) -> dict[str, Any] | None:
    if peak is None:
        return None
    pods = max((s["replicas"].get(workload, 0) for s in samples), default=0)
    return peak | ({"peak_per_pod": peak["peak"] / pods} if pods else {})


Reader = Callable[[Sequence[Sample], Sequence[Sample], str], dict[str, Any] | None]


def _redis_memory(samples: Sequence[Sample], window: Sequence[Sample], workload: str) -> dict[str, Any] | None:
    return _peak_end(_values(samples, _pct), "% of maxmemory")


def _evictions(samples: Sequence[Sample], window: Sequence[Sample], workload: str) -> dict[str, Any] | None:
    d = _delta(_values(samples, _key("redis", "evicted_keys")))
    return None if d is None else {"during_run": d, "unit": "evicted keys"}


def _queue(metric: str) -> Reader:
    def read(samples: Sequence[Sample], window: Sequence[Sample], workload: str) -> dict[str, Any] | None:
        return _per_pod(_peak_end(_values(samples, _key("queues", metric)), "pending"), samples, workload)
    return read


def _oldest(samples: Sequence[Sample], window: Sequence[Sample], workload: str) -> dict[str, Any] | None:
    return _peak_end(_values(samples, _oldest_age), "seconds since the oldest pending job was created")


def _completions(samples: Sequence[Sample], window: Sequence[Sample], workload: str) -> dict[str, Any] | None:
    kinds = {k for s in window for k in s["smithdb"] if k.startswith(BY_KIND)}
    done = {k: _delta(_values(window, _key("smithdb", k))) for k in sorted(kinds)}
    return {"completed_in_window": {k: v for k, v in done.items() if v is not None}, "unit": "jobs"} if done else None


def _mean(family: str) -> Reader:
    def read(samples: Sequence[Sample], window: Sequence[Sample], workload: str) -> dict[str, Any] | None:
        return _mean_seconds(window, family)
    return read


def smithdb_value(s: Sample, family: str, **match: str) -> float | None:
    """A SmithDB family's value in one sample: the matching series where the pods label it so, the
    whole family where they do not (an older SmithDB without the label)."""
    values = s["smithdb"]
    labelled = any(k.partition("{")[0] == family and any(f"{m}=" in k for m in match) for k in values)
    return family_sum(values, family, **match) if labelled else family_sum(values, family)


def _gauge(family: str, per_pod: bool = False, **match: str) -> Reader:
    def read(samples: Sequence[Sample], window: Sequence[Sample], workload: str) -> dict[str, Any] | None:
        reading = _peak_end(_values(samples, lambda s: smithdb_value(s, family, **match)), "count", **({"series": match} if match else {}))
        return _per_pod(reading, samples, workload) if per_pod else reading
    return read


def _oldest_task(samples: Sequence[Sample], window: Sequence[Sample], workload: str) -> dict[str, Any] | None:
    return _peak_end(_values(samples, _key("queues", "oldest_task_seconds")), "seconds the oldest task waited")


def _expired(samples: Sequence[Sample], window: Sequence[Sample], workload: str) -> dict[str, Any] | None:
    count = samples[-1].get("expired_runs") if samples else None
    return None if count is None else {"during_run": count, "unit": "runs skipped as expired"}


def _redis_clients(samples: Sequence[Sample], window: Sequence[Sample], workload: str) -> dict[str, Any] | None:
    return _peak_end(_values(samples, _key("redis", "connected_clients")), "connected clients")


def _postgres_connections(samples: Sequence[Sample], window: Sequence[Sample], workload: str) -> dict[str, Any] | None:
    reading = _peak_end(_values(samples, _key("postgres", "connections")), "connections in use")
    tops = [s["postgres"]["max_connections"] for s in samples if "max_connections" in s["postgres"]]
    return None if reading is None else reading | ({"max_connections": max(tops)} if tops else {})


def _oom(samples: Sequence[Sample], window: Sequence[Sample], workload: str) -> dict[str, Any] | None:
    oom = _delta(_values(samples, lambda s: s.get("oom_killed")))
    restarts = _delta(_values(samples, lambda s: s.get("restarts")))
    return None if oom is None else {"during_run": oom, "restarts_during_run": restarts, "unit": "containers last killed for memory"}


def _throttling(samples: Sequence[Sample], window: Sequence[Sample], workload: str) -> dict[str, Any] | None:
    return _throttled_share(window, workload)


def _increase(family: str, unit: str) -> Reader:
    def read(samples: Sequence[Sample], window: Sequence[Sample], workload: str) -> dict[str, Any] | None:
        during = _delta(_values(samples, lambda s: smithdb_counter(s, family)))
        return None if during is None else {"during_run": during, "unit": unit}
    return read


# How each watched metric is read from the samples; a SmithDB gauge not named here is read as peak and end.
READERS: dict[str, Reader] = {
    "used_memory": _redis_memory,
    "evicted_keys": _evictions,
    "ingestion_queue.pending": _queue("ingestion_queue.pending"),
    "feedback_queue.pending": _queue("feedback_queue.pending"),
    OLDEST: _oldest,
    BY_KIND: _completions,
    "metastore_batch_flush_duration": _mean("metastore_batch_flush_duration"),
    "object_store_op_duration": _mean("object_store_op_duration"),
    "compaction_queue_job_count": _gauge("compaction_queue_job_count", per_pod=True, status="pending"),
    "ingest_pending_segment_entry_count": _gauge("ingest_pending_segment_entry_count", level="l0"),
    QUEUE_LATENCY: _oldest_task,
    f"log:{EXPIRED_LINE}": _expired,
    "connected_clients": _redis_clients,
    "pg_stat_activity": _postgres_connections,
    "kube_pod_container_status_last_terminated_reason": _oom,
    THROTTLED: _throttling,
    "query_fanout_limit_exceeded_total": _increase("query_fanout_limit_exceeded_total", "queries refused for scan-partition fanout"),
}


def _item(item: dict[str, Any], samples: Sequence[Sample], window: Sequence[Sample]) -> dict[str, Any] | None:
    metric = item["metric"]
    return READERS.get(metric, _gauge(metric))(samples, window, item["workload"])


def _autoscaler_items(item_id: str, samples: Sequence[Sample]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for name in sorted({w for s in samples for w in s["hpa"]}):
        points = _values(samples, _hpa_current(name))
        top = max(s["hpa"][name][1] for s in samples if name in s["hpa"])
        out[f"{item_id}:{name}"] = _peak_end(points, "replicas", max=top, at_ceiling_share=sum(v >= top for _, v in points) / len(points))
    return out


def metrics(samples: Sequence[Sample], window: Sequence[Sample], items: Sequence[dict[str, Any]]) -> dict[str, Any]:
    """Each watch item's reading, keyed by the plan's item id (langsmith_sizing.compare reads them)."""
    out: dict[str, Any] = {}
    for item in items:
        if item["metric"].startswith("kube_horizontalpodautoscaler"):
            out |= _autoscaler_items(item["id"], samples)
            continue
        reading = _item(item, samples, window)
        if reading is not None:
            out[item["id"]] = reading
    return out


def summarize(samples: Sequence[Sample], window: tuple[float, float], runs_per_second: float | None) -> tuple[dict[str, Any], dict[str, Any]]:
    """(metrics keyed by watch item id, the cluster section of the results)."""
    p = sizing_params.values(sizing_params.load())
    steady = [s for s in samples if window[0] <= s["t"] <= window[1]]
    used = cores(steady)
    flushed = _delta(_values(steady, flushed_rows))
    span = steady[-1]["t"] - steady[0]["t"] if len(steady) > 1 else 0
    peaks = memory_peaks(samples)
    coefficients = {
        w: {"cores_used": used.get(w), **({"runs_per_core": runs_per_second / c} if runs_per_second and (c := used.get(w)) and w in INGEST_PATH else {}),
            **({"memory_peak_mib": peaks[w]} if w in peaks else {})}
        for w in sorted(used.keys() | peaks.keys())
    }
    unread = sorted({u for s in samples for u in s["unread"]})
    cluster = {
        "read": True, "samples": len(samples), "steady_samples": len(steady),
        "window": {"from": window[0], "to": window[1]},
        "runs_per_second_sent": runs_per_second,
        "smithdb_rows_flushed_per_second": flushed / span if flushed is not None and span > 0 else None,
        "kept_up": {
            "ingestion_queue": kept_up(steady, lambda s: s["queues"].get("ingestion_queue.pending")),
            "compaction": kept_up(steady, lambda s: s["queues"].get("compaction.pending", smithdb_value(s, "compaction_queue_job_count", status="pending"))),
        },
        "coefficients": coefficients,
        "disk_bytes_per_run": disk_per_run(steady, runs_per_second),
        "unread": unread,
    }
    return metrics(samples, steady, p["watch.items"]), cluster
