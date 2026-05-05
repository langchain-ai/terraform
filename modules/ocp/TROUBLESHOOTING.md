# LangSmith on OCP — Troubleshooting Guide

> **Status: Coming Soon** — This guide will be updated as the OCP module is developed.

Issues and fixes will be documented here as they are discovered during development and customer deployments.

---

## Known Considerations

### SCC (Security Context Constraints)

OpenShift enforces SCCs more strictly than standard Kubernetes pod security. LangSmith pods may require a custom SCC or the `nonroot` SCC to run without `root` privileges.

### Route vs Gateway API

OpenShift Routes are the default ingress mechanism on OCP. The Gateway API (via OpenShift Gateway API or Istio) is available on OCP 4.13+. The module will support both.

### ODF / S3-Compatible Storage

OpenShift Data Foundation (ODF) provides an S3-compatible object store (Noobaa/MCGS). LangSmith blob storage is configured identically to any S3-compatible endpoint — set `endpoint_url`, `access_key`, and `secret_key` in Helm values.

---

## Reference

- [LangSmith Self-Hosted Changelog](https://docs.langchain.com/langsmith/self-hosted-changelog)
- [OpenShift SCC Documentation](https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html)
