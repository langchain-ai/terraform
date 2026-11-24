# Operating a Lite box

> **Status:** current · **Last verified:** 2026-11-24

Choosing and checking a machine, reaching the box, watching it, changing and upgrading it, keeping its
data, removing it, and what to do when an install stops. Every command is a `make` target in this
folder.

## The machine

Any Linux machine with systemd, amd64 or arm64, reached over ssh: a server, a VM in any cloud, a VM on
a laptop. `cloud = "baremetal"` takes any of them by `ssh_host`; `cloud = "aws"` also makes the EC2
instance (`infra/hosts/aws`), with one gp3 disk of the plan's size. Native GCP and Azure hosts are to
come; until then, make a VM of the preset's size there and use `baremetal`. k3s needs a Linux kernel,
so on a Mac or Windows machine Lite runs in a Linux VM (Lima, OrbStack, UTM, Hyper-V) that is the
`baremetal` box, for example `limactl start --cpus 8 --memory 32 --disk 512 template://ubuntu-lts`.

`make preflight` checks the machine over ssh, read-only and without root; `make up` runs the same
checks on the box before it installs anything:

| Check | Needed | Otherwise |
|:--|:--|:--|
| Linux, amd64 or arm64, systemd | k3s runs on Linux as a systemd service | FAIL |
| cgroup v2 with cpu and memory | pod limits are enforced | FAIL without the controllers; warn on v1 |
| vCPUs, memory, disk under `/var/lib` | the plan's `machine`, less a tenth of the memory and disk for what the kernel and filesystem keep | FAIL: set `machine` to what it is, or use a bigger one |
| k3s | none, or one Lite installed | FAIL on an agent of another cluster, or a server Lite did not install |
| ports 6443, 10250, and 80, 443 for `ip` and `dns` | free | FAIL |
| firewalld or ufw | off, or open for k3s (6443/tcp, 10250/tcp, 8472/udp, the pod and service ranges) | warn |
| Docker | not needed; may run beside k3s | warn: its FORWARD DROP can block pod traffic |
| internet | k3s's release, the Helm repos, the image registries, GitHub | FAIL: a proxy or an air gap is not supported yet |
| sudo for the ssh user | to install and remove k3s only | asked once per command, so a password or a key's touch works |

| System | Status |
|:--|:--|
| Ubuntu 22.04, 24.04 | written for; the AWS host's image is 24.04 |
| Debian 12, 13 | written for |
| Arch and Arch-based (Omarchy) | preflight passes (2026-11-24); install not yet run |
| RHEL, Rocky, Alma, Fedora, Amazon Linux | untested; with SELinux enforcing, k3s needs `k3s-selinux` |
| Alpine, or anything without systemd | not supported |

A system becomes tested when `make up`, `make verify` and `make soak` at its box's design rate have run
on it, and this table says so with the date.

## Reaching it

`make access` prints every login and holds one ssh session open that forwards:

| Local address | What | Login |
|:--|:--|:--|
| http://localhost:8080 | LangSmith, with `access = localhost` | `admin_email`, generated password |
| http://localhost:3000 | Grafana | `admin`, generated password |
| http://localhost:3001 | Mission Control | `admin`, generated password |

With `access = ip`, `dns` or `tunnel`, LangSmith is at the `url` output, and `make access` still carries
Grafana and Mission Control.

| `access` | Before `make up` |
|:--|:--|
| `localhost` | Nothing. |
| `ip` | Nothing; browsers warn about the self-signed certificate. On AWS, set `access_cidrs` to who may reach 443. |
| `dns` | An A record for `domain` pointing at the box (on AWS, the `ssh` output's `host` after the first apply, then `make up` again once it resolves). Port 80 must be reachable from the internet for Let's Encrypt. |
| `tunnel` | A Cloudflare Tunnel whose public hostname is `domain`, with the service `http://traefik.kube-system.svc.cluster.local:80`; `make secrets` saves its token. |

The chart creates the organization and its first admin (`admin_email`) at install. Create an API key
in LangSmith (Settings, API Keys) for the SDK; `make verify` and `make soak` make and revoke their own.

What listens on the box's addresses: ssh (22); k3s's API (6443, TLS with client certificates) and
kubelet (10250, authenticated), which a host firewall should close as the AWS security group does; and
Traefik on 443 for `ip`, or 80 and 443 for `dns`. Nothing else: Grafana, Mission Control, Prometheus
and the stores have no port there, and node-exporter runs off the host's network.

## Watching it

Grafana's "LangSmith Lite" folder:

| Dashboard | Read it for |
|:--|:--|
| LangSmith (the chart's own) | SmithDB's ingestion and compaction backlogs, query latency, the ingest queue's depth and latency |
| Node Exporter Full | CPU, memory, disk use and IO; a filling object store shows on the disk panel first |
| Redis | memory against `maxmemory`: at `noeviction` a full Redis refuses writes and ingestion stops |
| PostgreSQL | connections against `max_connections`, and the databases' size |

`make status` gives the same from the shell: each release's install, every pod, what the node and the
pods use, and the volumes. Mission Control adds LangSmith's health view, preflight and database checks,
and a diagnostics bundle for a support case.

## Changing and upgrading it

Every setting is a variable (`infra/variables.tf`, SIZING.md lists them); a change is `make plan` then
`make up`, which reinstalls only the releases whose manifests changed. A larger volume is not grown in
place: local-path volumes are folders, so the plan's disk check is what holds them.

```bash
make pins    # what each chart line resolves to now, and what is newer
make plan    # resolves the lines again: a new LangSmith patch shows as a changed HelmChart
make up
```

A patch inside a pinned line arrives with any plan. A new line (LangSmith 0.19, k3s 1.37) is an edit to
`infra/pins.yaml`, made on purpose: read the chart's changelog, then `make render` before any box gets it.

## Keeping its data

ponytail: backups are not automated; one box is one failure domain, and the upgrade path is snapshots
of the box's disk, or a cloud module with managed stores (PROPOSALS.md, Backups).

| What | Where | How to copy it |
|:--|:--|:--|
| Traces, payloads, SmithDB's segments | RustFS's volume, under `/var/lib/rancher/k3s/storage/` on the box | a disk snapshot (EBS on AWS), or any S3 client through a port-forward |
| Users, projects, SmithDB's metastore | Postgres's volume, the same folder | `pg_dumpall` in the Postgres pod, or the disk snapshot |
| Every credential | `infra/terraform.tfstate` on the laptop | beside the box's backups; without it the stores' passwords are lost |
| The license key | `infra/.secrets.env` on the laptop | where licenses live |

A disk snapshot is consistent only with the box stopped, or taken by a tool that freezes the filesystem.

`make down` asks for the install's name, then on AWS destroys the instance and its disk, and on any
other box runs k3s's uninstaller (k3s, every volume, the manifests, the kubeconfig) if that k3s is
Lite's, and forgets the credentials. Nothing is kept.

## When an install stops

The install stops at the first step that fails, prints the end of its log, and keeps every step's log
under `/var/lib/langsmith-lite/logs/` on the box (root only). Then, on the box, as the ssh user:

```bash
export KUBECONFIG=~/.kube/langsmith-lite.yaml       # written at the end of an install; before it, sudo k3s kubectl
k3s kubectl -n kube-system get helmcharts           # each release
k3s kubectl -n kube-system logs job/helm-install-langsmith
k3s kubectl -n langsmith get pods
k3s kubectl -n langsmith describe pod <pod>
journalctl -u k3s --since -30min
```

| Symptom | Usual cause |
|:--|:--|
| A pod `Pending`, "Insufficient cpu" or "memory" | the machine is smaller than the plan's `machine`, or a `resources` override outgrew it: `make plan` says |
| `helm-install-<release>` failing on a value | the chart refused it: `make render` shows which, without a box |
| An install Job failed three times | the install stops and prints its log; fewer are retried, as while the stores start |
| A pod `OOMKilled` | raise its memory with `resources`, citing what Grafana showed it use |
| Pods that cannot reach each other, with Docker on the box | Docker's FORWARD policy: allow the pod range (10.42.0.0/16), or stop Docker |
| No certificate with `access = dns` | the A record does not resolve to the box, or port 80 is closed: Traefik's log says which |

## What the first install confirms

What only a running box can show, each read on the first install of each box size (PROPOSALS.md,
Measure what is not measured):

1. SmithDB as one pod at each preset's size: its use at the design load, and whether it is killed.
2. Traefik's HTTPS redirect and Let's Encrypt resolver, as k3s's bundled Traefik chart takes them.
3. Grafana 13 provisioning the chart's v2 dashboard from a file.
4. Postgres connections in use, and the metastore's growth.
5. Mission Control taking the pre-created login rather than its first-run setup token.
6. The install's waits on a first install, and on an upgrade that changes one release.
7. k3s beside Docker on an Arch-family machine, then Ubuntu (AWS) and Debian.
