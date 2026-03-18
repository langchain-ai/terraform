# LangSmith OCP modules

> **Status: Coming Soon** — This module is under active development.

This folder will contain Terraform modules to deploy a self-hosted version of LangSmith on OpenShift Container Platform (OCP), including ROSA (Red Hat OpenShift Service on AWS) and on-premises OpenShift deployments.

## Planned modules

- LangSmith (root module)
- Routes (OpenShift Route or Gateway API)
- cert-manager integration
- PostgreSQL Operator (Crunchy Data or in-cluster)
- Redis Operator (or in-cluster Redis)
- OpenShift Data Foundation (ODF) for object storage

## Planned deployment model

```
Pass 1 — OCP Infrastructure (cluster assumed pre-existing)
           Namespaces, RBAC, operators, storage classes

Pass 2 — LangSmith Base Platform
           Helm install via oc / helm

Pass 3 — LangSmith Deployments (LangGraph Platform)
           enable_langsmith_deployments = true
```

## Prerequisites (planned)

- OpenShift 4.12+ or ROSA cluster
- `oc` CLI authenticated (`oc login`)
- Helm 3.12+
- Terraform 1.5+
- Cluster admin role for initial setup

## Reference

- [LangSmith Self-Hosted Docs](https://docs.smith.langchain.com/self_hosting)
- [LangSmith Self-Hosted Changelog](https://docs.langchain.com/langsmith/self-hosted-changelog)
- [OpenShift Documentation](https://docs.openshift.com)
