#!/usr/bin/env bash
# Logs into an OpenShift cluster and sets the current kubeconfig context.
set -euo pipefail

API_URL="${1:-}"
USERNAME="${2:-}"

if [[ -z "$API_URL" ]]; then
  echo "Usage: $0 <api-url> [username]" >&2
  echo "  Example: $0 https://api.cluster.example.com:6443 kubeadmin" >&2
  echo "" >&2
  echo "  For token-based login, run: oc login <api-url> --token=<token>" >&2
  exit 1
fi

if [[ -n "$USERNAME" ]]; then
  oc login "$API_URL" -u "$USERNAME"
else
  oc login "$API_URL"
fi

echo "Done. Current context: $(kubectl config current-context)"
