#!/usr/bin/env bash
# Infrastructure is applied before the application Service exists. Bind after
# Helm deploys it, and let Kubernetes remove the binding with that Service.
set -euo pipefail

target_group_arn="${1:?target group ARN is required}"
namespace="${2:?release namespace is required}"
release_name="${3:?release name is required}"
[[ "$target_group_arn" =~ ^arn:[a-z0-9-]+:elasticloadbalancing:[a-z0-9-]+:[0-9]{12}:targetgroup/[a-zA-Z0-9-]+/[a-zA-Z0-9]+$ ]] || {
  echo "ERROR: invalid frontend target group ARN; apply infrastructure first." >&2
  exit 1
}

# Discover Helm fullname/name overrides from the live Service. Named targetPort
# is the chart contract; the binding uses the Service port, not container port.
manifest=$(kubectl get services -n "$namespace" -l "app.kubernetes.io/instance=$release_name" -o json |
  python3 -c '
import json, sys
services = [s for s in json.load(sys.stdin)["items"]
            if any(p.get("targetPort") == "frontend" and p.get("name") == "http"
                   for p in s["spec"].get("ports", []))]
if len(services) != 1 or services[0]["spec"].get("type", "ClusterIP") != "ClusterIP":
    sys.exit("ERROR: expected one ClusterIP frontend Service. Run make init-values and make deploy with a supported chart.")
service = services[0]["metadata"]
json.dump({
    "apiVersion": "elbv2.k8s.aws/v1beta1", "kind": "TargetGroupBinding",
    "metadata": {
        "name": service["name"] + "-alb", "namespace": sys.argv[2],
        "ownerReferences": [{"apiVersion": "v1", "kind": "Service",
                             "name": service["name"], "uid": service["uid"]}]
    },
    "spec": {"serviceRef": {"name": service["name"], "port": "http"},
             "targetGroupARN": sys.argv[1], "targetType": "ip"}
}, sys.stdout)
' "$target_group_arn" "$namespace")
binding_name=$(printf '%s' "$manifest" |
  python3 -c 'import json, sys; print(json.load(sys.stdin)["metadata"]["name"])')
current_arn=$(kubectl get targetgroupbinding "$binding_name" \
  -n "$namespace" --ignore-not-found \
  -o jsonpath='{.spec.targetGroupARN}')

# The controller treats the target group ARN as immutable.
if [[ -n "$current_arn" && "$current_arn" != "$target_group_arn" ]]; then
  kubectl delete targetgroupbinding "$binding_name" \
    -n "$namespace" --wait=true --timeout=120s
fi

printf '%s\n' "$manifest" | kubectl apply -f -
