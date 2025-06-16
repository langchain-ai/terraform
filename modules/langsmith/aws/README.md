### LangSmith AWS modules
This folder containers helpful starting terraform modules to get a self-hosted version of LangSmith up and running. Keep in mind that these are meant to be starting points. You may want to modify some of these Terraform modules depending on any internal standards you may want to adhere to (example: adding certain tags to resources).

We provide the following modules here:
- VPC module
- EKS module
- Redis cache module
- Postgres DB module
- S3 module

For production use cases, we strongly recommend using managed solutions for Redis, Postgres, and blob storage. If you want to setup the bare minimum, you will only need the VPC and EKS modules to bring up a virtual network and a kubernetes cluster within that network.

## VPC module
TODO

## EKS module
This module will provision an Elastic Kubernetes Service (EKS) cluster. The following are pre-requi

Afterwards, you may want to fetch the kubeconfig locally with a command like this:
```
aws eks update-kubeconfig \
  --region <your-region> \
  --name <your-cluster-name>

```

## Redis cache module

## Postres DB module

## S3 module
