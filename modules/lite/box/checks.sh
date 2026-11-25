#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# Whether this machine can be a Lite box, read-only and without root. Run by make preflight (over ssh,
# before anything is installed) and by box/install.sh first, so a box passes or fails the same way.
#
#   MACHINE_CPU MACHINE_MEM_GI MACHINE_DISK_GI   the machine the plan is for; the disk is the system's
#   DATA_MOUNT DATA_DISK_GI DATA_VOLUME_ID       where the volumes go, when they have a disk of their own
#   ACCESS                                       localhost, ip, dns or tunnel
#
# One row a check: ok, warn (it may work; the detail says what to watch) or FAIL (it will not). Exit 1
# when any check fails. Needs lib/ui.sh's row, sourced before this file.

: "${MACHINE_CPU:?} ${MACHINE_MEM_GI:?} ${MACHINE_DISK_GI:?} ${ACCESS:?}"
failed=0
ours=0
check() {
  row "$@"
  [[ "$1" != FAIL ]] || failed=1
}

gib_of() { df -Pk "$1" | awk -v col="$2" 'NR == 2 { printf "%d", $col / 1048576 }'; }

# The systems the install is written against; others with systemd usually work.
check_os() {
  # shellcheck source=/dev/null  # the box's own
  . /etc/os-release 2>/dev/null || true
  local os="${PRETTY_NAME:-unknown Linux}"
  case " ${ID:-} ${ID_LIKE:-} " in
    *" ubuntu "* | *" debian "* | *" arch "*) check ok os "$os" ;;
    *" rhel "* | *" fedora "* | *" centos "* | *" amzn "*)
      check warn os "$os: untested; with SELinux enforcing, k3s needs the k3s-selinux package" ;;
    *) check warn os "$os: untested; k3s needs systemd, iptables or nftables, and cgroups" ;;
  esac
}

check_arch() {
  case "$(uname -m)" in
    x86_64 | aarch64) check ok arch "$(uname -m)" ;;
    *) check FAIL arch "$(uname -m): k3s runs on amd64 and arm64" ;;
  esac
}

check_init() {
  local init
  init="$(ps -p 1 -o comm= 2>/dev/null || echo unknown)"
  if [[ "$init" == systemd ]]; then check ok init "systemd"; else
    check FAIL init "$init: k3s installs as a systemd service"; fi
}

check_cgroups() {
  if [[ ! -f /sys/fs/cgroup/cgroup.controllers ]]; then
    check warn cgroups "v1: k3s runs, but v2 is what Lite is written for"
    return
  fi
  local controllers
  controllers="$(cat /sys/fs/cgroup/cgroup.controllers)"
  if [[ " $controllers " == *" cpu "* && " $controllers " == *" memory "* ]]; then
    check ok cgroups "v2, cpu and memory"
  else
    check FAIL cgroups "v2 without the cpu or memory controller ($controllers): pod limits cannot be enforced"
  fi
}

# The machine against the plan. The kernel and firmware keep some memory, so a machine of exactly the
# planned size reports up to a tenth less of it.
check_size() {
  local cpus mem_gi
  cpus="$(nproc)"
  mem_gi="$(awk '/^MemTotal:/ { printf "%d", $2 / 1048576 }' /proc/meminfo)"
  if ((cpus >= MACHINE_CPU)); then check ok cpu "$cpus vCPU (the plan: $MACHINE_CPU)"; else
    check FAIL cpu "$cpus vCPU, the plan is for $MACHINE_CPU: set machine to what it is, or use a bigger one"; fi
  if ((mem_gi * 10 >= MACHINE_MEM_GI * 9)); then check ok memory "$mem_gi GiB (the plan: $MACHINE_MEM_GI)"; else
    check FAIL memory "$mem_gi GiB, the plan is for $MACHINE_MEM_GI"; fi
}

# The system disk's size against the plan (the filesystem keeps up to a tenth); on a first install its
# free space too (an update's volumes already use some of it, by design).
check_disk() {
  local disk_gi free_gi
  disk_gi="$(gib_of /var/lib 2)"
  free_gi="$(gib_of /var/lib 4)"
  if ((disk_gi * 10 < MACHINE_DISK_GI * 9)); then
    check FAIL disk "$disk_gi GiB under /var/lib, the plan is for $MACHINE_DISK_GI"
  elif [[ ! -e /etc/rancher/k3s/installed-by-langsmith-lite ]] && ((free_gi * 10 < MACHINE_DISK_GI * 9)); then
    check FAIL disk "$free_gi GiB free of $disk_gi under /var/lib, the plan needs $MACHINE_DISK_GI"
  else
    check ok disk "$disk_gi GiB under /var/lib, $free_gi free (the plan: $MACHINE_DISK_GI)"
  fi
}

# An AWS data volume is attached but not yet mounted on a first install; a data_path is mounted apart from /.
check_data() {
  if [[ -n "${DATA_VOLUME_ID:-}" ]]; then
    if ls /dev/disk/by-id/*"${DATA_VOLUME_ID//-/}"* >/dev/null 2>&1; then
      check ok data "volume ${DATA_VOLUME_ID} attached; mounted at ${DATA_MOUNT} by the install"
    else
      check FAIL data "volume ${DATA_VOLUME_ID} is not attached to this instance"
    fi
    return
  fi
  [[ "${DATA_MOUNT:-/}" != / ]] || return 0
  if ! mountpoint -q "$DATA_MOUNT" 2>/dev/null; then
    check FAIL data "$DATA_MOUNT is not a mounted filesystem: mount the data disk there, or clear data_path"
    return
  fi
  local data_gi
  data_gi="$(gib_of "$DATA_MOUNT" 2)"
  if ((data_gi * 10 >= ${DATA_DISK_GI:-0} * 9)); then check ok data "$DATA_MOUNT, $data_gi GiB (the plan: ${DATA_DISK_GI:-0})"; else
    check FAIL data "$DATA_MOUNT has $data_gi GiB, the plan needs ${DATA_DISK_GI:-0}"; fi
}

# An agent of another cluster is refused: a server would inherit its certificates.
check_k3s() {
  if [[ -e /etc/systemd/system/k3s-agent.service ]]; then
    check FAIL k3s "an agent of another cluster: remove it first with /usr/local/bin/k3s-agent-uninstall.sh"
  elif [[ -e /etc/systemd/system/k3s.service && ! -e /etc/rancher/k3s/installed-by-langsmith-lite ]]; then
    check FAIL k3s "a k3s server Lite did not install: Lite would take it over; use another machine, or remove it with /usr/local/bin/k3s-uninstall.sh"
  elif [[ -e /etc/systemd/system/k3s.service ]]; then
    ours=1
    check ok k3s "installed by Lite ($(k3s --version 2>/dev/null | awk 'NR == 1 { print $3 }')): this is an update"
  else
    check ok k3s "not installed"
  fi
}

# 80 and 443 only when Traefik serves the box's address.
check_ports() {
  local ports="6443 10250" held="" p
  [[ "$ACCESS" != ip && "$ACCESS" != dns ]] || ports="$ports 80 443"
  if ((ours)); then
    check ok ports "held by this install's k3s"
    return
  fi
  if ! command -v ss >/dev/null; then
    check warn ports "cannot tell (no ss): $ports must be free"
    return
  fi
  for p in $ports; do
    ! ss -ltnH "sport = :$p" 2>/dev/null | grep -q . || held="$held $p"
  done
  if [[ -z "$held" ]]; then check ok ports "free: $ports"; else
    check FAIL ports "in use:$held; stop what holds them (ss -ltnp shows it, with sudo)"; fi
}

# A host firewall drops k3s's pod and service traffic unless those ranges are opened (docs.k3s.io,
# requirements). Not 6443: the docs open it for agents on other machines, and on one box it would only
# expose k3s's API to the network.
UFW_RULES="ufw allow from 10.42.0.0/16 to any; ufw allow from 10.43.0.0/16 to any"
check_firewall() {
  if systemctl is-active -q firewalld 2>/dev/null; then
    check warn firewall "firewalld is on: allow the 10.42.0.0/16 and 10.43.0.0/16 ranges into the trusted zone, or turn it off"
  # ufw.conf, not ufw status: status needs root, and read as the ssh user its error passed for off
  # (magus, 2026-11-24, where the install then found it on).
  elif grep -qs '^ENABLED=yes' /etc/ufw/ufw.conf; then
    check_ufw_rules
  else
    check ok firewall "no firewalld or ufw running"
  fi
}

check_ufw_rules() {
  if ((EUID != 0)); then
    check warn firewall "ufw is on; its rules need root to read, so the install checks them. If k3s's are missing, as root: $UFW_RULES"
  elif ufw status | grep -q '10.42.0.0/16' && ufw status | grep -q '10.43.0.0/16'; then
    check ok firewall "ufw is on and allows k3s's pod and service ranges"
  else
    check FAIL firewall "ufw is on and would drop k3s's pod and service traffic; as root: $UFW_RULES"
  fi
}

# Docker sets the FORWARD policy to DROP; k3s adds rules for its own ranges, which usually suffices.
check_docker() {
  ! systemctl is-active -q docker 2>/dev/null ||
    check warn docker "running beside k3s: if pods cannot reach each other, Docker's FORWARD DROP is why"
}

# What the install downloads: k3s's installer and binary, the charts, the images, the dashboards. Never
# get.k3s.io, which the install does not use: checking it failed an install on a host that reached
# everything needed (magus, 2026-11-24).
check_internet() {
  local unreachable="" url code
  for url in https://github.com https://registry-1.docker.io/v2/ https://quay.io \
    https://registry.k8s.io https://langchain-ai.github.io/helm/index.yaml https://raw.githubusercontent.com \
    https://prometheus-community.github.io/helm-charts/index.yaml https://grafana-community.github.io/helm-charts/index.yaml; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$url" 2>/dev/null || true)"
    [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] || unreachable="$unreachable ${url#https://}"
  done
  if [[ -z "$unreachable" ]]; then check ok internet "k3s, the charts and the images are reachable"; else
    check FAIL internet "unreachable:$unreachable (a proxy or an air gap is not supported yet)"; fi
}

check_sudo() {
  # Under the install this runs as root, where sudo -n always passes: it printed "passwordless" on a
  # box that asks for a key's touch (magus, 2026-11-25). Only make preflight, as the ssh user, can tell.
  ((EUID == 0)) && return 0
  if sudo -n true 2>/dev/null; then check ok sudo "passwordless"; else
    check ok sudo "asks for a password or a key's touch: make up asks once"; fi
}

# k3s runs on Linux only; a Mac or Windows machine runs Lite inside a Linux VM (OPERATE.md, The machine).
if [[ "$(uname -s)" != Linux ]]; then
  check FAIL os "$(uname -s): k3s needs Linux; run Lite in a Linux VM on this machine"
  exit 1
fi
check_os
check_arch
check_init
check_cgroups
check_size
check_disk
check_data
check_k3s
check_ports
check_firewall
check_docker
check_internet
check_sudo
exit "$failed"
