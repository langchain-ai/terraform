# Operating Lite

> **Status:** current · **Last verified:** 2026-11-25 (installed, verified and soaked on an Arch-family server; dashboards and alerts on Grafana 13.3.1 locally)

Choosing and checking a machine, reaching it, proving it works, watching it, changing it, keeping its
data, handing an install to a cluster, and what to do when an install stops. Every command is a `make`
target in this folder, run from your laptop.

## The machine

Any Linux machine with systemd, amd64 or arm64, that your laptop can ssh to: a server, a VM in any
cloud, a VM on a laptop. Nothing is copied to it by hand: `make up` sends what it needs over ssh.

| `cloud` | The machine | Its data |
|:--|:--|:--|
| `baremetal` | `ssh_host` (an address, or an alias in `~/.ssh/config`) and `ssh_user` (one with sudo) | on the system disk, or `data_path`: a mounted disk of its own, with `machine.data_disk_gi` its size |
| `aws` | an EC2 instance of the size's type (`infra/hosts/aws`), reached as `ubuntu` | a gp3 volume of its own, mounted at k3s's storage folder, kept when the instance is replaced, snapshotted daily |
| `cluster` | none: the releases for a Kubernetes cluster you run (Handing it to a cluster) | the cluster's storage classes |

### AWS permissions

With `cloud = "aws"`, the credentials `make up` and `make down` run with need what
[`infra/hosts/aws/iam-policy.json`](infra/hosts/aws/iam-policy.json) grants, and no more:

| For | Allowed |
|:--|:--|
| the instance, its data volume, address, security group and key pair | the EC2 actions that create, change and delete each, and every `ec2:Describe*` |
| the daily snapshots | Data Lifecycle Manager's policy actions, and `ec2:DeleteSnapshot` for removing them after `make down` |
| the snapshot policy's role | IAM actions on roles named `*-snapshots` only, attaching only AWS's `AWSDataLifecycleManagerServiceRole` policy, passed to `dlm.amazonaws.com` only |

Attach it to the user or role that runs Lite:

```bash
aws iam create-policy --policy-name langsmith-lite --policy-document file://infra/hosts/aws/iam-policy.json
aws iam attach-user-policy --user-name <user> --policy-arn arn:aws:iam::<account>:policy/langsmith-lite
```

Or in your own Terraform: `resource "aws_iam_policy" "langsmith_lite" { policy =
file("<path>/iam-policy.json") }`. To hold it to one region, add `"Condition": { "StringEquals": {
"aws:RequestedRegion": "us-east-1" } }` to each EC2 and DLM statement. The instance goes in the region's
default VPC, or the subnet `aws_subnet_id` names, which must give it a public address. `make check` fails
when the AWS host makes a resource the policy has no statement for; the policy itself is first exercised
by the first AWS install.

On GCP or Azure, make a VM of the size's shape and use `baremetal` until their hosts land. k3s needs
Linux, so on a Mac or Windows machine the box is a Linux VM (Lima, OrbStack, UTM, Hyper-V), for example
`limactl start --cpus 8 --memory 64 --disk 640 template://ubuntu-lts`.

`make preflight` checks the machine over ssh, read-only and without root; `make up` runs the same checks
on the box before it changes anything:

| Check | Needed | Otherwise |
|:--|:--|:--|
| Linux, amd64 or arm64, systemd | k3s runs as a systemd service | FAIL |
| cgroup v2 with cpu and memory | pod limits are enforced | FAIL without the controllers; warn on v1 |
| vCPUs, memory, disks | the plan's `machine`: every vCPU, and the memory and disks less a tenth for what the kernel and filesystem keep | FAIL: set `machine` to what it is, or a larger box |
| the data disk | on AWS the volume attached; with `data_path`, mounted and of `data_disk_gi` | FAIL |
| k3s | none, or one Lite installed | FAIL on an agent of another cluster, or a server Lite did not install |
| ports 6443, 10250; 80 and 443 for `ip` and `dns` | free | FAIL |
| firewalld or ufw | off, or allowing k3s's pod and service ranges (`ufw allow from 10.42.0.0/16 to any`, and `10.43.0.0/16`) | warn; with ufw on, the install reads its rules as root and FAILs without them |
| Docker | not needed; may run beside k3s | warn: its FORWARD DROP can block pod traffic |
| internet | k3s's release, the Helm repos, the image registries, GitHub | FAIL: a proxy or an air gap is not supported yet |
| sudo for the ssh user | to install and remove k3s only | asked once a command, so a password or a security key's touch works |

| System | Status |
|:--|:--|
| Ubuntu 22.04, 24.04 | written for; the AWS host's image is 24.04 |
| Debian 12, 13 | written for |
| Arch and Arch-based (Omarchy) | tested: `make up`, `make verify` and `make soak` passed (2026-11-25) |
| RHEL, Rocky, Alma, Fedora, Amazon Linux | untested; with SELinux enforcing, k3s needs `k3s-selinux` |
| Alpine, or anything without systemd | not supported |

A system counts as tested once `make up`, `make verify` and `make soak` have passed on it; its row then
carries the date.

## Reaching it

`make access` prints every login and holds one ssh session open that forwards:

| Local address | What | Login |
|:--|:--|:--|
| http://localhost:8080 | LangSmith, with `access = localhost` | `admin_email`, generated password |
| http://localhost:3000 | Grafana | `admin`, generated password |
| http://localhost:3001 | Mission Control | `admin`, generated password |

| `access` | LangSmith at | Before `make up` |
|:--|:--|:--|
| `localhost` (default) | http://localhost:8080, while `make access` runs | nothing |
| `ip` | `https://<box address>`, a self-signed certificate | on AWS, `access_cidrs`: who may reach 443 |
| `dns` | `https://<domain>`, Let's Encrypt | an A record for `domain` (on AWS, after the first apply, then `make up` again); port 80 reachable for the certificate |
| `tunnel` | `https://<domain>` through a Cloudflare Tunnel | a tunnel whose public hostname is `domain`, service `http://traefik.kube-system.svc.cluster.local:80`; `make up` asks for its token |

What listens on the box's addresses: ssh (22); k3s's API (6443, client certificates), kubelet (10250,
authenticated) and flannel's overlay (8472/udp), which a host firewall should close as the AWS security
group does; Traefik on 80 (a redirect) and 443 for `ip` and `dns`. Nothing else: Grafana, Mission
Control, Prometheus and the stores have no port there.

### Sending traces

An application traces to LangSmith with the SDK's usual settings: `LANGSMITH_ENDPOINT` is LangSmith's
address from the `access` table with `/api/v1` (for `localhost`, `http://localhost:8080/api/v1`,
reachable only while `make access` runs on the same machine), `LANGSMITH_API_KEY` a key made in LangSmith
(Settings, API Keys), and `LANGSMITH_TRACING=true`. A trace then shows in its project within seconds;
`make verify` checks the same path end to end. Reading traces back from SmithDB takes the SDK's newer
query methods (Python `langsmith` 0.10.15 or later, TypeScript 0.8.9): they call LangSmith's `/v2`
endpoints from the same `/api/v1` address ([the SmithDB SDK
migration](https://docs.langchain.com/langsmith/smithdb-sdk-migration)).

### A real endpoint: DNS, certificates, SSO

What a team-wide LangSmith on a web address needs, what Lite does today, and what it leaves to you. Lite's
scope is the box and its four access modes; the rest are noted here so an install can grow into them.

| Need | Lite today | Otherwise |
|:--|:--|:--|
| A name | `dns`: you make the A record for `domain`; `tunnel`: Cloudflare makes it | private DNS, or a load balancer in front: point it at the box's 80 and 443 |
| A trusted certificate | `dns`: Let's Encrypt through Traefik (HTTP-01, so port 80 must reach the box); `tunnel`: Cloudflare's | your own certificate or an internal CA's: not yet; with `ip`, clients must trust Traefik's self-signed one ([self-signed certificates](https://docs.langchain.com/langsmith/self-host-usage#self-signed-certificates)) |
| Reachable only inside a network | `localhost` (ssh only), or `ip` with `access_cidrs` on AWS; `tunnel` with [Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/applications/) in front | a VPN or private subnet the box sits in |
| Single sign-on | not yet: logins are LangSmith's own (email and password, the first admin's generated) | [SSO with OAuth 2.0 and OIDC](https://docs.langchain.com/langsmith/self-host-sso), in the steps after this table |
| Outbound through a proxy, or to services an internal CA signed | not supported: the box needs the internet ([The machine](#the-machine)) | [custom TLS certificates](https://docs.langchain.com/langsmith/self-host-custom-tls-certificates) |

SSO, when it lands, follows the chart's own path, and an install made today is ready for it: Lite already
runs LangSmith with `authType: mixed` (which SSO needs) and sets its hostname. The order matters and is
one-way:

1. Use `access = dns` or `tunnel`: SSO works only over HTTPS on a stable name.
2. Log in once as the first admin with the generated password, and give that same email an account in
   your identity provider.
3. Register the redirect URI `https://<domain>/api/v1/oauth/custom-oidc/callback` with any OIDC provider
   (Entra ID, Okta, Auth0, Google Workspace), then turn SSO on with its issuer URL, client id and client
   secret. Basic auth goes off; LangSmith does not move an install back from SSO to passwords.
4. Keep a [recovery admin login](https://docs.langchain.com/langsmith/self-host-sso-recovery) for when the
   identity provider is down.

Every LangSmith sign-in option is on [Authentication
methods](https://docs.langchain.com/langsmith/authentication-methods#self-hosted).

## Proving it works

<img alt="Four questions, each a command. make verify, about 2 minutes: do traces flow; ten traces followed through four hops, accepted, drained from Redis, flushed by SmithDB, readable by a query. make soak, 17 minutes: does it hold its design load; a 2-minute ramp, then the design rate with its readers for 15 minutes, every target judged. STEP=1 make soak, until a step does not hold: what does it hold; the design rate times 0.5, 1, 1.5, 2, 3 and 4 in turn. make experiment, about an hour and a quarter a size: what each size holds; for xs, s, m and l, a fresh install, verify, then the design rate twice, then 2 and 3 times it." src="diagrams/proving.png">

| Command | Answers | Takes |
|:--|:--|:--|
| `make verify` | Do traces flow? Ten traces followed hop by hop: accepted by the API, Redis's ingestion queue drained, SmithDB flushed, readable by a query. Where they stop, that workload's last log lines. | about 2 minutes |
| `make soak` | Does the box hold its design load, with reads? Every target (nothing lost, readable in time), whether ingestion kept up, and each watch item against its alarm level. | `DURATION` (900 s) plus a 120 s ramp |
| `TRACES=agent make soak` | The same soak in realistic traces; `verify` and `experiment` take `TRACES` too. `simple`, the default for `verify` and `soak`, is ten runs in a flat tree, each a size from a measured mix: quick, and comparable run to run. `agent`, the default for `experiment`, is an application's traces as customers send them: mostly one model call, a third an agent calling tools for several turns, every model call resending the conversation so far (the load test's [`payloads/agent.py`](../../utils/langsmith-load-test/src/loadtest/payloads/agent.py)). | the same |
| `STEP=1 make soak` | What does it hold? The design rate x 0.5, 1, 1.5, 2, 3 and 4 in turn, until a step does not hold, and what crossed its level there. | up to six soaks |
| `make experiment` | What does each size hold? For each size (`SIZES`, all four by default): `FRESH=1 make up` at that size, held to its machine (`emulate_machine`), `make verify`, then `MINUTES` (10) at each multiple of its design rate in `STEPS` (1 1 2 3: 1x right after the fresh install and again once it has warmed), every step run whether or not the last held. After each size and at the end, two tables: what each step held, and what it took from the machine. Deletes the install's data for each size, one root step a size: it asks for the install's name, or takes `CONFIRM=<name>`. Stopped part way, the next `make experiment` continues it with the settings it started with: the sizes that finished are kept, and the one it was on is measured again from no data. `NEW=1` starts a new one. `TRACES` (`agent` unless set) is kept with the experiment's settings. | about an hour and a quarter a size |
| `make report` | The runs in `build/soak/`, or the folders given, as figures, their numbers and the runs' own files. | a minute |

They log in as the first admin, make an API key for the run and revoke it after; they reach the box's
Kubernetes API and LangSmith through ssh, with no port opened. They are the load test's own commands
([`utils/langsmith-load-test`](../../utils/langsmith-load-test)), which run the same way against a cloud
or bare-metal install.

Each run keeps, in `build/verify/`, `build/soak/` or the experiment's folder, its results and every
sample of the install taken every 15 s: each workload's cores and memory, the stores' included; every
pod together against the machine, with how often the size's cap throttled them; each disk's throughput
and busy time (those through the install's Prometheus, so a box without observability, size `xs`, reads
none of them); the bytes each store's volume gained a run (read with `du` in its pod each minute), the
payload bytes sent a run, Redis's memory, Postgres's connections, the queues, and SmithDB's segments,
compactions and refused queries.
`make experiment` writes one report a size and one for all of them. A report's figures are in the
LangChain brand when `FONTS` and `LOGOS` name the folders holding its faces and logos, read where they
are and never copied in; without them each figure is drawn as a labelled draft.

## Watching it

Grafana's "LangSmith Lite" folder holds the two dashboards that matter most:

| Dashboard | Tabs | Read it for |
|:--|:--|:--|
| LangSmith Lite health | Red flags; Ingestion; Writes and queries; Compaction; Stores and pods; Capacity | is anything wrong: one tile a signal, green, orange (the early signal) or red (an alert fires); each tab graphs its signals with their levels as lines, one line an install |
| LangSmith Self-Hosted (the chart's own, from its [observability bundle](https://docs.langchain.com/langsmith/self-host-observability-dashboards)) | SmithDB; Sandboxes, empty on Lite, which runs none | why: every SmithDB and LangSmith metric in depth |

Node Exporter, Redis and PostgreSQL dashboards are there too. Every signal on the health dashboard is one
alert rule in Grafana (Alerting, Alert rules), from one list, [`infra/health.yaml`](infra/health.yaml):
LangSmith's [recommended SmithDB alerts](https://docs.langchain.com/langsmith/self-host-smithdb-alerts)
(runs lost, an old backlog, Redis nearly full, failed or slow writes and queries, a saturated metastore,
compaction behind or stopped, a component with no pods, restarts) and the bounds the plan sized (the
disks, each pod's memory). A rule shows in Grafana's alert list; where it is sent (email, Slack, a pager)
is a contact point you add in Grafana. SmithDB's panics are read from logs, which Lite does not collect.

The LangSmith and SmithDB signals are grouped by namespace and the dashboard has an install picker, so
the same dashboard serves a Grafana that scrapes many installs ([ARCHITECTURE.md, Many
installs](ARCHITECTURE.md#many-installs)); Redis, Postgres and the disks come from the box's own
exporters and stay one a box.

`make status` gives the shell's view: each release's install, every pod, what the node and the pods use,
and the volumes. Mission Control adds LangSmith's health view and a diagnostics bundle for a support
case.

## Changing and upgrading it

Change a setting in `infra/terraform.tfvars`, or on the command line (`make up box=m`), then `make up`:
it shows the plan, asks, applies what changed and reinstalls only the releases whose manifests changed.
`make plan` shows the same without changing anything. Volumes are folders on the data disk, not
resizable claims, so a larger size needs a disk that holds it, which the plan checks.

`FRESH=1 make up` starts from no data on the same k3s: one root step removes the install's releases,
its namespaces and its volumes (the stores' too, which a plain uninstall keeps), then installs. k3s and
the images it pulled stay, so it is minutes, not a reinstall. It asks for the install's name, or takes
`CONFIRM=<name>`.

```bash
make pins    # what each chart line resolves to now, and what is newer
make up      # resolves the lines again: a new LangSmith patch shows as a changed HelmChart
```

A patch inside a pinned line arrives with any `make up`. A new line (LangSmith 0.19, k3s 1.37) is an edit
to `infra/pins.yaml`, made on purpose: read the chart's changelog, then `make render` before any box gets
it.

## Keeping its data

| What | Where | Copy |
|:--|:--|:--|
| Traces, payloads, SmithDB's segments; users, projects, the metastore | the data disk: on AWS its own volume, else `data_path` or the system disk, under k3s's storage folder | on AWS, the daily snapshots (`backup_snapshot_days`, 7 by default); elsewhere a disk snapshot, or `pg_dumpall` in the Postgres pod and any S3 client through a port-forward |
| Every credential | `infra/terraform.tfstate` on the laptop | beside the box's backups: without it the stores' passwords are lost |
| The license key | `infra/.secrets.env` on the laptop | where licenses live |

On AWS the data volume outlives the instance: replacing the instance (a new type, a new image) keeps the
data on it. A new k3s on the new instance makes new volume folders beside the old ones (local-path names
each after its claim's id), so its stores start empty until the old folders are moved into place. A
snapshot is crash-consistent: what a power cut would leave, which Postgres and SmithDB recover from.
Limit: no restore or reattach command yet; one box is one failure domain, and the upgrade path is a
cloud module with managed stores.

`make down` asks for the install's name, then on AWS destroys the instance, its volume and its
snapshot policy, and on any other box runs k3s's uninstaller (k3s, every volume, the bundle, the
kubeconfig, and the volumes under `data_path`), only if that k3s is Lite's, and forgets the credentials.
On AWS the snapshots already taken are kept, as the last copy of the data, and billed until deleted:
`make down` prints the commands that list and delete them. A script confirms with
`CONFIRM=<name> make down`.

## Handing it to a cluster

With `cloud = "cluster"` there is no box: `make up` (or `make export`, again at any time) writes the same
releases, values and Secrets to `build/export/<name>/` for a Kubernetes cluster you run, one install a
namespace on the cluster's own storage classes (`storage_class`, `scratch_storage_class`):

```bash
kubectl apply --server-side -f build/export/<name>/cluster.yaml -f build/export/<name>/secrets.yaml
bash build/export/<name>/install.sh       # helm upgrade --install, each release in order
rm build/export/<name>/secrets.yaml       # every credential; mode 600 until then
```

Lite makes no Ingress there: route your ingress controller to the Service `langsmith-frontend`, port 80, in
the install's namespace, and set `ingress_namespaces` to the controller's namespace.

Or hand `values/` to Helm or Argo CD as they are. Installs on one cluster are independent
([ARCHITECTURE.md, Many installs](ARCHITECTURE.md#many-installs)): the cluster's CNI must enforce
NetworkPolicies, and `ingress_namespaces` names its ingress controller's namespace. Observability and
Mission Control are off by default there, since a cluster runs one stack for all of them.

## When an install stops

The install stops at the first step that fails, prints the end of its log, and keeps every step's log
under `/var/lib/langsmith-lite/logs/` on the box (root only). `make up` again resumes it. On the box, as
the ssh user:

```bash
export KUBECONFIG=~/.kube/langsmith-lite.yaml       # written at the end of an install; before it, sudo k3s kubectl
k3s kubectl -n kube-system get helmcharts           # each release
k3s kubectl -n <name> get pods                      # the install's namespace: its name, unless namespace is set
sudo k3s kubectl -n kube-system logs job/helm-install-langsmith   # a release's install log: kube-system's logs need root
sudo journalctl -u k3s --since -30min
```

| Symptom | Usual cause |
|:--|:--|
| A pod `Pending`, "Insufficient cpu" or "memory" | the machine is smaller than the plan's `machine`, or a `resources` override outgrew it: `make plan` says |
| `helm-install-<release>` failing on a value | the chart refused it: `make render` shows which, without a box |
| A pod `OOMKilled` | raise its memory with `resources`, citing what Grafana showed it use |
| Pods that cannot reach each other, with Docker on the box | Docker's FORWARD policy: allow the pod range (10.42.0.0/16), or stop Docker |
| No certificate with `access = dns` | the A record does not resolve to the box, or port 80 is closed: Traefik's log says which |
| `make verify` stops at a hop | that hop's workload printed its last log lines; the health dashboard's tab for it shows since when |
| feedback stats answers 429, "Too many concurrent partitions" | SmithDB refused a query that would scan more than its partition limit, in the minute before compaction merges the segments waiting for it; it answers again once they are merged. Seen on magus at `m` from 25 runs/s, raised with SmithDB's maintainers (2026-11-25) |

## What the first install confirms

What only a running box can show, each read on the first install of each size:

1. SmithDB as one pod at each size: its use at the design load (`make soak`), and whether it is killed.
   At `m` on magus (2026-11-25): 1.5 to 1.6 cores from 50 to 75 runs/s, never killed; every run stored up
   to 75 runs/s, three times the design rate. Every size in the load test's simple traces (2026-11-26):
   never killed, every run stored at 1 to 3 times its design rate. In realistic traces: `make experiment`.
2. Traefik's HTTPS redirect and Let's Encrypt resolver, as k3s's bundled Traefik chart takes them.
3. The health dashboard's signals reading data. Three LangSmith metric names
   (`langsmith_ingest_task_failures_total`, `langsmith_asynq_queue_latency_seconds`,
   `langsmith_asynq_ingestion_queue_retry`) come from the alerts page, not yet read from a 0.18 install;
   SmithDB's are checked against its source. Grafana 13.3.1 provisioning both dashboards and every rule
   was checked locally (2026-11-24).
4. Postgres connections in use, and the metastore's growth. At `m`: about 40 connections of 200, from
   12.5 to 75 runs/s; the metastore's growth is in each run's disk readings.
5. Mission Control taking the pre-created login rather than its first-run setup token.
6. Ubuntu (the AWS host's image) and Debian. magus, Arch-family with Docker beside k3s, passed
   (2026-11-25).
