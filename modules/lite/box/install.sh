#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# Runs on the box, as root, from the bundle make up sends:
#
#   sudo bash install.sh <bundle folder> [fresh]
#
# fresh removes this install's releases, namespaces and volumes first, so it starts from no data on the
# same k3s: no k3s reinstall and no image pulled again (make up FRESH=1, and make experiment each size).
#
# Checks the machine, installs k3s, hands each release to k3s's helm-controller in order, and removes
# what an earlier bundle had and this one lacks. A second run changes only what differs. Each step's
# output goes to /var/lib/langsmith-lite/logs/.
set -euo pipefail

SRC="${1:?usage: install.sh <bundle folder> [fresh]}"
FRESH="${2:-}"
LITE_HOME=/var/lib/langsmith-lite
MANIFESTS=/var/lib/rancher/k3s/server/manifests
STATIC=/var/lib/rancher/k3s/server/static/charts
K3S_CONFIG=/etc/rancher/k3s/config.yaml
# Marks k3s as Lite's. Readable without root (checks.sh runs as the ssh user), so a k3s server someone
# else installed is refused and make down removes only Lite's.
MARKER=/etc/rancher/k3s/installed-by-langsmith-lite

# shellcheck source=lib/ui.sh
source "$SRC/ui.sh"
[[ $EUID -eq 0 ]] || fail "install.sh runs as root" "make up runs it with sudo."
[[ -z "$FRESH" || "$FRESH" == fresh ]] || fail "install.sh: unknown argument $FRESH" "the only one is fresh."

# lite.env, KEY=value lines. Split at the first = by hand: IFS='=' read drops a value's trailing =, which
# cut the padding off a base64 token.
while IFS= read -r line; do
  [[ -n "$line" ]] && printf -v "${line%%=*}" '%s' "${line#*=}"
done <"$SRC/lite.env"
: "${NAME:?} ${K3S_VERSION:?} ${MACHINE_CPU:?} ${MACHINE_MEM_GI:?} ${MACHINE_DISK_GI:?} ${ACCESS:?} ${DATASTORES_TGZ:?}"
: "${DATA_MOUNT:?} ${NS:?} ${NS_DATA:?} ${RELEASES:?} ${POD_CPU_M:?} ${POD_MEM_MI:?}"
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
# On AWS the data volume is mounted at k3s's storage folder before k3s starts. It is formatted only if it
# has no filesystem: a reattached volume keeps its data. Found by the volume's id, as Nitro instances
# name NVMe devices in attach order, not by the name Terraform asked for.
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

# k3s starts only with its own data disk (the AWS volume or a data_path) mounted: a disk missing at boot
# (fstab's nofail keeps the box bootable) once left k3s on the root disk's empty folder, where Postgres
# initialised a new, empty database.
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

# k3s's installer at the pinned release's own tag, not get.k3s.io's latest script; it checks the binary's
# sha256. Marked first: a failed first install is still Lite's to retry or remove.
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

# emulate_machine: every pod together held to the size's machine less its reservation, through the slice
# systemd runs them in, so a small size measured on a large box (make experiment) meets its own limits.
# set-property applies at once and persists; empty values lift a cap an earlier install set. ponytail:
# CPU and memory only, not the disk's size or speed, nor k3s's own server, which runs outside the slice.
cap_pods() {
  if ((POD_CPU_M > 0)); then
    systemctl set-property kubepods.slice CPUQuota="$((POD_CPU_M / 10))%" MemoryMax="${POD_MEM_MI}M"
  else
    systemctl set-property kubepods.slice CPUQuota= MemoryMax=
  fi
  echo "kubepods.slice cpu.max: $(cat /sys/fs/cgroup/kubepods.slice/cpu.max), memory.max: $(cat /sys/fs/cgroup/kubepods.slice/memory.max)"
}
if ((POD_CPU_M > 0)); then
  run machine "every pod held to ${POD_CPU_M}m CPU and ${POD_MEM_MI}Mi memory (emulate_machine)" cap_pods
else
  run machine "no cap on the pods" cap_pods
fi

# unplace FILE: take a manifest out of k3s's folder, delete what it made, and forget it. k3s keeps an
# Addon per manifest with the file's checksum and skips a file whose checksum it has applied: left
# behind, a release removed and placed again unchanged never came back (magus, 2026-11-26: after
# FRESH=1, Grafana, the exporters and Mission Control, whose manifests are the same at every size, had
# no HelmChart).
unplace() {
  local file="$1" held status
  held="$(mktemp -d)"
  mv "$file" "$held/"
  kubectl delete -f "$held/$(basename "$file")" --ignore-not-found --wait --timeout=600s &&
    kubectl -n kube-system delete addon "$(basename "$file" .yaml)" --ignore-not-found
  status=$?
  rm -rf "$held"
  return $status
}

#--- 4. A fresh start ---------------------------------------------------------------------------------
# Each release's manifest is unplaced; deleting its HelmChart has helm-controller uninstall the release. The namespaces go with everything in them. The stores'
# volumes are Retain, so their volumes and folders are removed by name: only a volume claimed in one of
# this install's namespaces, and only a folder named for that volume.
remove_volume() {
  local pv="$1" path
  path="$(kubectl get pv "$pv" -o jsonpath='{.spec.local.path}{.spec.hostPath.path}')" || return 1
  # Checked before anything is deleted, so a volume that is not local-path's is left whole.
  [[ -z "$path" || "$(basename "$path")" == "${pv}_"* ]] || { echo "volume $pv: $path is not a folder local-path made for it, left in place"; return 1; }
  kubectl delete pv "$pv" --wait --timeout=120s || return 1
  [[ -z "$path" ]] || rm -rf "$path"
}

start_fresh() {
  local selector="langsmith-lite/instance=$NAME" namespaces volumes file pv
  for file in "$MANIFESTS"/lite-[0-9][0-9]-*.yaml; do
    [[ -e "$file" && "$(basename "$file")" != lite-00-base.yaml ]] || continue
    echo "removing $(basename "$file")"
    unplace "$file" || return 1
  done
  namespaces="$(kubectl get ns -l "$selector" -o jsonpath='{.items[*].metadata.name}')" || return 1
  namespaces=" $namespaces "
  echo "removing namespaces:${namespaces% }"
  kubectl delete ns -l "$selector" --wait --timeout=600s || return 1
  # Read before the loop: an unreadable list would otherwise look like no volumes and leave every one.
  volumes="$(kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}={.spec.claimRef.namespace}{"\n"}{end}')" || return 1
  for pv in $volumes; do
    [[ "$namespaces" == *" ${pv#*=} "* ]] || continue
    echo "removing volume ${pv%%=*}"
    remove_volume "${pv%%=*}" || return 1
  done
}
if [[ -n "$FRESH" ]]; then
  run fresh "remove this install's releases, namespaces and volumes: it starts from no data" start_fresh
fi

#--- 5. Base and Secrets ------------------------------------------------------------------------------
install -d -m 755 "$STATIC"
install -m 644 "$SRC/$DATASTORES_TGZ" "$STATIC/$DATASTORES_TGZ"
run base "namespaces, storage class, Traefik" kubectl apply -f "$SRC/lite-00-base.yaml"
# Server-side apply: a client-side apply would copy every Secret's data into an annotation.
run secrets "every credential, as Secrets" \
  kubectl apply --server-side --force-conflicts --field-manager=langsmith-lite -f "$SRC/secrets.yaml"
rm -f "$SRC/secrets.yaml"

#--- 6. The ssh user's kubeconfig ---------------------------------------------------------------------
# The operator ServiceAccount's (bundle.tf), not k3s's admin one, which stays root-only. Written before
# the releases: written after them, a release that failed left nothing to read it with but root (magus).
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

#--- 7. The releases ----------------------------------------------------------------------------------
# A HelmChart's install Job (helm-install-<name>) is replaced when the HelmChart changes. A changed
# release waits for a Job with a new uid; an unchanged one's last Job stands. Tracked per release: one
# time for the whole run made an upgrade of LangSmith wait out every unchanged release's timeout.
job_uid() { kubectl -n kube-system get job "helm-install-$1" -o jsonpath='{.metadata.uid}' 2>/dev/null || true; }

# place FILE RELEASE...: install the manifest if it changed, noting each release's Job beforehand.
place() {
  local file="$1" release
  shift
  cmp -s "$SRC/$file" "$MANIFESTS/$file" 2>/dev/null && return 0
  for release in "$@"; do printf -v "before_${release//-/_}" '%s' "$(job_uid "$release")"; done
  install -m 600 "$SRC/$file" "$MANIFESTS/$file"
}

# wait_release NAME SECONDS: helm-controller retries a failed Job (the stores may still be starting);
# three failures are not transient.
wait_release() {
  local name="$1" deadline=$((SECONDS + $2)) var uid failed
  var="before_${name//-/_}"
  while :; do
    uid="$(job_uid "$name")"
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

# One manifest a release (lite-NN-<release>.yaml): the stores first, ready before LangSmith's migrations
# need them, then the rest.
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

#--- 8. What this bundle no longer has ----------------------------------------------------------------
# A manifest this bundle lacks is removed, but its objects only when no file here carries the same
# release: deleting by file alone would uninstall a merely renamed release, stores included.
retire() {
  local old release
  for old in "$MANIFESTS"/lite-*.yaml; do
    [[ -e "$old" && ! -f "$SRC/$(basename "$old")" ]] || continue
    release="$(basename "$old" .yaml | sed 's/^lite-[0-9][0-9]-//')"
    if [[ " $RELEASES tunnel base " != *" $release "* ]]; then
      unplace "$old" || return 1
    else
      # A release still here under a new file name: its objects stay, and k3s forgets the old name.
      rm -f "$old"
      kubectl -n kube-system delete addon "$(basename "$old" .yaml)" --ignore-not-found
    fi
  done
  for old in "$STATIC"/datastores-*.tgz; do
    [[ "$(basename "$old")" == "$DATASTORES_TGZ" ]] || rm -f "$old"
  done
}
run retire "remove what an earlier install had and this one lacks" retire

printf '\n'
field "logs" "$LOG_DIR"
