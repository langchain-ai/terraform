#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# Using a box: preflight, access, status, values, load. Sourced by bin/lite. None of these needs root on
# the box.

# Whether the machine can be the box, before anything is installed: box/checks.sh over ssh, as the ssh
# user. make up runs the same checks on the box first, so a box passes or fails the same way either way.
cmd_preflight() {
  need terraform python3 ssh
  heading "preflight" "can this machine be the box? read-only, no root"
  local cloud machine port colour=0
  cloud="$(tf_eval var.cloud)" || fail "could not read the configuration" "run make init, and check infra/terraform.tfvars."
  if [[ "$cloud" == aws ]]; then
    tf output -json ssh >/dev/null 2>&1 ||
      fail "the instance does not exist yet" "make up makes it, then runs these checks on it before installing."
    ssh_from_outputs
  else
    port="$(tf_eval 'var.ssh_port == null ? "" : tostring(var.ssh_port)')"
    ssh_to "$(tf_eval var.ssh_user)" "$(tf_eval var.ssh_host)" "$port"
  fi
  machine="$(tf_eval local.machine)"
  start_log "$BUILD/logs"
  run ssh "reach $SSH_TARGET over ssh" ssh "${SSH_OPTS[@]}" "$SSH_TARGET" true
  printf '\n'
  [[ -n "$GREEN" ]] && colour=1
  # shellcheck disable=SC2029  # the machine's size is read here and passed to the box
  cat "$LITE/lib/ui.sh" "$LITE/box/checks.sh" | ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
    "FORCE_COLOR=$colour MACHINE_CPU=$(json_get cpu <<<"$machine") MACHINE_MEM_GI=$(json_get memory_gi <<<"$machine") MACHINE_DISK_GI=$(json_get disk_gi <<<"$machine") ACCESS=$(tf_eval var.access) bash -s" ||
    fail "this machine cannot be the box" "each FAIL above says why."
  next "make up"
}

# Print every login, and hold the tunnels to the box's private UIs open until Ctrl-C. One ssh session
# carries them all: on the box kubectl port-forwards each Service to the box's own loopback, and ssh
# forwards those ports here.
cmd_access() {
  need terraform python3 ssh
  local url forwards remote
  ssh_from_outputs
  url="$(tf_output url | json_get)"
  heading "access" "every login, and the tunnels to the box's UIs"
  tf_output logins | python3 -c '
import json, sys
dim, off = (sys.argv[1], sys.argv[2])
for name, l in json.load(sys.stdin).items():
    print(f"  {dim}{name.replace(\"_\", \" \"):<16}{off} {l[\"url\"]:<34} {l[\"user\"]:<26} {l[\"password\"]}")
' "$DIM" "$OFF"
  forwards=(-L 3000:127.0.0.1:13000 -L 3001:127.0.0.1:13001)
  remote="$BOX_K"'
k -n observe port-forward svc/grafana 13000:80 >/dev/null &
k -n langsmith port-forward svc/mission-control-frontend 13001:3000 >/dev/null &'
  if [[ "$url" == http://localhost:8080 ]]; then
    forwards+=(-L 8080:127.0.0.1:18080)
    remote+='
k -n kube-system port-forward svc/traefik 18080:80 >/dev/null &'
  fi
  remote+='
trap "kill 0" EXIT
wait'
  printf '\n  %stunnels open to %s; Ctrl-C closes them%s\n\n' "$DIM" "$SSH_TARGET" "$OFF"
  ssh "${SSH_OPTS[@]}" -o ExitOnForwardFailure=yes "${forwards[@]}" "$SSH_TARGET" "$remote"
}

# Where the box stands, read-only: each release's install, every pod, what the node and the pods use,
# and the volumes.
cmd_status() {
  need terraform python3 ssh
  ssh_from_outputs
  heading "status" "$SSH_TARGET"
  # shellcheck disable=SC2016  # expands on the box
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$BOX_K"'
echo "## releases (an install Job per HelmChart; COMPLETE 1 is installed)"
k -n kube-system get jobs -l helmcharts.helm.cattle.io/chart -o custom-columns=RELEASE:.metadata.labels.helmcharts\.helm\.cattle\.io/chart,COMPLETE:.status.succeeded,FAILED:.status.failed,CREATED:.metadata.creationTimestamp
echo "## pods"
k get pods -n langsmith -o wide; k get pods -n langsmith-data; k get pods -n observe
echo "## use (metrics-server; empty for a minute after a restart)"
k top node || true
k top pods -A --sort-by=memory 2>/dev/null | head -25 || true
echo "## volumes"
k get pvc -A
df -h /var/lib/rancher 2>/dev/null || df -h /' |
    awk -v b="$BOLD" -v o="$OFF" '/^## / { print ""; print "  " b substr($0, 4) o; next } { print "  " $0 }'
  printf '\n'
}

cmd_values() { tf output -json values; }

# The load test in utils/langsmith-load-test against this box, with an API key made in LangSmith.
cmd_load() {
  need terraform uv
  [[ -n "${LANGSMITH_API_KEY:-}" ]] ||
    fail "no LANGSMITH_API_KEY" "make one in LangSmith (Settings, API Keys) and export it."
  local endpoint
  endpoint="$(tf output -raw url)/api/v1"
  heading "load" "synthetic traces at $endpoint"
  [[ "$endpoint" == http://localhost* ]] && printf '  %smake access must be running in another terminal%s\n\n' "$DIM" "$OFF"
  (cd "$LITE/../../utils/langsmith-load-test" && LANGSMITH_TRACING=true LANGSMITH_ENDPOINT="$endpoint" uv run load-test "$@")
}
