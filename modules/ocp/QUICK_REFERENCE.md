---
title: "Quick Reference"
description: "Essential commands and shortcuts for managing a LangSmith deployment on OpenShift."
provider: "ocp"
type: "reference"
---

# LangSmith on OCP — Quick Reference

> **Status: Coming Soon** — Commands will be added when the OCP module is available.

---

## Planned Prerequisites

```bash
# Authenticate to OpenShift cluster
oc login --token=<token> --server=<api-url>
oc whoami   # verify

# Verify cluster version
oc version
```

---

## Secrets

The chart reads existing secrets on this module — see the key table in
[README.md](README.md#secrets).

```bash
# Create or update them
export LANGSMITH_LICENSE_KEY=...
export INITIAL_ORG_ADMIN_PASSWORD=...
export POSTGRES_CONNECTION_URL=...
export REDIS_CONNECTION_URL=...
./helm/scripts/generate-secrets.sh
```

```bash
# Which keys are in the secret (names only, no values)
oc get secret langsmith-secrets -n langsmith -o jsonpath='{range $k,$v := .data}{$k}{"\n"}{end}'
```

```bash
# Confirm the chart is reading them rather than generating its own
helm get values langsmith -n langsmith --all | grep -B1 -A1 existingSecretName
```

Rotating a secret does not restart the pods: with `existingSecretName` set the
chart drops its `checksum/secrets` annotation, so roll the deployments yourself
(`oc rollout restart deployment -n langsmith`) or run Reloader.

---

## Planned Deployment

```bash
cd ocp/infra/langsmith
terraform init
terraform apply

# Install LangSmith
helm repo add langchain https://langchain-ai.github.io/helm
helm repo update

# The license key comes from the secret above, not --set: with
# config.existingSecretName set, config.langsmithLicenseKey is ignored.
helm install langsmith langchain/langsmith \
  -f langsmith-values.yaml \
  -n langsmith --create-namespace
```

---

## Reference

- [LangSmith Helm Chart](https://langchain-ai.github.io/helm)
- [LangSmith Self-Hosted Docs](https://docs.smith.langchain.com/self_hosting)
- [LangSmith Changelog](https://docs.langchain.com/langsmith/self-hosted-changelog)
