# LangSmith on OCP — Teardown Guide

> **Status: Coming Soon** — This guide will be updated when the OCP module is available.

---

## Planned Teardown Order

```
Pass 3 (if enabled) — Remove LangGraph deployments (LGP CRDs + pods)
Pass 2              — Uninstall LangSmith Helm release
Pass 1              — Remove operators, namespaces, storage resources
```

### General steps (subject to change)

```bash
# Remove LGP deployments
kubectl delete lgp --all -n langsmith
kubectl delete crd lgps.apps.langchain.ai

# Uninstall Helm release
helm uninstall langsmith -n langsmith

# Delete namespace
oc delete project langsmith

# Terraform destroy
cd ocp/infra/langsmith
terraform destroy
```

See the [LangSmith Self-Hosted Changelog](https://docs.langchain.com/langsmith/self-hosted-changelog) for any version-specific teardown notes.
