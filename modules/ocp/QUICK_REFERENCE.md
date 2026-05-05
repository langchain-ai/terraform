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

## Planned Deployment

```bash
cd ocp/infra/langsmith
terraform init
terraform apply

# Install LangSmith
helm repo add langchain https://langchain-ai.github.io/helm
helm repo update

helm install langsmith langchain/langsmith \
  -f langsmith-values.yaml \
  -n langsmith --create-namespace \
  --set config.langsmithLicenseKey="<license-key>"
```

---

## Reference

- [LangSmith Helm Chart](https://langchain-ai.github.io/helm)
- [LangSmith Self-Hosted Docs](https://docs.smith.langchain.com/self_hosting)
- [LangSmith Changelog](https://docs.langchain.com/langsmith/self-hosted-changelog)
