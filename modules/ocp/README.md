# LangSmith OCP modules

> **Status: Coming Soon** — This module is under active development.

This folder will contain Terraform modules to deploy a self-hosted version of LangSmith on OpenShift Container Platform (OCP), including ROSA (Red Hat OpenShift Service on AWS) and on-premises OpenShift deployments.

> **Releases:** when this module ships, deploy from the latest `v0.16.*` release tag, not `main`. Tags pin the LangSmith chart line (`~0.16.0` = latest `0.16.x`). See [Versioning and releases](../../README.md#versioning-and-releases).

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
- Terraform 1.11.0+
- Cluster admin role for initial setup

## Secrets

The chart can generate its own Kubernetes Secrets, or read secrets that already
exist. This module always uses existing secrets: `helm/values/values.yaml` sets
`config.existingSecretName: langsmith-secrets`, and the values-overrides example
sets `postgres.external.existingSecretName` / `redis.external.existingSecretName`.
See [Self-host using an existing secret](https://docs.langchain.com/langsmith/self-host-using-an-existing-secret).

The consequence to know before editing values: with `config.existingSecretName`
set, the chart never renders its own `secrets.yaml`, so every secret-bearing
`config.*` value is inert. Setting `config.oauth.oauthClientSecret` or
`insights.encryptionKey` in a values file does nothing — those go in the secret.

### Creating them

```bash
export LANGSMITH_LICENSE_KEY=...
export INITIAL_ORG_ADMIN_PASSWORD=...          # >= 12 bytes, upper, lower, symbol
export POSTGRES_CONNECTION_URL="postgresql://langsmith:...@postgres.example.com:5432/langsmith"
export REDIS_CONNECTION_URL="rediss://:...@redis.example.com:6380/0"
./helm/scripts/generate-secrets.sh
```

The script creates the namespace, grants the SCC, applies the secrets and then
lists the keys that landed. It never prints a value, and passes them to `oc` as
base64 on stdin rather than as `--from-literal` arguments, so they stay out of the
process list.

| Secret | Key | Environment variable | Required when |
|---|---|---|---|
| `langsmith-secrets` | `langsmith_license_key` | `LANGSMITH_LICENSE_KEY` | always |
| | `api_key_salt` | `API_KEY_SALT` | generated if unset |
| | `jwt_secret` | `JWT_SECRET` | generated if unset |
| | `initial_org_admin_password` | `INITIAL_ORG_ADMIN_PASSWORD` | `config.basicAuth.enabled` |
| | `oauth_client_id` | `OAUTH_CLIENT_ID` | `config.oauth.enabled` |
| | `oauth_client_secret` | `OAUTH_CLIENT_SECRET` | `config.authType: mixed` |
| | `oauth_issuer_url` | `OAUTH_ISSUER_URL` | `config.oauth.enabled` |
| | `blob_storage_access_key` | `BLOB_STORAGE_ACCESS_KEY` | static object-storage creds |
| | `blob_storage_access_key_secret` | `BLOB_STORAGE_ACCESS_KEY_SECRET` | static object-storage creds |
| | `agent_builder_encryption_key` | `AGENT_BUILDER_ENCRYPTION_KEY` | generated if unset |
| | `insights_encryption_key` | `INSIGHTS_ENCRYPTION_KEY` | generated if unset |
| | `polly_encryption_key` | `POLLY_ENCRYPTION_KEY` | generated if unset |
| | `engine_encryption_key` | `ENGINE_ENCRYPTION_KEY` | generated if unset |
| | `langsmith_signing_jwks` | `LANGSMITH_SIGNING_JWKS` | optional |
| | `sandbox_callback_signing_jwk` | `SANDBOX_CALLBACK_SIGNING_JWK` | `sandboxes.enabled` |
| `langsmith-postgres` | `connection_url` | `POSTGRES_CONNECTION_URL` | external Postgres |
| `langsmith-redis` | `connection_url` | `REDIS_CONNECTION_URL` | external Redis |

Key names are fixed by chart 0.16. A misspelled key reaches the pod as an empty
environment variable rather than an error, so trust the table over improvisation.

Anything marked "generated if unset" is generated only on first run: after that
the script reads the value back out of the secret and reuses it, because a new
`api_key_salt` invalidates every issued API key, a new `jwt_secret` logs everyone
out, and a new encryption key orphans that product's stored data. Export a value
to set it explicitly instead.

The four encryption keys are Fernet keys, not hex strings. The documented
`openssl rand -hex 32` recipe produces 64 characters, which these products
reject; the script generates 32 random bytes as URL-safe base64, matching the
chart's own `Fernet.generate_key()` instruction. Generated keys exist only in the
cluster, so back them up out of it before you rely on the install:

```bash
oc get secret langsmith-secrets -n langsmith -o jsonpath='{.data.insights_encryption_key}' | base64 --decode
```

### Pulling images from an internal registry

A cluster with no egress to Docker Hub needs `images.registry` pointed at its
proxy; the commented block in `helm/values/values-overrides.yaml.example` has the
detail. The value is *prepended* to repositories that already carry their upstream
host, so `nexus.example.com` yields
`nexus.example.com/docker.io/langchain/langsmith-backend`. Chart 0.16 pulls from
three upstream hosts — `docker.io`, `mcr.microsoft.com` (presidio, with insights)
and `registry.k8s.io` (the CSI registrar, with sandboxes) — and each needs a proxy
path before the install can pull.

### Terraform as the other writer

`infra/modules/secrets` writes the same two datastore secrets when
`postgres_connection_url` / `redis_connection_url` are set, and skips them when
empty. Set each URL in one place — Terraform or the script — not both. Both URLs
embed a password and land in Terraform state in plaintext, so keep state in an
encrypted remote backend, or leave the variables empty and let the script own them.

For production, swap either writer for the External Secrets Operator or the Vault
Agent Injector. Note that the chart drops its `checksum/secrets` pod annotation
whenever `existingSecretName` is set, so rotating a secret does not restart the
pods on its own — drive that with Reloader or a deliberate restart.

## Reference

- [LangSmith Self-Hosted Docs](https://docs.smith.langchain.com/self_hosting)
- [LangSmith Self-Hosted Changelog](https://docs.langchain.com/langsmith/self-hosted-changelog)
- [OpenShift Documentation](https://docs.openshift.com)
