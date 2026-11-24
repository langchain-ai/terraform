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

#--- The box ------------------------------------------------------------------

variable "cloud" {
  type        = string
  default     = "baremetal"
  description = "Where the box comes from. baremetal: a machine you already have, reached over ssh. aws: an EC2 instance this module creates. gcp and azure are coming (infra/hosts/README.md)."

  validation {
    condition     = contains(["baremetal", "aws"], var.cloud)
    error_message = "cloud must be baremetal or aws; gcp and azure are not built yet (infra/hosts/README.md)."
  }
}

variable "box" {
  type        = string
  default     = "s"
  description = "The size preset: s (4 vCPU, 16 GiB), m (8 vCPU, 32 GiB) or l (16 vCPU, 64 GiB). Sets the machine, the design load and every store's size (sizes.yaml)."

  validation {
    condition     = contains(["s", "m", "l"], var.box)
    error_message = "box must be s, m or l."
  }
}

variable "machine" {
  type = object({
    cpu       = number
    memory_gi = number
    disk_gi   = number
  })
  default     = null
  description = "The machine as it is, when it differs from the preset's (a bare-metal box or a VM): vCPUs, GiB of memory and GiB of disk. The install refuses a machine smaller than this."
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
  default     = 14
  description = "Days a trace is kept on the short tier, the default for every project. Drives LangSmith's TTL and the blob bucket's expiry rule for ttl_s/."

  validation {
    condition     = var.short_ttl_days >= 1 && floor(var.short_ttl_days) == var.short_ttl_days
    error_message = "short_ttl_days must be a whole number of days, at least 1."
  }
}

variable "long_ttl_days" {
  type        = number
  default     = 30
  description = "Days a trace is kept on the long tier (extended retention). Drives LangSmith's TTL, SmithDB's long-term retention and the blob bucket's expiry rule for ttl_l/. Lower than the chart's 400 so one box's disk stays bounded."

  validation {
    condition     = var.long_ttl_days >= 14 && floor(var.long_ttl_days) == var.long_ttl_days
    error_message = "long_ttl_days must be a whole number of days, at least 14 (the chart refuses less)."
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

variable "postgres_max_connections" {
  type        = number
  default     = 200
  description = "Postgres max_connections. The Grafana Postgres dashboard shows connections in use; raise this before they reach it."
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
  description = "The ssh user. Empty: ~/.ssh/config's User for ssh_host on bare metal, ubuntu on AWS. It needs sudo to install and remove k3s (make up, make install, make down), asked once per command; make status and make access run without it."
}

variable "ssh_port" {
  type        = number
  default     = null
  description = "The ssh port. Empty: ~/.ssh/config's Port for ssh_host, else 22."
}

#--- AWS ----------------------------------------------------------------------

variable "aws_region" {
  type        = string
  default     = "us-west-2"
  description = "cloud = aws: the region."
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
    condition     = alltrue([for c in var.admin_cidrs : can(cidrhost(c, 0))])
    error_message = "admin_cidrs must be CIDR blocks, such as 203.0.113.7/32."
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
  description = "The LangSmith license key. make secrets saves it in infra/.secrets.env; bin/lite passes it to Terraform as TF_VAR_langsmith_license_key."
}

variable "tunnel_token" {
  type        = string
  default     = ""
  sensitive   = true
  description = "access = tunnel: the Cloudflare Tunnel's token. make secrets saves it."
}
