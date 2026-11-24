#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# Paths, the tools a command needs, Terraform with the secrets it reads, its outputs, and ssh to the
# box. Sourced by bin/lite.
# shellcheck disable=SC2034  # the paths are read by the files bin/lite sources after this one

LITE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA="$LITE/infra"
BUILD="$LITE/build"
SECRETS_FILE="$INFRA/.secrets.env"
DATASTORES_CHART="$LITE/../baremetal/charts/datastores"
PLAN_FILE="$BUILD/plan.out"

# Each tool a command needs, the oldest version that works, and how to read it: checked up front, as a
# missing tool used to surface halfway through as "command not found".
# shellcheck disable=SC2016  # each probe runs later, through bash -c
TOOLS='terraform 1.11 terraform version -json | python3 -c "import json,sys; print(json.load(sys.stdin)[\"terraform_version\"])"
helm 3.12 helm version --template "{{.Version}}"
python3 3.9 python3 -c "import platform; print(platform.python_version())"
ssh 0 echo 0
curl 0 echo 0
uv 0.13.4 uv --version | cut -d" " -f2
kubectl 1.28 kubectl version --client -o json | python3 -c "import json,sys; print(json.load(sys.stdin)[\"clientVersion\"][\"gitVersion\"])"
shellcheck 0.9 shellcheck --version | awk "/^version:/ {print \$2}"'

version_at_least() {
  python3 - "$1" "$2" <<'EOF'
import re, sys
have, want = ([int(x) for x in re.findall(r"\d+", v)[:3]] for v in sys.argv[1:])
sys.exit(0 if have + [0] * (3 - len(have)) >= want + [0] * (3 - len(want)) else 1)
EOF
}

need() {
  local tool line min probe have problems=()
  for tool in "$@"; do
    # A tool with no row (tar) is only checked for being installed: grep found no row for tar, and under
    # set -e that ended make up in silence after the apply (magus, 2026-11-24).
    line="$(grep "^$tool " <<<"$TOOLS" || true)"
    min="$(awk '{print $2}' <<<"$line")"
    probe="$(cut -d' ' -f3- <<<"$line")"
    if ! command -v "$tool" >/dev/null 2>&1; then
      problems+=("$tool is not installed")
    elif [[ -n "$min" && "$min" != 0 ]]; then
      have="$(bash -c "$probe" 2>/dev/null || echo 0)"
      version_at_least "${have#v}" "$min" || problems+=("$tool is ${have#v}; Lite needs $min or later")
    fi
  done
  ((${#problems[@]} == 0)) || fail "missing tools" "${problems[@]}" "README.md, Quick start, lists what each is for."
}

# Terraform in infra/, with the license key and tunnel token passed as TF_VAR_ environment variables,
# never as -var arguments, which any process on the machine could read.
tf() {
  local line
  if [[ -f "$SECRETS_FILE" ]]; then
    # Split at the first = by hand: IFS='=' read drops a value's trailing =, which cut the padding off a
    # base64 tunnel token.
    while IFS= read -r line; do
      case "${line%%=*}" in
        LANGSMITH_LICENSE_KEY) export TF_VAR_langsmith_license_key="${line#*=}" ;;
        TUNNEL_TOKEN) export TF_VAR_tunnel_token="${line#*=}" ;;
      esac
    done <"$SECRETS_FILE"
  fi
  if [[ ! -d "$INFRA/.terraform" && "${1:-}" != init ]]; then
    mkdir -p "$BUILD"
    terraform -chdir="$INFRA" init -input=false >"$BUILD/init.log" 2>&1 ||
      fail "terraform init failed" "its output: build/init.log"
  fi
  terraform -chdir="$INFRA" "$@"
}

tf_output() {
  tf output -json "$1" 2>/dev/null || fail "no Terraform output $1" "run make up first."
}

# An expression evaluated against the configuration with no apply, for what preflight reads before a
# machine exists. console prints jsonencode's result as an HCL string, so it is decoded twice: decoded
# only once, a user read "reed" with its quotes and ssh took "" for a port.
tf_eval() {
  tf console <<<"jsonencode($1)" 2>/dev/null | python3 -c 'import json,sys
v = json.loads(json.loads(sys.stdin.read()))
print("" if v is None else v if isinstance(v, (str, int, float)) else json.dumps(v))'
}

json_get() {
  python3 -c 'import json,sys
v = json.load(sys.stdin)
for k in sys.argv[1:]: v = v[k]
print(json.dumps(v) if isinstance(v, (dict, list)) else v)' "$@"
}

# ssh_to USER HOST PORT: ssh with a deadline. BatchMode fails on a missing key rather than prompting,
# ConnectTimeout and ServerAlive end an unreachable or vanished box, accept-new learns a fresh key once
# and still refuses a changed one. An empty user or port is left to ~/.ssh/config: passing them always
# overrode an alias's own User and Port.
ssh_to() {
  SSH_TARGET="${1:+$1@}$2"
  SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new
    -o ServerAliveInterval=30 -o ServerAliveCountMax=4)
  [[ -z "$3" || "$3" == None ]] || SSH_OPTS+=(-p "$3")
}

# An instance Lite made has a Terraform-generated host key, checked strictly in a known_hosts of its
# own. A machine of your own keeps accept-new: its key is yours to know.
ssh_from_outputs() {
  local s key
  s="$(tf_output ssh)"
  ssh_to "$(json_get user <<<"$s" | sed 's/^None$//')" "$(json_get host <<<"$s")" "$(json_get port <<<"$s")"
  key="$(json_get host_key <<<"$s" | sed 's/^None$//')"
  if [[ -n "$key" ]]; then
    mkdir -p "$BUILD"
    printf '%s %s\n' "$(json_get host <<<"$s")" "$key" >"$BUILD/known_hosts"
    SSH_OPTS=("${SSH_OPTS[@]/StrictHostKeyChecking=accept-new/StrictHostKeyChecking=yes}" -o UserKnownHostsFile="$BUILD/known_hosts")
  fi
}

# A new instance takes a minute or two to answer on sshd; the install's first ssh failed there.
wait_for_ssh() {
  local deadline=$((SECONDS + 240))
  until ssh "${SSH_OPTS[@]}" -o ConnectTimeout=5 "$SSH_TARGET" true 2>/dev/null; do
    ((SECONDS < deadline)) || { echo "no ssh to $SSH_TARGET after 4 minutes"; return 1; }
    sleep 5
  done
}

# ssh_root WHY COMMAND: root on the box, only to install, upgrade or remove k3s. -t and sudo -v ask once,
# up front, so a password or a security key's touch works (a sudo that needed a touch failed without
# them). It says why root is asked for, and that it was granted, so a long install after a touch is not
# a silent wait (magus, 2026-11-24).
ssh_root() {
  printf '\n  %-18s %s%s%s\n' root "$DIM" "$1" "$OFF"
  ssh -t "${SSH_OPTS[@]}" "$SSH_TARGET" \
    "sudo -v && printf '  %-18s %s %sgranted%s\n\n' root 'on \$(hostname)' '$GREEN' '$OFF' && $2"
}

# Defines k on the box: kubectl as the ssh user, with the kubeconfig the install gave it.
# shellcheck disable=SC2016  # expands on the box
BOX_K='k() { k3s kubectl --kubeconfig "$HOME/.kube/langsmith-lite.yaml" "$@"; }
if [ ! -r "$HOME/.kube/langsmith-lite.yaml" ]; then echo "no kubeconfig for $(id -un) on this box: run make up."; exit 1; fi'
