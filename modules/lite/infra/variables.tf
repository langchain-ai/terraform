#------------------------------------------------------------------------------
# What one Lite install is: where the box comes from, how big it is, how it is
# reached, and the settings that bound its data. Every default is the box
# preset's (sizes.yaml); SIZING.md says where each number comes from.
#------------------------------------------------------------------------------

variable "name" {
  type        = string
  default     = "langsmith-lite"
  description = "Names the install: the AWS resources' Name tag and the box's Kubernetes node."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,40}$", var.name))
    error_message = "name must be lowercase letters, digits and hyphens, starting with a letter, at most 41 characters."
  }
}

variable "namespace" {
  type        = string
  default     = null
  description = "LangSmith's namespace; the stores go in <namespace>-data and the observability stack in <namespace>-observe. Unset: the install's name, so two installs on one cluster never share a namespace (whose Secrets each would overwrite)."

  validation {
    condition     = var.namespace == null || can(regex("^[a-z][a-z0-9-]{0,40}$", var.namespace))
    error_message = "namespace must be lowercase letters, digits and hyphens, at most 41 characters."
  }
}

#--- The box ------------------------------------------------------------------

variable "cloud" {
  type        = string
  default     = "baremetal"
  description = "Where it runs. baremetal: a machine you have, reached over ssh. aws: an EC2 instance this module makes. cluster: a Kubernetes cluster you already run, one install a namespace: make up writes the releases, values and Secrets for it (make export) instead of installing a box. gcp and azure hosts are to come; until then a VM there with baremetal."

  validation {
    condition     = contains(["baremetal", "aws", "cluster"], var.cloud)
    error_message = "cloud must be baremetal, aws or cluster."
  }
}

variable "box" {
  type        = string
  default     = "s"
  description = "The size preset: xs (2 vCPU, 16 GiB, 1 run/s), s (4, 16, 5 runs/s), m (8, 32, 25 runs/s) or l (16, 64, 50 runs/s). Sets the machine, the design load, every per-box size and whether the observability stack and Mission Control run (sizes.yaml). Past l is a full deployment: a cloud module."

  validation {
    condition     = contains(["xs", "s", "m", "l"], var.box)
    error_message = "box must be xs, s, m or l; past l, use a cloud module (../aws, ../gcp, ../azure)."
  }
}

variable "machine" {
  type = object({
    cpu          = number
    memory_gi    = number
    disk_gi      = number
    data_disk_gi = optional(number)
  })
  default     = null
  description = "The machine as it is, when it differs from the preset's (a bare-metal box or a VM): vCPUs, GiB of memory, GiB of disk, and with data_path the GiB of that disk. make preflight and the install refuse a machine smaller than this."
}

#--- The load it is sized for -------------------------------------------------

variable "runs_per_second" {
  type        = number
  default     = null
  description = "Peak runs a second the box is sized for (a trace of 10 runs at 1 trace/s is 10). Sizes LangSmith's pods through the measured model in sizes.yaml. Default: the preset's."

  validation {
    condition     = var.runs_per_second == null || try(var.runs_per_second > 0, false)
    error_message = "runs_per_second must be above 0."
  }
}

variable "readers" {
  type        = number
  default     = null
  description = "People reading traces in the UI at once. Sizes the frontend and backend. Default: the preset's."

  validation {
    condition     = var.readers == null || try(var.readers >= 1, false)
    error_message = "readers must be at least 1."
  }
}

variable "payload_mix_pct" {
  type = object({
    small  = number
    medium = number
    large  = number
  })
  default     = null
  description = "Share of runs at each measured size, in percent: small (4 + 4 KiB), medium (32 + 32 KiB), large (about 1.5 MB). Sizes the object store and Redis. Default: 70, 25, 5 (sizes.yaml, storage)."

  validation {
    condition     = var.payload_mix_pct == null || try(var.payload_mix_pct.small + var.payload_mix_pct.medium + var.payload_mix_pct.large > 0 && min(var.payload_mix_pct.small, var.payload_mix_pct.medium, var.payload_mix_pct.large) >= 0, false)
    error_message = "payload_mix_pct needs shares of at least 0 that sum to more than 0."
  }
}

variable "storage_factor" {
  type        = number
  default     = 1
  description = "How many times the measured storage your runs take. 1 for the measured payloads, which compress well; real text can need 2 to 5. Scales the object store's volume."

  validation {
    condition     = var.storage_factor >= 0.5 && var.storage_factor <= 10
    error_message = "storage_factor must be from 0.5 to 10."
  }
}

#--- What runs beyond tracing ------------------------------------------------

variable "playground" {
  type        = bool
  default     = false
  description = "Run the playground service: prompt playground and experiments from the UI, which call model providers. Off: Lite is tracing, and the pod's 0.9 GiB goes to the stores."
}

variable "code_evaluators" {
  type        = bool
  default     = false
  description = "Run ace-backend, which executes custom code evaluators. Off: Lite is tracing."
}

variable "observability" {
  type        = bool
  default     = null
  description = "Run Prometheus, Grafana and the exporters on the box. Unset: the preset's (on, but off for xs, an instance a fleet watches from one shared stack). Every pod is labelled with the instance, for a shared Prometheus to scrape."
}

variable "mission_control" {
  type        = bool
  default     = null
  description = "Run Mission Control on the box. Unset: the preset's (on, but off for xs)."
}

variable "resources" {
  type = map(object({
    cpu_m      = number
    mem_mi     = number
    lim_cpu_m  = number
    lim_mem_mi = number
  }))
  default     = {}
  description = "Requests and limits that replace a pod's computed ones, keyed as in the plan output's pods (backend, smithdb, rustfs, ...). For a size a load test measured; cite the run beside it."

  validation {
    condition     = alltrue([for r in values(var.resources) : r.cpu_m > 0 && r.mem_mi > 0 && r.lim_mem_mi >= r.mem_mi && (r.lim_cpu_m == 0 || r.lim_cpu_m >= r.cpu_m)])
    error_message = "Each resources entry needs requests above 0, a memory limit at least its request, and a CPU limit at least its request (or 0 for none)."
  }
}

variable "max_request_ratio" {
  type        = number
  default     = 0.85
  description = "The share of the box's allocatable CPU and memory the pods may request. A box runs nothing else, so it is higher than a shared cluster's 0.7; the rest is room for bursts above requests."

  validation {
    condition     = var.max_request_ratio > 0 && var.max_request_ratio <= 1
    error_message = "max_request_ratio must be above 0 and at most 1."
  }
}

#--- Data: how long it is kept and how big it may grow ------------------------

variable "short_ttl_days" {
  type        = number
  default     = null
  description = "Days a trace is kept: the default for every project. With the long TTL it is the largest lever on the disk (SIZING.md, The retention). Unset, the plan uses 14 and says so on every plan: set it to what you must keep."

  validation {
    condition     = var.short_ttl_days == null || try(var.short_ttl_days >= 1 && floor(var.short_ttl_days) == var.short_ttl_days, false)
    error_message = "short_ttl_days must be a whole number of days, at least 1."
  }
}

variable "long_ttl_days" {
  type        = number
  default     = null
  description = "Days a trace is kept on extended retention, and SmithDB's long-term retention. Unset, the plan uses 30 (the chart's own is 400) and says so on every plan."

  validation {
    condition     = var.long_ttl_days == null || try(var.long_ttl_days >= 14 && floor(var.long_ttl_days) == var.long_ttl_days, false)
    error_message = "long_ttl_days must be a whole number of days, at least 14 (the chart refuses less)."
  }
}

variable "extended_retention_pct" {
  type        = number
  default     = 5
  description = "Percent of runs kept on extended retention (the long TTL). The rest expire at the short TTL."

  validation {
    condition     = var.extended_retention_pct >= 0 && var.extended_retention_pct <= 100
    error_message = "extended_retention_pct must be from 0 to 100."
  }
}

variable "attachment_kib_per_run" {
  type        = number
  default     = 0
  description = "Average KiB of attachments a run carries (files, images). Attachments go to the blob bucket and are kept on the run's TTL."

  validation {
    condition     = var.attachment_kib_per_run >= 0
    error_message = "attachment_kib_per_run must be 0 or more."
  }
}

variable "query_hot_days" {
  type        = number
  default     = 7
  description = "Days of recent traces SmithDB's query cache holds on local disk, so reads of them skip the object store. Sizes the cache."

  validation {
    condition     = var.query_hot_days >= 1
    error_message = "query_hot_days must be at least 1."
  }
}

variable "volumes" {
  type = object({
    postgres_gi      = optional(number)
    redis_gi         = optional(number)
    object_store_gi  = optional(number)
    smithdb_cache_gi = optional(number)
    prometheus_gi    = optional(number)
  })
  default     = {}
  description = "Volume sizes in GiB, each defaulting to the preset's. object_store_gi holds every trace for its TTL; smithdb_cache_gi is SmithDB's disposable query cache."
}

variable "ingress_namespaces" {
  type        = list(string)
  default     = ["kube-system"]
  description = "Namespaces allowed to reach LangSmith's pods beside the install's own: the ingress controller's. k3s's Traefik is in kube-system; on a cluster of one's own (cloud = cluster), name its ingress controller's, for example ingress-nginx."
}

variable "storage_class" {
  type        = string
  default     = "local-path-retain"
  description = "The storage class of the stores' volumes. On a box, k3s's local-path with Retain, which Lite makes. For make export, the cluster's own class (gp3, for example): one that keeps a volume when its claim is deleted."
}

variable "scratch_storage_class" {
  type        = string
  default     = "local-path"
  description = "The storage class of SmithDB's query cache and Prometheus's volume, both rebuilt if lost. For make export, the cluster's own."
}

variable "postgres_max_connections" {
  type        = number
  default     = null
  description = "Postgres max_connections. Unset, it is derived from the pods' pools (SIZING.md); set it only from what the PostgreSQL dashboard showed in use."
}

variable "max_payload_mb" {
  type        = number
  default     = 25
  description = "Largest request body the frontend accepts, in MB (its nginx client_max_body_size): a batch of runs, or one run with its attachments."

  validation {
    condition     = var.max_payload_mb >= 1 && floor(var.max_payload_mb) == var.max_payload_mb
    error_message = "max_payload_mb must be a whole number of MB, at least 1."
  }
}

variable "blob_min_kb" {
  type        = number
  default     = 20
  description = "Payloads at or above this many KB go to the object store rather than SmithDB's rows (config.blobStorage.minBlobStorageSizeKb)."
}

variable "redis_runs_expiry_hours" {
  type        = number
  default     = 6
  description = "Hours a run waits in Redis for the ingest workers before it is dropped. Lowering it bounds Redis's memory, at the cost of losing runs if the workers stop for longer."

  validation {
    condition     = var.redis_runs_expiry_hours >= 1
    error_message = "redis_runs_expiry_hours must be at least 1: below it a short outage of the workers loses runs."
  }
}

variable "prometheus_retention_days" {
  type        = number
  default     = 15
  description = "Days of metrics Prometheus keeps."
}

#--- Reaching it --------------------------------------------------------------

variable "access" {
  type        = string
  default     = "localhost"
  description = "How LangSmith is reached. localhost: LangSmith is not served on the box's addresses; make access forwards it to http://localhost:8080. ip: HTTPS on the box's address with a self-signed certificate. dns: HTTPS on domain with a Let's Encrypt certificate. tunnel: a Cloudflare Tunnel to domain, no inbound port. Grafana and Mission Control are reached through make access in every mode."

  validation {
    condition     = contains(["localhost", "ip", "dns", "tunnel"], var.access)
    error_message = "access must be localhost, ip, dns or tunnel."
  }
}

variable "domain" {
  type        = string
  default     = ""
  description = "The hostname LangSmith is served on, for access = dns (an A record to the box) or tunnel (a public hostname on the tunnel)."

  validation {
    condition     = var.domain == "" || can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.domain))
    error_message = "domain must be a DNS name such as langsmith.example.com, without a scheme or port."
  }
}

variable "acme_email" {
  type        = string
  default     = ""
  description = "The email Let's Encrypt registers the certificate to, for access = dns."
}

variable "access_cidrs" {
  type        = list(string)
  default     = []
  description = "Who may reach HTTPS on an aws box with access = ip or dns. Empty: nobody but through make access. Let's Encrypt's HTTP challenge needs port 80 open to 0.0.0.0/0."

  validation {
    condition     = alltrue([for c in var.access_cidrs : can(cidrhost(c, 0))])
    error_message = "access_cidrs must be CIDR blocks, such as 203.0.113.0/24."
  }
}

variable "admin_email" {
  type        = string
  default     = "admin@langsmith.lite"
  description = "The first organization admin's login. Its password is generated (make access prints it)."

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.admin_email))
    error_message = "admin_email must be an email address."
  }
}

#--- ssh, for every cloud -----------------------------------------------------

variable "ssh_host" {
  type        = string
  default     = ""
  description = "cloud = baremetal: the box's address or ssh alias. Ignored for aws, which uses the instance's address."
}

variable "ssh_user" {
  type        = string
  default     = ""
  description = "The ssh user. Empty: ~/.ssh/config's User for ssh_host on bare metal, ubuntu on AWS. It needs sudo to install and remove k3s (make up, make down), asked once per command; make status and make access run without it."
}

variable "ssh_port" {
  type        = number
  default     = null
  description = "The ssh port. Empty: ~/.ssh/config's Port for ssh_host, else 22."
}

variable "data_path" {
  type        = string
  default     = ""
  description = "cloud = baremetal: a mounted filesystem for every store's volume (a second disk, a RAID, a SAN volume), kept apart from the system. Set machine.data_disk_gi to its size. Empty: the volumes go on the root filesystem."

  validation {
    condition     = var.data_path == "" || startswith(var.data_path, "/")
    error_message = "data_path must be an absolute path."
  }
}

#--- AWS ----------------------------------------------------------------------

variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "cloud = aws: the region. The plan's cost is at us-east-1's list prices; elsewhere set aws_hourly_usd."
}

variable "aws_subnet_id" {
  type        = string
  default     = ""
  description = "cloud = aws: a public subnet for the instance. Empty: the default VPC's first subnet."
}

variable "aws_instance_type" {
  type        = string
  default     = ""
  description = "cloud = aws: the instance type. Empty: the box preset's (hosts/aws). One with the preset's vCPUs and memory or more."
}

variable "data_disk_gi" {
  type        = number
  default     = null
  description = "cloud = aws: GiB of the data volume, which holds every store's volume apart from the root volume and outlives the instance. Unset: the plan's volumes plus a fifth."
}

variable "backup_snapshot_days" {
  type        = number
  default     = 7
  description = "cloud = aws: days of daily snapshots of the data volume kept by Data Lifecycle Manager. 0 turns them off."

  validation {
    condition     = var.backup_snapshot_days >= 0 && floor(var.backup_snapshot_days) == var.backup_snapshot_days
    error_message = "backup_snapshot_days must be a whole number of days, 0 or more."
  }
}

variable "aws_hourly_usd" {
  type        = number
  default     = null
  description = "cloud = aws: the instance's price an hour, for the plan's cost estimate, when it is not the us-east-1 on-demand list price (another region, a reservation, a discount)."
}

variable "ssh_public_key" {
  type        = string
  default     = ""
  description = "cloud = aws: the public key the instance admits for ssh_user."
}

variable "admin_cidrs" {
  type        = list(string)
  default     = []
  description = "cloud = aws: who may reach ssh (port 22). Your address, as a /32."

  validation {
    condition     = alltrue([for c in var.admin_cidrs : can(cidrhost(c, 0)) && !endswith(c, "/0")])
    error_message = "admin_cidrs must be CIDR blocks, such as 203.0.113.7/32, and never the whole internet: ssh to the box is root through sudo."
  }
}

#--- Versions -----------------------------------------------------------------

variable "resolved" {
  type = object({
    charts        = map(string)
    app_versions  = map(string)
    scrape_values = optional(string, "")
  })
  default     = null
  description = "Written to resolved.auto.tfvars.json by make plan (lib/versions.sh): the exact versions pins.yaml's lines resolve to, their appVersions, and the chart's own Prometheus scrape values at that release. null in the offline tests, where each chart keeps its line."
}

#--- Secrets: from infra/.secrets.env as TF_VAR_ variables, never in a tfvars --

variable "langsmith_license_key" {
  type        = string
  default     = ""
  sensitive   = true
  description = "The LangSmith license key. make up asks for it once and keeps it in infra/.secrets.env (make secrets changes it); bin/lite passes it to Terraform as TF_VAR_langsmith_license_key."
}

variable "tunnel_token" {
  type        = string
  default     = ""
  sensitive   = true
  description = "access = tunnel: the Cloudflare Tunnel's token. make secrets saves it."
}
