#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# init-values.sh — Write the Helm values files for LangSmith on bare metal.
#
# Usage (from baremetal/):   make init-values
#
# Reads:
#   terraform outputs   langsmith_helm_values, smithdb_helm_values, features
#   terraform.tfvars    sizing_profile
#   infra/.secrets.env  INITIAL_ORG_ADMIN_EMAIL (written by make setup-env)
#
# Writes helm/values/ (gitignored, no secrets):
#   langsmith-values-overrides.yaml        hostname, gateway         (every run)
#   langsmith-values-admin.yaml            initial admin email       (every run)
#   langsmith-values-smithdb.yaml          SmithDB sizing + wiring   (every run)
#   langsmith-values-sizing-<profile>.yaml app sizing                (copied once)
#   langsmith-values-<feature>.yaml        enabled features          (copied once)
#
# Copied-once files keep your edits; delete one to get the example back.
# Secrets never go into these files: they live in the langsmith-config Secret
# (deploy.sh) and the datastore Secrets (Terraform).

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  bash "${BASH_SOURCE[0]}" ${@+"$@"}
  return $?
fi
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INFRA_DIR="$(cd "$HELM_DIR/../infra" && pwd)"
VALUES_DIR="$HELM_DIR/values"
EXAMPLES_DIR="$VALUES_DIR/examples"
export INFRA_DIR
# shellcheck source=../../infra/scripts/_common.sh
source "$INFRA_DIR/scripts/_common.sh"

_tf_output_raw() {
  terraform -chdir="$INFRA_DIR" output -raw "$1" 2>/dev/null
}

# Write terraform output NAME (an object) to FILE as plain block YAML.
# Terraform's yamlencode quotes every key, so the object is formatted here
# instead, with the Python standard library only (no PyYAML or yq needed).
# Keys stay in Terraform's (sorted) order. A string is written bare only when
# YAML can't read it as anything else; otherwise it gets JSON double quotes,
# which YAML reads the same way. So "2" (CPU) and "5432" (port) stay strings.
_tf_output_yaml() {
  local name="$1" file="$2" json
  json="$(terraform -chdir="$INFRA_DIR" output -json "$name" 2>/dev/null)" || return 1
  printf '%s' "$json" | python3 -I -c '
import json, re, sys

src = sys.argv[1]
data = json.load(sys.stdin)
if not isinstance(data, dict):
    sys.exit(2)  # state still holds the old yamlencode string: run make apply

PLAIN = re.compile(r"^[A-Za-z_/][A-Za-z0-9_./:-]*$")
QUANTITY = re.compile(r"^[0-9]+(\.[0-9]+)?[A-Za-z]+$")  # 500m, 10Gi: never a number
KEYWORDS = {"true", "false", "yes", "no", "on", "off", "y", "n", "null", "~"}

# Section headers, in the style of the sizing files. Keyed by key path.
SECTIONS = {
    "smithdb.clusterManager": "Cluster manager: routes each tenant to an ingestion/query pod",
    "smithdb.compaction": "Compaction scheduler: plans merges, TTL and GC (no cache)",
    "smithdb.compactionWorker": "Compaction worker: merges files (cache = emptyDir)",
    "smithdb.config": "Wiring: metastore (postgres-smithdb) + object store (RustFS)",
    "smithdb.enabled": "SmithDB on",
    "smithdb.ingestion": "Ingestion: writes traces (cache = emptyDir)",
    "smithdb.langsmith": "LangSmith gates: ingest + query through SmithDB, no ClickHouse migration",
    "smithdb.query": "Query: reads traces (cache = emptyDir)",
    "smithdb.resourceTier": "Base tier; every component above overrides its resources",
    "config": "Hostname LangSmith builds its URLs from",
    "gateway": "Envoy Gateway the chart attaches its HTTPRoute to",
}

def section(path, pad, out):
    title = SECTIONS.get(path)
    if title:
        rule = "-" * max(3, 78 - len(pad) - len(title) - 6)
        out.append("")
        out.append(f"{pad}# -- {title} {rule}")

def scalar(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if v is None:
        return "null"
    if isinstance(v, (int, float)):
        return json.dumps(v)
    if QUANTITY.match(v):
        return v
    if PLAIN.match(v) and v.lower() not in KEYWORDS and ": " not in v and not v.endswith(":"):
        return v
    return json.dumps(v)

def emit(v, indent, out, path=""):
    pad = "  " * indent
    if isinstance(v, dict):
        for k, item in v.items():
            here = f"{path}.{k}" if path else k
            section(here, pad, out)
            if isinstance(item, (dict, list)) and item:
                out.append(f"{pad}{scalar(k)}:")
                emit(item, indent + 1, out, here)
            else:
                out.append(f"{pad}{scalar(k)}: {empty_or_scalar(item)}")
    else:
        for item in v:
            if isinstance(item, (dict, list)) and item:
                sub = []
                emit(item, indent + 1, sub, path + "[]")
                first = sub[0][len(pad) + 2:]
                out.append(f"{pad}- {first}")
                out.extend(sub[1:])
            else:
                out.append(f"{pad}- {empty_or_scalar(item)}")

def empty_or_scalar(v):
    if isinstance(v, dict):
        return "{}"
    if isinstance(v, list):
        return "[]"
    return scalar(v)

out = [f"# Generated by make init-values from terraform output {src}.",
       "# Rewritten on every run: change Terraform variables, not this file."]
emit(data, 0, out)
print("\n".join(out))
' "$name" > "$file"
}

header "LangSmith Helm values → $VALUES_DIR"

# ── Preconditions ────────────────────────────────────────────────────────────
command -v terraform >/dev/null || { fail "terraform not found"; exit 1; }
command -v python3 >/dev/null || { fail "python3 not found (used to read terraform output -json)"; exit 1; }
if ! _tf_output_raw langsmith_url >/dev/null; then
  fail "terraform output langsmith_url is missing — run make apply first."
  exit 1
fi

# ── Every run: values Terraform computes ─────────────────────────────────────
for pair in "langsmith_helm_values:langsmith-values-overrides.yaml" \
            "smithdb_helm_values:langsmith-values-smithdb.yaml"; do
  if ! _tf_output_yaml "${pair%%:*}" "$VALUES_DIR/${pair#*:}"; then
    fail "terraform output ${pair%%:*} is missing or still a YAML string — run make apply first."
    exit 1
  fi
done
pass "langsmith-values-overrides.yaml (hostname $(_tf_output_raw langsmith_url))"
pass "langsmith-values-smithdb.yaml (SmithDB → RustFS + postgres-smithdb)"

# ── Every run: admin email (from the secrets file, kept out of Terraform) ────
admin_email="$(_secret_get INITIAL_ORG_ADMIN_EMAIL)"
if [[ -z "$admin_email" ]]; then
  fail "INITIAL_ORG_ADMIN_EMAIL is not in $SECRETS_FILE — run make setup-env first."
  exit 1
fi
if ! reason="$(_validate_email "$admin_email")"; then
  fail "INITIAL_ORG_ADMIN_EMAIL $reason"
  exit 1
fi
# JSON is valid YAML, and json.dumps quotes the value correctly.
python3 -I -c 'import json,sys; print(json.dumps({"config": {"initialOrgAdminEmail": sys.argv[1]}}, indent=2))' \
  "$admin_email" > "$VALUES_DIR/langsmith-values-admin.yaml"
pass "langsmith-values-admin.yaml (initial org admin)"

# ── Copied once: app sizing for the profile ──────────────────────────────────
profile="$(_parse_tfvar sizing_profile)"
profile="${profile:-minimum}"
# lab uses the dev app sizing (it differs from dev only in its SmithDB tier).
sizing_source="$profile"
[[ "$profile" == "lab" ]] && sizing_source="dev"
sizing_file="$VALUES_DIR/langsmith-values-sizing-$profile.yaml"
if [[ -f "$sizing_file" ]]; then
  skip "langsmith-values-sizing-$profile.yaml exists (kept; delete it to reset)"
else
  cp "$EXAMPLES_DIR/langsmith-values-sizing-$sizing_source.yaml" "$sizing_file"
  pass "langsmith-values-sizing-$profile.yaml (from examples/…-$sizing_source.yaml)"
fi

# ── Copied once: enabled features (same files and order as modules/gcp) ──────
features_json="$(terraform -chdir="$INFRA_DIR" output -json features)"
enabled="$(python3 -I -c '
import json, sys
f = json.loads(sys.argv[1])
names = []
if f.get("deployments"): names.append("agent-deploys")
for name, file in (("fleet", "fleet"), ("polly", "standalone-polly"), ("insights", "standalone-insights")):
    if name in f.get("standalone", {}): names.append(file)
print(" ".join(names))
' "$features_json")"

for feature in agent-deploys fleet standalone-polly standalone-insights; do
  file="$VALUES_DIR/langsmith-values-$feature.yaml"
  if [[ " $enabled " == *" $feature "* ]]; then
    if [[ -f "$file" ]]; then
      skip "langsmith-values-$feature.yaml exists (kept)"
    else
      cp "$EXAMPLES_DIR/langsmith-values-$feature.yaml" "$file"
      pass "langsmith-values-$feature.yaml (feature enabled)"
    fi
  else
    skip "$feature off"
  fi
done

header "Done"
info "No secrets were written to $VALUES_DIR."
action "Next: make deploy"
