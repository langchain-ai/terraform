"""A fake install answering kubectl as the API server would, one step of a load per sample.

Shapes are the real ones: the pod and HPA lists of `kubectl get -o json`, platform-backend's queue JSON,
SmithDB's Prometheus text and Redis INFO. Each `step()` moves time 15 s: ingest-queue burns 2 cores,
platform-backend 1, the ingestion backlog rises then drains, SmithDB flushes 1,000 rows a second.
"""

from __future__ import annotations

import json
from collections.abc import Sequence
from typing import Any

NS, RELEASE, STEP_SECONDS = "ls", "langsmith", 15.0
PODS = (
    ("langsmith-ingest-queue-a", "langsmith-ingest-queue", None),
    ("langsmith-platform-backend-a", "langsmith-platform-backend", None),
    ("langsmith-smithdb-ingestion-a", "langsmith-smithdb-ingestion", 8050),
    ("langsmith-smithdb-compaction-worker-a", "langsmith-smithdb-compaction-worker", None),
    ("langsmith-redis-0", "langsmith-redis", None),
    ("langsmith-postgres-0", "langsmith-postgres", None),
)
CORES = {"langsmith-ingest-queue-a": 2.0, "langsmith-platform-backend-a": 1.0, "langsmith-smithdb-ingestion-a": 4.0}
BACKLOG = (0, 40, 80, 60, 20, 10, 10)


class FakeCluster:
    def __init__(self, *, unreadable: Sequence[str] = (), data_namespace: str | None = None) -> None:
        # With data_namespace the stores run there, labelled by name as the datastores chart labels them.
        self.data_namespace = data_namespace
        self.n = 0
        self.unreadable = tuple(unreadable)
        self.calls: list[list[str]] = []

    @property
    def t(self) -> float:
        return 1_000.0 + self.n * STEP_SECONDS

    def step(self) -> None:
        self.n += 1

    def __call__(self, args: Sequence[str]) -> str | None:
        self.calls.append(list(args))
        joined = " ".join(args)
        if any(u in joined for u in self.unreadable):
            return None
        for needle, answer in (
            ("get pods", lambda: self._pods(args[args.index("-n") + 1])), ("get services", self._services), ("get hpa", self._hpa),
            ("platform-backend:1984/proxy/metrics?format=json", self._queues), ("backend:1984/proxy/metrics/queue", lambda: json.dumps({"queued": 0})),
            ("smithdb-compaction:8070/proxy/metrics/jobs", lambda: json.dumps({"pending": BACKLOG[min(self.n, len(BACKLOG) - 1)] // 10})),
            ("/proxy/metrics/cadvisor", self._cadvisor),
            # Prometheus's federate serves cAdvisor's series, each value followed by a timestamp.
            ("/proxy/federate?", lambda: "\n".join(f"{line} 1732500000000" for line in self._cadvisor().splitlines() if line and not line.startswith("#"))), ("redis-cli", self._redis), ("psql", lambda: f"{12 + self.n}|100\n"),
            ("platform-backend:1984/proxy/metrics", self._queue_latency), ("logs", lambda: "x Skipping run as it has expired\n" * 2 + "ok\n"),
            ("/proxy/metrics", self._smithdb),
        ):
            if needle in joined:
                return answer()
        return None

    def _pods(self, ns: str) -> str:
        items: list[dict[str, Any]] = []
        for name, component, port in PODS:
            store = component.removeprefix(f"{RELEASE}-") in ("redis", "postgres")
            if self.data_namespace and (ns == self.data_namespace) != store:
                continue
            labels = {"app.kubernetes.io/name": component.removeprefix(f"{RELEASE}-")} if self.data_namespace and store else {"app.kubernetes.io/component": component}
            ports = [{"name": "http", "containerPort": port}] if port else []
            items.append({
                "metadata": {"name": name, "labels": labels},
                "spec": {"nodeName": "node-1", "containers": [{"name": "main", "ports": ports}]},
                "status": {"phase": "Running", "containerStatuses": [{"restartCount": 1 if name.endswith("redis-0") and self.n > 3 else 0,
                                                                      "lastState": {"terminated": {"reason": "OOMKilled"}} if name.endswith("redis-0") and self.n > 3 else {}}]},
            })
        return json.dumps({"items": items})

    def _queue_latency(self) -> str:
        return f'langsmith_asynq_queue_latency_seconds{{queue="ingestion"}} {self.n * 2}\nlangsmith_asynq_queue_latency_seconds{{queue="default"}} 1'

    def _services(self) -> str:
        names = {"langsmith-platform-backend": 1984, "langsmith-backend": 1984, "langsmith-smithdb-compaction": 8070}
        return json.dumps({"items": [{"metadata": {"name": n}, "spec": {"ports": [{"port": p}]}} for n, p in names.items()]})

    def _hpa(self) -> str:
        current = min(1 + self.n, 4)
        return json.dumps({"items": [{"spec": {"scaleTargetRef": {"name": "langsmith-ingest-queue"}, "maxReplicas": 4}, "status": {"currentReplicas": current}}]})

    def _queues(self) -> str:
        pending = BACKLOG[min(self.n, len(BACKLOG) - 1)]
        return json.dumps({"ingestion_queue": {"pending": pending}, "feedback_queue": {"pending": 1}, "adhoc_queue": {"pending": 0}})

    def _cadvisor(self) -> str:
        lines = ['container_cpu_usage_seconds_total{container="main",namespace="other",pod="x"} 99']
        for pod, cores in CORES.items():
            lines.append(f'container_cpu_usage_seconds_total{{container="main",namespace="{NS}",pod="{pod}"}} {cores * self.n * STEP_SECONDS}')
            lines.append(f'container_cpu_usage_seconds_total{{container="POD",namespace="{NS}",pod="{pod}"}} 5')
            # Working-set memory that rises and falls back, so a peak differs from the last sample.
            lines.append(f'container_memory_working_set_bytes{{container="main",namespace="{NS}",pod="{pod}"}} {(200 + 50 * (self.n % 3)) * 2**20}')
        if self.data_namespace:
            # The stores in their own namespace burn CPU too: Postgres half a core.
            lines.append(f'container_cpu_usage_seconds_total{{container="main",namespace="{self.data_namespace}",pod="langsmith-postgres-0"}} {0.5 * self.n * STEP_SECONDS}')
        # Every pod together, as cAdvisor reports the cgroup k3s runs them in: 8 cores, a tenth of periods
        # throttled; and node-exporter's disk counters: 4 MiB/s written, busy a quarter of the time.
        lines.append(f'container_cpu_usage_seconds_total{{id="/kubepods.slice"}} {8 * self.n * STEP_SECONDS}')
        lines.append(f'container_cpu_cfs_periods_total{{id="/kubepods.slice"}} {1000 * self.n}')
        lines.append(f'container_cpu_cfs_throttled_periods_total{{id="/kubepods.slice"}} {100 * self.n}')
        lines.append(f'container_memory_working_set_bytes{{id="/kubepods.slice"}} {(10 + self.n % 3) * 2**30}')
        lines.append(f'node_disk_written_bytes_total{{device="nvme0n1"}} {4 * 2**20 * self.n * STEP_SECONDS}')
        lines.append('node_disk_read_bytes_total{device="nvme0n1"} 0')
        lines.append(f'node_disk_io_time_seconds_total{{device="nvme0n1"}} {0.25 * self.n * STEP_SECONDS}')
        lines.append(f'node_disk_written_bytes_total{{device="loop0"}} {self.n}')
        lines.append(f'container_cpu_cfs_periods_total{{container="main",namespace="{NS}",pod="langsmith-platform-backend-a"}} {100 * self.n}')
        lines.append(f'container_cpu_cfs_throttled_periods_total{{container="main",namespace="{NS}",pod="langsmith-platform-backend-a"}} {10 * self.n}')
        return "\n".join(lines)

    def _redis(self) -> str:
        return f"# Clients\r\nconnected_clients:{40 + self.n}\r\n# Memory\r\nused_memory:{(50 + self.n) * 2**20}\r\nmaxmemory:{100 * 2**20}\r\n# Stats\r\nevicted_keys:0\r\n"

    def _smithdb(self) -> str:
        return "\n".join([
            "# TYPE ingest_pending_segment_entry_count gauge",
            f'ingest_pending_segment_entry_count{{level="l0"}} {BACKLOG[min(self.n, len(BACKLOG) - 1)] * 3}',
            'ingest_pending_segment_entry_count{level="l1"} 5000',
            # A histogram, as SmithDB serves it (magus, 2026-11-25): its _sum is the rows.
            f'ingest_flush_rows_sum{{status="success",level="L0"}} {1000 * self.n * STEP_SECONDS}',
            f'ingest_flush_rows_count{{status="success",level="L0"}} {self.n}',
            f'compaction_queue_job_count{{status="pending",job_kind="runs"}} {self.n % 3}',
            'compaction_queue_job_count{status="inflight",job_kind="runs"} 7',
            f"compaction_queue_oldest_pending_created_at_seconds {self.t - 30}",
            f'compaction_jobs_executed_total{{job_kind="runs",status="success"}} {5 * self.n}',
            f"object_store_op_duration_sum {0.2 * self.n}",
            f"object_store_op_duration_count {10 * self.n}",
            "query_admission_queue_length 0",
            "unrelated_family 7",
        ])


def samples(steps: int = 7, prometheus: str | None = None, **kw: Any) -> list[dict[str, Any]]:
    from loadtest.cluster import Collector

    fake = FakeCluster(**kw)
    collector = Collector(fake, NS, RELEASE, STEP_SECONDS, clock=lambda: fake.t, data_namespace=kw.get("data_namespace"), prometheus=prometheus)
    out = []
    for _ in range(steps):
        out.append(collector.sample())
        fake.step()
    return out
