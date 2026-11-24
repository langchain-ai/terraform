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

# The tools each command needs, with the oldest version that works, checked before it starts: a
# missing tool used to surface halfway through, as a "command not found" from a script.
#   name  minimum  how to read its version
# shellcheck disable=SC2016  # each probe runs later, through bash -c
TOOLS='terraform 1.11 terraform version -json | python3 -c "import json,sys; print(json.load(sys.stdin)[\"terraform_version\"])"
helm 3.12 helm version --template "{{.Version}}"
python3 3.9 python3 -c "import platform; print(platform.python_version())"
ssh 0 echo 0
curl 0 echo 0
uv 0.5 uv --version | cut -d" " -f2
shellcheck 0.9 shellcheck --version | awk "/^version:/ {print \$2}"'

version_at_least() {
  # version_at_least 1.11.2 1.11: compares numerically, field by field.
  python3 - "$1" "$2" <<'EOF'
import re, sys
have, want = ([int(x) for x in re.findall(r"\d+", v)[:3]] for v in sys.argv[1:])
sys.exit(0 if have + [0] * (3 - len(have)) >= want + [0] * (3 - len(want)) else 1)
EOF
}

# need TOOL [TOOL ...]: fail naming every missing or too-old tool at once.
need() {
  local tool line min probe have problems=()
  for tool in "$@"; do
    line="$(grep "^$tool " <<<"$TOOLS")"
    min="$(awk '{print $2}' <<<"$line")"
    probe="$(cut -d' ' -f3- <<<"$line")"
    if ! command -v "$tool" >/dev/null 2>&1; then
      problems+=("$tool is not installed")
    elif [[ "$min" != 0 ]]; then
      have="$(bash -c "$probe" 2>/dev/null || echo 0)"
      version_at_least "${have#v}" "$min" || problems+=("$tool is ${have#v}; Lite needs $min or later")
    fi
  done
  ((${#problems[@]} == 0)) || fail "missing tools" "${problems[@]}" "README.md, Quick start, lists what each is for."
}

# Terraform in infra/, with the license key and tunnel token from infra/.secrets.env as TF_VAR_ environment
# variables, never as -var arguments, which any process on the machine could read.
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
  # A fresh checkout initialises on its first use, so no verb needs a separate init step first.
  if [[ ! -d "$INFRA/.terraform" && "${1:-}" != init ]]; then
    mkdir -p "$BUILD"
    terraform -chdir="$INFRA" init -input=false >"$BUILD/init.log" 2>&1 ||
      fail "terraform init failed" "its output: build/init.log"
  fi
  terraform -chdir="$INFRA" "$@"
}

# A Terraform output as JSON. A root never applied has none.
tf_output() {
  tf output -json "$1" 2>/dev/null || fail "no Terraform output $1" "run make up first."
}

# An expression evaluated against the configuration and tfvars, with no apply: what preflight reads
# before a machine exists.
# Prints a string or number as it is and anything else as JSON. console prints jsonencode's result as an
# HCL string, so it is decoded twice: once printed it read "reed" with its quotes, and ssh took "" for a port.
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

# ssh with a deadline: BatchMode so a missing key fails rather than prompts, ConnectTimeout so an
# unreachable box fails in seconds, accept-new so a fresh instance's key is learnt once and a changed
# key is still refused, ServerAlive so a session whose box went away ends.
# ssh_to USER HOST PORT: an empty user or port is left to ~/.ssh/config, so an alias's own User and Port
# apply; passing them always overrode the alias.
ssh_to() {
  SSH_TARGET="${1:+$1@}$2"
  SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new
    -o ServerAliveInterval=30 -o ServerAliveCountMax=4)
  [[ -z "$3" || "$3" == None ]] || SSH_OPTS+=(-p "$3")
}

ssh_from_outputs() {
  local s
  s="$(tf_output ssh)"
  ssh_to "$(json_get user <<<"$s" | sed 's/^None$//')" "$(json_get host <<<"$s")" "$(json_get port <<<"$s")"
}

# A new instance boots for a minute or two before its sshd answers; the install's first ssh failed
# there after the instance was already running.
wait_for_ssh() {
  local deadline=$((SECONDS + 240))
  until ssh "${SSH_OPTS[@]}" -o ConnectTimeout=5 "$SSH_TARGET" true 2>/dev/null; do
    ((SECONDS < deadline)) || { echo "no ssh to $SSH_TARGET after 4 minutes"; return 1; }
    sleep 5
  done
}

# A command on the box as root: only installing, upgrading and removing k3s, a system service. -t
# gives sudo a terminal and sudo -v asks once, up front, so sudo that wants a password or a security
# key's touch works as well as passwordless sudo (one that needed a touch failed every call without it).
ssh_root() {
  ssh -t "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo -v && $1"
}

# Defines k on the box: kubectl as the ssh user with the kubeconfig the install gave it. Reading the
# cluster needs no root.
# shellcheck disable=SC2016  # expands on the box
BOX_K='k() { k3s kubectl --kubeconfig "$HOME/.kube/langsmith-lite.yaml" "$@"; }
if [ ! -r "$HOME/.kube/langsmith-lite.yaml" ]; then echo "no kubeconfig for $(id -un) on this box: run make up."; exit 1; fi'
