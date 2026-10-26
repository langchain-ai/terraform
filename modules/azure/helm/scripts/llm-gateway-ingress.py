#!/usr/bin/env python3
# MIT License - Copyright (c) 2026 LangChain, Inc.
"""Build the LLM Gateway's own Ingress from the chart's LangSmith Ingress.

The chart's frontend proxy allows 900 s on /gateway/ for long model calls, but
the ingress controller in front of it cuts requests sooner: ingress-nginx at
60 s, Application Gateway at 30 s. Raising the timeout on the chart's Ingress
would raise it for every LangSmith path, so a hung request anywhere could hold
a connection for fifteen minutes. Instead this builds a second Ingress for the
same host with only the /gateway/ path and the longer timeout. Both
controllers merge Ingresses for one host and route by the longest matching
path, so every other path keeps the controller's default.

The new Ingress copies the chart's class, TLS block, host and frontend backend,
and its annotations (so AGIC's health-probe override carries over), minus the
ones that belong to one object only: cert-manager's, so no second Certificate
is created for the same secret, external-dns's, Helm's and the chart's labels.

Reads the chart's Ingress as JSON on stdin; writes the new one as JSON on
stdout. Usage:

  kubectl get ingress <release>-ingress -n <ns> -o json \\
    | llm-gateway-ingress.py --controller nginx --name <release>-llm-gateway \\
    | kubectl apply -f -
"""

import argparse
import json
import sys

TIMEOUT_SECONDS = "900"

TIMEOUT_ANNOTATIONS = {
    "nginx": {
        "nginx.ingress.kubernetes.io/proxy-read-timeout": TIMEOUT_SECONDS,
        "nginx.ingress.kubernetes.io/proxy-send-timeout": TIMEOUT_SECONDS,
    },
    "agic": {
        "appgw.ingress.kubernetes.io/request-timeout": TIMEOUT_SECONDS,
    },
}

# Annotations that must stay on the chart's Ingress alone. The chart also copies
# its labels into annotations (helm.sh/chart, app.kubernetes.io/managed-by: Helm),
# and those would misstate who owns this object.
DROPPED_PREFIXES = (
    "helm.sh/",
    "app.kubernetes.io/",
    "cert-manager.io/",
    "acme.cert-manager.io/",
    "external-dns.alpha.kubernetes.io/",
    "meta.helm.sh/",
    "kubectl.kubernetes.io/",
)


def build(src, controller, name):
    meta = src["metadata"]
    spec = src["spec"]
    rule = spec["rules"][0]
    first_path = rule["http"]["paths"][0]

    annotations = {
        k: v
        for k, v in (meta.get("annotations") or {}).items()
        if not k.startswith(DROPPED_PREFIXES)
    }
    annotations.update(TIMEOUT_ANNOTATIONS[controller])

    # The chart routes /<subdomain> to the frontend, "/" by default; the
    # frontend proxies <that>/gateway/ to the gateway pod.
    prefix = first_path["path"].rstrip("/") + "/gateway/"

    out_rule = {
        "http": {
            "paths": [
                {
                    "path": prefix,
                    "pathType": "Prefix",
                    "backend": first_path["backend"],
                }
            ]
        }
    }
    if rule.get("host"):
        out_rule["host"] = rule["host"]

    out_spec = {"rules": [out_rule]}
    if spec.get("ingressClassName"):
        out_spec["ingressClassName"] = spec["ingressClassName"]
    if spec.get("tls"):
        out_spec["tls"] = spec["tls"]

    return {
        "apiVersion": "networking.k8s.io/v1",
        "kind": "Ingress",
        "metadata": {
            "name": name,
            "namespace": meta["namespace"],
            "labels": {
                "app.kubernetes.io/managed-by": "langsmith-azure-deploy",
                "app.kubernetes.io/part-of": meta.get("labels", {}).get(
                    "app.kubernetes.io/instance", "langsmith"
                ),
            },
            "annotations": annotations,
        },
        "spec": out_spec,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--controller", required=True, choices=sorted(TIMEOUT_ANNOTATIONS))
    parser.add_argument("--name", required=True)
    args = parser.parse_args()
    json.dump(build(json.load(sys.stdin), args.controller, args.name), sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
