#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# Proving a running install: verify and soak. Sourced by bin/lite. The judging is the load test's
# (utils/langsmith-load-test), the same for every install; lib/prove.py adds the API key; this file
# reaches the install:
#
#   a box      ssh forwards the box's Kubernetes API to a free port here; the ssh user's kubeconfig,
#              pointed at it, lives in the run's folder (mode 600) and goes with it
#   a cluster  the kubectl context in use (cloud = cluster)
#   both       kubectl port-forwards LangSmith's frontend to a free port here, so traces take the same
#              path whatever the access mode, with no certificate to trust

cmd_verify() {
  heading "verify" "traces go in, and come back out: every hop, about two minutes"
  prove verify
  next "make soak"
}

cmd_soak() {
  local rate
  rate="${RATE:-$(tf_output plan | json_get runs_per_second)}"
  heading "soak" "$rate runs/s with reads for ${DURATION:-900} s, the install read every 15 s${STEP:+; raised until a step fails}"
  local extra=(--runs-per-second "$rate" --duration "${DURATION:-900}" --ramp "${RAMP:-120}")
  [[ "${STEP:-}" == 1 ]] && extra+=(--step)
  prove soak "${extra[@]}"
}

prove() {
  need terraform python3 ssh kubectl uv
  local mode="$1" ns work kport wport logins
  shift
  ns="$(tf_output namespaces)"
  logins="$(tf_output logins)"
  work="$BUILD/$mode/$(date -u +%Y%m%dT%H%M%SZ)"
  umask 077
  mkdir -p "$work"
  start_log "$BUILD/logs"
  # $work expanded now, a local being gone by the time EXIT runs (see install_bundle); TUNNELS then.
  # Each tunnel is disowned and killed by its pid: a job killed at exit printed bash's "Terminated"
  # notice with its whole command line after a passing verify (magus, 2026-11-25).
  TUNNELS=()
  # shellcheck disable=SC2064
  trap "kill \"\${TUNNELS[@]}\" 2>/dev/null; rm -f '$work/kubeconfig'" EXIT
  if [[ "$(tf_eval var.cloud)" != cluster ]]; then
    ssh_from_outputs
    kport="$(free_port)"
    run kubeconfig "the ssh user's kubeconfig, pointed here" box_kubeconfig "$work/kubeconfig" "$kport"
    export KUBECONFIG="$work/kubeconfig"
    ssh "${SSH_OPTS[@]}" -N -o ExitOnForwardFailure=yes -L "$kport:127.0.0.1:6443" "$SSH_TARGET" &
    TUNNELS+=("$!") && disown
    run kube "reach the box's Kubernetes API over ssh" wait_for kubectl get --raw /readyz
  fi
  # Port 0: kubectl binds a free port itself. One picked here and bound later could be taken first by
  # another local user, who would receive the admin's login (security review, 2026-11-24).
  kubectl -n "$(json_get langsmith <<<"$ns")" port-forward svc/langsmith-frontend "0:$(frontend_port "$ns")" >"$work/port-forward.log" 2>&1 &
  TUNNELS+=("$!") && disown
  run forward "a tunnel to LangSmith's frontend" wait_for grep -q '^Forwarding from 127.0.0.1:' "$work/port-forward.log"
  wport="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) .*/\1/p' "$work/port-forward.log" | head -1)"
  run frontend "LangSmith answers through it" wait_for curl -sf -o /dev/null "http://127.0.0.1:$wport/api/v1/info"
  printf '\n'
  LITE_ADMIN_EMAIL="$(json_get langsmith user <<<"$logins")" LITE_ADMIN_PASSWORD="$(json_get langsmith password <<<"$logins")" \
    python3 "$LITE/lib/prove.py" "$mode" --endpoint "http://127.0.0.1:$wport" \
    --namespace "$(json_get langsmith <<<"$ns")" --data-namespace "$(json_get data <<<"$ns")" \
    --loadtest "$LITE/../../utils/langsmith-load-test" --out "$work" "$@" ||
    fail "the install did not pass $mode" "the hop that failed is above; the run's results: ${work#"$LITE"/}"
}

free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

# The ssh user's own kubeconfig from the install, with its server moved to the forwarded port. The
# API's certificate names 127.0.0.1, so it verifies here as it does on the box. The install writes the
# server quoted; a pattern without the quotes matched nothing and verify stopped here (magus, 2026-11-25).
box_kubeconfig() {
  # shellcheck disable=SC2016  # expands on the box
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'cat "$HOME/.kube/langsmith-lite.yaml"' |
    sed -E "s#server: \"?https://127\.0\.0\.1:[0-9]+\"?#server: https://127.0.0.1:$2#" >"$1" || return 1
  grep -q "127.0.0.1:$2" "$1" || { echo "the box's kubeconfig has no server at https://127.0.0.1:<port> to point here"; return 1; }
}

frontend_port() {
  kubectl -n "$(json_get langsmith <<<"$1")" get svc langsmith-frontend -o jsonpath='{.spec.ports[0].port}'
}

# A forward takes a moment to listen; the first call through it failed before it did.
wait_for() {
  local deadline=$((SECONDS + 30))
  until "$@" >/dev/null 2>&1; do
    ((SECONDS < deadline)) || { echo "not answering after 30 s: $*"; return 1; }
    sleep 1
  done
}
