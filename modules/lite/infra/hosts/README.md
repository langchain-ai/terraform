# Hosts

> **Status:** current · **Last verified:** 2026-11-24

Where a Lite box comes from. A host makes a Linux machine reachable over ssh and nothing more: k3s and
everything on it are installed by `box/install.sh` the same way on every machine, so a new cloud is a
new folder here and one branch in `../hosts.tf`.

| `cloud` | What it makes | Status |
|:--|:--|:--|
| `baremetal` | Nothing: any machine you have, named by `ssh_host` (a server, a VM in any cloud, a VM on a laptop) | built |
| `aws` | One EC2 instance of the preset's size, an encrypted gp3 volume, a fixed address, a security group (`aws/`) | built |
| `gcp` | One Compute Engine instance, the same shape | coming; until then a GCE VM with `baremetal` |
| `azure` | One virtual machine, the same shape | coming; until then an Azure VM with `baremetal` |

## What any box needs

`make preflight` checks each of these over ssh, read-only and without root, and `box/install.sh` runs
the same checks before it installs anything:

| Check | Needed | When it is not met |
|:--|:--|:--|
| Linux | k3s runs on Linux only | FAIL: run Lite in a Linux VM on that machine (below) |
| amd64 or arm64 | k3s's architectures | FAIL |
| systemd | k3s installs as a systemd service | FAIL |
| cgroup v2 with cpu and memory | pod limits are enforced | FAIL without the controllers; warn on v1 |
| vCPUs, memory, disk under `/var/lib` | at least the plan's `machine` (a tenth less memory and disk is allowed for what the kernel and filesystem keep) | FAIL: set `machine` to what it is, or use a bigger one |
| k3s | none, or one Lite installed | FAIL on an agent of another cluster, or a server Lite did not install |
| ports 6443 and 10250 (and 80, 443 for `ip` and `dns`) | free | FAIL |
| firewalld or ufw | off, or opened for k3s (6443/tcp, 10250/tcp, 8472/udp, the pod and service ranges) | warn |
| Docker | not required; may run beside k3s | warn: Docker's FORWARD DROP can block pod traffic |
| internet | k3s's release, the Helm repos, the image registries, GitHub | FAIL: a proxy or an air gap is not supported yet |
| sudo for the ssh user | to install and remove k3s only | asked once per command, so a password or a key's touch works |

## Operating systems

| System | Status |
|:--|:--|
| Ubuntu 22.04, 24.04 | written for; the AWS host's image is 24.04 |
| Debian 12, 13 | written for |
| Arch and Arch-based (Omarchy) | preflight passes (2026-11-24); install not yet run |
| RHEL, Rocky, Alma, Fedora, Amazon Linux | untested; with SELinux enforcing, k3s needs the `k3s-selinux` package |
| Alpine, and anything without systemd | not supported |

A system moves to tested when `make up`, `make status` and `make load` at its box's design rate have
run on it; this table says so, with the date.

## macOS and Windows

k3s needs a Linux kernel, so a Mac or a Windows machine runs Lite inside a Linux VM, and that VM is a
`baremetal` box: give it the preset's vCPUs, memory and disk, an ssh server and a user with sudo, then
set `ssh_host` to it. Lima (`limactl start --cpus 8 --memory 32 --disk 256 template://ubuntu-lts`),
OrbStack, UTM, or Hyper-V on Windows each make one. Running `make` itself on macOS is supported.

## A new host

A host gives the root an address to ssh to, the user, and a machine at least the box's size, and opens
ssh to the operator; `aws/` is the worked example. It never installs anything on the machine itself.
