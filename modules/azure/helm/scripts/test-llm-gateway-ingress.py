#!/usr/bin/env python3
# MIT License - Copyright (c) 2026 LangChain, Inc.
"""Unit tests for llm-gateway-ingress.py against Ingresses shaped like chart 0.17's.

Run: python3 helm/scripts/test-llm-gateway-ingress.py
"""

import importlib.util
import pathlib
import sys

_spec = importlib.util.spec_from_file_location(
    "gw", pathlib.Path(__file__).with_name("llm-gateway-ingress.py")
)
gw = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gw)


def chart_ingress(cls, annotations, path="/", host="ls.example.com", tls=True):
    spec = {
        "ingressClassName": cls,
        "rules": [{
            "host": host,
            "http": {"paths": [{
                "path": path,
                "pathType": "Prefix",
                "backend": {"service": {"name": "langsmith-frontend", "port": {"number": 80}}},
            }]},
        }],
    }
    if tls:
        spec["tls"] = [{"secretName": "langsmith-tls", "hosts": [host]}]
    return {
        "metadata": {
            "name": "langsmith-ingress",
            "namespace": "langsmith",
            "labels": {"app.kubernetes.io/instance": "langsmith"},
            "annotations": dict(
                {"helm.sh/chart": "langsmith-0.17.0-rc.42", "app.kubernetes.io/managed-by": "Helm",
                 "meta.helm.sh/release-name": "langsmith",
                 "external-dns.alpha.kubernetes.io/hostname": host},
                **annotations,
            ),
        },
        "spec": spec,
    }


CASES = []


def case(fn):
    CASES.append(fn)
    return fn


@case
def nginx_gets_only_the_timeouts_and_keeps_tls():
    out = gw.build(chart_ingress("nginx", {"cert-manager.io/cluster-issuer": "letsencrypt-prod"}), "nginx", "langsmith-llm-gateway")
    ann = out["metadata"]["annotations"]
    assert ann == {
        "nginx.ingress.kubernetes.io/proxy-read-timeout": "900",
        "nginx.ingress.kubernetes.io/proxy-send-timeout": "900",
    }, ann
    assert out["spec"]["tls"] == [{"secretName": "langsmith-tls", "hosts": ["ls.example.com"]}]
    assert out["spec"]["ingressClassName"] == "nginx"
    path = out["spec"]["rules"][0]["http"]["paths"][0]
    assert path["path"] == "/gateway/" and path["pathType"] == "Prefix", path
    assert path["backend"]["service"]["name"] == "langsmith-frontend"


@case
def agic_keeps_the_health_probe_and_gets_the_request_timeout():
    out = gw.build(chart_ingress("azure-application-gateway", {
        "appgw.ingress.kubernetes.io/health-probe-path": "/health",
        "appgw.ingress.kubernetes.io/health-probe-status-codes": "200-399",
    }), "agic", "langsmith-llm-gateway")
    ann = out["metadata"]["annotations"]
    assert ann == {
        "appgw.ingress.kubernetes.io/health-probe-path": "/health",
        "appgw.ingress.kubernetes.io/health-probe-status-codes": "200-399",
        "appgw.ingress.kubernetes.io/request-timeout": "900",
    }, ann


@case
def a_subdomain_prefixes_the_gateway_path():
    out = gw.build(chart_ingress("nginx", {}, path="/langsmith"), "nginx", "x")
    assert out["spec"]["rules"][0]["http"]["paths"][0]["path"] == "/langsmith/gateway/"


@case
def no_tls_and_no_host_are_left_out_rather_than_emptied():
    out = gw.build(chart_ingress("nginx", {}, host="", tls=False), "nginx", "x")
    assert "tls" not in out["spec"], out["spec"]
    assert "host" not in out["spec"]["rules"][0], out["spec"]["rules"][0]


@case
def labels_mark_the_object_as_the_deploy_scripts():
    out = gw.build(chart_ingress("nginx", {}), "nginx", "langsmith-llm-gateway")
    assert out["metadata"]["name"] == "langsmith-llm-gateway"
    assert out["metadata"]["namespace"] == "langsmith"
    assert out["metadata"]["labels"]["app.kubernetes.io/managed-by"] == "langsmith-azure-deploy"


failed = 0
for fn in CASES:
    try:
        fn()
        print(f"  PASS  {fn.__name__}")
    except AssertionError as e:
        failed += 1
        print(f"  FAIL  {fn.__name__}: {e}")
print(f"\npassed={len(CASES) - failed} failed={failed}")
sys.exit(1 if failed else 0)
