# Operating a Lite box

> **Status:** current · **Last verified:** 2026-11-24

Checking a machine, reaching the box, watching it, upgrading it, keeping its data, removing it, and
what to do when an install stops. Every command is a `make` target in this folder.

## Before the first install

`make preflight` checks the machine over ssh, read-only and as the ssh user: Linux, systemd, cgroups,
its size against the plan, the ports k3s needs, a firewall, Docker, the internet, and any k3s already
there. One row a check, ok, warn or FAIL, each with what to do; `make up` runs the same checks on the
box before it installs anything. What each check needs: [infra/hosts/README.md](infra/hosts/README.md).

## Root on the box

Only installing, upgrading and removing k3s need root (`make up`, `make install`, `make down`): k3s is a
system service that runs containerd and sets up the kernel's networking, cgroups and mounts. Each of
those commands asks for sudo once, up front, so a password or a security key's touch works. Everything
else (`make preflight`, `make status`, `make access`, kubectl on the box) runs as the ssh user, with the
kubeconfig the install gave it (`~/.kube/langsmith-lite.yaml`, mode 600). k3s's rootless mode is
experimental, still needs root once to prepare the machine, and loses servicelb's host ports, so Lite
does not use it.

k3s is marked as Lite's (`/etc/rancher/k3s/installed-by-langsmith-lite`): the checks refuse a k3s server
someone else installed rather than take it over, and `make down` removes only a k3s that carries the
mark.

## Reaching it

`make access` prints every login and holds one ssh session open that forwards:

| Local address | What | Login |
|:--|:--|:--|
| http://localhost:8080 | LangSmith, with `access = localhost` | `admin_email`, generated password |
| http://localhost:3000 | Grafana | `admin`, generated password |
| http://localhost:3001 | Mission Control | `admin`, generated password |

With `access = ip`, `dns` or `tunnel`, LangSmith is at the `url` output instead, and `make access` still
carries Grafana and Mission Control.

| `access` | Before `make up` |
|:--|:--|
| `localhost` | Nothing. |
| `ip` | Nothing; browsers warn about the self-signed certificate. On AWS, set `access_cidrs` to who may reach 443. |
| `dns` | An A record for `domain` pointing at the box (on AWS, the `ssh` output's `host` after the first apply, then `make install` once the record resolves). Port 80 must be reachable from the internet for Let's Encrypt's challenge. |
| `tunnel` | A Cloudflare Tunnel whose public hostname is `domain`, with the service `http://traefik.kube-system.svc.cluster.local:80`; `make secrets` saves its token. No port of LangSmith's is opened. |

The chart creates the organization and its first admin (`admin_email`) at install. Create an API key
in LangSmith (Settings, API Keys) for the SDK and for `make load`.

### What listens on the box

| Port | What | Reachable from |
|:--|:--|:--|
| 22 | ssh | as the machine allows; on AWS, `admin_cidrs` |
| 6443 | k3s's API, TLS with client certificates | every address of the box; close it with a host firewall, as the AWS security group does |
| 10250 | the kubelet, authenticated | the same |
| 80, 443 | Traefik, with `access = ip` (443) or `dns` (80, 443) | every address; on AWS, `access_cidrs` |

Nothing else: Grafana, Mission Control, Prometheus and the stores have no port on the box's addresses,
and node-exporter runs off the host's network.

## Watching it

Grafana's "LangSmith Lite" folder holds four dashboards:

| Dashboard | Read it for |
|:--|:--|
| LangSmith (the chart's own) | SmithDB's ingestion and compaction backlogs, query latency, the ingest queue's depth and its latency from API to store |
| Node Exporter Full | The box: CPU, memory, disk use and IO. The disk panel is where a filling object store shows first |
| Redis | Memory against `maxmemory`. At `noeviction`, a full Redis refuses writes and ingestion stops |
| PostgreSQL | Connections in use against `max_connections`, and the databases' size |

Prometheus keeps `prometheus_retention_days` of metrics, and at most four fifths of its volume.
`make status` gives the same picture from the shell: each release's install, every pod, what the node
and the pods use, and the volumes. Mission Control adds LangSmith's own health view, preflight checks,
database checks and a diagnostics bundle for a support case; its features that write are off.

## Changing it

Every setting is a Terraform variable (`infra/variables.tf`); a change is `make plan` then `make up`,
which changes only what differs. A change that resizes a store's volume does not grow an existing
volume: local-path volumes are directories, so they are not enforced, but the plan's disk check is.

To size a pod from a measurement, set `resources` with the pod's name from the `plan` output, and cite
the run you measured beside it.

## Upgrading

```bash
make pins    # what each chart line resolves to now, and what is newer
make plan    # resolves the lines again: a new patch of LangSmith shows as a changed HelmChart
make up
```

A patch inside a pinned line arrives with any plan, and only the releases whose manifests changed are
reinstalled. A new line (LangSmith 0.19, k3s 1.37) is a change to `infra/pins.yaml`, made on purpose:
read the chart's changelog first, then `make render` to render every release at the new versions before
any box gets them.

## Keeping its data

ponytail: backups are not automated; one box is one failure domain, and the upgrade path is
scheduled snapshots of the box's disk, or a cloud module with managed stores.

What holds the data, and what to copy:

| What | Where | How |
|:--|:--|:--|
| Traces, payloads, SmithDB's segments | RustFS's volume, `/var/lib/rancher/k3s/storage/` on the box | A disk snapshot (EBS on AWS), or the S3 API with any S3 client through a port-forward |
| Users, projects, SmithDB's metastore | Postgres's volume, same folder | `pg_dumpall` in the Postgres pod, or the disk snapshot |
| Every credential | `infra/terraform.tfstate` on the laptop | Copy it beside the box's backups; without it the stores' passwords are lost |
| The license key | `infra/.secrets.env` on the laptop | Keep it where licenses live |

A disk snapshot is consistent only with the box stopped, or taken by a tool that freezes the
filesystem.

## Removing it

`make down` asks for the install's name, then on AWS destroys the instance and its volume, and on bare
metal runs k3s's uninstaller on the box (k3s, every volume, the manifests and the kubeconfig), if the
k3s there is Lite's, and forgets the credentials. Nothing is kept.

## When an install stops

The install stops at the first step that fails, prints the end of that step's log, and keeps every
step's log under `/var/lib/langsmith-lite/logs/` on the box (root only). Then, on the box, as the ssh
user:

```bash
export KUBECONFIG=~/.kube/langsmith-lite.yaml
k3s kubectl -n kube-system get helmcharts                  # each release
k3s kubectl -n kube-system logs job/helm-install-langsmith # one release's install, its Helm output
k3s kubectl -n langsmith get pods                          # what is not Ready
k3s kubectl -n langsmith describe pod <pod>                # why: scheduling, image, probes
journalctl -u k3s --since -30min                           # k3s itself
```

The kubeconfig is written at the end of a successful install; before that, use `sudo k3s kubectl`.

| Symptom | Usual cause |
|:--|:--|
| A pod `Pending`, "Insufficient cpu" or "memory" | The box is smaller than the plan's `machine`, or a `resources` override outgrew it: `make plan` says |
| `helm-install-<release>` failing on a value | The chart refused a value: `make render` shows which, without a box |
| An install Job that failed three times | The install stops and prints its log; helm-controller retries fewer than three, as while the stores start |
| A pod `OOMKilled` | Raise its memory with `resources`, citing what Grafana showed it use |
| Pods that cannot reach each other, with Docker on the box | Docker's FORWARD policy: allow the pod range (10.42.0.0/16) in the FORWARD chain, or stop Docker |
| No certificate with `access = dns` | The A record did not resolve to the box, or port 80 is closed: Traefik's log says which |

## What the first install confirms

Lite is proven by its plan tests, by rendering every release through its real chart, and by preflight
on an Arch-family machine; these are what only a running box can show:

1. SmithDB's unified pod at each preset's size: its use under the design load, and whether it is
   killed for memory.
2. Traefik's HTTP to HTTPS redirect and the Let's Encrypt resolver, as k3s's bundled Traefik chart
   takes them (`traefik_values` in `values.tf`).
3. Grafana 13 provisioning the chart's v2 dashboard from a file.
4. Postgres connections in use against `max_connections` 200.
5. Mission Control taking the pre-created login rather than its first-run setup token.
6. The install's waits on a first install and on an upgrade that changes one release.
7. k3s beside Docker on an Arch-family machine, then on Ubuntu (AWS) and Debian.
