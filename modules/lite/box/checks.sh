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
check() {
  row "$@"
  [[ "$1" != FAIL ]] || failed=1
}

# k3s runs on Linux only; a Mac or Windows machine runs Lite inside a Linux VM (OPERATE.md, The machine).
if [[ "$(uname -s)" != Linux ]]; then
  check FAIL os "$(uname -s): k3s needs Linux; run Lite in a Linux VM on this machine"
  exit 1
fi

# The systems the install is written against; others with systemd usually work, and say so.
# shellcheck source=/dev/null  # the box's own
. /etc/os-release 2>/dev/null || true
os="${PRETTY_NAME:-unknown Linux}"
case " ${ID:-} ${ID_LIKE:-} " in
  *" ubuntu "* | *" debian "* | *" arch "*) check ok os "$os" ;;
  *" rhel "* | *" fedora "* | *" centos "* | *" amzn "*)
    check warn os "$os: untested; with SELinux enforcing, k3s needs the k3s-selinux package" ;;
  *) check warn os "$os: untested; k3s needs systemd, iptables or nftables, and cgroups" ;;
esac

case "$(uname -m)" in
  x86_64 | aarch64) check ok arch "$(uname -m)" ;;
  *) check FAIL arch "$(uname -m): k3s runs on amd64 and arm64" ;;
esac

if [[ "$(ps -p 1 -o comm= 2>/dev/null)" == systemd ]]; then
  check ok init "systemd"
else
  check FAIL init "$(ps -p 1 -o comm= 2>/dev/null || echo unknown): k3s installs as a systemd service"
fi

if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
  controllers="$(cat /sys/fs/cgroup/cgroup.controllers)"
  if [[ " $controllers " == *" cpu "* && " $controllers " == *" memory "* ]]; then
    check ok cgroups "v2, cpu and memory"
  else
    check FAIL cgroups "v2 without the cpu or memory controller ($controllers): pod limits cannot be enforced"
  fi
else
  check warn cgroups "v1: k3s runs, but v2 is what Lite is written for"
fi

# The machine against the plan. The kernel and firmware keep some memory and the filesystem some disk,
# so a machine of exactly the planned size reports up to a tenth less of each.
cpus="$(nproc)"
mem_gi="$(awk '/^MemTotal:/ { printf "%d", $2 / 1048576 }' /proc/meminfo)"
disk_gi="$(df -Pk /var/lib | awk 'NR == 2 { printf "%d", $2 / 1048576 }')"
free_gi="$(df -Pk /var/lib | awk 'NR == 2 { printf "%d", $4 / 1048576 }')"
if ((cpus >= MACHINE_CPU)); then check ok cpu "$cpus vCPU (the plan: $MACHINE_CPU)"; else
  check FAIL cpu "$cpus vCPU, the plan is for $MACHINE_CPU: set machine to what it is, or use a bigger one"; fi
if ((mem_gi * 10 >= MACHINE_MEM_GI * 9)); then check ok memory "$mem_gi GiB (the plan: $MACHINE_MEM_GI)"; else
  check FAIL memory "$mem_gi GiB, the plan is for $MACHINE_MEM_GI"; fi
# The disk's size against the plan; on a first install its free space too (an update's volumes already
# use some of it, by design).
if ((disk_gi * 10 < MACHINE_DISK_GI * 9)); then
  check FAIL disk "$disk_gi GiB under /var/lib, the plan is for $MACHINE_DISK_GI"
elif [[ ! -e /etc/rancher/k3s/installed-by-langsmith-lite ]] && ((free_gi * 10 < MACHINE_DISK_GI * 9)); then
  check FAIL disk "$free_gi GiB free of $disk_gi under /var/lib, the plan needs $MACHINE_DISK_GI"
else
  check ok disk "$disk_gi GiB under /var/lib, $free_gi free (the plan: $MACHINE_DISK_GI)"
fi

# The data disk, when the volumes have one of their own: an AWS data volume (attached, not yet mounted on
# a first install) or a bare-metal data_path (mounted, apart from /).
if [[ -n "${DATA_VOLUME_ID:-}" ]]; then
  if ls /dev/disk/by-id/*"${DATA_VOLUME_ID//-/}"* >/dev/null 2>&1; then
    check ok data "volume ${DATA_VOLUME_ID} attached; mounted at ${DATA_MOUNT} by the install"
  else
    check FAIL data "volume ${DATA_VOLUME_ID} is not attached to this instance"
  fi
elif [[ "${DATA_MOUNT:-/}" != / ]]; then
  if ! mountpoint -q "$DATA_MOUNT" 2>/dev/null; then
    check FAIL data "$DATA_MOUNT is not a mounted filesystem: mount the data disk there, or clear data_path"
  else
    data_gi="$(df -Pk "$DATA_MOUNT" | awk 'NR == 2 { printf "%d", $2 / 1048576 }')"
    if ((data_gi * 10 >= ${DATA_DISK_GI:-0} * 9)); then check ok data "$DATA_MOUNT, $data_gi GiB (the plan: ${DATA_DISK_GI:-0})"; else
      check FAIL data "$DATA_MOUNT has $data_gi GiB, the plan needs ${DATA_DISK_GI:-0}"; fi
  fi
fi

# k3s already here: ours (an update) or an agent of another cluster, whose certificates a server would
# inherit.
ours=0
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

# Ports k3s needs: its API and kubelet always; 80 and 443 when Traefik serves the box's address.
ports="6443 10250"
[[ "$ACCESS" == ip || "$ACCESS" == dns ]] && ports="$ports 80 443"
if ((ours)); then
  check ok ports "held by this install's k3s"
elif command -v ss >/dev/null; then
  held=""
  for p in $ports; do
    ss -ltnH "sport = :$p" 2>/dev/null | grep -q . && held="$held $p"
  done
  if [[ -z "$held" ]]; then check ok ports "free: $ports"; else
    check FAIL ports "in use:$held; stop what holds them (ss -ltnp shows it, with sudo)"; fi
else
  check warn ports "cannot tell (no ss): $ports must be free"
fi

# A host firewall drops k3s's own pod and service traffic unless opened (docs.k3s.io, requirements).
if systemctl is-active -q firewalld 2>/dev/null; then
  check warn firewall "firewalld is on: allow 6443/tcp, 10250/tcp, 8472/udp and the pod and service ranges, or turn it off"
elif command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
  check warn firewall "ufw is on: allow 6443/tcp, 10250/tcp, 8472/udp and the pod and service ranges"
else
  check ok firewall "no firewalld or ufw running"
fi

# Docker sets the FORWARD policy to DROP; k3s adds rules for its own ranges, which usually suffices.
if systemctl is-active -q docker 2>/dev/null; then
  check warn docker "running beside k3s: if pods cannot reach each other, Docker's FORWARD DROP is why"
fi

# What the install downloads: k3s, the charts, the images, the dashboards.
unreachable=""
for url in https://get.k3s.io https://github.com https://registry-1.docker.io/v2/ https://quay.io \
  https://registry.k8s.io https://langchain-ai.github.io/helm/index.yaml https://raw.githubusercontent.com \
  https://prometheus-community.github.io/helm-charts/index.yaml https://grafana-community.github.io/helm-charts/index.yaml; do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$url" 2>/dev/null || true)"
  [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] || unreachable="$unreachable ${url#https://}"
done
if [[ -z "$unreachable" ]]; then check ok internet "k3s, the charts and the images are reachable"; else
  check FAIL internet "unreachable:$unreachable (a proxy or an air gap is not supported yet)"; fi

if sudo -n true 2>/dev/null; then
  check ok sudo "passwordless"
else
  check ok sudo "asks for a password or a key's touch: make up asks once"
fi

exit "$failed"
