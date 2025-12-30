# LangSmith GCP modules
This folder contains helpful starting terraform modules to get a self-hosted version of LangSmith up and running on Google Cloud Platform. Keep in mind that these are meant to be starting points. You may want to modify some of these Terraform modules depending on any internal standards (example: adding certain labels to resources).

We provide the following modules here:
- LangSmith (uses the other modules under the hood)
- Networking (VPC) module
- GKE (Google Kubernetes Engine) cluster module
- Cloud SQL (PostgreSQL) module
- Redis (Memorystore) module
- Cloud Storage (GCS) module
- IAM module
- Kubernetes bootstrap module
- Ingress module

You can use an existing VPC instead of creating one by configuring the networking module accordingly. If you bring your own VPC, you will need to provide the necessary network configuration variables mentioned in `langsmith/variables.tf`.

## LangSmith Quick Start
You can clone or fork this repo. Decide where you want to keep your terraform state:
- (Recommended) If you want to keep your terraform state in a GCS bucket, uncomment the backend configuration in `langsmith/main.tf` and update as needed.
- If you want to keep your terraform state locally, then no changes are needed.

Provide the `project_id` variable for your GCP project. Determine if you want to create a new VPC or use an existing one. The networking module will create a VPC with subnets, NAT gateway, and private service connection for managed services.

Note that the default region for this module is `us-west2`. You can change that variable as needed.

Make sure you have valid GCP credentials locally that have the permissions to create the resources, or you can add relevant fields to the `provider "google"` block. See the [official Terraform provider page](https://registry.terraform.io/providers/hashicorp/google/latest/docs) for more information. You may need to run `gcloud auth application-default login` to get credentials locally.

### Required GCP Roles
The service account or user running Terraform needs the following IAM roles:
- `roles/serviceusage.serviceUsageAdmin` - Enable required APIs
- `roles/compute.networkAdmin` - Create and manage VPC, subnets, and networking resources
- `roles/servicenetworking.networksAdmin` - Set up private service connection (required when using external PostgreSQL or Redis)
- `roles/container.admin` - Create and manage GKE clusters
- `roles/cloudsql.admin` - Create and manage Cloud SQL instances
- `roles/redis.admin` - Create and manage Memorystore Redis instances
- `roles/storage.admin` - Create and manage GCS buckets
- `roles/iam.serviceAccountAdmin` - Create service accounts for Workload Identity
- `roles/resourcemanager.projectIamAdmin` - Manage IAM bindings and permissions

Alternatively, you can use the `roles/owner` role, though it's recommended to use the minimum required permissions in production environments.

Then run the following commands from the `langsmith` folder:

```
$ terraform init
$ terraform apply
```

You will be prompted to enter your desired configuration values. You can also copy `terraform.tfvars.example` to `terraform.tfvars` and customize it for your environment. Check out the terraform plan and confirm to create the resources.

Afterwards, you may want to fetch the kubeconfig locally with a command like this:
```
gcloud container clusters get-credentials <cluster-name> --region <region> --project <project-id>
```

Once everything is created, fill out the `langsmith-values.yaml` file with your [desired configuration](https://docs.smith.langchain.com/self_hosting/configuration) and follow our [helm installation instructions](https://docs.smith.langchain.com/self_hosting/installation/kubernetes#deploying-to-kubernetes). You can use the terraform outputs from the LangSmith module to fill in things like the Cloud SQL connection details, Redis host, and GCS bucket name.

### Networking module
This module will create a new VPC with subnets, Cloud NAT, and router configuration. It also sets up private service connection for managed services (Cloud SQL and Memorystore Redis) when using external PostgreSQL or Redis. External PostgreSQL and Redis always use private IP connections via VPC peering.

### GKE cluster module
This module will provision a Google Kubernetes Engine (GKE) cluster. You can choose between Standard mode or Autopilot mode. The module configures node pools with autoscaling, network policies (configurable provider: CALICO or DATA_PLANE_V2), and Workload Identity for secure access to GCP services.

### Cloud SQL module
This module creates a Cloud SQL PostgreSQL instance with private IP only (requires VPC peering). It is only created when `postgres_source = "external"` (default). The default instance tier is `db-custom-2-8192` which has 2 vCPUs and 8 GB of memory. High availability can be enabled for production workloads. Storage size and other configurations are customizable via module variables. You must provide a PostgreSQL password via the `postgres_password` variable (minimum 8 characters) when using external PostgreSQL. It is recommended to set this via the `TF_VAR_postgres_password` environment variable for security. When `postgres_source = "in-cluster"`, PostgreSQL is deployed via the Helm chart.

### Redis module
This module creates a Memorystore Redis instance with private IP only (requires VPC peering). It is only created when `redis_source = "external"` (default). The default memory size is 5GB with high availability enabled. When `redis_source = "in-cluster"`, Redis is deployed in-cluster via the Helm chart.

### Cloud Storage module
This module creates a GCS bucket for storing LangSmith trace data. The bucket is configured with lifecycle policies matching LangSmith's TTL structure: `ttl_s/` prefix (14 days default) and `ttl_l/` prefix (400 days default). To access the bucket from LangSmith, configure GCS HMAC credentials (access key and secret) in your Helm values. See the [LangSmith blob storage documentation](https://docs.langchain.com/langsmith/self-host-blob-storage) for details.

### IAM module
This module creates a service account and sets up Workload Identity binding to allow the Kubernetes service account to authenticate as the GCP service account. The service account is granted permissions for logging, monitoring, and Secret Manager access.

### Kubernetes bootstrap module
This module handles Kubernetes-specific setup including namespace creation, secret management for database and Redis credentials, and optional installation of cert-manager and KEDA for LangSmith Deployment features.

### Ingress module
This module optionally installs and configures Envoy Gateway (Gateway API) for exposing LangSmith services. The Gateway uses HTTPS only (port 443) - TLS must be configured via cert-manager with Let's Encrypt or using existing certificates. The module supports extensibility for future ingress types (Istio, etc.), but currently only Envoy Gateway is implemented.

# Helm values
We also provide some guidance around deploying LangSmith onto these resources.

### Values file
In the `langsmith` folder, you will also see a `langsmith-values.yaml` file which provides a lot of the configuration required to connect to these external resources. Feel free to use that as a starting point.

