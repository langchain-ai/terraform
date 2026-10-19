#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# _common.sh — Shared helpers for Azure LangSmith scripts.
#
# Usage: source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
#
# Provides:
#   _parse_tfvar <key>              — Read a value from terraform.tfvars
#   _parse_tfvar_quoted <key> <f>   — Read a quoted value, spaces intact, from <f>
#   _tfvar_is_true <key>            — Return 0 if tfvar == true
#   _set_tfvar <key> <value>        — Set one key in terraform.tfvars, editing only its line
#   _confirm <prompt>               — Yes/no prompt that defaults to no
#   _tf_out <name>                  — Read one terraform output, or return 1
#   _validate_admin_password <pw>   — Enforce the LangSmith admin password rules
#   _values_input_stamp             — tfvars values baked into values-overrides.yaml
#   _langsmith_images_block         — images: block for values-overrides.yaml from a mirror
#   _langsmith_image_keys           — the chart images the module knows (0.17 and 0.18 lines)
#   _read_values_stamp <f> <k>      — Read one stamped value back out
#   _name_suffix                    — Resource-name suffix derived from name_prefix
#   _derive_kv_name                 — Key Vault name, mirroring local.keyvault_name
#   _require_kv_name                — _derive_kv_name, or exit with the reason it could not
#   Color helpers: _bold, _green, _red, _yellow, _cyan, _dim
#   Status helpers: pass, warn, fail, skip, info, header, action

# ── Resolve INFRA_DIR ────────────────────────────────────────────────────────
# INFRA_DIR is the Terraform root the deployment runs in: terraform.tfvars,
# secrets.auto.tfvars, state, and outputs. It defaults to infra/ next to this
# script. LANGSMITH_INFRA_DIR points it at a root outside this repo, such as a
# wrapper module that sources modules/azure/infra; LANGSMITH_VALUES_DIR does the
# same for the generated Helm values. Scripts, examples, and the base
# values.yaml always come from this repo.
_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${INFRA_DIR:-${LANGSMITH_INFRA_DIR:-$(cd "$_COMMON_DIR/.." && pwd)}}"

# ── terraform.tfvars parser ──────────────────────────────────────────────────
_parse_tfvar() {
  local key="$1"
  local tfvars_file="${INFRA_DIR:-$(pwd)}/terraform.tfvars"
  local raw val
  raw=$(grep -E "^\s*${key}\s*=" "$tfvars_file" 2>/dev/null | head -1) || return 1
  [[ -n "$raw" ]] || return 1
  # Quoted string: key = "value"
  val=$(echo "$raw" | sed -n 's/.*=[[:space:]]*"\([^"]*\)".*/\1/p' | tr -d '[:space:]')
  if [[ -z "$val" ]]; then
    # Unquoted value: key = true / key = 42 / key = {}. The trailing comment goes
    # first, or "create_keyvault = false # attach" returns a value matching
    # neither true nor false and every caller silently takes the other branch.
    val=$(echo "$raw" | sed 's/.*=[[:space:]]*//' | sed 's/#.*//' | tr -d '[:space:]"')
  fi
  [[ -n "$val" ]] || return 1
  echo "$val"
}

# Read one quoted scalar out of a tfvars file, preserving spaces inside the
# value. _parse_tfvar runs its result through `tr -d '[:space:]'`, which is right
# for a region or a resource name and silently mangles a password that contains a
# space. The file defaults to terraform.tfvars and is resolved against INFRA_DIR
# unless absolute, so callers can read secrets.auto.tfvars the same way.
_parse_tfvar_quoted() {
  local key="$1"
  local file="${2:-terraform.tfvars}"
  [[ "$file" == /* ]] || file="${INFRA_DIR:-$(pwd)}/$file"
  local val
  val=$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"\(.*\)\"[[:space:]]*\$/\1/p" \
    "$file" 2>/dev/null | head -1)
  [[ -n "$val" ]] || return 1
  echo "$val"
}

# Parse a boolean tfvar (unquoted true/false). Returns 0 for true, 1 for false.
_tfvar_is_true() {
  local val
  val=$(_parse_tfvar "$1") || return 1
  [[ "$val" == "true" ]]
}

# Replace the first uncommented `key = ...` line in terraform.tfvars, or append
# one, so every other setting stays exactly as written. `cat >`, not mv, keeps
# the file permissions.
_set_tfvar() {
  local _key="$1" _value="$2" _file="$INFRA_DIR/terraform.tfvars" _tmp
  _tmp="$(mktemp)"
  if awk -v key="$_key" -v value="$_value" '
    !done && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { print key " = " value; done = 1; next }
    { print }
    END { exit done ? 0 : 3 }
  ' "$_file" > "$_tmp"; then
    cat "$_tmp" > "$_file"
  else
    [[ -s "$_file" && -n "$(tail -c 1 "$_file")" ]] && printf '\n' >> "$_file"
    printf '%s = %s\n' "$_key" "$_value" >> "$_file"
  fi
  rm -f "$_tmp"
}

_confirm() {
  local _answer
  read -r -p "  $1 [y/N] " _answer
  [[ "$_answer" =~ ^[Yy] ]]
}

# ── terraform output reader ──────────────────────────────────────────────────
# `terraform output -raw <name>` exits 0 against a state with no outputs and
# prints its warning to stdout, so an exit-code check alone captures the warning
# as the value. Accept only a value shaped like a resource name, ID, or email;
# the leading alphanumeric also stops a value being read as an az CLI flag.
_tf_out() {
  local name="$1" val
  val=$(terraform -chdir="$INFRA_DIR" output -raw "$name" 2>/dev/null) || return 1
  [[ "$val" =~ ^[A-Za-z0-9][A-Za-z0-9._@+-]*$ ]] || return 1
  printf '%s' "$val"
}

# ── Azure cloud ──────────────────────────────────────────────────────────────
# The cloud this deployment targets. Once applied, the azure_environment output
# is the value Terraform actually used, whichever of terraform.tfvars,
# *.auto.tfvars or TF_VAR_azure_environment it came from, so read that first.
# Before the first apply there is no output: fall back to terraform.tfvars, then
# the environment variable, then public. The names below mirror
# local.azure_clouds in infra/main.tf; keep the two in step.
_azure_environment() {
  local val=""
  if command -v terraform >/dev/null 2>&1; then
    val=$(terraform -chdir="$INFRA_DIR" output -raw azure_environment 2>/dev/null) || val=""
  fi
  case "$val" in
    public|usgovernment) ;;
    *) val=$(_parse_tfvar azure_environment) || val="${TF_VAR_azure_environment:-public}" ;;
  esac
  echo "$val"
}

# Suffix Azure appends to a public IP DNS label: <label>.<region>.<suffix>.
_azure_cloudapp_suffix() {
  case "$(_azure_environment)" in
    usgovernment) echo "cloudapp.usgovcloudapi.net" ;;
    *) echo "cloudapp.azure.com" ;;
  esac
}

# cert-manager's azureDNS solver names the cloud its own way.
_cert_manager_azure_environment() {
  case "$(_azure_environment)" in
    usgovernment) echo "AzureUSGovernmentCloud" ;;
    *) echo "AzurePublicCloud" ;;
  esac
}

# ── Cluster credentials ──────────────────────────────────────────────────────
# az aks get-credentials for the deployed cluster. With no private DNS zone
# ("None"), only the public FQDN resolves (to the private IP), so the kubeconfig
# has to name it: the aks_kubeconfig_public_fqdn output says when.
_aks_get_credentials() {
  local cluster="$1" rg="$2" flags=()
  [[ "$(_tf_out aks_kubeconfig_public_fqdn || true)" == "true" ]] && flags=(--public-fqdn)
  az aks get-credentials --name "$cluster" --resource-group "$rg" \
    --overwrite-existing ${flags[@]+"${flags[@]}"}
}

# ── Entra ID sign-in for kubectl and Helm ───────────────────────────────────
# On a cluster with Entra ID integration, `az aks get-credentials` writes a
# kubeconfig whose user signs in interactively. Convert it to reuse the caller's
# az session, the same sign-in the Terraform providers use (aks_kube_auth), so
# scripts run unattended from a workstation, a pipeline, or a managed identity.
# Run it right after get-credentials, which rewrites the user entry each time.
# --context limits the conversion to this cluster's user: without it kubelogin
# rewrites every kubelogin or legacy Azure user in the kubeconfig, switching the
# operator's other AKS contexts to azurecli sign-in. get-credentials (without
# --admin or --context) names the context after the cluster.
# Returns 1 when the cluster needs kubelogin and it is not installed.
_aks_kubelogin_convert() {
  local cluster="$1" rg="$2" mode aad
  mode=$(_parse_tfvar aks_kube_auth) || mode="auto"
  [[ "$mode" == "certificate" ]] && return 0
  if [[ "$mode" == "auto" ]]; then
    # Same test as aks_kube_auth = "auto" in Terraform: any Entra profile,
    # AKS-managed or legacy, is what makes azurerm drop the client certificate.
    aad=$(az aks show --name "$cluster" --resource-group "$rg" --query "aadProfile != \`null\`" -o json --only-show-errors 2>/dev/null) || aad=""
    [[ "$aad" == "true" ]] || return 0
  fi
  if ! command -v kubelogin >/dev/null 2>&1; then
    fail "Cluster '${cluster}' uses Entra ID and kubelogin is not on the PATH. Install it with 'az aks install-cli'"
    return 1
  fi
  kubelogin convert-kubeconfig -l azurecli --context "$cluster"
}

# ── Admin password rules ─────────────────────────────────────────────────────
# The LangSmith Helm chart's auth-bootstrap job rejects an initial org admin
# password without a symbol, and it fails ~10 minutes into the release rather
# than at the point the value was entered. Same rule set as the AWS module's
# setup-env.sh, so a password valid on one cloud is valid on the other.
#
# Prints the reason and returns 1 on failure; returns 0 silently on success.
_validate_admin_password() {
  local pw="$1" err=""

  if [[ ${#pw} -lt 12 ]]; then
    err="must be at least 12 characters long"
  elif ! printf '%s' "$pw" | grep -qE '[]!#$%()+,./:?@^_{~}[\-]'; then
    err="must contain at least one symbol: !#\$%()+,-./:?@[\\]^_{~}"
  elif ! printf '%s' "$pw" | grep -q '[a-z]'; then
    err="must contain at least one lowercase letter"
  elif ! printf '%s' "$pw" | grep -q '[A-Z]'; then
    err="must contain at least one uppercase letter"
  fi

  if [[ -n "$err" ]]; then
    echo "Admin password is invalid — ${err}."
    return 1
  fi
}

# ── License key validation ───────────────────────────────────────────────────
# Two shapes reach platform-backend. An online key is `lcl_` plus the key body,
# which the backend exchanges with Beacon at startup (smith-go tests only the
# prefix). An offline key is a three-part JWT whose first part is a base64url
# JSON header carrying the alg member RFC 7515 requires. Anything else is parsed
# as a JWT and fails inside the pod with an error that names neither the prompt
# nor licensing (#250), so the shape is checked here, where the operator still
# has the right value in front of them. Shape only: no signature check, and the
# body-length floor on lcl_ keys is a typo guard rather than a specification.
_b64url_decode() {
  local s="${1//-/+}"
  s="${s//_//}"
  case $(( ${#s} % 4 )) in
    1) return 1 ;;
    2) s="${s}==" ;;
    3) s="${s}=" ;;
  esac
  printf '%s' "$s" | base64 -d 2>/dev/null
}

_validate_license_key() {
  local key="$1" err="" header="" header_json="" dots=""
  # A JWS header is a JSON object and must carry alg (RFC 7515 §4.1.1). Kept in
  # a variable: bash 3.2 treats a quoted regex literally, and this one has quotes.
  local header_re='^\{.*"alg"[[:space:]]*:.*\}$'

  case "$key" in
    "")                 err="cannot be empty" ;;
    *[[:space:]]*)      err="contains whitespace; paste the key on its own" ;;
    http://*|https://*) err="looks like a URL, not a license key. Paste the key itself, not the link it was shared in" ;;
    lcl_*)
      if [[ ! "${key#lcl_}" =~ ^[A-Za-z0-9_-]{16,}$ ]]; then
        err="is too short, or has characters outside A-Z a-z 0-9 - _, for an lcl_ key"
      fi ;;
    *)
      dots="${key//[^.]/}"
      if [[ ${#dots} -ne 2 ]]; then
        err="is not a LangSmith license key: expected lcl_<key>, or an offline token with exactly three dot-separated parts"
      else
        header="${key%%.*}"
        if [[ ! "$header" =~ ^[A-Za-z0-9_-]+$ ]] || ! header_json=$(_b64url_decode "$header") \
           || [[ ! "$header_json" =~ $header_re ]]; then
          err="has three parts, but its first part is not a base64url JSON header with an alg member, so it is not an offline license token"
        fi
      fi ;;
  esac

  if [[ -n "$err" ]]; then
    echo "License key ${err}."
    return 1
  fi
}

# ── values-overrides.yaml staleness stamp ────────────────────────────────────
# terraform.tfvars keys whose value init-values.sh bakes into
# values-overrides.yaml. That file is generated once and `make deploy` never
# regenerates it, so editing terraform.tfvars afterwards leaves Terraform and
# Helm deploying different configurations. init-values.sh writes these values
# into the generated file's header; deploy.sh reads them back and compares.
#
# Keys deploy.sh re-reads from terraform.tfvars on every run — sizing_profile and
# the enable_* flags, which select whole values files — are deliberately absent.
# Those cannot go stale, so listing them would fail a deploy that is fine.
# enable_sso_oidc is the exception: it is baked into the generated auth block
# (basicAuth off, oauth on), so a flip after init-values would deploy the old
# login path.
_VALUES_INPUT_KEYS="ingress_controller tls_certificate_source postgres_source redis_source clickhouse_source langsmith_domain dns_label location langsmith_custom_ca_secret_name langsmith_custom_ca_secret_key sandbox_service_url_base_url sandbox_host_min_count sandbox_host_max_count enable_sso_oidc langsmith_image_registry langsmith_image_registry_keeps_source_host langsmith_image_pull_secret_name"

# The chart line deploy.sh installs when neither CHART_VERSION in the
# environment nor langsmith_helm_chart_version in terraform.tfvars names one.
_LANGSMITH_CHART_PIN="~0.17.0"

# The chart version or constraint the next deploy resolves: CHART_VERSION from
# the environment, else langsmith_helm_chart_version, else the pin. deploy.sh
# and init-values.sh read the same answer, so what init-values writes for a
# chart line is what deploy installs.
_resolve_chart_version() {
  local v="${CHART_VERSION:-}"
  if [[ -z "$v" ]]; then v=$(_parse_tfvar "langsmith_helm_chart_version") || v=""; fi
  printf '%s' "${v:-$_LANGSMITH_CHART_PIN}"
}

# The <major>.<minor> line of a chart version or constraint: ~0.17.0 → 0.17.
_chart_line_of() {
  printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+' | head -1 || true
}

# ── LangSmith images from a mirror ────────────────────────────────────────────
# The chart's images and their repositories for the chart lines deploy.sh
# accepts here (0.17, and 0.18 with its two operator-deployment images),
# key=repository. init-values.sh writes one images.<key>.repository
# per entry when langsmith_image_registry_keeps_source_host = false (the
# default), the layout of a mirror that serves each source registry's paths
# directly (the chart's scripts/mirror_langsmith_images.sh pushes it, a proxy
# repository in Nexus or Artifactory serves it), because images.registry alone
# would compose <registry>/docker.io/... there. deploy.sh compares this list with the
# chart it is about to install and stops on an image the list does not carry,
# which would otherwise pull from its public registry. Keep the list equal to
# the images: block of the chart's values.yaml at the pinned lines.
_LANGSMITH_IMAGE_REPOSITORIES="aceBackendImage=docker.io/langchain/langsmith-ace-backend backendImage=docker.io/langchain/langsmith-backend engineInsightsAgentImage=docker.io/langchain/langsmith-insights-engine frontendImage=docker.io/langchain/langsmith-frontend operatorImage=docker.io/langchain/langgraph-operator postgresImage=docker.io/postgres redisImage=docker.io/redis clickhouseImage=docker.io/clickhouse/clickhouse-server agentBuilderImage=docker.io/langchain/agent-builder-deep-agent pollyAgentImage=docker.io/langchain/langsmith-polly smithdbImage=docker.io/langchain/smithdb presidioAnalyzerImage=mcr.microsoft.com/presidio-analyzer sandboxHostImage=docker.io/langchain/sandbox-host juicefsCSIImage=docker.io/juicedata/juicefs-csi-driver juicefsCSINodeDriverRegistrarImage=registry.k8s.io/sig-storage/csi-node-driver-registrar juicefsMountImage=docker.io/juicedata/mount deploymentRedisImage=docker.io/redis deploymentDbImage=docker.io/pgvector/pgvector"

# Print the image keys of a chart's values.yaml read on stdin: the top-level
# entries under images: whose name ends in Image, one per line. Reads to the
# end of its input on purpose. deploy.sh pipes `helm show values` into this
# under set -o pipefail, and an awk that exits at the first key after the
# images: block leaves helm with most of a 100 KB file still to write; helm
# then dies of SIGPIPE, the pipeline fails, and the caller reads "the chart's
# images could not be read" for a chart it read fine.
_chart_image_keys_from_stdin() {
  awk '/^images:/{p=1; next} p && /^[^ ]/{p=0} p && /^  [A-Za-z0-9]+Image:/{sub(":", "", $1); print $1}'
}

# Print the image keys the module knows, one per line.
_langsmith_image_keys() {
  local e
  for e in $_LANGSMITH_IMAGE_REPOSITORIES; do
    printf '%s\n' "${e%%=*}"
  done
}

# Print the images: block for values-overrides.yaml from the three tfvars:
#   _langsmith_images_block <registry> <keeps_source_host true|false> <pull secret>
# Nothing set: one comment line naming the knob. A registry that keeps the
# source host: images.registry alone. One that drops it: images.registry empty
# and every repository the list above knows, with the source host removed
# (docker.io/langchain/x becomes <registry>/langchain/x; images from other
# registries lose their host the same way, which is what a group repository
# that proxies several registries serves). A pull Secret: images.imagePullSecrets.
_langsmith_images_block() {
  local registry="$1" keeps_host="$2" pull_secret="$3" e key repo
  # Terraform rejects a trailing slash at plan time, but a tfvars edit after
  # the last plan reaches this function first and would write <registry>//<path>.
  registry="${registry%/}"
  if [[ -z "$registry" && -z "$pull_secret" ]]; then
    printf '# images: the chart defaults (docker.io). Set langsmith_image_registry for a mirror.\n'
    return 0
  fi
  printf 'images:\n'
  if [[ -n "$registry" ]]; then
    if [[ "$keeps_host" == "false" ]]; then
      printf '  # %s serves each source registry'"'"'s paths directly, so the prefix stays\n' "$registry"
      printf '  # empty and every repository names the mirror path (langsmith_image_registry_keeps_source_host = false).\n'
      printf '  registry: ""\n'
      for e in $_LANGSMITH_IMAGE_REPOSITORIES; do
        key="${e%%=*}"; repo="${e#*=}"; repo="${repo#*/}"
        printf '  %s:\n    repository: "%s/%s"\n' "$key" "$registry" "$repo"
      done
    else
      printf '  registry: "%s"\n' "$registry"
    fi
  fi
  if [[ -n "$pull_secret" ]]; then
    printf '  imagePullSecrets:\n    - name: "%s"\n' "$pull_secret"
  fi
}

# operator.templates.redis and operator.templates.db for the 0.17 chart line,
# the two images pointed at the mirror:
#   _deployment_templates_block <registry> <keeps_source_host true|false>
# On 0.17 the two templates are full manifests in the chart's values.yaml with
# docker.io/redis:7 and pgvector/pgvector:pg15 written in, and images.registry
# does not reach them, so a cluster that pulls only from the mirror gets
# ImagePullBackOff on both pods of every deployment while make deploy reports
# success. init-values.sh appends this block to langsmith-values-agent-deploys.yaml
# (which overrides operator.templates.deployment the same way) when
# langsmith_image_registry is set and the chart line is 0.17. The 0.18 line
# reads images.deploymentRedisImage and images.deploymentDbImage, which the
# images: block covers, so nothing is written there. The repositories come
# from _LANGSMITH_IMAGE_REPOSITORIES under the images: block's layout rule; the
# tags are the 0.17 templates' own. Template text copied from chart
# langsmith-0.17.6; re-copy it when the chart's operator.templates change.
_deployment_templates_block() {
  local registry="$1" keeps_host="$2" e redis_repo="" db_repo="" redis db
  registry="${registry%/}"
  for e in $_LANGSMITH_IMAGE_REPOSITORIES; do
    case "${e%%=*}" in
      deploymentRedisImage) redis_repo="${e#*=}" ;;
      deploymentDbImage)    db_repo="${e#*=}" ;;
    esac
  done
  if [[ "$keeps_host" == "false" ]]; then
    redis_repo="${redis_repo#*/}"; db_repo="${db_repo#*/}"
  fi
  redis="${registry}/${redis_repo}:7"
  db="${registry}/${db_repo}:pg15"
  sed -e "s|@@REDIS_IMAGE@@|${redis}|" -e "s|@@DB_IMAGE@@|${db}|" <<'EOF'
    # The per-deployment Redis and PostgreSQL from langsmith_image_registry: the 0.17
    # chart writes docker.io into these two templates. Written by init-values.sh.
    redis: |
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: ${service_name}
        namespace: ${namespace}
      spec:
        replicas: 1
        selector:
          matchLabels:
            app: ${service_name}
        template:
          metadata:
            labels:
              app: ${service_name}
          spec:
            enableServiceLinks: false
            containers:
            - name: redis
              image: @@REDIS_IMAGE@@
              ports:
              - containerPort: 6379
                name: redis
              livenessProbe:
                exec:
                  command:
                  - redis-cli
                  - ping
                initialDelaySeconds: 30
                periodSeconds: 10
              readinessProbe:
                tcpSocket:
                  port: 6379
                initialDelaySeconds: 10
                periodSeconds: 5
    db: |
      apiVersion: apps/v1
      kind: StatefulSet
      metadata:
        name: ${service_name}
      spec:
        serviceName: ${service_name}
        selector:
          matchLabels:
            app: ${service_name}
        persistentVolumeClaimRetentionPolicy:
          whenDeleted: Delete
          whenScaled: Retain
        template:
          metadata:
            labels:
              app: ${service_name}
          spec:
            containers:
            - name: postgres
              image: @@DB_IMAGE@@
              ports:
              - containerPort: 5432
              command: ["docker-entrypoint.sh"]
              args:
                - postgres
                - -c
                - max_connections=${max_connections}
              env:
              - name: PGDATA
                value: /var/lib/postgresql/data/pgdata
              volumeMounts:
              - name: postgres-data
                mountPath: /var/lib/postgresql/data
            enableServiceLinks: false
        volumeClaimTemplates:
        - metadata:
            name: postgres-data
          spec:
            accessModes: ["ReadWriteOnce"]
            resources:
              requests:
                storage: "${storage_gi}Gi"
EOF
}

# Emit the stamp block, one comment line per key. Stamps the raw tfvars value and
# leaves it empty when the key is absent — never the default a caller substitutes,
# so both sides of the comparison are reading the same thing.
_values_input_stamp() {
  local key val
  for key in $_VALUES_INPUT_KEYS; do
    val=$(_parse_tfvar "$key") || val=""
    printf '#   %s = %s\n' "$key" "$val"
  done
}

# Read one stamped value back out of a generated values file. Prints the value and
# returns 0 when the stamp line is present, including when the value is empty.
# Returns 1 when the file carries no stamp for that key, which is how a file
# written by an older init-values.sh is told apart from a genuine empty value.
_read_values_stamp() {
  local file="$1" key="$2" line
  line=$(grep -E "^#   ${key} =" "$file" 2>/dev/null | head -1) || return 1
  [[ -n "$line" ]] || return 1
  printf '%s' "$line" | sed "s/^#   ${key} =[[:space:]]*//"
}

# Compare a generated values file's stamp with the current terraform.tfvars,
# one line per key that disagrees:
#   <key>: generated with '<was>', terraform.tfvars now says '<now>'
#   <key>: not stamped (the file predates this key), terraform.tfvars now says '<now>'
# Returns 0 when the file is stamped and every key agrees, 1 when a line was
# printed, 2 when the file carries no stamp at all (written by an older
# init-values.sh; the lines printed, if any, are then only informative).
# A key the stamp lacks counts as drift only when terraform.tfvars sets it:
# an older file with the key unset on both sides still describes those
# tfvars, but one generated before langsmith_image_registry existed, with a
# tfvars that now sets it, would otherwise deploy from docker.io and report
# success.
_values_stamp_drift() {
  local file="$1" key was now stamped="false" drift="false"
  for key in $_VALUES_INPUT_KEYS; do
    if was=$(_read_values_stamp "$file" "$key"); then
      stamped="true"
      now=$(_parse_tfvar "$key") || now=""
      [[ "$was" == "$now" ]] && continue
      printf "%s: generated with '%s', terraform.tfvars now says '%s'\n" "$key" "$was" "$now"
      drift="true"
    else
      now=$(_parse_tfvar "$key") || now=""
      [[ -n "$now" ]] || continue
      printf "%s: not stamped (the file predates this key), terraform.tfvars now says '%s'\n" "$key" "$now"
      drift="true"
    fi
  done
  [[ "$stamped" == "true" ]] || return 2
  [[ "$drift" == "true" ]] && return 1
  return 0
}

# Returns 0 when a values file carries the host-kept mirror layout
# (images.registry set) while terraform.tfvars sets langsmith_image_registry
# and leaves langsmith_image_registry_keeps_source_host unset: a file generated
# under that key's previous default (true; the 0.16 line's v0.16.124 to .126
# wrote it). The default is now false, the stamp reads '' on both sides so
# _values_stamp_drift passes the file, and the next make init-values would
# switch the layout under a mirror that serves the host-kept one. deploy.sh
# stops on it until the key is set.
#   _values_layout_from_old_default <values-file>
_values_layout_from_old_default() {
  local file="$1" registry
  registry=$(_parse_tfvar "langsmith_image_registry") || return 1
  [[ -n "$registry" ]] || return 1
  _parse_tfvar "langsmith_image_registry_keeps_source_host" >/dev/null 2>&1 && return 1
  awk '/^images:/{p=1; next} /^[^ #]/{p=0} p && /^  registry: "[^"]+"/{f=1} END{exit !f}' "$file" 2>/dev/null
}

# Print ingress.ingressClassName from a values file, quotes stripped; nothing when
# unset or empty. With ingress_controller = "none" this is the only place a class
# comes from, so init-values.sh keeps it on re-run and deploy.sh checks it.
_values_ingress_class() {
  awk '
    /^[A-Za-z_]/ { top = $1; sub(":", "", top) }
    top == "ingress" && /^  ingressClassName:/ { v = $2; gsub(/["\047]/, "", v); cls = v }
    END { print cls }
  ' "$1" 2>/dev/null
}

# Resource-name suffix, mirroring local.name_suffix in main.tf.
# name_prefix carries no hyphen ("prod") but every derived name needs one
# ("langsmith-kv-prod"), so the separator is added here. Falls back to the
# retired `identifier` key, hyphen and all, so these scripts can still resolve
# names for a deployment whose tfvars predates the rename.
# Returns 1 when neither key is set — callers treat that as "no suffix".
_name_suffix() {
  local val
  val=$(_parse_tfvar "name_prefix") || val=$(_parse_tfvar "identifier") || return 1
  printf -- '-%s' "${val#-}"
}

# Key Vault name, mirroring local.keyvault_name in main.tf including the
# unique_resource_names hash. Keep the two in step.
#
# The attach branch comes first, as in main.tf: with create_keyvault = false a
# derived name points at a vault that does not exist, and before the first
# apply there is no terraform output to catch it — setup-env.sh would read no
# secret and mint a fresh Postgres password over the real one. Returns 1 when
# attach mode is on but existing_keyvault_name is unset.
_derive_kv_name() {
  local explicit suffix sub salt hash base create
  create=$(_parse_tfvar create_keyvault || echo "true")
  if [[ "$create" == "false" ]]; then
    explicit=$(_parse_tfvar existing_keyvault_name || true)
    [[ -n "$explicit" ]] || return 1
    echo "$explicit"
    return 0
  fi
  explicit=$(_parse_tfvar keyvault_name || true)
  if [[ -n "$explicit" ]]; then
    echo "$explicit"
    return 0
  fi
  suffix=$(_name_suffix || true)
  # name_base overrides the ls/langsmith switch outright, same as main.tf.
  base=$(_parse_tfvar name_base || true)
  if _tfvar_is_true unique_resource_names; then
    sub=$(_parse_tfvar subscription_id || true)
    salt=$(_parse_tfvar name_suffix_salt || true)
    if command -v shasum &>/dev/null; then
      hash=$(printf '%s' "${sub}${suffix}${salt}" | shasum -a 256 | cut -c1-6)
    else
      hash=$(printf '%s' "${sub}${suffix}${salt}" | sha256sum | cut -c1-6)
    fi
    echo "${base:-ls}-kv${suffix}-${hash}"
  else
    echo "${base:-langsmith}-kv${suffix}"
  fi
}

# _derive_kv_name with its one failure spelled out. Every caller but status.sh
# needs a real vault, so they exit here rather than carry an empty name into an
# az command.
_require_kv_name() {
  local name
  if ! name=$(_derive_kv_name); then
    echo "  create_keyvault = false but existing_keyvault_name is unset in terraform.tfvars." >&2
    echo "  Set it to the vault to attach to, or set create_keyvault = true." >&2
    exit 1
  fi
  printf '%s' "$name"
}

# ── Color helpers ────────────────────────────────────────────────────────────
_bold()  { printf '\033[1m%s\033[0m' "$*"; }
_green() { printf '\033[32m%s\033[0m' "$*"; }
_red()   { printf '\033[31m%s\033[0m' "$*"; }
_yellow(){ printf '\033[33m%s\033[0m' "$*"; }
_cyan()  { printf '\033[0;36m%s\033[0m' "$*"; }
_dim()   { printf '\033[0;90m%s\033[0m' "$*"; }

# ── Status line helpers ──────────────────────────────────────────────────────
_RESET='\033[0m'
pass()  { printf "  \033[32m✔${_RESET}  %s\n" "$1"; }
warn()  { printf "  \033[1;33m⚠${_RESET}  %s\n" "$1"; }
fail()  { printf "  \033[31m✘${_RESET}  %s\n" "$1"; }
skip()  { printf "  \033[0;90m○${_RESET}  %s\n" "$1"; }
info()  { printf "  \033[0;36mℹ${_RESET}  %s\n" "$1"; }
header(){ printf "\n\033[1m── %s ──${_RESET}\n" "$1"; }
action(){ printf "  \033[1;33m→${_RESET}  %s\n" "$1"; }
