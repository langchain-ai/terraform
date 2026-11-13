#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

set -euo pipefail
# create-tls-secret.sh — Create the langsmith-tls Kubernetes secret.
#
# WARNING: SELF-SIGNED — FOR TESTING/DEMO ONLY. Clients will not trust this cert.
#   For production, replace langsmith-tls with a certificate from your own CA
#   (for example one exported from Azure Key Vault): re-run this script with
#   --cert/--key, or manage the secret yourself. See DEPLOYMENT.md.
#
# Usage:
#   cd terraform/modules/azure-private/infra
#   ./scripts/create-tls-secret.sh [--hostname langsmith.example.internal]
#   ./scripts/create-tls-secret.sh --cert path/to/tls.crt --key path/to/tls.key
#
# Prerequisites:
#   - az aks get-credentials run (kubectl context set to the target cluster)
#   - langsmith namespace exists (created by the bootstrap/ apply)
#   - openssl + kubectl on PATH
#
# What this creates:
#   langsmith-tls — a kubernetes.io/tls secret. The LangSmith Helm chart
#                   references it via ingress.tls[].secretName: langsmith-tls.
#
# Safe to re-run — uses --dry-run=client | kubectl apply, so it updates in place.

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SECRET_NAME="langsmith-tls"
CERT_HOSTNAME="langsmith.local"
CERT_FILE=""
KEY_FILE=""

# ── Parse args ─────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname) CERT_HOSTNAME="$2"; shift 2 ;;
    --cert)     CERT_FILE="$2"; shift 2 ;;
    --key)      KEY_FILE="$2"; shift 2 ;;
    -h|--help)  grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ── Resolve namespace ──────────────────────────────────────────────────────────
NAMESPACE=$(cd "$INFRA_DIR" && terraform output -raw langsmith_namespace 2>/dev/null) || NAMESPACE="langsmith"

echo ""
echo "LangSmith — create TLS secret ($SECRET_NAME)"
echo "  namespace : $NAMESPACE"

# ── Obtain certificate + key ───────────────────────────────────────────────────
# Restrict permissions on any files we create (private key must not be world/group
# readable) and always clean up the temp dir on exit. Key material is never echoed.
umask 077

if [[ -z "$CERT_FILE" || -z "$KEY_FILE" ]]; then
  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT
  CERT_FILE="$TMP_DIR/tls.crt"
  KEY_FILE="$TMP_DIR/tls.key"

  echo "  cert      : self-signed (CN/SAN=$CERT_HOSTNAME, RSA 2048, 365d)"
  echo -e "  ${RED}WARNING${NC}: self-signed certificate — testing only, not trusted by clients."
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$KEY_FILE" -out "$CERT_FILE" \
    -days 365 -subj "/CN=$CERT_HOSTNAME" \
    -addext "subjectAltName=DNS:$CERT_HOSTNAME" >/dev/null 2>&1
else
  echo "  cert      : provided ($CERT_FILE)"
  [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]] || {
    echo -e "  ${RED}ERROR${NC}: --cert / --key file not found." >&2
    exit 1
  }
fi

# ── Create/update the secret ───────────────────────────────────────────────────
echo "  Applying $SECRET_NAME to namespace/$NAMESPACE..."
kubectl create secret tls "$SECRET_NAME" \
  --namespace "$NAMESPACE" \
  --cert="$CERT_FILE" \
  --key="$KEY_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo -e "  ${GREEN}[OK]${NC} $SECRET_NAME present in namespace/$NAMESPACE"
  echo -e "  ${GREEN}Ready.${NC} Reference it in Helm values: ingress.tls[].secretName: $SECRET_NAME"
else
  echo -e "  ${RED}[FAIL]${NC} $SECRET_NAME not found after apply." >&2
  exit 1
fi
