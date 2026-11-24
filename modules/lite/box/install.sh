#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# Runs on the box, as root, from the bundle make up and make install send:
#
#   sudo bash install.sh <bundle folder>
#
# 1. checks.sh: refuses a machine that cannot be this box (the same checks make preflight runs).
# 2. k3s at the pinned version with the bundle's config, or a restart when only the config changed.
# 3. The namespaces, the Retain storage class and Traefik's settings, then the Secrets, whose file is
#    deleted once applied.
# 4. Each release handed to k3s's helm-controller in order, the stores before LangSmith, waiting for
#    each install Job and for the stores to be ready before LangSmith's migrations run.
# 5. The ssh user's own kubeconfig, so reading the cluster needs no root.
# 6. Any release an earlier bundle had and this one does not, removed.
#
# A second run changes only what differs. Each step's output goes to /var/lib/langsmith-lite/logs/.
set -euo pipefail

SRC="${1:?usage: install.sh <bundle folder>}"
LITE_HOME=/var/lib/langsmith-lite
MANIFESTS=/var/lib/rancher/k3s/server/manifests
STATIC=/var/lib/rancher/k3s/server/static/charts
K3S_CONFIG=/etc/rancher/k3s/config.yaml
# Marks k3s as Lite's. Readable without root (checks.sh runs as the ssh user), so preflight and the
# install refuse a k3s server someone else installed, and make down removes only Lite's.
MARKER=/etc/rancher/k3s/installed-by-langsmith-lite

# shellcheck source=lib/ui.sh
source "$SRC/ui.sh"
[[ $EUID -eq 0 ]] || fail "install.sh runs as root" "make up and make install run it with sudo."

# lite.env: KEY=value lines Terraform wrote. Split at the first = by hand: IFS='=' read drops a value's
# trailing =, which cut the padding off a base64 token.
while IFS= read -r line; do
  [[ -n "$line" ]] && printf -v "${line%%=*}" '%s' "${line#*=}"
done <"$SRC/lite.env"
: "${NAME:?} ${K3S_VERSION:?} ${MACHINE_CPU:?} ${MACHINE_MEM_GI:?} ${MACHINE_DISK_GI:?} ${ACCESS:?} ${DATASTORES_TGZ:?}"
export MACHINE_CPU MACHINE_MEM_GI MACHINE_DISK_GI ACCESS

heading "$NAME" "k3s $K3S_VERSION on $(hostname)"

#--- 1. The machine -----------------------------------------------------------------------------------
# checks.sh exits on its first impossible machine (not Linux) and otherwise reports every row.
set +e
# shellcheck source=box/checks.sh
(source "$SRC/checks.sh")
checks=$?
set -e
((checks == 0)) || fail "this machine cannot be the box" "each FAIL above says why; make preflight runs the same checks."
printf '\n'

install -d -m 700 "$LITE_HOME" "$LITE_HOME/logs"
start_log "$LITE_HOME/logs"

#--- 2. k3s -------------------------------------------------------------------------------------------
config_changed=0
install -d -m 755 /etc/rancher/k3s
if ! cmp -s "$SRC/k3s-config.yaml" "$K3S_CONFIG" 2>/dev/null; then
  install -m 600 "$SRC/k3s-config.yaml" "$K3S_CONFIG"
  config_changed=1
fi

# k3s's installer at the pinned release's own tag, not get.k3s.io's latest script; it checks the
# binary's sha256 against the release's checksums.
# Marked before k3s starts: a failed first install is still Lite's to retry or remove.
install_k3s() {
  install -m 644 /dev/null "$MARKER"
  curl -sfL "https://raw.githubusercontent.com/k3s-io/k3s/${K3S_VERSION//+/%2B}/install.sh" |
    INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server
}
running="$(k3s --version 2>/dev/null | awk 'NR == 1 { print $3 }' || true)"
if [[ "$running" != "$K3S_VERSION" ]]; then
  run k3s "install k3s $K3S_VERSION${running:+ (was $running)}" install_k3s
elif ((config_changed)); then
  run k3s "restart k3s: its config changed" systemctl restart k3s
else
  run k3s "k3s $K3S_VERSION already running" systemctl is-active k3s
fi

kubectl() { k3s kubectl "$@"; }
node_ready() {
  local _
  for _ in $(seq 1 60); do
    kubectl get node "$NAME" >/dev/null 2>&1 && break
    sleep 5
  done
  kubectl wait --for=condition=Ready "node/$NAME" --timeout=300s &&
    # k3s registers its HelmChart kinds as it starts; applying one before they exist fails.
    kubectl wait --for=condition=Established crd/helmcharts.helm.cattle.io crd/helmchartconfigs.helm.cattle.io --timeout=120s
}
run node "wait for the node to be Ready" node_ready

#--- 3. Base and Secrets ------------------------------------------------------------------------------
install -d -m 755 "$STATIC"
install -m 644 "$SRC/$DATASTORES_TGZ" "$STATIC/$DATASTORES_TGZ"
run base "namespaces, storage class, Traefik" kubectl apply -f "$SRC/lite-00-base.yaml"
# Server-side apply: a client-side apply would copy every Secret's data into an annotation.
run secrets "every credential, as Secrets" \
  kubectl apply --server-side --force-conflicts --field-manager=langsmith-lite -f "$SRC/secrets.yaml"
rm -f "$SRC/secrets.yaml"

#--- 4. The releases ----------------------------------------------------------------------------------
# A HelmChart's install Job is helm-install-<name>, replaced when its HelmChart changes. A release whose
# manifest changed waits for a Job other than the one it had before (by uid); an unchanged release's
# last Job stands. Tracked per release: one time for the whole run made an upgrade of LangSmith wait out
# every unchanged release's timeout, then fail.
job_uid() { kubectl -n kube-system get job "helm-install-$1" -o jsonpath='{.metadata.uid}' 2>/dev/null || true; }

# place FILE RELEASE...: install the manifest if it changed, remembering each release's Job before.
place() {
  local file="$1" release
  shift
  cmp -s "$SRC/$file" "$MANIFESTS/$file" 2>/dev/null && return 0
  for release in "$@"; do printf -v "before_${release//-/_}" '%s' "$(job_uid "$release")"; done
  install -m 600 "$SRC/$file" "$MANIFESTS/$file"
}

# wait_release NAME SECONDS: its install Job succeeded (a new one, if its manifest changed). helm-controller
# retries a failed Job, as when the stores are still starting; three failures are not transient.
wait_release() {
  local name="$1" deadline=$((SECONDS + $2)) var uid failed
  var="before_${name//-/_}"
  while :; do
    uid="$(job_uid "$name")"
    # A Job exists and, if the manifest changed, it is not the one from before.
    if [[ -n "$uid" && (-z "${!var+set}" || "$uid" != "${!var:-}") ]]; then
      [[ "$(kubectl -n kube-system get job "helm-install-$name" -o jsonpath='{.status.succeeded}')" == 1 ]] && return 0
      failed="$(kubectl -n kube-system get job "helm-install-$name" -o jsonpath='{.status.failed}')"
      if ((${failed:-0} >= 3)); then
        echo "installing $name failed ${failed} times; the install Job's log:"
        kubectl -n kube-system logs "job/helm-install-$name" --tail=40 || true
        return 1
      fi
    fi
    if ((SECONDS >= deadline)); then
      echo "installing $name did not finish in $2 s; the install Job's log:"
      kubectl -n kube-system logs "job/helm-install-$name" --tail=40 || true
      return 1
    fi
    sleep 5
  done
}

stores_ready() {
  local sts
  for sts in postgres-langsmith redis-langsmith rustfs; do
    kubectl -n langsmith-data rollout status "statefulset/$sts" --timeout=600s || return 1
  done
}

place lite-10-datastores.yaml datastores
run datastores "Postgres, Redis, RustFS" wait_release datastores 900
run stores "the stores ready" stores_ready

place lite-20-langsmith.yaml langsmith
place lite-30-observe.yaml prometheus grafana redis-exporter postgres-exporter
place lite-40-mission-control.yaml mission-control
if [[ -f "$SRC/lite-50-tunnel.yaml" ]]; then place lite-50-tunnel.yaml; fi
run langsmith "LangSmith (first install pulls every image)" wait_release langsmith 1800
run prometheus "Prometheus" wait_release prometheus 900
run grafana "Grafana and its dashboards" wait_release grafana 900
run redis-exp "the Redis exporter" wait_release redis-exporter 600
run postgres-exp "the Postgres exporter" wait_release postgres-exporter 600
run mission "Mission Control" wait_release mission-control 900
run available "every LangSmith deployment available" \
  kubectl -n langsmith wait --for=condition=Available deployment --all --timeout=900s

#--- 5. The ssh user's kubeconfig ---------------------------------------------------------------------
# k3s's own copy stays root-only (write-kubeconfig-mode 0600); this one is the ssh user's alone, so make
# status and make access read the cluster without root.
user_kubeconfig() {
  local home
  home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
  [[ -n "$home" ]] || home="$(awk -F: -v u="$SUDO_USER" '$1 == u { print $6 }' /etc/passwd)"
  install -d -m 700 -o "$SUDO_USER" "$home/.kube"
  install -m 600 -o "$SUDO_USER" /etc/rancher/k3s/k3s.yaml "$home/.kube/langsmith-lite.yaml"
}
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
  run kubeconfig "a kubeconfig for $SUDO_USER" user_kubeconfig
fi

#--- 6. What this bundle no longer has ----------------------------------------------------------------
retire() {
  local old
  for old in "$MANIFESTS"/lite-*.yaml; do
    [[ -e "$old" && ! -f "$SRC/$(basename "$old")" ]] || continue
    kubectl delete -f "$old" --ignore-not-found
    rm -f "$old"
  done
  for old in "$STATIC"/datastores-*.tgz; do
    [[ "$(basename "$old")" == "$DATASTORES_TGZ" ]] || rm -f "$old"
  done
}
run retire "remove what an earlier install had and this one lacks" retire

printf '\n'
field "logs" "$LOG_DIR"
