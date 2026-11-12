#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# init-values.sh — Write the Helm values files for LangSmith on bare metal.
#
# Usage (from baremetal/):   make init-values
#
# Reads:
#   terraform outputs   langsmith_helm_values, smithdb_helm_values, values_files
#   terraform.tfvars    langsmith_admin_email (else infra/.secrets.env INITIAL_ORG_ADMIN_EMAIL)
#
# Writes helm/values/ (gitignored, no secrets):
#   langsmith-values-overrides.yaml        hostname, gateway         (every run)
#   langsmith-values-admin.yaml            initial admin email       (every run)
#   langsmith-values-smithdb.yaml          SmithDB sizing + wiring   (every run)
#   langsmith-values-sizing-<profile>.yaml app sizing                (every run, from examples/)
#   langsmith-values-<feature>.yaml        enabled features          (copied once)
#
# Copied-once files keep your edits; delete one to get the example back. The sizing file is the one the
# budget gate counted at make apply, so it is never edited: tuning goes in langsmith-values-local.yaml,
# which the budget counts too.
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

# ── Every run: admin email (terraform.tfvars, as on the cloud modules; else the secrets file) ──
admin_email="$(_parse_tfvar langsmith_admin_email)"
[[ -n "$admin_email" ]] || admin_email="$(_secret_get INITIAL_ORG_ADMIN_EMAIL)"
if [[ -z "$admin_email" ]]; then
  fail "no admin email: set langsmith_admin_email in terraform.tfvars, or run make setup-env."
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

# _sizing_write SRC DEST LABEL: SRC behind a first line naming it and the hash of what follows.
_sizing_write() {
  python3 -I -c '
import hashlib, sys
body = open(sys.argv[1], "rb").read()
head = f"# Generated by make init-values from {sys.argv[3]}, sha256 {hashlib.sha256(body).hexdigest()}. Not edited: tuning goes in langsmith-values-local.yaml.\n"
open(sys.argv[2], "wb").write(head.encode() + body)
' "$1" "$2" "$3"
}

# _sizing_unedited FILE EXAMPLE: true when FILE is what _sizing_write wrote, or a copy from before the
# header existed that still equals EXAMPLE.
_sizing_unedited() {
  python3 -I -c '
import hashlib, re, sys
data = open(sys.argv[1], "rb").read()
first, _, body = data.partition(b"\n")
m = re.search(rb"sha256 ([0-9a-f]{64})", first)
if m:
    sys.exit(0 if hashlib.sha256(body).hexdigest().encode() == m.group(1) else 1)
sys.exit(0 if data == open(sys.argv[2], "rb").read() else 1)
' "$1" "$2"
}

# ── App sizing (every run) and enabled features (copied once), as deploy.sh will layer them ──
# The files come from Terraform's list (output values_files).
values_files="$(terraform -chdir="$INFRA_DIR" output -json values_files | python3 -I -c 'import json, sys; print(" ".join(json.load(sys.stdin)))')"
for name in $values_files; do
  source_name="$name"
  # lab uses the dev app sizing (it differs from dev only in its SmithDB tier).
  [[ "$name" == "langsmith-values-sizing-lab.yaml" ]] && source_name="langsmith-values-sizing-dev.yaml"
  [[ -f "$EXAMPLES_DIR/$source_name" ]] || continue
  # The budget gate reads the example, so a copy edited by hand deployed more than it counted and the
  # pods sat Pending after a green plan (Dzmitry Dubarau's review of #488). The file is rewritten every
  # run, with the hash of what was written in its first line: an unedited file from an older example is
  # replaced, and only an edit stops the run, since comparing with the current example refused every
  # unedited copy after a module upgrade.
  if [[ "$name" == langsmith-values-sizing-*.yaml ]]; then
    if [[ -f "$VALUES_DIR/$name" ]] && ! _sizing_unedited "$VALUES_DIR/$name" "$EXAMPLES_DIR/$source_name"; then
      fail "$name differs from what make init-values wrote; the budget gate counts examples/$source_name, not it"
      fail "Move any change of yours to helm/values/langsmith-values-local.yaml (the budget counts it), delete $name, rerun."
      exit 1
    fi
    _sizing_write "$EXAMPLES_DIR/$source_name" "$VALUES_DIR/$name" "examples/$source_name"
    pass "$name (from examples/$source_name)"
    continue
  fi
  if [[ -f "$VALUES_DIR/$name" ]]; then
    skip "$name exists (kept; delete it to reset)"
  else
    cp "$EXAMPLES_DIR/$source_name" "$VALUES_DIR/$name"
    pass "$name (from examples/$source_name)"
  fi
done

header "Done"
info "No secrets were written to $VALUES_DIR."
action "Next: make deploy"
