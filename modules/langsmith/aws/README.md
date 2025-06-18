### LangSmith AWS modules
This folder containers helpful starting terraform modules to get a self-hosted version of LangSmith up and running. Keep in mind that these are meant to be starting points. You may want to modify some of these Terraform modules depending on any internal standards you may want to adhere to (example: adding certain tags to resources).

We provide the following modules here:
- VPC module
- EKS module
- Redis cache module
- Postgres DB module
- S3 module

You can use an existing VPC instead of creating one by setting the `create_vpc` variable to false. If you bring your own VPC, you will need to provide a couple of variables mentioned in `langsmith_full/variables.tf`

## VPC module
This module will create a new VPC with a single NAT gateway as well as some subnet tags to assist in load balancer creation.

## EKS module
This module will provision an Elastic Kubernetes Service (EKS) cluster. The following add ons are created on the cluster as part of this module:
- Metrics server
- Load balancer controller
- Cluster autoscaler
- EBS CSI driver


Afterwards, you may want to fetch the kubeconfig locally with a command like this:
```
aws eks update-kubeconfig \
  --region <your-region> \
  --name <your-cluster-name>

```

## Redis cache module
This module will create a Redis Elasticache in the provided subnets and enable inbound traffic from the EKS module. The default instance type created by the module is a `cache.m5.large` which has 2 vCPUs and 6 GB of memory. Feel free to update this based on your desired scale and our [scaling recommendations](https://docs.smith.langchain.com/self_hosting/configuration/scale).

## Postres DB module
This module will create a private PostgresQL RDS instance and enable traffic from the ingress CIDRs provided. Please make sure to set an appropriate username and password. The default instance is a `db.t3.large` which has 2 vCPUs and 8 GB of memory. We also configure the database to have 10GB of storage. This is configurable by passing in variables to the module.

## S3 module
This module creates an S3 bucket and enables access only from a desired VPC.
