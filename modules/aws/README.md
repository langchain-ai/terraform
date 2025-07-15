# LangSmith AWS modules
This folder containers helpful starting terraform modules to get a self-hosted version of LangSmith up and running. Keep in mind that these are meant to be starting points. You may want to modify some of these Terraform modules depending on any internal standards (example: adding certain tags to resources).

We provide the following modules here:
- VPC module
- EKS module
- Redis cache module
- PostgreSQL DB module
- S3 module

You can use an existing VPC instead of creating one by setting the `create_vpc` variable to false. If you bring your own VPC, you will need to provide a couple of variables mentioned in `langsmith/variables.tf`

## Quick Start
You can clone or fork this repo. Decide where you want to keep your terraform state:
- (Recommended) If you want to keep your terraform state in an S3 bucket, comment out backend.tf and update as needed.
- If you want to keep your terraform state locally, then no changes are needed.

Determine if you want to create a new VPC or use an existing one. If you want to use an existing VPC, set the `create_vpc` variable to false and you will need to provide `vpc_id`, `private_subnets`, `public_subnets`, and `vpc_cidr_block` as variables.

Note that the default region for this module is `us-west-2`. You can change that variable as needed.

Make sure you have valid AWS credentials locally that have the permissions to create the resources, or you can add relevant fields to the `provider "aws"` block. See the [official Terraform provider page](https://registry.terraform.io/providers/hashicorp/aws/latest/docs) for more information.
You will also need to wait for the EKS cluster to be created to bootstrap some of the resources. Here is a sample `main.tf` file that you can use to get started:

```hcl
locals {
  region    = "us-west-2"
}

provider "aws" {
  region = local.region
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.eks.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.eks.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.eks.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.eks.token
  }
}

resource "null_resource" "wait_for_cluster" {
  provisioner "local-exec" {
    command = "aws eks wait cluster-active --name ${module.langsmith.cluster_name} --region ${local.region}"
  }
}

data "aws_eks_cluster" "eks" {
  name = module.langsmith.cluster_name

  depends_on = [null_resource.wait_for_cluster]
}

data "aws_eks_cluster_auth" "eks" {
  name = module.langsmith.cluster_name

  depends_on = [null_resource.wait_for_cluster]
}

module "langsmith" {
  source = "git::https://github.com/langchain-ai/terraform.git//modules/aws/langsmith?ref=infra/dont-use-eks-module-add-outputs-2"
  
  region            = local.region
  postgres_username = "pgusername"
  postgres_password = "your postgres password"
}
```

Then run the following commands from the `langsmith` folder:

```
$ terraform init
$ terraform apply
```

You will be prompted to enter your desired postgres_password and postgres_username for the database that will be created. Check out the terraform plan and confirm to create the resources.

Afterwards, you may want to fetch the kubeconfig locally with a command like this:
```
aws eks update-kubeconfig \
  --region <your-region> \
  --name <your-cluster-name>
```

Once everything is created, fill out the values_aws.yaml file with your [desired configuration](https://docs.smith.langchain.com/self_hosting/configuration) and follow our [helm installation instructions](https://docs.smith.langchain.com/self_hosting/installation/kubernetes#deploying-to-kubernetes)

### VPC module
This module will create a new VPC with a single NAT gateway as well as some subnet tags to assist in load balancer creation. By default, this module will create 5 private subnets and 3 public subnets in this VPC. Other resources that require its own subnet (like the Postgres database) can use a subset of the private subnets.

### EKS module
This module will provision an Elastic Kubernetes Service (EKS) cluster. The following add ons are created on the cluster as part of this module:
- Metrics server
- Load balancer controller
- Cluster autoscaler
- EBS CSI driver

### Redis cache module
This module will create a Redis Elasticache in the provided subnets and enable inbound traffic from the EKS module. The default instance type created by the module is a `cache.m5.large` which has 2 vCPUs and 6 GB of memory. Feel free to update this based on your desired scale and our [scaling recommendations](https://docs.smith.langchain.com/self_hosting/configuration/scale).

### PostresQL database module
This module will create a private PostgreSQL RDS instance and enable traffic from the ingress CIDRs provided. Please make sure to set an appropriate username and password.

The default instance is a `db.t3.large` which has 2 vCPUs and 8 GB of memory. We also configure the database to have 10GB of storage. This is configurable by passing in variables to the module.

### S3 module
This module creates an S3 bucket and enables access only from a desired VPC endpoint. This will enable access from the Kubernetes cluster.

# Helm values
We also provide some guidance around deploying LangSmith onto these resources.

### Values file
In the `langsmith` folder, you will also see a `values_aws.yaml` file which provides a lot of the configuration required to connect to these external resources. Feel free to use that as a starting point.
