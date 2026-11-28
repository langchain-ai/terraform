"""What make plan prints from a plan, and what make export writes from the outputs."""

import io
import json
import os
import stat
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

import export
import summary


def plan(cloud: str = "baremetal", set_by_person: bool = True, cost: bool = False) -> dict:
    p = {
        "box": "m", "machine": {"cpu": 8, "memory_gi": 64, "disk_gi": 640}, "runs_per_second": 25, "readers": 5,
        "requested": {"cpu_m": 5367, "mem_mi": 25700}, "allowed": {"cpu_m": 6162, "mem_mi": 53964},
        "disks": {"volumes_gi": 468, "data_separate": cloud == "aws", "data_gi": 590, "data_mount": "/data", "used_pct": 79, "snapshot_days": 7 if cloud == "aws" else 0},
        "data": {"runs_a_day": 720000, "redis_maxmemory_mi": 5433, "redis_expiry_hours": 6, "redis_stall_hours": 1, "kb_a_run": {"redis": 8.115}, "postgres_max_connections": 200},
        "volumes_gi": {"object_store": 354, "smithdb_cache": 68, "postgres": 20, "redis": 6, "prometheus": 20},
        "retention": {"short_days": 14, "long_days": 30, "extended_pct": 5, "metrics_days": 15, "set_by_person": set_by_person},
        "features": {"observability": True, "mission_control": True, "code_evaluators": False, "tunnel": False, "k3s": True},
        "versions": {"langsmith": "0.18.2", "k3s": "v1.36.6+k3s1", "mission-control": "1.2.10"},
        "releases": ["datastores", "langsmith", "mission-control"],
        "cost_usd_a_month": {"total": 464, "instance_type": "r7i.2xlarge", "instance": 386.32, "disks": 50.4, "snapshots": 23.4, "address": 3.65} if cost else None,
    }
    outputs = {"plan": {"value": p}, "instance": {"value": {"cloud": cloud}}, "ssh": {"value": {"host": "magus"}}, "url": {"value": "http://localhost:8080"}}
    changes = [{"change": {"actions": ["create"]}}, {"change": {"actions": ["delete", "create"]}}, {"change": {"actions": ["no-op"]}}]
    output_changes = {"values": {"actions": ["update"]}, "url": {"actions": ["no-op"]}}
    return {"planned_values": {"outputs": outputs}, "resource_changes": changes, "output_changes": output_changes}


def printed(doc: dict) -> tuple[int, str]:
    out = io.StringIO()
    with mock.patch.object(sys, "stdin", io.StringIO(json.dumps(doc))), redirect_stdout(out):
        code = summary.main()
    return code, out.getvalue()


class Summary(unittest.TestCase):
    def test_a_box_shows_its_fit_its_disk_and_its_changes(self) -> None:
        code, text = printed(plan())
        self.assertEqual(code, 0)
        for line in ("m: 8 vCPU, 64 GiB, on magus", "system's 640 GiB disk, 79% used", "not running", "code evaluators", "2 to add, 0 to change, 1 to destroy; 1 outputs change", "while make access runs"):
            self.assertIn(line, text)

    def test_retention_left_at_the_defaults_is_said_loudly(self) -> None:
        _, text = printed(plan(set_by_person=False))
        self.assertIn("the defaults", text)
        self.assertIn("set short_ttl_days and long_ttl_days", text)

    def test_aws_shows_its_data_disk_snapshots_and_cost(self) -> None:
        _, text = printed(plan(cloud="aws", cost=True))
        self.assertIn("a data disk of 590 GiB at /data", text)
        self.assertIn("daily snapshots kept 7 days", text)
        self.assertIn("about $464 a month", text)

    def test_a_cluster_shows_requests_and_no_box(self) -> None:
        _, text = printed(plan(cloud="cluster"))
        self.assertIn("on a cluster of one's own", text)
        self.assertNotIn("langsmith at", text)

    def test_a_plan_without_the_sizing_output_fails(self) -> None:
        code, _ = printed({"planned_values": {"outputs": {}}})
        self.assertEqual(code, 1)

    def test_a_plan_that_changes_only_the_values_has_something_to_apply(self) -> None:
        doc = {"resource_changes": [{"change": {"actions": ["no-op"]}}], "output_changes": {"values": {"actions": ["update"]}}}
        out = io.StringIO()
        with mock.patch.object(sys, "stdin", io.StringIO(json.dumps(doc))), redirect_stdout(out):
            summary.count()
        self.assertEqual(out.getvalue().strip(), "1")

    def test_share_colours_by_how_full(self) -> None:
        self.assertIn("(50%)", summary.share(1, 2, "vCPU"))
        self.assertIn("(0%)", summary.share(0, 0, "vCPU"))


class Export(unittest.TestCase):
    def test_writes_each_release_in_order_and_the_secrets_private(self) -> None:
        releases = {
            "datastores": {"chart": {"chart": "/x/datastores-0.6.0.tgz"}, "namespace": "a-data", "values": {"k": 1}, "layer": ""},
            "langsmith": {"chart": {"chart": "langsmith", "repo": "https://example.com", "version": "0.18.2"}, "namespace": "a", "values": {}, "layer": "smithdb: {}\n"},
        }
        out_doc = {"cluster_yaml": "kind: Namespace\n", "secrets_yaml": "kind: Secret\n", "datastores_tgz": "datastores-0.6.0.tgz"}
        with tempfile.TemporaryDirectory() as d:
            Path(d, "v.json").write_text(json.dumps(releases))
            Path(d, "e.json").write_text(json.dumps(out_doc))
            out = os.path.join(d, "out")
            stdout = io.StringIO()
            with mock.patch.object(sys, "argv", ["export.py", out, f"{d}/v.json", f"{d}/e.json"]), redirect_stdout(stdout):
                self.assertEqual(export.main(), 0)
            self.assertEqual(stdout.getvalue().strip(), "datastores-0.6.0.tgz")
            script = Path(out, "install.sh").read_text().splitlines()
            self.assertIn("helm upgrade --install datastores charts/datastores-0.6.0.tgz -n a-data -f values/00-datastores.yaml", script[-2])
            self.assertIn("-f values/01-langsmith.yaml -f values/01-langsmith.layer.yaml", script[-1])
            self.assertEqual(stat.S_IMODE(os.stat(os.path.join(out, "secrets.yaml")).st_mode), 0o600)
            self.assertTrue(Path(out, "values", "01-langsmith.layer.yaml").exists())


if __name__ == "__main__":
    unittest.main()
