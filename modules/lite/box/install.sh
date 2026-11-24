#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# Runs on the box, as root, from the bundle make up sends:
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
[[ $EUID -eq 0 ]] || fail "install.sh runs as root" "make up runs it with sudo."

# lite.env: KEY=value lines Terraform wrote. Split at the first = by hand: IFS='=' read drops a value's
# trailing =, which cut the padding off a base64 token.
while IFS= read -r line; do
  [[ -n "$line" ]] && printf -v "${line%%=*}" '%s' "${line#*=}"
done <"$SRC/lite.env"
: "${NAME:?} ${K3S_VERSION:?} ${MACHINE_CPU:?} ${MACHINE_MEM_GI:?} ${MACHINE_DISK_GI:?} ${ACCESS:?} ${DATASTORES_TGZ:?}"
: "${DATA_MOUNT:?} ${NS:?} ${NS_DATA:?} ${RELEASES:?}"
export MACHINE_CPU MACHINE_MEM_GI MACHINE_DISK_GI DATA_DISK_GI DATA_MOUNT DATA_VOLUME_ID ACCESS

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

#--- 2. The data volume -------------------------------------------------------------------------------
# On AWS the data volume is mounted at k3s's own storage folder before k3s starts, so every store's
# volume lands on it. It is formatted only if it has no filesystem: a reattached volume keeps its data.
# The device is found by the volume's id (Nitro instances name NVMe devices in attach order, not by
# the device name Terraform asked for).
mount_data_volume() {
  local dev uuid found
  found=(/dev/disk/by-id/*"${DATA_VOLUME_ID//-/}"*)
  dev="${found[0]}"
  [[ -e "$dev" ]] || { echo "the data volume $DATA_VOLUME_ID is not attached"; return 1; }
  dev="$(readlink -f "$dev")"
  blkid "$dev" >/dev/null 2>&1 || mkfs.ext4 -q -L langsmith-data "$dev"
  uuid="$(blkid -s UUID -o value "$dev")"
  install -d -m 755 "$DATA_MOUNT"
  grep -q "UUID=$uuid" /etc/fstab || echo "UUID=$uuid $DATA_MOUNT ext4 defaults,nofail 0 2" >>/etc/fstab
  mountpoint -q "$DATA_MOUNT" || mount "$DATA_MOUNT"
  # A grown volume: the filesystem follows it.
  resize2fs "$dev" >/dev/null
}
if [[ -n "${DATA_VOLUME_ID:-}" ]]; then
  run data "the data volume at $DATA_MOUNT" mount_data_volume
fi

# A data disk of its own, the AWS volume or a data_path: k3s starts only with it mounted. Without this,
# a disk missing at boot (fstab's nofail keeps the box bootable) left k3s to start on the empty folder of
# the root disk, where Postgres initialised a new, empty database.
require_data_mount() {
  mountpoint -q "$DATA_MOUNT" || { echo "$DATA_MOUNT is not a mounted filesystem: mount the data disk there first"; return 1; }
  install -d -m 755 /etc/systemd/system/k3s.service.d
  printf '[Unit]\nRequiresMountsFor=%s\n' "$DATA_MOUNT" >/etc/systemd/system/k3s.service.d/langsmith-lite-data.conf
  systemctl daemon-reload
}
if [[ "$DATA_MOUNT" != / ]]; then
  run mounted "k3s starts only with $DATA_MOUNT mounted" require_data_mount
fi

#--- 3. k3s -------------------------------------------------------------------------------------------
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

#--- 4. Base and Secrets ------------------------------------------------------------------------------
install -d -m 755 "$STATIC"
install -m 644 "$SRC/$DATASTORES_TGZ" "$STATIC/$DATASTORES_TGZ"
run base "namespaces, storage class, Traefik" kubectl apply -f "$SRC/lite-00-base.yaml"
# Server-side apply: a client-side apply would copy every Secret's data into an annotation.
run secrets "every credential, as Secrets" \
  kubectl apply --server-side --force-conflicts --field-manager=langsmith-lite -f "$SRC/secrets.yaml"
rm -f "$SRC/secrets.yaml"

#--- 5. The releases ----------------------------------------------------------------------------------
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
    kubectl -n "$NS_DATA" rollout status "statefulset/$sts" --timeout=600s || return 1
  done
}

# One manifest a release (lite-NN-<release>.yaml), in install order: the stores first, waited for before
# LangSmith's migrations need them; then every other release.
declare -A labels=(
  [datastores]="Postgres, Redis, RustFS" [langsmith]="LangSmith (a first install pulls every image)"
  [prometheus]="Prometheus" [grafana]="Grafana and its dashboards" [redis-exporter]="the Redis exporter"
  [postgres-exporter]="the Postgres exporter" [mission-control]="Mission Control"
)
release_file() { ls "$SRC"/lite-[0-9][0-9]-"$1".yaml; }
place "$(basename "$(release_file datastores)")" datastores
run datastores "${labels[datastores]}" wait_release datastores 900
run stores "the stores ready" stores_ready
for r in $RELEASES; do
  [[ "$r" == datastores ]] || place "$(basename "$(release_file "$r")")" "$r"
done
if [[ -f "$SRC/lite-90-tunnel.yaml" ]]; then place lite-90-tunnel.yaml; fi
for r in $RELEASES; do
  [[ "$r" == datastores ]] || run "$r" "${labels[$r]:-$r}" wait_release "$r" 1800
done
run available "every LangSmith deployment available" \
  kubectl -n "$NS" wait --for=condition=Available deployment --all --timeout=900s

#--- 6. The ssh user's kubeconfig ---------------------------------------------------------------------
# k3s's admin kubeconfig stays root-only (write-kubeconfig-mode 0600). The ssh user's is the operator
# ServiceAccount's (bundle.tf): what make status, access, verify and soak use, not cluster-admin.
user_kubeconfig() {
  local home token="" ca tmp
  home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
  [[ -n "$home" ]] || home="$(awk -F: -v u="$SUDO_USER" '$1 == u { print $6 }' /etc/passwd)"
  # The token controller fills the Secret a moment after it is created.
  for _ in $(seq 1 30); do
    token="$(kubectl -n kube-system get secret langsmith-lite-operator -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)"
    [[ -n "$token" ]] && break
    sleep 1
  done
  [[ -n "$token" ]] || { echo "the operator ServiceAccount's token was never issued"; return 1; }
  ca="$(awk '/certificate-authority-data:/ { print $2; exit }' /etc/rancher/k3s/k3s.yaml)"
  install -d -m 700 -o "$SUDO_USER" "$home/.kube"
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: langsmith-lite
    cluster: { server: "https://127.0.0.1:6443", certificate-authority-data: "$ca" }
users:
  - name: langsmith-lite-operator
    user: { token: "$token" }
contexts:
  - name: langsmith-lite
    context: { cluster: langsmith-lite, user: langsmith-lite-operator }
current-context: langsmith-lite
EOF
  install -m 600 -o "$SUDO_USER" "$tmp" "$home/.kube/langsmith-lite.yaml"
  rm -f "$tmp"
}
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
  run kubeconfig "a kubeconfig for $SUDO_USER" user_kubeconfig
fi

#--- 7. What this bundle no longer has ----------------------------------------------------------------
# A manifest file this bundle lacks is removed; the objects in it are deleted only when no file in this
# bundle carries the same release. Deleting by file alone would uninstall a release whose manifest was
# only renamed (its HelmChart deleted, helm-controller uninstalls it, and the stores with it).
retire() {
  local old release
  for old in "$MANIFESTS"/lite-*.yaml; do
    [[ -e "$old" && ! -f "$SRC/$(basename "$old")" ]] || continue
    release="$(basename "$old" .yaml | sed 's/^lite-[0-9][0-9]-//')"
    if [[ " $RELEASES tunnel base " != *" $release "* ]]; then
      kubectl delete -f "$old" --ignore-not-found
    fi
    rm -f "$old"
  done
  for old in "$STATIC"/datastores-*.tgz; do
    [[ "$(basename "$old")" == "$DATASTORES_TGZ" ]] || rm -f "$old"
  done
}
run retire "remove what an earlier install had and this one lacks" retire

printf '\n'
field "logs" "$LOG_DIR"
