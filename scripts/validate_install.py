#!/usr/bin/env python3
"""
Post-apply validation script for Kubernetes deployments (Terraform + Helm).
Validates cluster connectivity, Helm releases, workloads, Jobs, Services, and optional Ingress/Gateway.
Read-only and idempotent.
"""

from __future__ import annotations

import json
import logging
import os
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

import click
import yaml
from kubernetes import client, config
from kubernetes.client.rest import ApiException

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
DEFAULT_KUBECONFIG = os.path.expanduser("~/.kube/config")
DEFAULT_TIMEOUT_SECONDS = 900
DEFAULT_POLL_SECONDS = 10
BAD_POD_REASONS = {"CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "CreateContainerConfigError"}

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
    }

    try:
        cfg = load_config(config_path)
    except FileNotFoundError as e:
        logger.error(str(e))
        sys.exit(2)

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

        # Connectivity is checked fresh each round (result added to report)
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
