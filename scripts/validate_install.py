#!/usr/bin/env python3
"""
Post-apply validation script for Kubernetes deployments (Terraform + Helm).
Validates cluster connectivity, Helm releases, workloads, Jobs, Services,
Ingress/Gateway, PVCs, Secrets, external services, pod logs, HTTP endpoints,
node capacity, and beacon connectivity.
Read-only and idempotent.
"""

from __future__ import annotations

import base64
import json
import logging
import os
import re
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

import click
import requests
import yaml
from kubernetes import client, config
from kubernetes.client.rest import ApiException
from kubernetes.stream import stream as k8s_stream

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
DEFAULT_KUBECONFIG = os.path.expanduser("~/.kube/config")
DEFAULT_TIMEOUT_SECONDS = 900
DEFAULT_POLL_SECONDS = 10
BAD_POD_REASONS = {"CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "CreateContainerConfigError"}

VALID_TOP_LEVEL_KEYS = {"namespaces", "helm_releases", "resource_checks", "exclusions"}
VALID_RESOURCE_CHECK_KEYS = {
    "deployments", "statefulsets", "daemonsets", "pods", "jobs", "services",
    "ingress", "pvcs", "secrets", "external_services", "pod_logs", "endpoints",
    "node_capacity", "beacon",
}

LANGSMITH_SERVICE_HEALTH_MAP: list[dict[str, Any]] = [
    {"name": "frontend", "port": 8080, "path": "/health"},
    {"name": "backend", "port": 1984, "path": "/health"},
    {"name": "platform-backend", "port": 1986, "path": "/ok"},
    {"name": "ace-backend", "port": 1987, "path": "/ok"},
    {"name": "playground", "port": 1988, "path": "/ok"},
]

NODE_PRESSURE_CONDITIONS = {"DiskPressure", "MemoryPressure", "PIDPressure"}

BEACON_ENV_KEYS = {"BEACON_LOGGING_ENABLED", "BEACON_METRICS_ENABLED", "BEACON_TRACING_ENABLED"}
BEACON_ERROR_PATTERNS = [
    r"beacon.*connection refused",
    r"beacon.*timeout",
    r"beacon.*unreachable",
    r"beacon.*failed",
    r"BEACON.*error",
    r"telemetry.*failed",
]

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------


class HumanFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        msg = super().format(record)
        if record.levelno >= logging.ERROR:
            return f"ERROR: {msg}"
        if record.levelno >= logging.WARNING:
            return f"WARN:  {msg}"
        return msg


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        d = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(record.created)),
            "level": record.levelname,
            "message": record.getMessage(),
        }
        if record.exc_info:
            d["exception"] = self.formatException(record.exc_info)
        return json.dumps(d)


def setup_logging(json_logs: bool) -> None:
    root = logging.getLogger()
    root.setLevel(logging.DEBUG)
    for h in list(root.handlers):
        root.removeHandler(h)
    handler = logging.StreamHandler(sys.stderr)
    handler.setLevel(logging.INFO)
    handler.setFormatter(JsonFormatter() if json_logs else HumanFormatter())
    root.addHandler(handler)


# -----------------------------------------------------------------------------
# Result tracking
# -----------------------------------------------------------------------------


@dataclass
class CheckResult:
    name: str
    passed: bool
    message: str
    details: Optional[str] = None
    warning: bool = False


@dataclass
class ValidationReport:
    results: list[CheckResult] = field(default_factory=list)
    start_time: float = field(default_factory=time.monotonic)

    def add(self, name: str, passed: bool, message: str, details: Optional[str] = None, warning: bool = False) -> None:
        self.results.append(CheckResult(name=name, passed=passed, message=message, details=details, warning=warning))

    def failed(self) -> list[CheckResult]:
        return [r for r in self.results if not r.passed and not r.warning]

    def warnings(self) -> list[CheckResult]:
        return [r for r in self.results if r.warning or (not r.passed and r.warning)]

    def passed_all(self) -> bool:
        return len(self.failed()) == 0

    def elapsed_seconds(self) -> float:
        return time.monotonic() - self.start_time


# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------


def load_config(path: str) -> dict[str, Any]:
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(f"Config file not found: {path}")
    with open(p, encoding="utf-8") as f:
        data = yaml.safe_load(f)
    return data or {}


def get_namespaces(cfg: dict[str, Any], cli_namespace: Optional[str]) -> list[str]:
    if cli_namespace:
        return [cli_namespace]
    return list(cfg.get("namespaces") or [])


def get_helm_releases(cfg: dict[str, Any]) -> list[dict[str, Any]]:
    return list(cfg.get("helm_releases") or [])


def get_resource_checks(cfg: dict[str, Any]) -> dict[str, Any]:
    return dict(cfg.get("resource_checks") or {})


def get_exclusions(cfg: dict[str, Any]) -> dict[str, Any]:
    return cfg.get("exclusions") or {}


# -----------------------------------------------------------------------------
# Dry-run config validation
# -----------------------------------------------------------------------------


def _validate_config_schema(cfg: dict[str, Any]) -> list[str]:
    """Return a list of human-readable issues found in the config structure."""
    issues: list[str] = []

    unknown_top = set(cfg.keys()) - VALID_TOP_LEVEL_KEYS
    if unknown_top:
        issues.append(f"Unknown top-level keys: {sorted(unknown_top)}")

    ns = cfg.get("namespaces")
    if ns is not None:
        if not isinstance(ns, list):
            issues.append(f"'namespaces' should be a list, got {type(ns).__name__}")
        elif len(ns) == 0:
            issues.append("'namespaces' is empty — no namespaces will be checked")

    releases = cfg.get("helm_releases")
    if releases is not None:
        if not isinstance(releases, list):
            issues.append(f"'helm_releases' should be a list, got {type(releases).__name__}")
        else:
            for i, rel in enumerate(releases):
                if not isinstance(rel, dict):
                    issues.append(f"helm_releases[{i}] should be a mapping")
                    continue
                if not rel.get("name"):
                    issues.append(f"helm_releases[{i}] missing 'name'")
                if not rel.get("namespace"):
                    issues.append(f"helm_releases[{i}] missing 'namespace'")

    rc = cfg.get("resource_checks")
    if rc is not None:
        if not isinstance(rc, dict):
            issues.append(f"'resource_checks' should be a mapping, got {type(rc).__name__}")
        else:
            unknown_rc = set(rc.keys()) - VALID_RESOURCE_CHECK_KEYS
            if unknown_rc:
                issues.append(f"Unknown resource_checks keys: {sorted(unknown_rc)}")

    excl = cfg.get("exclusions")
    if excl is not None:
        if not isinstance(excl, dict):
            issues.append(f"'exclusions' should be a mapping, got {type(excl).__name__}")
        else:
            for sel in excl.get("label_selectors") or []:
                if isinstance(sel, str) and "=" not in sel:
                    issues.append(f"Malformed label selector (missing '='): '{sel}'")

    return issues


def _compute_check_plan(cfg: dict[str, Any], cli_options: dict[str, Any]) -> list[str]:
    """Return a list of check names that would execute given the config and CLI flags."""
    plan: list[str] = ["cluster_connectivity"]
    rc = get_resource_checks(cfg)

    if not cli_options.get("skip_helm_release_checks") and get_helm_releases(cfg):
        plan.append("helm_releases")

    plan.extend(["deployments", "statefulsets", "daemonsets", "pods"])

    if not cli_options.get("skip_jobs"):
        plan.append("jobs")
    if not cli_options.get("skip_services"):
        plan.append("services")
    if not cli_options.get("skip_ingress"):
        plan.append("ingress")
    if not cli_options.get("skip_pvcs"):
        plan.append("pvcs")
    if not cli_options.get("skip_secrets") and rc.get("secrets"):
        plan.append("secrets")
    if not cli_options.get("skip_external_services"):
        ext = rc.get("external_services") or {}
        enabled = [k for k, v in ext.items() if isinstance(v, dict) and v.get("enabled")]
        if enabled:
            plan.append(f"external_services ({', '.join(enabled)})")
    if not cli_options.get("skip_pod_logs") and (rc.get("pod_logs") or {}).get("enabled"):
        plan.append("pod_logs")
    if not cli_options.get("skip_endpoints"):
        ep = rc.get("endpoints") or {}
        if ep.get("external_url") or (ep.get("in_cluster") or {}).get("enabled"):
            plan.append("endpoints")
    if not cli_options.get("skip_node_capacity"):
        plan.append("node_capacity")
    if not cli_options.get("skip_beacon") and (rc.get("beacon") or {}).get("enabled"):
        plan.append("beacon")

    return plan


def run_dry_run(cfg: dict[str, Any], cli_options: dict[str, Any]) -> int:
    """Validate config and print check plan. Returns exit code 0 or 2."""
    issues = _validate_config_schema(cfg)
    if issues:
        print("Config validation issues:", file=sys.stderr)
        for issue in issues:
            print(f"  - {issue}", file=sys.stderr)
        print("", file=sys.stderr)

    plan = _compute_check_plan(cfg, cli_options)
    namespaces = get_namespaces(cfg, cli_options.get("namespace"))
    print("--- Dry-run: check plan ---", file=sys.stderr)
    print(f"  Namespaces: {namespaces or '(none)'}", file=sys.stderr)
    print(f"  Checks ({len(plan)}):", file=sys.stderr)
    for name in plan:
        print(f"    - {name}", file=sys.stderr)

    if issues:
        print("\nConfig has issues — fix them before running.", file=sys.stderr)
        return 2
    print("\nConfig OK — ready to run.", file=sys.stderr)
    return 0


# -----------------------------------------------------------------------------
# K8s client
# -----------------------------------------------------------------------------


def load_kubeconfig(
    kubeconfig: Optional[str],
    context: Optional[str],
) -> tuple[client.CoreV1Api, client.AppsV1Api, client.BatchV1Api, client.NetworkingV1Api, Any]:
    kcfg = kubeconfig or os.environ.get("KUBECONFIG") or DEFAULT_KUBECONFIG
    if not os.path.isfile(kcfg):
        raise FileNotFoundError(f"Kubeconfig not found: {kcfg}")
    try:
        config.load_kube_config(config_file=kcfg, context=context)
    except config.ConfigException as e:
        raise RuntimeError(f"Failed to load kubeconfig: {e}") from e
    configuration = client.Configuration.get_default_copy()
    core = client.CoreV1Api()
    apps = client.AppsV1Api()
    batch = client.BatchV1Api()
    netv1 = client.NetworkingV1Api()
    custom = client.CustomObjectsApi()
    return core, apps, batch, netv1, custom


# -----------------------------------------------------------------------------
# Validators
# -----------------------------------------------------------------------------


def check_cluster_connectivity(core: client.CoreV1Api, report: ValidationReport) -> bool:
    try:
        core.list_namespace(limit=1)
        ver = client.VersionApi(core.api_client).get_code()
        report.add("cluster_connectivity", True, "Cluster API reachable", details=ver.git_version)
        return True
    except ApiException as e:
        report.add("cluster_connectivity", False, f"Cluster API error: {e.reason}", details=str(e.body))
        return False
    except Exception as e:
        report.add("cluster_connectivity", False, f"Cluster connection failed: {e}", details=None)
        return False


def _label_selector(labels: dict[str, str]) -> str:
    return ",".join(f"{k}={v}" for k, v in (labels or {}).items())


def _matches_exclusions(
    name: str,
    namespace: str,
    labels: dict,
    exclusions: dict[str, Any],
) -> bool:
    excl_ns = exclusions.get("namespaces") or []
    if namespace in excl_ns:
        return True
    for sel in exclusions.get("label_selectors") or []:
        # Simple key=value selector
        if "=" in sel:
            k, v = sel.split("=", 1)
            if labels.get(k) == v:
                return True
    for pattern in exclusions.get("resource_names") or []:
        if pattern in name or (pattern.startswith("*") and name.endswith(pattern[1:])):
            return True
    return False


def check_helm_release_presence(
    core: client.CoreV1Api,
    apps: client.AppsV1Api,
    releases: list[dict],
    report: ValidationReport,
    exclusions: dict[str, Any],
) -> None:
    for rel in releases:
        name = rel.get("name") or "unknown"
        namespace = rel.get("namespace") or "default"
        selector_labels = rel.get("selector_labels") or {"app.kubernetes.io/instance": name}
        required_kinds = rel.get("required_kinds") or ["Deployment", "StatefulSet", "DaemonSet", "Service"]
        allow_no_resources = rel.get("allow_no_resources", False)
        sel = _label_selector(selector_labels)
        found_helm_secret = False
        try:
            secrets = core.list_namespaced_secret(
                namespace,
                label_selector="owner=helm",
            )
            for s in secrets.items:
                if s.metadata.name.startswith(f"sh.helm.release.v1.{name}."):
                    found_helm_secret = True
                    break
        except ApiException:
            pass
        found_resources = []
        if "Deployment" in required_kinds:
            try:
                deploys = apps.list_namespaced_deployment(namespace, label_selector=sel)
                found_resources.extend([f"Deployment/{d.metadata.name}" for d in deploys.items])
            except ApiException:
                pass
        if "StatefulSet" in required_kinds:
            try:
                sts = apps.list_namespaced_stateful_set(namespace, label_selector=sel)
                found_resources.extend([f"StatefulSet/{s.metadata.name}" for s in sts.items])
            except ApiException:
                pass
        if "DaemonSet" in required_kinds:
            try:
                ds = apps.list_namespaced_daemon_set(namespace, label_selector=sel)
                found_resources.extend([f"DaemonSet/{d.metadata.name}" for d in ds.items])
            except ApiException:
                pass
        if "Service" in required_kinds:
            try:
                svcs = core.list_namespaced_service(namespace, label_selector=sel)
                found_resources.extend([f"Service/{s.metadata.name}" for s in svcs.items])
            except ApiException:
                pass
        if found_helm_secret or found_resources:
            report.add(
                f"helm_release:{name}/{namespace}",
                True,
                f"Release '{name}' found",
                details=", ".join(found_resources) if found_resources else "Helm secret present",
            )
        elif allow_no_resources:
            report.add(f"helm_release:{name}/{namespace}", True, f"Release '{name}' (allow_no_resources)", details=None)
        else:
            report.add(
                f"helm_release:{name}/{namespace}",
                False,
                f"No resources found for release '{name}' in {namespace}",
                details=f"selector={sel}",
            )


def check_deployments(
    apps: client.AppsV1Api,
    namespaces: list[str],
    report: ValidationReport,
    options: dict[str, Any],
    exclusions: dict[str, Any],
) -> None:
    for ns in namespaces:
        try:
            deploys = apps.list_namespaced_deployment(ns)
        except ApiException as e:
            report.add(f"deployments:{ns}", False, f"Failed to list Deployments: {e.reason}", details=str(e.body))
            continue
        for d in deploys.items:
            if _matches_exclusions(d.metadata.name, ns, d.metadata.labels or {}, exclusions):
                continue
            spec_replicas = d.spec.replicas or 0
            status = d.status or {}
            available = getattr(status, "available_replicas") or 0
            observed = getattr(status, "observed_generation") or 0
            generation = d.metadata.generation or 0
            conditions = getattr(status, "conditions") or []
            available_cond = next((c for c in conditions if c.type == "Available"), None)
            progressing_cond = next((c for c in conditions if c.type == "Progressing"), None)
            ok = (
                available >= spec_replicas
                and observed >= generation
                and (available_cond is None or getattr(available_cond, "status", "") == "True")
            )
            if not ok:
                report.add(
                    f"deployment:{ns}/{d.metadata.name}",
                    False,
                    f"Deployment not ready: available={available}/{spec_replicas}, observed_gen={observed}/{generation}",
                    details=f"Available condition: {available_cond}; Progressing: {progressing_cond}",
                )
            else:
                report.add(f"deployment:{ns}/{d.metadata.name}", True, f"available={available}/{spec_replicas}", details=None)


def check_statefulsets(
    apps: client.AppsV1Api,
    namespaces: list[str],
    report: ValidationReport,
    options: dict[str, Any],
    exclusions: dict[str, Any],
) -> None:
    require_updated = (options.get("statefulsets") or {}).get("require_updated_replicas", True)
    for ns in namespaces:
        try:
            sts_list = apps.list_namespaced_stateful_set(ns)
        except ApiException as e:
            report.add(f"statefulsets:{ns}", False, f"Failed to list StatefulSets: {e.reason}", details=str(e.body))
            continue
        for s in sts_list.items:
            if _matches_exclusions(s.metadata.name, ns, s.metadata.labels or {}, exclusions):
                continue
            replicas = s.spec.replicas or 0
            status = s.status or {}
            ready = getattr(status, "ready_replicas") or 0
            updated = getattr(status, "updated_replicas") or 0
            ok = ready == replicas and (not require_updated or updated == replicas)
            if not ok:
                report.add(
                    f"statefulset:{ns}/{s.metadata.name}",
                    False,
                    f"StatefulSet not ready: ready={ready}/{replicas}, updated={updated}/{replicas}",
                    details=None,
                )
            else:
                report.add(f"statefulset:{ns}/{s.metadata.name}", True, f"ready={ready}/{replicas}", details=None)


def check_daemonsets(
    apps: client.AppsV1Api,
    namespaces: list[str],
    report: ValidationReport,
    options: dict[str, Any],
    exclusions: dict[str, Any],
) -> None:
    for ns in namespaces:
        try:
            ds_list = apps.list_namespaced_daemon_set(ns)
        except ApiException as e:
            report.add(f"daemonsets:{ns}", False, f"Failed to list DaemonSets: {e.reason}", details=str(e.body))
            continue
        for d in ds_list.items:
            if _matches_exclusions(d.metadata.name, ns, d.metadata.labels or {}, exclusions):
                continue
            status = d.status or {}
            desired = getattr(status, "desired_number_scheduled") or 0
            number_ready = getattr(status, "number_ready") or 0
            updated = getattr(status, "updated_number_scheduled") or 0
            ok = number_ready == desired and updated == desired
            if not ok:
                report.add(
                    f"daemonset:{ns}/{d.metadata.name}",
                    False,
                    f"DaemonSet not ready: number_ready={number_ready}/{desired}, updated={updated}/{desired}",
                    details=None,
                )
            else:
                report.add(f"daemonset:{ns}/{d.metadata.name}", True, f"ready={number_ready}/{desired}", details=None)


def check_pods(
    core: client.CoreV1Api,
    namespaces: list[str],
    report: ValidationReport,
    options: dict[str, Any],
    exclusions: dict[str, Any],
) -> None:
    opts = options.get("pods") or {}
    require_ready = opts.get("require_ready", True)
    ignore_completed = opts.get("ignore_completed", True)
    allowed_phases = set(opts.get("allowed_phases") or ["Running", "Succeeded"])
    for ns in namespaces:
        try:
            pods = core.list_namespaced_pod(ns)
        except ApiException as e:
            report.add(f"pods:{ns}", False, f"Failed to list Pods: {e.reason}", details=str(e.body))
            continue
        for p in pods.items:
            if _matches_exclusions(p.metadata.name, ns, p.metadata.labels or {}, exclusions):
                continue
            phase = p.status.phase if p.status else "Unknown"
            if phase == "Succeeded" and ignore_completed:
                continue
            if phase not in allowed_phases:
                reason = ""
                for c in (p.status.container_statuses or []) if p.status else []:
                    state = c.state
                    if state and state.waiting:
                        reason = state.waiting.reason or ""
                        if reason in BAD_POD_REASONS:
                            report.add(
                                f"pod:{ns}/{p.metadata.name}",
                                False,
                                f"Pod bad state: {reason}",
                                details=getattr(state.waiting, "message", ""),
                            )
                            break
                if reason not in BAD_POD_REASONS:
                    report.add(
                        f"pod:{ns}/{p.metadata.name}",
                        False,
                        f"Pod phase={phase} (allowed: {allowed_phases})",
                        details=reason or None,
                    )
                continue
            ready = False
            if p.status and p.status.conditions:
                for c in p.status.conditions:
                    if c.type == "Ready" and c.status == "True":
                        ready = True
                        break
            if require_ready and not ready:
                report.add(f"pod:{ns}/{p.metadata.name}", False, "Pod not Ready", details=f"phase={phase}")
            else:
                report.add(f"pod:{ns}/{p.metadata.name}", True, f"phase={phase}, Ready={ready}", details=None)


def check_jobs(
    batch: client.BatchV1Api,
    namespaces: list[str],
    report: ValidationReport,
    options: dict[str, Any],
    exclusions: dict[str, Any],
) -> None:
    opts = options.get("jobs") or {}
    require_complete = opts.get("require_complete", True)
    forbid_failed = opts.get("forbid_failed", True)
    for ns in namespaces:
        try:
            jobs = batch.list_namespaced_job(ns)
        except ApiException as e:
            report.add(f"jobs:{ns}", False, f"Failed to list Jobs: {e.reason}", details=str(e.body))
            continue
        for j in jobs.items:
            if _matches_exclusions(j.metadata.name, ns, j.metadata.labels or {}, exclusions):
                continue
            status = j.status or {}
            succeeded = getattr(status, "succeeded") or 0
            failed = getattr(status, "failed") or 0
            completions = j.spec.completions if j.spec and j.spec.completions is not None else 1
            complete = succeeded >= completions
            no_fail = not forbid_failed or failed == 0
            if require_complete and not complete:
                report.add(
                    f"job:{ns}/{j.metadata.name}",
                    False,
                    f"Job not complete: succeeded={succeeded}/{completions}",
                    details=None,
                )
            elif forbid_failed and failed > 0:
                report.add(
                    f"job:{ns}/{j.metadata.name}",
                    False,
                    f"Job has failures: failed={failed}",
                    details=None,
                )
            else:
                report.add(f"job:{ns}/{j.metadata.name}", True, f"succeeded={succeeded}, failed={failed}", details=None)


def check_services(
    core: client.CoreV1Api,
    namespaces: list[str],
    report: ValidationReport,
    options: dict[str, Any],
    require_lb: bool,
    exclusions: dict[str, Any],
) -> None:
    opts = options.get("services") or {}
    require_endpoints = opts.get("require_endpoints_for_clusterip", False)
    require_lb = require_lb or opts.get("require_loadbalancer_ip_or_hostname", False)
    for ns in namespaces:
        try:
            svcs = core.list_namespaced_service(ns)
        except ApiException as e:
            report.add(f"services:{ns}", False, f"Failed to list Services: {e.reason}", details=str(e.body))
            continue
        for s in svcs.items:
            if _matches_exclusions(s.metadata.name, ns, s.metadata.labels or {}, exclusions):
                continue
            if require_lb and (s.spec.type or "") == "LoadBalancer":
                ingress = s.status.load_balancer.ingress if s.status and s.status.load_balancer else []
                if not ingress:
                    report.add(
                        f"service:{ns}/{s.metadata.name}",
                        False,
                        "LoadBalancer has no ingress address",
                        details=None,
                    )
                else:
                    addrs = [i.hostname or i.ip for i in ingress]
                    report.add(
                        f"service:{ns}/{s.metadata.name}",
                        True,
                        f"LoadBalancer: {addrs}",
                        details=None,
                    )
            elif require_endpoints and (s.spec.type or "") == "ClusterIP":
                try:
                    ep = core.read_namespaced_endpoints(s.metadata.name, ns)
                    subsets = ep.subsets or []
                    if not subsets:
                        report.add(
                            f"service:{ns}/{s.metadata.name}",
                            False,
                            "ClusterIP Service has no endpoints",
                            details=None,
                        )
                    else:
                        report.add(f"service:{ns}/{s.metadata.name}", True, "has endpoints", details=None)
                except ApiException:
                    report.add(
                        f"service:{ns}/{s.metadata.name}",
                        False,
                        "Could not read Endpoints",
                        details=None,
                    )
            else:
                report.add(f"service:{ns}/{s.metadata.name}", True, f"type={s.spec.type or 'ClusterIP'}", details=None)


def check_ingress(
    netv1: client.NetworkingV1Api,
    custom: client.CustomObjectsApi,
    namespaces: list[str],
    report: ValidationReport,
    options: dict[str, Any],
    require_address: bool,
    exclusions: dict[str, Any],
) -> None:
    opts = options.get("ingress") or {}
    require_address = require_address or opts.get("require_address", False)
    for ns in namespaces:
        try:
            ing_list = netv1.list_namespaced_ingress(ns)
        except ApiException:
            ing_list = type("IngressList", (), {"items": []})()
            ing_list.items = []
        for ing in getattr(ing_list, "items", []):
            if _matches_exclusions(ing.metadata.name, ns, ing.metadata.labels or {}, exclusions):
                continue
            status = getattr(ing, "status", None)
            lb = getattr(status, "load_balancer", None) if status else None
            ingress_list = getattr(lb, "ingress", []) if lb else []
            if require_address and not ingress_list:
                report.add(
                    f"ingress:{ns}/{ing.metadata.name}",
                    False,
                    "Ingress has no address",
                    details=None,
                )
            else:
                addrs = [getattr(i, "hostname", None) or getattr(i, "ip", None) for i in ingress_list]
                report.add(
                    f"ingress:{ns}/{ing.metadata.name}",
                    True,
                    f"addresses={addrs}" if addrs else "present",
                    details=None,
                )
        try:
            gateways = custom.list_namespaced_custom_object(
                group="gateway.networking.k8s.io",
                version="v1",
                namespace=ns,
                plural="gateways",
            )
        except ApiException:
            gateways = {"items": []}
        for g in gateways.get("items", []):
            name = g.get("metadata", {}).get("name", "?")
            if _matches_exclusions(name, ns, g.get("metadata", {}).get("labels") or {}, exclusions):
                continue
            status = g.get("status", {})
            addresses = status.get("addresses", [])
            conditions = status.get("conditions", [])
            admitted = any(c.get("type") == "Programmed" and c.get("status") == "True" for c in conditions)
            if require_address and not addresses:
                report.add(
                    f"gateway:{ns}/{name}",
                    False,
                    "Gateway has no addresses",
                    details=None,
                )
            else:
                addrs = [a.get("value") for a in addresses]
                report.add(
                    f"gateway:{ns}/{name}",
                    True,
                    f"admitted={admitted}, addresses={addrs}" if addrs else f"admitted={admitted}",
                    details=None,
                )


# -----------------------------------------------------------------------------
# New validators
# -----------------------------------------------------------------------------


def check_pvcs(
    core: client.CoreV1Api,
    namespaces: list[str],
    report: ValidationReport,
    options: dict[str, Any],
    exclusions: dict[str, Any],
) -> None:
    opts = options.get("pvcs") or {}
    require_bound = opts.get("require_bound", True)
    for ns in namespaces:
        try:
            pvcs = core.list_namespaced_persistent_volume_claim(ns)
        except ApiException as e:
            report.add(f"pvcs:{ns}", False, f"Failed to list PVCs: {e.reason}", details=str(e.body))
            continue
        for pvc in pvcs.items:
            if _matches_exclusions(pvc.metadata.name, ns, pvc.metadata.labels or {}, exclusions):
                continue
            phase = pvc.status.phase if pvc.status else "Unknown"
            sc = pvc.spec.storage_class_name or "(default)"
            if phase == "Bound":
                report.add(f"pvc:{ns}/{pvc.metadata.name}", True, f"Bound, storageClass={sc}")
            elif phase == "Pending" and require_bound:
                event_msg = _get_pvc_events(core, pvc.metadata.name, ns)
                report.add(
                    f"pvc:{ns}/{pvc.metadata.name}",
                    False,
                    f"PVC stuck in Pending, storageClass={sc}",
                    details=event_msg or None,
                )
            elif phase == "Lost":
                report.add(
                    f"pvc:{ns}/{pvc.metadata.name}",
                    False,
                    f"PVC Lost, storageClass={sc}",
                    details=None,
                    warning=True,
                )
            else:
                report.add(f"pvc:{ns}/{pvc.metadata.name}", True, f"phase={phase}, storageClass={sc}")


def _get_pvc_events(core: client.CoreV1Api, name: str, namespace: str) -> str:
    """Fetch recent warning events for a PVC to explain why it is Pending."""
    try:
        events = core.list_namespaced_event(
            namespace,
            field_selector=f"involvedObject.name={name},involvedObject.kind=PersistentVolumeClaim",
        )
        warnings = [
            e.message for e in (events.items or [])
            if e.type == "Warning" and e.message
        ]
        return "; ".join(warnings[-3:]) if warnings else ""
    except ApiException:
        return ""


def check_secrets_existence(
    core: client.CoreV1Api,
    namespaces: list[str],
    report: ValidationReport,
    options: dict[str, Any],
    exclusions: dict[str, Any],
) -> None:
    secret_specs = options.get("secrets") or []
    if not isinstance(secret_specs, list):
        return
    for spec in secret_specs:
        name = spec.get("name", "")
        ns = spec.get("namespace") or (namespaces[0] if namespaces else "default")
        required_keys = spec.get("required_keys") or []
        if _matches_exclusions(name, ns, {}, exclusions):
            continue
        try:
            secret = core.read_namespaced_secret(name, ns)
        except ApiException as e:
            if e.status == 404:
                report.add(f"secret:{ns}/{name}", False, "Secret not found")
            else:
                report.add(f"secret:{ns}/{name}", False, f"Failed to read secret: {e.reason}")
            continue
        existing_keys = set((secret.data or {}).keys())
        missing = [k for k in required_keys if k not in existing_keys]
        if missing:
            report.add(
                f"secret:{ns}/{name}",
                False,
                f"Secret missing keys: {missing}",
                details=f"present keys: {sorted(existing_keys)}",
            )
        else:
            report.add(f"secret:{ns}/{name}", True, f"exists with {len(existing_keys)} keys")


def check_external_services(
    core: client.CoreV1Api,
    namespaces: list[str],
    report: ValidationReport,
    options: dict[str, Any],
    exclusions: dict[str, Any],
) -> None:
    ext_cfg = options.get("external_services") or {}
    for svc_name, svc_opts in ext_cfg.items():
        if not isinstance(svc_opts, dict) or not svc_opts.get("enabled"):
            continue
        secret_name = svc_opts.get("secret_name", "")
        secret_ns = svc_opts.get("secret_namespace") or (namespaces[0] if namespaces else "default")
        host_key = svc_opts.get("host_key", "")
        port_key = svc_opts.get("port_key")

        if not secret_name:
            report.add(f"external:{svc_name}", False, "No secret_name configured")
            continue

        try:
            secret = core.read_namespaced_secret(secret_name, secret_ns)
        except ApiException as e:
            report.add(
                f"external:{svc_name}",
                False,
                f"Cannot read secret {secret_ns}/{secret_name}: {e.reason}",
            )
            continue

        data = secret.data or {}
        if host_key and host_key not in data:
            report.add(
                f"external:{svc_name}",
                False,
                f"Secret missing key '{host_key}'",
                details=f"secret={secret_ns}/{secret_name}",
            )
            continue

        host_val = _decode_secret_value(data.get(host_key, ""))
        port_val = _decode_secret_value(data.get(port_key, "")) if port_key and port_key in data else None

        _check_external_via_endpoints(core, svc_name, namespaces, report)

        if svc_opts.get("probe_from_pod"):
            _probe_external_from_pod(core, svc_name, host_val, port_val, namespaces, report)
        else:
            detail_parts = [f"host_key={host_key} present in secret"]
            if port_val:
                detail_parts.append(f"port_key={port_key} present")
            report.add(f"external:{svc_name}", True, "Secret credentials found", details="; ".join(detail_parts))


def _decode_secret_value(encoded: str) -> str:
    try:
        return base64.b64decode(encoded).decode("utf-8")
    except Exception:
        return encoded


def _check_external_via_endpoints(
    core: client.CoreV1Api,
    svc_name: str,
    namespaces: list[str],
    report: ValidationReport,
) -> None:
    """Check if a K8s Service matching the external service name has endpoints."""
    for ns in namespaces:
        try:
            ep = core.read_namespaced_endpoints(svc_name, ns)
            subsets = ep.subsets or []
            if subsets:
                addrs = sum(len(s.addresses or []) for s in subsets)
                report.add(
                    f"external_endpoints:{svc_name}/{ns}",
                    True,
                    f"Service has {addrs} endpoint(s)",
                )
                return
        except ApiException:
            pass


def _probe_external_from_pod(
    core: client.CoreV1Api,
    svc_name: str,
    host: str,
    port: Optional[str],
    namespaces: list[str],
    report: ValidationReport,
) -> None:
    """Exec a lightweight connectivity test from a running pod."""
    target_pod = _find_running_pod(core, namespaces)
    if not target_pod:
        report.add(f"external_probe:{svc_name}", False, "No running pod found for exec probe", warning=True)
        return

    pod_name, pod_ns, container = target_pod
    probe_cmds = {
        "postgres": f"pg_isready -h {host}" + (f" -p {port}" if port else ""),
        "redis": f"redis-cli -h {host}" + (f" -p {port}" if port else "") + " ping",
        "clickhouse": f"wget -q -O- http://{host}:{port or '8123'}/ping",
    }
    cmd = probe_cmds.get(svc_name, f"wget -q -O- http://{host}:{port or '80'}/")

    try:
        result = k8s_stream(
            core.connect_get_namespaced_pod_exec,
            pod_name,
            pod_ns,
            container=container,
            command=["/bin/sh", "-c", cmd],
            stderr=True,
            stdout=True,
            stdin=False,
            tty=False,
        )
        report.add(f"external_probe:{svc_name}", True, f"Probe OK from {pod_ns}/{pod_name}", details=result[:200])
    except Exception as e:
        report.add(f"external_probe:{svc_name}", False, f"Probe failed: {e}", warning=True)


def _find_running_pod(core: client.CoreV1Api, namespaces: list[str]) -> Optional[tuple[str, str, str]]:
    """Find a running pod to exec into. Returns (name, namespace, container) or None."""
    for ns in namespaces:
        try:
            pods = core.list_namespaced_pod(ns, field_selector="status.phase=Running")
            for p in pods.items:
                containers = p.spec.containers or []
                if containers:
                    return (p.metadata.name, ns, containers[0].name)
        except ApiException:
            pass
    return None


def check_pod_error_logs(
    core: client.CoreV1Api,
    namespaces: list[str],
    report: ValidationReport,
    options: dict[str, Any],
    exclusions: dict[str, Any],
) -> None:
    opts = options.get("pod_logs") or {}
    tail_lines = opts.get("tail_lines", 100)
    patterns_raw = opts.get("error_patterns") or ["FATAL", "panic:", "OOMKilled"]
    max_matches = opts.get("max_matches_per_pod", 5)

    compiled = [re.compile(p, re.IGNORECASE) for p in patterns_raw]

    for ns in namespaces:
        try:
            pods = core.list_namespaced_pod(ns)
        except ApiException as e:
            report.add(f"pod_logs:{ns}", False, f"Failed to list pods: {e.reason}")
            continue
        for p in pods.items:
            if _matches_exclusions(p.metadata.name, ns, p.metadata.labels or {}, exclusions):
                continue
            phase = p.status.phase if p.status else "Unknown"
            if phase not in ("Running", "Failed", "CrashLoopBackOff"):
                if phase == "Succeeded":
                    continue
            for container in p.spec.containers or []:
                try:
                    logs = core.read_namespaced_pod_log(
                        p.metadata.name,
                        ns,
                        container=container.name,
                        tail_lines=tail_lines,
                    )
                except ApiException:
                    continue
                if not logs:
                    continue
                matches: list[str] = []
                for line in logs.splitlines():
                    if len(matches) >= max_matches:
                        break
                    for pat in compiled:
                        if pat.search(line):
                            matches.append(line.strip()[:200])
                            break
                if matches:
                    report.add(
                        f"pod_logs:{ns}/{p.metadata.name}/{container.name}",
                        False,
                        f"Found {len(matches)} error(s) in logs",
                        details="\n".join(matches),
                        warning=True,
                    )


def check_langsmith_endpoints(
    core: client.CoreV1Api,
    namespaces: list[str],
    report: ValidationReport,
    options: dict[str, Any],
) -> None:
    opts = options.get("endpoints") or {}
    external_url = (opts.get("external_url") or "").rstrip("/")
    external_paths = opts.get("external_paths") or ["/ok"]
    in_cluster_cfg = opts.get("in_cluster") or {}
    in_cluster_enabled = in_cluster_cfg.get("enabled", False)
    timeout = opts.get("timeout_seconds", 10)

    if external_url:
        for path in external_paths:
            url = f"{external_url}{path}"
            try:
                resp = requests.get(url, timeout=timeout, allow_redirects=True)
                if resp.status_code < 400:
                    report.add(f"endpoint_ext:{path}", True, f"GET {url} -> {resp.status_code}")
                else:
                    report.add(
                        f"endpoint_ext:{path}",
                        False,
                        f"GET {url} -> {resp.status_code}",
                        details=resp.text[:200],
                    )
            except requests.RequestException as e:
                report.add(f"endpoint_ext:{path}", False, f"GET {url} failed: {e}")

    if in_cluster_enabled:
        for svc_info in LANGSMITH_SERVICE_HEALTH_MAP:
            svc_name = svc_info["name"]
            port = svc_info["port"]
            path = svc_info["path"]
            for ns in namespaces:
                try:
                    resp_body = core.connect_get_namespaced_service_proxy_with_path(
                        f"{svc_name}:{port}",
                        ns,
                        path.lstrip("/"),
                    )
                    report.add(
                        f"endpoint_cluster:{ns}/{svc_name}{path}",
                        True,
                        f"Service proxy OK",
                        details=str(resp_body)[:200] if resp_body else None,
                    )
                except ApiException as e:
                    report.add(
                        f"endpoint_cluster:{ns}/{svc_name}{path}",
                        False,
                        f"Service proxy failed: {e.reason}",
                        details=str(e.body)[:200] if e.body else None,
                    )
                break


def check_node_capacity(
    core: client.CoreV1Api,
    report: ValidationReport,
    options: dict[str, Any],
) -> None:
    opts = options.get("node_capacity") or {}
    warn_pct = opts.get("warn_threshold_percent", 90)
    check_conditions = opts.get("check_conditions", True)

    try:
        nodes = core.list_node()
    except ApiException as e:
        report.add("node_capacity", False, f"Failed to list nodes: {e.reason}")
        return

    all_pods_by_node: dict[str, list] = {}
    try:
        all_pods = core.list_pod_for_all_namespaces()
        for p in all_pods.items:
            node = p.spec.node_name
            if node:
                all_pods_by_node.setdefault(node, []).append(p)
    except ApiException:
        pass

    for node in nodes.items:
        name = node.metadata.name
        allocatable = node.status.allocatable or {}
        alloc_cpu = _parse_cpu(allocatable.get("cpu", "0"))
        alloc_mem = _parse_memory(allocatable.get("memory", "0"))

        req_cpu = 0.0
        req_mem = 0
        for p in all_pods_by_node.get(name, []):
            for c in p.spec.containers or []:
                res = (c.resources.requests or {}) if c.resources else {}
                req_cpu += _parse_cpu(res.get("cpu", "0"))
                req_mem += _parse_memory(res.get("memory", "0"))

        cpu_pct = (req_cpu / alloc_cpu * 100) if alloc_cpu > 0 else 0
        mem_pct = (req_mem / alloc_mem * 100) if alloc_mem > 0 else 0

        detail = (
            f"cpu: {req_cpu:.1f}/{alloc_cpu:.1f} cores ({cpu_pct:.0f}%), "
            f"memory: {_format_memory(req_mem)}/{_format_memory(alloc_mem)} ({mem_pct:.0f}%)"
        )

        over_threshold = cpu_pct >= warn_pct or mem_pct >= warn_pct
        if over_threshold:
            report.add(f"node_capacity:{name}", False, f"Resource usage high", details=detail, warning=True)
        else:
            report.add(f"node_capacity:{name}", True, detail)

        if check_conditions:
            for cond in node.status.conditions or []:
                if cond.type in NODE_PRESSURE_CONDITIONS and cond.status == "True":
                    report.add(
                        f"node_condition:{name}/{cond.type}",
                        False,
                        f"{cond.type} is True: {cond.message}",
                        warning=True,
                    )


def _parse_cpu(val: str) -> float:
    """Parse K8s CPU quantity (e.g. '500m', '2') to float cores."""
    val = str(val).strip()
    if not val or val == "0":
        return 0.0
    if val.endswith("m"):
        return float(val[:-1]) / 1000.0
    return float(val)


def _parse_memory(val: str) -> int:
    """Parse K8s memory quantity (e.g. '512Mi', '2Gi') to bytes."""
    val = str(val).strip()
    if not val or val == "0":
        return 0
    suffixes = {"Ki": 1024, "Mi": 1024**2, "Gi": 1024**3, "Ti": 1024**4}
    for suffix, multiplier in suffixes.items():
        if val.endswith(suffix):
            return int(float(val[: -len(suffix)]) * multiplier)
    if val.endswith("k"):
        return int(float(val[:-1]) * 1000)
    if val.endswith("M"):
        return int(float(val[:-1]) * 1_000_000)
    if val.endswith("G"):
        return int(float(val[:-1]) * 1_000_000_000)
    return int(val)


def _format_memory(mem_bytes: int) -> str:
    if mem_bytes >= 1024**3:
        return f"{mem_bytes / 1024**3:.1f}Gi"
    if mem_bytes >= 1024**2:
        return f"{mem_bytes / 1024**2:.0f}Mi"
    return f"{mem_bytes}B"


def check_beacon_connectivity(
    core: client.CoreV1Api,
    namespaces: list[str],
    report: ValidationReport,
    options: dict[str, Any],
    exclusions: dict[str, Any],
) -> None:
    opts = options.get("beacon") or {}
    check_pod_logs = opts.get("check_pod_logs", True)

    beacon_enabled = False
    for ns in namespaces:
        try:
            cms = core.list_namespaced_config_map(ns)
        except ApiException:
            continue
        for cm in cms.items:
            if not cm.data:
                continue
            for key in BEACON_ENV_KEYS:
                if cm.data.get(key, "").lower() == "true":
                    beacon_enabled = True
                    break
            if beacon_enabled:
                break
        if beacon_enabled:
            break

    if not beacon_enabled:
        report.add("beacon", True, "Beacon telemetry is disabled — skipping")
        return

    report.add("beacon_config", True, "Beacon telemetry is enabled")

    if not check_pod_logs:
        return

    compiled = [re.compile(p, re.IGNORECASE) for p in BEACON_ERROR_PATTERNS]
    beacon_errors: list[str] = []

    for ns in namespaces:
        try:
            pods = core.list_namespaced_pod(ns, field_selector="status.phase=Running")
        except ApiException:
            continue
        for p in pods.items:
            if _matches_exclusions(p.metadata.name, ns, p.metadata.labels or {}, exclusions):
                continue
            for container in p.spec.containers or []:
                try:
                    logs = core.read_namespaced_pod_log(
                        p.metadata.name, ns, container=container.name, tail_lines=50,
                    )
                except ApiException:
                    continue
                if not logs:
                    continue
                for line in logs.splitlines():
                    for pat in compiled:
                        if pat.search(line):
                            beacon_errors.append(f"{p.metadata.name}/{container.name}: {line.strip()[:200]}")
                            break
                    if len(beacon_errors) >= 10:
                        break

    if beacon_errors:
        report.add(
            "beacon_logs",
            False,
            f"Found {len(beacon_errors)} beacon-related error(s) in pod logs",
            details="\n".join(beacon_errors),
            warning=True,
        )
    else:
        report.add("beacon_logs", True, "No beacon errors found in pod logs")


# -----------------------------------------------------------------------------
# Main run loop
# -----------------------------------------------------------------------------


def run_validations(
    core: client.CoreV1Api,
    apps: client.AppsV1Api,
    batch: client.BatchV1Api,
    netv1: client.NetworkingV1Api,
    custom: Any,
    cfg: dict[str, Any],
    report: ValidationReport,
    cli_options: dict[str, Any],
) -> None:
    namespaces = get_namespaces(cfg, cli_options.get("namespace"))
    exclusions = get_exclusions(cfg)
    resource_checks = get_resource_checks(cfg)

    if not get_namespaces(cfg, cli_options.get("namespace")):
        return  # already validated in main()

    if not cli_options.get("skip_helm_release_checks", False):
        releases = get_helm_releases(cfg)
        if releases:
            check_helm_release_presence(core, apps, releases, report, exclusions)

    check_deployments(apps, namespaces, report, resource_checks, exclusions)
    check_statefulsets(apps, namespaces, report, resource_checks, exclusions)
    check_daemonsets(apps, namespaces, report, resource_checks, exclusions)
    check_pods(core, namespaces, report, resource_checks, exclusions)

    if not cli_options.get("skip_jobs", False):
        check_jobs(batch, namespaces, report, resource_checks, exclusions)

    if not cli_options.get("skip_services", False):
        check_services(
            core,
            namespaces,
            report,
            resource_checks,
            cli_options.get("require_loadbalancer_addresses", False),
            exclusions,
        )

    if not cli_options.get("skip_ingress", False):
        check_ingress(
            netv1,
            custom,
            namespaces,
            report,
            resource_checks,
            cli_options.get("require_ingress_addresses", False),
            exclusions,
        )

    if not cli_options.get("skip_pvcs", False):
        check_pvcs(core, namespaces, report, resource_checks, exclusions)

    if not cli_options.get("skip_secrets", False):
        check_secrets_existence(core, namespaces, report, resource_checks, exclusions)

    if not cli_options.get("skip_external_services", False):
        check_external_services(core, namespaces, report, resource_checks, exclusions)

    if not cli_options.get("skip_pod_logs", False) and (resource_checks.get("pod_logs") or {}).get("enabled"):
        check_pod_error_logs(core, namespaces, report, resource_checks, exclusions)

    if not cli_options.get("skip_endpoints", False):
        ep_cfg = resource_checks.get("endpoints") or {}
        if ep_cfg.get("external_url") or (ep_cfg.get("in_cluster") or {}).get("enabled"):
            check_langsmith_endpoints(core, namespaces, report, resource_checks)

    if not cli_options.get("skip_node_capacity", False):
        check_node_capacity(core, report, resource_checks)

    if not cli_options.get("skip_beacon", False) and (resource_checks.get("beacon") or {}).get("enabled"):
        check_beacon_connectivity(core, namespaces, report, resource_checks, exclusions)


def print_report(report: ValidationReport) -> None:
    failed = report.failed()
    for r in report.results:
        if not r.passed:
            print(f"  FAIL  {r.name}: {r.message}", file=sys.stderr)
            if r.details:
                print(f"        {r.details}", file=sys.stderr)
        elif r.warning:
            print(f"  WARN  {r.name}: {r.message}", file=sys.stderr)
        else:
            print(f"  OK    {r.name}: {r.message}", file=sys.stderr)
    print("", file=sys.stderr)
    print(f"--- Summary ({report.elapsed_seconds():.1f}s) ---", file=sys.stderr)
    total = len(report.results)
    passed = total - len(failed)
    print(f"  Passed: {passed}/{total}", file=sys.stderr)
    if failed:
        print(f"  Failed: {len(failed)}", file=sys.stderr)
        for r in failed:
            print(f"    - {r.name}: {r.message}", file=sys.stderr)


# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------


@click.command()
@click.option(
    "--kubeconfig",
    type=click.Path(exists=False),
    default=None,
    help="Path to kubeconfig (default: KUBECONFIG env or ~/.kube/config)",
)
@click.option("--context", "kube_context", type=str, default=None, help="Kubernetes context name")
@click.option("--config", "config_path", type=click.Path(exists=True), required=True, help="Path to validation config YAML")
@click.option("--timeout-seconds", type=int, default=DEFAULT_TIMEOUT_SECONDS, help="Max time to run validations")
@click.option("--poll-seconds", type=int, default=DEFAULT_POLL_SECONDS, help="Seconds between poll rounds")
@click.option("--fail-fast", is_flag=True, default=False, help="Stop on first failure")
@click.option("--json-logs", is_flag=True, default=False, help="Emit logs as JSON lines")
@click.option("--namespace", type=str, default=None, help="Override namespaces: check only this namespace")
@click.option("--require-loadbalancer-addresses", is_flag=True, default=False, help="Require LoadBalancer Services to have addresses")
@click.option("--require-ingress-addresses", is_flag=True, default=False, help="Require Ingress/Gateway to have addresses")
@click.option("--skip-helm-release-checks", is_flag=True, default=False, help="Skip Helm release presence checks")
@click.option("--skip-jobs", is_flag=True, default=False, help="Skip Job completion checks")
@click.option("--skip-ingress", is_flag=True, default=False, help="Skip Ingress/Gateway checks")
@click.option("--skip-services", is_flag=True, default=False, help="Skip Service checks")
@click.option("--skip-pvcs", is_flag=True, default=False, help="Skip PersistentVolumeClaim checks")
@click.option("--skip-secrets", is_flag=True, default=False, help="Skip Secrets existence checks")
@click.option("--skip-external-services", is_flag=True, default=False, help="Skip external service connectivity checks")
@click.option("--skip-pod-logs", is_flag=True, default=False, help="Skip pod error log scanning")
@click.option("--skip-endpoints", is_flag=True, default=False, help="Skip LangSmith HTTP endpoint liveness checks")
@click.option("--skip-node-capacity", is_flag=True, default=False, help="Skip node capacity checks")
@click.option("--skip-beacon", is_flag=True, default=False, help="Skip beacon connectivity checks")
@click.option("--dry-run", is_flag=True, default=False, help="Validate config and show check plan without connecting to K8s")
def main(
    kubeconfig: Optional[str],
    kube_context: Optional[str],
    config_path: str,
    timeout_seconds: int,
    poll_seconds: int,
    fail_fast: bool,
    json_logs: bool,
    namespace: Optional[str],
    require_loadbalancer_addresses: bool,
    require_ingress_addresses: bool,
    skip_helm_release_checks: bool,
    skip_jobs: bool,
    skip_ingress: bool,
    skip_services: bool,
    skip_pvcs: bool,
    skip_secrets: bool,
    skip_external_services: bool,
    skip_pod_logs: bool,
    skip_endpoints: bool,
    skip_node_capacity: bool,
    skip_beacon: bool,
    dry_run: bool,
) -> None:
    """Post-apply validation for Kubernetes (Terraform + Helm)."""
    setup_logging(json_logs)
    logger = logging.getLogger(__name__)

    cli_options = {
        "namespace": namespace,
        "require_loadbalancer_addresses": require_loadbalancer_addresses,
        "require_ingress_addresses": require_ingress_addresses,
        "skip_helm_release_checks": skip_helm_release_checks,
        "skip_jobs": skip_jobs,
        "skip_ingress": skip_ingress,
        "skip_services": skip_services,
        "skip_pvcs": skip_pvcs,
        "skip_secrets": skip_secrets,
        "skip_external_services": skip_external_services,
        "skip_pod_logs": skip_pod_logs,
        "skip_endpoints": skip_endpoints,
        "skip_node_capacity": skip_node_capacity,
        "skip_beacon": skip_beacon,
    }

    try:
        cfg = load_config(config_path)
    except FileNotFoundError as e:
        logger.error(str(e))
        sys.exit(2)

    if dry_run:
        sys.exit(run_dry_run(cfg, cli_options))

    namespaces = get_namespaces(cfg, namespace)
    if not namespaces:
        logger.error("No namespaces to check: set 'namespaces' in config or pass --namespace")
        sys.exit(2)

    try:
        core, apps, batch, netv1, custom = load_kubeconfig(kubeconfig, kube_context)
    except (FileNotFoundError, RuntimeError) as e:
        logger.error(str(e))
        sys.exit(2)

    report = ValidationReport()
    deadline = time.monotonic() + timeout_seconds

    while time.monotonic() < deadline:
        report.results.clear()
        report.start_time = time.monotonic()

        if not check_cluster_connectivity(core, report):
            print_report(report)
            sys.exit(1)

        run_validations(core, apps, batch, netv1, custom, cfg, report, cli_options)

        if report.passed_all():
            print_report(report)
            sys.exit(0)

        if fail_fast:
            print_report(report)
            sys.exit(1)

        logger.info("Some checks failed; retrying in %ds (timeout in %.0fs)", poll_seconds, deadline - time.monotonic())
        time.sleep(poll_seconds)

    print_report(report)
    logger.error("Validation timed out after %d seconds", timeout_seconds)
    sys.exit(1)


if __name__ == "__main__":
    main()
