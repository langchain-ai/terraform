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
  traces_field
  # shellcheck disable=SC2046  # the flags split on spaces, as typed
  prove verify $(traces_flags) || exit 1
  next "make soak"
}

cmd_soak() {
  local plan rate readers
  plan="$(tf_output plan)"
  rate="${RATE:-$(json_get runs_per_second <<<"$plan")}"
  readers="$(json_get readers <<<"$plan")"
  heading "soak" "$rate runs/s and $readers reader$([[ "$readers" == 1 ]] || echo s) for $(minutes "${DURATION:-900}") after a $(minutes "${RAMP:-120}") ramp${STEP:+, raised until a step fails}"
  local extra=(--runs-per-second "$rate" --readers "$readers" --duration "${DURATION:-900}" --ramp "${RAMP:-120}")
  [[ "${STEP:-}" == 1 ]] && extra+=(--step)
  traces_field
  # shellcheck disable=SC2046,SC2086  # the flags split on spaces, as typed
  prove soak "${extra[@]}" $(traces_flags) ${LOADTEST_FLAGS:-} || exit 1
}

# TRACES: the traces verify, soak and every experiment step send, the load test's --traces.
#   simple  ten runs in a flat tree, each a size from the measured mix: quick, and comparable run to run
#   agent   an application's traces, as customers send them: mostly one model call, a third an agent that
#           calls tools for several turns, every model call resending the conversation so far (the load
#           test's payloads/agent.py, calibrated in params.yaml's load.agent_trace)
#   coding  a coding agent's: every trace calls tools for dozens of turns, its context grown to hundreds of
#           KB a model call and then compacted (load.coding_trace, provisional until measured)
# verify and soak send simple unless TRACES says otherwise; an experiment sends agent, as it measures
# what a size holds for real traffic. The first experiment's simple traces put 34 KiB a run in blob
# storage and 86 in SmithDB's segments on box l, against 25.7 KB the plan budgets (magus, 2026-11-26).
# Checked here, in the verb's own shell: a fail inside $(traces_flags) would end only its subshell.
traces_field() {
  case "${TRACES:-simple}" in
    simple | agent | coding) field "traces" "${TRACES:-simple}" ;;
    *) fail "TRACES is simple, agent or coding, not $TRACES" "simple: the quick test traces; agent: an application's realistic ones; coding: a coding agent's." ;;
  esac
}
traces_flags() { [[ -z "${TRACES:-}" ]] || printf -- '--traces %s' "$TRACES"; }

prove() {
  need terraform python3 ssh kubectl uv
  local mode="$1" ns work kport wport logins STALL_PID=""
  shift
  ns="$(tf_output namespaces)"
  logins="$(tf_output logins)"
  work="${OUT:-$BUILD/$mode/$(date -u +%Y%m%dT%H%M%SZ)}"
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
  if [[ -n "${STALL_SECONDS:-}" ]]; then
    field "stall" "ingest-queue stopped for $(minutes "$STALL_SECONDS") from $(minutes $((${RAMP:-120} + 120))) in"
    stall_ingest "$(json_get langsmith <<<"$ns")" "$((${RAMP:-120} + 120))" "$STALL_SECONDS" "$work/stall.log" &
    STALL_PID="$!"
  fi
  printf '\n'
  # CPU through the install's own Prometheus: the operator's kubeconfig cannot reach the kubelet, by design.
  # The +-expansion: bash 3.2, macOS's, calls an empty array unbound under set -u.
  local prometheus=()
  [[ "$(tf_output plan | json_get features observability)" == True ]] &&
    prometheus=(--prometheus "$(json_get observe <<<"$ns")/prometheus-server:80")
  LITE_ADMIN_EMAIL="$(json_get langsmith user <<<"$logins")" LITE_ADMIN_PASSWORD="$(json_get langsmith password <<<"$logins")" \
    python3 "$LITE/lib/prove.py" "$mode" --endpoint "http://127.0.0.1:$wport" \
    --namespace "$(json_get langsmith <<<"$ns")" --data-namespace "$(json_get data <<<"$ns")" ${prometheus[@]+"${prometheus[@]}"} \
    --loadtest "$LITE/../../utils/langsmith-load-test" --out "$work" "$@"
  local status=$?
  # The stall ends inside the step (check_steps), so this waits on nothing; were the load to stop early,
  # it waits for ingest-queue to be started again rather than leave it stopped.
  [[ -n "${STALL_PID:-}" ]] && wait "$STALL_PID"
  # The load test's own last line says what held and what did not; this adds where the run is kept.
  field "results" "${work#"$LITE"/}"
  return "$status"
}

# ingest-queue stopped mid-step and started again, each moment written to the step's stall.log: how Redis
# grows while nothing drains it and how long the backlog takes to clear, both unmeasured until now. Its
# replicas are put back when the step is stopped part way too. A Ctrl-C that also ends the ssh tunnel first
# can leave it stopped: the stall.log then ends at "stopped", and
#   kubectl -n <namespace> scale deploy/langsmith-ingest-queue --replicas=1
# starts it again (make pods shows it at 0).
stall_ingest() {
  local ns="$1" after="$2" seconds="$3" log="$4" deploy="deploy/langsmith-ingest-queue" replicas
  sleep "$after"
  replicas="$(kubectl -n "$ns" get "$deploy" -o jsonpath='{.spec.replicas}')" || return 1
  # shellcheck disable=SC2064  # $replicas expanded now
  trap "kubectl -n '$ns' scale '$deploy' --replicas='$replicas' >/dev/null && echo \"\$(date -u +%s) started\" >>'$log'" EXIT
  trap 'exit 1' INT TERM
  echo "$(date -u +%s) stopped" >>"$log"
  kubectl -n "$ns" scale "$deploy" --replicas=0 >/dev/null
  # Waited on, not slept in the foreground: bash runs a trap only once a foreground command ends, and a
  # stall stopped part way kept ingest-queue stopped until its whole sleep was out (a fake kubectl, 2026-11-28).
  sleep "$seconds" &
  wait "$!"
}

minutes() { python3 -c "s = $1; print(f'{s / 60:g} minutes' if s % 60 == 0 else f'{s:g} s')"; }

# Every size measured the same way, for sizing from runs rather than from a model: for each size, a clean
# install held to that size's machine (emulate_machine), verify, then the load at each multiple of its
# design rate in turn, every run kept in one folder with its report. Each step is a verb of its own in a
# process of its own, so a size that fails is recorded and the next one still runs.
cmd_experiment() {
  need terraform python3 ssh kubectl uv
  local name out size sizes steps minutes traces
  name="$(tf_eval var.name)"
  out="$(experiment_folder)" || exit 1
  sizes="$(experiment_setting "$out" SIZES)" steps="$(experiment_setting "$out" STEPS)" minutes="$(experiment_setting "$out" MINUTES)"
  traces="$(experiment_setting "$out" TRACES)"
  STEP_VARIANTS="$(step_variants)" || exit 1
  check_steps "$steps" "$minutes" || exit 1
  heading "experiment" "each size from no data, held to its machine: verify, then $minutes minutes a step: ${steps// /, }"
  field "sizes" "$sizes"
  TRACES="$traces" traces_field
  for size in $sizes; do [[ -e "$out/$size/finished" ]] && field "$size" "finished earlier: kept"; done
  field "results" "${out#"$LITE"/}"
  field "root" "asked once a size, to install it"
  # Each size starts from no data, so the sizes differ in one thing; that deletes every trace each time.
  confirm_delete "$name" "for each size, every trace in $name and its Postgres, Redis and object store volumes; it reinstalls from no data" \
    "k3s, the images it pulled, the credentials, and the earlier experiments' results" ||
    fail "nothing changed" "the name did not match."
  for size in $sizes; do
    [[ -e "$out/$size/finished" ]] && continue
    # A size stopped part way is measured again from a clean install: its partial runs were taken on a
    # box holding data the rerun will not, so keeping both would put two unequal copies in the report.
    rm -rf "${out:?}/$size"
    # A size stops only when its down, up or verify fails, and each size after it would fail the same
    # way: magus, 2026-11-25, ran down and up for s, m and l against one timed-out sudo touch.
    experiment_size "$size" "$out/$size" "$name" "$steps" "$minutes" "$traces" ||
      fail "size $size stopped: its $(cat "$out/$size/stopped" 2>/dev/null || echo run) did not pass" "make experiment continues from $size; the sizes that finished are kept."
  done
  # Every size's steps, not its verify: a verify is a minute of one user, not a rate.
  heading "experiment" "every size"
  report "$out/report" "$out"/*/*x/
  cmd_compare "$out"
  next "make up   (the last size stays held to its machine until a plain make up lifts the cap)"
}

# The experiment to run: the newest under build/experiment with no report yet, continued with the
# settings it started with, or a new one when every earlier one finished or NEW=1. Stopping a run
# (Ctrl-C, a sleeping Mac) then costs the size it was on, not the sizes before it.
experiment_folder() {
  local last out
  last="$(find "$BUILD/experiment" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1)"
  # One with no settings file was started before experiments could continue: it starts again.
  if [[ -n "$last" && -e "$last/settings" && ! -e "$last/report" && "${NEW:-}" != 1 ]]; then
    local key
    for key in SIZES STEPS MINUTES TRACES; do
      [[ -z "${!key:-}" || "${!key}" == "$(experiment_setting "$last" "$key")" ]] ||
        fail "$key differs from the unfinished experiment ${last#"$LITE"/}" "NEW=1 starts a new one with $key=${!key}."
    done
    echo "$last"
    return 0
  fi
  out="$BUILD/experiment/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$out"
  # LABEL names the experiment in make compare's figures; COMMIT is the tree it ran.
  printf 'SIZES=%s\nSTEPS=%s\nMINUTES=%s\nTRACES=%s\nLABEL=%s\nCOMMIT=%s\n' "${SIZES:-xs s m l}" "${STEPS:-1 1 2 3}" "${MINUTES:-10}" "${TRACES:-agent}" \
    "${LABEL:-}" "$(git -C "$LITE" describe --always --dirty 2>/dev/null)" >"$out/settings"
  echo "$out"
}

# lib/steps.yaml as JSON, through Terraform's YAML reader as infra/pins.yaml is, so no YAML library is needed.
step_variants() { tf_eval 'yamldecode(file("../lib/steps.yaml"))' || fail "could not read lib/steps.yaml" "check it is valid YAML."; }

# Every step a multiple, or a multiple and a variant lib/steps.yaml defines: checked before any size is
# deleted, so a typo stops the experiment, not its third size an hour in.
check_steps() {
  python3 -c 'import json, re, sys
variants, names = json.loads(sys.argv[1]), ", ".join(json.loads(sys.argv[1]))
for step in sys.argv[2].split():
    m = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)(?::([a-z]+))?", step)
    if not m or (m[2] and m[2] not in variants):
        sys.exit(f"  ERROR  step {step!r}: a multiple (2, 1.5), or a multiple and one of {names} (2:projects)")
    v = variants.get(m[2]) or {}
    if v.get("stall_seconds") and 240 + v["stall_seconds"] >= 60 * v.get("minutes", int(sys.argv[3])):
        sys.exit(f"  ERROR  step {step!r}: its stall must end before the step does")' "$STEP_VARIANTS" "$1" "$2"
}

# A step's variant setting, empty when it has none.
step_setting() {
  python3 -c 'import json, sys; print((json.loads(sys.argv[1]).get(sys.argv[2]) or {}).get(sys.argv[3], ""))' "$STEP_VARIANTS" "$1" "$2"
}

experiment_setting() { awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$1/settings"; }

experiment_size() {
  local size="$1" dir="$2" name="$3" steps="$4" minutes="$5" traces="$6" design k i=0
  heading "experiment" "size $size"
  mkdir -p "$dir"
  export LITE_INNER=1
  # From no data on the same k3s: the box keeps k3s and every image it pulled, and each size costs one
  # root step, not a down and an up (two touches, k3s installed again and every image pulled again).
  # The cap rides on this up alone, never saved: the next plain make up lifts it.
  # Every size runs the versions the first one resolved, so the sizes differ in their size alone.
  local versions="${dir%/*}/versions.json" from=()
  [[ -e "$versions" ]] && from=(VERSIONS_FROM="$versions")
  env ${from[@]+"${from[@]}"} box="$size" TF_VAR_emulate_machine=true FRESH=1 CONFIRM="$name" YES=1 "$LITE/bin/lite" up || { echo install >"$dir/stopped"; return 1; }
  [[ -e "$versions" ]] || cp "$INFRA/resolved.auto.tfvars.json" "$versions"
  TRACES="$traces" OUT="$dir/verify" "$LITE/bin/lite" verify || { echo verify >"$dir/stopped"; return 1; }
  # The plan the size ran with, beside its steps: make compare sets what each workload used against what
  # it asked, and an experiment run after the sizing changed must be read against its own plan.
  tf_output plan >"$dir/plan.json"
  design="$(json_get runs_per_second <"$dir/plan.json")"
  # Each step's folder is numbered in order, as a multiple can repeat: STEPS 1 1 2 3 runs 1x again once
  # the install has warmed, so a first step slower than the second is the fresh install, not the load. The
  # first experiment's first steps after a fresh install were each size's slowest (magus, 2026-11-26).
  local step k variant what step_traces step_minutes
  for step in $steps; do
    i=$((i + 1))
    k="${step%%:*}" variant=""
    [[ "$step" == *:* ]] && variant="${step#*:}"
    what="$(step_setting "$variant" what)" step_traces="$(step_setting "$variant" traces)" step_minutes="$(step_setting "$variant" minutes)"
    [[ -n "$what" ]] && field "step $i" "${k}x, $what"
    # A step that does not hold still runs the next: where each one fails is what this measures. A stall
    # step does not hold by design; what it measures is Redis's growth and how long the backlog took.
    RATE="$(python3 -c "print(f'{$design * $k:g}')")" DURATION="$((${step_minutes:-$minutes} * 60))" TRACES="${step_traces:-$traces}" \
      LOADTEST_FLAGS="$(step_setting "$variant" flags)" STALL_SECONDS="$(step_setting "$variant" stall_seconds)" \
      OUT="$dir/$i-${k}x${variant:+-$variant}" "$LITE/bin/lite" soak ||
      warn "$size at $step (step $i) did not hold; the next step still runs"
  done
  heading "experiment" "size $size: what it held, and what it took"
  report "$dir/report" "$dir"/*x/ --design "$design"
  # Written last: a size without it was stopped, and the next make experiment measures it again.
  touch "$dir/finished"
}

# The load test's report of the runs in the folders given: figures in the LangChain brand (the faces and
# logo read where the ps-ops-center and content-studio checkouts keep them, or from FONTS and LOGOS; never
# copied here, and without them the figures are labelled drafts), every number as JSON and CSV, and each
# run's own files.
cmd_report() {
  need uv
  local folders=("$@")
  ((${#folders[@]})) || folders=("$BUILD"/soak/*/)
  heading "report" "${#folders[@]} folders of runs"
  report "$BUILD/report/$(date -u +%Y%m%dT%H%M%SZ)" "${folders[@]}"
}

# Experiments side by side: every size and every experiment on one scale, a row a step in steps.csv and
# the figures in the brand's dark theme (the load test's load-test-experiments). Each run's own report
# shows one size; this one shows what changed between them.
cmd_compare() {
  need uv
  local folders=("$@") out brand=()
  if ((${#folders[@]} == 0)); then
    for f in "$BUILD"/experiment/*/; do [[ -e "$f/settings" && -e "$f/report" ]] && folders+=("$f"); done
  fi
  ((${#folders[@]})) || fail "no finished experiment to compare" "make experiment runs one; or name the folders."
  out="$BUILD/compare/$(date -u +%Y%m%dT%H%M%SZ)"
  heading "compare" "${#folders[@]} experiments on one scale"
  if [[ -n "${FONTS:-}" ]]; then brand=(--fonts "$FONTS" ${LOGOS:+--logos "$LOGOS"}); else brand=(--draft); fi
  uv run --quiet --project "$LITE/../../utils/langsmith-load-test" load-test-experiments "$out" "${folders[@]}" "${brand[@]}" || exit 1
  field "figures" "${out#"$LITE"/}/figures"
}

report() {
  local out="$1" brand=()
  shift
  if [[ -n "${FONTS:-}" ]]; then brand=(--fonts "$FONTS" ${LOGOS:+--logos "$LOGOS"}); else brand=(--draft); fi
  uv run --quiet --project "$LITE/../../utils/langsmith-load-test" load-test-report "$out" "$@" "${brand[@]}" ||
    warn "no report for ${out#"$LITE"/}: the folders held no finished run"
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
